var global_gpa: std.heap.DebugAllocator(.{}) = .init;
var read_buffer: [4096]u8 = undefined;
var write_buffer: [4096]u8 = undefined;
var read_control_buffer: [4096]u8 align(ipc.cmsg.algn) = undefined;
var write_control_buffer: [ipc.DomainStream.ControlBuffer.sizeFromCapacity(posix.system.fd_t, fd_max_count)]u8 align(ipc.cmsg.algn) = undefined;
var read_fd_buffer: [fd_max_count]posix.system.fd_t = undefined;

const fd_max_count = 32;
const ObjectMap = std.hash_map.AutoHashMapUnmanaged(u32, wire.protocol.AnyObject);

pub fn main(init: std.process.Init.Minimal) !void {
    defer {
        const leaks = global_gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        global_gpa.deinitWithoutLeakChecks();
    }
    const allocator = global_gpa.allocator();

    const display: ipc.DomainStream = conn: {
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
    defer ipc.closeFd(display.socket);

    var transfer_queue: ipc.TransferQueue = try .create(.{});
    defer transfer_queue.deinit();

    testDisplayConnection(allocator, display, &transfer_queue) catch |err| switch (err) {
        error.EndOfStream => std.log.info("encountered end of stream", .{}),
        else => |e| return e,
    };


    //const display: ipc.DomainStream = conn: {
    //    const display_path = try spark.wayland.discoverDisplayPath(allocator)
    //        orelse return error.HostDown;
    //    log.debug("trying Wayland display at {s}", .{display_path});
    //    defer allocator.free(display_path);
    //    break :conn try .open(display_path, .{});
    //};
    //defer ipc.closeFd(display.socket);

    //var reader = display.reader(&read_buffer, &read_control_buffer, &read_fd_buffer);
    //var writer = display.writer(&write_buffer, &write_control_buffer);

    //testDisplayConnection(allocator, &writer.interface, &reader.interface) catch |err| switch (err) {
    //    error.ReadFailed => return reader.err.?,
    //    error.WriteFailed => return writer.err.?,
    //    error.EndOfStream => std.log.info("encountered end of stream", .{}),
    //    else => |e| return e,
    //};
}

fn testDisplayConnection(gpa: Allocator, display: ipc.DomainStream, transfer_queue: *ipc.TransferQueue) !void {
    var object_map: ObjectMap = .empty;
    defer object_map.deinit(gpa);
    const init_sync_id = 3;
    const registry_id = 2;
    {
        var writer: Io.Writer = .fixed(transfer_queue.sendDataWritable());

        try object_map.putNoClobber(gpa, registry_id, .{ .wayland = .registry });
        try wire.writeMessage(&writer, wl.Display{ .id = wire.object_id.display }, .{ .get_registry = .{
            .registry = .{ .id = registry_id },
        }});

        try object_map.putNoClobber(gpa, init_sync_id, .{ .wayland = .callback });
        try wire.writeMessage(&writer, wl.Display{ .id = wire.object_id.display }, .{ .sync = .{
            .callback = .{ .id = init_sync_id },
        }});

        transfer_queue.sendDataPublish(writer.buffered().len);
    }
    while (transfer_queue.send.len() > 0) try display.flushQueue(transfer_queue, .{});

    var registry_compositor_name: ?u32 = null;
    var registry_compositor_version: ?u32 = null;
    var registry_shm_name: ?u32 = null;
    var registry_shm_version: ?u32 = null;

    init_reg_emit: while (true) {
        log.info("trying next message...", .{});
        while (
            transfer_queue.receivedDataPeek().len < @sizeOf(wire.Header)
            or transfer_queue.receivedDataPeek().len < std.mem.bytesToValue(wire.Header, transfer_queue.receivedDataPeek()[0..@sizeOf(wire.Header)]).info.size
        ) {
            try display.fillQueue(transfer_queue, .{});
        }
        const header = std.mem.bytesToValue(wire.Header, transfer_queue.receivedDataPeek()[0..@sizeOf(wire.Header)]);
        if (header.info.size % 4 != 0) unreachable; // TODO not acceptable as UB (need to always check)
        const payload_size = header.info.size - @sizeOf(wire.Header);
        const payload: []const u8 = transfer_queue.receivedDataPeek()[@sizeOf(wire.Header)..][0..payload_size];
        const obj: wire.protocol.AnyObject =
            if (header.object == wire.object_id.display) .{ .wayland = .display }
            else object_map.get(header.object).?;
        switch (obj) {
            inline else => |o, protocol| { switch (o) { inline else => |object| {
                const Obj = object.ToInterface();
                if (@hasDecl(Obj, "Event")) {
                    const message = try wire.messageFromPayload(
                        Obj.Event.Message,
                        header.info.operation,
                        payload,
                        &.{},
                    );
                    switch (message) {
                        inline else => |event| log.info("got {t}.{t}.{t}: {f}", .{
                            protocol,
                            o,
                            std.meta.activeTag(message),
                            wire.formatAlt(event),
                        }),
                    }
                    if (Obj == wl.Registry and message == .global) {
                        const interface_name = message.global.interface.toSlice();
                        if (wire.mapInterfaceName(interface_name)) |iface| {
                            log.info("mapped \"{s}\"", .{interface_name});
                            if (std.meta.eql(iface, .{ .wayland = .compositor })) {
                                if (registry_compositor_name != null) unreachable;
                                if (registry_compositor_version != null) unreachable;
                                registry_compositor_name = message.global.name;
                                registry_compositor_version = message.global.version;
                            } else if (std.meta.eql(iface, .{ .wayland = .shm })) {
                                if (registry_shm_name != null) unreachable;
                                if (registry_shm_version != null) unreachable;
                                registry_shm_name = message.global.name;
                                registry_shm_version = message.global.version;
                            }
                        } else {
                            log.warn("unrecognized interface name \"{s}\"", .{interface_name});
                        }
                    }
                    if (Obj == wl.Callback and message == .done) {
                        //if (!object_map.remove(header.object)) unreachable;
                        if (header.object == init_sync_id) {
                            log.info("received end of registry global emit (id {d})", .{init_sync_id});
                            break :init_reg_emit;
                        }
                    }
                } else {
                    unreachable;
                }
            }}},
        }
        transfer_queue.receivedDataToss(header.info.size);
    }

    const registry_compositor_name_final: u32 = registry_compositor_name orelse return error.MissingWaylandGlobals;
    const registry_compositor_version_final: u32 = registry_compositor_version orelse return error.MissingWaylandGlobals;
    const registry_shm_name_final: u32 = registry_shm_name orelse return error.MissingWaylandGlobals;
    const registry_shm_version_final: u32 = registry_shm_version orelse return error.MissingWaylandGlobals;

    _ = registry_compositor_name_final;
    _ = registry_compositor_version_final;
    _ = registry_shm_name_final;
    _ = registry_shm_version_final;

    const compositor_id = 4;
    const shm_id = 5;
    const surface_id = 6;
    {
        var writer: Io.Writer = .fixed(transfer_queue.sendDataWritable());

        try object_map.putNoClobber(gpa, compositor_id, .{ .wayland = .compositor });
        try wire.writeMessage(&writer, wl.Registry{ .id = registry_id }, .{ .bind = .{
            .name = registry_compositor_name.?,
            .id = .{
                .name = .fromSlice("wl_compositor"),
                .version = @min(
                    registry_compositor_version.?,
                    wire.protocol.wayland.Compositor.version,
                ),
                .id = compositor_id,
            },
        }});
        try object_map.putNoClobber(gpa, shm_id, .{ .wayland = .shm });
        try wire.writeMessage(&writer, wl.Registry{ .id = registry_id }, .{ .bind = .{
            .name = registry_shm_name.?,
            .id = .{
                .name = .fromSlice("wl_shm"),
                .version = @min(
                    registry_shm_version.?,
                    wire.protocol.wayland.Shm.version,
                ),
                .id = shm_id,
            },
        }});
        try wire.writeMessage(&writer, wl.Compositor{ .id = compositor_id }, .{ .create_surface = .{
            .id = .{ .id = surface_id },
        }});

        transfer_queue.sendDataPublish(writer.buffered().len);
    }
    while (transfer_queue.send.len() > 0) try display.flushQueue(transfer_queue, .{});

    while (true) {
        log.info("trying next message...", .{});
        while (
            transfer_queue.receivedDataPeek().len < @sizeOf(wire.Header)
            or transfer_queue.receivedDataPeek().len < std.mem.bytesToValue(wire.Header, transfer_queue.receivedDataPeek()[0..@sizeOf(wire.Header)]).info.size
        ) {
            try display.fillQueue(transfer_queue, .{});
        }
        const header = std.mem.bytesToValue(wire.Header, transfer_queue.receivedDataPeek()[0..@sizeOf(wire.Header)]);
        if (header.info.size % 4 != 0) unreachable; // TODO not acceptable as UB (need to always check)
        const payload_size = header.info.size - @sizeOf(wire.Header);
        const payload: []const u8 = transfer_queue.receivedDataPeek()[@sizeOf(wire.Header)..][0..payload_size];
        const obj: wire.protocol.AnyObject =
            if (header.object == wire.object_id.display) .{ .wayland = .display }
            else object_map.get(header.object).?;
        switch (obj) {
            inline else => |o, protocol| { switch (o) { inline else => |object| {
                const Obj = object.ToInterface();
                if (@hasDecl(Obj, "Event")) {
                    const message = try wire.messageFromPayload(
                        Obj.Event.Message,
                        header.info.operation,
                        payload,
                        &.{},
                    );
                    switch (message) {
                        inline else => |event| log.info("got {t}.{t}.{t}: {f}", .{
                            protocol,
                            o,
                            std.meta.activeTag(message),
                            wire.formatAlt(event),
                        }),
                    }
                } else {
                    std.debug.panic("Obj {s} has no events", .{@typeName(Obj)});
                }
            }}},
        }
        transfer_queue.receivedDataToss(header.info.size);
    }

    log.info("exiting", .{});
}

// TODO document main constraint about ancillary fds in wayland:
// you must `sendmsg` the FDs no later than the last byte of the message they belong to
// (which is already satisfied because the pending FDs are always all sent,
// and the client does not allow you to push FDs onto the send buffer beyond the static max),
// because when a message is demarshaled the marshal just pops an FD off the queue,
// expecting it to be there

// TODO need to handle `wl_registry::global_remove`s for certain applications
// but if just grabbing the compositor and input seat wayland shouldn't ever remove these

const native_os = @import("builtin").os.tag;
const native_endian = @import("builtin").target.cpu.arch.endian();

const wl = wire.protocol.wayland;
const wire = spark.wayland.wire;
const Display = wire.protocol.wayland.Display;
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
