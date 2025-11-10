display: *h.Display,
window: *h.Window,

pub fn init(platform: *Platform, options: WindowCreationOptions) InitError!void {
    // TODO display selection, screen selection

    platform.display = lib.XOpenDisplay(null) orelse return error.Failure;

    var attributes = mem.zeroes(h.XSetWindowAttributes);
    attributes.event_mask =
        h.ExposureMask |
        h.KeyPressMask |
        h.KeyReleaseMask |
        h.ButtonPressMask |
        h.ButtonReleaseMask |
        h.PointerMotionMask |
        h.StructureNotifyMask
    ;

    const screen: c_int = h.DefaultScreen(platform.display);
    const root: h.Window = h.RootWindow(platform.display, screen);

    platform.window = lib.XCreateWindow(
        platform.display, root,
        0, 0, options.width, options.height, 0,
        h.CopyFromParent, h.InputOutput,
        @ptrFromInt(h.CopyFromParent),
        h.CWEventMask, &attributes,
    ) orelse return error.Failure;
}

pub const InitError = common.InitError;
pub const WindowCreationOptions = common.WindowCreationOptions;

const lib = if (build_options.x11_linked) struct {
    pub extern fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*h.Display;
    pub extern fn XCreateWindow(
        display: *h.Display,
        parent: h.Window,
        x: c_int,
        y: c_int,
        width: c_uint,
        height: c_uint,
        border_width: c_uint,
        depth: c_int,
        class: c_uint,
        visual: ?*h.Visual,
        valuemask: c_ulong,
        attributes: *h.XSetWindowAttributes,
    ) callconv(.c) ?*h.Window;
} else @compileError("invalid reference to unlinked X11 library");

const h = if (build_options.x11_linked) @import("x11")
    else @compileError("invalid reference to unlinked X11 headers");

const Platform = @This();
const common = @import("common.zig");
const mem = std.mem;
const build_options = @import("build_options");
const std = @import("std");
