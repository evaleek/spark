const null_context: h.XContext = 0;
var context_key: h.XContext = null_context;

display: *h.Display,
err: u8,

pub const ConnectionError = common.ConnectionError;

/// Initialize a connection to the display server.
pub fn connect(client: *Client) ConnectionError!void {
    client.display = lib.XOpenDisplay(null) orelse return no_display: {
        // TODO I don't think this is a rigorous check
        // of all of the ways this could have failed
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
                    break :no_display error.ConnectionFailed;
                } else |err| switch (err) {
                    error.AccessDenied,
                    error.FileBusy,
                    error.InputOutput,
                    error.PermissionDenied => break :no_display error.ConnectionFailed,
                    else => break :no_display error.HostDown,
                }
            }
        }
        break :no_display error.HostDown;
    };
    errdefer client.display = undefined;
    errdefer _ = lib.XCloseDisplay(client.display);

    client.err = h.Success;
    errdefer client.err = undefined;

    if (@atomicLoad(h.XContext, &context_key, .acquire) == null_context) {
        const context = h.XUniqueContext();
        debug.assert(context != null_context);
        @atomicStore(h.XContext, &context_key, context, .release);
    }

    const context = @atomicLoad(h.XContext, &context_key, .acquire);

    switch (lib.XSaveContext(
        client.display,
        @intFromPtr(client.display),
        context,
        @ptrCast(client),
    )) {
        0 => {},
        h.XCNOMEM => return error.OutOfMemory,
        else => unreachable,
    }
    errdefer {
        switch (lib.XDeleteContext(
            client.display,
            @intFromPtr(client.display),
            context,
        )) {
            0 => {},
            h.XCNOENT => unreachable,
            else => unreachable,
        }
    }
}

test "no context before set" {
    if (build_options.x11_linked) {
        const display = lib.XOpenDisplay(null) orelse return error.SkipZigTest;
        defer _ = lib.XCloseDisplay(display);
        const context = h.XUniqueContext();

        var ptr: [*c]u8 = null;

        try testing.expectEqual(h.XCNOENT, lib.XFindContext(
            display,
            @intFromPtr(display),
            context,
            &ptr
        ));

        try testing.expectEqual(h.XCNOENT, lib.XDeleteContext(
            display,
            @intFromPtr(display),
            context,
        ));
    } else {
        return error.SkipZigTest;
    }
}

/// Deinitialize the connection to the display server.
/// Invalidates any resources created with this client.
pub fn disconnect(client: *Client) void {
    defer client.* = undefined;

    {
        const context = @atomicLoad(h.XContext, &context_key, .acquire);
        if (context != null_context) {
            switch (lib.XDeleteContext(
                client.display,
                @intFromPtr(client.display),
                context,
            )) {
                0 => {},
                h.XCNOENT => log.err("missing X context to delete at deinit", .{}),
                else => unreachable,
            }
        } else {
            log.err("null X context key at deinit", .{});
        }
    }

    _ = lib.XCloseDisplay(client.display);
}

fn fromContext(display: *h.Display) !*Client {
    const context = @atomicLoad(h.XContext, &context_key, .acquire);
    if (context != null_context) {
        var ptr: [*c]u8 = null;

        switch (lib.XFindContext(
            display,
            @intFromPtr(display),
            context,
            &ptr,
        )) {
            0 => {},
            h.XCNOENT => return error.ContextNotFound,
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
    _ = lib.XSync(client.display, h.False);
    const err = @atomicLoad(@FieldType(Client, "err"), &client.err, .acquire);
    @atomicStore(@FieldType(Client, "err"), &client.err, h.Success, .release);
    return err;
}

fn onError(display: *h.Display, event: *h.XErrorEvent) callconv(.c) c_int {
    const client: *Client = fromContext(display) catch |err| {
        log.err("{t} in X error handler", .{ err });
        return -1;
    };

    switch (event.errorcode) {
        else => {},
        // This would go more nicely after XCloseDisplay() in disconnect(),
        // but once XCloseDisplay() is called
        // checking this error synchronously becomes a potential segfault
        h.BadGC => log.warn("pending graphics context operations at X11 disconnect", .{}),
    }

    @atomicStore(@FieldType(Client, "err"), &client.err, event.error_code, .release);

    return 0;
}

pub fn openWindow(client: *Client, options: Window.CreationOptions) Window.CreationError!Window {
    var window: Window = undefined;
    try window.open(client, options);
    return window;
}

pub fn closeWindow(client: *Client, window: *Window) void {
    window.close(client);
}

pub const Window = struct {
    handle: h.Window,

    pub const CreationOptions = common.WindowCreationOptions;
    pub const CreationError = common.WindowCreationError;

    pub fn open(window: *Window, client: *Client, options: CreationOptions) CreationError!void {
        const screen: c_int = h.DefaultScreen(client.display);
        const root: h.Window = h.RootWindow(client.display, screen);

        var attributes = mem.zeroes(h.XSetWindowAttributes);
        attributes.event_mask =
            h.ExposureMask |
            h.KeyPressMask |
            h.KeyReleaseMask |
            h.ButtonPressMask |
            h.ButtonReleaseMask |
            h.PointerMotionMask |
            h.StructureNotifyMask
        ;

        window.handle = lib.XCreateWindow(
            client.display, root,
            0, 0, options.width, options.height, 0,
            h.CopyFromParent, h.InputOutput,
            @ptrFromInt(h.CopyFromParent),
            h.CWEventMask, &attributes,
        );
        switch (client.checkError()) {
            h.Success => {},
            // The server failed to allocate the requested resource or server memory.
            h.BadAlloc => return error.OutOfMemory,
            // A value for a Colormap argument does not name a defined Colormap.
            h.BadColor => unreachable,
            // A value for a Cursor argument does not name a defined Cursor.
            h.BadCursor => unreachable,
            // The values do not exist for an InputOnly window.
            // Some argument or pair of arguments has the correct type and range
            // but fails to match in some other way required by the request.
            h.BadMatch => unreachable,
            // A value for a Pixmap argument does not name a defined Pixmap.
            h.BadPixmap => unreachable,
            // Some numeric value falls outside the range of values accepted by the request.
            // Unless a specific range is specified for an argument,
            // the full range defined by the argument's type is accepted.
            // Any argument defined as a set of alternatives can generate this error.
            h.BadValue => unreachable,
            // A value for a window argument does not name a defined window.
            h.BadWindow => unreachable,
            else => unreachable,
        }

        _ = lib.XStoreName(client.display, window.handle, options.name.ptr);
        switch (client.checkError()) {
            h.Success => {},
            h.BadAlloc => return error.OutOfMemory,
            h.BadWindow => unreachable,
            else => unreachable,
        }

        _ = lib.XMapWindow(client.display, window.handle);
        switch (client.checkError()) {
            h.Success => {},
            h.BadWindow => unreachable,
            else => unreachable,
        }
    }

    pub fn close(window: *Window, client: *Client) void {
        _ = lib.XDestroyWindow(client.display, window.handle);

        switch (@import("builtin").mode) {
            .Debug, .ReleaseSafe => {
                switch (client.checkError()) {
                    h.Success => {},
                    h.BadWindow => log.err(
                        "an X11 window ({d}) was invalid at destruction",
                        .{ window.handle },
                    ),
                    else => unreachable,
                }
            },
            .ReleaseFast, .ReleaseSmall => {},
        }

        window.* = undefined;
    }
};

test "open and close window" {
    if (build_options.x11_linked) {
        var client: Client = undefined;
        client.connect() catch return error.SkipZigTest;
        defer client.disconnect();

        var window = try client.openWindow(.{
            .name = "test window",
            .width = 800,
            .height = 400,
        });
        defer client.closeWindow(&window);
    } else {
        return error.SkipZigTest;
    }
}

const lib = if (build_options.x11_linked) struct {
    pub extern fn XOpenDisplay(display_name: ?[*:0]const u8) callconv(.c) ?*h.Display;
    pub extern fn XCloseDisplay(display: *h.Display) callconv(.c) c_int;

    pub extern fn XFlush(display: *h.Display) callconv(.c) c_int;
    pub extern fn XSync(display: *h.Display, discard: h.Bool) callconv(.c) c_int;

    pub extern fn XSaveContext(
        display: *h.Display,
        rid: h.XID,
        context: h.XContext,
        data: h.XPointer,
    ) callconv(.c) c_int;
    pub extern fn XFindContext(
        display: *h.Display,
        rid: h.XID,
        context: h.XContext,
        data_return: *h.XPointer,
    ) callconv(.c) c_int;
    pub extern fn XDeleteContext(
        display: *h.Display,
        rid: h.XID,
        context: h.XContext,
    ) callconv(.c) c_int;

    pub extern fn XCreateWindow(
        display: *h.Display,
        parent: h.Window,
        x: c_int,
        y: c_int,
        width: c_uint,
        height: c_uint,
        border_width: c_uint,
        depth: c_int,
        class: c_uint,
        visual: ?*h.Visual,
        valuemask: c_ulong,
        attributes: *h.XSetWindowAttributes,
    ) callconv(.c) h.Window;
    pub extern fn XDestroyWindow(
        display: *h.Display,
        w: h.Window,
    ) callconv(.c) c_int;

    pub extern fn XStoreName(
        display: *h.Display,
        w: h.Window,
        window_name: [*:0]const u8,
    ) callconv(.c) c_int;
    pub extern fn XMapWindow(
        display: *h.Display,
        w: h.Window,
    ) callconv(.c) c_int;
} else @compileError("invalid reference to unlinked X11 library");

const h = if (build_options.x11_linked) @import("x11")
    else @compileError("invalid reference to unlinked X11 headers");

const Client = @This();

const debug = std.debug;
const testing = std.testing;
const log = std.log;
const mem = std.mem;
const posix = std.posix;

const common = @import("common.zig");
const build_options = @import("build_options");
const std = @import("std");
