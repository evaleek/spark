pub const X11 = @import("X11.zig");

test "asdf" {
    var x11: X11 = undefined;
    try x11.init(.{ .width = 800, .height = 400 });
}
