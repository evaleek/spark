display: *DisplayHandle,
xrr_available: bool,
delete_window_atom: Atom,
err: u8,

// TODO error checking in this module could generally be handled less naively:
// after every potential error, we stop and XSync() to see if there is an error

/// Get the next pending event for all passed windows,
/// or `null` if there are no more pending events.
pub fn poll(client: Client, windows: []const *Window) ?struct { ?*Window, Event } {
    // TODO invert this loop structure to the user
    // so we don't call XPending many times in a poll loop

    var pending = x11.XPending(client.display);
    debug.assert(pending >= 0); // TODO confirm never negative

    while (pending > 0) : (pending -= 1) {
        const x_event: XEvent = get: {
            // TODO needs to be zeroed or can be undefined?
            var e = mem.zeroes(XEvent);
            // TODO check this isn't returning something important
            _ = x11.XNextEvent(client.display, &e);
            break :get e;
        };

        const window: ?*Window = windowFromEvent(x_event, windows);
        if (client.processEvent(x_event, window)) |event|
            return .{ window, event };
    }

    return null;
}

/// Get the next pending event for all passed windows,
/// and block if there are not yet pending events.
pub fn wait(client: Client, windows: []const *Window) struct { ?*Window, Event } {
    while (true) {
        const x_event: XEvent = get: {
            // TODO needs to be zeroed or can be undefined?
            var e = mem.zeroes(XEvent);
            // TODO check this isn't returning something important
            _ = x11.XNextEvent(client.display, &e);
            break :get e;
        };

        const window: ?*Window = windowFromEvent(x_event, windows);
        if (client.processEvent(x_event, window)) |event|
            return .{ window, event };
    }
}

pub const Event = root.Event;
pub const Message = root.Message;

fn windowFromEvent(e: XEvent, windows: []const *Window) ?*Window {
    const handle = switch (e.@"type") {
        Expose => e.xexpose.window,
        ConfigureNotify => e.xconfigure.window,
        ClientMessage => e.xclient.window,
        else => null,
    };

    return for (windows) |w| {
        if (w.handle == handle) break w;
    } else null;
}

fn processEvent(client: Client, e: XEvent, window: ?*Window) ?Event {
    switch (e.@"type") {
        else => return null,

        Expose => return .{ .redraw = .{
            .x = @intCast(e.xexpose.x),
            .y = @intCast(e.xexpose.y),
            .width = @intCast(e.xexpose.width),
            .height = @intCast(e.xexpose.height),
        }},

        ConfigureNotify => {
            const new_width: ScreenSize = @intCast(e.xconfigure.width);
            const new_height: ScreenSize = @intCast(e.xconfigure.height);
            const new_x: ScreenPosition = @intCast(e.xconfigure.x);
            const new_y: ScreenPosition = @intCast(e.xconfigure.y);

            if (window) |w| {
                const old_width = @atomicLoad(ScreenSize, &w.width, .acquire);
                const old_height = @atomicLoad(ScreenSize, &w.height, .acquire);
                const old_x = @atomicLoad(ScreenPosition, &w.x, .acquire);
                const old_y = @atomicLoad(ScreenPosition, &w.y, .acquire);

                @atomicStore(ScreenSize, &w.width, new_width, .release);
                @atomicStore(ScreenSize, &w.height, new_height, .release);
                @atomicStore(ScreenPosition, &w.x, new_x, .release);
                @atomicStore(ScreenPosition, &w.y, new_y, .release);

                if (new_width != old_width or new_height != old_height) {
                    return .{ .resize = .{
                        .width = new_width,
                        .height = new_height,
                        .x = new_x,
                        .y = new_y,
                    }};
                } else if (new_x != old_x or new_y != old_y) {
                    return .{ .reposition = .{
                        .x = new_x,
                        .y = new_y,
                    }};
                } else {
                    return null;
                }
            } else {
                // TODO note in docs that if a ConfigureNotify cannot be matched to a window
                // then the window will not have its size/position updated
                // and it will always return a resize
                return .{ .resize = .{
                    .x = new_x,
                    .y = new_y,
                    .width = new_width,
                    .height = new_height,
                }};
            }
        },

        ClientMessage => {
            switch (e.xclient.format) {
                8, 16 => return null,
                32 => {
                    if (e.xclient.data.l[0] == client.delete_window_atom) {
                        return .{ .close = {} };
                    } else {
                        return null;
                    }
                },
                else => unreachable,
            }

            // TODO drag and drop

            // TODO clipboard
        },

        // TODO input
    }
}

pub const ConnectionError = root.ConnectionError;

pub const ConnectOptions = struct {
};

/// Initialize a connection to the display server.
pub fn connect(client: *Client, options: ConnectOptions) ConnectionError!void {
    _ = options;
    client.display = x11.XOpenDisplay(null) orelse return no_display: {
        // TODO I don't think this is a rigorous check
        // of all of the ways this could have failed
        if (@import("builtin").target.os.tag == .windows) return error.HostDown;
        if (posix.getenv("DISPLAY")) |env_display| {
            if (env_display.len>0 and env_display[0] == ':') {
                var path_buf = mem.zeroes([32]u8);
                if (posix.access(
                    std.fmt.bufPrint(
                        &path_buf,
                        "/tmp/.X11-unix/X{s}",
                        .{ env_display[1..] },
                    ) catch break :no_display error.HostDown,
                    posix.F_OK,
                )) {
                    break :no_display error.ConnectionFailure;
                } else |err| switch (err) {
                    error.AccessDenied,
                    error.FileBusy,
                    error.InputOutput,
                    error.PermissionDenied => break :no_display error.ConnectionFailure,
                    else => break :no_display error.HostDown,
                }
            }
        }
        break :no_display error.HostDown;
    };
    errdefer client.display = undefined;
    errdefer _ = x11.XCloseDisplay(client.display);

    client.err = Success;
    errdefer client.err = undefined;

    if (@atomicLoad(XContext, &context_key, .acquire) == null_context) {
        const context = XUniqueContext();
        debug.assert(context != null_context);
        @atomicStore(XContext, &context_key, context, .release);
    }

    const context = @atomicLoad(XContext, &context_key, .acquire);

    switch (x11.XSaveContext(
        client.display,
        @intFromPtr(client.display),
        context,
        @ptrCast(client),
    )) {
        0 => {},
        XCNOMEM => return error.OutOfMemory,
        else => unreachable,
    }
    errdefer {
        switch (x11.XDeleteContext(
            client.display,
            @intFromPtr(client.display),
            context,
        )) {
            0 => {},
            XCNOENT => unreachable,
            else => unreachable,
        }
    }

    {
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        client.xrr_available = x11.XRRQueryExtension(
            client.display,
            &event_base, &error_base,
        ) == True;
    }

    client.delete_window_atom = x11.XInternAtom(client.display, "WM_DELETE_WINDOW", False);
    switch (client.checkError()) {
        Success => {},
        BadAlloc => return error.OutOfMemory,
        BadValue => unreachable, // TODO error or undefined?
        else => unreachable,
    }
    debug.assert(client.delete_window_atom != None);
}

test "no context before set" {
    if (build_options.x11_linked) {
        const display = x11.XOpenDisplay(null) orelse return missing_backend_error;
        defer _ = x11.XCloseDisplay(display);
        const context = XUniqueContext();

        var ptr: [*c]u8 = null;

        try testing.expectEqual(XCNOENT, x11.XFindContext(
            display,
            @intFromPtr(display),
            context,
            &ptr
        ));

        try testing.expectEqual(XCNOENT, x11.XDeleteContext(
            display,
            @intFromPtr(display),
            context,
        ));
    } else {
        return error.SkipZigTest;
    }
}

pub const DisconnectionError = root.DisconnectionError;

/// Deinitialize the connection to the display server.
/// Invalidates any resources created with this client.
pub fn disconnect(client: *Client) DisconnectionError!void {
    defer client.* = undefined;

    {
        const context = @atomicLoad(XContext, &context_key, .acquire);
        if (context != null_context) {
            switch (x11.XDeleteContext(
                client.display,
                @intFromPtr(client.display),
                context,
            )) {
                0 => {},
                XCNOENT => return error.InvalidClient,
                else => unreachable,
            }
        } else {
            return error.InvalidClient;
        }
    }

    _ = x11.XCloseDisplay(client.display);
}

fn fromContext(display: *DisplayHandle) !*Client {
    const context = @atomicLoad(XContext, &context_key, .acquire);
    if (context != null_context) {
        var ptr: [*c]u8 = null;

        switch (x11.XFindContext(
            display,
            @intFromPtr(display),
            context,
            &ptr,
        )) {
            0 => {},
            XCNOENT => return error.ContextNotFound,
            else => unreachable,
        }

        if (ptr) |p| {
            return @ptrCast(p);
        } else {
            return error.MissingContext;
        }
    } else {
        return error.MissingContextKey;
    }
}

fn checkError(client: *Client) u8 {
    _ = x11.XSync(client.display, False);
    const err = @atomicLoad(@FieldType(Client, "err"), &client.err, .acquire);
    @atomicStore(@FieldType(Client, "err"), &client.err, Success, .release);
    return err;
}

fn onError(display: *DisplayHandle, event: *XErrorEvent) callconv(.c) c_int {
    const client: *Client = fromContext(display) catch |err| {
        log.err("{t} in X error handler", .{ err });
        return -1;
    };

    switch (event.errorcode) {
        else => {},
        // This would go more nicely after XCloseDisplay() in disconnect(),
        // but once XCloseDisplay() is called
        // checking this error synchronously becomes a potential segfault
        BadGC => log.warn("pending graphics context operations at X11 disconnect", .{}),
    }

    @atomicStore(@FieldType(Client, "err"), &client.err, event.error_code, .release);

    return 0;
}

pub fn iterateDisplays(client: Client) !Display.Iterator {
    return Display.iterate(client);
}

pub const Display = struct {
    pub const Info = root.DisplayInfo;
    pub const Size = root.DisplaySize;
    pub const Selection = root.DisplaySelection;

    pub fn iterate(client: Client) !Iterator {
        if (client.xrr_available) {
            const root_window: WindowHandle = DefaultRootWindow(client.display);
            const resources: *XRRScreenResources = x11.XRRGetScreenResources(
                client.display, root_window,
            ) orelse return error.Unavailable;

            return Iterator{
                .display = client.display,
                .resources = resources,
                .index = 0,
            };
        } else {
            return error.Unavailable;
        }
    }

    pub const Iterator = struct {
        display: *DisplayHandle,
        resources: *XRRScreenResources,
        index: usize,

        /// Reference fields in the Info struct (e.g. `.name[]`)
        /// have the same lifetime as the Iterator
        /// and must be copied if needed beyond this method.
        pub fn release(iter: *Iterator) void {
            x11.XRRFreeScreenResources(iter.resources);
            iter.* = undefined;
        }

        pub fn next(iter: *Iterator) ?Info {
            return while (iter.index < iter.count()) {
                defer iter.index += 1;

                const output_info: *XRROutputInfo = x11.XRRGetOutputInfo(
                    iter.display,
                    iter.resources,
                    iter.resources.outputs[iter.index],
                ).?;
                // TODO free the info. needs refactor so user can see name reference

                break Info{
                    .active = output_info.connection == RR_Connected,
                    .name = output_info.name[0..@intCast(output_info.nameLen)],
                    .size = if (output_info.crtc != None) get_size: {
                        const crtc_info: *XRRCrtcInfo = x11.XRRGetCrtcInfo(
                            iter.display,
                            iter.resources,
                            output_info.crtc,
                        ).?;
                        defer x11.XRRFreeCrtcInfo(crtc_info);

                        break :get_size .{
                            .width_pixels = @intCast(crtc_info.width),
                            .height_pixels = @intCast(crtc_info.height),
                            .width_millimeters = output_info.mm_width,
                            .height_millimeters = output_info.mm_height,
                        };
                    } else null,
                };
            } else null;
        }

        pub fn reset(iter: *Iterator) void {
            iter.index = 0;
        }

        pub fn atIndex(iter: Iterator, index: usize) !Info {
            if (index < iter.count()) {
                const output_info: *XRROutputInfo = x11.XRRGetOutputInfo(
                    iter.display,
                    iter.resources,
                    iter.resources.outputs[index],
                ).?;
                // TODO free the info. needs refactor so user can see name reference

                return Info{
                    .active = output_info.connection == RR_Connected,
                    .name = output_info.name[0..@intCast(output_info.nameLen)],
                    .size = if (output_info.crtc != None) get_size: {
                        const crtc_info: *XRRCrtcInfo = x11.XRRGetCrtcInfo(
                            iter.display,
                            iter.resources,
                            output_info.crtc,
                        ).?;
                        defer x11.XRRFreeCrtcInfo(crtc_info);

                        break :get_size .{
                            .width_pixels = @intCast(crtc_info.width),
                            .height_pixels = @intCast(crtc_info.height),
                            .width_millimeters = output_info.mm_width,
                            .height_millimeters = output_info.mm_height,
                        };
                    } else null,
                };
            } else {
                return error.OutOfBounds;
            }
        }

        pub fn count(iter: Iterator) usize {
            return @intCast(iter.resources.noutput);
        }
    };
};

pub fn openWindow(client: *Client, options: Window.CreationOptions) Window.CreationError!Window {
    var window: Window = undefined;
    try window.open(client, options);
    return window;
}

pub fn closeWindow(client: *Client, window: *Window) Window.DestructionError!void {
    return window.close(client);
}

pub fn showWindow(client: *Client, window: Window) Window.ShowError!void {
    return window.show(client);
}

pub const Window = struct {
    handle: WindowHandle,

    x: ScreenPosition,
    y: ScreenPosition,
    width: ScreenSize,
    height: ScreenSize,

    pub const CreationOptions = root.WindowCreationOptions;
    pub const CreationError = root.WindowCreationError;
    pub const DestructionError = root.WindowDestructionError;
    pub const ShowError = root.WindowShowError;

    pub fn open(window: *Window, client: *Client, options: CreationOptions) CreationError!void {
        // The library assumes a single X11 screen
        // (a modern machine that uses Xrandr for multiple monitor monitors).
        // Maybe TODO enumerate possible Screens if Xrandr is unavailable

        const screen: c_int = DefaultScreen(client.display);
        const root_window: WindowHandle = RootWindow(client.display, screen);

        const display_x: ScreenPosition,
        const display_y: ScreenPosition = getDisplayOrigin(
            client.*,
            root_window,
            options.display,
        ) catch |err| switch (err) {
            error.XRRUnavailable,
            error.NoScreenResources,
            error.MissingPrimaryOutputInfo => |e| nonfatal: {
                log.err("could not find X11 output origin ({t})", .{ e });
                break :nonfatal .{ 0, 0 };
            },
            error.InvalidDisplaySelection => |e| return e,
        };

        var attributes = mem.zeroes(XSetWindowAttributes);
        attributes.event_mask |=
            ExposureMask |
            KeyPressMask |
            KeyReleaseMask |
            ButtonPressMask |
            ButtonReleaseMask |
            PointerMotionMask |
            StructureNotifyMask
        ;

        window.x = display_x + ( options.origin_x orelse root.fallback_default_window_origin_x );
        window.y = display_y + ( options.origin_y orelse root.fallback_default_window_origin_y );
        window.width = options.width orelse root.fallback_default_window_width;
        window.height = options.height orelse root.fallback_default_window_height;

        window.handle = x11.XCreateWindow(
            client.display, root_window,
            window.x, window.y,
            window.width, window.height, 0,
            CopyFromParent, InputOutput,
            @ptrFromInt(CopyFromParent),
            CWEventMask, &attributes,
        );
        switch (client.checkError()) {
            Success => {},
            // The server failed to allocate the requested resource or server memory.
            BadAlloc => return error.OutOfMemory,
            // A value for a Colormap argument does not name a defined Colormap.
            BadColor => unreachable,
            // A value for a Cursor argument does not name a defined Cursor.
            BadCursor => unreachable,
            // The values do not exist for an InputOnly window.
            // Some argument or pair of arguments has the correct type and range
            // but fails to match in some other way required by the request.
            BadMatch => unreachable,
            // A value for a Pixmap argument does not name a defined Pixmap.
            BadPixmap => unreachable,
            // Some numeric value falls outside the range of values accepted by the request.
            // Unless a specific range is specified for an argument,
            // the full range defined by the argument's type is accepted.
            // Any argument defined as a set of alternatives can generate this error.
            BadValue => unreachable,
            // A value for a window argument does not name a defined window.
            BadWindow => unreachable,
            else => unreachable,
        }
        errdefer _ = x11.XDestroyWindow(client.display, window.handle);

        _ = x11.XStoreName(client.display, window.handle, options.name.ptr);
        switch (client.checkError()) {
            Success => {},
            BadAlloc => return error.OutOfMemory,
            BadWindow => unreachable,
            else => unreachable,
        }

        _ = x11.XSetWMProtocols(
            client.display,
            window.handle,
            @ptrCast(&client.delete_window_atom),
            1,
        );
        switch (client.checkError()) {
            Success => {},
            BadAlloc => return error.OutOfMemory,
            BadWindow => unreachable,
            else => unreachable,
        }
    }

    pub fn close(window: *Window, client: *Client) DestructionError!void {
        _ = x11.XDestroyWindow(client.display, window.handle);

        switch (client.checkError()) {
            Success => {},
            BadWindow => return error.InvalidWindow,
            else => unreachable,
        }

        window.* = undefined;
    }

    pub fn show(window: Window, client: *Client) ShowError!void {
        _ = x11.XMapWindow(client.display, window.handle);
        switch (client.checkError()) {
            Success => {},
            BadWindow => return error.InvalidWindow,
            else => unreachable,
        }
    }
};

fn getDisplayOrigin(
    client: Client,
    window: WindowHandle,
    selection: ?Display.Selection,
) !struct { ScreenPosition, ScreenPosition } {
    if (client.xrr_available) {
        const resources: *XRRScreenResources = x11.XRRGetScreenResources(
            client.display, window,
        ) orelse return error.NoScreenResources;
        defer x11.XRRFreeScreenResources(resources);

        const outputs: []const RROutput =
            resources.outputs[0..@intCast(resources.noutput)];

        if (selection) |display_selection| {
            switch (display_selection) {
                .index => |index| {
                    if (outputs.len > index) {
                        const output_info: *XRROutputInfo = x11.XRRGetOutputInfo(
                            client.display,
                            resources,
                            outputs[index],
                        ).?;
                        defer x11.XRRFreeOutputInfo(output_info);

                        if (output_info.crtc != None) {
                            const crtc_info: *XRRCrtcInfo = x11.XRRGetCrtcInfo(
                                client.display,
                                resources,
                                output_info.crtc,
                            ).?;
                            defer x11.XRRFreeCrtcInfo(crtc_info);

                            return .{
                                @intCast(crtc_info.x),
                                @intCast(crtc_info.y),
                            };
                        }
                    }
                },

                .name => |select_name| {
                    for (outputs) |output| {
                        const output_info: *XRROutputInfo = x11.XRRGetOutputInfo(
                            client.display,
                            resources,
                            output,
                        ).?;
                        defer x11.XRRFreeOutputInfo(output_info);

                        if (output_info.crtc != None) {
                            const crtc_info: *XRRCrtcInfo = x11.XRRGetCrtcInfo(
                                client.display,
                                resources,
                                output_info.crtc,
                            ).?;
                            defer x11.XRRFreeCrtcInfo(crtc_info);

                            const output_name: []const u8 =
                                output_info.name[0..@intCast(output_info.nameLen)];
                            if (mem.eql(u8, select_name, output_name)) {
                                return .{
                                    @intCast(crtc_info.x),
                                    @intCast(crtc_info.y),
                                };
                            }
                        }
                    }
                },
            }

            return error.InvalidDisplaySelection;
        } else {
            const primary: RROutput = x11.XRRGetOutputPrimary(client.display, window);
            for (outputs) |output| {
                if (output == primary) {
                    const output_info: *XRROutputInfo = x11.XRRGetOutputInfo(
                        client.display,
                        resources,
                        output,
                    ).?;
                    defer x11.XRRFreeOutputInfo(output_info);

                    if (output_info.crtc != None) {
                        const crtc_info: *XRRCrtcInfo = x11.XRRGetCrtcInfo(
                            client.display,
                            resources,
                            output_info.crtc,
                        ).?;
                        defer x11.XRRFreeCrtcInfo(crtc_info);

                        return .{
                            @intCast(crtc_info.x),
                            @intCast(crtc_info.y),
                        };
                    }
                }
            }

            return error.MissingPrimaryOutputInfo;
        }

    } else {
        return error.XRRUnavailable;
    }
}

var context_key: XContext = null_context;
const null_context: XContext = 0;

const x11 = if (build_options.x11_linked) struct {
    pub extern fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*DisplayHandle;
    pub extern fn XCloseDisplay(display: *DisplayHandle) callconv(.c) c_int;

    pub extern fn XFlush(display: *DisplayHandle) callconv(.c) c_int;
    pub extern fn XSync(display: *DisplayHandle, discard: Bool) callconv(.c) c_int;

    pub extern fn XPending(display: *DisplayHandle) callconv(.c) c_int;
    pub extern fn XNextEvent(display: *DisplayHandle, *XEvent) callconv(.c) c_int;

    pub extern fn XInternAtom(
        display: *DisplayHandle,
        atom_name: [*:0]const u8,
        only_if_exists: Bool,
    ) callconv(.c) Atom;

    pub extern fn XSaveContext(
        display: *DisplayHandle,
        rid: XID,
        context: XContext,
        data: XPointer,
    ) callconv(.c) c_int;
    pub extern fn XFindContext(
        display: *DisplayHandle,
        rid: XID,
        context: XContext,
        data_return: *XPointer,
    ) callconv(.c) c_int;
    pub extern fn XDeleteContext(
        display: *DisplayHandle,
        rid: XID,
        context: XContext,
    ) callconv(.c) c_int;

    pub extern fn XCreateWindow(
        display: *DisplayHandle,
        parent: WindowHandle,
        x: c_int,
        y: c_int,
        width: c_uint,
        height: c_uint,
        border_width: c_uint,
        depth: c_int,
        class: c_uint,
        visual: ?*Visual,
        valuemask: c_ulong,
        attributes: *XSetWindowAttributes,
    ) callconv(.c) WindowHandle;
    pub extern fn XDestroyWindow(
        display: *DisplayHandle,
        w: WindowHandle,
    ) callconv(.c) c_int;

    pub extern fn XStoreName(
        display: *DisplayHandle,
        w: WindowHandle,
        window_name: [*:0]const u8,
    ) callconv(.c) c_int;
    pub extern fn XMapWindow(
        display: *DisplayHandle,
        w: WindowHandle,
    ) callconv(.c) c_int;
    pub extern fn XSetWMProtocols(
        display: *DisplayHandle,
        w: WindowHandle,
        protocols: [*]Atom,
        count: c_int,
    ) callconv(.c) Status;

    pub extern fn XRRQueryExtension(
        dpy: *DisplayHandle,
        event_base_return: *c_int,
        error_base_return: *c_int,
    ) callconv(.c) Bool;

    pub extern fn XRRGetScreenResources(
        display: *DisplayHandle,
        window: WindowHandle,
    ) callconv(.c) ?*XRRScreenResources;
    pub extern fn XRRFreeScreenResources(
        resources: *XRRScreenResources,
    ) callconv(.c) void;

    pub extern fn XRRGetOutputPrimary(
        dpy: *DisplayHandle,
        window: WindowHandle,
    ) callconv(.c) RROutput;

    pub extern fn XRRGetOutputInfo(
        dpy: *DisplayHandle,
        resources: *XRRScreenResources,
        output: RROutput,
    ) callconv(.c) ?*XRROutputInfo;
    pub extern fn XRRFreeOutputInfo(
        outputInfo: *XRROutputInfo,
    ) callconv(.c) void;

    pub extern fn XRRGetCrtcInfo(
        dpy: *DisplayHandle,
        resources: *XRRScreenResources,
        crtc: RRCrtc,
    ) callconv(.c) ?*XRRCrtcInfo;
    pub extern fn XRRFreeCrtcInfo(
        crtcInfo: *XRRCrtcInfo,
    ) callconv(.c) void;
} else @compileError("invalid reference to unlinked X11 library");

const XCNOMEM               = h.XCNOMEM;
const XCNOENT               = h.XCNOENT;

const None                  = h.None;
const True                  = h.True;
const False                 = h.False;
const Success               = h.Success;
const BadAlloc              = h.BadAlloc;
const BadValue              = h.BadValue;
const BadWindow             = h.BadWindow;
const BadGC                 = h.BadGC;
const BadColor              = h.BadColor;
const BadCursor             = h.BadCursor;
const BadMatch              = h.BadMatch;
const BadPixmap             = h.BadPixmap;
const RR_Connected          = h.RR_Connected;
const CopyFromParent        = h.CopyFromParent;
const InputOutput           = h.InputOutput;

const CWEventMask           = h.CWEventMask;
const ExposureMask          = h.ExposureMask;
const KeyPressMask          = h.KeyPressMask;
const KeyReleaseMask        = h.KeyReleaseMask;
const ButtonPressMask       = h.ButtonPressMask;
const ButtonReleaseMask     = h.ButtonReleaseMask;
const PointerMotionMask     = h.PointerMotionMask;
const StructureNotifyMask   = h.StructureNotifyMask;

const Expose                = h.Expose;
const ConfigureNotify       = h.ConfigureNotify;
const ClientMessage         = h.ClientMessage;

const Bool                  = h.Bool;
const Atom                  = h.Atom;
const XID                   = h.XID;
const XPointer              = h.XPointer;
const Status                = h.Status;
const DisplayHandle         = h.Display;
const WindowHandle          = h.Window;
const Visual                = h.Visual;
const RROutput              = h.RROutput;
const RRCrtc                = h.RRCrtc;
const XContext              = h.XContext;
const XEvent                = h.XEvent;
const XErrorEvent           = h.XErrorEvent;
const XSetWindowAttributes  = h.XSetWindowAttributes;
const XRRScreenResources    = h.XRRScreenResources;

const RootWindow            = h.RootWindow;
const DefaultRootWindow     = h.DefaultRootWindow;
const DefaultScreen         = h.DefaultScreen;
const XUniqueContext        = h.XUniqueContext;
const XRROutputInfo         = h.XRROutputInfo;
const XRRCrtcInfo           = h.XRRCrtcInfo;

const h = if (build_options.x11_linked) @import("x11")
    else @compileError("invalid reference to unlinked X11 headers");

const Client = @This();
const ScreenSize = root.ScreenSize;
const ScreenPosition = root.ScreenPosition;
const missing_backend_error =
    if (build_options.x11_force_test_host) error.X11ConnectionFailure
    else error.SkipZigTest;

const debug = std.debug;
const testing = std.testing;
const log = std.log;
const mem = std.mem;
const posix = std.posix;

const root = @import("../root.zig");
const build_options = @import("build_options");
const std = @import("std");
