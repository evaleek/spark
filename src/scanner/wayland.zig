// Wayland scanner

pub const source_format: SourceFormat = .{
    .indent = "    ",
};

var buffer: [0x1000]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const arena: Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 1) {
        log.err("invalid arguments", .{});
        log.info("usage: {s} input_0.xml input_1.xml ... output.zig", .{ args[0] });
        return error.InvalidArguments;
    }
    var protocol_list: ArrayList(ProtocolParse) = try .initCapacity(arena, args.len-1);
    for (args[1..args.len-1]) |arg| {
        const file = Io.Dir.cwd().openFile(init.io, arg, .{
            .mode = .read_only,
            .allow_directory = false,
            .lock = .shared,
        }) catch |err| {
            log.err("could not open file at {s}: {t}", .{ arg, err });
            return err;
        };
        defer file.close(init.io);
        var file_reader = file.reader(init.io, &buffer);
        errdefer |err| {
            if (err == error.ReadFailed) {
                if (file_reader.err) |e| log.err("{t} while reading file at {s}", .{ e, arg });
            }
        }
        try xml.tryPeekBom(&file_reader.interface);
        try takeAppendProtocolXml(arena, &file_reader.interface, &protocol_list);
    }

    const protocols: WaylandProtocols = try .fromParsed(arena, protocol_list.items);

    const out_file_arg = args[args.len-1];
    const out_file_stdout = mem.eql(u8, "-", out_file_arg);
    const out_file: Io.File =
        if (out_file_stdout)
            Io.File.stdout()
        else
            Io.Dir.cwd().createFile(init.io, out_file_arg, .{
                .lock = .exclusive,
            }) catch |err| {
                log.err("{t} failure opening {s}", .{ err, out_file_arg });
                return err;
            };
    defer {
        if (!out_file_stdout) out_file.close(init.io);
    }
    var out_writer = out_file.writerStreaming(init.io, &buffer);
    errdefer |err| {
        if (err == error.WriteFailed) {
            if (out_writer.err) |e| log.err("WriteFailed: {t}", .{ e });
        }
    }

    try protocols.writeSource(arena, &out_writer.interface, source_format, 0);
    try out_writer.interface.flush();
}

pub const SourceFormat = struct {
    indent: []const u8,
};

pub fn takeAppendProtocolXml(
    gpa: Allocator,
    reader: *Io.Reader,
    list: *ArrayList(ProtocolParse),
) (xml.ParseError || Allocator.Error)!void {
    while (cont: {
        xml.discardPlaintext(reader) catch |err| switch (err) {
            error.EndOfStream => break :cont false,
            error.ReadFailed => |e| return e,
        };
        @setEvalBranchQuota(6000);
        const protocol = (try xml.takeNode(gpa, reader, &.{ protocol_schema })).protocol;
        try list.append(gpa, protocol);
        break :cont true;
    }) {}
}

pub const ParseInvalid = error{
    EmptyValue,
    /// While parsing an attribute that has an expected integer type
    InvalidCharacter,
    /// While parsing an attribute that has an expected integer type
    Overflow,
    InvalidVersionNumber,
    ArgInterfaceNameInvalid,
    ArgEnumNameInvalid,
    ArgEnumAttributeBackingMismatch,
    EnumArgMissingEnum,
    EnumValuesInvalid,
    MultilineSummary,
    /// More than one description tag under a parent
    DescriptionCollision,
};
pub const ReparseError = ParseInvalid || Allocator.Error;

pub const WriteSourceError = Io.Writer.Error || Allocator.Error;

/// Intermediate layout that has validated the initial parse tree
/// and is simpler to write in one pass.
pub const WaylandProtocols = struct {
    protocol_names: []const []const u8,
    interfaces: []const Interface,

    pub fn writeSource(
        protocols: WaylandProtocols,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        try printLine(writer, "pub const Protocol = enum {{", .{}, format, indent_level);
        {
            for (protocols.protocol_names) |protocol_name| {
                const name = try xml.decollideIdentifierNonempty(arena, protocol_name);
                try printLine(writer, "{s},", .{ name }, format, indent_level + 1);
            }
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        try writer.writeByte('\n');

        try printLine(writer, "pub const Interface = enum {{", .{}, format, indent_level);
        {
            for (protocols.interfaces) |interface| {
                if (interface.description) |description| {
                    try description.writeSourceShort(writer, format, indent_level + 1);
                }
                const name = try xml.decollideIdentifierNonempty(arena, interface.name);
                try printLine(writer, "{s},", .{ name }, format, indent_level + 1);
            }

            try writer.writeByte('\n');

            try printLine(writer, "pub const Info = struct {{", .{}, format, indent_level + 1);
            try printLine(writer, "version: comptime_int,", .{}, format, indent_level + 2);
            try printLine(writer, "requests: []const MessageInfo,", .{}, format, indent_level + 2);
            try printLine(writer, "events: []const MessageInfo,", .{}, format, indent_level + 2);
            try printLine(writer, "}};", .{}, format, indent_level + 1);

            try writer.writeByte('\n');

            try printLine(writer, "pub fn info(comptime interface: Interface) Info {{", .{}, format, indent_level + 1);
            try printLine(writer, "return interface.Object().info;", .{}, format, indent_level + 2);
            try printLine(writer, "}}", .{}, format, indent_level + 1);

            try writer.writeByte('\n');

            try printLine(writer, "pub fn Object(comptime interface: Interface) type {{", .{}, format, indent_level + 1);
            try printLine(writer, "return switch (interface) {{", .{}, format, indent_level + 2);
            for (protocols.interfaces) |interface| {
                const name = try xml.decollideIdentifierNonempty(arena, interface.name);
                const type_name = try xml.caseSnakeToPascal(arena, interface.name);
                defer arena.free(type_name);
                try printLine(writer, ".{s} => {s},", .{ name, type_name }, format, indent_level + 3);
            }
            try printLine(writer, "}};", .{}, format, indent_level + 2);
            try printLine(writer, "}}", .{}, format, indent_level + 1);
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        try writer.writeByte('\n');

        try printLine(writer, "pub const MessageInfo = struct {{", .{}, format, indent_level);
        {
            try printLine(writer, "name: []const u8,", .{}, format, indent_level + 1);
            try printLine(writer, "since: comptime_int = 1,", .{}, format, indent_level + 1);
            try printLine(writer, "deprecated_since: ?comptime_int = null,", .{}, format, indent_level + 1);
            try printLine(writer, "args: []const ArgInfo", .{}, format, indent_level + 1);
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        try writer.writeByte('\n');

        try printLine(writer, "pub const ArgInfo = struct {{", .{}, format, indent_level);
        {
            try printLine(writer, "name: []const u8,", .{}, format, indent_level + 1);
            try printLine(writer, "optional: bool = false,", .{}, format, indent_level + 1);
            try printLine(writer, "@\"enum\": ?type = null,", .{}, format, indent_level + 1);
            try printLine(writer, "value: Value,", .{}, format, indent_level + 1);

            try writer.writeByte('\n');

            try printLine(writer, "pub const Value = union(enum) {{", .{}, format, indent_level + 1);
            for (std.enums.values(ArgType)) |arg_type| {
                switch (arg_type) {
                    .new_id => {
                        try printLine(writer, "new_id: Interface,", .{}, format, indent_level + 2);
                        try printLine(writer, "/// A special case of `.new_id`.", .{}, format, indent_level + 2);
                        try printLine(writer, "/// Args of this type are marshaled in three components:", .{}, format, indent_level + 2);
                        try printLine(writer, "///", .{}, format, indent_level + 2);
                        try printLine(writer, "/// 1. a `string` arg: the interface name", .{}, format, indent_level + 2);
                        try printLine(writer, "/// 2. a `uint` arg: the interface version", .{}, format, indent_level + 2);
                        try printLine(writer, "/// 3. a `uint` arg: the interface new_id", .{}, format, indent_level + 2);
                        try printLine(writer, "new_id_factory,", .{}, format, indent_level + 2);
                    },
                    else => try printLine(writer, "{t},", .{ arg_type }, format, indent_level + 2),
                }
            }
            try printLine(writer, "}};", .{}, format, indent_level + 1);
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        try writer.writeByte('\n');

        try printLine(writer, "pub const EnumInfo = struct {{", .{}, format, indent_level);
        {
            try printLine(writer, "since: comptime_int = 1,", .{}, format, indent_level + 1);
            try printLine(writer, "deprecated_since: ?comptime_int = null,", .{}, format, indent_level + 1);
            try printLine(writer, "entries: []const EntryInfo = null,", .{}, format, indent_level + 1);
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        try writer.writeByte('\n');
        try printLine(writer, "pub const EntryInfo = struct {{", .{}, format, indent_level);
        {
            try printLine(writer, "since: comptime_int = 1,", .{}, format, indent_level + 1);
            try printLine(writer, "deprecated_since: ?comptime_int = null,", .{}, format, indent_level + 1);
        }
        try printLine(writer, "}};", .{}, format, indent_level);

        for (protocols.interfaces) |interface| {
            try writer.writeByte('\n');
            try interface.writeSource(arena, writer, format, indent_level);
        }
    }

    pub fn fromParsed(arena: Allocator, parsed: []const ProtocolParse) ReparseError!WaylandProtocols {
        const protocol_names = try arena.alloc([]const u8, parsed.len);
        var interfaces_count: usize = 0;
        for (parsed, protocol_names) |protocol_parse, *protocol_name| {
            protocol_name.* = protocol_parse.name;
            for (protocol_parse.content) |protocol_parse_child| {
                switch (protocol_parse_child) {
                    .interface => interfaces_count += 1,
                    .copyright => {},
                }
            }
        }
        var interface_list: ArrayList(Interface) = try .initCapacity(arena, interfaces_count);
        for (parsed, protocol_names) |protocol_parse, protocol_name| {
            for (protocol_parse.content) |protocol_parse_child| {
                switch (protocol_parse_child) {
                    .interface => |interface_parsed| {
                        interface_list.appendAssumeCapacity(try .fromParsedShallow(arena, interface_parsed, protocol_name));
                    },
                    // Discard the copyright notice.
                    // It is still included in this source tree
                    // as long the original protocol XML is vendored.
                    .copyright => {},
                }
            }
        }
        var i: usize = 0;
        for (parsed) |protocol_parse| {
            for (protocol_parse.content) |protocol_parse_child| {
                switch (protocol_parse_child) {
                    .interface => |interface_parsed| {
                        try interface_list.items[i].finishReparseDeep(arena, interface_parsed, interface_list.items);
                        i += 1;
                    },
                    .copyright => {},
                }
            }
        }
        return .{
            .protocol_names = protocol_names,
            .interfaces = interface_list.items,
        };
    }
};

pub const Description = struct {
    short_line: ?[]const u8,
    long_lines: ?[]const []const u8,

    pub fn writeSourceShort(
        description: Description,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) Io.Writer.Error!void {
        if (description.short_line) |line| {
            try printLine(writer, "/// {s}", .{ line }, format, indent_level);
        }
    }

    pub fn writeSource(
        description: Description,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) Io.Writer.Error!void {
        if (description.short_line == null and description.long_lines == null) unreachable;
        if (description.short_line) |short_line| {
            try printLine(writer, "/// {s}", .{ short_line }, format, indent_level);
            if (description.long_lines != null) {
                try printLine(writer, "///", .{}, format, indent_level);
            }
        }
        if (description.long_lines) |long_lines| {
            if (long_lines.len == 0) unreachable;
            for (long_lines) |line| {
                try printLine(writer, "/// {s}", .{ line }, format, indent_level);
            }
        }
    }

    pub fn fromParsed(arena: Allocator, parsed: DescriptionParse) ReparseError!Description {
        if (parsed.summary.len == 0 and parsed.content.len == 0) return error.EmptyValue;
        var desc: Description = .{ .short_line = null, .long_lines = null };
        if (parsed.summary.len != 0) {
            for (parsed.summary) |c| switch (c) {
                '\n', '\r' => return error.MultilineSummary,
                else => {},
            };
            desc.short_line = mem.trim(u8, parsed.summary, &ascii.whitespace);
        }
        if (parsed.content.len != 0) {
            var lines_list: ArrayList([]const u8) = try .initCapacity(arena, 16);
            var lines_iter = xml.splitTextLines(parsed.content);
            while (lines_iter.next()) |line| try lines_list.append(arena, line);
            desc.long_lines = lines_list.items;
        }
        return desc;
    }

    pub fn fromParsedAttrs(
        arena: Allocator,
        parsed: DescriptionParse,
        summary: ?[]const u8,
        description: ?[]const u8,
    ) ReparseError!Description {
        if (summary != null or description != null) return error.DescriptionCollision;
        return .fromParsed(arena, parsed);
    }

    pub fn fromAttrs(
        arena: Allocator,
        summary: ?[]const u8,
        description: ?[]const u8,
    ) ReparseError!Description {
        return .fromParsed(arena, .{
            .summary = summary orelse &.{},
            .content = description orelse &.{},
        });
    }
};

pub const Interface = struct {
    protocol_name: []const u8,
    name: []const u8,
    version: VersionNumber,
    description: ?Description,
    all_members: []const InterfaceMember,
    requests: []const Request,
    events: []const Event,
    enums: []const Enum,

    pub fn writeSource(
        interface: Interface,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        if (interface.description) |description| try description.writeSource(writer, format, indent_level);
        {
            const pascal_name = try xml.caseSnakeToPascal(arena, interface.name);
            defer arena.free(pascal_name);
            try printLine(writer, "pub const {s} = struct {{", .{ pascal_name }, format, indent_level);
        }

        try printLine(writer, "id: u32,", .{}, format, indent_level + 1);

        if (interface.requests.len != 0) {
            try writer.writeByte('\n');

            try printLine(writer, "pub const Request = enum(u16) {{", .{}, format, indent_level + 1);
            for (interface.requests, 0..) |request, index| {
                if (request.description) |description| {
                    try description.writeSourceShort(writer, format, indent_level + 2);
                }
                const name = try xml.decollideIdentifierNonempty(arena, request.name);
                try printLine(writer, "{s} = {d},", .{ name, index }, format, indent_level + 2);
            }
            {
                try writer.writeByte('\n');
                try printLine(writer, "pub fn getInfo(comptime request: Request) MessageInfo {{", .{}, format, indent_level + 2);
                try printLine(writer, "const index = @intFromEnum(request);", .{}, format, indent_level + 3);
                try printLine(writer, "return info.requests[index];", .{}, format, indent_level + 3);
                try printLine(writer, "}}", .{}, format, indent_level + 2);
            }
            try printLine(writer, "}};", .{}, format, indent_level + 1);
        }

        if (interface.events.len != 0) {
            try writer.writeByte('\n');

            try printLine(writer, "pub const Event = enum(u16) {{", .{}, format, indent_level + 1);
            for (interface.events, 0..) |event, index| {
                if (event.description) |description| {
                    try description.writeSourceShort(writer, format, indent_level + 2);
                }
                const name = try xml.decollideIdentifierNonempty(arena, event.name);
                try printLine(writer, "{s} = {d},", .{ name, index }, format, indent_level + 2);
            }
            {
                try writer.writeByte('\n');
                try printLine(writer, "pub fn getInfo(comptime event: Event) MessageInfo {{", .{}, format, indent_level + 2);
                try printLine(writer, "const index = @intFromEnum(event);", .{}, format, indent_level + 3);
                try printLine(writer, "return info.events[index];", .{}, format, indent_level + 3);
                try printLine(writer, "}}", .{}, format, indent_level + 2);
            }
            try printLine(writer, "}};", .{}, format, indent_level + 1);
        }

        try writer.writeByte('\n');

        try printLine(writer, "pub const info: Interface.Info = .{{", .{}, format, indent_level + 1);
        {
            try printLine(writer, ".version = {d},", .{ interface.version }, format, indent_level + 2);
            if (interface.requests.len != 0) {
                try printLine(writer, ".requests = &.{{", .{}, format, indent_level + 2);
                for (interface.requests) |request| {
                    try printLine(writer, ".{{", .{}, format, indent_level + 3);
                    try request.writeInfoSource(arena, writer, format, indent_level + 4);
                    try printLine(writer, "}},", .{}, format, indent_level + 3);
                }
                try printLine(writer, "}},", .{}, format, indent_level + 2);
            }
            if (interface.events.len != 0) {
                try printLine(writer, ".events = &.{{", .{}, format, indent_level + 2);
                for (interface.events) |event| {
                    try printLine(writer, ".{{", .{}, format, indent_level + 3);
                    try event.writeInfoSource(arena, writer, format, indent_level + 4);
                    try printLine(writer, "}},", .{}, format, indent_level + 3);
                }
                try printLine(writer, "}},", .{}, format, indent_level + 2);
            }
        }
        try printLine(writer, "}};", .{}, format, indent_level + 1);

        for (interface.enums) |@"enum"| {
            try writer.writeByte('\n');
            try @"enum".writeTypeSource(arena, writer, format, indent_level + 1);
        }

        try printLine(writer, "}};", .{}, format, indent_level);
    }

    pub fn fromParsedShallow(
        arena: Allocator,
        parsed: InterfaceParse,
        protocol_name: []const u8,
    ) ReparseError!Interface {
        var description: ?Description = null;
        var enum_list: ArrayList(Enum) = try .initCapacity(arena, parsed.content.len);
        for (parsed.content) |interface_child_parsed| switch (interface_child_parsed) {
            .request => {},
            .event => {},
            .@"enum" => |enum_parsed| try enum_list.append(arena, try .fromParsed(arena, enum_parsed, parsed.version)),
            .description => |description_parsed| {
                if (description == null) {
                    description = try .fromParsed(arena, description_parsed);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        return .{
            .protocol_name = protocol_name,
            .name = parsed.name,
            .version = parsed.version,
            .description = description,
            .all_members = undefined,
            .requests = undefined,
            .events = undefined,
            .enums = enum_list.items,
        };
    }

    pub fn finishReparseDeep(
        interface: *Interface,
        arena: Allocator,
        parsed: InterfaceParse,
        all_interfaces: []const Interface,
    ) ReparseError!void {
        if (!mem.eql(u8, parsed.name, interface.name)) unreachable;
        var request_list: ArrayList(Request) = try .initCapacity(arena, parsed.content.len);
        var event_list: ArrayList(Event) = try .initCapacity(arena, parsed.content.len);
        var member_list: ArrayList(InterfaceMember) = try .initCapacity(arena, parsed.content.len);
        for (parsed.content) |interface_child_parsed| switch (interface_child_parsed) {
            .request => |request_parsed| {
                const request: Request = try .fromParsed(arena, request_parsed, parsed.version, all_interfaces, interface);
                const dest: *Request = request_list.addOneAssumeCapacity();
                dest.* = request;
                member_list.appendAssumeCapacity(.{ .request = dest });
            },
            .event => |event_parsed| {
                const event: Event = try .fromParsed(arena, event_parsed, parsed.version, all_interfaces, interface);
                const dest: *Event = event_list.addOneAssumeCapacity();
                dest.* = event;
                member_list.appendAssumeCapacity(.{ .event = dest });
            },
            .@"enum" => |enum_parsed| {
                const @"enum": *const Enum = for (interface.enums) |*item| {
                    if (mem.eql(u8, enum_parsed.name, item.name)) break item;
                } else unreachable;
                member_list.appendAssumeCapacity(.{ .@"enum" = @"enum" });
            },
            .description => {},
        };
        interface.all_members = member_list.items;
        interface.requests = request_list.items;
        interface.events = event_list.items;
    }
};

pub const InterfaceMember = union(enum) {
    request: *const Request,
    event: *const Event,
    @"enum": *const Enum,
};

pub const Request = struct {
    name: []const u8,
    description: ?Description,
    since: VersionNumber,
    deprecated_since: ?VersionNumber,
    is_deprecated: bool,
    // TODO make use of the type attr for requests and events
    is_destructor: bool,
    args: []const Arg,

    pub fn writeInfoSource(
        request: Request,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        try printLine(writer, ".name = \"{s}\",", .{ request.name }, format, indent_level);
        if (request.since != 1) {
            try printLine(writer, ".since = {d},", .{ request.since }, format, indent_level);
        }
        if (request.deprecated_since) |v| {
            try printLine(writer, ".deprecated_since = {d},", .{ v }, format, indent_level);
        }
        if (request.args.len != 0) {
            try printLine(writer, ".args = &.{{", .{}, format, indent_level);
            for (request.args) |arg| {
                try arg.writeInfoSource(arena, writer, format, indent_level + 1);
            }
            try printLine(writer, "}},", .{}, format, indent_level);
        } else {
            try printLine(writer, ".args = &.{{}},", .{}, format, indent_level);
        }
    }

    pub fn fromParsed(
        arena: Allocator,
        parsed: RequestParse,
        interface_version: VersionNumber,
        interfaces: []const Interface,
        this_interface: *const Interface,
    ) ReparseError!Request {
        const since,
        const deprecated_since,
        const is_deprecated = try versionInfo(interface_version, parsed.since, parsed.@"deprecated-since");
        var description: ?Description = null;
        var arg_count: usize = 0;
        for (parsed.content) |request_child_parse| switch (request_child_parse) {
            .arg => arg_count += 1,
            .description => |description_parse| {
                if (description == null) {
                    description = try .fromParsed(arena, description_parse);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        var arg_list: ArrayList(Arg) = try .initCapacity(arena, arg_count);
        for (parsed.content) |request_child_parse| switch (request_child_parse) {
            .arg => |arg_parse| arg_list.appendAssumeCapacity(try .fromParsed(arena, arg_parse, interfaces, this_interface)),
            .description => {},
        };
        return .{
            .name = parsed.name,
            .description = description,
            .since = since,
            .deprecated_since = deprecated_since,
            .is_deprecated = is_deprecated,
            .is_destructor = if (parsed.@"type") |t| ( switch (t) {
                .destructor => true,
            } ) else false,
            .args = arg_list.items,
        };
    }
};

pub const Event = struct {
    name: []const u8,
    description: ?Description,
    since: VersionNumber,
    deprecated_since: ?VersionNumber,
    is_deprecated: bool,
    // TODO make use of the type attr for requests and events
    is_destructor: bool,
    args: []const Arg,

    pub fn writeInfoSource(
        event: Event,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        try printLine(writer, ".name = \"{s}\",", .{ event.name }, format, indent_level);
        if (event.since != 1) {
            try printLine(writer, ".since = {d},", .{ event.since }, format, indent_level);
        }
        if (event.deprecated_since) |v| {
            try printLine(writer, ".deprecated_since = {d},", .{ v }, format, indent_level);
        }
        if (event.args.len != 0) {
            try printLine(writer, ".args = &.{{", .{}, format, indent_level);
            for (event.args) |arg| {
                try arg.writeInfoSource(arena, writer, format, indent_level + 1);
            }
            try printLine(writer, "}},", .{}, format, indent_level);
        } else {
            try printLine(writer, ".args = &.{{}},", .{}, format, indent_level);
        }
    }

    pub fn fromParsed(
        arena: Allocator,
        parsed: EventParse,
        interface_version: VersionNumber,
        interfaces: []const Interface,
        this_interface: *const Interface,
    ) ReparseError!Event {
        const since,
        const deprecated_since,
        const is_deprecated = try versionInfo(interface_version, parsed.since, parsed.@"deprecated-since");
        var description: ?Description = null;
        var arg_count: usize = 0;
        for (parsed.content) |event_child_parse| switch (event_child_parse) {
            .arg => arg_count += 1,
            .description => |description_parse| {
                if (description == null) {
                    description = try .fromParsed(arena, description_parse);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        var arg_list: ArrayList(Arg) = try .initCapacity(arena, arg_count);
        for (parsed.content) |event_child_parse| switch (event_child_parse) {
            .arg => |arg_parse| arg_list.appendAssumeCapacity(try .fromParsed(arena, arg_parse, interfaces, this_interface)),
            .description => {},
        };
        return .{
            .name = parsed.name,
            .description = description,
            .since = since,
            .deprecated_since = deprecated_since,
            .is_deprecated = is_deprecated,
            .is_destructor = if (parsed.@"type") |t| ( switch (t) {
                .destructor => true,
            } ) else false,
            .args = arg_list.items,
        };
    }
};

pub const Arg = struct {
    name: []const u8,
    description: ?Description,
    @"type": ArgType,
    interface: ?*const Interface,
    optional: bool,
    @"enum": ?struct { *const Interface, *const Enum },

    pub fn writeInfoSource(
        arg: Arg,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        try printLine(writer, ".{{", .{}, format, indent_level);
        try printLine(writer, ".name = \"{s}\",", .{ arg.name }, format, indent_level + 1);
        if (arg.optional) {
            try printLine(writer, ".optional = true,", .{}, format, indent_level + 1);
        }
        if (arg.@"enum") |@"enum"| {
            const i: *const Interface, const e: *const Enum = @"enum";
            const i_name = try xml.caseSnakeToPascal(arena, i.name);
            defer arena.free(i_name);
            const e_name = try xml.caseSnakeToPascal(arena, e.name);
            defer arena.free(e_name);
            try printLine(writer, ".@\"enum\" = {s}.{s},", .{ i_name, e_name }, format, indent_level + 1);
        }
        switch (arg.@"type") {
            .new_id => {
                if (arg.interface) |i| {
                    try printLine(writer, ".value = .{{ .new_id = .{s} }},", .{ i.name }, format, indent_level + 1);
                } else {
                    try printLine(writer, ".value = .new_id_factory,", .{}, format, indent_level + 1);
                }
            },
            else => |t| try printLine(writer, ".value = .{t},", .{ t }, format, indent_level + 1),
        }
        try printLine(writer, "}},", .{}, format, indent_level);
    }

    pub fn fromParsed(
        arena: Allocator,
        parsed: ArgParse,
        interfaces: []const Interface,
        this_interface: *const Interface,
    ) ReparseError!Arg {
        var description: ?Description = null;
        for (parsed.content) |arg_child_parse| switch (arg_child_parse) {
            .description => |description_parse| {
                if (description == null) {
                    description = try .fromParsedAttrs(arena, description_parse, parsed.summary, parsed.description);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        if (description == null) {
            if (parsed.summary != null or parsed.description != null) {
                description = try .fromAttrs(arena, parsed.summary, parsed.description);
            }
        }
        const interface: ?*const Interface =
            if (parsed.interface) |interface_name|
                for (interfaces) |*interface| {
                    if (mem.eql(u8, interface_name, interface.name)) break interface;
                } else return error.ArgInterfaceNameInvalid
            else
                null;
        const @"enum": ?struct { *const Interface, *const Enum } =
            if (parsed.@"enum") |enum_name|
                try findEnum(enum_name, this_interface, this_interface.enums, interfaces)
            else
                null;
        const optional: bool = switch (parsed.@"allow-null" orelse .@"false") {
            .@"true" => true,
            .@"false" => false,
        };
        return .{
            .name = parsed.name,
            .description = description,
            .@"type" = parsed.@"type",
            .interface = interface,
            .optional = optional,
            .@"enum" = @"enum",
        };
    }

    fn findEnum(
        name: []const u8,
        this_interface: *const Interface,
        this_interface_enums: []const Enum,
        interfaces: []const Interface,
    ) (error{ArgEnumNameInvalid})!struct { *const Interface, *const Enum } {
        if (mem.cutScalar(u8, name, '.')) |pair| {
            const interface_name, const enum_name = pair;
            const interface: *const Interface = for (interfaces) |*iface| {
                if (mem.eql(u8, interface_name, iface.name)) break iface;
            } else return error.ArgEnumNameInvalid;
            const @"enum": *const Enum = for (interface.enums) |*e| {
                if (mem.eql(u8, enum_name, e.name)) break e;
            } else return error.ArgEnumNameInvalid;
            return .{ interface, @"enum" };
        } else {
            return for (this_interface_enums) |*e| {
                if (mem.eql(u8, name, e.name)) break .{ this_interface, e };
            } else error.ArgEnumNameInvalid;
        }
    }
};

pub const Enum = struct {
    name: []const u8,
    description: ?Description,
    since: VersionNumber,
    deprecated_since: ?VersionNumber,
    is_deprecated: bool,
    backing_value: EnumFields.Backing,
    fields: EnumFields,

    pub fn writeTypeSource(
        @"enum": Enum,
        arena: Allocator,
        writer: *Io.Writer,
        format: SourceFormat,
        indent_level: usize,
    ) WriteSourceError!void {
        const backing_value_name: []const u8 = switch (@"enum".backing_value) {
            .unsigned_32 => "u32",
            .signed_32 => "i32",
        };
        const pascal_name = try xml.caseSnakeToPascal(arena, @"enum".name);
        switch (@"enum".fields) {
            .int => try printLine(
                writer,
                "pub const {s} = enum({s}) {{",
                .{ pascal_name, backing_value_name },
                format,
                indent_level,
            ),
            .bitfield => try printLine(
                writer,
                "pub const {s} = packed struct({s}) {{",
                .{ pascal_name, backing_value_name },
                format,
                indent_level,
            ),
        }

        switch (@"enum".fields) {
            .int => |int| try int.writeSource(arena, writer, format, indent_level + 1),
            .bitfield => |bitfield| try bitfield.writeSource(arena, writer, pascal_name, format, indent_level + 1),
        }

        try writer.writeByte('\n');

        try printLine(writer, "pub const info: EnumInfo = .{{", .{}, format, indent_level + 1);
        {
            try printLine(writer, ".since = {d},", .{ @"enum".since }, format, indent_level + 2);
            if (@"enum".deprecated_since) |v| {
                try printLine(writer, ".deprecated_since = {d},", .{ v }, format, indent_level + 2);
            }
            try printLine(writer, ".entries = &.{{", .{}, format, indent_level + 2);
            switch (@"enum".fields) {
                inline else => |fields| try fields.writeInfoSource(writer, format, indent_level + 3),
            }
            try printLine(writer, "}},", .{}, format, indent_level + 2);
        }
        try printLine(writer, "}};", .{}, format, indent_level + 1);

        try printLine(writer, "}};", .{}, format, indent_level);
    }

    pub fn fromParsed(
        arena: Allocator,
        parsed: EnumParse,
        interface_version: VersionNumber,
    ) ReparseError!Enum {
        const since,
        const deprecated_since,
        const is_deprecated = try versionInfo(interface_version, parsed.since, parsed.@"deprecated-since");
        var description: ?Description = null;
        for (parsed.content) |enum_child_parse| switch (enum_child_parse) {
            .entry => {},
            .description => |description_parse| {
                if (description == null) {
                    description = try .fromParsed(arena, description_parse);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        const backing: EnumFields.Backing = try .findValidate(arena, parsed.content);
        const value: EnumFields = switch (parsed.bitfield orelse .@"false") {
            .@"false" => .{ .int = try .fromParsed(arena, parsed.content, interface_version) },
            .@"true" => .{ .bitfield = try .fromParsed(arena, parsed.content, backing, interface_version) },
        };
        return .{
            .name = parsed.name,
            .description = description,
            .since = since,
            .deprecated_since = deprecated_since,
            .is_deprecated = is_deprecated,
            .backing_value = backing,
            .fields = value,
        };
    }
};

pub const EnumFields = union(enum) {
    int: Int,
    bitfield: Bitfield,

    pub const Backing = enum {
        unsigned_32,
        signed_32,

        pub fn findValidate(arena: Allocator, enum_parse_children: []const EnumParseChild) ReparseError!Backing {
            const minInt = std.math.minInt;
            const maxInt = std.math.maxInt;
            var low: i33 = maxInt(i33);
            var high: i33 = minInt(i33);
            var seen: ArrayList(i33) = try .initCapacity(arena, enum_parse_children.len);
            defer seen.deinit(arena);
            for (enum_parse_children) |enum_child_parse| switch (enum_child_parse) {
                .description => {},
                .entry => |entry_parse| {
                    const value = std.fmt.parseInt(i33, entry_parse.value, 0)
                        catch return error.EnumValuesInvalid;
                    if (mem.findScalar(i33, seen.items, value)) |_|
                        return error.EnumValuesInvalid;
                    if (value < low) low = value;
                    if (value > high) high = value;
                    seen.appendAssumeCapacity(value);
                },
            };
            if (low >= minInt(u32) and high <= maxInt(u32)) return .unsigned_32;
            if (low >= minInt(i32) and high <= maxInt(i32)) return .signed_32;
            return error.EnumValuesInvalid;
        }
    };

    pub const Int = struct {
        entries: []const Entry,

        pub const Entry = struct { info: EntryInfo, value: []const u8 };

        pub fn writeSource(
            fields: Int,
            arena: Allocator,
            writer: *Io.Writer,
            format: SourceFormat,
            indent_level: usize,
        ) WriteSourceError!void {
            for (fields.entries) |entry| {
                if (entry.info.description) |description| try description.writeSource(writer, format, indent_level);
                const name = try xml.decollideIdentifierNonempty(arena, entry.info.name);
                try printLine(writer, "{s} = {s},", .{ name, entry.value }, format, indent_level);
            }
        }

        pub fn writeInfoSource(
            fields: Int,
            writer: *Io.Writer,
            format: SourceFormat,
            indent_level: usize,
        ) Io.Writer.Error!void {
            for (fields.entries) |entry| {
                if (entry.info.deprecated_since) |v| {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d}, .deprecated_since = {d} }},",
                        .{ entry.info.name, entry.info.since, v },
                        format,
                        indent_level,
                    );
                } else {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d} }},",
                        .{ entry.info.name, entry.info.since },
                        format,
                        indent_level,
                    );
                }
            }
        }

        pub fn fromParsed(
            arena: Allocator,
            enum_parse_children: []const EnumParseChild,
            interface_version: VersionNumber,
        ) ReparseError!Int {
            var entry_list: ArrayList(Entry) = try .initCapacity(arena, enum_parse_children.len);
            for (enum_parse_children) |enum_child_parse| switch (enum_child_parse) {
                .description => {},
                .entry => |entry_parse| {
                    const info: EntryInfo = try .fromParsed(arena, entry_parse, interface_version);
                    entry_list.appendAssumeCapacity(.{ .info = info, .value = entry_parse.value });
                },
            };
            return .{ .entries = entry_list.items };
        }
    };

    pub const Bitfield = struct {
        entries: []const Entry,
        combination_entries: []const CombinationEntry,

        pub const Entry = struct { info: EntryInfo, bit_idx: u5 };
        /// A valid field which is the union of other fields, e.g.
        /// `top=1, left=2, top_left=5`
        pub const CombinationEntry = struct { info: EntryInfo, fields: []const *const Entry };

        pub fn writeInfoSource(
            fields: Bitfield,
            writer: *Io.Writer,
            format: SourceFormat,
            indent_level: usize,
        ) Io.Writer.Error!void {
            for (fields.entries) |entry| {
                if (entry.info.deprecated_since) |v| {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d}, .deprecated_since = {d} }},",
                        .{ entry.info.name, entry.info.since, v },
                        format,
                        indent_level,
                    );
                } else {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d} }},",
                        .{ entry.info.name, entry.info.since },
                        format,
                        indent_level,
                    );
                }
            }
            for (fields.combination_entries) |entry| {
                if (entry.info.deprecated_since) |v| {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d}, .deprecated_since = {d} }},",
                        .{ entry.info.name, entry.info.since, v },
                        format,
                        indent_level,
                    );
                } else {
                    try printLine(
                        writer,
                        ".{{ .name = \"{s}\", .since = {d} }},",
                        .{ entry.info.name, entry.info.since },
                        format,
                        indent_level,
                    );
                }
            }
        }

        pub fn writeSource(
            fields: Bitfield,
            arena: Allocator,
            writer: *Io.Writer,
            enum_pascal_name: []const u8,
            format: SourceFormat,
            indent_level: usize,
        ) WriteSourceError!void {
            var pad_idx: u8 = 0;
            var bit_idx: u8 = 0;
            for (fields.entries) |entry| {
                const padding_bits = entry.bit_idx - @as(u5, @intCast(bit_idx));
                if (padding_bits != 0) {
                    try printLine(writer, "_{d}: u{d} = 0,", .{ pad_idx, padding_bits }, format, indent_level);
                    pad_idx += 1;
                }
                if (entry.info.description) |description| try description.writeSource(writer, format, indent_level);
                const name = try xml.decollideIdentifierNonempty(arena, entry.info.name);
                try printLine(writer, "{s}: bool = false,", .{ name }, format, indent_level);
                bit_idx = @as(u8, entry.bit_idx) + 1;
            }
            const post_padding_bits = 32 - bit_idx;
            if (post_padding_bits != 0) {
                try printLine(writer, "_{d}: u{d} = 0,", .{ pad_idx, post_padding_bits }, format, indent_level);
            }
            for (fields.combination_entries) |entry| {
                try writer.writeByte('\n');
                if (entry.info.description) |description| try description.writeSource(writer, format, indent_level);
                const name = try xml.decollideIdentifierNonempty(arena, entry.info.name);
                if (entry.fields.len == 0) {
                    try printLine(writer, "pub const {s}: {s} = .{{}};", .{ name, enum_pascal_name }, format, indent_level);
                } else {
                    try printLine(writer, "pub const {s}: {s} = .{{", .{ name, enum_pascal_name }, format, indent_level);
                    for (entry.fields) |field| {
                        const field_name = try xml.decollideIdentifierNonempty(arena, field.info.name);
                        try printLine(writer, ".{s} = true,", .{ field_name }, format, indent_level + 1);
                    }
                    try printLine(writer, "}};", .{}, format, indent_level);
                }
            }
        }

        pub fn fromParsed(
            arena: Allocator,
            enum_parse_children: []const EnumParseChild,
            backing: Backing,
            interface_version: VersionNumber,
        ) ReparseError!Bitfield {
            var bitset: u32 = 0;
            var entries_list: ArrayList(Entry) = try .initCapacity(arena, enum_parse_children.len);
            var invalid_entries_list: ArrayList(struct { EntryInfo, u32 }) = try .initCapacity(arena, enum_parse_children.len);
            for (enum_parse_children) |enum_child_parse| switch (enum_child_parse) {
                .description => {},
                .entry => |entry_parse| {
                    const info: EntryInfo = try .fromParsed(arena, entry_parse, interface_version);
                    switch (backing) {
                        inline .unsigned_32, .signed_32 => |b| {
                            const T = switch (b) {
                                .unsigned_32 => u32,
                                .signed_32 => i32,
                            };
                            const value: u32 = @bitCast(std.fmt.parseInt(T, entry_parse.value, 0) catch unreachable);
                            if (value > 0 and std.math.isPowerOfTwo(value)) {
                                if (value & bitset != 0) return error.EnumValuesInvalid;
                                entries_list.appendAssumeCapacity(.{ .info = info, .bit_idx = @intCast(@ctz(value)) });
                                bitset |= value;
                            } else {
                                for (invalid_entries_list.items) |invalid_entry| {
                                    if (invalid_entry[1] == value) return error.EnumValuesInvalid;
                                }
                                invalid_entries_list.appendAssumeCapacity(.{ info, value });
                            }
                        },
                    }
                },
            };
            mem.sort(Entry, entries_list.items, {}, struct {
                fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                    return lhs.bit_idx < rhs.bit_idx;
                }
            }.lessThan);
            const combination_entries = try arena.alloc(CombinationEntry, invalid_entries_list.items.len);
            for (combination_entries, invalid_entries_list.items) |*comb_entry, invalid_entry| {
                const info: EntryInfo, const value: u32 = invalid_entry;
                if (bitset & value != value) return error.EnumValuesInvalid;
                const sub_entries_size = @popCount(value);
                const sub_entries = try arena.alloc(*const Entry, sub_entries_size);
                var idx: u8 = 0;
                for (entries_list.items) |*entry| {
                    const as_int = @shlExact(@as(u32, 1), entry.bit_idx);
                    if (as_int & value != 0) {
                        sub_entries[idx] = entry;
                        idx += 1;
                    }
                }
                if (idx != sub_entries_size) unreachable;
                comb_entry.* = .{ .info = info, .fields = sub_entries };
            }
            return .{
                .entries = entries_list.items,
                .combination_entries = combination_entries,
            };
        }
    };
};

pub const EntryInfo = struct {
    name: []const u8,
    description: ?Description,
    since: VersionNumber,
    deprecated_since: ?VersionNumber,
    is_deprecated: bool,

    pub fn fromParsed(arena: Allocator, parsed: EntryParse, interface_version: VersionNumber) ReparseError!EntryInfo {
        const since,
        const deprecated_since,
        const is_deprecated = try versionInfo(interface_version, parsed.since, parsed.@"deprecated-since");
        var description: ?Description = null;
        for (parsed.content) |entry_child_parse| switch (entry_child_parse) {
            .description => |description_parse| {
                if (description == null) {
                    description = try .fromParsedAttrs(arena, description_parse, parsed.summary, parsed.description);
                } else {
                    return error.DescriptionCollision;
                }
            },
        };
        if (description == null) {
            if (parsed.summary != null or parsed.description != null) {
                description = try .fromAttrs(arena, parsed.summary, parsed.description);
            }
        }
        return .{
            .name = parsed.name,
            .description = description,
            .since = since,
            .deprecated_since = deprecated_since,
            .is_deprecated = is_deprecated,
        };
    }
};

pub fn versionInfo(
    interface_version: VersionNumber,
    since: ?VersionNumber,
    dep_since: ?VersionNumber,
) (error{InvalidVersionNumber})!struct { VersionNumber, ?VersionNumber, bool } {
    if (dep_since) |v| if (v == 0) return error.InvalidVersionNumber;
    if (since) |v| if (v == 0) return error.InvalidVersionNumber;
    if (since) |s| {
        if (dep_since) |d| {
            if (d <= s) return error.InvalidVersionNumber;
        }
    }
    const is_dep = if (dep_since) |dep| interface_version >= dep else false;
    return .{ since orelse 1, dep_since, is_dep };
}

fn printLine(
    writer: *Io.Writer,
    comptime fmt: []const u8,
    args: anytype,
    format: SourceFormat,
    indent_level: usize,
) Io.Writer.Error!void {
    try writer.splatBytesAll(format.indent, indent_level);
    try writer.print(fmt, args);
    try writer.writeByte('\n');
}

pub const ArgType: type = @FieldType(ArgParse, "type");
pub const VersionNumber = u32;
pub const version_int_info = @typeInfo(VersionNumber).int;

const CopyrightParse: type = copyright_schema.Parsed();
const DescriptionParse: type = description_schema.Parsed();
const ProtocolParse: type = protocol_schema.Parsed();
const InterfaceParse: type = interface_schema.Parsed();
const RequestParse: type = request_schema.Parsed();
const EventParse: type = event_schema.Parsed();
const EnumParse: type = enum_schema.Parsed();
const EnumParseChild: type = @typeInfo(@FieldType(EnumParse, "content")).pointer.child;
const ArgParse: type = arg_schema.Parsed();
const EntryParse: type = entry_schema.Parsed();

const copyright_schema: Schema = .{
    .tag_name = "copyright",
    .content = .literal_text,
};

const description_schema: Schema = .{
    .tag_name = "description",
    .attributes = &.{
        .{ .name = "summary", .value = .string },
    },
    .content = .literal_text,
};

const protocol_schema: Schema = .{
    .tag_name = "protocol",
    .attributes = &.{
        .{ .name = "name", .value = .string },
    },
    .content = .{ .child_nodes = &.{
        interface_schema,
        copyright_schema,
    } },
};

const interface_schema: Schema = .{
    .tag_name = "interface",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "version", .value = .{ .int = version_int_info } },
    },
    .content = .{ .child_nodes = &.{
        request_schema,
        event_schema,
        enum_schema,
        description_schema,
    } },
};

const request_schema: Schema = .{
    .tag_name = "request",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "deprecated-since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "type",  .optional = true, .value = .{ .@"enum" = &.{
            "destructor",
        } } },
    },
    .content = .{ .child_nodes = &.{
        arg_schema,
        description_schema,
    } },
};

const event_schema: Schema = .{
    .tag_name = "event",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "deprecated-since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "type",  .optional = true, .value = .{ .@"enum" = &.{
            "destructor",
        } } },
    },
    .content = .{ .child_nodes = &.{
        arg_schema,
        description_schema,
    } },
};

const enum_schema: Schema = .{
    .tag_name = "enum",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "deprecated-since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "bitfield",  .optional = true, .value = .{ .@"enum" = &.{
            "true",
            "false",
        } } },
    },
    .content = .{ .child_nodes = &.{
        entry_schema,
        description_schema,
    } },
};

const arg_schema: Schema = .{
    .tag_name = "arg",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "type", .value = .{ .@"enum" = &.{
            "int",
            "uint",
            "fixed",
            "string",
            "object",
            "new_id",
            "array",
            "fd",
        } } },
        .{ .name = "interface", .value = .string, .optional = true },
        .{ .name = "allow-null", .optional = true, .value = .{ .@"enum" = &.{
            "true",
            "false",
        } } },
        .{ .name = "summary", .value = .string, .optional = true },
        .{ .name = "description", .value = .string, .optional = true },
        .{ .name = "enum", .value = .string, .optional = true },
    },
    .content = .{ .child_nodes = &.{
        description_schema,
    } },
};

const entry_schema: Schema = .{
    .tag_name = "entry",
    .attributes = &.{
        .{ .name = "name", .value = .string },
        .{ .name = "value", .value = .string },
        .{ .name = "summary", .value = .string, .optional = true },
        .{ .name = "description", .value = .string, .optional = true },
        .{ .name = "since", .value = .{ .int = version_int_info }, .optional = true },
        .{ .name = "deprecated-since", .value = .{ .int = version_int_info }, .optional = true },
    },
    .content = .{ .child_nodes = &.{
        description_schema,
    } },
};

const Schema = xml.Schema;
const xml = @import("xml.zig");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ascii = std.ascii;
const log = std.log;
const mem = std.mem;
const std = @import("std");
