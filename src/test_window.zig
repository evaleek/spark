//! This module initializes and runs a Spark window for the target system.

pub fn main() !void {
    var client: Client = undefined;
    try client.connect(.{});

    var window: Window = try client.openWindow(.{ .name = "Spark test window" });
    try client.showWindow(window);

    log.info("opened {d}x{d} window at ({d}, {d})", .{
        window.width, window.height,
        window.x, window.y,
    });

    main: while (true) {
        const win: ?*Window,
        const event: Event = client.wait(&.{ &window });

        if (win) |_| {
            log.debug("received {t} event", .{ event });
            switch (event) {
                .close => break :main,

                .redraw => |redraw| {
                    log.debug(
                        "redraw rect at ({d}, {d}), ({d}, {d})",
                        .{
                            redraw.x, redraw.y,
                            redraw.x + @as(i32, @intCast(redraw.width)),
                            redraw.y + @as(i32, @intCast(redraw.height)),
                        },
                    );
                },

                .resize => |resize| {
                    log.debug(
                        "resize to {d}x{d} at ({d}, {d})",
                        .{ resize.width, resize.height, resize.x, resize.y },
                    );

                    if (window.width != resize.width or window.height != resize.height or
                        window.x != resize.x or window.y != resize.y
                    ) log.err("window failed to update resize info before poll exit", .{});
                },

                .reposition => |reposition| {
                    log.debug(
                        "reposition to ({d}, {d})",
                        .{ reposition.x, reposition.y },
                    );

                    if (window.x != reposition.x or window.y != reposition.y)
                        log.err("window failed to update reposition info before poll exit", .{});
                },
            }
        } else {
            log.err("missing window of {t} event", .{ event });
        }
    }

    try client.closeWindow(&window);
    try client.disconnect();
}

// TODO smarter selection
const Client = switch (@import("builtin").target.os.tag) {
    .linux, .freebsd, .netbsd, .openbsd, .illumos => spark.X11.Linked,
    .windows => spark.Win32.Linked,
    else => |t| @compileError(std.fmt.comptimePrint("unsupported target platform: {t}", .{t})),
};
const Window = Client.Window;
const Event = Client.Event;

const log = std.log;

const spark = @import("spark");
const std = @import("std");
