pub const ConnectionError = error{
    OutOfMemory,
    HostDown,
    ConnectionFailed,
};

pub const WindowCreationOptions = struct {
    name: [:0]const u8,
    width: u16,
    height: u16,
};

pub const WindowCreationError = error{
    OutOfMemory,
};

pub const DisplayInfo = struct {
    active: bool,
    name: []const u8,
    size: ?DisplaySize,
};

pub const DisplaySize = struct {
    width_pixels: u16,
    height_pixels: u16,
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

const std = @import("std");
