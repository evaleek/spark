var global_gpa: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init.Minimal) !void {
    defer {
        const leaks = global_gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        global_gpa.deinitWithoutLeakChecks();
    }
    const allocator = global_gpa.allocator();

    var display: Display = undefined;

    display.stream = conn: {
        if (spark.wayland.getPreconnectedSocket(init.environ)) |res| {
            if (res) |fd| {
                std.log.info("found preconnected wayland display socket at fd {d}", .{fd});
                break :conn .{ .socket = fd };
            }
        } else |_| {
            std.log.err("failed to parse fd from WAYLAND_SOCKET=\"{s}\"", .{ init.environ.getPosix("WAYLAND_SOCKET").? });
        }

        const addr: std.posix.system.sockaddr.un = addr: {
            var addr: std.posix.system.sockaddr.un = .{
                .family = system.AF.UNIX,
                .path = undefined,
            };
            var w: Io.Writer = .fixed(&addr.path);
            spark.wayland.printDisplayPath(&w, init.environ) catch |err| switch (err) {
                error.MissingXDGRuntimeDir => |e| return e,
                error.WriteFailed => return error.WaylandDisplayPathTooBig,
            };
            w.writeByte(0) catch return error.WaylandDisplayPathTooBig;
            break :addr addr;
        };
        const stream: ipc.DomainStream = try .open(&addr, .{});
        std.log.info("successfully connected to domain stream at {s}", .{ @as([*:0]const u8, @ptrCast(&addr.path)) });
        break :conn stream;
    };
    defer ipc.closeFd(display.stream.socket);

    display.transfer_queue = try .create(.{});
    defer display.transfer_queue.deinit();

    _ = allocator;

    testDisplayConnection(&display) catch |err| switch (err) {
        error.EndOfStream => std.log.info("encountered end of stream", .{}),
        else => |e| return e,
    };
}

fn testDisplayConnection(display: *Display) !void {
    var next_id_counter: u32 = 1;
    var object_map: Object.Map = .empty;
    var registry_proxy: RegistryProxy = .empty;

    const surface_width: u32 = 200;
    const surface_height: u32 = 200;
    const surface_buffer_format: wire.protocol.wayland.Shm.Format.Code = .xrgb8888;
    const surface_buffer_pixel_stride: u32 = 4; // TODO function for format -> pixel size
    const surface_buffer_stride: u32 = surface_width * surface_buffer_pixel_stride;
    const surface_buffer_size: u32 = surface_buffer_stride * surface_height;
    const surface_buffer_count: u32 = 1;
    const shm_size: u32 = surface_buffer_size * surface_buffer_count;
    const shm_file: ipc.AnonymousFile = try .createMemFd("wl_shm", shm_size);
    defer shm_file.closeMemFd();
    const shm_data = try shm_file.map(0, shm_size);
    if (shm_data.len != shm_size) unreachable;
    defer ipc.AnonymousFile.unmap(shm_data);
    const surface_buffers: [surface_buffer_count]*[surface_buffer_size]u8 = .{
        shm_data[0..surface_buffer_size],
        //shm_data[surface_buffer_size..][0..surface_buffer_size],
    };

    object_map.bind(.display, try allocObjectId(&next_id_counter));
    {
        const registry_id = try allocObjectId(&next_id_counter);
        object_map.bind(.registry, registry_id);
        try display.pushRequest(.wl_display, .{ .id = wire.object_id.display }, .{ .get_registry = .{
            .registry = .{ .id = registry_id },
        }});
    }
    {
        const init_sync_id = try allocObjectId(&next_id_counter);
        object_map.bind(.init_sync, init_sync_id);
        try display.pushRequest(.wl_display, .{ .id = wire.object_id.display }, .{ .sync = .{
            .callback = .{ .id = init_sync_id },
        }});
    }
    try display.flush();

    {
        var in_roundtrip: bool = true;
        while (in_roundtrip) {
            const header, const payload = try display.peekNextEventRaw();
            if (header.info.size % 4 != 0) return error.InvalidMessageSize;
            const object = object_map.getObject(header.object) orelse return error.UnmappedObject;
            switch (object) {
                .display => try dispatchDisplayEvent(
                    &object_map,
                    try display.parseEvent(.wl_display, header, payload),
                ),
                .registry => try dispatchRegistryEvent(
                    &registry_proxy,
                    try display.parseEvent(.wl_registry, header, payload),
                    true,
                ),
                .init_sync => switch (try display.parseEvent(.wl_callback, header, payload)) {
                    .done => |done| {
                        if (in_roundtrip == false) unreachable;
                        log.info("finished init roundtrip (0x{x})", .{ done.callback_data });
                        in_roundtrip = false;
                    },
                },
                .compositor => unreachable,
                .xdg_wm_base => unreachable,
                .surface => unreachable,
                .xdg_surface => unreachable,
                .xdg_toplevel => unreachable,
                .shm => unreachable,
                .shm_pool => unreachable,
                .buffer_1, .buffer_2 => unreachable,
            }
            display.tossBuffered(header.info.size);
        }
    }

    if (!registry_proxy.hasAll()) return error.MissingWaylandGlobals;

    {
        const compositor_id = try allocObjectId(&next_id_counter);
        object_map.bind(.compositor, compositor_id);
        const registry_entry = registry_proxy.get(.wl_compositor)
            orelse return error.MissingWaylandGlobals;
        try display.pushRequest(.wl_registry, .{ .id = object_map.getId(.registry).? }, .{ .bind = .{
            .name = registry_entry.name,
            .id = .{
                .name = .fromSlice(@tagName(.wl_compositor)),
                // TODO consume actual version somewhere
                .version = @min(registry_entry.version, wire.protocol.wayland.Compositor.version),
                .id = compositor_id,
            },
        }});
    }
    {
        const xdg_wm_id = try allocObjectId(&next_id_counter);
        object_map.bind(.xdg_wm_base, xdg_wm_id);
        const registry_entry = registry_proxy.get(.xdg_wm_base)
            orelse return error.MissingWaylandGlobals;
        try display.pushRequest(.wl_registry, .{ .id = object_map.getId(.registry).? }, .{ .bind = .{
            .name = registry_entry.name,
            .id = .{
                .name = .fromSlice(@tagName(.xdg_wm_base)),
                // TODO consume actual version somewhere
                .version = @min(registry_entry.version, wire.protocol.xdg_shell.WmBase.version),
                .id = xdg_wm_id,
            },
        }});
    }
    {
        const surface_id = try allocObjectId(&next_id_counter);
        object_map.bind(.surface, surface_id);
        try display.pushRequest(.wl_compositor, .{ .id = object_map.getId(.compositor).? }, .{ .create_surface = .{
            .id = .{ .id = surface_id },
        }});
    }
    {
        const xdg_surface_id = try allocObjectId(&next_id_counter);
        object_map.bind(.xdg_surface, xdg_surface_id);
        try display.pushRequest(.xdg_wm_base, .{ .id = object_map.getId(.xdg_wm_base).? }, .{ .get_xdg_surface = .{
            .id = .{ .id = xdg_surface_id },
            .surface = .{ .id = object_map.getId(.surface).? },
        }});
    }
    {
        const xdg_toplevel_id = try allocObjectId(&next_id_counter);
        object_map.bind(.xdg_toplevel, xdg_toplevel_id);
        try display.pushRequest(.xdg_surface, .{ .id = object_map.getId(.xdg_surface).? }, .{ .get_toplevel = .{
            .id = .{ .id = xdg_toplevel_id },
        }});
    }
    try display.pushRequest(.wl_surface, .{ .id = object_map.getId(.surface).? }, .{ .commit = .{}});
    try display.flush();

    var configure_acc: ConfigureState = .empty;
    var last_configure: ConfigureState = .empty;

    {
        var init_configure: bool = true;
        while (init_configure) {
            const header, const payload = try display.peekNextEventRaw();
            if (header.info.size % 4 != 0) return error.InvalidMessageSize;
            const object = object_map.getObject(header.object) orelse return error.UnmappedObject;
            switch (object) {
                .display => try dispatchDisplayEvent(
                    &object_map,
                    try display.parseEvent(.wl_display, header, payload),
                ),
                .registry => try dispatchRegistryEvent(
                    &registry_proxy,
                    try display.parseEvent(.wl_registry, header, payload),
                    true,
                ),
                .init_sync => unreachable, // TODO should be error
                .compositor => unreachable, // no events
                .xdg_wm_base => switch (try display.parseEvent(.xdg_wm_base, header, payload)) {
                    .ping => |ping| {
                        log.info("got ping (0x{x})", .{ping.serial});
                        try display.pushRequest(.xdg_wm_base, .{ .id = object_map.getId(.xdg_wm_base).? }, .{ .pong = .{
                            .serial = ping.serial,
                        }});
                        try display.flush(); // TODO unbatched
                        log.info("sent pong (0x{x})", .{ping.serial});
                    },
                },
                .surface => switch (try display.parseEvent(.wl_surface, header, payload)) {
                    inline else => |args, event| log.info("wl_surface.{t}: {f}", .{ event, wire.formatAlt(args) }),
                },
                .xdg_surface => switch (try display.parseEvent(.xdg_surface, header, payload)) {
                    .configure => |configure| {
                        log.info("got configure (0x{x})", .{configure.serial});
                        if (!configure_acc.isComplete()) log.warn("xdg_surface.configure with incomplete state", .{});
                        last_configure = configure_acc;
                        configure_acc = .empty;

                        try display.pushRequest(.xdg_surface, .{ .id = object_map.getId(.xdg_surface).? }, .{ .ack_configure = .{
                            .serial = configure.serial,
                        }});
                        try display.flush(); // TODO unbatched
                        log.info("acked configure (0x{x})", .{configure.serial});
                        if (init_configure == true) {
                            init_configure = false;
                        } else {
                            unreachable;
                        }
                    },
                },
                .xdg_toplevel => switch (try display.parseEvent(.xdg_toplevel, header, payload)) {
                    // TODO
                    .configure => |configure| {
                        if (configure_acc.size == null) {
                            configure_acc.size = .{ configure.width, configure.height };
                        } else {
                            log.err("xdg_toplevel.configure state collision", .{});
                        }
                    },
                    inline else => |args, event| log.info("xdg_toplevel.{t}: {f}", .{ event, wire.formatAlt(args) }),
                },
                .shm => unreachable,
                .shm_pool => unreachable,
                .buffer_1, .buffer_2 => unreachable,
            }
            display.tossBuffered(header.info.size);
        }
    }
    log.info("received initial configure", .{});

    {
        const shm_id = try allocObjectId(&next_id_counter);
        object_map.bind(.shm, shm_id);
        const registry_entry = registry_proxy.get(.wl_shm)
            orelse return error.MissingWaylandGlobals;
        try display.pushRequest(.wl_registry, .{ .id = object_map.getId(.registry).? }, .{ .bind = .{
            .name = registry_entry.name,
            .id = .{
                .name = .fromSlice(@tagName(.wl_shm)),
                // TODO consume actual version somewhere
                .version = @min(registry_entry.version, wire.protocol.wayland.Shm.version),
                .id = shm_id,
            },
        }});
    }
    // Wayland compositors are required to support `.argb8888` and `.xrgb8888`,
    // so we pick the format without checking for support first
    // and let the display send the fatal error if it's missing.
    {
        const shm_pool_id = try allocObjectId(&next_id_counter);
        object_map.bind(.shm_pool, shm_pool_id);
        try display.pushRequest(.wl_shm, .{ .id = object_map.getId(.shm).? }, .{ .create_pool = .{
            .id = .{ .id = shm_pool_id },
            .fd = .{ .descriptor = shm_file.fd },
            .size = @intCast(shm_size),
        }});
    }
    {
        const buffer_1_id = try allocObjectId(&next_id_counter);
        //const buffer_2_id = try allocObjectId(&next_id_counter);
        object_map.bind(.buffer_1, buffer_1_id);
        try display.pushRequest(.wl_shm_pool, .{ .id = object_map.getId(.shm_pool).? }, .{ .create_buffer = .{
            .id = .{ .id = buffer_1_id },
            .offset = 0,
            .width = surface_width,
            .height = surface_height,
            .stride = surface_buffer_stride,
            .format = surface_buffer_format,
        }});
        //object_map.bind(.buffer_2, buffer_2_id);
        //try display.pushRequest(.wl_shm_pool, .{ .id = object_map.getId(.shm_pool).? }, .{ .create_buffer = .{
        //    .id = .{ .id = buffer_2_id },
        //    .offset = surface_buffer_size,
        //    .width = surface_width,
        //    .height = surface_height,
        //    .stride = surface_buffer_stride,
        //    .format = surface_buffer_format,
        //}});
    }
    try display.pushRequest(.wl_surface, .{ .id = object_map.getId(.surface).? }, .{ .attach = .{
        .buffer = .{ .id = object_map.getId(.buffer_1).? },
        .x = 0,
        .y = 0,
    }});
    try display.pushRequest(.wl_surface, .{ .id = object_map.getId(.surface).? }, .{ .damage_buffer = .{
        .x = 0,
        .y = 0,
        .width = std.math.maxInt(i32),
        .height = std.math.maxInt(i32),
    }});
    try display.pushRequest(.wl_surface, .{ .id = object_map.getId(.surface).? }, .{ .commit = .{}});
    try display.flush();

    _ = surface_buffers;

    while (true) {
        const header, const payload = try display.peekNextEventRaw();
        if (header.info.size % 4 != 0) return error.InvalidMessageSize;
        const object = object_map.getObject(header.object) orelse return error.UnmappedObject;
        switch (object) {
            .display => try dispatchDisplayEvent(
                &object_map,
                try display.parseEvent(.wl_display, header, payload),
            ),
            .registry => try dispatchRegistryEvent(
                &registry_proxy,
                try display.parseEvent(.wl_registry, header, payload),
                true,
            ),
            .init_sync => unreachable, // TODO should be error
            .compositor => unreachable, // no events
            .xdg_wm_base => switch (try display.parseEvent(.xdg_wm_base, header, payload)) {
                .ping => |ping| {
                    log.info("got ping (0x{x})", .{ping.serial});
                    try display.pushRequest(.xdg_wm_base, .{ .id = object_map.getId(.xdg_wm_base).? }, .{ .pong = .{
                        .serial = ping.serial,
                    }});
                    try display.flush(); // TODO unbatched
                    log.info("sent pong (0x{x})", .{ping.serial});
                },
            },
            .surface => switch (try display.parseEvent(.wl_surface, header, payload)) {
                inline else => |args, event| log.info("wl_surface.{t}: {f}", .{ event, wire.formatAlt(args) }),
            },
            .xdg_surface => switch (try display.parseEvent(.xdg_surface, header, payload)) {
                .configure => |configure| {
                    log.info("got configure (0x{x})", .{configure.serial});
                    if (!configure_acc.isComplete()) log.warn("xdg_surface.configure with incomplete state", .{});
                    last_configure = configure_acc;
                    configure_acc = .empty;

                    try display.pushRequest(.xdg_surface, .{ .id = object_map.getId(.xdg_surface).? }, .{ .ack_configure = .{
                        .serial = configure.serial,
                    }});
                    try display.flush(); // TODO unbatched
                    log.info("acked configure (0x{x})", .{configure.serial});
                },
            },
            .xdg_toplevel => switch (try display.parseEvent(.xdg_toplevel, header, payload)) {
                // TODO
                .configure => |configure| {
                    if (configure_acc.size == null) {
                        configure_acc.size = .{ configure.width, configure.height };
                    } else {
                        log.err("xdg_toplevel.configure state collision", .{});
                    }
                },
                inline else => |args, event| log.info("xdg_toplevel.{t}: {f}", .{ event, wire.formatAlt(args) }),
            },
            .shm => switch (try display.parseEvent(.wl_shm, header, payload)) {
                .format => |format| log.debug("wl_shm offers format: {t}", .{format.format}),
            },
            .shm_pool => unreachable, // no events
            .buffer_1 => switch (try display.parseEvent(.wl_buffer, header, payload)) {
                .release => log.info("buffer_1.release", .{}),
            },
            .buffer_2 => unreachable,
            //.buffer_2 => switch (try display.parseEvent(.wl_buffer, header, payload)) {
            //    .release => log.info("buffer_2.release", .{}),
            //},
        }
        display.tossBuffered(header.info.size);
    }

    log.info("closing", .{});
}

fn dispatchDisplayEvent(
    object_map: *Object.Map,
    event: wire.protocol.wayland.Display.Event.Message,
) (error{WaylandFatal})!void {
    switch (event) {
        .@"error" => |@"error"| {
            const msg = @"error".message.toSlice();
            const interface: ?wire.protocol.Interface =
                if (object_map.getObject(@"error".object_id.id)) |obj| obj.toInterface()
                else null;
            if (interface) |iface| {
                switch (iface) {
                    inline else => |ifc| {
                        const Obj = ifc.GetObject();
                        const Error: ?type = get_err_type: {
                            if (@hasDecl(Obj, "Error") and @typeInfo(Obj.Error) == .@"enum") {
                                break :get_err_type Obj.Error;
                            } else if (@hasDecl(Obj, "Error") and @hasDecl(Obj.Error, "Code") and @typeInfo(Obj.Error.Code) == .@"enum") {
                                break :get_err_type Obj.Error.Code;
                            } else {
                                break :get_err_type null;
                            }
                        };
                        if (Error) |Err| {
                            switch (@as(Err, @enumFromInt(@"error".code))) {
                                _ => log.err("{t} fatal (unsupported error code): {s}", .{ iface, msg }),
                                else => |err| log.err("{t} fatal .{t}: {s}", .{ iface, err, msg }),
                            }
                        } else {
                            log.err("{t} fatal: (missing error enum) {s}", .{ iface, msg });
                        }
                    },
                }
            } else {
                log.err("unmapped object {d} fatal: {s}", .{ @"error".object_id.id, msg });
            }
            return error.WaylandFatal;
        },
        .delete_id => |delete_id| {
            if (object_map.unbindId(delete_id.id)) |deleted_object| {
                log.info("delete_id on object.{t}", .{deleted_object});
            } else {
                log.err("delete_id on object_id {d} (unmapped)", .{delete_id.id});
            }
        },
    }
}

fn dispatchRegistryEvent(
    proxy: *RegistryProxy,
    event: wire.protocol.wayland.Registry.Event.Message,
    need_all_globals: bool,
) (error{LostGlobal} || RegistryProxy.Error)!void {
    switch (event) {
        .global => |global| proxy.put(global) catch |err| switch (err) {
            error.UnsupportedInterface => log.debug("unrecognized global interface \"{s}\"", .{global.interface.toSlice()}),
            else => |e| return e,
        },
        .global_remove => |remove| {
            if (try proxy.putRemove(remove)) |removed_global| {
                if (need_all_globals) {
                    log.err("wl_display::global_remove {t} ({d})", .{ removed_global, remove.name });
                } else {
                    log.info("wl_display::global_remove {t} ({d})", .{ removed_global, remove.name });
                }
            } else {
                log.err("unmapped wl_display::global_remove on name {d}", .{remove.name});
            }
            if (need_all_globals) return error.LostGlobal;
        },
    }
}

const ConfigureState = struct {
    size: ?[2]i32,

    pub const empty: ConfigureState = .{
        .size = null,
    };

    pub fn isComplete(state: ConfigureState) bool {
        if (state.size == null) return false;
        return true;
    }
};

const Object = enum {
    display,
    registry,
    init_sync,
    compositor,
    xdg_wm_base,
    surface,
    xdg_surface,
    xdg_toplevel,
    shm,
    shm_pool,
    buffer_1,
    buffer_2,

    pub fn toInterface(object: Object) wire.protocol.Interface {
        return switch (object) {
            .display => .wl_display,
            .registry => .wl_registry,
            .init_sync => .wl_callback,
            .compositor => .wl_compositor,
            .xdg_wm_base => .xdg_wm_base,
            .surface => .wl_surface,
            .xdg_surface => .xdg_surface,
            .xdg_toplevel => .xdg_toplevel,
            .shm => .wl_shm,
            .shm_pool => .wl_shm_pool,
            .buffer_1, .buffer_2 => .wl_buffer,
        };
    }

    pub const Map = spark.wayland.IdArray(Object);
};

const allocObjectId = spark.wayland.allocObjectIdMonotonic;

const RegistryProxy = spark.wayland.RegistryProxy(RegistryGlobal);
const RegistryGlobal = Subset(wire.protocol.Interface, &.{
    .wl_compositor,
    .wl_shm,
    .xdg_wm_base,
});
fn Subset(comptime E: type, comptime subset: []const E) type {
    const info = @typeInfo(E).@"enum";
    var names: [subset.len][]const u8 = undefined;
    var values: [subset.len]info.tag_type = undefined;
    for (subset, &names, &values) |tag, *name, *value| {
        name.* = @tagName(tag);
        value.* = @intFromEnum(tag);
    }
    return @Enum(info.tag_type, .exhaustive, &names, &values);
}

fn interfaceFromRegistryGlobal(global: RegistryGlobal) wire.protocol.Interface {
    return @enumFromInt(@intFromEnum(global));
}

const Display = struct {
    stream: ipc.DomainStream,
    transfer_queue: ipc.TransferQueue,

    pub const SendError = error{ AncillaryOverflow } || ipc.DomainStream.SendError;
    pub const ReceiveError = error{ EndOfStream } || ipc.DomainStream.ReceiveError;

    /// Asserts the stream was not opened in nonblocking mode.
    pub fn drain(display: *Display) SendError!void {
        const before_buffered_size = display.transfer_queue.send.len();
        display.stream.drainQueue(&display.transfer_queue, .{}) catch |err| switch (err) {
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
        log.debug("sent {d}B", .{ before_buffered_size - display.transfer_queue.send.len() });
    }

    /// Asserts the stream was not opened in nonblocking mode.
    pub fn flush(display: *Display) SendError!void {
        while (display.transfer_queue.send.len() != 0) try display.drain();
    }

    /// Adds the message to the queue, draining to make room if necessary.
    ///
    /// Asserts the stream was not opened in nonblocking mode.
    pub fn pushRequest(
        display: *Display,
        comptime interface: wire.protocol.Interface,
        object: interface.GetObject(),
        message: interface.GetObject().Request.Message,
    ) (error{SendBufferOverflow} || SendError)!void {
        const message_size = @sizeOf(wire.Header) + switch (message) {
            inline else => |args| wire.payloadSize(args),
        };
        log.debug("push request: {t}.{t} ({d}B)", .{ interface, std.meta.activeTag(message), message_size });
        if (message_size > display.transfer_queue.send.capacity) return error.SendBufferOverflow;
        while (display.transfer_queue.send.space() < message_size) try display.drain();
        switch (message) {
            inline else => |args| {
                if (comptime wire.expectedAncillaryCount(@TypeOf(args)) > 0) {
                    const fds = wire.argsFds(args);
                    // TODO confirm: is error because fd buffer size should be the max possible in one batch
                    display.transfer_queue.fd_send.appendFds(&fds) catch return error.AncillaryOverflow;
                }
            },
        }
        var writer: Io.Writer = .fixed(display.transfer_queue.sendDataWritable()[0..message_size]);
        wire.writeRequestAll(&writer, interface, object, message) catch |err| switch (err) {
            error.WriteFailed => unreachable,
        };
        if (writer.unusedCapacityLen() != 0) unreachable;
        display.transfer_queue.sendDataPublish(message_size);
    }

    // TODO need error for if the display is trying to send us a message
    // that there is not enough room in the receive buffer to fit the entirety of

    /// Asserts the stream was not opened in nonblocking mode.
    pub fn fill(display: *Display) ReceiveError!void {
        display.stream.fillQueue(&display.transfer_queue, .{}) catch |err| switch (err) {
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
    }

    /// Return the header and raw payload of the next complete message,
    /// blocking until the peer sends more data if there is not yet enough.
    ///
    /// If the peer is sending according to protocol,
    /// positionally-corresponding fds part of the parsed message
    /// will be in the receive queue when this returns.
    ///
    /// Asserts the stream was not opened in nonblocking mode.
    pub fn peekNextEventRaw(display: *Display) ReceiveError!struct{ wire.Header, []const u8 } {
        var received: ?struct { wire.Header, []const u8 } = display.peekNextEventBufferedRaw();
        while (received == null) {
            // We don't check for new data on `EndOfStream` because this only occurs when 0 bytes were read
            try display.fill();
            received = display.peekNextEventBufferedRaw();
        }
        return received.?;
    }

    /// Return the header and raw payload of the next complete buffered message
    /// (available without streaming more data).
    ///
    /// If the peer is sending according to protocol,
    /// positionally-corresponding fds part of the parsed message
    /// will be in the receive queue when this returns.
    pub fn peekNextEventBufferedRaw(display: *Display) ?struct { wire.Header, []const u8 } {
        // TODO kind of failing to annotate alignment info here,
        // we should be able to guarantee 4 (8?) alignment of this readable slice
        var reader: Io.Reader = .fixed(display.transfer_queue.receivedDataPeek());
        const header = reader.takeStruct(wire.Header, wire.endian) catch return null;
        const message_size = header.info.size;
        const payload_size = message_size - comptime @as(@TypeOf(message_size), @intCast(@sizeOf(wire.Header)));
        const payload = reader.take(payload_size) catch return null;
        return .{ header, payload };
    }

    /// Call this after getting, parsing, *and* using one peeked event
    /// (lifetime of strings and arrays in the message end after tossed by this call),
    /// passing the `size` value from the message header
    /// (which should be equal to `@sizeOf(Header)` plus the payload size).
    ///
    /// Asserts `message_size` bytes are currently buffered.
    pub fn tossBuffered(display: *Display, message_size: usize) void {
        display.transfer_queue.receivedDataToss(message_size);
    }

    // TODO parseEvent needs variant that does not toss the fds per message
    // but allows caller to accumulate fd taken count in a single dispatch
    // and then toss them all after that.
    // might need to modify the transfer_queue functions to add that
    // (read-ahead peeking or something)

    /// Given the `interface` type of the object id specified in `header`,
    /// parse the raw message into the event type for that interface.
    pub fn parseEvent(
        display: *Display,
        comptime interface: wire.protocol.Interface,
        header: wire.Header,
        payload: []const u8,
    ) wire.MessageMalformation!interface.GetObject().Event.Message {
        const event = wire.eventFromPayload(
            interface,
            header.info.operation,
            payload,
            display.transfer_queue.fd_receive,
        ) catch |err| {
            std.log.err("{t} parsing {t} event {d} ({d}B)", .{
                err,
                interface,
                header.info.operation,
                header.info.size,
            });
            return err;
        };
        switch (event) {
            inline else => |args| {
                const fds_count = comptime wire.expectedAncillaryCount(@TypeOf(args));
                if (fds_count > 0) display.transfer_queue.receivedFdsToss(fds_count);
            }
        }
        return event;
    }
};

// TODO document main constraint about ancillary fds in wayland:
// you must `sendmsg` the FDs no later than the last byte of the message they belong to
// (which is already satisfied because the pending FDs are always all sent,
// and the client does not allow you to push FDs onto the send buffer beyond the static max),
// because when a message is demarshaled the marshal just pops an FD off the queue,
// expecting it to be there

// TODO need to handle `wl_registry::global_remove`s for certain applications
// but if just grabbing the compositor and input seat wayland shouldn't ever remove these

const wl = wire.protocol.wayland;
const wire = spark.wayland.wire;
const ipc = spark.ipc;

const system = posix.system;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const log = std.log;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stream = Io.net.Stream;

const spark = @import("spark");
const std = @import("std");
