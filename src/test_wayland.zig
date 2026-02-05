var gpa: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    defer {
        const leaks = gpa.detectLeaks();
        if (leaks > 0) log.warn("{d} memory leaks at exit", .{ leaks });
        gpa.deinitWithoutLeakChecks();
    }
    const allocator = gpa.allocator();

    const socket: posix.socket_t = discover: {
        const display_path = try spark.wayland.discoverDisplayPath(allocator)
            orelse return error.HostDown;
        defer allocator.free(display_path);
        log.info("display path: '{s}'", .{ display_path });
        break :discover try spark.Wire.openLocalSocket(display_path);
    };
    spark.Wire.close(socket);
}

const posix = std.posix;
const debug = std.debug;
const log = std.log;

const spark = @import("spark");
const std = @import("std");
