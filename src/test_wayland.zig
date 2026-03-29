var gpa: std.heap.DebugAllocator(.{}) = .init;
var read_buffer: [4096]u8 = undefined;
var write_buffer: [4096]u8 = undefined;
var read_control_buffer: [4096]u8 align(ipc.cmsg.algn) = undefined;
var write_control_buffer: [ipc.DomainStream.ControlBuffer.sizeFromCapacity(posix.system.fd_t, fd_max_count)]u8 align(ipc.cmsg.algn) = undefined;
var read_fd_buffer: [fd_max_count]posix.system.fd_t = undefined;

const fd_max_count = 32;

pub fn main() !void {
    //var threaded: Io.Threaded = .init_single_threaded;
    //defer threaded.deinit();
    //const io = threaded.io();

    defer {
        const leaks = gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        gpa.deinitWithoutLeakChecks();
    }
    const allocator = gpa.allocator();

    const display: ipc.DomainStream = conn: {
        const display_path = try spark.wayland.discoverDisplayPath(allocator)
            orelse return error.HostDown;
        defer allocator.free(display_path);
        break :conn try .open(display_path, .{});
    };
    defer ipc.closeFd(display.socket);

    var reader = display.reader(&read_buffer, &read_control_buffer, &read_fd_buffer);
    var writer = display.writer(&write_buffer, &write_control_buffer);

    testDisplayConnection(&writer.interface, &reader.interface) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return writer.err.?,
        error.EndOfStream => std.log.info("encountered end of stream", .{}),
        else => |e| return e,
    };
}

fn testDisplayConnection(writer: *Io.Writer, reader: *Io.Reader) !void {
    try writer.writeStruct(wire.Header{
        .object = 1,
        .info = .{ .operation = 1, .size = 12 },
    }, native_endian);
    try writer.writeInt(u32, 2, native_endian);
    try writer.flush();

    while (true) {
        const header = try reader.takeStruct(wire.Header, native_endian);
        debug.assert(header.info.size % 4 == 0);
        const payload_size = header.info.size - @sizeOf(wire.Header);
        const payload: []const u8 = try reader.peek(payload_size);
        log.info("got {{ object_id: {d}, op: {d}, size: {d} }}", .{
            header.object,
            header.info.operation,
            header.info.size,
        });
        switch (header.object) {
            wire.object_id.display => {
                switch (try wire.messageFromPayload(Display.Event.Message, header.info.operation, payload, &.{})) {
                    .@"error" => |@"error"| {
                        const code = std.enums.fromInt(Display.Error.Code, @"error".code);
                        if (code) |err| {
                            debug.print("error '{t}' on object {d}: {s}\n", .{ err, header.object, @"error".message.toSlice() });
                        } else {
                            debug.print("error [{d}] on object {d}: {s}\n", .{ @"error".code, header.object, @"error".message.toSlice() });
                        }
                    },
                    else => {},
                }
            },
            else => |id| log.warn("object id {d} is unknown, discarding", .{id}),
        }
        reader.toss(payload_size);
        log.info("trying next message...", .{});
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
