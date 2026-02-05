// TODO 0.16 IO

pub fn openLocalSocket(absolute_path: []const u8) !posix.socket_t {
    const path_max_len = @typeInfo(@FieldType(posix.system.sockaddr.un, "path")).array.len - 1;
    if (absolute_path.len > path_max_len) return error.PathTooLong;

    const s = socket(
        posix.system.AF.UNIX,
        posix.system.SOCK.STREAM | posix.system.SOCK.CLOEXEC,
        0,
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SystemResources,
        error.Unexpected => |e| return e,
        error.AddressFamilyNotSupported => unreachable,
        error.ProtocolFamilyNotAvailable => unreachable,
        error.ProtocolNotSupported => unreachable,
        error.SocketTypeNotSupported => unreachable,
    };
    errdefer close(s);

    var addr = mem.zeroInit(posix.system.sockaddr.un, .{
        .family = posix.system.AF.UNIX,
    });
    assert(absolute_path.len < addr.path.len);
    @memcpy(addr.path[0..absolute_path.len], absolute_path);
    assert(addr.path[absolute_path.len] == 0);

    connect(
        s,
        @ptrCast(&addr),
        @sizeOf(@TypeOf(addr)),
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.AddressInUse,
        error.AddressNotAvailable,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.FileNotFound,
        //error.NotDir,
        error.PermissionDenied,
        //error.ProcessFdQuotaExceeded,
        //error.SystemFdQuotaExceeded,
        error.SystemResources,
        error.Unexpected => |e| return e,
        //error.Canceled,
        //error.OptionUnsupported,
        error.ConnectionTimedOut,
        //error.Timeout,
        //error.UnsupportedClock,
        error.WouldBlock => |e| return e,
        error.AddressFamilyNotSupported => unreachable,
        //error.ProtocolUnsupportedByAddressFamily => unreachable,
        //error.ProtocolUnsupportedBySystem => unreachable,
        //error.SocketModeUnsupported => unreachable,
        // Impossible for UNIX domain socket paths
        //error.SymLinkLoop => unreachable,
        // Asserts we are connecting to a UNIX socket created
        // by the host, not us the client
        //error.ReadOnlyFileSystem => unreachable,
        // Network only
        //error.HostUnreachable => unreachable,
        //error.NetworkDown => unreachable,
        error.NetworkUnreachable => unreachable,
    };

    return s;
}

// Posix socket(), connect(), close() are removed from std 0.15->0.16
// TODO replace with new IO

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    comptime assert(builtin.target.os.tag != .windows);
    comptime assert(!builtin.target.os.tag.isDarwin());
    comptime assert(builtin.target.os.tag != .haiku);
    const rc = posix.system.socket(domain, socket_type, protocol);
    return switch (posix.system.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .INVAL => error.ProtocolFamilyNotAvailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .PROTOTYPE => error.SocketTypeNotSupported,
        else => |err| posix.unexpectedErrno(err),
    };
}

const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProcessFdQuotaExceeded,
    ProtocolFamilyNotAvailable,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub fn connect(
    sock: posix.socket_t,
    sock_addr: *const posix.system.sockaddr,
    len: posix.system.socklen_t,
) ConnectError!void {
    comptime assert(builtin.target.os.tag != .windows);
    while (true) {
        switch (posix.system.errno(posix.system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .INTR => continue,
            .ISCONN => unreachable, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
            .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

const ConnectError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    FileNotFound,
    NetworkUnreachable,
    PermissionDenied,
    SystemResources,
    Unexpected,
    WouldBlock,
};

pub fn close(fd: posix.fd_t) void {
    comptime assert(builtin.target.os.tag != .windows);
    comptime assert(builtin.target.os.tag != .wasi);
    switch (posix.system.errno(posix.system.close(fd))) {
        .BADF => unreachable,
        .INTR => return,
        else => return,
    }
}

const assert = debug.assert;

const posix = std.posix;
const mem = std.mem;
const debug = std.debug;

const std = @import("std");
const builtin = @import("builtin");
