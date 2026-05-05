/// Unix domain stream socket connected to a local process,
/// handling file descriptors transferred through ancillary data.
pub const DomainStream = struct {
    socket: system.fd_t,

    // TODO make packed struct
    pub const ConnectOptions = struct {
        /// Open the socket in nonblocking mode.
        nonblocking: bool = false,

        pub fn toInt(flags: ConnectOptions) u32 {
            return @as(u32, posix.SOCK.NONBLOCK) * @intFromBool(flags.nonblocking);
        }
    };

    // TODO make packed struct
    pub const SendReceiveOptions = struct {
        /// Per-call nonblocking mode.
        dont_wait: bool = false,

        pub fn toInt(flags: SendReceiveOptions) u32 {
            return @as(u32, system.MSG.DONTWAIT) * @intFromBool(flags.dont_wait);
        }
    };

    pub const SendError = error {
        /// The socket is not connected.
        SocketUnconnected,
        /// The socket is no longer connected.
        SocketDisconnected,
        /// The socket was forcibly closed by a peer.
        ConnectionResetByPeer,
        /// Insufficient system resources were available
        /// to perform the request.
        SystemResources,
        Unexpected,
    };

    pub const ReceiveError = error {
        /// The socket is not connected.
        SocketUnconnected,
        /// The socket is no longer connected.
        SocketDisconnected,
        /// The socket was forcibly closed by a peer.
        ConnectionResetByPeer,
        /// Data was received, but some ancillary data was lost
        /// due to insufficient control buffer size.
        AncillaryOverflow,
        /// Insufficient system resources were available
        /// to perform the request.
        SystemResources,
        /// The process's limit on open files was exceeded.
        ProcessFdQuotaExceeded,
        /// The system-wide limit on open files was exceeded.
        SystemFdQuotaExceeded,
        Unexpected,
    };

    /// If `stream` is `const`, close with `closeFd(stream.socket)`
    pub fn close(stream: *DomainStream) void {
        closeFd(stream.socket);
        stream.* = undefined;
    }

    /// Asserts the `address.path` contains a `0`-terminated path.
    pub fn open(address: *const system.sockaddr.un, options: ConnectOptions) !DomainStream {
        //// TODO how do i know whether the system wants sockaddr or sockaddr_un?
        //const Address = system.sockaddr.un;
        //// `-1` to always leave a sentinel TODO is that necessary?
        //const max_path_len = @typeInfo(@FieldType(Address, "path")).array.len - 1;
        //if (path.len > max_path_len) return error.NameTooLong;
        //if (path.len == 0) return error.PathEmpty;

        const socket_fd: system.fd_t = while (true) {
            // TODO on non linux systems we just have to see if some flags are present
            // and if they aren't, then do this in the posix compliant way with fcntl
            if (native_os != .linux) @compileError("unsupported");
            const rc = system.socket(
                posix.AF.UNIX,
                posix.SOCK.STREAM | posix.SOCK.CLOEXEC | options.toInt(),
                0,
            );
            switch (system.errno(rc)) {
                .SUCCESS => {
                    const fd: system.fd_t = @intCast(rc);
                    break fd;
                },
                .INTR => continue,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported, // TODO is errnoBug?
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                // Errors caused by invalid parameters, which are hardcoded above
                .INVAL => |err| return errnoBug(err),
                .PROTONOSUPPORT => |err| return errnoBug(err),
                .PROTOTYPE => |err| return errnoBug(err),
                else => |err| return posix.unexpectedErrno(err),
            }
        };
        errdefer closeFd(socket_fd);

        //const address = addr: {
        //    var addr: Address = .{
        //        .family = posix.AF.UNIX,
        //        .path = @splat(0),
        //    };
        //    @memcpy(addr.path[0..path.len], path);
        //    break :addr addr;
        //};
        if (address.family != posix.AF.UNIX) unreachable;
        const path_len = for (address.path, 0..) |char, i| {
            if (char == 0) break i;
        } else unreachable; // assert the passed path is null-terminated
        const address_len: system.socklen_t = @intCast(@offsetOf(system.sockaddr.un, "path") + path_len + 1);

        while (true) {
            // TODO remove ptrcast in 0.16 where the address is anyopaque
            switch (system.errno(system.connect(socket_fd, @ptrCast(address), address_len))) {
                .SUCCESS => break,
                .INTR => continue,
                .ISCONN => return error.IsConnected,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported, // TODO possible to still see here?
                .AGAIN => return error.WouldBlock, // TODO poll and retry
                .INPROGRESS => return error.WouldBlock, // TODO poll and retry
                .ACCES => return error.AccessDenied,
                .LOOP => return error.SymLinkLoop,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .ROFS => return error.ReadOnlyFileSystem,
                .PERM => return error.PermissionDenied,
                .PROTOTYPE => return error.InvalidProtocolType, // TODO does this make sense here
                // The socket FD was opened directly preceding this
                .BADF => |err| return errnoBug(err),
                .CONNABORTED => |err| return errnoBug(err),
                .FAULT => |err| return errnoBug(err),
                .NOTSOCK => |err| return errnoBug(err),
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        return .{ .socket = socket_fd };
    }

    /// Returns the number of bytes sent.
    /// If successful, all control data is sent.
    /// On failure, no data or control data is sent.
    ///
    /// Asserts `data` is not empty,
    /// each buffer of `data` is not empty,
    /// and the size of `control_buffer` is `CMSG`-aligned.
    ///
    /// Blocks, or returns `error.WouldBlock`,
    /// when the kernel's send buffer is full
    /// (the peer has not yet received previous messages).
    pub fn send(
        stream: DomainStream,
        data: []const posix.iovec_const,
        control: ?[]const align(cmsg.algn) u8,
        options: SendReceiveOptions,
    ) (SendError || error{WouldBlock})!usize {
        if (data.len == 0) unreachable;
        for (data) |buf| { if (buf.len == 0) unreachable; }
        if (control) |buffer| { if (!cmsg.alignment.check(buffer.len)) unreachable; }

        const msg: system.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = data.ptr,
            .iovlen = data.len,
            .control = if (control) |buffer| buffer.ptr else null,
            .controllen = if (control) |buffer| buffer.len else 0,
            .flags = 0,
        };

        while (true) {
            const rc = system.sendmsg(
                stream.socket,
                &msg,
                system.MSG.NOSIGNAL | options.toInt(),
            );
            switch (system.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,

                .PIPE => return error.SocketDisconnected,
                .NOTCONN => return error.SocketUnconnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,

                .ISCONN => |err| return errnoBug(err), // provided destination address in connected stream socket
                .BADF => |err| return errnoBug(err), // use after close
                .NOTSOCK => |err| return errnoBug(err),
                .OPNOTSUPP => |err| return errnoBug(err), // unsupported flag
                .FAULT => |err| return errnoBug(err), // invalid memory
                .INVAL => |err| return errnoBug(err), // invalid `msghdr` contents

                .AFNOSUPPORT => |err| return errnoBug(err), // should error at open ? TODO
                .ALREADY => |err| return errnoBug(err), // FASTOPEN never used for domain sockets
                .MSGSIZE => |err| return errnoBug(err), // Never for stream sockets
                .HOSTUNREACH => |err| return errnoBug(err), // IP networking only
                .NETUNREACH => |err| return errnoBug(err), // IP networking only
                .NETDOWN => |err| return errnoBug(err), // IP networking only
                .DESTADDRREQ => |err| return errnoBug(err), // unconnected datagram socket (we are always stream)
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    /// Returns the number of bytes and ancillary data received.
    /// 0 bytes read indicates end of stream.
    ///
    /// Asserts `data` is not empty,
    /// each buffer of `data` is not empty,
    /// and the size of `control_buffer` is `CMSG`-aligned.
    ///
    /// Blocks, or returns `error.WouldBlock`,
    /// when the kernel's receive buffer is empty, but still open
    /// (the other process has not yet sent any new data).
    pub fn receive(
        stream: DomainStream,
        data: []posix.iovec,
        control_buffer: []align(cmsg.algn) u8,
        options: SendReceiveOptions,
    ) (ReceiveError || error{WouldBlock})!struct{ usize, ?[]align(cmsg.algn) u8 } {
        if (data.len == 0) unreachable;
        for (data) |buf| { if (buf.len == 0) unreachable; }
        if (!cmsg.alignment.check(control_buffer.len)) unreachable;

        var msg: system.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = data.ptr,
            .iovlen = data.len,
            .control = control_buffer.ptr,
            .controllen = control_buffer.len,
            .flags = undefined,
        };

        while (true) {
            const rc = system.recvmsg(
                stream.socket,
                &msg,
                // TODO NOSIGNAL is ignored for recvmsg?
                system.MSG.NOSIGNAL | options.toInt(),
            );
            switch (system.errno(rc)) {
                .SUCCESS => {
                    if (msg.flags & posix.MSG.EOR != 0) unreachable; // never for stream sockets
                    if (msg.flags & posix.MSG.OOB != 0) unreachable; // never for Unix domain sockets
                    if (msg.flags & posix.MSG.TRUNC != 0) unreachable; // never for stream sockets
                    if (msg.flags & posix.MSG.CTRUNC != 0) return error.AncillaryOverflow;
                    return .{
                        @intCast(rc),
                        if (msg.control) |ptr| @alignCast(@as([*]u8, @ptrCast(ptr))[0..msg.controllen]) else null,
                    };
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,

                .PIPE => return error.SocketDisconnected, // TODO this is send-side, not receive-side?
                .NOTCONN => return error.SocketUnconnected,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,

                .BADF => |err| return errnoBug(err), // use after close
                .NOTSOCK => |err| return errnoBug(err),
                .OPNOTSUPP => |err| return errnoBug(err), // unsupported flag
                .FAULT => |err| return errnoBug(err), // invalid memory
                .INVAL => |err| return errnoBug(err), // invalid `msghdr` contents

                .MSGSIZE => |err| return errnoBug(err), // Never for stream sockets
                .NETDOWN => |err| return errnoBug(err), // IP networking only
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    /// Send as much data queued for sending in the `TransferQueue`
    /// as the stream will accept in one call.
    pub fn drainQueue(
        stream: DomainStream,
        queue: *TransferQueue,
        options: SendReceiveOptions,
    ) (SendError || error{WouldBlock})!void {
        const buffered: []u8 = queue.send.readable();
        // TODO confirm passing the double mapped ring buffer slice to sendmsg causes no problems
        if (buffered.len > 0) {
            const sent_size = try stream.send(
                &.{ .{ .base = buffered.ptr, .len = buffered.len } },
                queue.fd_send.sendable(),
                options,
            );
            queue.fd_send.clear();
            if (sent_size > buffered.len) unreachable;
            @memset(buffered[0..sent_size], undefined);
            queue.send.consume(sent_size);
            queue.send.resetIfEmpty();
        }
    }

    pub fn fillQueue(
        stream: DomainStream,
        queue: *TransferQueue,
        options: SendReceiveOptions,
    ) (error{EndOfStream} || ReceiveError || error{WouldBlock})!void {
        const bufferable: []u8 = queue.receive.writable();
        if (bufferable.len > 0) {
            var recv_data: [1]posix.iovec = .{ .{ .base = bufferable.ptr, .len = bufferable.len } };
            const received_size, const received_control = try stream.receive(
                &recv_data,
                queue.control,
                options,
            );
            if (received_size > bufferable.len) unreachable;
            if (queue.receive.publishWillOverflow(received_size)) {
                @branchHint(.cold);
                queue.receive.normalize();
            }
            queue.receive.publish(received_size);
            if (received_control) |control| {
                var cmsg_iter: cmsg.Iterator = .{ .control = control };
                while (cmsg_iter.nextMatching(.{ .socket = .rights })) |cmsg_data| {
                    // TODO we have guarantee that cmsg will always slice exactly like this?
                    const fds: []const align(1) system.fd_t = mem.bytesAsSlice(system.fd_t, cmsg_data);
                    queue.receivedFdsAppend(fds) catch return error.AncillaryOverflow;
                }
            }
            @memset(queue.control, undefined);
            if (received_size == 0) return error.EndOfStream;
        }
    }

    pub fn fillQueueNoNormalize(
        stream: DomainStream,
        queue: *TransferQueue,
        options: SendReceiveOptions,
    ) (error{EndOfStream} || ReceiveError || error{WouldBlock})!void {
        const bufferable: []u8 = stream.receive.writable();
        if (bufferable.len > 0) {
            var recv_data: [1]posix.iovec = .{ .base = bufferable.ptr, .len = bufferable.len };
            const received_size, const received_control = try stream.receive(
                &recv_data,
                queue.control,
                options,
            );
            if (received_size > bufferable.len) unreachable;
            queue.receive.publish(received_size);
            if (received_control) |control| {
                var cmsg_iter: cmsg.Iterator = .{ .control = control };
                while (cmsg_iter.nextMatching(.{ .socket = .rights })) |cmsg_data| {
                    // TODO we have guarantee that cmsg will always slice exactly like this?
                    const fds: []const align(1) system.fd_t = mem.bytesAsSlice(system.fd_t, cmsg_data);
                    queue.receivedFdsAppend(fds) catch return error.AncillaryOverflow;
                }
            }
            @memset(queue.control, undefined);
            if (received_size == 0) return error.EndOfStream;
        }
    }

    pub fn reader(
        stream: DomainStream,
        data_buffer: []u8,
        control_buffer: []align(cmsg.algn) u8,
        fd_buffer: []system.fd_t,
    ) Reader {
        return .init(stream, data_buffer, control_buffer, fd_buffer);
    }

    pub fn writer(
        stream: DomainStream,
        data_buffer: []u8,
        control_buffer: []align(cmsg.algn) u8,
    ) Writer {
        return .init(stream, data_buffer, control_buffer);
    }

    // TODO was copied arbitrarily
    pub const max_iovecs_count = 8;
    // TODO was copied arbitrarily
    pub const splat_buffer_size = 64;

    /// Populates with transferred file descriptors
    /// as they are received during reading.
    pub const Reader = struct {
        pub const FdIndex = u8;

        interface: Io.Reader,
        stream: DomainStream,
        control_buffer: []align(cmsg.algn) u8,
        fd_buf: [*]system.fd_t,
        fd_cap: FdIndex,
        fd_seek: FdIndex,
        fd_end: FdIndex,
        err: ?ReceiveError,

        pub fn init(
            stream: DomainStream,
            data_buffer: []u8,
            control_buffer: []align(cmsg.algn) u8,
            fd_buffer: []system.fd_t,
        ) Reader {
            if (!std.math.isPowerOfTwo(fd_buffer.len)) unreachable;
            return .{
                .interface = .{
                    .vtable = &.{
                        .stream = streamImpl,
                        .readVec = readVecImpl,
                    },
                    .buffer = data_buffer,
                    .seek = 0,
                    .end = 0,
                },
                .stream = stream,
                .control_buffer = control_buffer,
                .fd_buf = fd_buffer.ptr,
                .fd_cap = @intCast(fd_buffer.len),
                .fd_seek = 0,
                .fd_end = 0,
                .err = null,
            };
        }

        fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const dest = limit.slice(try io_w.writableSliceGreedy(1));
            var data: [1][]u8 = .{dest};
            const n = try io_r.readVec(&data);
            io_w.advance(n);
            return n;
        }

        fn readVecImpl(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
            var iovecs_buffer: [max_iovecs_count]posix.iovec = undefined;
            const dest_n, const data_size = try io_r.writableVectorPosix(&iovecs_buffer, data);
            const dest = iovecs_buffer[0..dest_n];
            if (dest[0].len == 0) unreachable;
            const n, const control = r.stream.receive(
                dest,
                r.control_buffer,
                .{},
            ) catch |err| switch (err) {
                // TODO async awareness here.
                // this currently causes fills on nonblocking sockets to just spin
                error.WouldBlock => return 0,
                else => |e| {
                    r.err = e;
                    return error.ReadFailed;
                },
            };
            if (control) |c| {
                var cmsg_iter: cmsg.Iterator = .{ .control = c };
                while (cmsg_iter.nextMatching(.{ .socket = .rights })) |cmsg_data| {
                    // TODO we have guarantee that cmsg will always slice exactly like this?
                    const fds: []const system.fd_t = @alignCast(mem.bytesAsSlice(system.fd_t, cmsg_data));
                    r.appendFds(fds) catch |err| switch (err) {
                        error.OutOfMemory => {
                            r.err = error.AncillaryOverflow;
                            return error.ReadFailed;
                        },
                    };
                }
            }
            if (n == 0) {
                return error.EndOfStream;
            }
            if (n > data_size) {
                r.interface.end += n - data_size;
                return data_size;
            }
            return n;
        }

        pub fn fdBuffer(r: Reader) []system.fd_t {
            return r.fd_buf[0..r.fd_cap];
        }

        pub fn takeFd(r: *Reader) ?system.fd_t {
            return if (r.takeFds(1)) |fds| fds else null;
        }

        pub fn takeFds(r: *Reader, comptime n: FdIndex) ?[n]system.fd_t {
            if (r.fd_end > r.fd_cap) unreachable;
            const len = r.fd_end - r.fd_seek;
            if (len >= n) {
                const fds: [n]system.fd_t = r.fd_buf[r.fd_seek..][0..n].*;
                @memset(r.fd_buf[r.fd_seek..][0..n], undefined);
                if (len == n) {
                    r.fd_seek = 0;
                    r.fd_end = 0;
                } else {
                    r.fd_seek += n;
                }
                return fds;
            } else {
                return null;
            }
        }

        pub fn getAllFds(r: Reader) []system.fd_t {
            if (r.fd_end > r.fd_cap) unreachable;
            return r.fd_buf[r.fd_seek..r.fd_end];
        }

        /// Release the first `n` FDs that have been received.
        pub fn tossFds(r: *Reader, n: FdIndex) void {
            const len = r.fd_end - r.fd_seek;
            if (n >= len) unreachable;
            @memset(r.getAllFds()[0..n], undefined);
            if (n == len) {
                r.fd_seek = 0;
                r.fd_end = 0;
            } else {
                r.fd_seek += n;
            }
        }

        /// Release all received and untossed FDs.
        pub fn tossAllFds(r: *Reader) void {
            @memset(r.getAllFds(), undefined);
            r.fd_seek = 0;
            r.fd_end = 0;
        }

        pub fn appendFds(r: *Reader, fds: []const system.fd_t) error{OutOfMemory}!void {
            const len = r.fd_end - r.fd_seek;
            const buffer = r.fdBuffer();
            if (buffer.len - @as(usize, len) >= fds.len) {
                if (buffer.len - r.fd_end < fds.len) {
                    @branchHint(.unlikely);
                    @memmove(buffer[0..len], buffer[r.fd_seek..][0..len]);
                    @memset(buffer[len..][0..r.fd_seek], undefined);
                    r.fd_seek = 0;
                    r.fd_end = len;
                }
                @memcpy(buffer[r.fd_end..][0..fds.len], fds);
                r.fd_end += @intCast(fds.len);
            } else {
                return error.OutOfMemory;
            }
        }
    };

    pub const Writer = struct {
        interface: Io.Writer,
        stream: DomainStream,
        /// Ancillary buffer with queued file descriptors,
        /// which will all be transferred together on the next successful drain.
        ///
        /// Add FDs to `control` **before** writing the positionally corresponding data.
        control: ControlBuffer,
        err: ?SendError,

        pub fn init(
            stream: DomainStream,
            data_buffer: []u8,
            control_buffer: []align(cmsg.algn) u8,
        ) Writer {
            return .{
                .interface = .{
                    .vtable = &.{
                        .drain = drainImpl,
                    },
                    .buffer = data_buffer,
                },
                .stream = stream,
                .control = .init(control_buffer),
                .err = null,
            };
        }

        fn drainImpl(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
            var iovecs: [max_iovecs_count]posix.iovec_const = undefined;
            var iovecs_count: usize = 0;
            var splat_buffer: [splat_buffer_size]u8 = undefined;
            {
                addBuf(&iovecs, &iovecs_count, io_w.buffered());
                for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &iovecs_count, bytes);
                const pattern = data[data.len - 1];
                if (iovecs.len - iovecs_count != 0) switch (splat) {
                    0 => {},
                    1 => addBuf(&iovecs, &iovecs_count, pattern),
                    else => switch (pattern.len) {
                        0 => {},
                        1 => {
                            const buf = splat_buffer[0..@min(splat_buffer.len, splat)];
                            @memset(buf, pattern[0]);
                            addBuf(&iovecs, &iovecs_count, buf);
                            var remaining_splat = splat - buf.len;
                            while (remaining_splat > splat_buffer.len and iovecs.len - iovecs_count != 0) {
                                if (buf.len != splat_buffer.len) unreachable;
                                addBuf(&iovecs, &iovecs_count, &splat_buffer);
                                remaining_splat -= splat_buffer.len;
                            }
                            addBuf(&iovecs, &iovecs_count, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
                        },
                        else => for (0..@min(splat, iovecs.len - iovecs_count)) |_| {
                            addBuf(&iovecs, &iovecs_count, pattern);
                        },
                    },
                };
            }
            if (iovecs_count == 0) unreachable;
            const n = w.stream.send(
                iovecs[0..iovecs_count],
                w.control.sendable(),
                .{},
            ) catch |err| switch (err) {
                // TODO async awareness here.
                // this currently causes flushes on nonblocking sockets to just spin
                error.WouldBlock => return 0,
                else => |e| {
                    w.err = e;
                    return error.WriteFailed;
                },
            };
            w.control.clear();
            return io_w.consume(n);
        }

        /// Copied directly: `std.Io.Threaded.addBuf`
        fn addBuf(v: []posix.iovec_const, i: *usize, bytes: []const u8) void {
            // OS checks ptr addr before length so zero length vectors must be omitted.
            if (bytes.len == 0) return;
            if (v.len - i.* == 0) return;
            v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
            i.* += 1;
        }
    };
};

// TODO this is currently tightly packing fds when it should be aware of their alignment?

/// A control buffer containing a single `SCM_RIGHTS` message,
/// with a set of file descriptors to be transferred.
///
/// TODO linux specifies a maximum control buffer size at `/proc/sys/net/core/optmem_max`
/// that could be checked
pub const ControlBuffer = struct {
    buffer: []align(cmsg.algn) u8,

    pub fn getHeader(control: ControlBuffer) *cmsg.hdr {
        const hdr: *cmsg.hdr = @ptrCast(control.buffer.ptr);
        // If these asserts fail, the beginning of the buffer
        // was mutated after initialization or was not initialized correctly.
        if (hdr.pad0 != 0) unreachable;
        if (hdr.pad1 != 0) unreachable;
        if (hdr.len < cmsg.hdr.data_offset) unreachable;
        if (hdr.level != .socket) unreachable;
        if (hdr.@"type".socket != .rights) unreachable;
        return hdr;
    }

    pub fn getData(control: ControlBuffer) []u8 {
        const hdr = control.getHeader();
        return control.buffer[0..hdr.len][cmsg.hdr.data_offset..];
    }

    pub fn bufferedFds(control: ControlBuffer) []system.fd_t {
        return mem.bytesAsSlice(system.fd_t, control.data());
    }

    pub fn appendFd(control: ControlBuffer, fd: system.fd_t) error{OutOfMemory}!void {
        return control.appendFds(&.{fd});
    }

    pub fn appendFds(control: ControlBuffer, fds: []const system.fd_t) error{OutOfMemory}!void {
        return control.append(mem.sliceAsBytes(fds));
    }

    // TODO test append

    pub fn append(control: ControlBuffer, data: []const u8) error{OutOfMemory}!void {
        const hdr = control.getHeader();
        const dest = control.buffer[hdr.len..];
        if (dest.len >= data.len) {
            @memcpy(dest[0..data.len], data);
            hdr.len += data.len;
        } else {
            return error.OutOfMemory;
        }
    }

    pub fn sendable(control: ControlBuffer) ?[]align(cmsg.algn) u8 {
        const l = control.getHeader().len;
        debug.assert(l >= cmsg.hdr.data_offset);
        if (l == cmsg.hdr.data_offset) {
            return null;
        } else {
            const ctrl = control.buffer[0..cmsg.alignment.forward(l)];
            for (ctrl[l..]) |pad| { if (pad != 0) unreachable; }
            return ctrl;
        }
    }

    pub fn clear(control: ControlBuffer) void {
        control.getHeader().len = cmsg.hdr.data_offset;
        @memset(control.buffer[@sizeOf(cmsg.hdr)..], 0);
    }

    pub fn fromBuffer(buffer: []align(cmsg.algn) u8) ControlBuffer {
        const hdr: *cmsg.hdr = @ptrCast(buffer.ptr);
        // If these asserts fail, the beginning of the buffer
        // was mutated after initialization or was not initialized correctly.
        if (hdr.pad0 != 0) unreachable;
        if (hdr.pad1 != 0) unreachable;
        if (hdr.len < cmsg.hdr.data_offset) unreachable;
        if (hdr.level != .socket) unreachable;
        if (hdr.@"type".socket != .rights) unreachable;
        return .{ .buffer = buffer };
    }

    pub fn init(buffer: []align(cmsg.algn) u8) ControlBuffer {
        @memset(buffer, 0);
        const hdr: *cmsg.hdr = @ptrCast(buffer.ptr);
        hdr.* = .{
            .len = cmsg.hdr.data_offset,
            .level = .socket,
            .@"type" = .{ .socket = .rights },
        };
        return .{ .buffer = buffer };
    }

    /// Returns necessary byte length to buffer a single control message
    /// of at most `capacity` items.
    ///
    /// Due to end padding requirements,
    /// the returned size may have a corresponding capacity
    /// greater than what was requested.
    pub fn sizeFromCapacity(comptime Item: type, capacity: usize) usize {
        return cmsg.space(capacity * @sizeOf(Item));
    }

    pub fn capacityFromSize(comptime Item: type, size: usize) usize {
        return @divFloor(
            size - cmsg.hdr.data_offset,
            @sizeOf(Item),
        );
    }
};

// TODO improvements:
// - variant that parses with ring buffer wrap awareness
//   (or eats cost of memmoving contents on overflow)
//   and can be initialized with std alloced slices

/// Collection of buffers for queuing to-be-sent and received data
/// and transferred file descriptors through a stream socket.
///
/// Allocates buffers directly with `mmap` in order to double-map ring buffers.
pub const TransferQueue = struct {
    send: MirrorRing,
    receive: MirrorRing,
    fd_send: ControlBuffer,
    /// Access this field directly to peek received fds.
    fd_receive: []system.fd_t,
    fd_receive_capacity: usize,
    control: []align(cmsg.algn) u8,

    // TODO these are arbitrary defaults,
    // in particular i think the max fds in one control send is defined by e.g. wayland somewhere
    pub const InitOptions = struct {
        send_capacity_minimum: usize = std.heap.page_size_min,
        receive_capacity_minimum: usize = std.heap.page_size_min,
        /// Minimum buffer size for receiving control data.
        /// Linux documents that the maximum size of a single message of control data
        /// can be found at `/proc/sys/net/core/optmem_max`.
        control_capacity_minimum: usize = std.heap.page_size_min,
        /// Minimum capacity of file descriptors to buffer until the next send.
        fd_send_capacity_minimum: usize = 32,
        /// Minimum capacity of file descriptors to buffer after receives
        /// until they are consumed following the read.
        fd_receive_capacity_minimum: usize = 32,
    };

    pub const InitError = MirrorRing.CreateError || mem.Allocator.Error;

    pub fn create(options: InitOptions) InitError!TransferQueue {
        var buffers: TransferQueue = undefined;
        try buffers.init(options);
        return buffers;
    }

    /// Allocates with the global page allocator.
    pub fn init(buffers: *TransferQueue, options: InitOptions) InitError!void {
        // TODO bulk mmap?
        const page_size = std.heap.pageSize();
        buffers.send = try .create(ceilingMultiple(options.send_capacity_minimum, page_size));
        errdefer buffers.send.destroy();
        buffers.receive = try .create(ceilingMultiple(options.receive_capacity_minimum, page_size));
        errdefer buffers.receive.destroy();

        const fd_send_offset: usize = 0;
        const fd_send_size = cmsg.space(options.fd_send_capacity_minimum * @sizeOf(system.fd_t));
        const fd_receive_offset = mem.alignForward(usize, fd_send_offset + fd_send_size, @alignOf(system.fd_t));
        const fd_receive_size = options.fd_receive_capacity_minimum * @sizeOf(system.fd_t);
        const control_recv_offset = mem.alignForward(usize, fd_receive_offset + fd_receive_size, cmsg.algn);
        const req_size = control_recv_offset + options.control_capacity_minimum;
        // Want to ensure the control buffer extends to the very end of the last page
        if (std.heap.page_size_min % cmsg.algn != 0) comptime unreachable;
        const control_total_size = mem.alignForward(usize, req_size, page_size);

        // TODO have not checked that this slices properly
        const control: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @alignCast(std.heap.PageAllocator.map(
            control_total_size,
            .fromByteUnits(page_size),
        ) orelse return error.OutOfMemory))[0..control_total_size];
        errdefer std.heap.PageAllocator.unmap(control);
        @memset(control, undefined);

        if (fd_send_offset != 0) unreachable;
        buffers.fd_send = .init(control[fd_send_offset..][0..fd_send_size]);
        const fd_receive_buffer: []system.fd_t = @alignCast(mem.bytesAsSlice(system.fd_t, control[fd_receive_offset..][0..fd_receive_size]));
        buffers.fd_receive = fd_receive_buffer[0..0];
        buffers.fd_receive_capacity = fd_receive_buffer.len;
        buffers.control = @alignCast(control[control_recv_offset..]);
        if (!mem.isAligned(buffers.control.len, cmsg.algn)) unreachable;
    }

    pub fn deinit(buffers: *TransferQueue) void {
        buffers.destroy();
        buffers.* = undefined;
    }

    pub fn destroy(buffers: TransferQueue) void {
        std.heap.PageAllocator.unmap(buffers.controlPages());
        buffers.receive.free();
        buffers.send.free();
    }

    pub fn receivedDataPeek(buffers: *const TransferQueue) []u8 {
        return buffers.receive.readable();
    }

    /// Asserts that at least `size` bytes are buffered in the receive buffer.
    pub fn receivedDataToss(buffers: *TransferQueue, size: usize) void {
        @memset(buffers.receive.readable()[0..size], undefined);
        buffers.receive.consume(size);
        buffers.receive.resetIfEmpty();
    }

    /// Asserts that at least `size` bytes are buffered in the receive buffer.
    pub fn receivedDataTossNoReset(buffers: *TransferQueue, size: usize) void {
        @memset(buffers.receive.readable()[0..size], undefined);
        buffers.receive.consume(size);
    }

    /// Asserts that at least `count` fds are buffered in `fd_receive`.
    /// Prefer to batch this into one call after a series of parsed messages,
    /// to avoid unnecessary repeated `memmove`s.
    pub fn receivedFdsToss(buffers: *TransferQueue, count: usize) void {
        if (count == buffers.fd_receive.len) {
            @memset(buffers.fd_receive, undefined);
            buffers.fd_receive.len = 0;
        } else if (count < buffers.fd_receive.len) {
            const new_len = buffers.fd_receive.len - count;
            @memmove(buffers.fd_receive[0..new_len], buffers.fd_receive[count..]);
            @memset(buffers.fd_receive[new_len..], undefined);
            buffers.fd_receive.len = new_len;
        } else {
            unreachable;
        }
    }

    pub fn receivedFdsAppend(buffers: *TransferQueue, fds: []const align(1) system.fd_t) (error{OutOfMemory})!void {
        const cap = buffers.fd_receive_capacity;
        const len = buffers.fd_receive.len;
        if (cap - len >= fds.len) {
            buffers.fd_receive.len += fds.len;
            @memcpy(buffers.fd_receive[len..], fds);
        } else {
            return error.OutOfMemory;
        }
    }

    /// Add new data to the send buffer to be sent.
    pub fn sendDataAppend(buffers: *TransferQueue, data: []const u8) (error{OutOfMemory})!void {
        const bufferable = buffers.send.writable();
        if (bufferable.len >= data.len) {
            if (buffers.send.publishWillOverflow(data.len)) {
                @branchHint(.cold);
                buffers.send.normalize();
            }
            @memcpy(bufferable[0..data.len], data);
            buffers.send.publish(data.len);
        } else {
            return error.OutOfMemory;
        }
    }

    /// Add new data to the send buffer to be sent.
    ///
    /// Overflows the ring buffer cursor after `maxInt(usize)` bytes of buffered data
    /// (~4GB on 32-bit systems), if not resetting or the buffer is never empty for a reset.
    pub fn sendDataAppendNoNormalize(buffers: *TransferQueue, data: []const u8) (error{OutOfMemory})!void {
        const bufferable = buffers.send.writable();
        if (bufferable.len >= data.len) {
            @memcpy(bufferable[0..data.len], data);
            buffers.send.publish(data.len);
        } else {
            return error.OutOfMemory;
        }
    }

    pub fn sendDataWritable(buffers: TransferQueue) []u8 {
        return buffers.send.writable();
    }

    /// Advance the send buffer end cursor by `size`,
    /// marking the next `size` bytes of the writable send buffer slice
    /// as new data to be sent.
    ///
    /// Asserts there was at least `size` bytes of space remaining in the send buffer.
    pub fn sendDataPublish(buffers: *TransferQueue, size: usize) void {
        if (buffers.send.space() <= size) unreachable;
        if (buffers.send.publishWillOverflow(size)) {
            @branchHint(.cold);
            buffers.send.normalize();
        }
        buffers.send.publish(size);
    }

    /// Advance the send buffer end cursor by `size`,
    /// marking the next `size` bytes of the writable send buffer slice
    /// as new data to be sent.
    ///
    /// Asserts there was at least `size` bytes of space remaining in the send buffer.
    ///
    /// Overflows the ring buffer cursor after `maxInt(usize)` bytes of buffered data
    /// (~4GB on 32-bit systems), if not resetting or the buffer is never empty for a reset.
    pub fn sendDataPublishNoNormalize(buffers: *TransferQueue, size: usize) void {
        if (buffers.send.space() <= size) unreachable;
        buffers.send.publish(size);
    }

    pub fn controlPages(buffers: TransferQueue) []align(std.heap.page_size_min) u8 {
        const page_size = std.heap.pageSize();
        const start: [*]u8 = buffers.fd_send.buffer.ptr;
        if (!mem.isAligned(@intFromPtr(start), page_size)) unreachable;
        if (@intFromPtr(buffers.fd_receive.ptr) < @intFromPtr(start)) unreachable;
        if (@intFromPtr(buffers.control.ptr) < @intFromPtr(buffers.fd_receive.ptr)) unreachable;
        const end_addr: usize = @intFromPtr(buffers.control.ptr) + buffers.control.len;
        if (!mem.isAligned(end_addr, page_size)) unreachable;
        const len: usize = end_addr - @intFromPtr(start);
        return @alignCast(start[0..len]);
    }
};

/// A ring buffer kept on double-mapped pages,
/// for which access past the buffer is wrapped by virtual addressing,
/// allowing reads and writes to assume contiguity.
pub const MirrorRing = struct {
    buffer: [*]align(std.heap.page_size_min) u8,
    capacity: usize,
    head: usize,
    tail: usize,

    // TODO atomic variants

    // TODO non-aliased halves as iovec variants

    // TODO which if any fns should be inline

    pub fn index(ring: MirrorRing, cursor: usize) usize {
        if (ring.capacity & (ring.capacity - 1) != 0) unreachable;
        return cursor & (ring.capacity - 1);
    }

    pub fn len(ring: MirrorRing) usize {
        return ring.head - ring.tail;
    }

    pub fn space(ring: MirrorRing) usize {
        return ring.capacity - ( ring.head - ring.tail );
    }

    pub fn readable(ring: MirrorRing) []u8 {
        const read = ring.index(ring.tail);
        const available = ring.len();
        if (available > ring.capacity) unreachable;
        return (ring.buffer + read)[0..available];
    }

    pub fn writable(ring: MirrorRing) []u8 {
        const write = ring.index(ring.head);
        const available = ring.space();
        return (ring.buffer + write)[0..available];
    }

    pub fn consume(ring: *MirrorRing, size: usize) void {
        if (ring.head - ring.tail < size) unreachable;
        ring.tail += size;
    }

    /// It is unlikely, although technically possible
    /// (after ~4GB of buffered data on 32-bit systems),
    /// that the cursor may eventually integer overflow,
    /// because it is advanced monotonically.
    pub fn publish(ring: *MirrorRing, size: usize) void {
        ring.head += size;
        if (ring.head - ring.tail > ring.capacity) unreachable;
    }

    /// It is unlikely, although technically possible
    /// (after ~4GB of buffered data on 32-bit systems),
    /// that the cursor may eventually integer overflow,
    /// because it is advanced monotonically.
    pub fn publishCheckOverflow(ring: *MirrorRing, size: usize) (error{Overflow})!void {
        ring.head = try std.math.add(@TypeOf(ring.head), ring.head, size);
        if (ring.head - ring.tail > ring.capacity) unreachable;
    }

    /// Returns `true` if a publish of `size` would overflow the cursor.
    ///
    /// It is unlikely, although technically possible
    /// (after ~4GB of buffered data on 32-bit systems),
    /// that the cursor may eventually integer overflow,
    /// because it is advanced monotonically.
    pub fn publishWillOverflow(ring: MirrorRing, size: usize) bool {
        return if (std.math.add(@TypeOf(ring.head), ring.head, size)) |_| false else |_| true;
    }

    /// Asserts the buffer is empty.
    pub fn reset(ring: *MirrorRing) void {
        if (ring.head - ring.tail != 0) unreachable;
        ring.head = 0;
        ring.tail = 0;
    }

    pub fn resetIfEmpty(ring: *MirrorRing) void {
        const zero_if_empty = @as(usize, @intFromBool(ring.tail == ring.head)) -% 1;
        ring.tail &= zero_if_empty;
        ring.head &= zero_if_empty;
    }

    pub fn normalize(ring: *MirrorRing) void {
        const l = ring.len();
        ring.tail = ring.index(ring.tail);
        ring.head = ring.tail + l;
    }

    pub const CreateError = error{
        OutOfMemory,
        SystemResources,
        Unsupported,
        Unexpected,
    };

    /// Directly mmap the needed pages (totaling double `capacity`).
    /// Asserts `capacity` is a multiple of the page size.
    pub fn create(capacity: usize) CreateError!MirrorRing {
        // If the std concept of page size is removed, what is relevant to us here is simply
        // the smallest piece of virtual memory that can be individually requested.
        const page_size = std.heap.pageSize();
        if (capacity % page_size != 0) unreachable;
        // Should also already be implied by being a multiple of page size
        if (capacity & (capacity - 1) != 0) unreachable;
        switch (native_os) {
            .linux => {
                const fd = std.posix.memfd_create("ring", 0) catch |err| switch (err) {
                    error.NameTooLong => unreachable,
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ProcessFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.SystemFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.SystemOutdated => return error.Unsupported, // TODO is possible on linux?
                    error.Unexpected => return error.Unexpected,
                };
                defer closeFd(fd);
                trunc: while (true) {
                    switch (system.errno(system.ftruncate(fd, @intCast(capacity)))) {
                        .SUCCESS => break :trunc,
                        .INTR => continue :trunc,
                        .INVAL => |e| return errnoBug(e),
                        .FBIG => |e| return errnoBug(e),
                        .IO => |e| return errnoBug(e), // TODO confirm
                        .BADF => |e| return errnoBug(e),
                        else => |e| return errnoBug(e),
                    }
                }
                const buffer = std.posix.mmap(
                    null,
                    capacity*2,
                    .{},
                    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                    -1,
                    0,
                ) catch |err| switch (err) {
                    error.AccessDenied => unreachable,
                    error.LockedMemoryLimitExceeded => unreachable,
                    error.MappingAlreadyExists => unreachable,
                    error.MemoryMappingNotSupported => return error.Unsupported,
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PermissionDenied => unreachable,
                    error.ProcessFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.SystemFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.Unexpected => return error.Unexpected,
                };
                errdefer std.posix.munmap(buffer);
                if (buffer.len != capacity*2) unreachable;
                const former = std.posix.mmap(
                    buffer.ptr,
                    capacity,
                    .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .SHARED, .FIXED = true },
                    fd,
                    0,
                ) catch |err| switch (err) {
                    error.AccessDenied => unreachable,
                    error.LockedMemoryLimitExceeded => unreachable,
                    error.MappingAlreadyExists => unreachable,
                    error.MemoryMappingNotSupported => return error.Unsupported,
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PermissionDenied => unreachable,
                    error.ProcessFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.SystemFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.Unexpected => return error.Unexpected,
                };
                // mmapping the same fd and offset again
                // has the page table for the latter virtual half
                // address the same logical pages the former is set to.
                const latter = std.posix.mmap(
                    @alignCast(buffer.ptr + capacity),
                    capacity,
                    .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .SHARED, .FIXED = true },
                    fd,
                    0,
                ) catch |err| switch (err) {
                    error.AccessDenied => unreachable,
                    error.LockedMemoryLimitExceeded => unreachable,
                    error.MappingAlreadyExists => unreachable,
                    error.MemoryMappingNotSupported => return error.Unsupported,
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PermissionDenied => unreachable,
                    error.ProcessFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.SystemFdQuotaExceeded => return error.SystemResources, // TODO should this just also be OOM?
                    error.Unexpected => return error.Unexpected,
                };
                if (!std.meta.eql(buffer[0..capacity], former)) unreachable;
                if (!std.meta.eql(buffer[capacity..][0..capacity], latter)) unreachable;
                // TODO assert check that the halves actually mirror
                @memset(buffer[0..capacity], undefined);
                return .{
                    .buffer = buffer.ptr,
                    .capacity = capacity,
                    .head = 0,
                    .tail = 0,
                };
            },
            else => |os| @compileError("unimplemented for target " ++ @tagName(os)),
        }
    }

    pub fn destroy(ring: *MirrorRing) void {
        ring.free();
        ring.* = undefined;
    }

    pub fn free(ring: MirrorRing) void {
        std.posix.munmap(ring.buffer[0..ring.capacity*2]);
    }
};

pub const cmsg = struct {
    pub const hdr = extern struct {
        // See `std.c.MuslOnlyPadding`
        pad0: MuslOnlyPadding(.big) = 0,
        len: @FieldType(system.cmsghdr, "len"),
        // See `std.c.MuslOnlyPadding`
        pad1: MuslOnlyPadding(.little) = 0,
        level: Level,
        @"type": Type,

        comptime {
            if (@sizeOf(hdr) != @sizeOf(system.cmsghdr)) unreachable;
            if (@sizeOf(i32) != @sizeOf(c_int)) unreachable;
            if (@alignOf(i32) != @alignOf(c_int)) unreachable;
        }

        pub const Level = enum(i32) {
            socket = system.SOL.SOCKET,
            // TODO the other possible fields
            _,
        };

        pub const Type = packed union(i32) {
            socket: Socket,

            pub const Socket = enum(i32) {
                rights = system.SCM.RIGHTS,
                credentials = system.SCM.CREDENTIALS,
                security = system.SCM.SECURITY,
                // TODO others
            };
        };

        pub fn matchesFlags(h: cmsg.hdr, flags: Flags) bool {
            const level_int: i32 = @intFromEnum(@as(Level, flags));
            const type_int: i32 = switch (flags) { inline else => |t| @intFromEnum(t) };
            return @as(i32, @intFromEnum(h.level)) == level_int and
                @as(i32, @bitCast(h.@"type")) == type_int;
        }

        pub const Flags = union(Level) {
            socket: Type.Socket,
        };

        /// Asserts that `h.len` is at least the aligned `hdr` size,
        /// which correctly built `CMSG`s should always be.
        pub fn data(chdr: *hdr) []u8 {
            const s = alignment.forward(@sizeOf(cmsg.hdr));
            return (@as([*]u8, @ptrCast(chdr)) + s)[0..(@as(usize, chdr.len) - s)];
        }

        pub const data_offset: usize = alignment.forward(@sizeOf(hdr));
    };

    pub inline fn firsthdr(mhdr: *system.msghdr) ?*cmsg.hdr {
        return if (mhdr.controllen < @sizeOf(cmsg.hdr)) null else @ptrCast(mhdr.control);
    }

    pub inline fn nexthdr(mhdr: *system.msghdr, chdr: *cmsg.hdr) ?*cmsg.hdr {
        if (@as(usize, @intFromPtr(chdr)) < @as(usize, @intFromPtr(mhdr.control.?))) unreachable;
        const next: usize = @as(usize, @intFromPtr(chdr)) + alignment.forward(chdr.len);
        const end: usize = @as(usize, mhdr.control.?) + mhdr.controllen;
        return if (next + @sizeOf(cmsg.hdr) <= end) @ptrFromInt(next) else null;
    }

    pub const alignment: std.mem.Alignment = .of( switch (native_os) {
        .linux => usize,
        else => @compileError("unimplemented CMSG platform"),
    } );
    pub const algn: u29 = @intCast(alignment.toByteUnits());

    /// Return the total bytes to allocate
    /// for one `CMSG` with `l` bytes of data.
    pub inline fn space(l: usize) usize {
        return hdr.data_offset + alignment.forward(l);
    }

    /// Return the correct value of the `.len` field
    /// for a `cmsg.hdr` with `l` bytes of data.
    pub inline fn len(l: usize) usize {
        return hdr.data_offset + l;
    }

    pub const Iterator = struct {
        /// Remaining control buffer.
        control: []u8,

        /// Get the next set of control data matching `flags`,
        /// skipping non-matching control messages.
        pub fn nextMatching(iter: *Iterator, flags: hdr.Flags) ?[]u8 {
            while (iter.control.len >= @sizeOf(cmsg.hdr)) {
                const h: *const cmsg.hdr = @alignCast(@ptrCast(iter.control.ptr));
                defer iter.control = iter.control[@min(alignment.forward(h.len), iter.control.len)..];
                if (h.matchesFlags(flags)) {
                    return iter.control[0..h.len][hdr.data_offset..];
                }
            }
            return null;
        }
    };
};

pub fn closeFd(fd: system.fd_t) void {
    switch (system.errno(system.close(fd))) {
        .SUCCESS, .INTR => {},
        .BADF => unreachable,
        else => unreachable,
    }
}

fn errnoBug(err: system.E) error{Unexpected} {
    // TODO not correct way to check for debug mode?
    if (comptime @import("builtin").mode == .Debug) {
        std.debug.panic("programmer bug caused syscall error: E{t}", .{err});
    }
    return error.Unexpected;
}

// TODO use std.c when 0.16
fn MuslOnlyPadding(endian: std.builtin.Endian) type {
    return if (@import("builtin").abi.isMusl() and @sizeOf(usize) == 8 and native_endian == endian) u32 else u0;
}

inline fn ceilingMultiple(x: anytype, n: @TypeOf(x)) @TypeOf(x) {
    if (x < 0) comptime unreachable;
    if (n < 0) comptime unreachable;
    return @divFloor(x+n-1, n) * n;
}

const system = posix.system;
const native_os = builtin.os.tag;
const native_endian = builtin.target.cpu.arch.endian();

const Io = std.Io;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const root = @import("root.zig");
const std = @import("std");
const builtin = @import("builtin");
