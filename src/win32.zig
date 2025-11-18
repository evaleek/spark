pub const UINT = windows.UINT;
pub const DWORD = windows.DWORD;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;
pub const HWND = windows.HWND;

pub const POINT = windows.POINT;

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

const testing = std.testing;

const windows = std.os.windows;
const std = @import("std");
