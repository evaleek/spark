pub const protocol = @import("wayland_protocol");
pub const Fixed = protocol.Fixed;
pub const String = protocol.String;
pub const Array = protocol.Array;
pub const FD = protocol.FD;

/// Get what should be an already established socket connection to the display.
/// This may be set in cases such as being launched by a parent process
/// which configures a connection for us.
pub fn discoverDisplayPreconnected(env: process.Environ) fmt.ParseIntError!?posix.fd_t {
    if (env.getPosix(socket_env_key)) |env_socket| {
        return try fmt.parseInt(posix.fd_t, env_socket, 10);
    }
    return null;
}

/// Get the full path to the display, if set.
pub fn discoverDisplayPathFull(env: process.Environ) ?[:0]const u8 {
    const display = getEnvNonempty(env, display_env_key) orelse return null;
    return if (fs.path.isSep(display[0])) display else null;
}

/// Resolve the display socket path as configured by the environment.
/// Allocates the path name to be freed by the caller
/// only if the full path to the display is not set
/// (allocates when `discoverDisplayPathFull` returns `null`).
/// Returns `null` if no valid display location is configured.
pub fn discoverDisplayPath(allocator: Allocator, env: process.Environ) Allocator.Error!?[:0]const u8 {
    const display = getEnvNonempty(display_env_key) orelse fallback_display_name;
    if (fs.path.isSep(display[0])) return display;
    const runtime_dir = getEnvNonempty(env, runtime_dir_env_key) orelse return null;
    if (runtime_dir.len == 0) return null;
    const path = try allocator.allocSentinel(u8, runtime_dir.len + display.len + 1, 0);
    @memcpy(path[0..runtime_dir.len], runtime_dir);
    comptime assert(fs.path.isSep('/'));
    path[runtime_dir.len] = '/';
    @memcpy(path[runtime_dir.len+1..][0..display.len], display);
    return path;
}

fn getEnvNonempty(env: process.Environ, key: []const u8) ?[:0]const u8 {
    const get = env.getPosix(key) orelse return null;
    return if (get.len != 0) get else null;
}

pub const fallback_display_name = "wayland-0";
pub const socket_env_key = "WAYLAND_DISPLAY";
pub const display_env_key = "WAYLAND_DISPLAY";
pub const runtime_dir_env_key = "XDG_RUNTIME_DIR";

const assert = debug.assert;
const Allocator = mem.Allocator;

const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const posix = std.posix;
const process = std.process;
const debug = std.debug;

const std = @import("std");
const root = @import("root.zig");
