var gpa: std.heap.DebugAllocator(.{}) = .init;
var read_buffer: [1024]u8 = undefined;
var write_buffer: [1024]u8 = undefined;

pub fn main() !void {
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    defer {
        const leaks = gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        gpa.deinitWithoutLeakChecks();
    }
    const allocator = gpa.allocator();

    const display: Stream = connect: {
        const display_path = try spark.wayland.discoverDisplayPath(allocator)
            orelse return error.HostDown;
        defer allocator.free(display_path);
        const address: Io.net.UnixAddress = try .init(display_path);
        break :connect try address.connect(io);
    };
    defer display.close(io);

    var reader = display.reader(io, &read_buffer);
    var writer = display.writer(io, &write_buffer);

    try writer.interface.writeStruct(wire.Header{
        .object = 1,
        .msg = .{ .op = 1, .size = 12 },
    }, native_endian);
    try writer.interface.writeInt(u32, 2, native_endian);
    try writer.interface.flush();

    mainloop: while (true) {
        const header = reader.interface.takeStruct(wire.Header, native_endian)
            catch |err| switch (err) {
                error.EndOfStream => break :mainloop,
                else => |e| return e,
            };
        log.info("got {{ object_id: {d}, op: {d}, size: {d} }}", .{
            header.object,
            header.msg.op,
            header.msg.size,
        });
        std.debug.assert(header.msg.size % 4 == 0);
        const payload: []const u8 = reader.interface.take(header.msg.size-@sizeOf(wire.Header))
            catch |err| switch (err) {
                error.EndOfStream => break :mainloop,
                else => |e| return e,
            };
        switch (header.object) {
            wire.object_id.display => {
                switch (try wire.messageFromPayload(Display.Event.Message, header.msg.op, payload, &.{})) {
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
            else => |id| log.warn("object id {d} is unknown, discarding", .{ id }),
        }
        log.info("trying next message...", .{});
    }
    log.info("end of stream", .{});
}

const native_endian = @import("builtin").target.cpu.arch.endian();

const wire = spark.wayland.wire;
const Display = wire.protocol.wayland.Display;

const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const log = std.log;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stream = Io.net.Stream;

const spark = @import("spark");
const std = @import("std");
