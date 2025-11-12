pub const X11 = struct {
    pub const Linked = @import("X11/Linked.zig");
};

test "reference decls" {
    _ = X11.Linked;
}
