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

    pub fn open(path: []const u8, options: ConnectOptions) !DomainStream {
        // TODO how do i know whether the system wants sockaddr or sockaddr_un?
        const Address = system.sockaddr.un;
        // `-1` to always leave a sentinel TODO is that necessary?
        const max_path_len = @typeInfo(@FieldType(Address, "path")).array.len - 1;
        if (path.len > max_path_len) return error.NameTooLong;
        if (path.len == 0) return error.PathEmpty;

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

        const address = addr: {
            var addr: Address = .{
                .family = posix.AF.UNIX,
                .path = @splat(0),
            };
            @memcpy(addr.path[0..path.len], path);
            break :addr addr;
        };
        const address_len: system.socklen_t = @intCast(@offsetOf(Address, "path") + path.len + 1);

        while (true) {
            // TODO remove ptrcast in 0.16 where the address is anyopaque
            switch (system.errno(system.connect(socket_fd, @ptrCast(&address), address_len))) {
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
        debug.assert(data.len > 0);
        for (data) |buf| debug.assert(buf.len > 0);
        if (control) |buffer| debug.assert(cmsg.alignment.check(buffer.len));

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
        debug.assert(data.len > 0);
        for (data) |buf| debug.assert(buf.len > 0);
        debug.assert(cmsg.alignment.check(control_buffer.len));

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
            debug.assert(std.math.isPowerOfTwo(fd_buffer.len));
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
            debug.assert(dest[0].len > 0);
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
            debug.assert(r.fd_end <= r.fd_cap);
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
            debug.assert(r.fd_end <= r.fd_cap);
            return r.fd_buf[r.fd_seek..r.fd_end];
        }

        /// Release the first `n` FDs that have been received.
        pub fn tossFds(r: *Reader, n: FdIndex) void {
            const len = r.fd_end - r.fd_seek;
            debug.assert(n < len);
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
                                debug.assert(buf.len == splat_buffer.len);
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
            debug.assert(iovecs_count > 0);
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
            debug.assert(hdr.pad0 == 0);
            debug.assert(hdr.pad1 == 0);
            debug.assert(hdr.len >= cmsg.hdr.data_offset);
            debug.assert(hdr.level == .socket);
            debug.assert(hdr.@"type".socket == .rights);
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
            if (dest.len <= data.len) {
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
            debug.assert(hdr.pad0 == 0);
            debug.assert(hdr.pad1 == 0);
            debug.assert(hdr.len >= cmsg.hdr.data_offset);
            debug.assert(hdr.level == .socket);
            debug.assert(hdr.@"type".socket == .rights);
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

        comptime { debug.assert(@sizeOf(hdr) == @sizeOf(system.cmsghdr)); }
        comptime { debug.assert(@sizeOf(i32) == @sizeOf(c_int)
                            and @alignOf(i32) == @alignOf(c_int)); }

        pub const Level = enum(i32) {
            socket = system.SOL.SOCKET,
            // TODO the other possible fields
            _,
        };

        pub const Type = packed union {
            socket: Socket,

            pub const Socket = enum(i32) {
                rights = system.SCM.RIGHTS,
                credentials = system.SCM.CREDENTIALS,
                security = system.SCM.SECURITY,
                // TODO others
            };
        };
        comptime { debug.assert(@sizeOf(Type) == @sizeOf(i32)
                            and @alignOf(Type) == @alignOf(i32)); }

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
        debug.assert(@as(usize, @intFromPtr(chdr)) >= @as(usize, @intFromPtr(mhdr.control.?)));
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

const system = posix.system;
const native_os = builtin.os.tag;
const native_endian = builtin.target.cpu.arch.endian();
pub const closeFd = root.closeFd;

const Io = std.Io;
const posix = std.posix;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const root = @import("root.zig");
const std = @import("std");
const builtin = @import("builtin");
