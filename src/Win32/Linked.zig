use_main_show_hint: bool,
hInstance: HINSTANCE,
nCmdShow: c_int,
direct_window_class: ATOM,

pub fn poll(client: *Client, windows: []const *Window) ?struct { ?*Window, Event } {
    _ = client;
    var msg: MSG = undefined;
    if ( win32.PeekMessageW(&msg, 0, 0, 0, PM_REMOVE) != 0 ) {
        // TODO look into how necessary DispatchMessage is
        defer _ = win32.DispatchMessageW(&msg);

        const window: ?*Window = for (windows) |w| {
            if (w.handle == msg.hwnd) break w;
        } else null;

        const event = processEvent(window, msg) orelse return null;

        return .{ window, event };
    } else {
        return null;
    }
}

pub fn wait(client: *Client, windows: []const *Window) struct { ?*Window, Event } {
    _ = client;
    while (true) {
        var msg: MSG = undefined;
        const got = win32.GetMessageW(&msg, 0, 0, 0);
        // In direct polling there should be no WM_QUIT.
        // If we want to allow it it has to be handled here
        debug.assert(got != 0);

        defer _ = win32.DispatchMessageW(&msg);

        const window: ?*Window = for (windows) |w| {
            if (w.handle == msg.hwnd) break w;
        } else null;

        const event = processEvent(window, msg) orelse continue;

        return .{ window, event };
    }
}

pub const Event = root.Event;
pub const Message = root.Message;

fn processEvent(window: ?*Window, msg: MSG) ?Event {
    _ = window;
    switch (msg.message) {
        else => return null,

        WM_CLOSE => return .{ .close = {} },
    }
}

pub const ConnectionError = root.ConnectionError;

pub const ConnectOptions = struct {
    /// Whether to use or ignore `nCmdShow` for the first/next *shown* window,
    /// which shows the window with the executable's main window initial show hint.
    ///
    /// This value can be left default and ignored for expected behavior.
    ///
    /// After showing a window when `.use_main_show_hint = true`,
    /// the flag will be disabled.
    /// If you wish to open another window with the main window show hint
    /// (not intended behavior for Windows applications),
    /// set this field, in the Client, back to `true` before showing that window.
    use_main_show_hint: bool = true,
    /// Provide an `hInstance` to use for window creation. If `null`,
    /// `connect` will retrieve the executable's `hInstance` from `GetModuleHandle(null)`.
    hInstance: ?HINSTANCE = null,
    /// Provide an `nCmdShow` to use for main window creation. If `null`,
    /// `connect` will retrieve the executable's `nCmdShow` from `GetStartupInfo()`
    nCmdShow: ?c_int = null,
};

pub fn connect(client: *Client, options: ConnectOptions) ConnectionError!void {
    client.use_main_show_hint = options.use_main_show_hint;

    // TODO does GetModuleHandle always return the correct HINSTANCE
    // and can it return null in this case
    client.hInstance = options.hInstance orelse @as(HINSTANCE,
        @alignCast(@ptrCast( kernel32.GetModuleHandleW(null).? )));

    client.nCmdShow = options.nCmdShow orelse get_cmd_show: {
        var si = mem.zeroes(STARTUPINFOW);
        win32.GetStartupInfoW(&si);
        break :get_cmd_show
            if (si.dwFlags & STARTF_USESHOWWINDOW != 0) si.wShowWindow
            else SW_SHOWDEFAULT;
    };

    client.direct_window_class = win32.RegisterClassExW(&.{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .lpfnWndProc = &WndProcDefault,
        .hInstance = client.hInstance,
        .lpszClassName = strL(direct_window_class_name),
        .style = 0, // TODO
        .hIcon = 0, // TODO
        .hCursor = win32.LoadCursorW(0, IDC_ARROW),

        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hbrBackground = 0, // TODO is this ever relevant?
    });
    if (client.direct_window_class == 0) {
        return switch (inner_err: { break :inner_err switch (win32.GetLastError()) {
            ERROR_SUCCESS => unreachable,
            ERROR_CLASS_ALREADY_EXISTS => error.WindowClassAlreadyExists,
            ERROR_INVALID_PARAMETER => error.InvalidParameter,
            ERROR_ACCESS_DENIED => error.AccessDenied,
            ERROR_INVALID_HANDLE => error.InvalidInstanceHandle,
            else => |err| unsupported: {
                if (log_unrecognized_errors) logSystemError(err) catch {};
                break :unsupported error.UnsupportedWindowsClassRegistrationError;
            },
        };}) {
            error.InvalidParameter => unreachable,
            error.InvalidInstanceHandle => error.InvalidOptions,
            error.WindowClassAlreadyExists => error.DuplicateClient,
            error.UnsupportedWindowsClassRegistrationError => error.ConnectionFailed,
        };
    }
}

pub fn disconnect(client: *Client) void {
    defer client.* = undefined;

    // TODO free windows stored in client

    {
        const result = win32.UnregisterClassW(
            strL(direct_window_class_name),
            null, // TODO is the hInstance needed here?
        );
        if (result == 0) {
            // error: class could not be found
            // or window still exists that was created with the class
        }
    }
}

// TODO note somewhere that, in the direct polling mode,
// the redraw event is specifically a *deferred* redraw
// in that we have technically already told the compositor
// that that region has been redrawn (validated)
// by the time the redraw event is returning from poll()
// (so the user should, if not already continuously redrawing,
// immediately redraw to be well-behaved).
// if the user really wants to ensure they have redrawn
// before the rect is validated, they need to use the callback mode
// (unless i can figure out some way to avoid DispatchMessage)

pub const direct_window_class_name = "SparkDirect";

// TODO is callconv(.winapi) equivalent to __stdcall?
fn WndProcDefault(
    hWnd: HWND,
    uMsg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT {
    switch (uMsg) {
        else => return win32.DefWindowProcW(hWnd, uMsg, wParam, lParam),

        WM_PAINT => {
            var ps = mem.zeroes(PAINTSTRUCT);

            const hdc: HDC = win32.BeginPaint(hWnd, &ps);
            // We don't need the display device context here,
            // because we are just calling this to acknowledge the PAINT event
            // and be a well-behaved Windows window
            // (polling will return a .redraw event immediately after this).
            // If BeginPaint fails here, this value would be null,
            // but we don't care yet.
            _ = hdc;

            const end = win32.EndPaint(hWnd, &ps);
            // EndPaint documents itself as always returning nonzero
            debug.assert(end != 0);

            return 0;
        },

        WM_ERASEBKGND => return 1,
    }
}

pub fn openWindow(client: *Client, options: Window.CreationOptions) Window.CreationError!Window {
    var window: Window = undefined;
    try window.open(client, options);
    return window;
}

pub fn closeWindow(client: *Client, window: *Window) void {
    window.close(client);
}

pub fn showWindow(client: *Client, window: Window) void {
    window.show(client);
}

pub const Window = struct {
    handle: HWND,

    x: ScreenPosition,
    y: ScreenPosition,
    width: ScreenSize,
    height: ScreenSize,

    pub const CreationOptions = root.WindowCreationOptions;
    pub const CreationError = root.WindowCreationError;

    pub fn open(window: *Window, client: *Client, options: CreationOptions) CreationError!void {
        // TODO determine good max name length
        const max_name_length = 127;
        // TODO can this be done any cleaner without doing allocation
        var name_buffer: [max_name_length+1]u16 = @splat(0);
        const window_name: [:0]u16 = str_l: {
            if (options.name.len <= max_name_length) {
                const len = bufStrL(name_buffer[0..max_name_length], options.name)
                    catch |err| break :str_l err;
                break :str_l name_buffer[0..len :0];
            } else {
                break :str_l error.Overflow;
            }
        } catch return error.InvalidName;

        window.handle = win32.CreateWindowExW(
            0, // TODO extended window style
            .fromAtom(client.direct_window_class),
            window_name,
            WS_OVERLAPPEDWINDOW,
            options.origin_x orelse CW_USEDEFAULT,
            options.origin_y orelse CW_USEDEFAULT,
            if (options.width) |width| @intCast(width) else CW_USEDEFAULT,
            if (options.height) |height| @intCast(height) else CW_USEDEFAULT,
            0, 0,
            client.hInstance,
            null,
        );
        if (window.handle == 0) {
            // TODO error
        }
        errdefer _ = win32.DestroyWindow(window.handle);

        //window.x = undefined;
        //window.y = undefined;
        //window.width = undefined;
        //window.height = undefined;

        // TODO query what the window size and origin is now and assign
    }

    pub fn close(window: *Window, client: *Client) void {
        _ = client;
        if (win32.DestroyWindow(window.handle) != 0) {} else {
            // TODO error
        }
        window.* = undefined;
    }

    pub fn show(window: Window, client: *Client) void {
        const cmd: c_int = get_cmd: {
            if (client.use_main_show_hint) {
                client.use_main_show_hint = false;
                break :get_cmd client.nCmdShow;
            } else {
                break :get_cmd SW_SHOW;
            }
        };

        if (win32.ShowWindow(window.handle, cmd) != 0) {} else {
            // TODO error
        }

        // TODO where does this go
        //if (win32.UpdateWindow(window.handle) != 0) {} else {
        //    // TODO error
        //}
    }
};

const StringOrAtom = packed union {
    string: LPCWSTR,
    atom: packed struct {
        word: WORD,
        _high: @Type(.{ .int = .{
            .signedness = .unsigned,
            .bits = @bitSizeOf(LPCWSTR) - @bitSizeOf(WORD),
        }}) = 0,
    },

    pub inline fn fromAtom(atom: ATOM) StringOrAtom {
        return .{ .atom = .{ .word = atom }};
    }
};
comptime { debug.assert(ATOM == WORD); }
comptime { debug.assert(@bitSizeOf(WORD) == 16); }
comptime { debug.assert(@bitSizeOf(StringOrAtom) == @bitSizeOf(LPCWSTR)); }
test StringOrAtom {
    const atom: ATOM = 0x63;
    const as_macro: usize = @intFromPtr(MAKEINTATOM(atom));
    const as_union: usize = @bitCast(StringOrAtom.fromAtom(atom));
    try testing.expectEqual(as_macro, as_union);
}

fn logSystemError(err: DWORD) !void {
    var msg: LPWSTR = null;

    const len: DWORD = win32.FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        err,
        0,
        @ptrCast(&msg), // system allocates
        0,
        null,
    );

    if (len == 0) return error.NoMessage;
    if (msg) |message| {
        std.log.err(
            "unsupported win32 system error code 0x{x} (error message follows)\n{f}",
            .{ err, unicode.fmtUtf16Le(message[0..len]) },
        );

        const free_result = win32.LocalFree(msg);
        if (free_result != null) std.log.err(
            "win32 LocalFree() after FormatMessageW() error code 0x{x}",
            .{ @intFromPtr(free_result) },
        );
    } else {
        return error.NoMessage;
    }

}

const win32 = if (build_options.win32_linked) struct {
    pub extern fn GetLastError() callconv(.winapi) DWORD;
    pub extern fn FormatMessageW(
        dwFlags: DWORD,
        lpSource: LPCVOID,
        dwMessageId: DWORD,
        dwLanguageId: DWORD,
        lpBuffer: LPWSTR,
        nSize: DWORD,
        Arguments: ?std.builtin.VaList,
    ) callconv(.winapi) DWORD;

    pub extern fn LocalFree(hMem: HLOCAL) callconv(.winapi) HLOCAL;

    pub extern fn RegisterClassExW(
        lpWndClass: *const WNDCLASSEXW,
    ) callconv(.winapi) ATOM;
    pub extern fn UnregisterClassW(
        lpClassName: LPCWSTR,
        hInstance: HINSTANCE,
    ) callconv(.winapi) BOOL;

    pub extern fn GetStartupInfoW(
        lpStartupInfo: LPSTARTUPINFOW,
    ) callconv(.winapi) void;

    pub extern fn LoadCursorW(
        hInstance: HINSTANCE,
        lpCursorName: LPCWSTR,
    ) callconv(.winapi) HCURSOR;

    pub extern fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: StringOrAtom,
        lpWindowName: LPCWSTR,
        dwStyle: DWORD,
        X: c_int,
        Y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: HWND,
        hMenu: HMENU,
        hInstance: HINSTANCE,
        lpParam: LPVOID,
    ) callconv(.winapi) HWND;
    pub extern fn DestroyWindow(
        hWnd: HWND,
    ) callconv(.winapi) BOOL;
    pub extern fn UpdateWindow(
        hWnd: HWND,
    ) callconv(.winapi) BOOL;
    pub extern fn ShowWindow(
        hWnd: HWND,
        cCmdShow: c_int,
    ) callconv(.winapi) BOOL;

    pub extern fn SetWindowLongPtrW(
        hWnd: HWND,
        nIndex: c_int,
        dwNewLong: LONG_PTR,
    ) callconv(.winapi) LONG_PTR;
    pub extern fn GetWindowLongPtrW(
        hWnd: HWND,
        nIndex: c_int,
    ) callconv(.winapi) LONG_PTR;

    pub extern fn PeekMessageW(
        lpMsg: LPMSG,
        hWnd: HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
        wRemoveMsg: UINT,
    ) callconv(.winapi) BOOL;
    pub extern fn GetMessageW(
        lpMsg: LPMSG,
        hWnd: HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
    ) callconv(.winapi) BOOL;
    pub extern fn TranslateMessage(
        lpMsg: *const MSG,
    ) callconv(.winapi) BOOL;
    pub extern fn DispatchMessageW(
        lpMsg: *const MSG,
    ) callconv(.winapi) LRESULT;

    pub extern fn DefWindowProcW(
        hWnd: HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) LRESULT;

    pub extern fn BeginPaint(
        hWnd: HWND,
        lpPaint: [*c]PAINTSTRUCT,
    ) callconv(.winapi) HDC;
    pub extern fn EndPaint(
        hWnd: HWND,
        lpPaint: [*c]const PAINTSTRUCT,
    ) callconv(.winapi) BOOL;
} else @compileError("invalid reference to unlinked Win32 library");

// translate-c (as of 0.15.2) has trouble with `winbase.h`
inline fn MAKEINTATOM(atom: ATOM) ?[*:0]const align(1) u16 {
    return @ptrFromInt(@as(u16, @intCast(atom)));
}

const log_unrecognized_errors: bool = switch (@import("builtin").mode) {
    .Debug => true,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
};

// Comes from `winbase.h`
const STARTF_USESHOWWINDOW: c_int = 0x00000001;

const SW_SHOW               = h.SW_SHOW;
const SW_SHOWDEFAULT        = h.SW_SHOWDEFAULT;
const CW_USEDEFAULT         = h.CW_USEDEFAULT;
const PM_REMOVE             = h.PM_REMOVE;
const IDC_ARROW             = h.IDC_ARROW;
const WS_OVERLAPPEDWINDOW   = h.WS_OVERLAPPEDWINDOW;
const WM_CLOSE              = h.WM_CLOSE;
const WM_PAINT              = h.WM_PAINT;
const WM_ERASEBKGND         = h.WM_ERASEBKGND;

const BOOL                  = h.BOOL;
const UINT                  = h.UINT;
const WORD                  = h.WORD;
const DWORD                 = h.DWORD;
const LONG_PTR              = h.LONG_PTR;
const ATOM                  = h.ATOM;
const HINSTANCE             = h.HINSTANCE;
const HWND                  = h.HWND;
const HDC                   = h.HDC;
const HMENU                 = h.HMENU;
const HLOCAL                = h.HLOCAL;
const HCURSOR               = h.HCURSOR;
const WPARAM                = h.WPARAM;
const LPARAM                = h.LPARAM;
const LRESULT               = h.LRESULT;

const MSG                   = h.MSG;
const STARTUPINFOW          = h.STARTUPINFOW;
const WNDCLASSEXW           = h.WNDCLASSEXW;
const PAINTSTRUCT           = h.PAINTSTRUCT;

const LPVOID                = h.LPVOID;
const LPWSTR                = h.LPWSTR;
const LPCVOID               = h.LPCVOID;
const LPCWSTR               = h.LPCWSTR;
const LPMSG                 = h.LPMSG;
const LPSTARTUPINFOW        = h.LPSTARTUPINFOW;

// Hardcoded because translate-c was not setting these macros to the correct values
const ERROR_SUCCESS                 = 0x0;
const ERROR_ACCESS_DENIED           = 0x5;
const ERROR_INVALID_HANDLE          = 0x6;
const ERROR_INVALID_PARAMETER       = 0x57;
const ERROR_CLASS_ALREADY_EXISTS    = 0x582;
const ERROR_CLASS_DOES_NOT_EXIST    = 0x583;
const ERROR_CLASS_HAS_WINDOWS       = 0x584;

// Comes from `winbase.h`
const FORMAT_MESSAGE_ALLOCATE_BUFFER    = 0x00000100;
const FORMAT_MESSAGE_FROM_SYSTEM        = 0x00001000;
const FORMAT_MESSAGE_IGNORE_INSERTS     = 0x00000200;

const Client = @This();
const ScreenSize = root.ScreenSize;
const ScreenPosition = root.ScreenPosition;
const missing_backend_error =
    if (build_options.win32_force_test_host) error.Win32ConnectionFailure
    else error.SkipZigTest;

const h = if (build_options.win32_linked) @import("win32")
    else @compileError("invalid reference to unlinked Win32 headers");

const VaList = std.builtin.VaList;
const strL = unicode.utf8ToUtf16LeStringLiteral;
const bufStrL = unicode.utf8ToUtf16Le;
const kernel32 = std.os.windows.kernel32;

const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const unicode = std.unicode;

const root = @import("../root.zig");
const build_options = @import("build_options");
const std = @import("std");
