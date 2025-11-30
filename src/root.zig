//! This module provides a uniform cross-backend client windowing abstraction.

pub const X11 = struct {
    pub const Linked = @import("X11/Linked.zig");
};


pub const Win32 = struct {
    pub const Linked = @import("Win32/Linked.zig");
};

/// Length in screen coordinates
pub const ScreenSize = u32;
/// Position in screen coordinates
pub const ScreenPosition = i32;

// ConnectionOptions varies per-module

pub const ConnectionError = error{
    OutOfMemory,
    AccessDenied,
    /// One or more of the `ConnectOptions` was invalid
    InvalidOptions,
    /// A client has already been initialized
    DuplicateClient,
    HostDown,
    ConnectionFailure,
};

pub const DisconnectionError = error{
    InvalidClient,
    /// On platforms where all windows must be closed before deinitialization
    StillActiveWindows,
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
    AccessDenied,
    InvalidClient,
    /// The name exceeded the maximum length or was not valid UTF-8.
    InvalidName,
    /// The display selection was invalid,
    /// or may have been invalidated since display enumeration.
    /// Retrying with a `null` display selection will never return this error.
    InvalidDisplaySelection,
    WindowCreationFailure,
};

pub const WindowDestructionError = error{
    OutOfMemory,
    AccessDenied,
    InvalidWindow,
    WindowDestructionFailure,
};

pub const WindowShowError = error{
    AlreadyVisible,
    InvalidWindow,
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

/// Open a local UNIX domain socket
/// using `std.posix` functions.
pub fn openLocalSocket(absolute_path: []const u8) !posix.socket_t {
    const path_max_len = @typeInfo(@FieldType(posix.system.sockaddr.un, "path")).array.len - 1;
    if (absolute_path.len > path_max_len) return error.PathTooLong;

    const socket = posix.socket(
        posix.system.AF.UNIX,
        posix.system.SOCK.STREAM | posix.system.SOCK.CLOEXEC,
        0,
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        error.Unexpected => |e| return e,
        error.AddressFamilyUnsupported => unreachable,
        error.ProtocolFamilyNotAvailable => unreachable,
        error.ProtocolNotSupported => unreachable,
        error.SocketTypeNotSupported => unreachable,
    };
    errdefer posix.close(socket);

    var addr = mem.zeroInit(posix.system.sockaddr.un, .{
        .family = posix.system.AF.UNIX,
    });
    assert(absolute_path.len < addr.path.len);
    @memcpy(addr.path[0..absolute_path.len], absolute_path);
    assert(addr.path[absolute_path.len] == 0);

    posix.connect(
        socket,
        @ptrCast(&addr),
        @sizeOf(@TypeOf(addr)),
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.AddressUnavailable,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.FileNotFound,
        error.NotDir,
        error.PermissionDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        error.Unexpected => |e| return e,
        error.Canceled,
        error.OptionUnsupported,
        error.Timeout,
        error.UnsupportedClock,
        error.WouldBlock => |e| return e,
        error.AddressFamilyUnsupported => unreachable,
        error.ProtocolUnsupportedByAddressFamily => unreachable,
        error.ProtocolUnsupportedBySystem => unreachable,
        error.SocketModeUnsupported => unreachable,
        // Impossible for UNIX domain socket paths
        error.SymLinkLoop => unreachable,
        // Assert we are connecting to a UNIX socket created
        // by the host, not us the client
        error.ReadOnlyFileSystem => unreachable,
        // Network only
        error.HostUnreachable => unreachable,
        error.NetworkDown => unreachable,
        error.NetworkUnreachable => unreachable,
    };

    return socket;
}

pub const fallback_default_window_origin_x = 0;
pub const fallback_default_window_origin_y = 0;
pub const fallback_default_window_width = 800;
pub const fallback_default_window_height = 600;

test "reference all backends" {
    inline for ([_][:0]const u8{
        "X11",
        "Win32",
    }) |backend_name| {
        const lowercase_name = comptime toLowercaseComptime(backend_name);
        const Backend = @field(@This(), backend_name);
        if (@hasDecl(Backend, "Linked") and
            @field(build_options, lowercase_name ++ "_linked")) _ = Backend.Linked;
        if (@hasDecl(Backend, "Loaded")) _ = Backend.Loaded;
        if (@hasDecl(Backend, "Standalone")) _ = Backend.Standalone;
    }
}

test "x11-linked window creation" {
    if (build_options.x11_linked and passesUnitTests(&.{ "X11", "Linked" })) {
        try openCloseWindow(X11.Linked);
    } else {
        return error.SkipZigTest;
    }
}

test "win32-linked window creation" {
    if (build_options.win32_linked and passesUnitTests(&.{ "Win32", "Linked" })) {
        try openCloseWindow(Win32.Linked);
    } else {
        return error.SkipZigTest;
    }
}

fn openCloseWindow(comptime Client: type) !void {
    if (!@import("builtin").is_test)
        @compileError("openCloseWindow() is a test helper function");

    var client: Client = undefined;
    client.connect(.{}) catch |err| switch (err) {
        error.HostDown => return error.SkipZigTest,
        else => return err,
    };

    var window = try client.openWindow(.{ .name = "Spark test window" });
    try client.showWindow(window);
    try client.closeWindow(&window);

    try client.disconnect();
}

fn passesUnitTests(qualifiers: []const []const u8) bool {
    return for (@import("builtin").test_functions) |test_fn| {
        if (isNamespace(test_fn.name, qualifiers))
            test_fn.func() catch break false;
    } else true;
}

fn toLowercaseComptime(comptime string: []const u8) [string.len :0]u8 {
    var buffer: [string.len :0]u8 = undefined;
    for (&buffer, string) |*b, s| b.* = ascii.toLower(s);
    return buffer;
}

fn isNamespace(name: []const u8, qualifiers: []const []const u8) bool {
    const Iterator = mem.TokenIterator(u8, .scalar);
    var iter = Iterator{
        .buffer = name,
        .delimiter = '.',
        .index = 0,
    };

    return for (qualifiers) |qualifier| {
        if (
            if (iter.next()) |token| !mem.eql(u8, qualifier, token)
            else break false
        ) break false;
    } else true;
}

const assert = debug.assert;

const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const ascii = std.ascii;

const build_options = @import("build_options");
const std = @import("std");
