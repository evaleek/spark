/// Caller always frees the returned slice.
pub fn discoverDisplayPath(allocator: Allocator) (error{MissingXDGRuntimeDir} || Allocator.Error)![:0]const u8 {
    const display: [:0]const u8 = get_display: {
        const env = posix.getenv("WAYLAND_DISPLAY")
            orelse break :get_display fallback_wayland_display_sub_path;
        break :get_display if (env.len > 0) env else fallback_wayland_display_sub_path;
    };
    if (display[0] == path_delimiter) {
        // Allocate so that the user can unconditionally free.
        const path = try allocator.allocSentinel(u8, display.len, 0);
        @memcpy(path, display);
        return path;
    } else {
        // Wayland specifies no fallback path in the case of unset `XDG_RUNTIME_DIR`.
        const dir_path = posix.getenv("XDG_RUNTIME_DIR") orelse return error.MissingXDGRuntimeDir;
        const path = try allocator.allocSentinel(u8, dir_path.len + display.len + 1, 0);
        @memcpy(path[0..dir_path.len], dir_path);
        path[dir_path.len] = path_delimiter;
        @memcpy(path[dir_path.len+1..][0..display.len], display);
        return path;
    }
}

pub const fallback_wayland_display_sub_path = "wayland-0";

pub const path_delimiter = '/';

const Allocator = std.mem.Allocator;

const posix = std.posix;

const std = @import("std");
