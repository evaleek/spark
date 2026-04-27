pub const wire = @import("wayland/wire.zig");

// TODO delete, moved to root
//pub const Display = struct {
//    stream: ipc.DomainStream,
//    send_buffer: root.MirrorRing,
//    receive_buffer: root.MirrorRing,
//    fd_send_queue: ipc.DomainStream.ControlBuffer,
//    fd_receive_queue: []system.fd_t,
//    fd_receive_capacity: usize,
//    control_buffer: []align(ipc.cmsg.algn) u8,
//
//    // TODO this is not really specific to wayland display connection,
//    // just any unix domain socket IPC that only cares about control for fd transfer.
//    // move to root
//
//    /// If the compositor is following protocol,
//    /// any file descriptors in the message args for a completely received message
//    /// will be queued in order in `.fd_receive_queue`
//    pub fn peekNext(display: Display) ?[]u8 {
//        const buffered: []u8 = display.receive_buffer.readable();
//        if (buffered.len >= @sizeOf(wire.Header)) {
//            const header: *wire.Header = mem.bytesAsValue(wire.Header, buffered[0..@sizeOf(wire.Header)]);
//            // The message header size field is the header + payload size
//            if (@as(usize, header.info.size) <= buffered.len) {
//                return buffered[0..header.info.size];
//            }
//        }
//        return null;
//    }
//
//    /// Asserts that at least `size` bytes are buffered in the receive buffer.
//    pub fn toss(display: *Display, size: usize) void {
//        @memset(display.receive_buffer.readable()[0..size], undefined);
//        display.receive_buffer.consume(size);
//        // TODO which is better
//        // if (size == len) display.receive_buffer.reset();
//        display.receive_buffer.resetIfEmpty();
//    }
//
//    pub fn tossNoReset(display: *Display, size: usize) void {
//        @memset(display.receive_buffer.readable()[0..size], undefined);
//        display.receive_buffer.consume(size);
//    }
//
//    pub fn peekFds(display: Display) []const system.fd_t {
//        return display.fd_receive_queue;
//    }
//
//    /// Asserts that at least `count` fds are buffered in `fd_receive_queue`.
//    /// Prefer to batch this into one call after a series of parsed messages,
//    /// to avoid a repeated `memmove`.
//    pub fn tossFds(display: *Display, count: usize) void {
//        if (count == display.fd_receive_queue.len) {
//            @memset(display.fd_receive_queue, undefined);
//            display.fd_receive_queue.len = 0;
//        } else if (count < display.fd_receive_queue.len) {
//            const new_len = display.fd_receive_queue.len - count;
//            @memmove(display.fd_receive_queue[0..new_len], display.fd_receive_queue[count..]);
//            @memset(display.fd_receive_queue[new_len..], undefined);
//            display.fd_receive_queue.len = new_len;
//        } else {
//            unreachable;
//        }
//    }
//
//    /// Add data for sending at the next flush. Never flushes.
//    pub fn queue(display: *Display, data: []const u8) (error{OutOfMemory})!void {
//        const bufferable = display.send_buffer.writable();
//        if (bufferable.len >= data.len) {
//            if (display.send_buffer.publishWouldOverflow(bufferable.len)) {
//                @branchHint(.cold);
//                display.send_buffer.normalize();
//            }
//            @memcpy(bufferable[0..data.len], data);
//            display.send_buffer.publish(data.len);
//        } else {
//            return error.OutOfMemory;
//        }
//    }
//
//    /// Add data for sending at the next flush. Never flushes.
//    /// Overflows the ring buffer cursor after `maxInt(usize)` bytes of buffered data
//    /// (~4GB on 32-bit systems), if not resetting or the buffer is never empty for a reset.
//    pub fn queueNoNormalize(display: *Display, data: []const u8) (error{OutOfMemory})!void {
//        const bufferable = display.send_buffer.writable();
//        if (bufferable.len >= data.len) {
//            @memcpy(bufferable[0..data.len], data);
//            display.send_buffer.publish(data.len);
//        } else {
//            return error.OutOfMemory;
//        }
//    }
//
//    pub fn getQueue(display: Display) []u8 {
//        return display.send_buffer.writable();
//    }
//
//    pub fn canQueue(display: Display, size: usize) bool {
//        return display.send_buffer.space() >= size;
//    }
//
//    /// Advance the send buffer end cursor by `size`,
//    /// marking the first `size` bytes of the writable send buffer slice
//    /// as new data for sending at the next flush.
//    pub fn publishQueued(display: *Display, size: usize) void {
//        debug.assert(display.send_buffer.space() <= size);
//        if (display.send_buffer.publishWouldOverflow(size)) {
//            @branchHint(.cold);
//            display.send_buffer.normalize();
//        }
//        display.send_buffer.publish(size);
//    }
//
//    /// Send as much queued message data in one call as the stream will accept,
//    /// without blocking.
//    pub fn flush(display: *Display) void {
//        const buffered: []u8 = display.send_buffer.readable();
//        // TODO this is passing the double mapped ring buffer slice to sendmsg,
//        // i want to confirm that this causes no problems
//        if (buffered.len) {
//            const sent = display.stream.send(
//                &.{ .base = buffered.ptr, .len = buffered.len },
//                display.fd_send_queue.sendable(),
//                .{ .dont_wait = true },
//            ) catch |err| switch (err) {
//                error.WouldBlock => return,
//                else => |e| return e,
//            };
//            display.fd_send_queue.clear();
//            debug.assert(sent <= buffered.len);
//            @memset(buffered[0..sent], undefined);
//            display.send_buffer.consume(sent);
//            // TODO which is better
//            // if (sent == buffered.len) display.send_buffer.reset();
//            display.send_buffer.resetIfEmpty();
//        }
//        // TODO assert not empty?
//    }
//
//    /// Receive as much new message data in one call
//    /// as the stream will provide and there is buffer space for,
//    /// without blocking.
//    pub fn fill(display: *Display) void {
//        const bufferable: []u8 = display.receive_buffer.writable();
//        if (bufferable.len) {
//            if (display.receive_buffer.publishWouldOverflow(bufferable.len)) {
//                @branchHint(.cold);
//                display.receive_buffer.normalize();
//            }
//            const received, const received_control = display.stream.receive(
//                &.{ .base = bufferable.ptr, .len = bufferable.len },
//                display.control_buffer,
//                .{ .dont_wait = true },
//            ) catch |err| switch (err) {
//                error.WouldBlock => return,
//                else => |e| return e,
//            };
//            debug.assert(received <= bufferable.len);
//            display.receive_buffer.publish(received);
//            if (received_control) |control| {
//                var cmsg_iter: ipc.cmsg.Iterator = .{ .control = control };
//                while (cmsg_iter.nextMatching(.{ .socket = .rights })) |cmsg_data| {
//                    // TODO we have guarantee that cmsg will always slice exactly like this?
//                    const fds: []const system.fd_t = mem.bytesAsSlice(system.fd_t, cmsg_data);
//                    display.appendReceivedFds(fds) catch return error.AncillaryOverflow;
//                }
//            }
//            @memset(display.control_buffer, undefined);
//            if (received == 0) return error.EndOfStream;
//        }
//        // TODO assert not full?
//    }
//
//    fn appendReceivedFds(display: *Display, fds: []const system.fd_t) (error{OutOfMemory})!void {
//        const cap = display.fd_receive_capacity;
//        const len = display.fd_receive_queue.len;
//        if (cap - len >= fds.len) {
//            display.fd_receive_queue.len += fds.len;
//            @memcpy(display.fd_receive_queue[len..], fds);
//        } else {
//            return error.OutOfMemory;
//        }
//    }
//
//    pub const MinimumBufferCapacity = struct {
//        // TODO these are arbitrary defaults,
//        // in particular i think the max fds in one control send is defined by wayland somewhere
//        send: usize = 4096,
//        receive: usize = 4096,
//        /// Minimum control buffer size for receiving control data.
//        /// Linux documents that the maximum size of a single message of control data
//        /// can be queried at `/proc/sys/net/core/optmem_max`.
//        control: usize = 4096,
//        /// Minimum capacity of file descriptors to buffer until the next send.
//        fd_send: usize = 32,
//        /// Minimum capacity of file descriptors to buffer after receives
//        /// until they are parsed into the corresponding messages.
//        fd_receive: usize = 32,
//    };
//
//    pub fn connect(options: MinimumBufferCapacity) Display {
//        var display: Display = undefined;
//        try display.init(options);
//        return display;
//    }
//
//    /// Initialize a connection to the compositor,
//    /// opening a socket at the correct path according to the environment variables
//    /// and allocating full-page buffers to configured capacity.
//    pub fn init(display: *Display, options: MinimumBufferCapacity) void {
//        {
//            var addr: system.sockaddr.un = undefined;
//            @memset(mem.asBytes(&address), 0);
//            address.family = posix.AF.UNIX;
//            bufPrintDisplayPath(env, &addr.path);
//            display.stream = try .open(&address, .{ .nonblocking = true });
//        }
//        errdefer display.stream.close();
//        try display.initBuffers(options);
//        errdefer display.destroyBuffers();
//    }
//
//    pub fn initBuffers(display: *Display, cap: MinimumBufferCapacity) void {
//        // TODO bulk mmap?
//        const page_size = std.heap.pageSize();
//        display.send_buffer = try .create(ceilingMultiple(cap.send, page_size));
//        errdefer display.send_buffer.destroy();
//        display.receive_buffer = try .create(ceilingMultiple(cap.receive, page_size));
//        errdefer display.receive_buffer.destroy();
//
//        const fd_send_offset: usize = 0;
//        const fd_send_size = ipc.cmsg.space(cap.fd_send * @sizeOf(system.fd_t));
//        const fd_receive_offset = mem.alignForward(usize, fd_send_offset + fd_send_size, @alignOf(system.fd_t));
//        const fd_receive_size = cap.fd_receive * @sizeOf(system.fd_t);
//        const control_recv_offset = mem.alignForward(usize, fd_receive_offset + fd_receive_size, ipc.cmsg.algn);
//        const req_size = control_recv_offset + cap.control;
//        comptime debug.assert(std.heap.page_size_min % ipc.cmsg.algn == 0);
//        const control_total_size = mem.alignForward(usize, req_size, page_size);
//        const control = std.heap.PageAllocator.map(control_total_size, page_size)
//            orelse return error.OutOfMemory;
//        errdefer std.heap.PageAllocator.unmap(control);
//        @memset(control, undefined);
//
//        display.fd_send_queue = .init(control[fd_send_offset..][0..fd_send_size]);
//        const fd_receive_buffer: []system.fd_t = mem.bytesAsSlice(system.fd_t, control[fd_receive_offset..][0..fd_receive_size]);
//        display.fd_receive_queue = fd_receive_buffer[0..0];
//        display.fd_receive_capacity = fd_receive_buffer.len;
//        display.control_buffer = control[control_recv_offset..];
//        debug.assert(mem.isAligned(display.control_buffer.len, ipc.cmsg.algn));
//    }
//
//    pub fn deinit(display: *Display) void {
//        display.close();
//        display.* = undefined;
//    }
//
//    pub fn close(display: Display) void {
//        display.destroyBuffers();
//        ipc.closeFd(display.stream.socket);
//    }
//
//    pub fn destroyBuffers(display: Display) void {
//        std.heap.PageAllocator.unmap(display.controlBufferPages());
//        display.receive_buffer.free();
//        display.send_buffer.free();
//    }
//
//    pub fn controlBufferPages(display: Display) []align(std.heap.page_size_min) u8 {
//        const page_size = std.heap.pageSize();
//        const start: [*]u8 = display.fd_send_queue.ptr;
//        debug.assert(mem.isAligned(@intFromPtr(start), page_size));
//        debug.assert(display.fds_received.ptr > start);
//        debug.assert(display.control_buffer.ptr > display.fds_received.ptr);
//        const end_addr: usize = @intFromPtr(display.control_buffer.ptr) + display.control_buffer.len;
//        debug.assert(mem.isAligned(end_addr, page_size));
//        const len: usize = end_addr - @intFromPtr(start);
//        return @alignCast(start[0..len]);
//    }
//};

/// The environment may set an already-established connection to the Wayland display.
/// In such a case, returns what should be that socket's open file descriptor.
pub fn getPreconnectedSocket(env: process.Environ) (error{InvalidInteger})!?system.fd_t {
    return if (env.getPosix("WAYLAND_SOCKET")) |socket|
        std.fmt.parseInt(system.fd_t, socket, 10) catch return error.InvalidInteger
        else null;
}

// TODO how should it be handled if these keys are present but length 0
pub fn printDisplayPath(writer: *Io.Writer, env: process.Environ) (error{MissingXDGRuntimeDir} || Io.Writer.Error)!void {
    const display = env.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    if (display.len > 0 and fs.path.isSep(display[0])) {
        try writer.writeAll(display);
    } else {
        const runtime_dir = env.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingXDGRuntimeDir;
        try writer.writeAll(runtime_dir);
        try writer.writeByte(std.fs.path.sep);
        try writer.writeAll(display);
    }
}

// TODO with 0.16
///// Get what should be an already established socket connection to the display.
///// This may be set in cases such as being launched by a parent process
///// which configures a connection for us.
//pub fn discoverDisplayPreconnected(env: process.Environ) fmt.ParseIntError!?posix.fd_t {
//    if (env.getPosix(socket_env_key)) |env_socket| {
//        return try fmt.parseInt(posix.fd_t, env_socket, 10);
//    }
//    return null;
//}
//
///// Get the full path to the display, if set.
//pub fn discoverDisplayPathFull(env: process.Environ) ?[:0]const u8 {
//    const display = getEnvNonempty(env, display_env_key) orelse return null;
//    return if (fs.path.isSep(display[0])) display else null;
//}
//
///// Resolve the display socket path as configured by the environment.
///// Allocates the path name to be freed by the caller
///// only if the full path to the display is not set
///// (allocates when `discoverDisplayPathFull` returns `null`).
///// Returns `null` if no valid display location is configured.
//pub fn discoverDisplayPath(allocator: Allocator, env: process.Environ) Allocator.Error!?[:0]const u8 {
//    const display = getEnvNonempty(display_env_key) orelse fallback_display_name;
//    if (fs.path.isSep(display[0])) return display;
//    const runtime_dir = getEnvNonempty(env, runtime_dir_env_key) orelse return null;
//    const path = try allocator.allocSentinel(u8, runtime_dir.len + display.len + 1, 0);
//    @memcpy(path[0..runtime_dir.len], runtime_dir);
//    comptime assert(fs.path.isSep('/'));
//    path[runtime_dir.len] = '/';
//    @memcpy(path[runtime_dir.len+1..][0..display.len], display);
//    return path;
//}
//
//fn getEnvNonempty(env: process.Environ, key: []const u8) ?[:0]const u8 {
//    const get = env.getPosix(key) orelse return null;
//    return if (get.len != 0) get else null;
//}

//pub fn discoverDisplayPath(allocator: Allocator) Allocator.Error!?[:0]const u8 {
//    const display = getEnvNonempty(display_env_key) orelse fallback_display_name;
//    if (fs.path.isSep(display[0])) {
//        return try allocator.dupeZ(u8, display);
//    } else {
//        const runtime = getEnvNonempty(runtime_dir_env_key) orelse return null;
//        const path = try allocator.allocSentinel(u8, runtime.len + display.len + 1, 0);
//        @memcpy(path[0..runtime.len], runtime);
//        comptime assert(fs.path.isSep('/'));
//        path[runtime.len] = '/';
//        @memcpy(path[runtime.len+1..][0..display.len], display);
//        return path;
//    }
//}
//
//fn getEnvNonempty(key: []const u8) ?[:0]const u8 {
//    const get = posix.getenv(key) orelse return null;
//    return if (get.len != 0) get else null;
//}

const Io = std.Io;
const Allocator = mem.Allocator;

const ipc = root.ipc;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const posix = std.posix;
const process = std.process;
const system = std.posix.system;
const debug = std.debug;

const std = @import("std");
const root = @import("root.zig");
