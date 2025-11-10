pub const ConnectionError = error{
    OutOfMemory,
    HostDown,
    ConnectionFailed,
};

pub const WindowCreationOptions = struct {
    display: ?DisplaySelection = null,
    name: [:0]const u8,
    width: ScreenPoints,
    height: ScreenPoints,
    /// Window left edge position relative to the left edge of the display
    origin_x: ScreenPoints = 0,
    /// Window top edge position relative to the top edge of the display
    origin_y: ScreenPoints = 0,
};

pub const DisplaySelection = union(enum) {
    /// Select the display by name as found from DisplayInfo
    name: []const u8,
    /// Select the display by the index it appeared when enumerating displays
    index: u16,
};

pub const WindowCreationError = error{
    OutOfMemory,
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
    width_pixels: ScreenPoints,
    height_pixels: ScreenPoints,
    /// The EDID size in millimeters,
    /// which may be missing, incorrect,
    /// or modified by the windowing environment for display scaling.
    width_millimeters: u64,
    /// The EDID size in millimeters,
    /// which may be missing, incorrect,
    /// or modified by the windowing environment for display scaling.
    height_millimeters: u64,

    pub const mm_per_inch = 25.4;

    pub fn xPixelsPerInch(info: DisplayInfo) ?f64 {
        if (info.width_millimeters > 0) {
            const px: f64 = @floatFromInt(info.width_pixels);
            const mm: f64 = @floatFromInt(info.width_millimeters);
            return px * mm_per_inch / mm;
        } else {
            return null;
        }
    }

    pub fn yPixelsPerInch(info: DisplayInfo) ?f64 {
        if (info.height_millimeters > 0) {
            const px: f64 = @floatFromInt(info.height_pixels);
            const mm: f64 = @floatFromInt(info.height_millimeters);
            return px * mm_per_inch / mm;
        } else {
            return null;
        }
    }
};

pub const ScreenPoints = u16;

const std = @import("std");
