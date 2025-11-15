//! This module provides a uniform cross-backend client windowing abstraction.

pub const X11 = struct {
    pub const Linked = @import("X11/Linked.zig");
};

pub const Win32 = struct {
    pub const Linked = @import("Win32/Linked.zig");
};

test "open and close window" {
    inline for ([_][:0]const u8{
        "X11",
        "Win32"
    }) |name| {
        const lowercase: [name.len :0]u8 = comptime to_lower: {
            var buffer: [name.len :0]u8 = undefined;
            for (&buffer, name) |*b, n| b.* = ascii.toLower(n);
            break :to_lower buffer;
        };
        if (comptime @field(build_options, lowercase ++ "_linked")) {
            const Client = @field(@This(), name).Linked;

            var client: Client = undefined;
            client.connect(.{}) catch |err| switch (err) {
                error.HostDown => return error.SkipZigTest,
                else => return err,
            };
            defer client.disconnect();

            var window = try client.openWindow(.{ .name = "Spark test window" });
            defer client.closeWindow(&window);

            client.showWindow(window);
        }
    }
}

/// Length in screen coordinates
pub const ScreenSize = u32;
/// Position in screen coordinates
pub const ScreenPosition = i32;

// ConnectionOptions varies per-module

pub const ConnectionError = error{
    OutOfMemory,
    HostDown,
    ConnectionFailed,
};

pub const WindowCreationOptions = struct {
    name: [:0]const u8,
    width: ?ScreenSize = null,
    height: ?ScreenSize = null,
    /// Window left edge position relative to the left edge of the display
    origin_x: ?ScreenPosition = null,
    /// Window top edge position relative to the top edge of the display
    origin_y: ?ScreenPosition = null,
    /// If `null`, prefer the primary display
    display: ?DisplaySelection = null,
};

pub const WindowCreationError = error{
    OutOfMemory,
    /// The name exceeded the maximum length or was not valid UTF-8.
    InvalidName,
    /// The display selection was invalid,
    /// or may have been invalidated since display enumeration.
    /// Retrying with a `null` display selection will never return this error.
    InvalidDisplay,
};

pub const DisplayInfo = struct {
    active: bool,
    name: []const u8,
    size: ?DisplaySize,
};

pub const DisplaySize = struct {
    width_pixels: ScreenSize,
    height_pixels: ScreenSize,
    /// The EDID size in millimeters,
    /// which may be missing, incorrect,
    /// or modified by the windowing environment for display scaling.
    width_millimeters: u64,
    /// The EDID size in millimeters,
    /// which may be missing, incorrect,
    /// or modified by the windowing environment for display scaling.
    height_millimeters: u64,

    pub fn xPixelsPerInch(info: DisplayInfo) ?f64 {
        const mm_per_inch = 25.4;
        if (info.width_millimeters > 0 and info.width_pixels > 0) {
            const px: f64 = @floatFromInt(info.width_pixels);
            const mm: f64 = @floatFromInt(info.width_millimeters);
            return px * mm_per_inch / mm;
        } else {
            return null;
        }
    }

    pub fn yPixelsPerInch(info: DisplayInfo) ?f64 {
        const mm_per_inch = 25.4;
        if (info.height_millimeters > 0 and info.height_pixels > 0) {
            const px: f64 = @floatFromInt(info.height_pixels);
            const mm: f64 = @floatFromInt(info.height_millimeters);
            return px * mm_per_inch / mm;
        } else {
            return null;
        }
    }
};

pub const DisplaySelection = union(enum) {
    /// Select the display by name as found from `DisplayInfo`
    name: []const u8,
    /// Select the display by the index it appeared when enumerating `DisplayInfo`s
    index: u16,
};

pub const Message = enum {
    close,
    redraw,
    resize,
    reposition,
};

pub const Event = union(Message) {
    close: Close,
    redraw: Redraw,
    resize: Resize,
    reposition: Reposition,

    pub const Close = void;

    pub const Redraw = struct {
        x: ScreenPosition,
        y: ScreenPosition,
        width: ScreenSize,
        height: ScreenSize,
    };

    pub const Resize = struct {
        x: ScreenPosition,
        y: ScreenPosition,
        width: ScreenSize,
        height: ScreenSize,
    };

    pub const Reposition = struct {
        x: ScreenPosition,
        y: ScreenPosition,
    };
};

pub const fallback_default_window_origin_x = 0;
pub const fallback_default_window_origin_y = 0;
pub const fallback_default_window_width = 800;
pub const fallback_default_window_height = 600;

const testing = std.testing;
const ascii = std.ascii;

const build_options = @import("build_options");
const std = @import("std");
