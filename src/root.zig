pub const X11 = struct {
    pub const Linked = @import("X11/Linked.zig");
};

pub const Win32 = struct {
    pub const Linked = @import("Win32/Linked.zig");
};

test "reference decls" {
    if (build_options.x11_linked) _ = X11.Linked;
    if (build_options.win32_linked) _ = Win32.Linked;
}

const build_options = @import("build_options");
