//! Relevant functions from `User32`,
//! which may be used as a dynamically-loaded interface,
//! or through a linked `User32` library via the externs in `.linked`.

LocalFree: *const fn (hMem: HLOCAL) callconv(.winapi) ATOM,
GetLastError: *const fn () callconv(.winapi) DWORD,
FormatMessageW: *const fn (
    dwFlags: DWORD,
    lpSource: ?LPCVOID,
    dwMessageId: DWORD,
    dwLanguageId: DWORD,
    lpBuffer: LPWSTR,
    nSize: DWORD,
    Arguments: ?*anyopaque, // [*c]va_list (always pass as null)
) callconv(.winapi) DWORD,

RegisterClassExW: *const fn (lpWndClass: *const WNDCLASSEXW) callconv(.winapi) BOOL,
UnregisterClassW: *const fn (lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL,

GetStartupInfoW: *const fn (lpStartupInfo: LPSTARTUPINFOW) callconv(.winapi) void,

LoadCursorW: *const fn (hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) void,

CreateWindowExW: *const fn (
    dwExStyle: DWORD,
    lpClassName: ?LPCWSTR,
    lpWindowName: ?LPCWSTR,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?LPVOID,
) callconv(.winapi) ?HWND,
DestroyWindow: *const fn (hWnd: HWND) callconv(.winapi) BOOL,
UpdateWindow: *const fn (hWnd: HWND) callconv(.winapi) BOOL,

SetWindowLongPtrW: *const fn (
    hWnd: HWND,
    nIndex: c_int,
    dwNewLong: LONG_PTR,
) callconv(.winapi) LONG_PTR,
GetWindowLongPtrW: *const fn (
    hWnd: HWND,
    nIndex: c_int,
) callconv(.winapi) LONG_PTR,

PostMessageW: *const fn (
    hWnd: ?HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) BOOL,
PeekMessageW: *const fn (
    lpMsg: LPMSG,
    hWnd: ?HWND,
    wMsgFilterMin: UINT,
    wMsgFilterMax: UINT,
    wRemoveMsg: UINT,
) callconv(.winapi) BOOL,
GetMessageW: *const fn (
    lpMsg: LPMSG,
    hWnd: ?HWND,
    wMsgFilterMin: UINT,
    wMsgFilterMax: UINT,
) callconv(.winapi) BOOL,
TranslateMessage: *const fn (lpMsg: *const MSG) callconv(.winapi) BOOL,
DispatchMessageW: *const fn (lpMsg: *const MSG) callconv(.winapi) LRESULT,

DefWindowProcW: *const fn (
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT,

BeginPaint: *const fn (hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC,
EndPaint: *const fn (hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL,

/// On error, the missing symbol name will be passed through `missing_name`
/// if not `null`.
///
/// `inline` to propagate the comptime-ness of `missing_name`.
pub inline fn init(interface: *User32, user32: *WindowsDynLib, missing_name: ?*[:0]const u8) error{MissingSymbol}!void {
    inline for (@typeInfo(User32).@"struct".fields) |field| {
        const proc_name: [:0]const u8 = field.name;
        const Proc: type = field.type;
        if (user32.lookup(Proc, proc_name)) |proc| {
            @field(interface, proc_name) = proc;
        } else {
            if (missing_name) |name_dest| name_dest.* = proc_name;
            return error.MissingSymbol;
        }
    }
}

pub fn load(user32: *WindowsDynLib) User32 {
    var interface: User32 = undefined;
    interface.init(user32);
    return interface;
}

/// The caller must `.close()` this object
/// only after the interface is no longer in use.
pub fn openDynLib() WindowsDynLib.Error!WindowsDynLib {
    return WindowsDynLib.openExW(dll_name_w, .load_library_search_system32);
}

pub const dll_name = "user32.dll";
pub const dll_name_w = std.unicode.utf8ToUtf16LeStringLiteral(dll_name);

pub const linked = if (build_options.win32_linked) struct { // TODO more explicitly user32 linked build flag
    pub extern fn LocalFree(hMem: HLOCAL) callconv(.winapi) ?HLOCAL;
    pub extern fn GetLastError() callconv(.winapi) DWORD;
    pub extern fn FormatMessageW(
        dwFlags: DWORD,
        lpSource: ?LPCVOID,
        dwMessageId: DWORD,
        dwLanguageId: DWORD,
        lpBuffer: LPWSTR,
        nSize: DWORD,
        Arguments: ?*anyopaque, // [*c]va_list (always pass as null)
    ) callconv(.winapi) DWORD;

    pub extern fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
    pub extern fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: ?HINSTANCE) callconv(.winapi) BOOL;

    pub extern fn GetStartupInfoW(lpStartupInfo: LPSTARTUPINFOW) callconv(.winapi) void;

    pub extern fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) void;

    pub extern fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: ?LPCWSTR,
        lpWindowName: ?LPCWSTR,
        dwStyle: DWORD,
        X: c_int,
        Y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: ?HINSTANCE,
        lpParam: ?LPVOID,
    ) callconv(.winapi) ?HWND;
    pub extern fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
    pub extern fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;

    pub extern fn SetWindowLongPtrW(
        hWnd: HWND,
        nIndex: c_int,
        dwNewLong: LONG_PTR,
    ) callconv(.winapi) LONG_PTR;
    pub extern fn GetWindowLongPtrW(
        hWnd: HWND,
        nIndex: c_int,
    ) callconv(.winapi) LONG_PTR;

    pub extern fn PostMessageW(
        hWnd: ?HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) BOOL;

    pub extern fn PeekMessageW(
        lpMsg: LPMSG,
        hWnd: ?HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
        wRemoveMsg: UINT,
    ) callconv(.winapi) BOOL;
    pub extern fn GetMessageW(
        lpMsg: LPMSG,
        hWnd: ?HWND,
        wMsgFilterMin: UINT,
        wMsgFilterMax: UINT,
    ) callconv(.winapi) BOOL;
    pub extern fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    pub extern fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;

    pub extern fn DefWindowProcW(
        hWnd: HWND,
        Msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) callconv(.winapi) LRESULT;

    pub extern fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
    pub extern fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
} else @compileError("invalid reference to unlinked user32 library");

const WNDCLASSEXW = win32.WNDCLASSEXW;

const BOOL = win32.BOOL;
const UINT = win32.UINT;
const ATOM = win32.ATOM;
const DWORD = win32.DWORD;
const WPARAM = win32.WPARAM;
const LPARAM = win32.LPARAM;
const LONG_PTR = win32.LONG_PTR;
const LPVOID = win32.LPVOID;
const LPCVOID = win32.LPCVOID;
const LPWSTR = win32.LPWSTR;
const LPMSG = win32.LPMSG;
const HLOCAL = win32.HLOCAL;
const HINSTANCE = win32.HINSTANCE;
const HWND = win32.HWND;
const HMENU = win32.HMENU;
const HDC = win32.HDC;
const PAINTSTRUCT = win32.PAINTSTRUCT;

const User32 = @This();
const WindowsDynLib = std.dynamic_library.WindowsDynLib;

const debug = std.debug;
const log = std.log;
const win32 = @import("../win32.zig");
const build_options = @import("build_options");
const std = @import("std");
