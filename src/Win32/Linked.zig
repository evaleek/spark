use_main_show_hint: bool,

hInstance: h.HINSTANCE,
nCmdShow: c_int,
direct_window_class: h.ATOM,

pub fn poll(client: *Client, windows: []const *Window) ?struct { ?*Window, Event } {
    _ = client;
    var msg: h.MSG = undefined;
    if ( win32.PeekMessageW(&msg, 0, 0, 0, h.PM_REMOVE) != 0 ) {
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
        var msg: h.MSG = undefined;
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

pub const Event = common.Event;
pub const Message = common.Message;

fn processEvent(window: ?*Window, msg: h.MSG) ?Event {
    _ = window;
    switch (msg.message) {
        else => return null,

        h.WM_CLOSE => return .{ .close = {} },
    }
}

pub const ConnectionError = common.ConnectionError;

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
    hInstance: ?h.HINSTANCE = null,
    /// Provide an `nCmdShow` to use for main window creation. If `null`,
    /// `connect` will retrieve the executable's `nCmdShow` from `GetStartupInfo()`
    nCmdShow: ?c_int = null,
};

pub fn connect(client: *Client, options: ConnectOptions) ConnectionError!void {
    client.use_main_show_hint = options.use_main_show_hint;

    // TODO does GetModuleHandle always return the correct HINSTANCE
    // and can it return null in this case
    client.hInstance = options.hInstance orelse @as(h.HINSTANCE,
        @alignCast(@ptrCast( kernel32.GetModuleHandleW(null).? )));

    client.nCmdShow = options.nCmdShow orelse get_cmd_show: {
        var si = mem.zeroes(h.STARTUPINFOW);
        win32.GetStartupInfoW(&si);
        break :get_cmd_show
            if (si.dwFlags & STARTF_USESHOWWINDOW != 0) si.wShowWindow
            else h.SW_SHOWDEFAULT;
    };

    client.direct_window_class = win32.RegisterClassExW(&.{
        .cbSize = @sizeOf(h.WNDCLASSEXW),
        .lpfnWndProc = &WndProcDefault,
        .hInstance = client.hInstance,
        .lpszClassName = strL(direct_window_class_name),
        .style = 0, // TODO
        .hIcon = 0, // TODO
        .hCursor = win32.LoadCursorW(0, h.IDC_ARROW),

        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hbrBackground = 0, // TODO is this ever relevant?
    });
    if (client.direct_window_class == 0) {
        // TODO failure
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
    hWnd: h.HWND,
    uMsg: h.UINT,
    wParam: h.WPARAM,
    lParam: h.LPARAM,
) callconv(.winapi) h.LRESULT {
    switch (uMsg) {
        else => return win32.DefWindowProcW(hWnd, uMsg, wParam, lParam),

        h.WM_PAINT => {
            var ps = mem.zeroes(h.PAINTSTRUCT);

            const hdc: h.HDC = win32.BeginPaint(hWnd, &ps);
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

        h.WM_ERASEBKGND => return 1,
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
    handle: h.HWND,

    x: ScreenCoordinates,
    y: ScreenCoordinates,
    width: ScreenPoints,
    height: ScreenPoints,

    pub const CreationError = common.WindowCreationError;
    pub const CreationOptions = common.WindowCreationOptions;

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
            MAKEINTATOM(client.direct_window_class),
            window_name,
            h.WS_OVERLAPPEDWINDOW,
            options.origin_x orelse h.CW_USEDEFAULT,
            options.origin_y orelse h.CW_USEDEFAULT,
            if (options.width) |width| @intCast(width) else h.CW_USEDEFAULT,
            if (options.height) |height| @intCast(height) else h.CW_USEDEFAULT,
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
                break :get_cmd h.SW_SHOW;
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

test "open and close window" {
    if (build_options.win32_linked) {
        var client: Client = undefined;
        client.connect(.{}) catch return error.SkipZigTest;
        defer client.disconnect();

        var window = try client.openWindow(.{
            .name = "test window",
        });
        defer client.closeWindow(&window);

        client.showWindow(window);
    } else {
        return error.SkipZigTest;
    }
}

const win32 = if (build_options.win32_linked) struct {
    pub extern fn RegisterClassExW(
        lpWndClass: *const h.WNDCLASSEXW,
    ) callconv(.winapi) h.ATOM;
    pub extern fn UnregisterClassW(
        lpClassName: h.LPCWSTR,
        hInstance: h.HINSTANCE,
    ) callconv(.winapi) h.BOOL;

    pub extern fn GetStartupInfoW(
        lpStartupInfo: h.LPSTARTUPINFOW,
    ) callconv(.winapi) void;

    pub extern fn LoadCursorW(
        hInstance: h.HINSTANCE,
        lpCursorName: h.LPCWSTR,
    ) callconv(.winapi) h.HCURSOR;

    pub extern fn CreateWindowExW(
        dwExStyle: h.DWORD,
        lpClassName: ?[*:0]const align(1) u16, // LPCWSTR or (LPCWSTR)ATOM
        lpWindowName: h.LPCWSTR,
        dwStyle: h.DWORD,
        X: c_int,
        Y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: h.HWND,
        hMenu: h.HMENU,
        hInstance: h.HINSTANCE,
        lpParam: h.LPVOID,
    ) callconv(.winapi) h.HWND;
    pub extern fn DestroyWindow(
        hWnd: h.HWND,
    ) callconv(.winapi) h.BOOL;
    pub extern fn UpdateWindow(
        hWnd: h.HWND,
    ) callconv(.winapi) h.BOOL;
    pub extern fn ShowWindow(
        hWnd: h.HWND,
        cCmdShow: c_int,
    ) callconv(.winapi) h.BOOL;

    pub extern fn SetWindowLongPtrW(
        hWnd: h.HWND,
        nIndex: c_int,
        dwNewLong: h.LONG_PTR,
    ) callconv(.winapi) h.LONG_PTR;
    pub extern fn GetWindowLongPtrW(
        hWnd: h.HWND,
        nIndex: c_int,
    ) callconv(.winapi) h.LONG_PTR;

    pub extern fn PeekMessageW(
        lpMsg: h.LPMSG,
        hWnd: h.HWND,
        wMsgFilterMin: h.UINT,
        wMsgFilterMax: h.UINT,
        wRemoveMsg: h.UINT,
    ) callconv(.winapi) h.BOOL;
    pub extern fn GetMessageW(
        lpMsg: h.LPMSG,
        hWnd: h.HWND,
        wMsgFilterMin: h.UINT,
        wMsgFilterMax: h.UINT,
    ) callconv(.winapi) h.BOOL;
    pub extern fn TranslateMessage(
        lpMsg: *const h.MSG,
    ) callconv(.winapi) h.BOOL;
    pub extern fn DispatchMessageW(
        lpMsg: *const h.MSG,
    ) callconv(.winapi) h.LRESULT;

    pub extern fn DefWindowProcW(
        hWnd: h.HWND,
        Msg: h.UINT,
        wParam: h.WPARAM,
        lParam: h.LPARAM,
    ) callconv(.winapi) h.LRESULT;

    pub extern fn BeginPaint(
        hWnd: h.HWND,
        lpPaint: [*c]h.PAINTSTRUCT,
    ) callconv(.winapi) h.HDC;
    pub extern fn EndPaint(
        hWnd: h.HWND,
        lpPaint: [*c]const h.PAINTSTRUCT,
    ) callconv(.winapi) h.BOOL;
} else @compileError("invalid reference to unlinked Win32 library");

const Client = @This();
const ScreenPoints = common.ScreenPoints;
const ScreenCoordinates = common.ScreenCoordinates;

// translate-c (as of 0.15.2) has trouble with `winbase.h`
inline fn MAKEINTATOM(atom: h.ATOM) ?[*:0]const align(1) u16 {
    return @ptrFromInt(@as(u16, @intCast(atom)));
}

// Comes from `winbase.h`
const STARTF_USESHOWWINDOW: c_int = 0x00000001;

const h = if (build_options.win32_linked) @import("win32")
    else @compileError("invalid reference to unlinked Win32 headers");

const strL = std.unicode.utf8ToUtf16LeStringLiteral;
const bufStrL = std.unicode.utf8ToUtf16Le;
const kernel32 = std.os.windows.kernel32;

const mem = std.mem;
const debug = std.debug;

const common = @import("common");
const build_options = @import("build_options");
const std = @import("std");
