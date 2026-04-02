var global_gpa: std.heap.DebugAllocator(.{}) = .init;
var read_buffer: [4096]u8 = undefined;
var write_buffer: [4096]u8 = undefined;
var read_control_buffer: [4096]u8 align(ipc.cmsg.algn) = undefined;
var write_control_buffer: [ipc.DomainStream.ControlBuffer.sizeFromCapacity(posix.system.fd_t, fd_max_count)]u8 align(ipc.cmsg.algn) = undefined;
var read_fd_buffer: [fd_max_count]posix.system.fd_t = undefined;

const fd_max_count = 32;

pub fn main() !void {
    defer {
        const leaks = global_gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        global_gpa.deinitWithoutLeakChecks();
    }
    const allocator = global_gpa.allocator();

    const display: ipc.DomainStream = conn: {
        const display_path = try spark.wayland.discoverDisplayPath(allocator)
            orelse return error.HostDown;
        log.debug("trying Wayland display at {s}", .{display_path});
        defer allocator.free(display_path);
        break :conn try .open(display_path, .{});
    };
    defer ipc.closeFd(display.socket);

    var reader = display.reader(&read_buffer, &read_control_buffer, &read_fd_buffer);
    var writer = display.writer(&write_buffer, &write_control_buffer);

    testDisplayConnection(allocator, &writer.interface, &reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return writer.err.?,
        error.EndOfStream => std.log.info("encountered end of stream", .{}),
        else => |e| return e,
    };
}

const ObjectMap = std.hash_map.AutoHashMapUnmanaged(u32, wire.protocol.AnyObject);

fn testDisplayConnection(gpa: Allocator, writer: *Io.Writer, reader: *Io.Reader) !void {
    var object_map: ObjectMap = .empty;
    {
        const registry_id = 2;
        try object_map.putNoClobber(gpa, registry_id, .{ .wayland = .registry });
        try wire.writeMessage(writer, wl.Display{ .id = wire.object_id.display }, .{ .get_registry = .{
            .registry = .{ .id = registry_id },
        }});
    }
    try writer.flush();

    while (true) {
        log.info("trying next message...", .{});
        const header = try reader.takeStruct(wire.Header, native_endian);
        debug.assert(header.info.size % 4 == 0);
        const payload_size = header.info.size - @sizeOf(wire.Header);
        const payload: []const u8 = try reader.peek(payload_size);
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
                        if (wire.mapInterfaceName(interface_name)) |_| {
                            log.info("mapped \"{s}\"", .{interface_name});
                        } else {
                            log.warn("unrecognized interface name \"{s}\"", .{interface_name});
                        }
                    }
                } else {
                    unreachable;
                }
            }}},
        }
        reader.toss(payload_size);
    }
}


// TODO document main constraint about ancillary fds in wayland:
// you must `sendmsg` the FDs no later than the last byte of the message they belong to
// (which is already satisfied because the pending FDs are always all sent,
// and the client does not allow you to push FDs onto the send buffer beyond the static max),
// because when a message is demarshaled the marshal just pops an FD off the queue,
// expecting it to be there

const native_os = @import("builtin").os.tag;
const native_endian = @import("builtin").target.cpu.arch.endian();

const wl = wire.protocol.wayland;
const wire = spark.wayland.wire;
const Display = wire.protocol.wayland.Display;
const ipc = spark.ipc;

const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const log = std.log;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stream = Io.net.Stream;

const spark = @import("spark");
const std = @import("std");
