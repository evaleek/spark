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

// TODO a higher level display connection state encapsulation like this
// should just internally handle, and not emit, any events
// that have completely internal side effects like configure, ping, global updates etc,
// and just pass a higher-level event type up to the user

fn testDisplayConnection(display: *Display) !void {
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

    try display.hello();
    try display.addRoundtrip();
    try display.flush();

    {
        var done: bool = false;
        while (!done) {
            const object, const event, const msg_size = try display.peekNextEvent();
            switch (object) {
                .sync => switch (event.wl_callback) {
                    .done => |d| {
                        if (done == false) {
                            log.info("finished init roundtrip (0x{x})", .{d.callback_data});
                            done = true;
                        } else {
                            unreachable;
                        }
                    },
                },
                inline .display, .registry => |o| {
                    const interface = comptime o.toInterface();
                    try display.dispatchDefault(interface, @field(event, @tagName(interface)));
                },
                else => unreachable,
            }
            display.tossBuffered(msg_size);
        }
    }

    try display.bindGlobal(.compositor);
    try display.bindGlobal(.xdg_wm_base);
    try display.addRequest(.compositor, .{ .create_surface = .{
        .id = try display.mapObject(.surface),
    }});
    try display.addRequest(.xdg_wm_base, .{ .get_xdg_surface = .{
        .id = try display.mapObject(.xdg_surface),
        .surface = try display.getObject(.surface),
    }});
    try display.addRequest(.xdg_surface, .{ .get_toplevel = .{
        .id = try display.mapObject(.xdg_toplevel),
    }});
    try display.addRequest(.surface, .{ .commit = .{} });
    try display.flush();

    var buf_window_configuration: WindowConfiguration = .new;
    var last_window_configuration: WindowConfiguration = undefined;

    {
        var got_configure: bool = false;
        while (!got_configure) {
            const object, const event, const msg_size = try display.peekNextEvent();
            if (object == .xdg_toplevel) {
                buf_window_configuration.addEvent(event);
            }
            switch (object) {
                inline .display, .registry, .xdg_wm_base => |o| {
                    const interface = comptime o.toInterface();
                    try display.dispatchDefault(interface, @field(event, @tagName(interface)));
                },
                .surface => switch (event.wl_surface) {
                    inline else => |msg, e| log.info("wl_surface.{t}: {f}", .{ e, wire.formatAlt(msg) }),
                },
                .xdg_toplevel => switch (event.xdg_toplevel) {
                    inline else => |msg, e| log.info("xdg_toplevel.{t}: {f}", .{ e, wire.formatAlt(msg) }),
                },
                .xdg_surface => switch (event.xdg_surface) {
                    .configure => |configure| {
                        last_window_configuration = buf_window_configuration;
                        try display.addRequest(.xdg_surface, .{ .ack_configure = .{
                            .serial = configure.serial,
                        }});
                        if (got_configure == false) {
                            log.info("got initial xdg_surface.configure (0x{x})", .{configure.serial});
                            got_configure = true;
                        } else {
                            unreachable;
                        }
                    },
                },
                else => unreachable,
            }
            display.tossBuffered(msg_size);
        }
    }
    // Flush because we just got the init configure and added the ack
    try display.flush();

    try display.bindGlobal(.shm);
    try display.addRequest(.shm, .{ .create_pool = .{
        .id = try display.mapObject(.shm_pool),
        .fd = .{ .descriptor = shm_file.fd },
        .size = @intCast(shm_size),
    }});
    // Wayland compositors are required to support `.argb8888` and `.xrgb8888`,
    // so we pick the format without checking for support first
    // and let the display send the fatal error if it's missing.
    try display.addRequest(.shm_pool, .{ .create_buffer = .{
        .id = try display.mapObject(.buffer_1),
        .offset = 0,
        .width = surface_width,
        .height = surface_height,
        .stride = surface_buffer_stride,
        .format = surface_buffer_format,
    }});
    //try display.addRequest(.shm_pool, .{ .create_buffer = .{
    //    .id = try display.mapObject(.buffer_2),
    //    .offset = surface_buffer_size,
    //    .width = surface_width,
    //    .height = surface_height,
    //    .stride = surface_buffer_stride,
    //    .format = surface_buffer_format,
    //}});
    try display.addRequest(.surface, .{ .attach = .{
        .buffer = try display.getObject(.buffer_1),
        .x = 0,
        .y = 0,
    }});
    try display.addRequest(.surface, .{ .damage_buffer = .{
        .x = 0,
        .y = 0,
        .width = std.math.maxInt(i32),
        .height = std.math.maxInt(i32),
    }});
    try display.addRequest(.surface, .{ .commit = .{} });
    try display.flush();

    _ = surface_buffers;

    var need_flush: bool = false;

    while (true) {
        const object, const event, const msg_size = try display.peekNextEvent();
        if (object == .xdg_toplevel) {
            buf_window_configuration.addEvent(event);
        }
        switch (object) {
            inline .display, .registry, .xdg_wm_base => |o| {
                const interface = comptime o.toInterface();
                try display.dispatchDefault(interface, @field(event, @tagName(interface)));
            },
            .surface => switch (event.wl_surface) {
                inline else => |msg, e| log.info("wl_surface.{t}: {f}", .{ e, wire.formatAlt(msg) }),
            },
            .xdg_toplevel => switch (event.xdg_toplevel) {
                inline else => |msg, e| log.info("xdg_toplevel.{t}: {f}", .{ e, wire.formatAlt(msg) }),
            },
            .xdg_surface => switch (event.xdg_surface) {
                .configure => |configure| {
                    last_window_configuration = buf_window_configuration;
                    try display.addRequest(.xdg_surface, .{ .ack_configure = .{
                        .serial = configure.serial,
                    }});
                    need_flush = true;
                },
            },
            .shm => switch (event.wl_shm) {
                //.format => |format| log.debug("wl_shm offers format: {t}", .{format.format}),
                .format => {},
            },
            .buffer_1 => switch (event.wl_buffer) {
                .release => {}, // TODO
            },
            else => unreachable,
        }
        display.tossBuffered(msg_size);

        if (need_flush) {
            try display.flush();
            need_flush = false;
        }
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

const WindowConfiguration = struct {
    pub const new: WindowConfiguration = .{};

    pub fn addEvent(conf: *WindowConfiguration, event: wayland.AnyEvent) void {
        // TODO
        _ = &conf;
        _ = event;
    }
};

const Object = enum {
    display,
    registry,
    sync,
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
            .sync => .wl_callback,
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

fn registryGlobalFromInterface(interface: wire.protocol.Interface) ?RegistryGlobal {
    return std.enums.fromInt(RegistryGlobal, @intFromEnum(interface));
}

const Display = struct {
    stream: ipc.DomainStream,
    transfer_queue: ipc.TransferQueue,

    next_id_counter: u32,
    object_map: Object.Map,
    registry_proxy: RegistryProxy,

    pub const SendError = error{ AncillaryOverflow } || ipc.DomainStream.SendError;
    pub const ReceiveError = error{ EndOfStream } || ipc.DomainStream.ReceiveError;
    pub const RequestError = error{
        /// The object passed as the request interface has no bound object id
        ObjectUnmapped,
    } || SendError;
    pub const BindObjectError = error{
        OutOfObjectIds,
        ObjectAlreadyMapped,
    };
    pub const BindError = BindObjectError || RequestError;
    pub const EventError = error{
        /// The received id mapped to no known object
        IdUnmapped,
        InvalidMessageSize,
    } || wire.MessageMalformation || ReceiveError;

    /// Push the initial connection request (`wl_display::get_registry`)
    /// and initialize object id state.
    pub fn hello(display: *Display) (error{OutOfObjectIds} || SendError)!void {
        display.next_id_counter = 2;
        display.object_map = .empty;
        display.registry_proxy = .empty;

        display.object_map.bind(.display, wire.object_id.display);
        const registry: wire.protocol.wayland.Registry.New = .{ .id = try allocObjectId(&display.next_id_counter) };
        try display.writeRequest(
            .wl_display,
            .{ .id = wire.object_id.display },
            .{ .get_registry = .{ .registry = registry } },
        );
        display.object_map.bind(.registry, registry.id);
    }

    pub fn addRoundtrip(display: *Display) BindError!void {
        if (display.object_map.getId(.sync)) |id| {
            log.err("failed to bind global {t}: already bound to id {d}", .{ .sync, id });
            return error.ObjectAlreadyMapped;
        }
        const sync_id = try allocObjectId(&display.next_id_counter);
        try display.addRequest(.display, .{ .sync = .{ .callback = .{ .id = sync_id } } });
        display.object_map.bind(.sync, sync_id);
    }

    pub fn addRequest(
        display: *Display,
        comptime object: Object,
        request: object.toInterface().GetObject().Request.Message,
    ) RequestError!void {
        if (display.object_map.getId(object)) |object_id| {
            try display.writeRequest(object.toInterface(), .{ .id = object_id }, request);
        } else {
            log.err("failed to construct request: object {t} is unmapped", .{object});
            return error.ObjectUnmapped;
        }
    }

    // TODO ideally this would be coupled with the request that actually adds the message that binds the Object.New,
    // so that it being internally mapped to the alloced id can only have the side effects on success
    pub fn mapObject(display: *Display, comptime object: Object) BindObjectError!object.toInterface().GetObject().New {
        if (display.object_map.getId(object)) |id| {
            log.err("failed to bind object {t}: already bound to id {d}", .{ object, id });
            return error.ObjectAlreadyMapped;
        }
        const new_id = try allocObjectId(&display.next_id_counter);
        display.object_map.bind(object, new_id);
        return .{ .id = new_id };
    }

    pub fn getObject(display: *const Display, comptime object: Object) (error{ObjectUnmapped})!object.toInterface().GetObject() {
        if (display.object_map.getId(object)) |id| {
            return .{ .id = id };
        } else {
            log.err("failed to get object {t}: not bound", .{ object });
            return error.ObjectUnmapped;
        }
    }

    pub fn bindGlobal(display: *Display, comptime object: Object) (error{GlobalUnnamed} || BindError)!void {
        const interface: wire.protocol.Interface = comptime object.toInterface();
        const global: RegistryGlobal = comptime registryGlobalFromInterface(interface)
            orelse @compileError(std.fmt.comptimePrint(
                "object .{t} (.{t}) has no enumerated global",
                .{ object, interface },
            ));
        if (display.object_map.getId(object)) |id| {
            log.err("failed to bind global {t}: already bound to id {d}", .{ global, id });
            return error.ObjectAlreadyMapped;
        }
        if (display.registry_proxy.get(global)) |entry| {
            const new_id = try allocObjectId(&display.next_id_counter);
            // TODO errdefer dealloc object id
            const interface_version: @TypeOf(entry.version) = interface.GetObject().version;
            const compat_version = @min(interface_version, entry.version);
            if (compat_version != interface_version) {
                log.info("have {t} version {d}, while display has version {d}", .{
                    interface,
                    interface_version,
                    entry.version,
                });
            }
            try display.addRequest(.registry, .{ .bind = .{
                .name = entry.name,
                .id = .{
                    .name = .fromSlice(@tagName(interface)),
                    .version = compat_version,
                    .id = new_id,
                },
            }});
            display.object_map.bind(object, new_id);
        } else {
            log.err("failed to bind global {t}: no name in registry", .{global});
            return error.GlobalUnnamed;
        }
    }

    pub fn peekNextEvent(display: *Display) EventError!struct { Object, wayland.AnyEvent, u16 } {
        const header, const payload = try display.peekNextEventRaw();
        if (display.object_map.getObject(header.object)) |object| {
            switch (object.toInterface()) {
                inline else => |interface| {
                    if (comptime @hasDecl(interface.GetObject(), "Event")) {
                        const event = try display.parseEvent(interface, header, payload);
                        return .{
                            object,
                            @unionInit(wayland.AnyEvent, @tagName(interface), event),
                            header.info.size,
                        };
                    } else {
                        // TODO should be impossible
                        return .{
                            object,
                            @unionInit(wayland.AnyEvent, @tagName(interface), {}),
                            header.info.size,
                        };
                    }
                },
            }
        } else {
            log.err("message {{ object: {d}, op: {d} }} ({d}B) maps to no known object", .{
                header.object,
                header.info.operation,
                header.info.size,
            });
            return error.IdUnmapped;
        }
    }

    // TODO define error well
    pub fn dispatchDefault(
        display: *Display,
        comptime interface: wire.protocol.Interface,
        event: interface.GetObject().Event.Message,
    ) !void {
        switch (interface) {
            .wl_display => try dispatchDisplayEvent(&display.object_map, event),
            .wl_registry => try dispatchRegistryEvent(&display.registry_proxy, event, true),
            .xdg_wm_base => switch (event) {
                // TODO immediately blocking for flush unbatched is not correct
                // but still need to integrate dispatching with overall event loop structure
                .ping => |ping| {
                    try display.addRequest(.xdg_wm_base, .{ .pong = .{
                        .serial = ping.serial,
                    }});
                    try display.flush();
                },
            },
            else => |iface| @compileError("no default behavior defined for " ++ @tagName(iface)),
        }
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
    pub fn writeRequest(
        display: *Display,
        comptime interface: wire.protocol.Interface,
        object: interface.GetObject(),
        message: interface.GetObject().Request.Message,
    ) SendError!void {
        const message_size = @sizeOf(wire.Header) + switch (message) {
            inline else => |args| wire.payloadSize(args),
        };
        log.debug("push request: {t}.{t} ({d}B)", .{ interface, std.meta.activeTag(message), message_size });
        // TODO this is not an error, message just has to be sent in multiple sends
        if (message_size > display.transfer_queue.send.capacity) unreachable;
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
};

// TODO document main constraint about ancillary fds in wayland:
// you must `sendmsg` the FDs no later than the last byte of the message they belong to
// (which is already satisfied because the pending FDs are always all sent,
// and the client does not allow you to push FDs onto the send buffer beyond the static max),
// because when a message is demarshaled the marshal just pops an FD off the queue,
// expecting it to be there

// TODO need to handle `wl_registry::global_remove`s for certain applications
// but if just grabbing the compositor and input seat wayland shouldn't ever remove these

const wayland = spark.wayland;
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
