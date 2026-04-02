pub const object_id = struct {
    pub const @"null": u32 = 0;
    /// The implicit ID of `wl_display`
    pub const display: u32 = 1;
    /// The client allocates object IDs within this range (start- and end-inclusive)
    pub const client_range: [2]u32 = .{ 2, 0xfeffffff };
    /// The server allocates object IDs within this range (start- and end-inclusive)
    pub const server_range: [2]u32 = .{ 0xff000000, 0xffffffff };
};

pub const Header = extern struct {
    /// The sender's object ID
    object: u32,
    info: packed struct(u32) {
        /// The request/event opcode
        operation: u16,
        /// The message size in bytes, including this header (i.e. always >=8)
        size: u16,
    },
};
comptime { assert(@sizeOf(Header) == 8); }

// TODO test of all message structs that written bytes == payloadSize

/// For an object which is a child of a protocol in `protocols`,
/// write a request message to `writer`.
///
/// This function ignores file descriptor arguments of the message.
/// The caller is responsible for transferring these.
pub fn writeMessage(
    writer: *Io.Writer,
    object: anytype,
    message: @TypeOf(object).Request.Message,
) Io.Writer.Error!void {
    switch (message) {
        inline else => |request, request_tag| {
            try writer.writeStruct(Header{
                .object = object.id,
                .info = .{
                    .operation = @intFromEnum(request_tag),
                    .size = @sizeOf(Header) + payloadSize(request),
                },
            }, endian);
            try writeArgsAll(writer, request);
        }
    }
}

/// For a struct `args` whose fields are all arg types found in `protocol`,
/// write the message payload bytes as they should appear
/// immediately following the header.
///
/// The caller is responsible for transferring file descriptor args
/// with `SCM_RIGHTS` ancillary to these bytes (in no particular order).
pub fn writeArgsAll(writer: *Io.Writer, args: anytype) Io.Writer.Error!void {
    const native_endian = @import("builtin").target.cpu.arch.endian(); // TODO is Endian decl in 0.16
    const Args = @TypeOf(args);
    inline for (@typeInfo(Args).@"struct".fields) |field| {
        const arg = @field(args, field.name);
        switch (field.@"type") {
            inline i32, u32 => |T| try writer.writeInt(T, arg, native_endian),
            Fixed => try writer.writeInt(
                @typeInfo(Fixed).@"struct".backing_integer.?,
                @bitCast(arg),
                native_endian,
            ),
            String => try writeStringArg(writer, arg),
            ?String => {
                if (arg) |string| {
                    try writeStringArg(writer, string);
                } else {
                    try writer.writeInt(u32, 0, native_endian);
                }
            },
            protocol.Interface => @compileError("TODO"),
            protocol.Interface.New => {
                comptime {
                    const info = @typeInfo(protocol.Interface.New).@"struct";
                    debug.assert(info.fields.len == 3);
                    debug.assert(std.mem.eql(u8, "name", info.fields[0].name));
                    debug.assert(std.mem.eql(u8, "version", info.fields[1].name));
                    debug.assert(std.mem.eql(u8, "id", info.fields[2].name));
                }
                try writeStringArg(writer, arg.name);
                try writer.writeInt(u32, arg.version, native_endian);
                try writer.writeInt(u32, arg.id, native_endian);
            },
            else => {
                const Object = @TypeOf(arg);
                const info = @typeInfo(Object);
                if ( comptime
                    ( (info == .@"struct" and info.@"struct".layout == .@"packed") or info == .@"enum" )
                    and @bitSizeOf(Object) == 32
                ) {
                    try writer.writeInt(u32, @bitCast(arg), native_endian);
                } else {
                    const is_optional = info == .optional;
                    const ObjectNoOptional = if (is_optional) info.optional.child else Object;
                    if (comptime isProtocolInterface(ObjectNoOptional)) {
                        if (is_optional) {
                            if (arg) |object| {
                                assert(object.id != 0);
                                try writer.writeInt(u32, object.id, native_endian);
                            } else {
                                try writer.writeInt(u32, 0, native_endian);
                            }
                        } else {
                            assert(arg.id != 0);
                            try writer.writeInt(u32, arg.id, native_endian);
                        }
                    } else {
                        @compileError(comptimePrint(
                            "expected a {s} interface container, found {s}",
                            .{ @typeName(protocol), @typeName(Object) },
                        ));
                    }
                }
            },
            Array => try writeArrayArg(writer, arg),
            File => @panic("TODO"),
        }
    }
}

pub fn writeStringArg(writer: *Io.Writer, string: String) Io.Writer.Error!void {
    const native_endian = @import("builtin").target.cpu.arch.endian(); // TODO is Endian decl in 0.16
    const string_with_terminator: []const u8 = string.ptr[0..string.len];
    assert(string_with_terminator[string_with_terminator.len-1] == 0);
    try writer.writeInt(u32, string.len, native_endian);
    try writer.writeAll(string_with_terminator);
    try writer.splatByteAll(undefined, diffToMultiple(string.len, 4));
}

pub fn writeArrayArg(writer: *Io.Writer, array: Array) Io.Writer.Error!void {
    const native_endian = @import("builtin").target.cpu.arch.endian(); // TODO is Endian decl in 0.16
    try writer.writeInt(u32, array.size, native_endian);
    try writer.writeAll(array.ptr[0..array.size]);
    try writer.splatByteAll(undefined, diffToMultiple(array.size, 4));
}

/// `Message` is a Request or Event `.Message` tagged union from `protocol`.
/// Asserts `ancillary` is the expected number of file descriptors from protocol.
/// Returns error if payload is not the expected number of bytes.
/// Strings and arrays are valid only for the lifetime of `payload`.
pub fn messageFromPayload(
    comptime Message: type,
    op: u16,
    //op: @typeInfo(Message).@"union".tag_type.?,
    payload: []const u8,
    ancillary: []const FD,
) MessageMalformation!Message {
    const Op = @typeInfo(Message).@"union".tag_type.?;
    if (@typeInfo(Op).@"enum".is_exhaustive) {
        const operation: Op = enums.fromInt(Op, op)
            orelse return error.UnsupportedOperation;
        switch (operation) {
            inline else => |tag| {
                const args = try argsFromPayload(
                    @FieldType(Message, @tagName(tag)),
                    payload,
                    ancillary,
                );
                return @unionInit(Message, @tagName(tag), args);
            },
        }
    } else {
        const operation: Op = @enumFromInt(op);
        switch (operation) {
            _ => return error.UnsupportedOperation,
            inline else => |tag| {
                const args = try argsFromPayload(
                    @FieldType(Message, @tagName(tag)),
                    payload,
                    ancillary,
                );
                return @unionInit(Message, @tagName(tag), args);
            },
        }
    }
}

// TODO test this impl vs scanning through for arg positions first
// and returning directly with .{} syntax
/// For a struct `Args` from `protocol`,
/// whose fields are all valid types found in `protocol`,
/// parse the `payload` bytes into the `Args` view.
/// Errors if `payload` is not the correct number of bytes.
/// Strings and arrays are valid only for the lifetime of `payload`.
pub fn argsFromPayload(
    comptime Args: type,
    payload: []const u8,
    ancillary: []const FD,
) PayloadMalformation!Args {
    assert(ancillary.len == comptime expectedAncillaryCount(Args));
    var remaining: []const u8 = payload;
    var remaining_fds: []const FD = ancillary;
    var args: Args = undefined;
    inline for (@typeInfo(Args).@"struct".fields) |field| {
        switch (field.@"type") {
            i32, u32, Fixed => |T| {
                @field(args, field.name) = mem.bytesToValue(T, remaining[0..@sizeOf(T)]);
                remaining = try payloadNext(remaining, @sizeOf(T));
            },

            String, ?String => |T| {
                const len: u32 = mem.bytesToValue(u32, remaining[0..@sizeOf(u32)]);
                remaining = try payloadNext(remaining, @sizeOf(u32));
                if (len != 0) {
                    @field(args, field.name) = String{
                        .len = len,
                        .ptr = @as([*:0]const u8, @ptrCast(remaining.ptr)),
                    };
                    remaining = try payloadNext(remaining, ceilingMultiple(len, 4));
                } else {
                    if (T == ?String) {
                        @field(args, field.name) = null;
                    } else {
                        return error.InvalidOptional;
                    }
                }
            },

            Array => {
                const size: u32 = mem.bytesToValue(u32, remaining[0..@sizeOf(u32)]);
                remaining = try payloadNext(remaining, @sizeOf(u32));
                @field(args, field.name) = Array{ .size = size, .ptr = remaining.ptr };
                remaining = try payloadNext(remaining, ceilingMultiple(size, 4));
            },

            protocol.Interface.New => @compileError(@typeName(Args) ++ ": TODO"),

            else => |Object| {
                const info = @typeInfo(Object);
                if ( comptime
                    ( (info == .@"struct" and info.@"struct".layout == .@"packed") or info == .@"enum" )
                    and @bitSizeOf(Object) == 32
                ) {
                    comptime { if (info == .@"enum") debug.assert(!info.@"enum".is_exhaustive); }
                    @field(args, field.name) = mem.bytesToValue(Object, remaining[0..@sizeOf(Object)]);
                    remaining = try payloadNext(remaining, @sizeOf(Object));
                } else {
                    const is_optional = info == .optional;
                    const ObjectNoOptional = if (is_optional) info.optional.child else Object;
                    if (comptime isProtocolInterface(ObjectNoOptional)) {
                        const id = mem.bytesToValue(u32, remaining[0..@sizeOf(u32)]);
                        if (id != 0) {
                            @field(args, field.name) = .{ .id = id };
                        } else {
                            if (is_optional) {
                                @field(args, field.name) = null;
                            } else {
                                return error.InvalidOptional;
                            }
                        }
                        remaining = try payloadNext(remaining, @sizeOf(u32));
                    } else {
                        @compileError(comptimePrint(
                            "expected a {s} interface container, found {s}",
                            .{ @typeName(protocol), @typeName(Object) },
                        ));
                    }
                }
            },

            File => {
                @field(args, field.name) = File{ .descriptor = remaining_fds[0] };
                remaining_fds = remaining_fds[1..];
            },
        }
    }
    if (remaining.len != 0) return error.PayloadUnderflow;
    assert(remaining_fds.len == 0);

    return args;
}

pub const MessageMalformation = error{
    /// Unrecognized opcode for the target interface.
    /// The message may be invalidly formatted
    /// or the client may have been built with an outdated protocol.
    UnsupportedOperation,
} || PayloadMalformation;

pub const PayloadMalformation = error{
    /// Reached the end of the payload buffer expecting more args
    PayloadOverflow,
    /// Parsed all args before reaching the end of the payload buffer
    PayloadUnderflow,
    /// A string or object not typed as optional was passed as NULL
    InvalidOptional,
};

pub fn mapInterfaceName(name: []const u8) ?protocol.AnyObject {
    const map: std.StaticStringMap(protocol.AnyObject) = comptime .initComptime(&kvs: {
        const count = count: {
            var c: usize = 0;
            for (@typeInfo(protocol.AnyObject).@"union".fields) |field| {
                const Object = field.type;
                c += @typeInfo(Object).@"enum".fields.len;
            }
            break :count c;
        };
        var kvs: [count]struct { []const u8, protocol.AnyObject } = undefined;
        var i: usize = 0;
        for (@typeInfo(protocol.AnyObject).@"union".fields) |field| {
            const Object = field.type;
            for (@typeInfo(Object).@"enum".fields) |field_inner| {
                kvs[i] = .{
                    ( if (Object.prefix) |prefix| prefix else "" ) ++ field_inner.name,
                    @unionInit(protocol.AnyObject, field.name, @enumFromInt(field_inner.value)),
                };
                i += 1;
            }
        }
        debug.assert(i == kvs.len);
        break :kvs kvs;
    });
    return map.get(name);
}

pub fn printArgs(writer: *std.Io.Writer, args: anytype) std.Io.Writer.Error!void {
    const Args = @TypeOf(args);
    try writer.writeAll("{ ");
    const fields = @typeInfo(Args).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const Arg = @FieldType(Args, field.name);
        const arg = @field(args, field.name);
        try writer.writeAll(field.name);
        try writer.writeAll(": ");
        switch (Arg) {
            i32, u32 => try writer.printInt(arg, 10, .lower, .{}),
            Fixed, String, Array => try arg.format(writer),
            File => try writer.print("fd{{ {d} }}", .{arg.descriptor}),
            ?String => {
                if (arg) |a| {
                    try a.format(writer);
                } else {
                    try writer.writeAll("null");
                }
            },
            protocol.Interface.New => {
                comptime {
                    const info = @typeInfo(protocol.Interface.New).@"struct";
                    debug.assert(info.fields.len == 3);
                    debug.assert(std.mem.eql(u8, "name", info.fields[0].name));
                    debug.assert(std.mem.eql(u8, "version", info.fields[1].name));
                    debug.assert(std.mem.eql(u8, "id", info.fields[2].name));
                }
                try writer.writeAll("{ name: \"");
                try arg.name.format(writer);
                try writer.writeAll("\", version: ");
                try writer.writeInt(arg.version);
                try writer.writeAll(", id: ");
                try writer.writeInt(arg.id);
                try writer.writeAll(" }");
            },
            else => |A| {
                const info = @typeInfo(A);
                if (info == .@"struct"
                        and info.@"struct".fields.len == 1
                        and comptime std.mem.eql(u8, "id", info.@"struct".fields[0].name)) {
                    try writer.print("id{{ {d} }}", .{arg.id});
                } else if (info == .optional) {
                    const info_inner = @typeInfo(info.optional.child);
                    if (info_inner == .@"struct"
                            and info_inner.@"struct".fields.len == 1
                            and comptime std.mem.eql(u8, "id", info_inner.@"struct".fields[0].name)) {
                        if (arg) |a| {
                            try writer.print("id{{ {d} }}", .{a.id});
                        } else {
                            try writer.writeAll("id{{ null }}");
                        }
                    } else {
                        @compileError(@typeName(A) ++ " is not a valid message arg");
                    }
                } else if (@bitSizeOf(A) == 32) {
                    switch (info) {
                        .@"enum" => |@"enum"| {
                            if (@"enum".is_exhaustive) {
                                try writer.writeAll(@tagName(arg));
                            } else {
                                if (enums.tagName(Arg, arg)) |tag| {
                                    try writer.writeAll(tag);
                                } else {
                                    try writer.print("(unknown: {d})", .{ @intFromEnum(arg) });
                                }
                            }
                        },
                        .@"struct" => |struct_info| {
                            try writer.writeAll("{ ");
                            inline for (struct_info.fields) |field_inner| {
                                if (field_inner.name[0] != '_' and @field(arg, field_inner.name)) {
                                    try writer.writeByte('.');
                                    try writer.writeAll(field_inner.name);
                                    try writer.writeByte(' ');
                                }
                            }
                            try writer.writeByte('}');
                        },
                        else => comptime unreachable,
                    }
                } else {
                    @compileError(@typeName(A) ++ " is not a valid message arg");
                }
            },
        }
        if (i != fields.len - 1) try writer.writeByte(',');
        try writer.writeByte(' ');
    }
    try writer.writeByte('}');
}

/// Creates a wrapper suitable for passing to a "{f}" placeholder.
pub fn formatAlt(args: anytype) FormatAlt(@TypeOf(args)) {
    return .{ .data = args };
}

/// Creates a wrapper type suitable for passing to a "{f}" placeholder.
pub fn FormatAlt(comptime Args: type) type {
    return struct {
        data: Args,
        pub inline fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
            try printArgs(writer, self.data);
        }
    };
}

/// For a struct `args` whose fields are all valid types found in `protocol`,
/// find their total size over the wire in bytes.
pub inline fn payloadSize(args: anytype) u16 {
    const Args = @TypeOf(args);
    var size: u16 = 0;
    inline for (@typeInfo(Args).@"struct".fields) |field| {
        const arg = @field(args, field.name);
        switch (field.@"type") {
            i32, u32, Fixed => |T| size += @sizeOf(T),
            String => size += 4 + ceilingMultiple(arg.len, 4),
            ?String => size += 4 + ( if (arg) |string| ceilingMultiple(string.len, 4) else 0 ),
            Array => size += 4 + ceilingMultiple(arg.len, 4),
            protocol.Interface.New => {
                comptime {
                    const info = @typeInfo(protocol.Interface.New).@"struct";
                    debug.assert(info.fields.len == 3);
                    debug.assert(std.mem.eql(u8, "name", info.fields[0].name));
                    debug.assert(std.mem.eql(u8, "version", info.fields[1].name));
                    debug.assert(std.mem.eql(u8, "id", info.fields[2].name));
                }
                size += 12 + @as(@TypeOf(size), @intCast(ceilingMultiple(arg.name.len, 4)));
            },
            else => {
                const object = arg;
                const Object = @TypeOf(object);
                const info = @typeInfo(Object);
                const is_optional = info == .optional;
                const ObjectNoOptional = if (is_optional) info.optional.child else Object;
                if (comptime isProtocolInterface(ObjectNoOptional)) {
                    size += 4;
                } else {
                    @compileError(comptimePrint(
                        "expected a {s} interface container, found {s}",
                        .{ @typeName(protocol), @typeName(Object) },
                    ));
                }
            },
            File => @panic("TODO"),
        }
    }
    assert(size % 4 == 0);
    return size;
}

pub fn expectedAncillaryCount(comptime Args: type) usize {
    var count: usize = 0;
    for (@typeInfo(Args).@"struct".fields) |field| {
        if (field.@"type" == File) count += 1;
    }
    return count;
}

pub fn isProtocolInterface(comptime Object: type) bool {
    if (Object == protocol.Interface or Object == protocol.Interface.New)
        return true;
    return forall: for (@typeInfo(protocol).@"struct".decls) |decl_outer| {
        const container = @field(protocol, decl_outer.name);
        switch (@typeInfo(container)) {
            .@"struct" => |protocol_info| {
                for (protocol_info.decls) |decl_inner| {
                    const Interface = @field(container, decl_inner.name);
                    if (@TypeOf(Interface) != type) continue;
                    switch (@typeInfo(Interface)) {
                        .@"struct" => |interface_info| {
                            if (
                                interface_info.fields.len == 1 and
                                mem.eql(u8, "id", interface_info.fields[0].name) and
                                interface_info.fields[0].@"type" == u32 and
                                @hasDecl(Interface, "New") and
                                @hasField(Interface.New, "id") and
                                @FieldType(Interface.New, "id") == u32
                            ) {
                                if (Object == Interface or Object == Interface.New) {
                                    break :forall true;
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    } else false;
}

fn payloadNext(buffer: []const u8, forward: usize) error{PayloadOverflow}![]const u8 {
    assert(forward % 4 == 0);
    if (buffer.len >= forward) {
        return buffer[forward..];
    } else {
        return error.PayloadOverflow;
    }
}

inline fn ceilingMultiple(x: anytype, n: @TypeOf(x)) @TypeOf(x) {
    assert(x >= 0);
    assert(n >= 0);
    return @divFloor(x+n-1, n) * n;
}

/// Returns the difference of `x`
/// to the least multiple of `n` greater than or equal to `x`.
inline fn diffToMultiple(x: anytype, n: @TypeOf(x)) @TypeOf(x) {
    assert(x >= 0);
    assert(n >= 0);
    if (@TypeOf(x) == comptime_int) return @mod(-x, n);
    const info = @typeInfo(@TypeOf(x)).int;
    switch (info.signedness) {
        .unsigned => {
            const signed_x: @Int(.signed, info.bits) = @intCast(x);
            const signed_n: @Int(.signed, info.bits) = @intCast(n);
            return @intCast(@mod(-signed_x, signed_n));
        },
        .signed => return @mod(-x, n),
    }
}

test diffToMultiple {
    try testing.expectEqual(0, diffToMultiple(0, 4));
    try testing.expectEqual(3, diffToMultiple(1, 4));
    try testing.expectEqual(2, diffToMultiple(2, 4));
    try testing.expectEqual(1, diffToMultiple(3, 4));
    try testing.expectEqual(0, diffToMultiple(4, 4));
    try testing.expectEqual(3, diffToMultiple(5, 4));
    try testing.expectEqual(2, diffToMultiple(6, 4));
    try testing.expectEqual(1, diffToMultiple(7, 4));
    try testing.expectEqual(0, diffToMultiple(8, 4));
    try testing.expectEqual(3, diffToMultiple(9, 4));
}

pub const protocol = @import("wayland_protocol");
pub const Fixed = protocol.Fixed;
pub const String = protocol.String;
pub const Array = protocol.Array;
pub const File = protocol.File;

pub const FD = @import("std").posix.fd_t;

/// Wayland wire protocol follows the host system endianness
/// TODO is std.builtin.Endian.native in 0.16
pub const endian = @import("builtin").target.cpu.arch.endian();

const assert = debug.assert;
const comptimePrint = std.fmt.comptimePrint;

const Io = std.Io;
const mem = std.mem;
const enums = std.enums;
const debug = std.debug;
const testing = std.testing;

const std = @import("std");
