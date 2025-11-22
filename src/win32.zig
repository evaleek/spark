pub const WWords = packed struct (WPARAM) {
    /// LOWORD(WPARAM) equivalent
    low: WORD,
    /// HIWORD(WPARAM) equivalent
    high: WORD,
    /// Unused on 64-bit systems
    _padding: @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @bitSizeOf(WPARAM) - ( 2 * @bitSizeOf(WORD) ),
    }}),
};

pub const LWords = packed struct (LPARAM) {
    /// LOWORD(LPARAM) equivalent
    low: WORD,
    /// HIWORD(LPARAM) equivalent
    high: WORD,
    /// Unused on 64-bit systems
    _padding: @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @bitSizeOf(LPARAM) - ( 2 * @bitSizeOf(WORD) ),
    }}),
};

pub const Message = union {

    pub const Create = extern struct {
        /// The `lpParam` value passed at `CreateWindow`(`Ex`).
        params: ?*anyopaque,
        /// The `HINSTANCE` which will own this new window.
        instance: HINSTANCE,
        /// The menu to be used by the new window.
        menu: HMENU,
        /// A handle to the parent or owner window,
        /// or `0` if this window is not a child or owned window.
        parent: HWND,
        /// The height of the new window, in pixels.
        height: c_int,
        /// The width of the new window, in pixels.
        width: c_int,
        /// The y-coordinate of the upper-left corner of the new window.
        /// If this new window is a child window,
        /// the coordinates are relative to the parent window.
        /// Otherwise, the coordinates are relative to the screen origin.
        y: c_int,
        /// The x-coordinate of the upper-left corner of the new window.
        /// If this new window is a child window,
        /// the coordinates are relative to the parent window.
        /// Otherwise, the coordinates are relative to the screen origin.
        x: c_int,
        style: WindowStyle,
        /// The name of the new window.
        name: [*:0]const WCHAR,
        /// A pointer to a null-terminated string or an atom
        /// that specifies the class name of the new window.
        class: StringOrAtom,
        extended_style: WindowStyleExtended,

        pub const message = WM.CREATE;
        /// If an application processes this message,
        /// it should return zero to continue creation of the window.
        pub const processed: LRESULT = 0;
        /// If the application returns -1,
        /// the window is destroyed
        /// and the `CreateWindowEx` or `CreateWindow` function
        /// returns a `NULL` handle.
        pub const failed: LRESULT = -1;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) *const Create {
            assert(uMsg == message);
            _ = wParam;
            return @ptrFromInt(lParam);
        }

        pub fn getParent(create: Create) ?HWND {
            return if (create.parent != 0) create.parent else null;
        }
    };
    comptime {
        assert(@sizeOf(Create) == @sizeOf(CREATESTRUCTW));
        assert(@alignOf(Create) == @alignOf(CREATESTRUCTW));
        for (
            @typeInfo(Create).@"struct".fields,
            @typeInfo(CREATESTRUCTW).@"struct".fields,
        ) |field_a, field_b| {
            assert(@sizeOf(field_a.type) == @sizeOf(field_b.type));
            assert(field_a.alignment == field_b.alignment);
            assert(@offsetOf(Create, field_a.name)
                == @offsetOf(CREATESTRUCTW, field_b.name));
        }
    }

    /// Sent when a window is being destroyed.
    /// It is sent to the window procedure of the window being destroyed
    /// after the window is removed from the screen.
    ///
    /// This message is sent first to the window being destroyed
    /// and then to the child windows (if any) as they are destroyed.
    /// During the processing of the message,
    /// it can be assumed that all child windows still exist.
    ///
    /// A window receives this message through its `WindowProc` function.
    pub const Destroy = struct {
        pub const message = WM.DESTROY;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) void {
            assert(uMsg == message);
            _ = wParam;
            _ = lParam;
            return {};
        }
    };

    /// The `DestroyWindow` function sends this message to the window
    /// following the `Destroy` message.
    /// `NonclientDestroy` is used to free the Windows memory object
    /// associated with the window.
    ///
    /// This message is sent after the child windows have been destroyed.
    /// In contrast, `Destroy` is sent before the child windows are destroyed.
    ///
    /// A window recieves this message through its `WindowProc` function.
    pub const NonclientDestroy = struct {
        pub const message = WM.NCDESTROY;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) void {
            assert(uMsg == message);
            _ = wParam;
            _ = lParam;
            return {};
        }
    };

    /// Indicates a request to terminate an application,
    /// and is generated when the application calls the `PostQuitMessage` function.
    /// This message causes the `GetMessage` function to return zero.
    ///
    /// The `Quit` message is not associated with a window
    /// and therefore will never be received through a window's window procedure.
    /// It is retrieved only by the `GetMessage` or `PeekMessage` functions.
    ///
    /// Do not post the `Quit` message using the `PostMessage` function;
    /// use `PostQuitMessage`.
    pub const Quit = struct {
        /// The application exit code given in `PostQuitMessage`.
        exit: c_int,

        pub const message = WM.QUIT;
        // This message does not have a return value
        // because it causes the message loop to terminate
        // before the message is sent to the application's window procedure.

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Quit {
            assert(uMsg == message);
            _ = lParam;
            const Mask = @Type(.{ .int = .{
                .signedness = .unsigned,
                .bits = @bitSizeOf(c_int),
            }});
            const masked: Mask = @truncate(wParam);
            const code: c_int = @bitCast(masked);
            return Quit{ .exit = code };
        }
    };

    /// The `DefWindowProc` function for this message
    /// hides or shows the window as specified by the message.
    /// If a window has the `visible` style when it is created,
    /// the window receives this message after it is created,
    /// but before it is displayed.
    /// A window also receives this message when its visibility state is changed
    /// by the `ShowWindow` or `ShowOwnedPopups` function.
    ///
    /// This message is not sent under the following circumstances:
    ///
    /// - When a top-level, overlapped window
    ///   is created with the `maximize` or `minimize` style
    /// - When the `show_normal` flag is specified
    ///   in the call to the `ShowWindow` function.
    pub const ShowWindow = struct {
        /// Indicates whether a window is being shown.
        /// If `true`, the window is being shown.
        /// If `false`, the window is being hidden.
        shown: bool,
        status: ShowStatus,

        pub const message = WM.SHOWWINDOW;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) ShowWindow {
            assert(uMsg == message);
            return ShowWindow{
                .shown = wParam != 0,
                .status = @enumFromInt(lParam),
            };
        }
    };

    /// Sent as a signal that a window or application should terminate.
    ///
    /// A window receives this message through its `WindowProc` function.
    pub const Close = struct {
        pub const message = WM.CLOSE;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) void {
            assert(uMsg == message);
            _ = wParam;
            _ = lParam;
            return {};
        }
    };

    /// Sent after a window has been moved.
    pub const Move = struct {
        /// The x-coordinate of the upper left corner of the client area of the window.
        x: i16,
        /// The y-coordinate of the upper left corner of the client area of the window.
        y: i16,

        pub const message = WM.MOVE;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Move {
            assert(uMsg == message);
            const l: LWords = @bitCast(lParam);
            _ = wParam;
            return Move{
                .x = @bitCast(l.low),
                .y = @bitCast(l.high),
            };
        }
    };

    /// Sent to a window after its size has changed.
    pub const Size = struct {
        /// The type of resizing requested.
        request: Request,
        /// The new width of the client area.
        width: u16,
        /// The new height of the client area.
        height: u16,

        pub const message = WM.SIZE;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub const Request = enum (WPARAM) {
            /// Message is sent to all pop-up windows
            /// when some other window is maximized.
            max_hide = SIZE.MAXHIDE,
            /// The window has been maximized.
            maximized = SIZE.MAXIMIZED,
            /// Message is sent to all pop-up windows
            /// when some other window has been restored to its former size.
            max_show = SIZE.MAXSHOW,
            /// The window has been minimized.
            minimized = SIZE.MINIMIZED,
            /// The window has been resized,
            /// but neither the `minimized` nor `maximized` value applies.
            restored = SIZE.RESTORED,
            _,

            pub fn fromParam(wParam: WPARAM) Request {
                return @enumFromInt(wParam);
            }
        };

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Size {
            assert(uMsg == message);
            const l: LWords = @bitCast(lParam);
            return Size{
                .request = .fromParam(wParam),
                .width = l.low,
                .height = l.high,
            };
        }
    };

    /// Sent to a window whose size, position, or place in the Z-order
    /// is about to change (for `*CHANGING`) or has changed (for `*CHANGED`)
    /// as a result of a call to the `SetWindowPos` function
    /// or another window management function.
    ///
    /// Calling `DefWindowProc` on `WM_WINDOWPOSCHANGED`
    /// sends the `Size` and `Move` messages to the window,
    /// and they are not sent if an application handles this message
    /// without calling `DefWindowProc`.
    ///
    /// It is more efficient to perform any move or size change processing
    /// during `WM_WINDOWPOSCHANGED` without calling `DefWindowProc`.
    pub const WindowPositionChange = extern struct {
        /// The `hwnd` listed in this event's inner struct.
        window: HWND,
        /// The position of the window in Z order (front-to-back position).
        /// This member can be a handle to
        /// the window behind which this window is placed,
        /// or can be a special value.
        z: Z,
        /// The new position of the left edge of the window.
        x: c_int,
        /// The new position of the top edge of the window.
        y: c_int,
        /// The new window width, in pixels.
        width: c_int,
        /// The new window height, in pixels.
        height: c_int,
        flags: SetWindowPosition,

        /// If an application processes either
        /// `WM_WINDOWPOSCHANGING` or `WM_WINDOWPOSCHANGED`,
        /// it should return this value.
        pub const processed: LRESULT = 0;

        pub const Z = packed union {
            order: packed struct {
                placement: WindowSpecialZ,
                _padding: @Type(.{ .int = .{
                    .signedness = .unsigned,
                    .bits = @bitSizeOf(HWND) - @bitSizeOf(WindowSpecialZ),
                }}) = 0,
            },
            window: HWND,

            pub const OrderOrWindow = enum { order, window };

            pub fn which(z: Z) OrderOrWindow {
                return if (std.math.cast(@typeInfo(WindowSpecialZ).tag_type,
                        @as(HWND, @bitCast(z)))) |_| .order
                    else .window;
            }

            pub fn fromSpecial(special: WindowSpecialZ) Z {
                return .{ .order = .{ .placement = special }};
            }

            pub fn fromAfter(after: HWND) Z {
                return .{ .after = after };
            }
        };

        /// An application receives this struct during the CHANGED event
        /// and may use it to update internal window state.
        ///
        /// It is more efficient to perform any move or size change processing
        /// during `WM_WINDOWPOSCHANGED` without calling `DefWindowProc`.
        ///
        /// This reference is owned by Windows and cannot be freed,
        /// and should only be considered valid within the WndProc.
        pub fn fromParamsChanged(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) *const WindowPositionChange {
            assert(uMsg == WM.WINDOWPOSCHANGED);
            _ = wParam;
            return @ptrFromInt(lParam);
        }

        /// An application may modify this struct during the CHANGING event
        /// to affect the window's new size, position, or Z order,
        /// and set or clear appropriate bits of the `.flags` field.
        ///
        /// Changes to some SetWindowPosition flags,
        /// including `.no_activate` and `.no_owner_z_order`,
        /// are ignored when modified during this event.
        ///
        /// This reference is owned by Windows and cannot be freed,
        /// and should only be considered valid within the WndProc.
        pub fn fromParamsChanging(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) *WindowPositionChange {
            assert(uMsg == WM.WINDOWPOSCHANGING);
            _ = wParam;
            return @ptrFromInt(lParam);
        }
    };
    comptime {
        assert(@sizeOf(WindowPositionChange) == @sizeOf(WINDOWPOS));
        assert(@alignOf(WindowPositionChange) == @alignOf(WINDOWPOS));
        for (
            @typeInfo(WindowPositionChange).@"struct".fields,
            @typeInfo(WINDOWPOS).@"struct".fields,
        ) |field_a, field_b| {
            assert(@sizeOf(field_a.type) == @sizeOf(field_b.type));
            assert(field_a.alignment == field_b.alignment);
            assert(@offsetOf(WindowPositionChange, field_a.name)
                == @offsetOf(WINDOWPOS, field_b.name));
        }
    }

    pub const WindowPositionChanging = struct {
        pub const message = WM.WINDOWPOSCHANGING;
        pub const processed = WindowPositionChange.processed;
        pub const fromParams = WindowPositionChange.fromParamsChanging;
        pub const Z = WindowPositionChange.Z;
    };

    pub const WindowPositionChanged = struct {
        pub const message = WM.WINDOWPOSCHANGED;
        pub const processed = WindowPositionChange.processed;
        pub const fromParams = WindowPositionChange.fromParamsChanged;
        pub const Z = WindowPositionChange.Z;
    };

    /// Sent when the effective dots per inch (dpi) for a window has changed.
    /// The DPI is the scale factor for the window.
    /// There are multiple events that can cause the DPI to change.
    /// The following list indicates the possible causes for the change in DPI.
    ///
    /// - The window is moved to a new monitor that has a different DPI.
    /// - The DPI of the monitor hosting the window changes.
    ///
    /// The current DPI for a window always equals
    /// the last DPI sent by this message.
    /// This is the scale factor that the window should be scaling to
    /// for threads that are aware of DPI changes.
    pub const DPIChanged = struct {
        /// The X-axis value of the new DPI of the window.
        /// Identical to the Y-axis value for Windows apps.
        x_dpi: u16,
        /// The Y-axis value of the new DPI of the window.
        /// Identical to the X-axis value for Windows apps.
        y_dpi: u16,
        /// A suggested new size and position of the current window
        /// scaled for the new DPI.
        ///
        /// The expectation is that apps will reposition and resize windows
        /// based on the suggestion when handling this message.
        suggested_window: *const RECT,

        pub const message = WM.DPICHANGED;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) DPIChanged {
            assert(uMsg == message);
            const w: WWords = @bitCast(wParam);
            return DPIChanged{
                .x_dpi = w.low,
                .y_dpi = w.high,
                .suggested_window = @intFromPtr(lParam),
            };
        }
    };

    /// This message is sent to all top-level windows,
    /// and posted to all others,
    /// when the display resolution has changed.
    pub const DisplayChange = struct {
        /// The new display bit depth, in bits per pixel.
        bits_per_pixel: usize,
        /// The new horizontal resolution of the screen.
        horizontal: u16,
        /// The new vertical resolution of the screen.
        vertical: u16,

        pub const message = WM.DISPLAYCHANGE;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) DisplayChange {
            assert(uMsg == message);
            const l: LWords = @bitCast(lParam);
            return DisplayChange{
                .bits_per_pixel = wParam,
                .horizontal = l.low,
                .vertical = l.high,
            };
        }
    };

    /// Sent to a window after it has gained the keyboard focus.
    ///
    /// This event is the intended time to display a caret.
    pub const SetFocus = struct {
        /// A handle to the window that has lost the keyboard focus,
        /// if any.
        donor: ?HWND,

        pub const message = WM.SETFOCUS;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) SetFocus {
            assert(uMsg == message);
            _ = lParam;
            return SetFocus{
                .donor = if (wParam != 0) @ptrFromInt(wParam) else null,
            };
        }
    };

    /// Sent to a window immediately before it loses the keyboard focus.
    ///
    /// This event is the intended time to destroy the caret.
    ///
    /// While processing this message, do not make any function calls
    /// that display or activate a window.
    /// This causes the thread to yield control
    /// and can cause the application to stop responding to messages.
    pub const KillFocus = struct {
        /// A handle to the window that receives the keyboard focus,
        /// if any.
        recipient: ?HWND,

        pub const message = WM.KILLFOCUS;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) KillFocus {
            assert(uMsg == message);
            _ = lParam;
            return KillFocus{
                .recipient = if (wParam != 0) @ptrFromInt(wParam) else null,
            };
        }
    };

    /// Sent to both the window being activated and the window being deactivated.
    /// If the windows use the same input queue,
    /// the message is sent synchronously,
    /// first to the window procedure of the top-level window being deactivated,
    /// then to the window procedure of the top-level window being activated.
    /// If the windows use different input queues,
    /// the message is sent asynchronously,
    /// so the window is activated immediately.
    ///
    /// If the window is being activated and is not minimized,
    /// the `DefWindowProc` function sets the keyboard focus to the window.
    /// If the window is activated by a mouse click,
    /// it also receives a `MOUSEACTIVATE` message.
    pub const Activate = struct {
        activation: WindowActivation,
        /// The minimized state of the window being activated or deactivated.
        /// `true` indicates the window is minimized.
        minimized: bool,
        /// If this window is being deactivated,
        /// a handle to the window being activated, if any.
        /// If this window is being activated,
        /// a handle to the window being deactivated, if any.
        other: ?HWND,

        pub const message = WM.ACTIVATE;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Activate {
            assert(uMsg == message);
            const w: WWords = @bitCast(wParam);
            return Activate{
                .activation = @enumFromInt(w.low),
                .minimized = w.high!=0,
                .other = if (lParam != 0) @ptrFromInt(lParam) else null,
            };
        }
    };

    /// Sent to a window when its nonclient area needs to be changed
    /// to indicate an active or inactive state.
    ///
    /// A window receives this message through its `WindowProc` function.
    ///
    /// If `active` is `false`,
    /// the application should return `TRUE` (`1`)
    /// to indicate that the system should proceed with the default processing,
    /// or it should return `FALSE` to prevent the change.
    /// When `active` is true, the return value is ignored.
    pub const NonclientActivate = struct {
        /// Indicates when a title bar or icon needs to be changed
        /// to indicate an active or inactive state.
        /// `true` if an active title bar or icon is to be drawn, and
        /// `false` if an inactive title bar or icon is to be drawn.
        active: bool,
        /// Whether `DefWindowProc`
        /// will repaint the nonclient area to reflect the state change.
        repaint: bool,
        /// `null` if not repainting the nonclient area to reflect stage change,
        /// or if the previous/next window is from another application.
        /// Otherwise, a handle to the window that will next be activated,
        /// if `active` is `false`,
        /// or a handle to the previously active window,
        /// if `active` is `true`.
        other: ?HWND,

        pub const message = WM.NCACTIVATE;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) NonclientActivate {
            assert(uMsg == message);
            return NonclientActivate{
                .active = wParam!=0,
                .repaint = lParam==-1,
                .other = if (lParam > 0) @ptrFromInt(lParam) else null,
            };
        }
    };

    /// The data returned by all key events.
    /// Its meaning varies slightly depending on the value of `uMsg`.
    pub const Key = struct {
        virtual: VirtualKey,
        keystroke: Keystroke,

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Key {
            assert(
                uMsg == WM.KEYDOWN or
                uMsg == WM.KEYUP or
                uMsg == WM.SYSKEYDOWN or
                uMsg == WM.SYSKEYUP
            );
            const w: u8 = @truncate(wParam);
            const l: usize = @bitCast(lParam);
            const l_dword: u32 = @truncate(l);
            return Key{
                .virtual = @enumFromInt(w),
                .keystroke = @bitCast(l_dword),
            };
        }
    };

    /// Posted to the window with the keyboard focus
    /// when a nonsystem key is pressed.
    /// A nonsystem key is a key that is pressed when the ALT key is not pressed.
    pub const KeyDown = struct {
        pub const message = WM.KEYDOWN;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Key {
            assert(uMsg == message);
            return Key.fromParams(uMsg, wParam, lParam);
        }
    };

    /// Posted to the window with the keyboard focus
    /// when a nonsystem key is released.
    /// A nonsystem key is a key that is pressed when the ALT key is not pressed,
    /// or a keyboard key that is pressed when a window has the keyboard focus.
    pub const KeyUp = struct {
        pub const message = WM.KEYUP;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Key {
            assert(uMsg == message);
            return Key.fromParams(uMsg, wParam, lParam);
        }
    };

    /// Posted to the window with the keyboard focus
    /// when the user presses the F10 key
    /// (which activates the menu bar)
    /// or holds down the ALT key and then presses another key.
    /// It also occurs when no window currently has the keyboard focus;
    /// in this case, this message is sent to the active window.
    /// The window that receives the message
    /// can distinguish between these two contexts
    /// by checking the `.context` code of `.keystroke`.
    pub const SystemKeyDown = struct {
        pub const message = WM.SYSKEYDOWN;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Key {
            assert(uMsg == message);
            return Key.fromParams(uMsg, wParam, lParam);
        }
    };

    /// Posted to the window with the keyboard focus
    /// when the user releases a key that was pressed
    /// while the ALT key was held down.
    /// It also occurs when no window currently has the keyboard focus;
    /// in this case, this message is sent to the active window.
    /// The window that receives the message
    /// can distinguish between these two contexts
    /// by checking the `.context` code of `.keystroke`.
    pub const SystemKeyUp = struct {
        pub const message = WM.SYSKEYUP;
        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Key {
            assert(uMsg == message);
            return Key.fromParams(uMsg, wParam, lParam);
        }
    };

    /// Posted to the window with the keyboard focus
    /// when a key message is translated by the `TranslateMessage` function.
    /// This message contains the character code of the key that was pressed.
    ///
    /// Assumes that the window class was registered with the Unicode version
    /// (`RegisterClassExW`), which specifies UTF-16 code units.
    ///
    /// In Window Vista or higher, this event may receive UTF-16 surrogate pairs.
    pub const Character = struct {
        /// A single UTF-16 codepoint as translated by Windows
        /// through the `TranslateMessage` function.
        ///
        /// In modern versions of Windows,
        /// Character events may pass UTF-16 surrogate pairs:
        /// this value may be a high surrogate UTF-16 code point, in which case
        /// the next event would be its corresponding low surrogate
        /// for well-formed input.
        codepoint: u16,
        /// There is not necessarily a one-to-one correspondence
        /// between keypress events and character messages,
        /// and so information in the high word of `keystroke`
        /// is not generally useful to applications.
        keystroke: Keystroke,

        /// If an application processes this message, it should return this value.
        pub const processed: LRESULT = 0;

        pub fn fromParams(uMsg: UINT, wParam: WPARAM, lParam: LPARAM) Character {
            assert(
                uMsg == WM.CHAR or
                uMsg == WM.DEADCHAR or
                uMsg == WM.SYSCHAR or
                uMsg == WM.SYSDEADCHAR
            );
            const w: WWords = @bitCast(wParam);
            const l_unsigned: usize = @bitCast(lParam);
            const l_dword: u32 = @truncate(l_unsigned);
            return Character{
                .codepoint = w.low,
                .keystroke = @bitCast(l_dword),
            };
        }
    };
};

pub const WindowsMessage = enum(u16) {
    /// Sent when a window is being activated or deactivated.
    /// This message is sent first to the window procedure
    /// of the top-level window being deactivated;
    /// it is then sent to the window procedure
    /// of the top-level window being activated.
    activate = WM.ACTIVATE,
    /// Sent when a window belonging to a different application
    /// than the active window is about to be activated.
    /// The message is then sent to the application
    /// whose window is being activated
    /// and to the application
    /// whose window is being deactivated.
    activate_app = WM.ACTIVATEAPP,
    /// Specifies the first afx message.
    afx_first = WM.AFXFIRST,
    /// Specifies the last afx message.
    afx_last = WM.AFXLAST,
    /// Used by applications to help define private messages,
    /// usually of the form `WM_APP+X`,
    /// where `X` is an integer value.
    app = WM.APP,
    /// Sent to the clipboard owner by a clipboard viewer window
    /// to request the name of a `CF_OWNERDISPLAY` clipboard format.
    ask_clipboard_format_name = WM.ASKCBFORMATNAME,
    /// Posted to an application
    /// when a user cancels the application's journaling activities.
    /// The message is posted with a `NULL` window handle.
    cancel_journal = WM.CANCELJOURNAL,
    /// Sent to cancel certain modes, such as mouse capture.
    /// For example, the system sends this message to the active window
    /// when a dialogue box or message box is displayed.
    /// Certain functions also send this message explicitly to the specified window
    /// regardless of whether it is the active window.
    /// For example, the `EnableWindow` function
    /// sends this message when disabling the specified window.
    cancel_mode = WM.CANCELMODE,
    /// Sent to the window that is losing the mouse capture.
    capture_changed = WM.CAPTURECHANGED,
    /// Sent to the first window in the clipboard viewer chain
    /// when a window is being removed from the chain.
    change_clipboard_chain = WM.CHANGECBCHAIN,
    /// An application sends this message to indicate
    /// that the user interface (UI) state should be changed.
    change_user_interface_state = WM.CHANGEUISTATE,
    /// Posted to the window with the keyboard focus
    /// when a `WM_KEYDOWN` message is translated
    /// by the `TranslateMessage` function.
    /// This message contains the character code
    /// of the key that was pressed.
    character = WM.CHAR,
    /// Sent by a list box with the `LBS_WANTKEYBOARDINPUT` style to its owner
    /// in response to a `WM_CHAR` message.
    character_to_item = WM.CHARTOITEM,
    /// Sent to a child window
    /// when the user clicks the window's title bar
    /// or when the window is activated, moved, or sized.
    child_activate = WM.CHILDACTIVATE,
    /// An application sends this message to an edit control or combo box
    /// to delete (clear) the current selection, if any, from the edit control.
    clear = WM.CLEAR,
    /// Sent as a signal that the window or an application should terminate.
    close = WM.CLOSE,
    /// Sent when the user selects a command item from a menu,
    /// when a control sends a notification message to its parent window,
    /// or when an accelerator keystroke is translated.
    command = WM.COMMAND,
    /// Sent to all top-level windows
    /// when the system detects more than 12.5 percent of system time
    /// over a 30- to 60- second interval
    /// is being spent compacting memory.
    /// This indicates that system memory is low.
    compacting = WM.COMPACTING,
    /// The system sends this message
    /// to determine the relative position of a new item
    /// in the sorted list of an owner-drawn combo box or list box.
    /// Whenever the application adds a new item,
    /// the system sends this message to the owner of a combo box or list box
    /// created with the `CBS_SORT` or `LBS_SORT` style.
    compare_item = WM.COMPAREITEM,
    /// Notifies a window that the user clicked the right mouse button
    /// (right-clicked) in the window.
    context_menu = WM.CONTEXTMENU,
    /// An application sends this message to an edit control or combo box
    /// to copy the current selection to the clipboard in `CF_TEXT` format.
    copy = WM.COPY,
    /// An application sends this message to pass data to another application.
    copy_data = WM.COPYDATA,
    /// Sent when an application requests that a window be created
    /// by calling the `CreateWindowEx` or `CreateWindow` function.
    /// (The message is sent before the function returns.)
    /// The window procedure of the new window receives this message
    /// after the window is created, but before the window becomes visible.
    create = WM.CREATE,
    /// Sent to the parent window of a button before drawing the button.
    /// The parent window can change the button's text and background colors.
    /// However, only owner-drawn buttons respond
    /// to the parent window processing this message.
    control_color_button = WM.CTLCOLORBTN,
    /// Sent to a dialog box before the system draws the dialog box.
    /// By responding to this message,
    /// the dialog box can set its text and background colors
    /// using the specified display device context handle.
    control_color_dialog = WM.CTLCOLORDLG,
    /// An edit control that is not-read only or disabled
    /// sends this message to its parent window
    /// when the control is about to be drawn.
    /// By responding to this message,
    /// the parent window can use the specified device context handle
    /// to set the text and background colors of the edit control.
    control_color_edit = WM.CTLCOLOREDIT,
    /// Sent to the parent window of a list box
    /// before the system draws the list box.
    /// By responding to this message, the parent window
    /// can set the text and background colors of the list box
    /// by using the specified display device context handle.
    control_color_list_box = WM.CTLCOLORLISTBOX,
    /// Sent to the owner window of a message box
    /// before Windows draws the message box.
    /// By responding to this message, the owner window
    /// can set the text and background colors of the message box
    /// by using the given display device context handle.
    control_color_message_box = WM.CTLCOLORMSGBOX,
    /// Sent to the parent window of a scroll bar control
    /// when the control is about to be drawn.
    /// By responding to this message,
    /// the parent window can use the display context handle
    /// to set the background color of the scroll bar control.
    control_color_scroll_bar = WM.CTLCOLORSCROLLBAR,
    /// A static control, or an edit control that is read-only or disabled,
    /// sends this message to its parent window
    /// when the control is about to be drawn.
    /// By responding to this message,
    /// the parent window can use the specified device context handle
    /// to set the text and background colors of the static control.
    control_color_static = WM.CTLCOLORSTATIC,
    /// An application sends this message to an edit control or combo box
    /// to delete (cut) the current selection, if any, in the edit control
    /// and copy the deleted text to the clipboard in `CF_TEXT` format.
    cut = WM.CUT,
    /// Posted to the window with the keyboard focus
    /// when a `WM_KEYUP` message is translated
    /// by the `TranslateMessage` function.
    /// It specifies a character code generated by a dead key.
    ///
    /// A dead key is a key that generates a character,
    /// such as the umlaut (double-dot),
    /// that is combined with another character to form a composite character.
    ///
    /// For example, the umlaut-O character (Ö) is generated
    /// by typing the dead key for the umlaut character,
    /// and then typing the O key.
    dead_character = WM.DEADCHAR,
    /// Sent to the owner of a list box or combo box
    /// when the list box or combo box is destroyed
    /// or when items are removed by the
    /// `LB_DELETESTRING`, `LB_RESETCONTENT`, or `CB_RESETCONTENT` message.
    /// The system sends a `WM_DELETEITEM` for each deleted item.
    /// The systems sends the message for any deleted list box or combo box
    /// with nonzero item data.
    delete_item = WM.DELETEITEM,
    /// Sent when a window is being destroyed.
    /// It is sent to the window procedure of the window being destroyed
    /// after the window is removed from the screen.
    /// This message is sent first to the window being destroyed
    /// and then to the child windows (if any) as they are destroyed.
    /// During the processing of the message,
    /// it can be assumed that all child windows still exist.
    destroy = WM.DESTROY,
    /// Sent to the clipboard owner
    /// when a call to the `EmptyClipboard` function empties the clipboard.
    destroy_clipboard = WM.DESTROYCLIPBOARD,
    /// Notifies an application
    /// of a change to the hardware configuration of a device or the computer.
    device_change = WM.DEVICECHANGE,
    /// Sent to all top-level windows
    /// whenever the user changes device-mode settings.
    device_mode_change = WM.DEVMODECHANGE,
    /// Sent to all windows when the display resolution has changed.
    display_change = WM.DISPLAYCHANGE,
    /// Sent to the first window in the clipboard viewer chain
    /// when the content of the clipboard changes.
    /// This enables a clipboard viewer window
    /// to display the new content of the clipboard.
    draw_clipboard = WM.DRAWCLIPBOARD,
    /// Sent to the parent window
    /// of an owner-drawn button, combo box, list box, or menu
    /// when a visual aspect of the button, combo box, list box, or menu
    /// has changed.
    draw_item = WM.DRAWITEM,
    /// Sent when the user drops a file on the window of an application
    /// that has registered itself as a recipient of dropped files.
    drop_files = WM.DROPFILES,
    /// Sent when an application changes the enabled state of a window.
    /// It is sent to the window whose enabled state is changing.
    /// This message is sent before the `EnableWindow` function returns,
    /// but after the enabled state (`WS_DISABLED` style bit)
    /// of the window has changed.
    enable = WM.ENABLE,
    /// Sent to an application after the system processes the results
    /// of the `WM_QUERYENDSESSION` message.
    /// This message informs the application whether the session is ending.
    end_session = WM.ENDSESSION,
    /// Sent to the owner of a modal dialog box or menu
    /// that is entering an idle state.
    /// A modal dialog box or menu enters an idle state
    /// when no messages are waiting in its queue
    /// after it has processed one or more previous messages.
    enter_idle = WM.ENTERIDLE,
    /// Informs an application's main window procedure
    /// that a menu modal loop has been entered.
    enter_menu_loop = WM.ENTERMENULOOP,
    /// Sent one time to a window
    /// after it enters the moving or sizing modal loop.
    /// The window enters the moving or sizing modal loop
    /// when the user clicks the window's title bar or sizing border,
    /// or when the window passes the `WM_SYSCOMMAND` message
    /// to the `DefWindowProc` function and the `wParam` parameter
    /// of the message specifies the `SC_MOVE` or `SC_SIZE` value.
    /// The operation is complete when `DefWindowProc` returns.
    enter_size_move = WM.ENTERSIZEMOVE,
    /// Sent when the window background must be erased
    /// (for example, when a window is resized).
    /// The message is sent
    /// to prepare an invalidated portion of a window for painting.
    erase_background = WM.ERASEBKGND,
    /// Informs an application's main window procedure
    /// that a menu modal loop has been exited.
    exit_menu_loop = WM.EXITMENULOOP,
    /// Sent one time to a window,
    /// after it has exited the moving or sizing modal loop.
    /// The window enters the moving or sizing modal loop
    /// when the user clicks the window's title bar or sizing border,
    /// or when the window passes the `WM_SYSCOMMAND` message
    /// to the `DefWindowProc` function and the `wParam` parameter
    /// of the message specifies the `SC_MOVE` or `SC_SIZE` value.
    /// The operation is complete when `DefWindowProc` returns.
    exit_size_move = WM.EXITSIZEMOVE,
    /// An application sends this to all top-level windows in the system
    /// after changing the pool of font resources.
    font_change = WM.FONTCHANGE,
    /// Sent to the window procedure associated with a control.
    /// By default, the system handles all keyboard input to the control;
    /// the system interprets certain types of keyboard input
    /// as dialog box navigation keys.
    /// To override this default behavior,
    /// the control can respond to this message
    /// to indicate the types of input it wants to process itself.
    get_dialog_code = WM.GETDLGCODE,
    /// An application sends this message to a control to retrieve
    /// the font with which the control is currently drawing its text.
    get_font = WM.GETFONT,
    /// An application sends this message to determine
    /// the hot key associated with a window.
    get_hot_key = WM.GETHOTKEY,
    /// Sent to a window to retrieve a handle to the large or small icon
    /// associated with a window.
    /// The system displays the large icon in the ALT+TAB dialog,
    /// and the small icon in the window caption.
    get_icon = WM.GETICON,
    /// Sent to a window when the size or position of the window
    /// is about to change. An application can use this message
    /// to override the window's default maximized size and position,
    /// or its default minimum or maximum tracking size.
    get_min_max_info = WM.GETMINMAXINFO,
    /// Active Accessibility sends this message to obtain information
    /// about an accessible object contained in a server application.
    /// Applications never send this message directly.
    /// It is sent only by Active Accessibility in response to
    /// calls to `AccessibleObjectFromPoint`,
    /// `AccessibleObjectFromEvent`,
    /// or `AccessibleObjectFromWindow`.
    /// However, server applications handle this message.
    get_object = WM.GETOBJECT,
    /// An application sends this message
    /// to copy the text that corresponds to a window
    /// into a buffer provided by the caller.
    get_text = WM.GETTEXT,
    /// An application sends this message to determine
    /// the length, in characters, of the text associated with a window.
    get_text_length = WM.GETTEXTLENGTH,
    handheld_first = WM.HANDHELDFIRST,
    handheld_last = WM.HANDHELDLAST,
    /// Indicates that the user pressed the F1 key.
    /// If a menu is active when F1 is pressed,
    /// this message is sent to the window associated with the menu;
    /// otherwise, it is sent to the window that has the keyboard focus.
    /// If no window has the keyboard focus,
    /// it is send to the currently active window.
    help = WM.HELP,
    /// Posted when the user presses a hot key
    /// registered by the `RegisterHotKey` function.
    /// The message is placed at the top of the message queue
    /// associated with the thread that registered the hot key.
    hot_key = WM.HOTKEY,
    /// Sent to a window when a scroll event occurs
    /// in the window's standard horizontal scroll bar.
    /// This message is also sent to
    /// the owner of a horizontal scroll bar control
    /// when a scroll event occurs in the control.
    horizontal_scroll = WM.HSCROLL,
    /// Sent to the clipboard owner by a clipboard viewer window. This occurs
    /// when the clipboard contains data in the `CF_OWNERDISPLAY` format
    /// and an event occurs in the clipboard viewer's horizontal scroll bar.
    /// The owner should scroll the clipboard image
    /// and update the scroll bar values.
    horizontal_scroll_clipboard = WM.HSCROLLCLIPBOARD,
    /// Windows NT 3.51 and earlier:
    /// This message is sent to a minimized window
    /// when the background of the icon must be filled
    /// before painting the icon.
    /// A window receives this message
    /// only if a class icon is defined for the window;
    /// otherwise, `WM_ERASEBKGND` is sent.
    /// This message is not sent by newer versions of Windows.
    icon_erase_background = WM.ICONERASEBKGND,
    /// Sent to an application when the IME gets
    /// a character of the conversion result.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_character = WM.IME.CHAR,
    /// Sent to an application when the IME changes composition status
    /// as a result of a keystroke.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_composition = WM.IME.COMPOSITION,
    /// Sent to an application when the IME window finds no space
    /// to extend the area for the composition window.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_composition_full = WM.IME.COMPOSITIONFULL,
    /// Sent by an application
    /// to direct the IME window to carry out the requested command.
    /// The application uses this message
    /// to control the IME window that it has created.
    /// To send this message,
    /// the application calls the `SendMessage` function
    /// with the following parameters.
    input_method_editor_control = WM.IME.CONTROL,
    /// Sent to an application when the IME ends composition.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_end_composition = WM.IME.ENDCOMPOSITION,
    /// Sent to an application by the IME
    /// to notify the application of a key press and to keep message order.
    /// A window receieves this message through its `WindowProc` function.
    input_method_editor_key_down = WM.IME.KEYDOWN,
    input_method_editor_key_last = WM.IME.KEYLAST,
    /// Sent to an application by the IME
    /// to notify the application of a key release and to keep message order.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_key_up = WM.IME.KEYUP,
    /// Sent to an application to notify it of changes to the IME window.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_request = WM.IME.REQUEST,
    /// Sent to an application when
    /// the operating system is about to change the current IME.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_select = WM.IME.SELECT,
    /// Sent to an application when a window is activated.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_set_context = WM.IME.SETCONTEXT,
    /// Sent immediately before
    /// the IME generates the composition string as a result of a keystroke.
    /// A window receives this message through its `WindowProc` function.
    input_method_editor_start_composition = WM.IME.STARTCOMPOSITION,
    /// Sent to the dialog box procedure
    /// immediately before a dialog box is displayed.
    /// Dialog box procedures typically use this message
    /// to initialize controls and carry out any other initialization tasks
    /// that affect the appearance of the dialog box.
    initialize_dialog = WM.INITDIALOG,
    /// Sent when a menu is about to become active.
    /// It occurs when the user clicks an item on the menu bar
    /// or presses a menu key.
    /// This allows the application to modify the menu before it is displayed.
    initialize_menu = WM.INITMENU,
    /// Sent when a drop-down menu or submenu is about to become active.
    /// This allows an application to modify the menu before it is displayed,
    /// without changing the entire menu.
    initialize_menu_popup = WM.INITMENUPOPUP,
    /// Sent to the topmost affected window
    /// after an application's input language has been changed.
    /// You should make any application-specific settings
    /// and pass the message to the `DefWindowProc` function,
    /// which passes the message to all first-level child windows.
    /// These child windows can pass the message to `DefWindowProc`
    /// to have it pass the message to their child windows, and so on.
    input_language_changed = WM.INPUTLANGCHANGE,
    /// Posted to the window with the focus
    /// when the user chooses a new input language, either with the hotkey
    /// (specified in the Keyboard control panel application)
    /// or from the indicator on the system taskbar.
    /// An application can accept the change
    /// by passing the message to the `DefWindowProc` function
    /// or reject the change (and prevent it from taking place)
    /// by returning immediately.
    input_language_change_request = WM.INPUTLANGCHANGEREQUEST,
    /// Posted to the window with the keyboard focus
    /// when a nonsystem key is pressed. A nonsystem is key
    /// a key that is pressed when the ALT key is not pressed.
    key_down = WM.KEYDOWN,
    /// This message filters for keyboard messages.
    key_first = WM.KEYFIRST,
    /// This message filters for keyboard messages.
    key_last = WM.KEYLAST,
    /// Posted to the window with the keyboard focus
    /// when a nonsystem key is released. A nonsystem key is
    /// a key that is pressed when the ALT key is not pressed,
    /// or a keyboard key that is pressed
    /// when a window has the keyboard focus.
    key_up = WM.KEYUP,
    /// Sent to a window immediately before it loses the keyboard focus.
    kill_focus = WM.KILLFOCUS,
    /// Posted when the user double-clicks the left mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    left_mouse_button_double_click = WM.LBUTTONDBLCLK,
    /// Posted when the user presses the left mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    left_mouse_button_down = WM.LBUTTONDOWN,
    /// Posted when the user releases the left mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    left_mouse_button_up = WM.LBUTTONUP,
    /// Posted when the user double-clicks the middle mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    middle_mouse_button_double_click = WM.MBUTTONDBLCLK,
    /// Posted when the user presses the middle mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    middle_mouse_button_down = WM.MBUTTONDOWN,
    /// Posted when the user releases the middle mouse button
    middle_mouse_button_up = WM.MBUTTONUP,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to instruct the client window
    /// to activate a different MDI child window.
    multiple_document_interface_activate = WM.MDIACTIVATE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to arrange all its child windows in a cascade format.
    multiple_document_interface_cascade = WM.MDICASCADE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to create an MDI child window.
    multiple_document_interface_create = WM.MDICREATE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to close an MDI child window.
    multiple_document_interface_destroy = WM.MDIDESTROY,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to retrieve the handle to the active MDI child window.
    multiple_document_interface_get_active = WM.MDIGETACTIVE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to arrange all minimized MDI child windows.
    /// It does not affect child windows that are not minimized.
    multiple_document_interface_icon_arrange = WM.MDIICONARRANGE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to maximize an MDI child window.
    /// The system resizes the child window
    /// to make its client area fill the client window.
    /// The system places the child window's window menu icon
    /// in the rightmost position of the frame window's menu bar,
    /// and places the child window's restore icon in the leftmost position.
    /// The system also appends the title bar text of the child window
    /// to that of the frame window.
    multiple_document_interface_maximize = WM.MDIMAXIMIZE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to activate the next or previous child window.
    multiple_document_interface_next = WM.MDINEXT,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to refresh the window menu of the MDI frame window.
    multiple_document_interface_refresh_menu = WM.MDIREFRESHMENU,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to restore an MDI child window from maximized or minimized size.
    multiple_document_interface_restore = WM.MDIRESTORE,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to replace the entire menu of an MDI frame window,
    /// to replace the window menu of the frame window,
    /// or both.
    multiple_document_interface_set_menu = WM.MDISETMENU,
    /// An application sends this message
    /// to a multiple-document interface (MDI) client window
    /// to arrange all of its MDI child windows in a tile format.
    multiple_document_interface_tile = WM.MDITILE,
    /// This message is sent to the owner window
    /// of a combo box, list box, list view control, or menu item
    /// when the control or menu is created.
    measure_item = WM.MEASUREITEM,
    /// Sent whena menu is active an the user presses a key
    /// that does not correspond to any mnemonic or accelerator key.
    /// This message is sent to the window that owns the menu.
    menu_character = WM.MENUCHAR,
    /// Sent when the user makes a selection from a menu.
    menu_command = WM.MENUCOMMAND,
    /// Sent to the owner of a drag-and-drop menu
    /// when the user drags a menu item.
    menu_drag = WM.MENUDRAG,
    /// Sent to the owner of a drag-and-drop menu
    /// when the mouse cursor enters a menu item
    /// or moves from the center of the item
    /// to the top or bottom of the item.
    menu_get_object = WM.MENUGETOBJECT,
    /// Sent when the user releases the right mouse button
    /// while the cursor is on a menu item.
    menu_right_mouse_button_up = WM.MENURBUTTONUP,
    /// Sent to a menu's owner window hen the user selects a menu item.
    menu_select = WM.MENUSELECT,
    /// Sent when the cursor is in an inactive window
    /// and the user presses a mouse button.
    /// The parent window receives this message
    /// only if the child window passes it to the `DefWindowProc` function.
    mouse_activate = WM.MOUSEACTIVATE,
    /// Use this message to specify the first mouse message.
    /// Use the `PeekMessage()` Function.
    mouse_first = WM.MOUSEFIRST,
    /// Posted to a window
    /// when the cursor hovers over the client area of the window
    /// for the period of time specified in a prior call to `TrackMouseEvent`.
    mouse_hover = WM.MOUSEHOVER,
    mouse_last = WM.MOUSELAST,
    /// Posted to a window
    /// when the cursor leaves the client area of the window
    /// specified in a prior call to `TrackMouseEvent`.
    mouse_leave = WM.MOUSELEAVE,
    /// Posted to a window
    /// when the cursor moves.
    /// If the mouse is not captured,
    /// the message is posted to the window that contains the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    mouse_move = WM.MOUSEMOVE,
    /// Sent to the focus window when the mouse wheel is rotated.
    /// The `DefWindowProc` function propagates the message
    /// to the window's parent.
    /// There should be no internal forwarding of the message,
    /// since `DefWindowProc` propagates it up the parent chain
    /// until it finds a window that processes it.
    mouse_wheel = WM.MOUSEWHEEL,
    /// Sent to the focus window
    /// when the mouse's horizontal scroll wheel is tilted or rotated.
    /// The `DefWindowProc` function propagates the message
    /// to the window's parent.
    /// There should be no forwarding of the message,
    /// since `DefWindowProc` propagates it up the parent chain
    /// until it finds a window that processes it.
    mouse_horizontal_wheel = WM.MOUSEHWHEEL,
    /// Sent after a window has been moved.
    move = WM.MOVE,
    /// Sent to a window that the user is moving.
    /// By processing this messsage,
    /// an application can monitor the position of the drag rectangle
    /// and, if needed, change its position.
    moving = WM.MOVING,
    /// Non Client Area Activated
    /// Caption(Title) of the Form
    nonclient_activate = WM.NCACTIVATE,
    /// Sent when
    /// the size and position of a window's client area must be calculated.
    /// By processing this message,
    /// an application can control the content of the window's client area
    /// when the size or position of the window changes.
    nonclient_calculate_size = WM.NCCALCSIZE,
    /// Sent prior to the `WM_CREATE` message
    /// when a window is first created.
    nonclient_create = WM.NCCREATE,
    /// Informs a window that its nonclient area is being destroyed.
    /// The `DestroyWindow` function sends this message to the window
    /// following the `WM_DESTROY` message. `WM_DESTROY` is used
    /// to free the allocated memory object associated with the window.
    nonclient_destroy = WM.NCDESTROY,
    /// Sent to a window when the cursor moves,
    /// or when a mouse button is pressed or released.
    /// If the mouse is not captured,
    /// the message is sent to the window beneath the cursor.
    /// Otherwise, the message is sent
    /// to the window that has captured the mouse.
    nonclient_hit_test = WM.NCHITTEST,
    /// Posted when the user double-clicks the left mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_left_mouse_button_double_click = WM.NCLBUTTONDBLCLK,
    /// Posted when the user presses the left mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_left_mouse_button_down = WM.NCLBUTTONDOWN,
    /// Posted when the user releases the left mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_left_mouse_button_up = WM.NCLBUTTONUP,
    /// Posted when the user double-clicks the middle mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_middle_mouse_button_double_click = WM.NCMBUTTONDBLCLK,
    /// Posted when the user presses the middle mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_middle_mouse_button_down = WM.NCMBUTTONDOWN,
    /// Posted when the user releases the middle mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_middle_mouse_button_up = WM.NCMBUTTONUP,
    /// Posted to a window
    /// when the cursor hovers over the nonclient area of the window
    /// for the period of time specified in a prior call to `TrackMouseEvent`.
    nonclient_mouse_hover = WM.NCMOUSEHOVER,
    /// Posted to a window
    /// when the cursor hovers over the nonclient area of the window
    /// specified in a prior call to `TrackMouseEvent`.
    nonclient_mouse_leave = WM.NCMOUSELEAVE,
    /// Posted to a window
    /// when the cursor is moved within the nonclient area of the window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse,
    /// this message is not posted.
    nonclient_mouse_move = WM.NCMOUSEMOVE,
    /// Sent to a window when its frame must be painted.
    nonclient_paint = WM.NCPAINT,
    /// Posted when the user double-clicks the right mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse,
    /// this message is not posted.
    nonclient_right_mouse_button_double_click = WM.NCRBUTTONDBLCLK,
    /// Posted when the user presses the right mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse,
    /// this message is not posted.
    nonclient_right_mouse_button_down = WM.NCRBUTTONDOWN,
    /// Posted when the user releases the right mouse button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_right_mouse_button_up = WM.NCRBUTTONUP,
    /// Posted when the user double-clicks the first or second X button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_x_button_double_click = WM.NCXBUTTONDBLCLK,
    /// Posted when the user presses the first or second X button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_x_button_down = WM.NCXBUTTONDOWN,
    /// Posted when the user releases the first or second X button
    /// while the cursor is within the nonclient area of a window.
    /// This message is posted to the window that contains the cursor.
    /// If a window has captured the mouse, this message is not posted.
    nonclient_x_button_up = WM.NCXBUTTONUP,
    /// An undocumented message related to themes.
    /// When handling `WM_NCPAINT`, this message should also be handled.
    nonclient_uah_draw_caption = WM.NCUAHDRAWCAPTION, // TODO what does UAH stand for
    /// An undocumented message related to themes.
    /// When handling `WM_NCPAINT`, this message should also be handled.
    nonclient_uah_draw_frame = WM.NCUAHDRAWFRAME,
    /// Sent to a dialog box procedure
    /// to set the keyboard focus to a different control in the dialog box.
    next_dialog_control = WM.NEXTDLGCTL,
    /// Sent to an application when the right or left arrow key
    /// is used to switch between the menu bar and the system menu.
    next_menu = WM.NEXTMENU,
    /// Sent by a common control to its parent window
    /// when an event has occurred or the control requires some information.
    notify = WM.NOTIFY,
    /// Determines if a window accepts ANSI or Unicode structures
    /// in the `WM_NOTIFY` notification message.
    /// `WM_NOTIFYFORMAT` messages are sent
    /// from a common control to its parent window
    /// and from the parent window to the common control.
    notify_format = WM.NOTIFYFORMAT,
    /// Performs no operation.
    /// An application sends this message if it wants to post a message
    /// that the recipient window will ignore.
    @"null" = WM.NULL,
    /// Occurs when the control needs repainting.
    paint = WM.PAINT,
    /// Sent to the clipboard owner by a clipboard viewer window
    /// when the clipboard contains data in the `CF_OWNERDISPLAY` format
    /// and the clipboard viewer's client area needs repainting.
    paint_clipboard = WM.PAINTCLIPBOARD,
    /// Windows NT 3.51 and earlier:
    /// This message is sent to a minimized window
    /// when the icon is to be painted.
    /// This message is not sent by newer versions of Microsoft Windows,
    /// except in unusual circumstances explained in the Remarks.
    paint_icon = WM.PAINTICON,
    /// This message is sent by the OS to all top-level and overlapped windows
    /// after th window with the keyboard focus realizes its logical palette.
    /// This message enables windows that do not have the keyboard focus
    /// to realize their logicla palettes and update their client areas.
    palette_changed = WM.PALETTECHANGED,
    /// This message informs applications
    /// that an application is going to realize its logical palette.
    palette_is_changing = WM.PALETTEISCHANGING,
    /// Sent to the parent of a child window
    /// when the child window is created or destroyed,
    /// or when the user clicks a mouse button
    /// while the cursor is over the child window.
    /// When the child window is being created, the system sends this message
    /// just before the `CreateWindow` or `CreateWindowEx` function
    /// that creates the window returns.
    /// When the child window is being destroyed, the system sends the message
    /// before any processing to destroy the window takes place.
    parent_notify = WM.PARENTNOTIFY,
    /// An application sends this message
    /// to an edit control or combo box
    /// to copy the current content of the clipboard
    /// to the edit control at the current caret position.
    /// Data is inserted only if
    /// the clipboard contains data in `CF_TEXT` format.
    paste = WM.PASTE,
    pen_window_first = WM.PENWINFIRST,
    pen_window_last = WM.PENWINLAST,
    /// Notifies applications that the system,
    /// typically a battery-powered personal computer,
    /// is about to enter a suspended mode.
    /// Obsolete : use `POWERBROADCAST` instead
    power = WM.POWER,
    /// Notifies applications that a power-management event has occurred.
    power_broadcast = WM.POWERBROADCAST,
    /// Sent to a window to request
    /// that is draw itself in the specified device context,
    /// most commonly in a printer device context.
    print = WM.PRINT,
    /// Sent to a window to request that it draw its client area
    /// in the specified device context,
    /// most commonly in a printer device context.
    print_client = WM.PRINTCLIENT,
    /// Sent to a minimized (iconic) window.
    /// The window is about to be dragged by the user
    /// but does not have an icon defined for its class.
    /// An application can return a handle to an icon or cursor.
    /// The system displays this cursor or icon while the user drags the icon.
    query_drag_icon = WM.QUERYDRAGICON,
    /// Sent when the user chooses to end the session
    /// or when an application calls one of the system shutdown functions.
    /// If any application returns zero, the session is not ended.
    /// The system stops sending `WM_QUERYENDSESSION` messages
    /// as soon as one application returns zero.
    /// After processing this message,
    /// the system sends the `WM_ENDSESSION` message
    /// with the `wParam` parameter set to
    /// the results of the `WM_QUERYENDSESSION` message.
    query_end_session = WM.QUERYENDSESSION,
    /// This message informs a window
    /// that it is about to receive the keyboard focus,
    /// giving the window the opportunity to realize its logical palette
    /// when it receives the focus.
    query_new_palette = WM.QUERYNEWPALETTE,
    /// Sent to an icon when the user requests
    /// that the window be restored to its previous size and position.
    query_open = WM.QUERYOPEN,
    /// Sent by a computer-based training (CBT) application
    /// to separate user-input messages from other messages
    /// sent through the `WM_JOURNALPLAYBACK` Hook procedure.
    queue_sync = WM.QUERYSYNC,
    /// Once received, it ends the application's Message Loop,
    /// signaling the application to end.
    /// It can be sent by pressing Alt+F4,
    /// Clicking the X in the upper right-hand of the program,
    /// or going to File->Exit.
    quit = WM.QUIT,
    /// Posted when the user double-clicks the right mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    right_mouse_button_double_click = WM.RBUTTONDBLCLK,
    /// Posted when the user presses the right mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    right_mouse_button_down = WM.RBUTTONDOWN,
    /// Posted when the user releases the right mouse button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    right_mouse_button_up = WM.RBUTTONUP,
    /// Sent to the clipboard owner before it is destroyed,
    /// if the clipboard owner has delayed
    /// rendering one or more clipboard formats.
    ///
    /// For the content of the clipboard
    /// to remain available to other applications,
    /// the clipboard owner must render data in all the formats
    /// it is capable of generating,
    /// and place the data on the clipboard
    /// by calling the `SetClipboardData` function.
    render_all_formats = WM.RENDERALLFORMATS,
    /// Sent to the clipboard owner
    /// if it has delayed rendering a specific clipboard format
    /// and if an application has requested data in that format.
    /// The clipboard owner must render data in the specified format
    /// and place it on the clipboard
    /// by calling the `SetClipboardData` function.
    render_format = WM.RENDERFORMAT,
    /// Sent to a window
    /// if the mouse causes the cursor to move within a window
    /// and mouse input is not captured.
    set_cursor = WM.SETCURSOR,
    /// Sent to a window when it gains keyboard focus.
    set_focus = WM.SETFOCUS,
    /// An application sends this message
    /// to specify the font that a control is to use when drawing text.
    set_font = WM.SETFONT,
    /// An application sends this message to a window
    /// to associate a hot key with the window.
    /// When the user presses the hot key,
    /// the system activates the window.
    set_hot_key = WM.SETHOTKEY,
    /// An application sends this message
    /// to associate a new large or small icon with a window.
    /// The system displays the large icon in the ALT+TAB dialog box,
    /// and the small icon in the window caption.
    set_icon = WM.SETICON,
    /// An application sends this message to a window
    /// to allow changes in that window to be redrawn
    /// or to prevent changes in that window from being redrawn.
    set_redraw = WM.SETREDRAW,
    /// Text / Caption changed on the control.
    /// An application sends this message to set the text of a window.
    set_text = WM.SETTEXT,
    /// An application sends this message to all top-level windows
    /// after making a change to the `WIN.INI` file.
    /// The `SystemParametersInfo` function sends this message after
    /// an application uses the function to change a setting in `WIN.INI`.
    setting_change = WM.SETTINGCHANGE,
    /// Sent to a window when the window is about to be hidden or shown.
    show_window = WM.SHOWWINDOW,
    /// Sent to a window after its size has changed.
    size = WM.SIZE,
    /// Sent to the clipboard owner by a clipboard viewer window
    /// when the clipboard contains data in the `CF_OWNERDISPLAY` format
    /// and the clipboard viewer's client area has changed size.
    size_clipboard = WM.SIZECLIPBOARD,
    /// Sent to a window that the user is resizing.
    /// By processing this message,
    /// an application can monitor the size and position of the drag rectangle
    /// and, if needed, change its size or position.
    sizing = WM.SIZING,
    /// Sent from Print Manager
    /// whenever a job is added to or removed from the Print Manager queue.
    spooler_status = WM.SPOOLERSTATUS,
    /// Sent to a window after the `SetWindowLong` function
    /// has changed one or more of the window's styles.
    style_changed = WM.STYLECHANGED,
    /// Sent to a window when the `SetWindowLong` function
    /// is about to change one or more of the window's styles.
    style_changing = WM.STYLECHANGING,
    /// Used to synchronize painting
    /// while avoiding linking independent GUI threads.
    sync_paint = WM.SYNCPAINT,
    /// Posted to the window with the keyboard focus
    /// when a `WM_SYSKEYDOWN` message is translated
    /// by the `TranslateMessage` function.
    /// It specifies the character code of a system character key
    /// — that is, a character key that is pressed while the ALT key is down.
    system_character = WM.SYSCHAR,
    /// Sent to all top-level windows
    /// when a change is made to a system color setting.
    system_color_change = WM.SYSCOLORCHANGE,
    /// A window receives this message
    /// when the user chooses a command from the Window menu
    /// (formerly known as the system or control menu)
    /// or when the user chooses
    /// the maximize button, minimize button, restore button, or close button.
    system_command = WM.SYSCOMMAND,
    /// Sent to the window when a `WM_SYSKEYDOWN` message
    /// is translated by the `TranslateMessage` function.
    /// This message specifies the character code of a system dead key
    /// — that is, a dead key that is pressed while holding down the ALT key.
    system_dead_character = WM.SYSDEADCHAR,
    /// Posted to the window with the keyboard focus
    /// when the user presses the F10 key (which activates the menu bar)
    /// or holds down the ALT key and then presses another key.
    /// It also occurs when no window currently has the keyboard focus;
    /// in this case, this message is sent to the active window.
    /// The window that receives the message can distinguish between these
    /// two contexts by checking the context code in the `lParam` parameter.
    system_key_down = WM.SYSKEYDOWN,
    /// Posted to the window with the keyboard focus
    /// when the user releases a key that was pressed
    /// while the ALT key was held down.
    /// It also occurs when no window currently has the keyboard focus;
    /// in this case, the message is sent to the active window.
    /// The window that receives the message can distinguish between these
    /// two contexts by checking the context code in the `lParam` parameter.
    system_key_up = WM.SYSKEYUP,
    /// Sent to an application that has initiated
    /// a training card with Microsoft Windows Help.
    /// The message informs the application
    /// when the user clicks an authorable button.
    /// An application initiates a training card
    /// by specifying the `HELP_TCARD` command
    /// in a call to the `WinHelp` function.
    training_card = WM.TCARD,
    /// A message that is sent whenever there is a change in the system time.
    time_change = WM.TIMECHANGE,
    /// Posted to the installing thread's message queue when a timer expires.
    /// The message is posted by the `GetMessage` or `PeekMessage` function.
    timer = WM.TIMER,
    /// An application sends this message to an edit control
    /// to undo the last operation.
    /// When this message is sent to an edit control,
    /// the previously deleted text is restored
    /// or the previously added text is deleted.
    undo = WM.UNDO,
    /// Sent when a drop-down menu or submenu has been destroyed.
    uninit_menu_popup = WM.UNINITMENUPOPUP,
    /// Used by applications to help define private messages
    /// for use by private window classes,
    /// usually of the form `WM_USER+X`, where `X` is an integer value.
    user = WM.USER,
    /// Sent to all windows after the user has logged on or off.
    /// When the user logs on or off,
    /// the system updates the user-specific settings.
    /// The system sends this message immediately after updating the settings.
    user_changed = WM.USERCHANGED,
    /// Sent by a list box with the `LBS_WANTKEYBOARDINPUT` style
    /// to its owner in response to a `WM_KEYDOWN` message.
    virtual_key_to_item = WM.VKEYTOITEM,
    /// Sent to a window when a scroll event occurs
    /// in the window's standard vertical scroll bar.
    /// This message is also sent to the owner of a vertical scroll bar control
    /// when a scroll event occurs in the control.
    virtual_scroll = WM.VSCROLL,
    /// Sent to the clipboard owner by a clipboard viewer window
    /// when the clipboard contains data in the `CF_OWNERDISPLAY` format
    /// and an event occurs in the clipboard viewer's vertical scroll bar.
    /// The owner should scroll the clipboard image
    /// and update the scroll bar values.
    virtual_scroll_clipboard = WM.VSCROLLCLIPBOARD,
    /// Sent to a window whose size, position, or place in the Z order
    /// has changed as the result of a call to the `SetwindowPos` function
    /// or another window-management function.
    window_position_changed = WM.WINDOWPOSCHANGED,
    /// Sent to a window whose size, position, or place in the Z order
    /// is about to change as a result of a call to the `SetWindowPos` function
    /// or another window-management function.
    window_position_changing = WM.WINDOWPOSCHANGING,
    /// An application sends this message to all top-level windows
    /// after making a change to the `WIN.INI` file.
    /// The `SystemParametersInfo` function sends this message
    /// after an application uses the function
    /// to change a setting in `WIN.INI`.
    ///
    /// Note: this message is provided only
    /// for compatibility with earlier versions of the system.
    /// Applications should use the `WM_SETTINGCHANGE` message.
    win_ini_change = WM.WININICHANGE,
    /// Posted when the user double-clicks the first or second X button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    x_button_double_click = WM.XBUTTONDBLCLK,
    /// Posted when the user presses the first or second X button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Other wise, the message is posted
    /// to the window that has captured the mouse.
    x_button_down = WM.XBUTTONDOWN,
    /// Posted when the user releases the first or second X button
    /// while the cursor is in the client area of a window.
    /// If the mouse is not captured,
    /// the message is posted to the window beneath the cursor.
    /// Otherwise, the message is posted
    /// to the window that has captured the mouse.
    x_button_up = WM.XBUTTONUP,
    _,
};

pub const WindowClassStyle = packed struct(UINT) {
    /// Redraws the entire window
    /// if a movement or size adjustment changes the height of the client area.
    vertical_redraw: bool = false,
    /// Redraws the entire window
    /// if a movement or size adjustment changes the width of the client area.
    horizontal_redraw: bool = false,
    _unused_0: u1 = 0,
    /// Sends a double-click message to the window procedure
    /// when the user double-clicks the mouse
    /// while the cursor is within a window belonging to the class.
    double_clicks: bool = false,
    _unused_1: u1 = 0,
    device_context: DeviceContext = .none,
    _unused_2: u1 = 0,
    /// Disables __Close__ on the window menu.
    no_close: bool = false,
    _unused_3: u1 = 0,
    /// Saves, as a bitmap,
    /// the portion of the screen image obscured by a window of this class.
    /// When the window is removed,
    /// the system uses the saved bitmap to restore the screen image,
    /// including other windows that were obscured.
    /// Therefore, the system does not send `Paint` messages
    /// to windows that were obscured
    /// if the memory used by the bitmap has not been discarded
    /// and if other screen actions have not invalidated the stored image.
    ///
    /// This style is useful for small windows
    /// (for example, menus or dialog boxes)
    /// that are displayed briefly and then removed
    /// before other screen activity takes place.
    /// This style increases the time required to display the window,
    /// because the system must first allocate memory to store the bitmap.
    save_bits: bool = false,
    /// Aligns the window's client area on a byte boundary (in the x direction).
    /// This style affects the width of the window
    /// and its horizontal placement on the display.
    byte_align_client: bool = false,
    /// Aligns the window on a byte boundary (in the x direction).
    /// This style affects the width of the window
    /// and its horizontal placement on the display.
    byte_align_window: bool = false,
    /// Indicates that the window class is an application global class.
    global_class: bool = false,
    _unused_4: u2 = 0,
    /// Enables the drop shadow effect on a window.
    /// The effect is turned on and off through `SPI_SETDROPSHADOW`.
    /// Typically, this is enabled for small, short-lived windows such as menus
    /// to emphasize their Z-order relationship to other windows.
    /// Windows created from a class with this style must be top-level windows;
    /// they may not be child windows.
    drop_shadow: bool = false,
    _padding: @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @bitSizeOf(UINT) - 18,
    }}) = 0,

    pub const DeviceContext = enum(u3) {
        /// No device context style is specified.
        none    = 0b000,
        /// Allocates a unique device context for each window in the class.
        own     = 0b001,
        /// Allocates one device context to be shared by all windows in the class.
        /// Because window classes are process specific,
        /// it is possible for multiple threads of an application
        /// to create a window of the same class.
        /// It is also possible for the threads to attempt to use
        /// the device context simultaneously.
        /// When this happens, the system allows only one thread
        /// to successfully finish its drawing operation.
        class   = 0b010,
        /// Sets the clipping rectangle of the child window to that of
        /// the parent window so that the child can draw on the parent.
        /// A window with this style bit receives a regular device context
        /// from the system's cache of device contexts.
        /// It does not give the child the parent's device context
        /// or device context settings.
        /// Specifying this bit enhances an application's performance.
        parent  = 0b100,
        _,
    };
};

test WindowClassStyle {
    try testing.expectEqual(
        @as(UINT, CS.VREDRAW), @as(UINT, @bitCast(WindowClassStyle{ .vertical_redraw = true })));
    try testing.expectEqual(
        @as(UINT, CS.HREDRAW), @as(UINT, @bitCast(WindowClassStyle{ .horizontal_redraw = true })));
    try testing.expectEqual(
        @as(UINT, CS.DBLCLKS), @as(UINT, @bitCast(WindowClassStyle{ .double_clicks = true })));
    try testing.expectEqual(
        @as(UINT, CS.OWNDC), @as(UINT, @bitCast(WindowClassStyle{ .device_context = .own })));
    try testing.expectEqual(
        @as(UINT, CS.CLASSDC), @as(UINT, @bitCast(WindowClassStyle{ .device_context = .class })));
    try testing.expectEqual(
        @as(UINT, CS.PARENTDC), @as(UINT, @bitCast(WindowClassStyle{ .device_context = .parent })));
    try testing.expectEqual(
        @as(UINT, CS.NOCLOSE), @as(UINT, @bitCast(WindowClassStyle{ .no_close = true })));
    try testing.expectEqual(
        @as(UINT, CS.SAVEBITS), @as(UINT, @bitCast(WindowClassStyle{ .save_bits = true })));
    try testing.expectEqual(
        @as(UINT, CS.BYTEALIGNCLIENT), @as(UINT, @bitCast(WindowClassStyle{ .byte_align_client = true })));
    try testing.expectEqual(
        @as(UINT, CS.BYTEALIGNWINDOW), @as(UINT, @bitCast(WindowClassStyle{ .byte_align_window = true })));
    try testing.expectEqual(
        @as(UINT, CS.GLOBALCLASS), @as(UINT, @bitCast(WindowClassStyle{ .global_class = true })));
    try testing.expectEqual(
        @as(UINT, CS.DROPSHADOW), @as(UINT, @bitCast(WindowClassStyle{ .drop_shadow = true })));
}

pub const WindowStyle = packed struct(u32) {
    _padding: u16 = 0,
    /// The window is a control
    /// that can receive the keyboard focus when the user presses the TAB key,
    /// or the window has a maximize button.
    maximize_box_or_tabstop: bool = false,
    /// The window is the first control of a group of controls,
    /// or the window has a minimize button.
    minimize_box_or_group: bool = false,
    /// The window has a sizing border (also called 'THICKFRAME').
    size_box: bool = false,
    /// The window has a window menu on its title bar.
    /// If this field is active, the `.frame` field must be `.caption`.
    system_menu: bool = false,
    /// The window has a horizontal scroll bar.
    horizontal_scroll: bool = false,
    /// The window has a vertical scroll bar.
    vertical_scroll: bool = false,
    frame: Frame = .none,
    /// The window is initially maximized.
    maximize: bool = false,
    /// Excludes the area occupied by child windows
    /// when drawing occurs within the parent window.
    /// This style is used when creating the parent window.
    clip_children: bool = false,
    /// Clips child windows relative to each other;
    /// that is, when a particular child window receives a PAINT message,
    /// this style clips all other overlapping child windows
    /// out of the region of the child window to be updated.
    ///
    /// If this style is not specified and child windows overlap,
    /// it is possible, when drawing within the client area of a child window,
    /// to draw within the client area of a neighboring child window.
    clip_siblings: bool = false,
    /// The window is initially disabled.
    /// A disabled window cannot receive input from the user.
    /// To change this after a window has been created,
    /// use the `EnableWindow` function.
    disabled: bool = false,
    /// The window is initially visible.
    /// This style can be turned on and off
    /// by using the `ShowWindow` or `SetWindowPos` function.
    visible: bool = false,
    /// The window is initially minimized.
    minimize: bool = false,
    /// The window is a child window.
    /// A window with this style cannot have a menu bar.
    /// This style cannot be used with the `.pop_up` style.
    child: bool = false,
    /// The window is a pop-up window.
    /// This style cannot be used with the `.child` style.
    pop_up: bool = false,

    pub const Frame = enum(u2) {
        none = 0b00,
        /// The window has a border of a style typically used with dialog boxes.
        dialog = 0b01,
        /// The window has a thin-line border.
        border = 0b10,
        /// The window has a thin-line border and a title bar.
        caption = 0b11,
    };

    /// An overlapped window with no additional styles
    /// (legacy name 'TILED').
    pub const overlapped = WindowStyle{};

    /// An overlapped window with default styles.
    pub const overlapped_window = WindowStyle{
        .frame = .caption,
        .system_menu = true,
        .size_box = true,
        .minimize_box_or_group = true,
        .maximize_box_or_tabstop = true,
    };

    /// A pop-up window.
    /// The .frame` field must be set to `.caption`
    /// to make the window menu visible.
    pub const pop_up_window = WindowStyle{
        .pop_up = true,
        .frame = .border,
        .system_menu = true,
    };
};

test WindowStyle {
    try testing.expectEqual(
        @as(u32, WS.OVERLAPPED), @as(u32, @bitCast(WindowStyle.overlapped)));
    try testing.expectEqual(
        @as(u32, WS.TILED), @as(u32, @bitCast(WindowStyle.overlapped)));
    try testing.expectEqual(
        @as(u32, WS.TABSTOP), @as(u32, @bitCast(WindowStyle{ .maximize_box_or_tabstop = true })));
    try testing.expectEqual(
        @as(u32, WS.MAXIMIZEBOX), @as(u32, @bitCast(WindowStyle{ .maximize_box_or_tabstop = true })));
    try testing.expectEqual(
        @as(u32, WS.GROUP), @as(u32, @bitCast(WindowStyle{ .minimize_box_or_group = true })));
    try testing.expectEqual(
        @as(u32, WS.MINIMIZEBOX), @as(u32, @bitCast(WindowStyle{ .minimize_box_or_group = true })));
    try testing.expectEqual(
        @as(u32, WS.SIZEBOX), @as(u32, @bitCast(WindowStyle{ .size_box = true })));
    try testing.expectEqual(
        @as(u32, WS.THICKFRAME), @as(u32, @bitCast(WindowStyle{ .size_box = true })));
    try testing.expectEqual(
        @as(u32, WS.SYSMENU), @as(u32, @bitCast(WindowStyle{ .system_menu = true })));
    try testing.expectEqual(
        @as(u32, WS.HSCROLL), @as(u32, @bitCast(WindowStyle{ .horizontal_scroll = true })));
    try testing.expectEqual(
        @as(u32, WS.VSCROLL), @as(u32, @bitCast(WindowStyle{ .vertical_scroll = true })));
    try testing.expectEqual(
        @as(u32, WS.DLGFRAME), @as(u32, @bitCast(WindowStyle{ .frame = .dialog })));
    try testing.expectEqual(
        @as(u32, WS.BORDER), @as(u32, @bitCast(WindowStyle{ .frame = .border })));
    try testing.expectEqual(
        @as(u32, WS.CAPTION), @as(u32, @bitCast(WindowStyle{ .frame = .caption })));
    try testing.expectEqual(
        @as(u32, WS.MAXIMIZE), @as(u32, @bitCast(WindowStyle{ .maximize = true })));
    try testing.expectEqual(
        @as(u32, WS.CLIPCHILDREN), @as(u32, @bitCast(WindowStyle{ .clip_children = true })));
    try testing.expectEqual(
        @as(u32, WS.CLIPSIBLINGS), @as(u32, @bitCast(WindowStyle{ .clip_siblings = true })));
    try testing.expectEqual(
        @as(u32, WS.DISABLED), @as(u32, @bitCast(WindowStyle{ .disabled = true })));
    try testing.expectEqual(
        @as(u32, WS.VISIBLE), @as(u32, @bitCast(WindowStyle{ .visible = true })));
    try testing.expectEqual(
        @as(u32, WS.ICONIC), @as(u32, @bitCast(WindowStyle{ .minimize = true })));
    try testing.expectEqual(
        @as(u32, WS.MINIMIZE), @as(u32, @bitCast(WindowStyle{ .minimize = true })));
    try testing.expectEqual(
        @as(u32, WS.CHILD), @as(u32, @bitCast(WindowStyle{ .child = true })));
    try testing.expectEqual(
        @as(u32, WS.CHILDWINDOW), @as(u32, @bitCast(WindowStyle{ .child = true })));
    try testing.expectEqual(
        @as(u32, WS.POPUP), @as(u32, @bitCast(WindowStyle{ .pop_up = true })));

    try testing.expectEqual(
        @as(u32, WS.OVERLAPPEDWINDOW), @as(u32, @bitCast(WindowStyle.overlapped_window)));
    try testing.expectEqual(
        @as(u32, WS.TILEDWINDOW), @as(u32, @bitCast(WindowStyle.overlapped_window)));
    try testing.expectEqual(
        @as(u32, WS.POPUPWINDOW), @as(u32, @bitCast(WindowStyle.pop_up_window)));
}

pub const WindowStyleExtended = packed struct(u32) {
    /// The window has a double border;
    /// the window can, optionally, be created with a title bar
    /// by specifying the `.caption` style in the style parameter.
    dialog_modal_frame: bool = false,
    _unused_0: u1 = 0,
    /// The child window created with this style
    /// does not send the `WM_PARENTNOTIFY` message to its parent window
    /// when it is created or destroyed.
    no_parent_notify: bool = false,
    /// The window should be placed above all non-topmost windows
    /// and should stay above them, even when the window is deactivated.
    /// To add or remove this style, use the `SetWindowPos` function.
    topmost: bool = false,
    /// The window accepts drag-drop files.
    accept_files: bool = false,
    /// The window should not be painted until siblings beneath the window
    /// (that were created by the same thread) have been painted.
    /// The window appears transparent because
    /// the bits of underlying sibling windows have already been painted.
    ///
    /// To achieve transparency without these restrictions, use the SetWindowRgn function.
    transparent: bool = false,
    /// The window is a MDI child window.
    multiple_document_interface_child: bool = false,
    /// The window is intended to be used as a floating toolbar.
    /// A tool window has a title bar that is shorter than a normal title bar,
    /// and the window title is drawn using a smaller font.
    /// A tool window does not appear in the taskbar
    /// or in the dialog that appears when the user presses ALT+TAB.
    /// If a tool window has a system menu,
    /// its icon is not displayed on the title bar.
    /// However, you can display the system menu
    /// by right-clicking or by typing ALT+SPACE.
    tool_window: bool = false,
    /// The window has a border with a raised edge.
    window_edge: bool = false,
    /// The window has a border with a sunken edge.
    client_edge: bool = false,
    /// The title bar of the window includes a question mark.
    /// When the user clicks the question mark,
    /// the cursor changes to a question mark with a pointer.
    /// If the user then clicks a child window,
    /// the child receives a `WM_HELP` message.
    /// The child window should pass the message to the parent window procedure,
    /// which should call the `WinHelp` function
    /// using the `HELP_WM_HELP` command.
    /// The Help application displays a pop-up window
    /// that typically contains help for the child window.
    ///
    /// This style cannot be used with the 'MAXIMIZEBOX' or 'MINIMIZEBOX' styles.
    context_help: bool = false,
    _unused_1: u1 = 0,
    /// The window has generic "right-aligned" properties.
    /// This depends on the window class.
    /// This style has an effect
    /// only if the shell language is Hebrew, Arabic,
    /// or another language that supports reading-order alignment;
    /// otherwise, the style is ignored.
    ///
    /// Using this style for static or edit controls
    /// has the same effect as using the `SS_RIGHT` or `ES_RIGHT` style,
    /// respectively. Using this style with button controls
    /// has the same effect as using `BS_RIGHT` and `BS_RIGHTBUTTON` styles.
    right: bool = false,
    /// If the shell language is Hebrew, Arabic,
    /// or another language that supports reading-order alignment,
    /// the window text is displayed using right-to-left reading-order properties.
    /// For other languages, the style is ignored.
    right_to_left_reading: bool = false,
    /// If the shell language is Hebrew, Arabic,
    /// or another language that supports reading order alignment,
    /// the vertical scroll bar (if present) is to the left of the client area.
    /// For other languages, the style is ignored.
    left_scrollbar: bool = false,
    _unused_2: u1 = 0,
    /// The window itself contains child windows
    /// that should take part in dialog box navigation.
    /// If this style is specified,
    /// the dialog manager recurses into children of this window
    /// when performing navigation operations
    /// such as handling the TAB key, an arrow key, or a keyboard mnemonic.
    control_parent: bool = false,
    /// The window has a three-dimensional border style
    /// intended to be used for items that do not accept user input.
    static_edge: bool = false,
    /// Forces a top-level window onto the taskbar when the window is visible.
    app_window: bool = false,
    /// The window is a layered window.
    /// This style cannot be used if the window has a class style
    /// of either `CS_OWNDC` or `CS_CLASSDC`.
    ///
    /// Windows 8: The WS_EX_LAYERED style is supported
    /// for top-level windows and child windows.
    /// Previous Windows versions support `WS_EX_LAYERED` only for top-level windows.
    layered: bool = false,
    /// The window does not pass its window layout to its child windows.
    no_inherit_layout: bool = false,
    /// The window does not render to a redirection surface.
    /// This is for windows that do not have visible content
    /// or that use mechanisms other than surfaces to provide their visual.
    no_redirection_bitmap: bool = false,
    /// If the shell language is Hebrew, Arabic,
    /// or another language that supports reading order alignment,
    /// the horizontal origin of the window is on the right edge.
    /// Increasing horizontal values advance to the left.
    layout_right_to_left: bool = false,
    _unused_3: u2 = 0,
    /// Paints all descendants of a window
    /// in bottom-to-top painting order using double-buffering.
    /// Bottom-to-top painting order allows a descendent window
    /// to have translucency (alpha) and transparency (color-key) effects,
    /// but only if the descendent window also has the WS_EX_TRANSPARENT bit set.
    /// Double-buffering allows the window and its descendents
    /// to be painted without flicker.
    /// This cannot be used if the window has a class style
    /// of `CS_OWNDC`, `CS_CLASSDC`, or `CS_PARENTDC`.
    ///
    /// Windows 2000: This style is not supported.
    composited: bool = false,
    _unused_4: u1 = 0,
    /// A top-level window created with this style
    /// does not become the foreground window when the user clicks it.
    /// The system does not bring this window to the foreground
    /// when the user minimizes or closes the foreground window.
    /// The window should not be activated through programmatic access
    /// or via keyboard navigation by accessible technology, such as Narrator.
    /// To activate the window,
    /// use the `SetActiveWindow` or `SetForegroundWindow` function.
    /// The window does not appear on the taskbar by default.
    /// To force the window to appear on the taskbar,
    /// use the `.app_window` style.
    no_activate: bool = false,
    _padding: u4 = 0,

    /// The window is an overlapped window.
    pub const overlapped_window = WindowStyleExtended{
        .window_edge = true,
        .client_edge = true,
    };

    /// The window is palette window,
    /// which is a modeless dialog box that presents an array of commands.
    pub const palette_window = WindowStyleExtended{
        .window_edge = true,
        .tool_window = true,
        .topmost = true,
    };
};

test WindowStyleExtended {
    try testing.expectEqual(
        @as(u32, WS.EX.ACCEPTFILES), @as(u32, @bitCast(WindowStyleExtended{ .accept_files = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.APPWINDOW), @as(u32, @bitCast(WindowStyleExtended{ .app_window = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.CLIENTEDGE), @as(u32, @bitCast(WindowStyleExtended{ .client_edge = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.COMPOSITED), @as(u32, @bitCast(WindowStyleExtended{ .composited = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.CONTEXTHELP), @as(u32, @bitCast(WindowStyleExtended{ .context_help = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.CONTROLPARENT), @as(u32, @bitCast(WindowStyleExtended{ .control_parent = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.DLGMODALFRAME), @as(u32, @bitCast(WindowStyleExtended{ .dialog_modal_frame = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.LAYERED), @as(u32, @bitCast(WindowStyleExtended{ .layered = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.LAYOUTRTL), @as(u32, @bitCast(WindowStyleExtended{ .layout_right_to_left = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.LEFT), @as(u32, @bitCast(WindowStyleExtended{})));
    try testing.expectEqual(
        @as(u32, WS.EX.LEFTSCROLLBAR), @as(u32, @bitCast(WindowStyleExtended{ .left_scrollbar = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.LTRREADING), @as(u32, @bitCast(WindowStyleExtended{})));
    try testing.expectEqual(
        @as(u32, WS.EX.MDICHILD), @as(u32, @bitCast(WindowStyleExtended{ .multiple_document_interface_child = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.NOACTIVATE), @as(u32, @bitCast(WindowStyleExtended{ .no_activate = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.NOINHERITLAYOUT), @as(u32, @bitCast(WindowStyleExtended{ .no_inherit_layout = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.NOPARENTNOTIFY), @as(u32, @bitCast(WindowStyleExtended{ .no_parent_notify = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.NOREDIRECTIONBITMAP), @as(u32, @bitCast(WindowStyleExtended{ .no_redirection_bitmap = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.OVERLAPPEDWINDOW), @as(u32, @bitCast(WindowStyleExtended.overlapped_window)));
    try testing.expectEqual(
        @as(u32, WS.EX.PALETTEWINDOW), @as(u32, @bitCast(WindowStyleExtended.palette_window)));
    try testing.expectEqual(
        @as(u32, WS.EX.RIGHT), @as(u32, @bitCast(WindowStyleExtended{ .right = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.RIGHTSCROLLBAR), @as(u32, @bitCast(WindowStyleExtended{})));
    try testing.expectEqual(
        @as(u32, WS.EX.RTLREADING), @as(u32, @bitCast(WindowStyleExtended{ .right_to_left_reading = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.STATICEDGE), @as(u32, @bitCast(WindowStyleExtended{ .static_edge = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.TOOLWINDOW), @as(u32, @bitCast(WindowStyleExtended{ .tool_window = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.TRANSPARENT), @as(u32, @bitCast(WindowStyleExtended{ .transparent = true })));
    try testing.expectEqual(
        @as(u32, WS.EX.WINDOWEDGE), @as(u32, @bitCast(WindowStyleExtended{ .window_edge = true })));
}

pub const ShowStatus = enum (LPARAM) {
    /// The window is being shown as a result of a call to
    /// the `ShowWindow` or `ShowOwnedPopups` function.
    user = 0,
    /// The window is being uncovered
    /// because a maximize window was restored or minimized.
    other_unzoom = SW.OTHERUNZOOM,
    /// The window is being covered
    /// by another window that has been maximized.
    other_zoom = SW.OTHERZOOM,
    /// The window's owner window is being minimized.
    parent_closing = SW.PARENTCLOSING,
    /// The window's owner window is being restored.
    parent_opening = SW.PARENTOPENING,
    _,
};


/// The `flags` field of `WINDOWPOS`.
pub const SetWindowPosition = packed struct(UINT) {
    /// Retains the current size (ignores the `cx` and `cy` members).
    no_size: bool = false,
    /// Retains the current position (ignores the `x` and `y` members).
    no_move: bool = false,
    /// Retains the current Z order (ignores the `hwndInsertAfter` member).
    no_z_order: bool = false,
    /// Does not redraw changes.
    /// If this flag is set, no repainting of any kind occurs.
    /// This applies to the client area,
    /// the nonclient area (including the title bar and scroll bars),
    /// and any part of the parent window uncovered
    /// as a result of the window being moved.
    /// When this flag is set,
    /// the application must explicitly invalidate or redraw
    /// any parts of the window and parent window that need redrawing.
    no_redraw: bool = false,
    /// Does not activate the window.
    /// If this flag is not set,
    /// the window is activated and moved to the top of
    /// either the topmost or non-topmost group
    /// (depending on the setting of the `hwndInsertAfter` member).
    no_activate: bool = false,
    /// Draws a frame (defined in the window's class description) around the window,
    /// and sends a `WM_NCCALCSIZE` message to the the window,
    /// even if the window's size is not being changed.
    /// If this flag is not specified,
    /// `WM_NCCALCSIZE` is sent only when the window's size is being changed.
    draw_frame: bool = false,
    /// Displays the window.
    show_window: bool = false,
    /// Hides the window.
    hide_window: bool = false,
    /// Discards the entire contents of the client area.
    /// If this flag is not specified,
    /// the valid contents of the client area are saved
    /// and copied back into the client area
    /// after the window is sized or repositioned.
    no_copy_bits: bool = false,
    /// Does not change the owner window's position in the Z order.
    no_owner_z_order: bool = false,
    /// Prevents the window from receiving the `WM_WINDOWPOSCHANGING` message.
    no_send_changing: bool = false,
    _unused: u2 = 0,
    /// Prevents generation of the `WM_SYNCPAINT` message.
    defer_erase: bool = false,
    /// If the calling thread and the thread that owns the window
    /// are attached to different input queues,
    /// the system posts the request to the thread that owns the window.
    /// This prevents the calling thread from blocking its execution
    /// while other threads process the request.
    async_window_position: bool = false,
    _padding: @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = @bitSizeOf(UINT) - 15,
    }}) = 0,
};

test SetWindowPosition {
    try testing.expectEqual(0b0000000000000001, SWP.NOSIZE);
    try testing.expectEqual(0b0000000000000010, SWP.NOMOVE);
    try testing.expectEqual(0b0000000000000100, SWP.NOZORDER);
    try testing.expectEqual(0b0000000000001000, SWP.NOREDRAW);
    try testing.expectEqual(0b0000000000010000, SWP.NOACTIVATE);
    try testing.expectEqual(0b0000000000100000, SWP.DRAWFRAME);
    try testing.expectEqual(0b0000000000100000, SWP.FRAMECHANGED);
    try testing.expectEqual(0b0000000001000000, SWP.SHOWWINDOW);
    try testing.expectEqual(0b0000000010000000, SWP.HIDEWINDOW);
    try testing.expectEqual(0b0000000100000000, SWP.NOCOPYBITS);
    try testing.expectEqual(0b0000001000000000, SWP.NOOWNERZORDER);
    try testing.expectEqual(0b0000001000000000, SWP.NOREPOSITION);
    try testing.expectEqual(0b0000010000000000, SWP.NOSENDCHANGING);
    try testing.expectEqual(0b0010000000000000, SWP.DEFERERASE);
    try testing.expectEqual(0b0100000000000000, SWP.ASYNCWINDOWPOS);

    try testing.expectEqual(
        @as(UINT, SWP.NOSIZE),
        @as(UINT, @bitCast(SetWindowPosition{ .no_size = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOMOVE),
        @as(UINT, @bitCast(SetWindowPosition{ .no_move = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOZORDER),
        @as(UINT, @bitCast(SetWindowPosition{ .no_z_order = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOREDRAW),
        @as(UINT, @bitCast(SetWindowPosition{ .no_redraw = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOACTIVATE),
        @as(UINT, @bitCast(SetWindowPosition{ .no_activate = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.DRAWFRAME),
        @as(UINT, @bitCast(SetWindowPosition{ .draw_frame = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.FRAMECHANGED),
        @as(UINT, @bitCast(SetWindowPosition{ .draw_frame = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.SHOWWINDOW),
        @as(UINT, @bitCast(SetWindowPosition{ .show_window = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.HIDEWINDOW),
        @as(UINT, @bitCast(SetWindowPosition{ .hide_window = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOCOPYBITS),
        @as(UINT, @bitCast(SetWindowPosition{ .no_copy_bits = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOOWNERZORDER),
        @as(UINT, @bitCast(SetWindowPosition{ .no_owner_z_order = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOREPOSITION),
        @as(UINT, @bitCast(SetWindowPosition{ .no_owner_z_order = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.NOSENDCHANGING),
        @as(UINT, @bitCast(SetWindowPosition{ .no_send_changing = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.DEFERERASE),
        @as(UINT, @bitCast(SetWindowPosition{ .defer_erase = true })),
    );
    try testing.expectEqual(
        @as(UINT, SWP.ASYNCWINDOWPOS),
        @as(UINT, @bitCast(SetWindowPosition{ .async_window_position = true })),
    );
}

/// These values may appear in the `hwndInsertAfter` field of `WINDOWPOS`
/// instead of a handle to the window
/// that the recepient window is stacked above.
pub const WindowSpecialZ = enum (i2) {
    /// Places the window at the bottom of the Z order.
    /// If the `hWnd` parameter identifies a topmost window,
    /// the window loses its topmost status
    /// and is placed at the bottom of all other windows.
    bottom = HWNDZ.BOTTOM,
    /// Places the window above all non-topmost windows
    /// (that is, behind all topmost windows).
    /// This flag has no effect if the window is already a non-topmost window.
    no_top_most = HWNDZ.NOTOPMOST,
    /// Places the window at the top of the Z order.
    top = HWNDZ.TOP,
    /// Places the window above all non-topmost windows.
    /// The window maintains its topmost position even when it is deactivated.
    top_most = HWNDZ.TOPMOST,
};

pub const WindowActivation = enum(WORD) {
    /// Activated by some method other than a mouse click
    /// (for example, by a call to the `SetActiveWindow` function
    /// or by use of the keyboard interface to select the window).
    active = WA.ACTIVE,
    /// Activated by a mouse click.
    click_active = WA.CLICKACTIVE,
    /// Deactivated.
    inactive = WA.INACTIVE,
    _,
};

pub const Keystroke = packed struct(u32) {
    /// The repeat count for the current message.
    /// The value is the number of times the keystroke is autorepeated
    /// as a result of the user holding down the key.
    /// If the keystroke is held long enough, multiple messages are sent.
    /// However, the repeat count is not cumulative.
    repeat: u16,
    /// The scan code. The value depends on the OEM.
    scancode: u8,
    /// Whether the key is an extended key,
    /// such as the right-hand ALT and CTRL keys
    /// that appear on an enhanced 101- or 102-key keyboard.
    extended: bool,
    _reserved: u4 = 0,
    // The context code.
    // `false` for KEYDOWN or KEYUP messages.
    // For SYSKEYDOWN or SYSKEYUP, `true` only if the ALT key was down
    // when the key was pressed/released.
    context: bool,
    /// For KEYDOWN, `true` only if the key was also down
    /// before the message is sent (indicating a repeat).
    /// For KEYUP, always `true`.
    previously_down: bool,
    /// The transition state.
    /// `0` for a *KEYDOWN message, and `1` for a *KEYUP message.
    transition: u1,
};

pub const VirtualKey = enum(u8) {
    left_mouse_button = VK.LBUTTON,
    reft_mouse_button = VK.RBUTTON,
    /// Control-break processing
    cancel = VK.CANCEL,
    middle_mouse_button = VK.MBUTTON,
    /// X1 mouse button
    x_button_1 = VK.XBUTTON1,
    /// X2 mouse button
    x_button_2 = VK.XBUTTON2,
    /// Backspace key
    back = VK.BACK,
    tab = VK.TAB,
    clear = VK.CLEAR,
    /// Enter key
    @"return" = VK.RETURN,
    shift = VK.SHIFT,
    control = VK.CONTROl,
    /// Alt key
    menu = VK.MENU,
    pause = VK.PAUSE,
    /// Caps lock key
    capital = VK.CAPITAL,
    /// IME Kana/Hangul mode (same constant value)
    kana_hangul = VK.KANA,
    ime_on = VK.IME_ON,
    /// IME Junja mode
    junja = VK.JUNA,
    /// IME final mode
    final = VK.FINAL,
    /// IME Hanja/Kanji mode (same constant value)
    hanja_kanji = VK.HANJA,
    ime_off = VK.IME_OFF,
    escape = VK.ESCAPE,
    /// IME convert
    convert = VK.CONVERT,
    /// IME nonconvert
    nonconvert = VK.NONCONVERT,
    /// IME accept
    accept = VK.ACCEPT,
    /// IME mode change request
    mode_change = VK.MODECHANGE,
    /// Spacebar key
    space = VK.SPACE,
    /// Page up key
    prior = VK.PRIOR,
    /// Page down key
    next = VK.NEXT,
    end = VK.END,
    home = VK.HOME,
    /// Left arrow key
    left = VK.LEFT,
    /// Up arrow key
    up = VK.UP,
    /// Right arrow key
    right = VK.RIGHT,
    /// Down arrow key
    down = VK.DOWN,
    select = VK.SELECT,
    print = VK.PRINT,
    execute = VK.EXECUTE,
    snapshot = VK.SNAPSHOT,
    insert = VK.INSERT,
    delete = VK.INSERT,
    help = VK.HELP,
    @"0" = VK.@"0",
    @"1" = VK.@"1",
    @"2" = VK.@"2",
    @"3" = VK.@"3",
    @"4" = VK.@"4",
    @"5" = VK.@"5",
    @"6" = VK.@"6",
    @"7" = VK.@"7",
    @"8" = VK.@"8",
    @"9" = VK.@"9",
    a = VK.A,
    b = VK.B,
    c = VK.C,
    d = VK.D,
    e = VK.E,
    f = VK.F,
    g = VK.G,
    h = VK.H,
    i = VK.I,
    j = VK.J,
    k = VK.K,
    l = VK.L,
    m = VK.M,
    n = VK.N,
    o = VK.O,
    p = VK.P,
    q = VK.Q,
    r = VK.R,
    s = VK.S,
    t = VK.T,
    u = VK.U,
    v = VK.V,
    w = VK.W,
    x = VK.X,
    y = VK.Y,
    z = VK.Z,
    /// Left Windows logo key
    left_windows = VK.LWIN,
    /// Right Windows logo key
    right_windows = VK.RWIN,
    application = VK.APPS,
    /// Computer sleep key
    sleep = VK.SLEEP,
    numpad_0 = VK.NUMPAD0,
    numpad_1 = VK.NUMPAD1,
    numpad_2 = VK.NUMPAD2,
    numpad_3 = VK.NUMPAD3,
    numpad_4 = VK.NUMPAD4,
    numpad_5 = VK.NUMPAD5,
    numpad_6 = VK.NUMPAD6,
    numpad_7 = VK.NUMPAD7,
    numpad_8 = VK.NUMPAD8,
    numpad_9 = VK.NUMPAD9,
    multiply = VK.MULTIPLY,
    add = VK.ADD,
    separator = VK.SEPARATOR,
    subtract = VK.SUBTRACT,
    decimal = VK.DECIMAL,
    divide = VK.DIVIDE,
    function_1 = VK.F1,
    function_2 = VK.F2,
    function_3 = VK.F3,
    function_4 = VK.F4,
    function_5 = VK.F5,
    function_6 = VK.F6,
    function_7 = VK.F7,
    function_8 = VK.F8,
    function_9 = VK.F9,
    function_10 = VK.F10,
    function_11 = VK.F11,
    function_12 = VK.F12,
    function_13 = VK.F13,
    function_14 = VK.F14,
    function_15 = VK.F15,
    function_16 = VK.F16,
    function_17 = VK.F17,
    function_18 = VK.F18,
    function_19 = VK.F19,
    function_20 = VK.F20,
    function_21 = VK.F21,
    function_22 = VK.F22,
    function_23 = VK.F23,
    function_24 = VK.F24,
    num_lock = VK.NUMLOCK,
    scroll = VK.SCROLL,
    left_shift = VK.LSHIFT,
    right_shift = VK.RSHIFT,
    left_control = VK.LCONTROL,
    right_control = VK.RCONTROL,
    /// Left Alt key
    left_menu = VK.LMENU,
    /// Right Alt key
    right_menu = VK.RMENU,
    browser_back = VK.BROWSER_BACK,
    browser_forward = VK.BROWSER_FORWARD,
    browser_refresh = VK.BROWSER_REFRESH,
    browser_stop = VK.BROWSER_STOP,
    browser_search = VK.BROWSER_SEARCH,
    browser_favorites = VK.BROWSER_FAVORITES,
    browser_home = VK.BROWSER_HOME,
    volume_mute = VK.VOLUME_MUTE,
    volume_down = VK.VOLUME_DOWN,
    volume_up = VK.VOLUME_UP,
    media_next_track = VK.MEDIA_NEXT_TRACK,
    media_previous_track = VK.MEDIA_PREV_TRACK,
    media_stop = VK.MEDIA_STOP,
    media_play_pause = VK.MEDIA_PLAY_PAUSE,
    launch_mail = VK.LAUNCH_MAIL,
    launch_media_select = VK.MEDIA_SELECT,
    launch_app_1 = VK.LAUNCH_APP1,
    launch_app_2 = VK.LAUNCH_APP2,
    oem_1 = VK.OEM_1,
    oem_plus = VK.OEM_PLUS,
    oem_comma = VK.OEM_COMMA,
    oem_minus = VK.OEM_MINUS,
    oem_period = VK.OEM_PERIOD,
    oem_2 = VK.OEM_2,
    oem_3 = VK.OEM_3,
    gamepad_a = VK.GAMEPAD_A,
    gamepad_b = VK.GAMEPAD_B,
    gamepad_x = VK.GAMEPAD_X,
    gamepad_y = VK.GAMEPAD_Y,
    gamepad_right_shoulder = VK.GAMEPAD_RIGHT_SHOULDER,
    gamepad_left_shoulder = VK.GAMEPAD_LEFT_SHOULDER,
    gamepad_left_trigger = VK.GAMEPAD_LEFT_TRIGGER,
    gamepad_right_trigger = VK.GAMEPAD_RIGHT_TRIGGER,
    gamepad_dpad_up = VK.GAMEPAD_DPAD_UP,
    gamepad_dpad_down = VK.GAMEPAD_DPAD_DOWN,
    gamepad_dpad_left = VK.GAMEPAD_DPAD_LEFT,
    gamepad_dpad_right = VK.GAMEPAD_DPAD_RIGHT,
    gamepad_menu = VK.GAMEPAD_MENU,
    gamepad_view = VK.GAMEPAD_VIEW,
    gamepad_left_thumbstick_button = VK.GAMEPAD_LEFT_THUMBSTICK_BUTTON,
    gamepad_right_thumbstick_button = VK.GAMEPAD_RIGHT_THUMBSTICK_BUTTON,
    gamepad_left_thumbstick_up = VK.GAMEPAD_LEFT_THUMBSTICK_UP,
    gamepad_left_thumbstick_down = VK.GAMEPAD_RIGHT_THUMBSTICK_DOWN,
    gamepad_left_thumbstick_right = VK.GAMEPAD_LEFT_THUMBSTICK_RIGHT,
    gamepad_left_thumbstick_left = VK.GAMEPAD_LEFT_THUMSTICK_LEFT,
    gamepad_right_thumbstick_up = VK.GAMEPAD_RIGHT_THUMBSTICK_UP,
    gamepad_right_thumbstick_down = VK.GAMEPAD_RIGHT_THUMBSTICK_DOWN,
    gamepad_right_thumbstick_right = VK.GAMEPAD_RIGHT_THUMBSTICK_RIGHT,
    gamepad_right_thumbstick_left = VK.GAMEPAD_RIGHT_THUMBSTICK_LEFT,
    oem_4 = VK.OEM_4,
    oem_5 = VK.OEM_5,
    oem_6 = VK.OEM_6,
    oem_7 = VK.OEM_7,
    oem_8 = VK.OEM_8,
    oem_102 = VK.OEM_102,
    /// IME PROCESS key
    process_key = VK.PROCESS_KEY,
    /// Used to pass Unicode characters as if they were keystrokes.
    /// This key is the low word of a 32-bit Virtual Key value
    /// used for non-keyboard input methods.
    packet = VK.PACKET,
    attention = VK.ATTN,
    cursor_select = VK.CRSEL,
    extend_selection = VK.EXSEL,
    erase_to_eof = VK.EREOF,
    play = VK.PLAY,
    zoom = VK.ZOOM,
    /// Reserved
    no_name = VK.NONAME,
    pa_1 = VK.PA1,
    oem_clear = VK.OEM_CLEAR,
    _,
};

pub const MouseKey = packed struct (WORD) {
    left_button: bool = false,
    right_button: bool = false,
    shift: bool = false,
    control: bool = false,
    middle_button: bool = false,
    x_button_1: bool = false,
    x_button_2: bool = false,
    _padding: u9 = 0,
};

test MouseKey {
    try testing.expectEqual(
        @as(WORD, MK.LBUTTON),
        @as(WORD, @bitCast(MouseKey{ .left_button = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.RBUTTON),
        @as(WORD, @bitCast(MouseKey{ .right_button = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.SHIFT),
        @as(WORD, @bitCast(MouseKey{ .shift = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.CONTROL),
        @as(WORD, @bitCast(MouseKey{ .control = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.MBUTTON),
        @as(WORD, @bitCast(MouseKey{ .middle_button = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.XBUTTON1),
        @as(WORD, @bitCast(MouseKey{ .x_button_1 = true })),
    );
    try testing.expectEqual(
        @as(WORD, MK.XBUTTON2),
        @as(WORD, @bitCast(MouseKey{ .x_button_2 = true })),
    );
}

pub const MSG = extern struct {
    /// A handle to the window whose window procedure receives the message.
    /// This member is `null` when the message is a thread message.
    hwnd: ?HWND,
    /// The message identifier.
    /// Applications can only use the low word;
    /// the high word is reserved by the system.
    message: UINT,
    /// Additional information about the message.
    /// The exact meaning depends on the value of `.message`.
    wParam: WPARAM,
    /// Additional information about the message.
    /// The exact meaning depends on the value of `.message`.
    lParam: LPARAM,
    /// The time at which the message was posted
    /// (number of milliseconds since the system was started).
    time: DWORD,
    /// The cursor position, in screen coordinates,
    /// when the message was posted.
    pt: POINT,
    lPrivate: DWORD,

    pub fn identify(msg: MSG) WindowsMessage {
        // Windows intends for us to ignore the high word,
        // although it should be zero
        // (because it is also valid to compare directly to the `WM_*` macros)
        return @enumFromInt(@as(
            @typeInfo(WindowsMessage).@"enum".tag_type,
            @truncate(msg.message),
        ));
    }
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?LPVOID,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: LONG,
    lpszName: LPCWSTR,
    lpszClass: LPCWSTR,
    dwExStyle: DWORD,
};
comptime {
    assert(@sizeOf(LPVOID) == @sizeOf(?LPVOID));
    assert(@alignOf(LPVOID) == @alignOf(?LPVOID));
}

pub const WINDOWPOS = extern struct {
    /// A handle to the window.
    hwnd: HWND,
    /// The position of the window in Z order (front-to-back position).
    /// This member can be
    /// a handle to the window behind which this window is placed, or can be
    /// one of the special values listed with the `SetWindowPos` function.
    hwndInsertAfter: HWND,
    /// The position of the left edge of the window.
    x: c_int,
    /// The position of the top edge of the window.
    y: c_int,
    /// The window width, in pixels.
    cx: c_int,
    /// The window height, in pixels.
    cy: c_int,
    /// The window position.
    flags: UINT,
};

const StringOrAtom = packed union {
    string: [*:0]const WCHAR,
    atom: packed struct {
        word: WORD,
        _high: @Type(.{ .int = .{
            .signedness = .unsigned,
            .bits = @bitSizeOf(LPCWSTR) - @bitSizeOf(WORD),
        }}) = 0,
    },

    pub fn which(string_or_atom: StringOrAtom) enum { string, atom } {
        const raw: usize = @bitCast(string_or_atom);
        return if (raw <= std.math.maxInt(WORD)) .atom else .string;
    }

    pub fn fromAtom(atom: ATOM) StringOrAtom {
        return .{ .atom = .{ .word = atom }};
    }
};
comptime { assert(ATOM == WORD); }
comptime { assert(@bitSizeOf(WORD) == 16); }
comptime { assert(@bitSizeOf(StringOrAtom) == @bitSizeOf(LPCWSTR)); }
test StringOrAtom {
    const atom: ATOM = 0x63;
    const as_macro: usize = @intFromPtr(MAKEINTATOM(atom));
    const as_union: usize = @bitCast(StringOrAtom.fromAtom(atom));
    try testing.expectEqual(as_macro, as_union);
}

fn MAKEINTATOM(atom: ATOM) ?[*:0]const align(1) u16 {
    return @ptrFromInt(@as(u16, @intCast(atom)));
}

/// Windows message values appearing in the low word of the `MSG.message` identifier
pub const WM = struct {
    pub const ACTIVATE = 0x6;
    pub const ACTIVATEAPP = 0x1C;
    pub const AFXFIRST = 0x360;
    pub const AFXLAST = 0x37F;
    pub const APP = 0x8000;
    pub const ASKCBFORMATNAME = 0x030C;
    pub const CANCELJOURNAL = 0x004B;
    pub const CANCELMODE = 0x001F;
    pub const CAPTURECHANGED = 0x0215;
    pub const CHANGECBCHAIN = 0x030D;
    pub const CHANGEUISTATE = 0x0127;
    pub const CHAR = 0x0102;
    pub const CHARTOITEM = 0x002F;
    pub const CHILDACTIVATE = 0x0022;
    pub const CLEAR = 0x0303;
    pub const CLOSE = 0x0010;
    pub const CLIPBOARDUPDATE = 0x031D;
    pub const COMMAND = 0x0111;
    pub const COMPACTING = 0x0041;
    pub const COMPAREITEM = 0x0039;
    pub const CONTEXTMENU = 0x007B;
    pub const COPY = 0x0301;
    pub const COPYDATA = 0x004A;
    pub const CREATE = 0x0001;
    pub const CTLCOLORBTN = 0x0135;
    pub const CTLCOLORDLG = 0x0136;
    pub const CTLCOLOREDIT = 0x0133;
    pub const CTLCOLORLISTBOX = 0x0134;
    pub const CTLCOLORMSGBOX = 0x0132;
    pub const CTLCOLORSCROLLBAR = 0x0137;
    pub const CTLCOLORSTATIC = 0x0138;
    pub const CUT = 0x0300;
    pub const DEADCHAR = 0x0103;
    pub const DELETEITEM = 0x002D;
    pub const DESTROY = 0x0002;
    pub const DESTROYCLIPBOARD = 0x0307;
    pub const DEVICECHANGE = 0x0219;
    pub const DEVMODECHANGE = 0x001B;
    pub const DISPLAYCHANGE = 0x007E;
    pub const DRAWCLIPBOARD = 0x0308;
    pub const DRAWITEM = 0x002B;
    pub const DROPFILES = 0x0233;
    pub const ENABLE = 0x000A;
    pub const ENDSESSION = 0x0016;
    pub const ENTERIDLE = 0x0121;
    pub const ENTERMENULOOP = 0x0211;
    pub const ENTERSIZEMOVE = 0x0231;
    pub const ERASEBKGND = 0x0014;
    pub const EXITMENULOOP = 0x0212;
    pub const EXITSIZEMOVE = 0x0232;
    pub const FONTCHANGE = 0x001D;
    pub const GETDLGCODE = 0x0087;
    pub const GETFONT = 0x0031;
    pub const GETHOTKEY = 0x0033;
    pub const GETICON = 0x007F;
    pub const GETMINMAXINFO = 0x0024;
    pub const GETOBJECT = 0x003D;
    pub const GETTEXT = 0x000D;
    pub const GETTEXTLENGTH = 0x000E;
    pub const HANDHELDFIRST = 0x0358;
    pub const HANDHELDLAST = 0x035F;
    pub const HELP = 0x0053;
    pub const HOTKEY = 0x0312;
    pub const HSCROLL = 0x0114;
    pub const HSCROLLCLIPBOARD = 0x030E;
    pub const ICONERASEBKGND = 0x0027;
    pub const IME = struct {
        pub const CHAR = 0x0286;
        pub const COMPOSITION = 0x010F;
        pub const COMPOSITIONFULL = 0x0284;
        pub const CONTROL = 0x0283;
        pub const ENDCOMPOSITION = 0x010E;
        pub const KEYDOWN = 0x0290;
        pub const KEYLAST = 0x010F;
        pub const KEYUP = 0x0291;
        pub const NOTIFY = 0x0282;
        pub const REQUEST = 0x0288;
        pub const SELECT = 0x0285;
        pub const SETCONTEXT = 0x0281;
        pub const STARTCOMPOSITION = 0x010D;
    };
    pub const INITDIALOG = 0x0110;
    pub const INITMENU = 0x0116;
    pub const INITMENUPOPUP = 0x0117;
    pub const INPUTLANGCHANGE = 0x0051;
    pub const INPUTLANGCHANGEREQUEST = 0x0050;
    pub const KEYDOWN = 0x0100;
    pub const KEYFIRST = 0x0100;
    pub const KEYLAST = 0x0108;
    pub const KEYUP = 0x0101;
    pub const KILLFOCUS = 0x0008;
    pub const LBUTTONDBLCLK = 0x0203;
    pub const LBUTTONDOWN = 0x0201;
    pub const LBUTTONUP = 0x0202;
    pub const MBUTTONDBLCLK = 0x0209;
    pub const MBUTTONDOWN = 0x0207;
    pub const MBUTTONUP = 0x0208;
    pub const MDIACTIVATE = 0x0222;
    pub const MDICASCADE = 0x0227;
    pub const MDICREATE = 0x0220;
    pub const MDIDESTROY = 0x0221;
    pub const MDIGETACTIVE = 0x0229;
    pub const MDIICONARRANGE = 0x0228;
    pub const MDIMAXIMIZE = 0x0225;
    pub const MDINEXT = 0x0224;
    pub const MDIREFRESHMENU = 0x0234;
    pub const MDIRESTORE = 0x0223;
    pub const MDISETMENU = 0x0230;
    pub const MDITILE = 0x0226;
    pub const MEASUREITEM = 0x002C;
    pub const MENUCHAR = 0x0120;
    pub const MENUCOMMAND = 0x0126;
    pub const MENUDRAG = 0x0123;
    pub const MENUGETOBJECT = 0x0124;
    pub const MENURBUTTONUP = 0x0122;
    pub const MENUSELECT = 0x011F;
    pub const MOUSEACTIVATE = 0x0021;
    pub const MOUSEFIRST = 0x0200;
    pub const MOUSEHOVER = 0x02A1;
    pub const MOUSELAST = 0x020D;
    pub const MOUSELEAVE = 0x02A3;
    pub const MOUSEMOVE = 0x0200;
    pub const MOUSEWHEEL = 0x020A;
    pub const MOUSEHWHEEL = 0x020E;
    pub const MOVE = 0x0003;
    pub const MOVING = 0x0216;
    pub const NCACTIVATE = 0x0086;
    pub const NCCALCSIZE = 0x0083;
    pub const NCCREATE = 0x0081;
    pub const NCDESTROY = 0x0082;
    pub const NCHITTEST = 0x0084;
    pub const NCLBUTTONDBLCLK = 0x00A3;
    pub const NCLBUTTONDOWN = 0x00A1;
    pub const NCLBUTTONUP = 0x00A2;
    pub const NCMBUTTONDBLCLK = 0x00A9;
    pub const NCMBUTTONDOWN = 0x00A7;
    pub const NCMBUTTONUP = 0x00A8;
    pub const NCMOUSEHOVER = 0x02A0;
    pub const NCMOUSELEAVE = 0x02A2;
    pub const NCMOUSEMOVE = 0x00A0;
    pub const NCPAINT = 0x0085;
    pub const NCRBUTTONDBLCLK = 0x00A6;
    pub const NCRBUTTONDOWN = 0x00A4;
    pub const NCRBUTTONUP = 0x00A5;
    pub const NCXBUTTONDBLCLK = 0x00AD;
    pub const NCXBUTTONDOWN = 0x00AB;
    pub const NCXBUTTONUP = 0x00AC;
    pub const NCUAHDRAWCAPTION = 0x00AE;
    pub const NCUAHDRAWFRAME = 0x00AF;
    pub const NEXTDLGCTL = 0x0028;
    pub const NEXTMENU = 0x0213;
    pub const NOTIFY = 0x004E;
    pub const NOTIFYFORMAT = 0x0055;
    pub const NULL = 0x0000;
    pub const PAINT = 0x000F;
    pub const PAINTCLIPBOARD = 0x0309;
    pub const PAINTICON = 0x0026;
    pub const PALETTECHANGED = 0x0311;
    pub const PALETTEISCHANGING = 0x0310;
    pub const PARENTNOTIFY = 0x0210;
    pub const PASTE = 0x0302;
    pub const PENWINFIRST = 0x0380;
    pub const PENWINLAST = 0x038F;
    pub const POWER = 0x0048;
    pub const POWERBROADCAST = 0x0218;
    pub const PRINT = 0x0317;
    pub const PRINTCLIENT = 0x0318;
    pub const QUERYDRAGICON = 0x0037;
    pub const QUERYENDSESSION = 0x0011;
    pub const QUERYNEWPALETTE = 0x030F;
    pub const QUERYOPEN = 0x0013;
    pub const QUEUESYNC = 0x0023;
    pub const QUIT = 0x0012;
    pub const RBUTTONDBLCLK = 0x0206;
    pub const RBUTTONDOWN = 0x0204;
    pub const RBUTTONUP = 0x0205;
    pub const RENDERALLFORMATS = 0x0306;
    pub const RENDERFORMAT = 0x0305;
    pub const SETCURSOR = 0x0020;
    pub const SETFOCUS = 0x0007;
    pub const SETFONT = 0x0030;
    pub const SETHOTKEY = 0x0032;
    pub const SETICON = 0x0080;
    pub const SETREDRAW = 0x000B;
    pub const SETTEXT = 0x000C;
    pub const SETTINGCHANGE = 0x001A;
    pub const SHOWWINDOW = 0x0018;
    pub const SIZE = 0x0005;
    pub const SIZECLIPBOARD = 0x030B;
    pub const SIZING = 0x0214;
    pub const SPOOLERSTATUS = 0x002A;
    pub const STYLECHANGED = 0x007D;
    pub const STYLECHANGING = 0x007C;
    pub const SYNCPAINT = 0x0088;
    pub const SYSCHAR = 0x0106;
    pub const SYSCOLORCHANGE = 0x0015;
    pub const SYSCOMMAND = 0x0112;
    pub const SYSDEADCHAR = 0x0107;
    pub const SYSKEYDOWN = 0x0104;
    pub const SYSKEYUP = 0x0105;
    pub const TCARD = 0x0052;
    pub const TIMECHANGE = 0x001E;
    pub const TIMER = 0x0113;
    pub const UNDO = 0x0304;
    pub const UNINITMENUPOPUP = 0x0125;
    pub const USER = 0x0400;
    pub const USERCHANGED = 0x0054;
    pub const VKEYTOITEM = 0x002E;
    pub const VSCROLL = 0x0115;
    pub const VSCROLLCLIPBOARD = 0x030A;
    pub const WINDOWPOSCHANGED = 0x0047;
    pub const WINDOWPOSCHANGING = 0x0046;
    pub const WININICHANGE = 0x001A;
    pub const XBUTTONDBLCLK = 0x020D;
    pub const XBUTTONDOWN = 0x020B;
    pub const XBUTTONUP = 0x020C;
};

pub const CS = struct {
    pub const BYTEALIGNCLIENT = 0x1000;
    pub const BYTEALIGNWINDOW = 0x2000;
    pub const CLASSDC = 0x0040;
    pub const DBLCLKS = 0x0008;
    pub const DROPSHADOW = 0x00020000;
    pub const GLOBALCLASS = 0x4000;
    pub const HREDRAW = 0x0002;
    pub const NOCLOSE = 0x0200;
    pub const OWNDC = 0x0020;
    pub const PARENTDC = 0x0080;
    pub const SAVEBITS = 0x0800;
    pub const VREDRAW = 0x0001;
};

pub const WS = struct {
    pub const BORDER = 0x00800000;
    pub const CAPTION = 0x00C00000;
    pub const CHILD = 0x40000000;
    pub const CHILDWINDOW = 0x40000000;
    pub const CLIPCHILDREN = 0x02000000;
    pub const CLIPSIBLINGS = 0x04000000;
    pub const DISABLED = 0x08000000;
    pub const DLGFRAME = 0x00400000;
    pub const GROUP = 0x00020000;
    pub const HSCROLL = 0x00100000;
    pub const ICONIC = 0x20000000;
    pub const MAXIMIZE = 0x01000000;
    pub const MAXIMIZEBOX = 0x00010000;
    pub const MINIMIZE = 0x20000000;
    pub const MINIMIZEBOX = 0x00020000;
    pub const OVERLAPPED = 0x00000000;
    pub const OVERLAPPEDWINDOW =
        OVERLAPPED |
        CAPTION |
        SYSMENU |
        THICKFRAME |
        MINIMIZEBOX |
        MAXIMIZEBOX;
    pub const POPUP = 0x80000000;
    pub const POPUPWINDOW = POPUP | BORDER | SYSMENU;
    pub const SIZEBOX = 0x00040000;
    pub const SYSMENU = 0x00080000;
    pub const TABSTOP = 0x00010000;
    pub const THICKFRAME = 0x00040000;
    pub const TILED = 0x00000000;
    pub const TILEDWINDOW =
        OVERLAPPED |
        CAPTION |
        SYSMENU |
        THICKFRAME |
        MINIMIZEBOX |
        MAXIMIZEBOX;
    pub const VISIBLE = 0x10000000;
    pub const VSCROLL = 0x00200000;

    pub const EX = struct {
        pub const ACCEPTFILES = 0x00000010;
        pub const APPWINDOW = 0x00040000;
        pub const CLIENTEDGE = 0x00000200;
        pub const COMPOSITED = 0x02000000;
        pub const CONTEXTHELP = 0x00000400;
        pub const CONTROLPARENT = 0x00010000;
        pub const DLGMODALFRAME = 0x00000001;
        pub const LAYERED = 0x00080000;
        pub const LAYOUTRTL = 0x00400000;
        pub const LEFT = 0x00000000;
        pub const LEFTSCROLLBAR = 0x00004000;
        pub const LTRREADING = 0x00000000;
        pub const MDICHILD = 0x00000040;
        pub const NOACTIVATE = 0x08000000;
        pub const NOINHERITLAYOUT = 0x00100000;
        pub const NOPARENTNOTIFY = 0x00000004;
        pub const NOREDIRECTIONBITMAP = 0x00200000;
        pub const OVERLAPPEDWINDOW = WINDOWEDGE | CLIENTEDGE;
        pub const PALETTEWINDOW = WINDOWEDGE | TOOLWINDOW | TOPMOST;
        pub const RIGHT = 0x00001000;
        pub const RIGHTSCROLLBAR = 0x00000000;
        pub const RTLREADING = 0x00002000;
        pub const STATICEDGE = 0x00020000;
        pub const TOOLWINDOW = 0x00000080;
        pub const TOPMOST = 0x00000008;
        pub const TRANSPARENT = 0x00000020;
        pub const WINDOWEDGE = 0x00000100;
    };
};

/// HWND_* (conflicts with HWND)
pub const HWNDZ = struct {
    pub const BOTTOM = 1;
    pub const NOTOPMOST = -2;
    pub const TOP = 0;
    pub const TOPMOST = -1;
};

pub const SW = struct {
    pub const OTHERUNZOOM = 4;
    pub const OTHERZOOM = 2;
    pub const PARENTCLOSING = 1;
    pub const PARENTOPENING = 3;
};

pub const SWP = struct {
    pub const ASYNCWINDOWPOS = 0x4000;
    pub const DEFERERASE = 0x2000;
    pub const DRAWFRAME = 0x0020;
    pub const FRAMECHANGED = 0x0020;
    pub const HIDEWINDOW = 0x0080;
    pub const NOACTIVATE = 0x0010;
    pub const NOCOPYBITS = 0x0100;
    pub const NOMOVE = 0x0002;
    pub const NOOWNERZORDER = 0x0200;
    pub const NOREDRAW = 0x0008;
    pub const NOREPOSITION = 0x0200;
    pub const NOSENDCHANGING = 0x0400;
    pub const NOSIZE = 0x0001;
    pub const NOZORDER = 0x0004;
    pub const SHOWWINDOW = 0x0040;
};

pub const SIZE = struct {
    pub const MAXHIDE = 4;
    pub const MAXIMIZED = 2;
    pub const MAXSHOW = 3;
    pub const MINIMIZED = 1;
    pub const RESTORED = 0;
};

pub const WA = struct {
    pub const ACTIVE = 1;
    pub const CLICKACTIVE = 2;
    pub const INACTIVE = 0;
};

pub const VK = struct {
    pub const LBUTTON = 0x01;
    pub const RBUTTON = 0x02;
    pub const CANCEL = 0x03;
    pub const MBUTTON = 0x04;
    pub const XBUTTON1 = 0x05;
    pub const XBUTTON2 = 0x06;
    pub const BACK = 0x08;
    pub const TAB = 0x09;
    pub const CLEAR = 0x0C;
    pub const RETURN = 0x0D;
    pub const SHIFT = 0x10;
    pub const CONTROL = 0x11;
    pub const MENU = 0x12;
    pub const PAUSE = 0x13;
    pub const CAPITAL = 0x14;
    pub const KANA = 0x15;
    pub const HANGUL = 0x15;
    pub const IME_ON = 0x16;
    pub const JUNJA = 0x17;
    pub const FINAL = 0x18;
    pub const HANJA = 0x19;
    pub const KANJI = 0x19;
    pub const IME_OFF = 0x1A;
    pub const ESCAPE = 0x1B;
    pub const CONVERT = 0x1C;
    pub const NONCONVERT = 0x1D;
    pub const ACCEPT = 0x1E;
    pub const MODECHANGE = 0x1F;
    pub const SPACE = 0x20;
    pub const PRIOR = 0x21;
    pub const NEXT = 0x22;
    pub const END = 0x23;
    pub const HOME = 0x24;
    pub const LEFT = 0x25;
    pub const UP = 0x26;
    pub const RIGHT = 0x27;
    pub const DOWN = 0x28;
    pub const SELECT = 0x29;
    pub const PRINT = 0x2A;
    pub const EXECUTE = 0x2B;
    pub const SNAPSHOT = 0x2C;
    pub const INSERT = 0x2D;
    pub const DELETE = 0x2E;
    pub const HELP = 0x2F;
    pub const @"0" = 0x30;
    pub const @"1" = 0x31;
    pub const @"2" = 0x32;
    pub const @"3" = 0x33;
    pub const @"4" = 0x34;
    pub const @"5" = 0x35;
    pub const @"6" = 0x36;
    pub const @"7" = 0x37;
    pub const @"8" = 0x38;
    pub const @"9" = 0x39;
    pub const A = 0x41;
    pub const B = 0x42;
    pub const C = 0x43;
    pub const D = 0x44;
    pub const E = 0x45;
    pub const F = 0x46;
    pub const G = 0x47;
    pub const H = 0x48;
    pub const I = 0x49;
    pub const J = 0x4A;
    pub const K = 0x4B;
    pub const L = 0x4C;
    pub const M = 0x4D;
    pub const N = 0x4E;
    pub const O = 0x4F;
    pub const P = 0x50;
    pub const Q = 0x51;
    pub const R = 0x52;
    pub const S = 0x53;
    pub const T = 0x54;
    pub const U = 0x55;
    pub const V = 0x56;
    pub const W = 0x57;
    pub const X = 0x58;
    pub const Y = 0x59;
    pub const Z = 0x5A;
    pub const LWIN = 0x5B;
    pub const RWIN = 0x5C;
    pub const APPS = 0x5D;
    pub const SLEEP = 0x5F;
    pub const NUMPAD0 = 0x60;
    pub const NUMPAD1 = 0x61;
    pub const NUMPAD2 = 0x62;
    pub const NUMPAD3 = 0x63;
    pub const NUMPAD4 = 0x64;
    pub const NUMPAD5 = 0x65;
    pub const NUMPAD6 = 0x66;
    pub const NUMPAD7 = 0x67;
    pub const NUMPAD8 = 0x68;
    pub const NUMPAD9 = 0x69;
    pub const MULTIPLY = 0x6A;
    pub const ADD = 0x6B;
    pub const SEPARATOR = 0x6C;
    pub const SUBTRACT = 0x6D;
    pub const DECIMAL = 0x6E;
    pub const DIVIDE = 0x6F;
    pub const F1 = 0x70;
    pub const F2 = 0x71;
    pub const F3 = 0x72;
    pub const F4 = 0x73;
    pub const F5 = 0x74;
    pub const F6 = 0x75;
    pub const F7 = 0x76;
    pub const F8 = 0x77;
    pub const F9 = 0x78;
    pub const F10 = 0x79;
    pub const F11 = 0x7A;
    pub const F12 = 0x7B;
    pub const F13 = 0x7C;
    pub const F14 = 0x7D;
    pub const F15 = 0x7E;
    pub const F16 = 0x7F;
    pub const F17 = 0x80;
    pub const F18 = 0x81;
    pub const F19 = 0x82;
    pub const F20 = 0x83;
    pub const F21 = 0x84;
    pub const F22 = 0x85;
    pub const F23 = 0x86;
    pub const F24 = 0x87;
    pub const NUMLOCK = 0x90;
    pub const SCROLL = 0x91;
    pub const LSHIFT = 0xA0;
    pub const RSHIFT = 0xA1;
    pub const LCONTROL = 0xA2;
    pub const RCONTROL = 0xA3;
    pub const LMENU = 0xA4;
    pub const RMENU = 0xA5;
    pub const BROWSER_BACK = 0xA6;
    pub const BROWSER_FORWARD = 0xA7;
    pub const BROWSER_REFRESH = 0xA8;
    pub const BROWSER_STOP = 0xA9;
    pub const BROWSER_SEARCH = 0xAA;
    pub const BROWSER_FAVORITES = 0xAB;
    pub const BROWSER_HOME = 0xAC;
    pub const VOLUME_MUTE = 0xAD;
    pub const VOLUME_DOWN = 0xAE;
    pub const VOLUME_UP = 0xAF;
    pub const MEDIA_NEXT_TRACK = 0xB0;
    pub const MEDIA_PREV_TRACK = 0xB1;
    pub const MEDIA_STOP = 0xB2;
    pub const MEDIA_PLAY_PAUSE = 0xB3;
    pub const LAUNCH_MAIL = 0xB4;
    pub const LAUNCH_MEDIA_SELECT = 0xB5;
    pub const LAUNCH_APP1 = 0xB6;
    pub const LAUNCH_APP2 = 0xB7;
    pub const OEM_1 = 0xBA;
    pub const OEM_PLUS = 0xBB;
    pub const OEM_COMMA = 0xBC;
    pub const OEM_MINUS = 0xBD;
    pub const OEM_PERIOD = 0xBE;
    pub const OEM_2 = 0xBF;
    pub const OEM_3 = 0xC0;
    pub const GAMEPAD_A = 0xC3;
    pub const GAMEPAD_B = 0xC4;
    pub const GAMEPAD_X = 0xC5;
    pub const GAMEPAD_Y = 0xC6;
    pub const GAMEPAD_RIGHT_SHOULDER = 0xC7;
    pub const GAMEPAD_LEFT_SHOULDER = 0xC8;
    pub const GAMEPAD_LEFT_TRIGGER = 0xC9;
    pub const GAMEPAD_RIGHT_TRIGGER = 0xCA;
    pub const GAMEPAD_DPAD_UP = 0xCB;
    pub const GAMEPAD_DPAD_DOWN = 0xCC;
    pub const GAMEPAD_DPAD_LEFT = 0xCD;
    pub const GAMEPAD_DPAD_RIGHT = 0xCE;
    pub const GAMEPAD_MENU = 0xCF;
    pub const GAMEPAD_VIEW = 0xD0;
    pub const GAMEPAD_LEFT_THUMBSTICK_BUTTON = 0xD1;
    pub const GAMEPAD_RIGHT_THUMBSTICK_BUTTON = 0xD2;
    pub const GAMEPAD_LEFT_THUMBSTICK_UP = 0xD3;
    pub const GAMEPAD_LEFT_THUMBSTICK_DOWN = 0xD4;
    pub const GAMEPAD_LEFT_THUMBSTICK_RIGHT = 0xD5;
    pub const GAMEPAD_LEFT_THUMBSTICK_LEFT = 0xD6;
    pub const GAMEPAD_RIGHT_THUMBSTICK_UP = 0xD7;
    pub const GAMEPAD_RIGHT_THUMBSTICK_DOWN = 0xD8;
    pub const GAMEPAD_RIGHT_THUMBSTICK_RIGHT = 0xD9;
    pub const GAMEPAD_RIGHT_THUMBSTICK_LEFT = 0xDA;
    pub const OEM_4 = 0xDB;
    pub const OEM_5 = 0xDC;
    pub const OEM_6 = 0xDD;
    pub const OEM_7 = 0xDE;
    pub const OEM_8 = 0xDF;
    pub const OEM_102 = 0xE2;
    pub const PROCESSKEY = 0xE5;
    pub const PACKET = 0xE7;
    pub const ATTN = 0xF6;
    pub const CRSEL = 0xF7;
    pub const EXSEL = 0xF8;
    pub const EREOF = 0xF9;
    pub const PLAY = 0xFA;
    pub const ZOOM = 0xFB;
    pub const NONAME = 0xFC;
    pub const PA1 = 0xFD;
    pub const OEM_CLEAR = 0xFE;
};

pub const MK = struct {
    pub const CONTROL = 0x0008;
    pub const LBUTTON = 0x0001;
    pub const MBUTTON = 0x0010;
    pub const RBUTTON = 0x0002;
    pub const SHIFT = 0x0004;
    pub const XBUTTON1 = 0x0020;
    pub const XBUTTON2 = 0x0040;
};

// Assumed in some field types of message parse structs
comptime { assert(@bitSizeOf(WORD) == 16); }

pub const FALSE = 0;
pub const TRUE = 1;
pub const ATOM = windows.ATOM;
pub const UINT = windows.UINT;
pub const LONG = windows.LONG;
pub const WCHAR = windows.WCHAR;
pub const WORD = windows.WORD;
pub const DWORD = windows.DWORD;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LRESULT;
pub const HINSTANCE = windows.HINSTANCE;
pub const HWND = windows.HWND;
pub const HMENU = windows.HMENU;
pub const LPVOID = windows.LPVOID;
pub const LPCWSTR = windows.LPCWSTR;
pub const POINT = windows.POINT;
pub const RECT = windows.RECT;

const assert = std.debug.assert;

const testing = std.testing;

const windows = std.os.windows;
const std = @import("std");
