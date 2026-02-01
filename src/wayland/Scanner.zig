//! Parses Wayland protocol XML into Zig source imported and consumed by the Spark library.
//! This module is both an executable root and the object that parses and writes.

/// A file path argument to this executable with this prefix
/// will be written to as the output sink.
/// Otherwise, it writes to stdout.
pub const output_arg_prefix = "-o";

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator = switch (@import("builtin").mode) {
        .Debug => debug_allocator.allocator(),
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };
    defer switch (@import("builtin").mode) {
        .Debug => switch (debug_allocator.deinit()) {
            .ok => {},
            .leak => log.warn("memory leaks(s) detected during Wayland XML parsing", .{}),
        },
        else => {},
    };

    // TODO async IO
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var in_file_list: std.ArrayList([:0]const u8) = .empty;
    var out_file_path: ?[:0]const u8 = null;
    defer in_file_list.deinit(allocator);
    var arg_iterator: std.process.ArgIterator = try .initWithAllocator(allocator);
    defer arg_iterator.deinit();
    // The first argument is the program invokation
    assert(arg_iterator.next() != null);
    while (arg_iterator.next()) |arg| {
        const o = output_arg_prefix;
        if (arg.len > o.len and mem.eql(u8, o, arg[0..o.len])) {
            if (out_file_path == null) {
                out_file_path = arg[o.len..];
            } else {
                std.log.warn("ignoring additional output arg \'{s}\'", .{ arg });
            }
        } else {
            try in_file_list.append(allocator, arg);
        }
    }

    // TODO fs -> Io.Dir ?
    const cwd = std.fs.cwd();

    const out_file: std.fs.File =
        if (out_file_path) |path| cwd.openFile(path, .{ .mode = .write_only })
            catch return error.OutputFileOpenFailure
        else .stdout();
    var writer = out_file.writer(&write_buffer);
    defer { if (out_file_path) |_| out_file.close(); }

    var scanner: Scanner = try .init(allocator);
    defer scanner.deinit(allocator);

    if (in_file_list.items.len == 0) {
        read_buffer = undefined;
        var reader = Io.File.stdin().reader(io, &read_buffer);
        scanner.newStream();
        scanner.stream(&writer.interface, &reader.interface, allocator) catch |err| switch (err) {
            error.OutOfMemory,
            error.UnsupportedEncoding => |e| return e,
            error.WriteFailed => return writer.err orelse error.WriteFailedMissingError,
            error.ReadFailed => {
                if (reader.err) |e| {
                    log.err("{t} while reading stdin", .{ e });
                    return e;
                } else {
                    return error.ReadFailed;
                }
            },
            error.InvalidWaylandXML => {
                scanner.logSourceInvalidErr(std.log.err, "stdin");
                return error.ProtocolXMLParseFailure;
            },
            error.StreamIncomplete => return error.ProtocolXMLParseFailure,
        };
    } else for (in_file_list.items) |path| {
        read_buffer = undefined;
        const file = try cwd.openFile(path, .{ .mode = .read_only });
        defer file.close();
        var reader = file.reader(io, &read_buffer);
        scanner.newStream();
        scanner.stream(&writer.interface, &reader.interface, allocator) catch |err| switch (err) {
            error.OutOfMemory,
            error.UnsupportedEncoding, => |e| return e,
            error.WriteFailed => return writer.err orelse error.WriteFailedMissingError,
            error.ReadFailed => {
                if (reader.err) |e| {
                    log.err("{t} while reading {s}", .{ e, path });
                    return e;
                } else {
                    return error.ReadFailed;
                }
            },
            error.InvalidWaylandXML => {
                scanner.logSourceInvalidErr(std.log.err, path);
                return error.ProtocolXMLParseFailure;
            },
            error.StreamIncomplete => return error.ProtocolXMLParseFailure,
        };
        // Don't try to continue with other files after one file failed,
        // because we have probably now written incomplete and invalid source
    }

    // TODO unsure if when file writers/readers fail this would ever be null
    // (also above)
    writer.interface.flush() catch return writer.err orelse error.WriteFailedMissingError;
}

pub const Opcode = u32;
pub const BackingEnum = u32;

pub const SourceFormat = struct {
    indent: []const u8 = "    ",
};

/// Assumes multi-line strings in `protocols`
/// use exclusively Unix newlines.
pub fn writeProtocolSource(
    allocator: Allocator,
    protocols: []const Protocol,
    writer: *Io.Writer,
    format: SourceFormat,
) (Allocator.Error || Io.Writer.Error)!void {
    for (protocols) |protocol| {
        assert(isValidName(protocol.name));
        for (protocol.interfaces) |interface| {
            assert(isValidName(interface.name));
            if (interface.description_short) |description| {
                for (description) |c| assert(c != '\n');
            }
        }
    }

    for (protocols, 0..) |protocol, protocol_index| {
        if (protocol.copyright) |copyright| {
            var line_iter = mem.splitScalar(u8, copyright, '\n');
            while (line_iter.next()) |line| {
                try writer.writeAll("// ");
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
        }

        try writer.writeAll("pub const ");
        try writer.writeAll(protocol.name);
        try writer.writeAll(" = struct {\n");

        for (protocol.interfaces, 0..) |interface, interface_index| {
            try writeTagDescriptionSource(
                writer,
                interface.description_short,
                interface.description_long,
                format.indent,
                1,
            );

            try writer.writeAll(format.indent);
            try writer.writeAll("pub const ");
            try writer.writeAll(interface.name);
            try writer.writeAll(" = struct {\n");

            try writer.splatBytesAll(format.indent, 2);
            try writer.print("pub const version = {d};\n\n", .{ interface.version });

            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("pub const RequestCode = enum (" ++ @typeName(Opcode) ++ ") {\n");
            {
                var idx: usize = 0;
                for (interface.objects) |object| {
                    switch (object) {
                        .request => |request| {
                            if (request.description_short) |description| {
                                try writer.splatBytesAll(format.indent, 3);
                                try writer.writeAll("/// ");
                                try writer.writeAll(description);
                                try writer.writeByte('\n');
                            }
                            try writer.splatBytesAll(format.indent, 3);
                            try writer.print("{s} = {d},\n", .{ request.name, idx });
                            idx += 1;
                        },
                        else => {},
                    }
                }
                try writer.splatBytesAll(format.indent, 3);
                try writer.writeAll("_,\n");
            }
            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("};\n\n");

            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("pub const Request = union (RequestCode) {\n");
            {
                for (interface.objects) |object| {
                    switch (object) {
                        .request => |request| {
                            const upper_name = try upperName(allocator, request.name);
                            defer allocator.free(upper_name);
                            try writer.splatBytesAll(format.indent, 3);
                            try writer.writeAll(request.name);
                            try writer.writeAll(": ");
                            try writer.writeAll(upper_name);
                            try writer.writeAll(",\n");
                        },
                        else => {},
                    }
                }
            }
            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("};\n\n");

            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("pub const EventCode = enum (" ++ @typeName(Opcode) ++ ") {\n");
            {
                var idx: usize = 0;
                for (interface.objects) |object| {
                    switch (object) {
                        .event => |event| {
                            if (event.description_short) |description| {
                                try writer.splatBytesAll(format.indent, 3);
                                try writer.writeAll("/// ");
                                try writer.writeAll(description);
                                try writer.writeByte('\n');
                            }
                            try writer.splatBytesAll(format.indent, 3);
                            try writer.print("{s} = {d},\n", .{ event.name, idx });
                            idx += 1;
                        },
                        else => {},
                    }
                }
                try writer.splatBytesAll(format.indent, 3);
                try writer.writeAll("_,\n");
            }
            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("};\n\n");

            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("pub const Event = enum (EventCode) {\n");
            {
                for (interface.objects) |object| {
                    switch (object) {
                        .event => |event| {
                            const upper_name = try upperName(allocator, event.name);
                            defer allocator.free(upper_name);
                            try writer.splatBytesAll(format.indent, 3);
                            try writer.writeAll(event.name);
                            try writer.writeAll(": ");
                            try writer.writeAll(upper_name);
                            try writer.writeAll(",\n");
                        },
                        else => {},
                    }
                }
            }
            try writer.splatBytesAll(format.indent, 2);
            try writer.writeAll("};\n\n");

            for (interface.objects, 0..) |object, object_index| {
                switch (object) {
                    .request => |request| {
                        const upper_name = try upperName(allocator, request.name);
                        defer allocator.free(upper_name);

                        try writeTagDescriptionSource(
                            writer,
                            request.description_short,
                            request.description_long,
                            format.indent,
                            2,
                        );
                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("pub const ");
                        try writer.writeAll(upper_name);
                        try writer.writeAll(" = struct {\n");

                        try writer.splatBytesAll(format.indent, 3);
                        try writer.writeAll("pub const since: ?comptime_int = ");
                        if (request.since) |since| {
                            try writer.print("{d}", .{ since });
                        } else {
                            try writer.writeAll("null");
                        }
                        try writer.writeAll(";\n\n");

                        {} // TODO request body

                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("};\n");
                    },

                    .event => |event| {
                        const upper_name = try upperName(allocator, event.name);
                        defer allocator.free(upper_name);

                        try writeTagDescriptionSource(
                            writer,
                            event.description_short,
                            event.description_long,
                            format.indent,
                            2,
                        );

                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("pub const ");
                        try writer.writeAll(upper_name);
                        try writer.writeAll(" = struct {\n");

                        try writer.splatBytesAll(format.indent, 3);
                        try writer.writeAll("pub const since: ?comptime_int = ");
                        if (event.since) |since| {
                            try writer.print("{d}", .{ since });
                        } else {
                            try writer.writeAll("null");
                        }
                        try writer.writeAll("};\n\n");

                        {} // TODO event body

                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("};\n");
                    },

                    .@"enum" => |@"enum"| {
                        const upper_name = try upperName(allocator, @"enum".name);
                        defer allocator.free(upper_name);

                        try writeTagDescriptionSource(
                            writer,
                            @"enum".description_short,
                            @"enum".description_long,
                            format.indent,
                            2,
                        );

                        const bitfield = @"enum".bitfield orelse false;

                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("pub const ");
                        try writer.writeAll(upper_name);
                        if (!bitfield) {
                            try writer.writeAll(" = enum (" ++ @typeName(BackingEnum) ++ ") {\n");
                        } else {
                            try writer.writeAll(" = packed struct (" ++ @typeName(BackingEnum) ++ ") {\n");
                        }

                        try writer.splatBytesAll(format.indent, 3);
                        try writer.writeAll("pub const since: ?comptime_int = ");
                        if (@"enum".since) |since| {
                            try writer.print("{d}", .{ since });
                        } else {
                            try writer.writeAll("null");
                        }
                        try writer.writeAll("};\n\n");

                        if (!bitfield) {
                            for (@"enum".entries) |entry| {
                                if (entry.summary) |summary| {
                                    try writer.splatBytesAll(format.indent, 3);
                                    try writer.writeAll("/// ");
                                    try writer.writeAll(summary);
                                    try writer.writeByte('\n');
                                }
                                try writer.splatBytesAll(format.indent, 3);
                                try writer.writeAll(entry.name);
                                try writer.writeAll(" = ");
                                try writer.writeAll(entry.value);
                                try writer.writeAll(",\n");
                            }
                        } else {
                            // TODO
                            // validation in parsing that allows these catch unreachables
                            // include assertions in doc comment

                            const entries_sorted = try allocator.dupe(Entry, @"enum".entries);
                            defer allocator.free(entries_sorted);
                            std.mem.sort(Entry, entries_sorted, {}, struct {
                                fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                                    const lhs_int = fmt.parseInt(BackingEnum, lhs.value, 0) catch unreachable;
                                    const rhs_int = fmt.parseInt(BackingEnum, rhs.value, 0) catch unreachable;
                                    return lhs_int < rhs_int;
                                }
                            }.lessThan);
                            defer allocator.free(entries_sorted);

                            var padding_idx: usize = 0;
                            for (entries_sorted, 0..) |entry, entry_index| {
                                const value = fmt.parseInt(BackingEnum, entry.value, 0)
                                    catch unreachable;
                                assert(std.math.isPowerOfTwo(value));
                                const last_value: BackingEnum =
                                    if (entry_index == 0) 0
                                    else fmt.parseInt(
                                        BackingEnum,
                                        entries_sorted[entry_index-1].value,
                                        0,
                                    ) catch unreachable;

                                const pre_padding_bits: u16 = @ctz(value) - (@ctz(last_value)+1);

                                if (pre_padding_bits != 0) {
                                    try writer.splatBytesAll(format.indent, 3);
                                    try writer.print("_{d}: u{d} = 0,\n", .{ padding_idx, pre_padding_bits });
                                    padding_idx += 1;
                                }

                                if (entry.summary) |summary| {
                                    try writer.splatBytesAll(format.indent, 3);
                                    try writer.writeAll("/// ");
                                    try writer.writeAll(summary);
                                    try writer.writeBytes('\n');
                                }

                                try writer.splatBytesAll(format.indent, 3);
                                try writer.writeAll(entry.name);
                                try writer.writeAll(": bool = false,\n");
                            }
                        }

                        try writer.splatBytesAll(format.indent, 2);
                        try writer.writeAll("};\n");
                    },
                }
                if (object_index != interface.objects.len-1) try writer.writeByte('\n');
            }

            try writer.writeAll(format.indent);
            try writer.writeAll("};\n");
            if (interface_index != protocol.interfaces.len-1) try writer.writeByte('\n');
        }

        try writer.writeAll("};");
        if (protocol_index != protocols.len-1) try writer.splatByteAll('\n', 2);
    }
}

pub fn writeTagDescriptionSource(
    writer: *Io.Writer,
    short: ?[]const u8,
    long: ?[]const u8,
    indent: []const u8,
    indentation: usize,
) Io.Writer.Error!void {
    if (short != null or long != null) {
        if (short) |description| {
            try writer.splatBytesAll(indent, indentation);
            try writer.writeAll("/// ");
            try writer.writeAll(description);
            try writer.writeByte('\n');
        }

        if (short != null and long != null) {
            try writer.splatBytesAll(indent, indentation);
            try writer.writeAll("///\n");
        }

        if (long) |description| {
            var line_iter = mem.splitScalar(u8, description, '\n');
            while (line_iter.next()) |line| {
                try writer.splatBytesAll(indent, indentation);
                try writer.writeAll("/// ");
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
        }
    }
}

pub const SourceInvalidError = enum {
    broken_tag,
    empty_tag_name,
    unsupported_tag,
    clobber,
    invalid_attributes,
    invalid_name,
    mismatched_tag_close,
    unvalued_attribute,
    invalid_forward_slash,
    invalid_attribute_name_char,
    double_open_bracket,
    invalid_before_attribute_value,
    equals_before_attribute_name,
    invalid_declaration_question_mark,
    double_declaration,
    invalid_declaration_name,
    invalid_declaration_attributes,
    invalid_non_self_closing,
    invalid_self_closing,
    doctype_unsupported,
    non_root_protocol,
    interface_not_protocol_child,
    interface_child_not,
    invalid_arg_parent,
    invalid_entry_parent,
    invalid_description_parent,
    invalid_copyright_parent,
    invalid_entry_value,
    missing_attribute_at_final,
};

pub fn logSourceInvalidError(scanner: Scanner, comptime logFn: anytype, file_path: []const u8) void {
    if (scanner.source_invalid_err) |err| {
        switch (err) {
            .broken_tag => logFn(
                "{s}:{d}:{d}: source ends in unclosed tag",
                .{ file_path, scanner.line, scanner.column },
            ),
            .empty_tag_name => logFn(
                "{s}:{d}:{d}: expected a tag name, found \'>\'",
                .{ file_path, scanner.line, scanner.column },
            ),
            .unsupported_tag => logFn(
                "{s}:{d}:{d}: unsupported tag name \'{s}\'",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items }
            ),
            .clobber => logFn(
                "{s}:{d}:{d}: double declaration of attribute or description",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_attributes => logFn(
                "{s}:{d}:{d}: invalid attributes for tag <{s}>",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .invalid_name => logFn(
                "{s}:{d}:{d}: invalid {s} name (expected ^[a-z_][a-z0-9_]*$)",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .mismatched_tag_close => logFn(
                "{s}:{d}:{d}: mismatched \'<{s}>\' closing tag",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .unvalued_attribute => logFn(
                "{s}:{d}:{d}: attribute \'{s}\' has no value",
                .{ file_path, scanner.line, scanner.column, scanner.attribute_name_buffer.items },
            ),
            .invalid_forward_slash => logFn(
                "{s}:{d}:{d}: expected \'>\' after \'/\', found \'{c}\'",
                .{ file_path, scanner.line, scanner.column, scanner.last_byte.? },
            ),
            .invalid_attribute_name_char => logFn(
                "{s}:{d}:{d}: invalid character \'{c}\' in attribute name",
                .{ file_path, scanner.line, scanner.column, scanner.last_byte.? },
            ),
            .double_open_bracket => logFn(
                "{s}:{d}:{d}: encountered \'<\' while parsing tag",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_before_attribute_value => logFn(
                "{s}:{d}:{d}: expected start of attribute value, found \'{c}\'",
                .{ file_path, scanner.line, scanner.column, scanner.last_byte.? },
            ),
            .equals_before_attribute_name => logFn(
                "{s}:{d}:{d}: expected attribute name, found \'=\'",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_declaration_question_mark => logFn(
                "{s}:{d}:{d}: invalid token \'?{c}\' in declaration tag",
                .{ file_path, scanner.line, scanner.column, scanner.last_byte.? },
            ),
            .double_declaration => logFn(
                "{s}:{d}:{d}: encountered second XML declaration",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_declaration_name => logFn(
                "{s}:{d}:{d}: expected declaration tag name \'{s}\', found \'{s}\'",
                .{ file_path, scanner.line, scanner.column, XMLDeclaration.tag_name, scanner.tag_name_buffer.items },
            ),
            .invalid_declaration_attributes => logFn(
                "{s}:{d}:{d}: invalid attributes for \'<?xml?>\' tag",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_non_self_closing => logFn(
                "{s}:{d}:{d}: <{s}> is only supported as a self-closing tag",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .invalid_self_closing => logFn(
                "{s}:{d}:{d}: <{s}/> is unsupported as a self-closing tag",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .doctype_unsupported => logFn(
                "{s}:{d}:{d}: <!DOCTYPE> is unsupported",
                .{ file_path, scanner.line, scanner.column },
            ),
            .non_root_protocol => logFn(
                "{s}:{d}:{d}: protocol tag must only appear at root level",
                .{ file_path, scanner.line, scanner.column },
            ),
            .interface_not_protocol_child => logFn(
                "{s}:{d}:{d}: <interface> tag must appear as child of <protocol>",
                .{ file_path, scanner.line, scanner.column },
            ),
            .interface_child_not => logFn(
                "{s}:{d}:{d}: <{s}> tag must appear as child of <interface>",
                .{ file_path, scanner.line, scanner.column, scanner.tag_name_buffer.items },
            ),
            .invalid_arg_parent => logFn(
                "{s}:{d}:{d}: <arg> tag must appear as child of <request> or <event>",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_entry_parent => logFn(
                "{s}:{d}:{d}: <entry> tag must appear as child of <enum>",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_description_parent => logFn(
                "{s}:{d}:{d}: unsupported parent of <description> tag",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_copyright_parent => logFn(
                "{s}:{d}:{d}: unsupported parent of <copyright> tag",
                .{ file_path, scanner.line, scanner.column },
            ),
            .invalid_entry_value => logFn(
                "{s}:{d}:{d}: <entry/> value is not a valid integer",
                .{ file_path, scanner.line, scanner.column },
            ),
            .missing_attribute_at_final => logFn(
                "{s}: uncaught missing attributes after parsing",
                .{ file_path },
            ),
        }
    } else {
        logFn(
            "{s}:{d}:{d}: unspecified error (seeing this is a bug)",
            .{ file_path, scanner.line, scanner.column },
        );
    }
}

pub const Tag = enum {
    copyright,
    protocol,
    interface,
    description,
    request,
    event,
    @"enum",
    entry,
    arg,

    pub fn fromString(str: []const u8) ?Tag {
        return name_map.get(str);
    }

    const name_map: std.StaticStringMap(Tag) = .initComptime( make: {
        const tags = std.enums.values(Tag);
        var list: [tags.len]struct { []const u8, Tag } = undefined;
        for (&list, tags) |*kvs, tag| kvs.* = .{ @tagName(tag), tag };
        break :make list;
    } );
};

tag_stack: TagStack,
tag_name_buffer: ByteArrayList,
attribute_name_buffer: ByteArrayList,
attribute_value_buffer: ByteArrayList,
text_literal_buffer: ByteArrayList,
attribute_names: StringList,
attribute_values: StringList,
last_opening_was_literal_text_tag: bool,
last_byte: ?u8,
last_last_byte: ?u8,
first_tag: bool,
line: u32,
column: u32,
reading_declaration: bool,
xml_declaration: ?XMLDeclaration,
source_invalid_err: ?SourceInvalidError,

pub fn init(allocator: Allocator) Allocator.Error!Scanner {
    return .{
        .tag_stack = try .initCapacity(allocator, 16),
        .tag_name_buffer = try .initCapacity(allocator, 64),
        .attribute_name_buffer = try .initCapacity(allocator, 64),
        .attribute_value_buffer = try .initCapacity(allocator, 128),
        .text_literal_buffer = try .initCapacity(allocator, 512),
        .attribute_names = try .create(allocator),
        .attribute_values = try .create(allocator),
        .last_opening_was_literal_text_tag = undefined,
        .last_byte = undefined,
        .last_last_byte = undefined,
        .line = undefined,
        .column = undefined,
        .first_tag = undefined,
        .reading_declaration = undefined,
        .xml_declaration = undefined,
        .source_invalid_err = null,
    };
}

pub fn deinit(scanner: *Scanner, allocator: Allocator) void {
    scanner.attribute_values.deinit(allocator);
    scanner.attribute_names.deinit(allocator);
    scanner.text_literal_buffer.deinit(allocator);
    scanner.attribute_value_buffer.deinit(allocator);
    scanner.attribute_name_buffer.deinit(allocator);
    scanner.tag_name_buffer.deinit(allocator);
    scanner.tag_stack.deinit(allocator);
    scanner.* = undefined;
}

pub fn newStream(scanner: *Scanner) void {
    assert(scanner.tag_stack.items.len == 0);
    assert(scanner.tag_name_buffer.items.len == 0);
    assert(scanner.attribute_name_buffer.items.len == 0);
    assert(scanner.attribute_value_buffer.items.len == 0);
    assert(scanner.text_literal_buffer.items.len == 0);
    scanner.last_opening_was_literal_text_tag = false;
    scanner.last_byte = null;
    scanner.last_last_byte = null;
    scanner.first_tag = false;
    scanner.line = 0;
    scanner.column = 0;
    scanner.reading_declaration = false;
    scanner.xml_declaration = null;
}

pub const XMLDeclaration = struct {
    version_major: u8,
    version_minor: u8,
    encoding: ?Encoding,
    standalone: ?bool,

    /// Encodings supported by this parser
    pub const Encoding = enum { @"UTF-8" };

    /// The name expected of a '<? ... ?>' tag
    pub const tag_name = "xml";
};

pub const ParseError = error{
    ReadFailed,
    InvalidWaylandXML,
    UnsupportedEncoding,
    StreamIncomplete,
} || Allocator.Error;

const State = enum {
    /// Plain text outside of any tags
    plaintext,
    tag_name,
    attribute_name,
    attribute_sep,
    attribute_value,
    end_tag,
    /// Literal text content (i.e. within a '<description> ...')
    text,
    comment,
};

/// Parses `reader` to EOF,
/// allocating a slice of nested protocol objects for the caller to free.
pub fn parse(scanner: *Scanner, allocator: Allocator, reader: *Io.Reader) ParseError![]Protocol {
    scanner.newStream();

    var protocols: std.ArrayList(Protocol.Parsing) = try .initCapacity(allocator, 1);
    errdefer {
        for (protocols.items) |*protocol| protocol.deinit(allocator);
        protocols.deinit(allocator);
    }

    parse: switch (State.plaintext) {
        .plaintext => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }

                // Check for byte order mark
                if (scanner.line == 0) {
                    if (scanner.column == 2) {
                        if (char == 0xFE and scanner.last_byte == 0xFF) {
                            std.log.err("encountered BOM \'FF FE\' (UTF-16 Little Endian)", .{});
                            return error.UnsupportedEncoding;
                        } else if (char == 0xFF and scanner.last_byte == 0xFE) {
                            std.log.err("encountered BOM \'FE FF\' (UTF-16 Big Endian)", .{});
                            return error.UnsupportedEncoding;
                        }
                    } else if (scanner.column == 3) {
                        if (char == 0xBF and scanner.last_byte == 0xBB and scanner.last_last_byte == 0xEF) {
                            // UTF-8 BOM
                            // We already assume this and fail otherwise
                        }
                    }
                }
                // Now we can assume UTF-8 encoding unless another is declared in <?xml>

                if (char == '<') {
                    assert(scanner.tag_name_buffer.items.len == 0);
                    continue :parse .tag_name;
                } else {
                    continue :parse .plaintext;
                }
            } else {
                if (
                    scanner.tag_stack.items.len == 0 and
                    scanner.tag_name_buffer.items.len == 0 and
                    scanner.attribute_name_buffer.items.len == 0 and
                    scanner.attribute_value_buffer.items.len == 0 and
                    scanner.text_literal_buffer.items.len == 0 and
                    scanner.attribute_names.strings.items.len == 0 and
                    scanner.attribute_values.strings.items.len == 0
                ) {
                    const protocols_slice = try allocator.alloc(Protocol, protocols.items.len);
                    errdefer allocator.free(protocols_slice);
                    for (protocols_slice, protocols.items) |*new, *old| {
                        new.* = old.finalize(allocator) catch |err| switch (err) {
                            error.OutOfMemory => |e| return e,
                            error.MissingAttribute => return attr: {
                                scanner.source_invalid_err = .missing_attribute_at_final;
                                break :attr error.InvalidWaylandXML;
                            },
                        };
                    }
                    protocols.deinit(allocator);
                    return protocols_slice;
                } else {
                    return error.StreamIncomplete;
                }
            }
        },

        .tag_name => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }

                if (scanner.last_byte == '/' and char != '>') {
                    scanner.source_invalid_err = .invalid_forward_slash;
                    return error.InvalidWaylandXML;
                }

                if (scanner.last_byte == '?' and char != '>' and !scanner.reading_declaration) {
                    scanner.source_invalid_err = .invalid_declaration_question_mark;
                    return error.InvalidWaylandXML;
                }

                defer scanner.first_tag = true;

                switch (char) {
                    '<' => {
                        scanner.source_invalid_err = .double_open_bracket;
                        return error.InvalidWaylandXML;
                    },

                    '/' => {
                        if (scanner.last_byte == '<') {
                            assert(scanner.tag_name_buffer.items.len == 0);
                            continue :parse .end_tag;
                        } else {
                            continue :parse .tag_name;
                        }
                    },

                    '>' => {
                        if (scanner.tag_name_buffer.items.len == 0) {
                            scanner.source_invalid_err = .empty_tag_name;
                            return error.InvalidWaylandXML;
                        }

                        if (scanner.last_byte == '/') {
                            try scanner.pushEmptyElement(allocator, &protocols);
                            continue :parse .plaintext;
                        } else if (scanner.last_byte == '?') {
                            try scanner.pushDeclaration();
                            continue :parse .plaintext;
                        } else {
                            try scanner.pushStartElement(allocator, &protocols);
                            if (scanner.last_opening_was_literal_text_tag) {
                                assert(scanner.text_literal_buffer.items.len == 0);
                                continue :parse .text;
                            } else {
                                continue :parse .plaintext;
                            }
                        }
                    },

                    '?' => {
                        if (
                            scanner.last_byte == '<' and
                            scanner.xml_declaration == null and
                            !scanner.first_tag
                        ) {
                            scanner.reading_declaration = true;
                            continue :parse .tag_name;
                        } else if (
                            scanner.xml_declaration == null and
                            scanner.reading_declaration
                        ) {
                            scanner.reading_declaration = false;
                            continue :parse .tag_name;
                        } else {
                            scanner.source_invalid_err = .invalid_attribute_name_char;
                            return error.InvalidWaylandXML;
                        }
                    },

                    '!' => {
                        // Because '<' within tag_name is a parse error
                        if (scanner.last_byte == '<') {
                            continue :parse .tag_name;
                        } else {
                            scanner.source_invalid_err = .invalid_attribute_name_char;
                            return error.InvalidWaylandXML;
                        }
                    },

                    '-' => switch (scanner.last_byte.?) {
                        '!' => {
                            if (scanner.last_last_byte == '<') {
                                continue :parse .tag_name;
                            } else {
                                scanner.source_invalid_err = .invalid_attribute_name_char;
                                return error.InvalidWaylandXML;
                            }
                        },

                        '-' => {
                            if (scanner.last_last_byte == '!') {
                                continue :parse .comment;
                            } else {
                                scanner.source_invalid_err = .invalid_attribute_name_char;
                                return error.InvalidWaylandXML;
                            }
                        },

                        else => {
                            scanner.source_invalid_err = .invalid_attribute_name_char;
                            return error.InvalidWaylandXML;
                        },
                    },

                    else => |c| {
                        try scanner.tag_name_buffer.append(allocator, c);
                        continue :parse .tag_name;
                    },

                    ' ', '\t', '\n', '\r',
                    std.ascii.control_code.vt,
                    std.ascii.control_code.ff => {
                        if (scanner.tag_name_buffer.items.len == 0) {
                            continue :parse .tag_name;
                        } else {
                            try scanner.preValidateTagName(scanner.tag_name_buffer.items);
                            assert(scanner.attribute_name_buffer.items.len == 0);
                            continue :parse .attribute_name;
                        }
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .end_tag => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }
                switch (char) {
                    ' ', '\t', '\n', '\r',
                    std.ascii.control_code.vt,
                    std.ascii.control_code.ff => continue :parse .end_tag,

                    else => |c| {
                        try scanner.tag_name_buffer.append(allocator, c);
                        continue :parse .end_tag;
                    },

                    '>' => {
                        if (scanner.tag_name_buffer.items.len == 0) {
                            scanner.source_invalid_err = .empty_tag_name;
                            return error.InvalidWaylandXML;
                        } else {
                            try scanner.pushEndElement(allocator, &protocols);
                            continue :parse .plaintext;
                        }
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .attribute_name => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }
                switch (char) {
                    '<' => {
                        scanner.source_invalid_err = .double_open_bracket;
                        return error.InvalidWaylandXML;
                    },

                    '/' => {
                        if (scanner.attribute_name_buffer.items.len == 0) {
                            continue :parse .tag_name;
                        } else {
                            scanner.source_invalid_err = .invalid_attribute_name_char;
                            return error.InvalidWaylandXML;
                        }
                    },

                    '>' => {
                        if (scanner.attribute_name_buffer.items.len != 0) {
                            scanner.source_invalid_err = .unvalued_attribute;
                            return error.InvalidWaylandXML;
                        }

                        if (scanner.tag_name_buffer.items.len == 0) {
                            scanner.source_invalid_err = .empty_tag_name;
                            return error.InvalidWaylandXML;
                        }

                        if (scanner.last_byte == '/') {
                            try scanner.pushEmptyElement(allocator, &protocols);
                            continue :parse .plaintext;
                        } else {
                            try scanner.pushStartElement(allocator, &protocols);
                            if (scanner.last_opening_was_literal_text_tag) {
                                assert(scanner.text_literal_buffer.items.len == 0);
                                continue :parse .text;
                            } else {
                                continue :parse .plaintext;
                            }
                        }
                    },

                    '?' => {
                        if (
                            scanner.xml_declaration == null and
                            scanner.reading_declaration
                        ) {
                            scanner.reading_declaration = false;
                            continue :parse .tag_name;
                        } else {
                            scanner.source_invalid_err = .invalid_attribute_name_char;
                            return error.InvalidWaylandXML;
                        }
                    },

                    ' ', '\t', '\n', '\r',
                    std.ascii.control_code.vt,
                    std.ascii.control_code.ff => continue :parse .attribute_name,

                    else => |c| {
                        try scanner.attribute_name_buffer.append(allocator, c);
                        continue :parse .attribute_name;
                    },

                    '=' => {
                        if (scanner.attribute_name_buffer.items.len == 0) {
                            scanner.source_invalid_err = .equals_before_attribute_name;
                            return error.InvalidWaylandXML;
                        } else {
                            try scanner.pushAttribute(allocator);
                            continue :parse .attribute_sep;
                        }
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .attribute_sep => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }
                switch (char) {
                    ' ', '\t', '\n', '\r',
                    std.ascii.control_code.vt,
                    std.ascii.control_code.ff => continue :parse .attribute_sep,
                    '"' => {
                        assert(scanner.attribute_value_buffer.items.len == 0);
                        continue :parse .attribute_value;
                    },
                    else => {
                        scanner.source_invalid_err = .invalid_before_attribute_value;
                        return error.InvalidWaylandXML;
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .attribute_value => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }
                switch (char) {
                    else => |c| {
                        try scanner.attribute_value_buffer.append(allocator, c);
                        continue :parse .attribute_value;
                    },

                    '"' => {
                        try scanner.pushAttributeValue(allocator);
                        continue :parse .attribute_name;
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .text => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }
                switch (char) {
                    else => |c| {
                        try scanner.text_literal_buffer.append(allocator, c);
                        continue :parse .text;
                    },

                    '<' => {
                        continue :parse .tag_name;
                    },
                }
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },

        .comment => {
            if (try scanner.nextByte(reader)) |char| {
                defer {
                    scanner.last_last_byte = scanner.last_byte;
                    scanner.last_byte = char;
                }

                // TODO this makes something like '<!-->' a valid comment (is it?)
                continue :parse if (
                    char == '>' and
                    scanner.last_byte == '-' and
                    scanner.last_last_byte == '-'
                ) .plaintext else .comment;
            } else {
                scanner.source_invalid_err = .broken_tag;
                return error.InvalidWaylandXML;
            }
        },
    }

    comptime unreachable;
}

fn nextByte(scanner: *Scanner, reader: *Io.Reader) !?u8 {
    const byte = reader.takeByte() catch |err| return switch (err) {
        error.EndOfStream => null,
        error.ReadFailed => |e| e,
    };

    if ( if (scanner.last_byte) |last| isNewline(byte, last) else false ) {
        scanner.column = 0;
        scanner.line += 1;
    } else {
        scanner.column += 1;
    }

    return byte;
}

/// An empty element tag ('<TAGNAME/>').
fn pushEmptyElement(
    scanner: *Scanner,
    allocator: Allocator,
    protocols: *std.ArrayList(Protocol.Parsing),
) !void {
    const tag: Tag = Tag.fromString(scanner.tag_name_buffer.items) orelse return no_tag: {
        scanner.source_invalid_err = .unsupported_tag;
        break :no_tag error.InvalidWaylandXML;
    };
    assert(scanner.attribute_names.strings.items.len == scanner.attribute_values.strings.items.len);
    const attribute_count = scanner.attribute_names.strings.items.len;

    const top: ?Tag = scanner.tag_stack.getLastOrNull();
    try scanner.validateTagPosition(top, tag);

    switch (tag) {
        .entry => {
            var name: ?[]const u8 = null;
            var value: ?[]const u8 = null;
            var summary: ?[]const u8 = null;
            errdefer {
                if (name) |n| allocator.free(n);
                if (value) |v| allocator.free(v);
                if (summary) |s| allocator.free(s);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name" , attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "value", attr_name) ) {
                    if (value == null) {
                        value = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "summary", attr_name) ) {
                    if (summary == null) {
                        summary = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null or value == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            if (!Entry.isValidValue(value.?)) {
                scanner.source_invalid_err = .invalid_entry_value;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == .@"enum");
            {
                const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                const last: *Enum.Parsing = &last_interface.objects.items[last_interface.objects.items.len-1].@"enum";
                try last.entries.append(allocator, .{
                    .name = name.?,
                    .value = value.?,
                    .summary = summary,
                });
            }
        },

        .arg => {
            var name: ?[]const u8 = null;
            var @"type": ?Arg.Type = null;
            var interface: ?[]const u8 = null;
            var allow_null: ?bool = null;
            var summary: ?[]const u8 = null;
            errdefer {
                if (name) |n| allocator.free(n);
                if (interface) |i| allocator.free(i);
                if (summary) |s| allocator.free(s);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "type", attr_name) ) {
                    if (@"type" == null) {
                        if (Arg.Type.fromString(attr_value)) |t| {
                            @"type" = t;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "interface", attr_name) ) {
                    if (interface == null) {
                        interface = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "allow-null", attr_name) ) {
                    if (allow_null == null) {
                        if (mem.eql(u8, "true", attr_value)) {
                            allow_null = true;
                        } else if (mem.eql(u8, "false", attr_value)) {
                            allow_null = false;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "summary", attr_name) ) {
                    if (summary == null) {
                        summary = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null or @"type" == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            switch (top.?) {
                inline .request, .event => |parent| {
                    const Parsing: type = switch (parent) {
                        .request => Request.Parsing,
                        .event => Event.Parsing,
                        else => unreachable,
                    };
                    const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                    const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                    const last: *Parsing = &@field(
                        last_interface.objects.items[last_interface.objects.items.len-1],
                        @tagName(parent),
                    );
                    try last.args.append(allocator, .{
                        .name = name.?,
                        .@"type" = @"type".?,
                        .interface = interface,
                        .allow_null = allow_null,
                        .summary = summary,
                    });
                },
                else => unreachable,
            }
        },

        // <entry/> and <arg/> are the only realistically expected self-closing tags

        .copyright => {
            @branchHint(.unlikely);
            // Self-closing copyright tag has no meaning, and no valid attributes
            if (attribute_count != 0) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }
        },

        .protocol => {
            @branchHint(.unlikely);
            // Doesn't make sense, but still support it
            var name: ?[]const u8 = null;
            errdefer { if (name) |n| allocator.free(n); }
            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;
                if ( mem.eql(u8, "name", attr_name) and name == null ) {
                    name = try allocator.dupe(u8, attr_value);
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }
            if (name == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }
            // Tag hierarchy was validated above
            assert(top == null);
            var parsing: Protocol.Parsing = try .init(allocator);
            parsing.name = name;
            try protocols.append(allocator, parsing);
        },

        .interface => {
            @branchHint(.unlikely);
            // Doesn't make sense, but still support it
            var name: ?[]const u8 = null;
            var version: ?VersionNumber = null;
            errdefer { if (name) |n| allocator.free(n); }
            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;
                if (mem.eql(u8, "name", attr_name)) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if (mem.eql(u8, "version", attr_name)) {
                    if (version == null) {
                        if (fmt.parseUnsigned(VersionNumber, attr_value, 10)) |number| {
                            version = number;
                        } else |err| {
                            if (err == error.Overflow) std.log.err(
                                "version string \'{s}\' overflows the version number type"
                                    ++ @typeName(VersionNumber),
                                .{ attr_value },
                            );
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }
            if (name == null or version == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }
            // Tag hierarchy was validated above
            assert(top == .protocol);
            var parsing: Interface.Parsing = try .init(allocator);
            parsing.name = name;
            parsing.version = version;
            try protocols.items[protocols.items.len-1].interfaces.append(allocator, parsing);
        },

        .description => {
            @branchHint(.unlikely);
            // Self-closing description could contain the summary attribute
            var summary: ?[]const u8 = null;
            errdefer { if (summary) |s| allocator.free(s); }
            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;
                if (mem.eql(u8, "summary", attr_name) and summary == null) {
                    summary = try allocator.dupe(u8, attr_value);
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }
            if (summary) |description_short| {
                // Tag hierarchy was validated above
                switch (top.?) {
                    .interface => {
                        const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                        const last: *Interface.Parsing = &interfaces[interfaces.len-1];
                        if (last.description_short == null) {
                            last.description_short = description_short;
                        } else {
                            scanner.source_invalid_err = .clobber;
                            return error.InvalidWaylandXML;
                        }
                    },

                    inline .request, .event, .@"enum" => |child_obj| {
                        const Parsing: type = switch (child_obj) {
                            .request => Request.Parsing,
                            .event => Event.Parsing,
                            .@"enum" => Enum.Parsing,
                            else => comptime unreachable,
                        };
                        const child_tag: Interface.ChildTag = switch (child_obj) {
                            .request => .request,
                            .event => .event,
                            .@"enum" => .@"enum",
                            else => comptime unreachable,
                        };

                        const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                        const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                        // Asserts that the last object is of the type indicated by the tag stack
                        const last: *Parsing = &@field(
                            last_interface.objects.items[last_interface.objects.items.len-1],
                            @tagName(child_tag),
                        );
                        if (last.description_short == null) {
                            last.description_short = description_short;
                        } else {
                            scanner.source_invalid_err = .clobber;
                            return error.InvalidWaylandXML;
                        }
                    },

                    .protocol, .arg, .entry, .copyright, .description => {
                        scanner.source_invalid_err = .invalid_description_parent;
                        return error.InvalidWaylandXML;
                    },
                }
            }
        },

        .request, .event, .@"enum" => |interface_object_tag| {
            @branchHint(.unlikely);
            var name: ?[]const u8 = null;
            var since: ?VersionNumber = null;
            var bitfield: ?bool = null;
            errdefer {
                if (name) |n| allocator.free(n);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "since", attr_name) ) {
                    if (since == null) {
                        if (fmt.parseUnsigned(VersionNumber, attr_value, 10)) |number| {
                            since = number;
                        } else |err| {
                            if (err == error.Overflow) std.log.err(
                                "\'since\' string \'{s}\' overflows the version number type"
                                    ++ @typeName(VersionNumber),
                                .{ attr_value },
                            );
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "bitfield", attr_name) ) {
                    if (interface_object_tag == .@"enum" and bitfield == null) {
                        if ( mem.eql(u8, "true", attr_value) ) {
                            bitfield = true;
                        } else if ( mem.eql(u8, "false", attr_value) ) {
                            bitfield = false;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == .interface);

            const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
            const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
            switch (interface_object_tag) {
                inline else => |object_tag| {
                    const interface_child: Interface.ChildTag = switch (object_tag) {
                        .request => .request,
                        .event => .event,
                        .@"enum" => .@"enum",
                        else => unreachable,
                    };
                    const parsing = switch (comptime object_tag) {
                        .request => Request.Parsing{
                            .name = name,
                            .since = since,
                            .description_short = null,
                            .description_long = null,
                            .args = .empty,
                        },
                        .event => Event.Parsing{
                            .name = name,
                            .since = since,
                            .description_short = null,
                            .description_long = null,
                            .args = .empty,
                        },
                        .@"enum" => Enum.Parsing{
                            .name = name,
                            .since = since,
                            .description_short = null,
                            .description_long = null,
                            .bitfield = bitfield,
                            .entries = .empty,
                        },
                        else => unreachable,
                    };
                    try last_interface.objects.append(allocator, @unionInit(
                        Interface.Object.Parsing,
                        @tagName(interface_child),
                        parsing,
                    ));
                }
            }
        },
    }

    scanner.tag_name_buffer.clearRetainingCapacity();
    scanner.attribute_names.clear();
    scanner.attribute_values.clear();
}

/// A beginning element tag ('<TAGNAME>')
fn pushStartElement(
    scanner: *Scanner,
    allocator: Allocator,
    protocols: *std.ArrayList(Protocol.Parsing),
) !void {
    const tag: Tag = Tag.fromString(scanner.tag_name_buffer.items) orelse return no_tag: {
        scanner.source_invalid_err = .unsupported_tag;
        break :no_tag error.InvalidWaylandXML;
    };
    assert(scanner.attribute_names.strings.items.len == scanner.attribute_values.strings.items.len);
    const attribute_count = scanner.attribute_names.strings.items.len;

    scanner.last_opening_was_literal_text_tag = switch (tag) {
        .description, .copyright => true,
        else => false,
    };

    const top: ?Tag = scanner.tag_stack.getLastOrNull();
    try scanner.validateTagPosition(top, tag);

    switch (tag) {
        .description => {
            var summary: ?[]const u8 = null;
            errdefer { if (summary) |s| allocator.free(s); }
            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;
                if (mem.eql(u8, "summary", attr_name) and summary == null) {
                    summary = try allocator.dupe(u8, attr_value);
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (summary) |description_short| {
                // Tag hierarchy was validated above
                switch (top.?) {
                    .interface => {
                        const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                        const last: *Interface.Parsing = &interfaces[interfaces.len-1];
                        if (last.description_short == null) {
                            last.description_short = description_short;
                        } else {
                            scanner.source_invalid_err = .clobber;
                            return error.InvalidWaylandXML;
                        }
                    },

                    inline .request, .event, .@"enum" => |child_obj| {
                        const Parsing: type = switch (child_obj) {
                            .request => Request.Parsing,
                            .event => Event.Parsing,
                            .@"enum" => Enum.Parsing,
                            else => comptime unreachable,
                        };
                        const child_tag: Interface.ChildTag = switch (child_obj) {
                            .request => .request,
                            .event => .event,
                            .@"enum" => .@"enum",
                            else => comptime unreachable,
                        };

                        const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                        const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                        // Asserts that the last object is of the type indicated by the tag stack
                        const last: *Parsing = &@field(
                            last_interface.objects.items[last_interface.objects.items.len-1],
                            @tagName(child_tag),
                        );

                        if (last.description_short == null) {
                            last.description_short = description_short;
                        } else {
                            scanner.source_invalid_err = .clobber;
                            return error.InvalidWaylandXML;
                        }
                    },

                    else => unreachable,
                }
            }
        },

        .copyright => {
            // Tag hierarchy was validated above to be a <protocol> parent
            if (attribute_count != 0) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }
            if (protocols.items[protocols.items.len-1].copyright != null) {
                scanner.source_invalid_err = .clobber;
                return error.InvalidWaylandXML;
            }
            // The text content will be inserted at the closing '</copyright>'
        },

        .protocol => {
            var name: ?[]const u8 = null;
            errdefer {
                if (name) |n| allocator.free(n);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) and name == null ) {
                    name = try allocator.dupe(u8, attr_value);
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == null);
            var parsing: Protocol.Parsing = try .init(allocator);
            parsing.name = name;
            try protocols.append(allocator, parsing);
        },

        .interface => {
            var name: ?[]const u8 = null;
            var version: ?VersionNumber = null;
            errdefer {
                if (name) |n| allocator.free(n);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "version", attr_name) ) {
                    if (version == null) {
                        if (fmt.parseUnsigned(VersionNumber, attr_value, 10)) |number| {
                            version = number;
                        } else |err| {
                            if (err == error.Overflow) std.log.err(
                                "version string \'{s}\' overflows the version number type"
                                    ++ @typeName(VersionNumber),
                                .{ attr_value },
                            );
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null or version == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == .protocol);
            var parsing: Interface.Parsing = try .init(allocator);
            parsing.name = name;
            parsing.version = version;
            try protocols.items[protocols.items.len-1].interfaces.append(allocator, parsing);
        },

        .request, .event, .@"enum" => |interface_object_tag| {
            var name: ?[]const u8 = null;
            var since: ?VersionNumber = null;
            var bitfield: ?bool = null;
            errdefer {
                if (name) |n| allocator.free(n);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "since", attr_name) ) {
                    if (since == null) {
                        if (fmt.parseUnsigned(VersionNumber, attr_value, 10)) |number| {
                            since = number;
                        } else |err| {
                            if (err == error.Overflow) std.log.err(
                                "\'since\' string \'{s}\' overflows the version number type"
                                    ++ @typeName(VersionNumber),
                                .{ attr_value },
                            );
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "bitfield", attr_name) ) {
                    if (interface_object_tag == .@"enum" and bitfield == null) {
                        if ( mem.eql(u8, "true", attr_value) ) {
                            bitfield = true;
                        } else if ( mem.eql(u8, "false", attr_value) ) {
                            bitfield = false;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == .interface);

            const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
            const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
            switch (interface_object_tag) {
                inline else => |object_tag| {
                    const interface_child: Interface.ChildTag = switch (object_tag) {
                        .request => .request,
                        .event => .event,
                        .@"enum" => .@"enum",
                        else => unreachable,
                    };
                    var parsing: switch (object_tag) {
                        .request => Request.Parsing,
                        .event => Event.Parsing,
                        .@"enum" => Enum.Parsing,
                        else => unreachable,
                    } = try .init(allocator);
                    parsing.name = name;
                    parsing.since = since;
                    if (comptime object_tag == .@"enum") parsing.bitfield = bitfield;
                    try last_interface.objects.append(allocator, @unionInit(
                        Interface.Object.Parsing,
                        @tagName(interface_child),
                        parsing,
                    ));
                }
            }
        },

        // <entry></entry> or <arg></arg> are nonstandard but technically valid.
        // To reject these, uncomment this prong
        // and comment out the below prongs for .entry and .arg
        //.entry, .arg => {
        //    scanner.source_invalid_err = .invalid_non_self_closing;
        //    return error.InvalidWaylandXML;
        //}

        .entry => {
            @branchHint(.unlikely);
            var name: ?[]const u8 = null;
            var value: ?[]const u8 = null;
            var summary: ?[]const u8 = null;
            errdefer {
                if (name) |n| allocator.free(n);
                if (value) |v| allocator.free(v);
                if (summary) |s| allocator.free(s);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_names.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "value", attr_name) ) {
                    if (value == null) {
                        value = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "summary", attr_name) ) {
                    if (summary == null) {
                        summary = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null or value == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            if (!Entry.isValidValue(value.?)) {
                scanner.source_invalid_err = .invalid_entry_value;
                return error.InvalidWaylandXML;
            }

            // Tag hierarchy was validated above
            assert(top == .@"enum");
            {
                const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                const last: *Enum.Parsing = &last_interface.objects.items[last_interface.objects.items.len-1].@"enum";
                try last.entries.append(allocator, .{
                    .name = name.?,
                    .value = value.?,
                    .summary = summary,
                });
            }
        },

        .arg => {
            @branchHint(.unlikely);
            var name: ?[]const u8 = null;
            var @"type": ?Arg.Type = null;
            var interface: ?[]const u8 = null;
            var allow_null: ?bool = null;
            var summary: ?[]const u8 = null;
            errdefer {
                if (name) |n| allocator.free(n);
                if (interface) |i| allocator.free(i);
                if (summary) |s| allocator.free(s);
            }

            for (0..attribute_count) |attribute_index| {
                const attr_name = scanner.attribute_names.at(attribute_index).?;
                const attr_value = scanner.attribute_values.at(attribute_index).?;

                if ( mem.eql(u8, "name", attr_name) ) {
                    if (name == null) {
                        name = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "type", attr_name) ) {
                    if (@"type" == null) {
                        if (Arg.Type.fromString(attr_value)) |t| {
                            @"type" = t;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "interface", attr_name) ) {
                    if (interface == null) {
                        interface = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "allow-null", attr_name) ) {
                    if (allow_null == null) {
                        if (mem.eql(u8, "true", attr_value)) {
                            allow_null = true;
                        } else if (mem.eql(u8, "false", attr_value)) {
                            allow_null = false;
                        } else {
                            scanner.source_invalid_err = .invalid_attributes;
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else if ( mem.eql(u8, "summary", attr_name) ) {
                    if (summary == null) {
                        summary = try allocator.dupe(u8, attr_value);
                    } else {
                        scanner.source_invalid_err = .invalid_attributes;
                        return error.InvalidWaylandXML;
                    }
                } else {
                    scanner.source_invalid_err = .invalid_attributes;
                    return error.InvalidWaylandXML;
                }
            }

            if (name == null or @"type" == null) {
                scanner.source_invalid_err = .invalid_attributes;
                return error.InvalidWaylandXML;
            }

            switch (top.?) {
                inline .request, .event => |parent| {
                    const Parsing: type = switch (parent) {
                        .request => Request.Parsing,
                        .event => Event.Parsing,
                        else => unreachable,
                    };
                    const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                    const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                    const last: *Parsing = &@field(
                        last_interface.objects.items[last_interface.objects.items.len-1],
                        @tagName(parent),
                    );
                    try last.args.append(allocator, .{
                        .name = name.?,
                        .@"type" = @"type".?,
                        .interface = interface,
                        .allow_null = allow_null,
                        .summary = summary,
                    });
                },
                else => unreachable,
            }
        },
    }

    try scanner.tag_stack.append(allocator, tag);

    scanner.tag_name_buffer.clearRetainingCapacity();
    scanner.attribute_names.clear();
    scanner.attribute_values.clear();
}

/// An ending element tag ('</TAGNAME>')
fn pushEndElement(
    scanner: *Scanner,
    allocator: Allocator,
    protocols: *std.ArrayList(Protocol.Parsing),
) !void {
    const tag: Tag = Tag.fromString(scanner.tag_name_buffer.items) orelse return no_tag: {
        scanner.source_invalid_err = .unsupported_tag;
        break :no_tag error.InvalidWaylandXML;
    };

    if (scanner.tag_stack.pop() != tag) {
        scanner.source_invalid_err = .mismatched_tag_close;
        return error.InvalidWaylandXML;
    }

    const top: ?Tag = scanner.tag_stack.getLastOrNull();

    switch (tag) {
        .description => {
            if (top == null) {
                scanner.source_invalid_err = .invalid_description_parent;
                return error.InvalidWaylandXML;
            }

            const description_dest: *?[]const u8 = switch (top.?) {
                .interface => try interface_dest: {
                    const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                    const last: *Interface.Parsing = &interfaces[interfaces.len-1];

                    if (last.description_long == null) {
                        break :interface_dest &last.description_long;
                    } else {
                        scanner.source_invalid_err = .clobber;
                        break :interface_dest error.InvalidWaylandXML;
                    }
                },

                inline .request, .event, .@"enum" => |child_obj| try interface_child_dest: {
                    const Parsing: type = switch (child_obj) {
                        .request => Request.Parsing,
                        .event => Event.Parsing,
                        .@"enum" => Enum.Parsing,
                        else => unreachable,
                    };
                    const child_tag: Interface.ChildTag = switch (child_obj) {
                        .request => .request,
                        .event => .event,
                        .@"enum" => .@"enum",
                        else => unreachable,
                    };

                    const interfaces: []Interface.Parsing = protocols.items[protocols.items.len-1].interfaces.items;
                    const last_interface: *Interface.Parsing = &interfaces[interfaces.len-1];
                    // Asserts that the last object is of the type indicated by the tag stack
                    const last: *Parsing = &@field(
                        last_interface.objects.items[last_interface.objects.items.len-1],
                        @tagName(child_tag),
                    );

                    if (last.description_long == null) {
                        break :interface_child_dest &last.description_long;
                    } else {
                        scanner.source_invalid_err = .clobber;
                        break :interface_child_dest error.InvalidWaylandXML;
                    }
                },

                else => {
                    scanner.source_invalid_err = .invalid_description_parent;
                    return error.InvalidWaylandXML;
                },
            };

            const description: []const u8 = try trimLiteralText(allocator, scanner.text_literal_buffer.items);
            errdefer { if (description.len != 0) allocator.free(description); }
            if (description.len != 0) description_dest.* = description;
        },

        .copyright => {
            if (top != .protocol) {
                scanner.source_invalid_err = .invalid_copyright_parent;
                return error.InvalidWaylandXML;
            }

            const protocol: *Protocol.Parsing = &protocols.items[protocols.items.len-1];
            if (protocol.copyright != null) {
                scanner.source_invalid_err = .clobber;
                return error.InvalidWaylandXML;
            }

            const copyright: []const u8 = try trimLiteralText(allocator, scanner.text_literal_buffer.items);
            errdefer { if (copyright.len != 0) allocator.free(copyright); }
            if (copyright.len != 0) protocol.copyright = copyright;
        },

        // Parsing is structured to never collect literal text in these cases
        else => assert(scanner.text_literal_buffer.items.len == 0),
    }

    scanner.text_literal_buffer.clearRetainingCapacity();
    scanner.tag_name_buffer.clearRetainingCapacity();
    assert(scanner.attribute_names.strings.items.len == 0);
    assert(scanner.attribute_values.strings.items.len == 0);
}

/// A tag attribute (ATTRIBUTE of '<TAGNAME ATTRIBUTE="VALUE"'(/)>)
fn pushAttribute(scanner: *Scanner, allocator: Allocator) !void {
    assert(scanner.attribute_names.strings.items.len == scanner.attribute_values.strings.items.len);
    try scanner.attribute_names.add(allocator, scanner.attribute_name_buffer.items);
    scanner.attribute_name_buffer.clearRetainingCapacity();
}

/// A tag attribute value (VALUE of '<TAGNAME ATTRIBUTE="VALUE"'(/)>)
fn pushAttributeValue(scanner: *Scanner, allocator: Allocator) !void {
    assert(scanner.attribute_names.strings.items.len == scanner.attribute_values.strings.items.len + 1);
    try scanner.attribute_values.add(allocator, scanner.attribute_value_buffer.items);
    scanner.attribute_value_buffer.clearRetainingCapacity();
}

fn pushDeclaration(scanner: *Scanner) !void {
    if (scanner.xml_declaration == null) {
        if (mem.eql(u8, XMLDeclaration.tag_name, scanner.tag_name_buffer.items)) {
            assert(scanner.attribute_names.strings.items.len == scanner.attribute_values.strings.items.len);
            const attribute_count = scanner.attribute_names.strings.items.len;

            errdefer { scanner.source_invalid_err = .invalid_declaration_attributes; }

            var version: ?[2]u8 = null;
            var encoding: ?XMLDeclaration.Encoding = null;
            var standalone: ?bool = null;

            if (attribute_count >= 1 and mem.eql(u8,
                "version",
                scanner.attribute_names.at(0).?,
            )) {
                const major_string, const minor_string = mem.cutScalar(u8,
                    scanner.attribute_values.at(0).?,
                    '.',
                ) orelse return error.InvalidWaylandXML;
                const major: u8 = fmt.parseUnsigned(u8, major_string, 10)
                    catch return error.InvalidWaylandXML;
                const minor: u8 = fmt.parseUnsigned(u8, minor_string, 10)
                    catch return error.InvalidWaylandXML;
                version = .{ major, minor };
            } else {
                return error.InvalidWaylandXML;
            }

            for (1..attribute_count) |attribute_index| {
                const name = scanner.attribute_names.at(attribute_index).?;
                const value = scanner.attribute_values.at(attribute_index).?;

                if (mem.eql(u8, "encoding", name)) {
                    if (encoding == null) {
                        encoding = inline for (@typeInfo(XMLDeclaration.Encoding).@"enum".fields) |field| {
                            if (mem.eql(u8, field.name, value))
                                break @field(XMLDeclaration.Encoding, field.name);
                        } else return error.UnsupportedEncoding;
                    } else {
                        return error.InvalidWaylandXML;
                    }
                } else if (mem.eql(u8, "standalone", name)) {
                    if (standalone == null) {
                        if (mem.eql(u8, "yes", value)) {
                            standalone = true;
                        } else if (mem.eql(u8, "no", value)) {
                            standalone = false;
                        } else {
                            return error.InvalidWaylandXML;
                        }
                    } else {
                        return error.InvalidWaylandXML;
                    }
                } else {
                    return error.InvalidWaylandXML;
                }
            }

            scanner.xml_declaration = .{
                .version_major = version.?[0],
                .version_minor = version.?[1],
                .encoding = encoding,
                .standalone = standalone,
            };

            scanner.tag_name_buffer.clearRetainingCapacity();
            scanner.attribute_names.clear();
            scanner.attribute_values.clear();
        } else {
            scanner.source_invalid_err = .invalid_declaration_name;
            return error.InvalidWaylandXML;
        }
    } else {
        scanner.source_invalid_err = .double_declaration;
        return error.InvalidWaylandXML;
    }
}

pub const FinalizeError = error{ MissingAttribute } || Allocator.Error;

pub const Protocol = struct {
    name: []const u8,
    copyright: ?[]const u8,
    interfaces: []const Interface,

    /// Recursively deinit the nested parse objects.
    /// Prefer instead to init and bulk-deinit this parse structure with an arena.
    pub fn deinit(protocol: Protocol, allocator: Allocator) void {
        for (protocol.interfaces) |interface| interface.deinit(allocator);
        allocator.free(protocol.interfaces);
        if (protocol.copyright) |copyright| allocator.free(copyright);
        allocator.free(protocol.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        copyright: ?[]const u8,
        interfaces: std.ArrayList(Interface.Parsing),

        pub fn init(allocator: Allocator) Allocator.Error!Parsing {
            return .{
                .name = null,
                .copyright = null,
                .interfaces = try .initCapacity(allocator, 64),
            };
        }

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            for (parsing.interfaces.items) |*interface| interface.deinit(allocator);
            parsing.interfaces.deinit(allocator);
            if (parsing.copyright) |copyright| allocator.free(copyright);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: *Parsing, allocator: Allocator) FinalizeError!Protocol {
            const interfaces = try allocator.alloc(Interface, parsing.interfaces.items.len);
            errdefer allocator.free(interfaces);
            for (interfaces, parsing.interfaces.items) |*new, *old| new.* = try old.finalize(allocator);
            parsing.interfaces.deinit(allocator);
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .copyright = parsing.copyright,
                .interfaces = interfaces,
            };
        }
    };
};

pub const Interface = struct {
    name: []const u8,
    version: VersionNumber,
    description_short: ?[]const u8,
    description_long: ?[]const u8,
    objects: []const Interface.Object,

    pub fn deinit(interface: Interface, allocator: Allocator) void {
        for (interface.objects) |object| {
            switch (object) {
                inline else => |obj| obj.deinit(allocator),
            }
        }
        allocator.free(interface.objects);
        if (interface.description_long) |description| allocator.free(description);
        if (interface.description_short) |description| allocator.free(description);
        allocator.free(interface.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        version: ?VersionNumber,
        description_short: ?[]const u8,
        description_long: ?[]const u8,
        objects: std.ArrayList(Interface.Object.Parsing),

        pub fn init(allocator: Allocator) Allocator.Error!Parsing {
            return .{
                .name = null,
                .version = null,
                .description_short = null,
                .description_long = null,
                .objects = try .initCapacity(allocator, 128),
            };
        }

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            for (parsing.objects.items) |*object| switch (object.*) {
                inline else => |*obj| obj.deinit(allocator),
            };
            parsing.objects.deinit(allocator);
            if (parsing.description_long) |description| allocator.free(description);
            if (parsing.description_short) |description| allocator.free(description);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: *Parsing, allocator: Allocator) FinalizeError!Interface {
            const objects = try allocator.alloc(Interface.Object, parsing.objects.items.len);
            errdefer allocator.free(objects);
            for (objects, parsing.objects.items) |*new, *old| new.* = switch (old.*) {
                inline else => |*obj, tag| @unionInit(
                    Interface.Object,
                    @tagName(tag),
                    try obj.finalize(allocator),
                ),
            };
            parsing.objects.deinit(allocator);
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .version = parsing.version orelse return error.MissingAttribute,
                .description_short = parsing.description_short,
                .description_long = parsing.description_long,
                .objects = objects,
            };
        }
    };

    pub const ChildTag = enum { request, event, @"enum" };

    pub const Object = union(ChildTag) {
        request: Request,
        event: Event,
        @"enum": Enum,

        const Parsing = union(ChildTag) {
            request: Request.Parsing,
            event: Event.Parsing,
            @"enum": Enum.Parsing,
        };
    };
};

pub const Request = struct {
    name: []const u8,
    since: ?VersionNumber,
    description_short: ?[]const u8,
    description_long: ?[]const u8,
    args: []const Arg,

    pub fn deinit(request: Request, allocator: Allocator) void {
        for (request.args) |arg| arg.deinit(allocator);
        allocator.free(request.args);
        if (request.description_long) |description| allocator.free(description);
        if (request.description_short) |description| allocator.free(description);
        allocator.free(request.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        since: ?VersionNumber,
        description_short: ?[]const u8,
        description_long: ?[]const u8,
        args: std.ArrayList(Arg),

        pub fn init(allocator: Allocator) Allocator.Error!Parsing {
            return .{
                .name = null,
                .since = null,
                .description_short = null,
                .description_long = null,
                .args = try .initCapacity(allocator, 16),
            };
        }

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            for (parsing.args.items) |*arg| arg.deinit(allocator);
            parsing.args.deinit(allocator);
            if (parsing.description_long) |description| allocator.free(description);
            if (parsing.description_short) |description| allocator.free(description);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: *Parsing, allocator: Allocator) FinalizeError!Request {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .since = parsing.since,
                .description_short = parsing.description_short,
                .description_long = parsing.description_long,
                .args = try parsing.args.toOwnedSlice(allocator),
            };
        }
    };
};

pub const Event = struct {
    name: []const u8,
    since: ?VersionNumber,
    description_short: ?[]const u8,
    description_long: ?[]const u8,
    args: []const Arg,

    pub fn deinit(event: Event, allocator: Allocator) void {
        for (event.args) |arg| arg.deinit(allocator);
        allocator.free(event.args);
        if (event.description_long) |description| allocator.free(description);
        if (event.description_short) |description| allocator.free(description);
        allocator.free(event.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        since: ?VersionNumber,
        description_short: ?[]const u8,
        description_long: ?[]const u8,
        args: std.ArrayList(Arg),

        pub fn init(allocator: Allocator) Allocator.Error!Parsing {
            return .{
                .name = null,
                .since = null,
                .description_short = null,
                .description_long = null,
                .args = try .initCapacity(allocator, 16),
            };
        }

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            for (parsing.args.items) |*arg| arg.deinit(allocator);
            parsing.args.deinit(allocator);
            if (parsing.description_long) |description| allocator.free(description);
            if (parsing.description_short) |description| allocator.free(description);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: *Parsing, allocator: Allocator) FinalizeError!Event {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .since = parsing.since,
                .description_short = parsing.description_short,
                .description_long = parsing.description_long,
                .args = try parsing.args.toOwnedSlice(allocator),
            };
        }
    };
};

pub const Enum = struct {
    name: []const u8,
    since: ?VersionNumber,
    description_short: ?[]const u8,
    description_long: ?[]const u8,
    bitfield: bool,
    entries: []const Entry,

    pub fn deinit(@"enum": Enum, allocator: Allocator) void {
        for (@"enum".entries) |entry| entry.deinit(allocator);
        allocator.free(@"enum".entries);
        if (@"enum".description_long) |description| allocator.free(description);
        if (@"enum".description_short) |description| allocator.free(description);
        allocator.free(@"enum".name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        since: ?VersionNumber,
        description_short: ?[]const u8,
        description_long: ?[]const u8,
        bitfield: ?bool,
        entries: std.ArrayList(Entry),

        pub fn init(allocator: Allocator) Allocator.Error!Parsing {
            return .{
                .name = null,
                .since = null,
                .description_short = null,
                .description_long = null,
                .bitfield = null,
                .entries = try .initCapacity(allocator, 32),
            };
        }

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            for (parsing.entries.items) |*entry| entry.deinit(allocator);
            parsing.entries.deinit(allocator);
            if (parsing.description_long) |description| allocator.free(description);
            if (parsing.description_short) |description| allocator.free(description);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: *Parsing, allocator: Allocator) FinalizeError!Enum {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .since = parsing.since,
                .description_short = parsing.description_short,
                .description_long = parsing.description_long,
                .bitfield = parsing.bitfield orelse false,
                .entries = try parsing.entries.toOwnedSlice(allocator),
            };
        }
    };
};

pub const Arg = struct {
    name: []const u8,
    @"type": Type,
    interface: ?[]const u8,
    allow_null: ?bool,
    summary: ?[]const u8,

    pub fn deinit(arg: Arg, allocator: Allocator) void {
        if (arg.summary) |summary| allocator.free(summary);
        if (arg.interface) |interface| allocator.free(interface);
        allocator.free(arg.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        @"type": ?Type,
        interface: ?[]const u8,
        allow_null: ?bool,
        summary: ?[]const u8,

        pub const init: Parsing = .{
            .name = null,
            .@"type" = null,
            .interface = null,
            .allow_null = null,
            .summary = null,
        };

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            if (parsing.summary) |summary| allocator.free(summary);
            if (parsing.interface) |interface| allocator.free(interface);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: Parsing) error{MissingAttribute}!Arg {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .@"type" = parsing.@"type" orelse return error.MissingAttribute,
                .interface = parsing.interface,
                .allow_null = parsing.allow_null,
                .summary = parsing.summary,
            };
        }
    };

    pub const Type = enum {
        int,
        uint,
        fixed,
        string,
        object,
        new_id,
        array,
        fd,

        pub fn fromString(str: []const u8) ?Type {
            return name_map.get(str);
        }

        const name_map: std.StaticStringMap(Type) = .initComptime( make: {
            const types = std.enums.values(Type);
            var list: [types.len]struct { []const u8, Type } = undefined;
            for (&list, types) |*kvs, @"type"| kvs.* = .{ @tagName(@"type"), @"type" };
            break :make list;
        } );
    };
};

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
    summary: ?[]const u8,

    pub fn deinit(entry: Entry, allocator: Allocator) void {
        if (entry.summary) |summary| allocator.free(summary);
        allocator.free(entry.value);
        allocator.free(entry.name);
    }

    const Parsing = struct {
        name: ?[]const u8,
        value: ?[]const u8,
        summary: ?[]const u8,

        pub const init: Parsing = .{
            .name = null,
            .value = null,
            .summary = null,
        };

        pub fn deinit(parsing: *Parsing, allocator: Allocator) void {
            if (parsing.summary) |summary| allocator.free(summary);
            if (parsing.value) |value| allocator.free(value);
            if (parsing.name) |name| allocator.free(name);
            parsing.* = undefined;
        }

        fn finalize(parsing: Parsing) error{MissingAttribute}!Entry {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .value = parsing.value orelse return error.MissingAttribute,
                .summary = parsing.summary,
            };
        }
    };

    pub fn isValidValue(value: []const u8) bool {
        const PossibleBacking = [_]type{ u32, i32 };
        return inline for (PossibleBacking) |Backing| {
            if (fmt.parseInt(Backing, value, 0)) |_| {
                break true;
            } else |_| {}
        } else false;
    }
};

/// Format XML literal text blocks by
/// outdenting and deleting trailing (non-newline) whitespace,
/// allocating and returning the result.
pub fn trimLiteralText(allocator: Allocator, text: []const u8) ![]const u8 {
    // TODO support non-Unix newlines
    for (text) |c| { if (c == '\r') return error.UnsupportedEncoding; }

    var iter = mem.splitScalar(u8, mem.trim(u8, text, &std.ascii.whitespace), '\n');

    const result_len: usize = scan: {
        var count: usize = 0;
        while (iter.next()) |line| {
            const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
            count += if (iter.index!=null) trimmed.len + 1 else trimmed.len;
        }
        break :scan count;
    };

    iter.reset();

    const result = try allocator.alloc(u8, result_len);
    errdefer allocator.free(result);

    {
        var result_idx: usize = 0;
        while (iter.next()) |line| {
            const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
            @memcpy(result[result_idx..][0..trimmed.len], trimmed);
            result_idx += trimmed.len;
            if (iter.index != null) {
                result[result_idx] = '\n';
                result_idx += 1;
            }
        }
    }

    return result;
}

fn upperName(allocator: Allocator, name: []const u8) Allocator.Error![]const u8 {
    assert(isValidName(name));
    const upper = try allocator.alloc(u8, name.len - count: {
        var count: usize = 0;
        for (name) |c| { if (c == '_') count += 1; }
        break :count count;
    });
    errdefer allocator.free(upper);
    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    while (dst_idx < upper.len) {
        if (name[src_idx] != '_') {
            upper[dst_idx] =
                if (src_idx == 0 or name[src_idx-1] == '_') std.ascii.toUpper(name[src_idx])
                else name[src_idx]
            ;
            dst_idx += 1;
        }
        src_idx += 1;
    }
    assert(dst_idx == upper.len);
    return upper;
}

test upperName {
    const lower = "a__foo____bar___";
    const upper = try upperName(testing.allocator, lower);
    defer testing.allocator.free(upper);
    try testing.expectEqualStrings("AFooBar", upper);
}

fn preValidateTagName(scanner: *Scanner, name: []const u8) error{InvalidWaylandXML}!void {
    if ( mem.eql(u8, "DOCTYPE", name) ) {
        scanner.source_invalid_err = .doctype_unsupported;
        return error.InvalidWaylandXML;
    }
}

fn validateTagPosition(scanner: *Scanner, top: ?Tag, tag: Tag) error{InvalidWaylandXML}!void {
    switch (tag) {
        .protocol => {
            if (top != null) {
                scanner.source_invalid_err = .non_root_protocol;
                return error.InvalidWaylandXML;
            }
        },
        .interface => {
            if (top != .protocol) {
                scanner.source_invalid_err = .interface_not_protocol_child;
                return error.InvalidWaylandXML;
            }
        },
        .request, .event, .@"enum" => {
            if (top != .interface) {
                scanner.source_invalid_err = .interface_child_not;
                return error.InvalidWaylandXML;
            }
        },
        .arg => {
            if (top != .request and top != .event) {
                scanner.source_invalid_err = .invalid_arg_parent;
                return error.InvalidWaylandXML;
            }
        },
        .entry => {
            if (top != .@"enum") {
                scanner.source_invalid_err = .invalid_entry_parent;
                return error.InvalidWaylandXML;
            }
        },
        .description => {
            if (top) |t| {
                switch (t) {
                    .interface, .request, .event, .@"enum" => {},
                    else => {
                        scanner.source_invalid_err = .invalid_description_parent;
                        return error.InvalidWaylandXML;
                    },
                }
            } else {
                scanner.source_invalid_err = .invalid_description_parent;
                return error.InvalidWaylandXML;
            }
        },
        .copyright => {
            if (top != .protocol) {
                scanner.source_invalid_err = .invalid_copyright_parent;
                return error.InvalidWaylandXML;
            }
        },
    }
}

/// Protocol names seem to follow the same convention as Zig identifiers,
/// so we will just validate and map them directly to the output namespaces.
fn isValidName(name: []const u8) bool {
    return name.len >= 1 and
        ( std.ascii.isLower(name[0]) or name[0] == '_' ) and
        ( for (name[1..]) |c| {
            switch (c) {
                '0'...'9', 'a'...'z', '_' => {},
                else => break false,
            }
        } else true )
    ;
}

fn isNewline(char: u8, last_char: u8) bool {
    return char=='\r' or ( char=='\n' and last_char!='\r' );
}

pub const VersionNumber = usize;

test "maximal valid protocol" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "minimal",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{},
            }},
        }},
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<protocol name="minimal">
        \\    <interface name="foo" version="1"/>
        \\</protocol>
    );
}

test "interface with description only" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "described_interface",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = "short",
                .description_long =
                    \\Long description text.
                    \\Can span multiple lines.
                ,
                .objects = &.{},
            }},
        }},
        \\<protocol name="described_interface">
        \\    <interface name="foo" version="1">
        \\        <description summary="short">
        \\            Long description text.
        \\            Can span multiple lines.
        \\        </description>
        \\    </interface>
        \\</protocol>
    );
}

test "interface with request, no args" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "request_only",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .request = .{
                        .name = "ping",
                        .since = null,
                        .description_short = null,
                        .description_long = null,
                        .args = &.{},
                    }},
                },
            }},
        }},
        \\<protocol name="request_only">
        \\    <interface name="foo" version="1">
        \\        <request name="ping"/>
        \\    </interface>
        \\</protocol>
    );
}

test "request with all argument types" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "all_args",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .request = .{
                        .name = "everything",
                        .since = null,
                        .description_short = null,
                        .description_long = null,
                        .args = &.{
                            .{
                                .name = "a",
                                .@"type" = .int,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "b",
                                .@"type" = .uint,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "c",
                                .@"type" = .fixed,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "d",
                                .@"type" = .string,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "e",
                                .@"type" = .array,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "f",
                                .@"type" = .fd,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                            .{
                                .name = "g",
                                .@"type" = .object,
                                .interface = "foo",
                                .allow_null = true,
                                .summary = null,
                            },
                            .{
                                .name = "h",
                                .@"type" = .new_id,
                                .interface = "foo",
                                .allow_null = null,
                                .summary = null,
                            },
                        },
                    }},
                },
            }},
        }},
        \\<protocol name="all_args">
        \\    <interface name="foo" version="1">
        \\        <request name="everything">
        \\            <arg name="a" type="int"/>
        \\            <arg name="b" type="uint"/>
        \\            <arg name="c" type="fixed"/>
        \\            <arg name="d" type="string"/>
        \\            <arg name="e" type="array"/>
        \\            <arg name="f" type="fd"/>
        \\            <arg name="g" type="object" interface="foo" allow-null="true"/>
        \\            <arg name="h" type="new_id" interface="foo"/>
        \\        </request>
        \\    </interface>
        \\</protocol>
    );
}

test "event with arguments and description" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "event_example",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .event = .{
                        .name = "changed",
                        .since = null,
                        .description_short = "notification",
                        .description_long =
                            \\Sent when something changes.
                        ,
                        .args = &.{
                            .{
                                .name = "value",
                                .@"type" = .int,
                                .interface = null,
                                .allow_null = null,
                                .summary = null,
                            },
                        },
                    }},
                },
            }},
        }},
        \\<protocol name="event_example">
        \\    <interface name="foo" version="1">
        \\        <event name="changed">
        \\            <description summary="notification">
        \\                Sent when something changes.
        \\            </description>
        \\            <arg name="value" type="int"/>
        \\        </event>
        \\    </interface>
        \\</protocol>
    );
}

test "non-bitfield enum" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "enum_example",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .@"enum" = .{
                        .name = "error",
                        .since = null,
                        .description_short = "error codes",
                        .description_long =
                            \\Error conditions.
                        ,
                        .bitfield = false,
                        .entries = &.{
                            .{
                                .name = "ok",
                                .value = "0",
                                .summary = null,
                            },
                            .{
                                .name = "failed",
                                .value = "1",
                                .summary = null,
                            },
                        },
                    }},
                },
            }},
        }},
        \\<protocol name="enum_example">
        \\    <interface name="foo" version="1">
        \\        <enum name="error">
        \\            <description summary="error codes">
        \\                Error conditions.
        \\            </description>
        \\            <entry name="ok" value="0"/>
        \\            <entry name="failed" value="1"/>
        \\        </enum>
        \\    </interface>
        \\</protocol>
    );
}

test "bitfield enum" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "bitfield_enum",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 1,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .@"enum" = .{
                        .name = "flags",
                        .since = null,
                        .description_short = null,
                        .description_long = null,
                        .bitfield = true,
                        .entries = &.{
                            .{
                                .name = "one",
                                .value = "1",
                                .summary = null,
                            },
                            .{
                                .name = "two",
                                .value = "2",
                                .summary = null,
                            },
                            .{
                                .name = "four",
                                .value = "4",
                                .summary = null,
                            },
                        },
                    }},
                },
            }},
        }},
        \\<protocol name="bitfield_enum">
        \\    <interface name="foo" version="1">
        \\        <enum name="flags" bitfield="true">
        \\            <entry name="one" value="1"/>
        \\            <entry name="two" value="2"/>
        \\            <entry name="four" value="4"/>
        \\        </enum>
        \\    </interface>
        \\</protocol>
    );
}

test "since attribute usage" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "since_example",
            .copyright = null,
            .interfaces = &.{ .{
                .name = "foo",
                .version = 3,
                .description_short = null,
                .description_long = null,
                .objects = &.{
                    .{ .request = .{
                        .name = "old_method",
                        .since = null,
                        .description_short = null,
                        .description_long = null,
                        .args = &.{},
                    }},
                    .{ .request = .{
                        .name = "new_method",
                        .since = 2,
                        .description_short = null,
                        .description_long = null,
                        .args = &.{},
                    }},
                    .{ .event = .{
                        .name = "new_event",
                        .since = 3,
                        .description_short = null,
                        .description_long = null,
                        .args = &.{},
                    }},
                },
            }},
        }},
        \\<protocol name="since_example">
        \\    <interface name="foo" version="3">
        \\        <request name="old_method"/>
        \\        <request name="new_method" since="2"/>
        \\        <event name="new_event" since="3"/>
        \\    </interface>
        \\</protocol>
    );
}

test "multiple interfaces in one protocol" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "multi_interface",
            .copyright = null,
            .interfaces = &.{
                .{
                    .name = "bar",
                    .version = 1,
                    .description_short = null,
                    .description_long = null,
                    .objects = &.{},
                },
                .{
                    .name = "foo",
                    .version = 1,
                    .description_short = null,
                    .description_long = null,
                    .objects = &.{
                        .{ .request = .{
                            .name = "use_bar",
                            .since = null,
                            .description_short = null,
                            .description_long = null,
                            .args = &.{
                                .{
                                    .name = "obj",
                                    .@"type" = .object,
                                    .interface = "bar",
                                    .allow_null = null,
                                    .summary = null,
                                },
                            },
                        }},
                    },
                },
            },
        }},
        \\<protocol name="multi_interface">
        \\    <interface name="bar" version="1"/>
        \\
        \\    <interface name="foo" version="1">
        \\        <request name="use_bar">
        \\            <arg name="obj" type="object" interface="bar"/>
        \\        </request>
        \\    </interface>
        \\</protocol>
    );
}

test "maximal complete protocol" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseEqual(&scanner,
        &.{ .{
            .name = "complete",
            .copyright =
                \\Copyright (C) Example
                \\MIT License
            ,
            .interfaces = &.{
                .{
                    .name = "foo",
                    .version = 2,
                    .description_short = "main interface",
                    .description_long =
                        \\This interface demonstrates all features.
                    ,
                    .objects = &.{
                        .{ .@"enum" = .{
                            .name = "state",
                            .since = null,
                            .description_short = null,
                            .description_long = null,
                            .bitfield = false,
                            .entries = &.{
                                .{
                                    .name = "idle",
                                    .value = "0",
                                    .summary = null,
                                },
                                .{
                                    .name = "active",
                                    .value = "1",
                                    .summary = null,
                                },
                            },
                        }},
                        .{ .request = .{
                            .name = "set_state",
                            .since = 2,
                            .description_short = null,
                            .description_long = null,
                            .args = &.{
                                .{
                                    .name = "state",
                                    .@"type" = .uint,
                                    .interface = null,
                                    .allow_null = null,
                                    .summary = null,
                                },
                            },
                        }},
                        .{ .event = .{
                            .name = "state_changed",
                            .since = null,
                            .description_short = null,
                            .description_long = null,
                            .args = &.{
                                .{
                                    .name = "state",
                                    .@"type" = .uint,
                                    .interface = null,
                                    .allow_null = null,
                                    .summary = null,
                                },
                            },
                        }},
                    },
                },
            },
        }},
        \\<protocol name="complete">
        \\    <copyright>
        \\        Copyright (C) Example
        \\        MIT License
        \\    </copyright>
        \\
        \\    <interface name="foo" version="2">
        \\        <description summary="main interface">
        \\            This interface demonstrates all features.
        \\        </description>
        \\
        \\        <enum name="state">
        \\            <entry name="idle" value="0"/>
        \\            <entry name="active" value="1"/>
        \\        </enum>
        \\
        \\        <request name="set_state" since="2">
        \\            <arg name="state" type="uint"/>
        \\        </request>
        \\
        \\        <event name="state_changed">
        \\            <arg name="state" type="uint"/>
        \\        </event>
        \\    </interface>
        \\</protocol>
    );
}

test "mismatched end tag" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .mismatched_tag_close,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\</protocol>
    );
}

test "unclosed tag" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseError(&scanner, testing.allocator, error.StreamIncomplete,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
    );
}

test "invalid nesting" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .mismatched_tag_close,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <request name="bar">
        \\    </interface>
        \\    </request>
        \\</protocol>
    );
}

test "declaration after start" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .mismatched_tag_close,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <request name="bar">
        \\    </interface>
        \\    </request>
        \\</protocol>
    );
}

test "doctype preset" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .doctype_unsupported,
        \\<!DOCTYPE protocol>
        \\<protocol name="test"/>
    );
}

test "CDATA usage" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .unsupported_tag,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <description><![CDATA[hello]]></description>
        \\    </interface>
        \\</protocol>
    );
}

test "unknown root tag" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .unsupported_tag,
        \\<foo>
        \\    <protocol name="test"/>
        \\</foo>
    );
}

test "unknown tag" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .unsupported_tag,
        \\<protocol name="test">
        \\    <meow/>
        \\</protocol>
    );
}

test "arg as protocol child" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_arg_parent,
        \\<protocol name="test">
        \\    <arg name="x" type="int"/>
        \\</protocol>
    );
}

test "missing protocol name" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol>
        \\</protocol>
    );
}

test "missing interface version" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol name="test">
        \\    <interface name="foo"/>
        \\</protocol>
    );
}

test "missing request name" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <request><request/>
        \\    </interface>
        \\</protocol>
    );
}

test "missing arg type" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <request name="bar">
        \\            <arg name="x"/>
        \\        <request/>
        \\    </interface>
        \\</protocol>
    );
}

test "unknown attribute" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol name="test" foo="bar"/>
    );
}

test "illegal attribute on tag" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
        \\<protocol name="test">
        \\    <interface name="foo" version="1" since="2"/>
        \\</protocol>
    );
}

test "invalid name characters" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);
    //try expectSourceInvalid(&scanner, testing.allocator, .invalid_attributes,
    //    \\<protocol name="test">
    //    \\    <interface name="Foo-Bar" version="1"/>
    //    \\</protocol>
    //);
}

test "version not a positive integer" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="0"/>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.invalid_attributes, scanner.source_invalid_err);
}

test "since greater than interface version" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <request name="bar" since="2"/>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.invalid_attributes, scanner.source_invalid_err);
}

test "invalid arg type" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <request name="bar">
    //    \\            <arg name="x" type="float"/>
    //    \\        </request>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "object arg missing interface" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <request name="bar">
    //    \\            <arg name="x" type="object"/>
    //    \\        </request>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "allow-null on non-object" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <request name="bar">
    //    \\            <arg name="x" type="int" allow-null="true"/>
    //    \\        </request>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "invalid allow-null value" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <request name="bar">
    //    \\            <arg name="x" type="object" interface="foo" allow-null="yes"/>
    //    \\        </request>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}


test "enum without entries" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <enum name="foo"/>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "entry missing value" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <enum name="foo">
    //    \\            <entry name="bar"/>
    //    \\        </enum>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "duplicate enum entry values" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <enum name="foo">
    //    \\            <entry name="bar" value="1"/>
    //    \\            <entry name="bar" value="1"/>
    //    \\        </enum>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "bitfield enum with non-power-of-two" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" version="1">
    //    \\        <enum name="foo" bitfield="true">
    //    \\            <entry name="bad" value="3"/>
    //    \\        </enum>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "description with nested tags" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .unsupported_tag,
        \\<protocol name="test">
        \\    <interface name="foo" version="1">
        \\        <description>
        \\            <b>bold</b>
        \\        </description>
        \\    </interface>
        \\</protocol>
    );
}

test "entry outside enum" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_entry_parent,
        \\<protocol name="test">
        \\    <entry name="x" value="1"/>
        \\</protocol>
    );
}

test "arg outside request or event" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_arg_parent,
        \\<protocol name="test">
        \\    <arg name="x" type="int"/>
        \\</protocol>
    );
}

test "non-utf-8 encoding declaration" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectParseError(&scanner, testing.allocator, error.UnsupportedEncoding,
        \\<?xml version="1.0" encoding="ISO-8859-1"?>
        \\<protocol name="test"/>
    );
}

test "non-beginning XML declaration" {
    var scanner: Scanner = try .init(testing.allocator);
    defer scanner.deinit(testing.allocator);
    try expectSourceInvalid(&scanner, testing.allocator, .invalid_attribute_name_char,
        \\<protocol name="test"/>
        \\<?xml version="1.0"?>
    );
}

test "duplicate interface names" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" value="1"/>
    //    \\    <interface name="foo" value="2"/>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

test "duplicate request names" {
    // TODO
    return error.SkipZigTest;
    //var scanner: Scanner = try .init(testing.allocator);
    //defer scanner.deinit(testing.allocator);

    //var xml: Io.Reader = .fixed(
    //    \\<protocol name="test">
    //    \\    <interface name="foo" value="1">
    //    \\        <request name="bar"/>
    //    \\        <request name="bar"/>
    //    \\    </interface>
    //    \\</protocol>
    //);

    //scanner.newStream();
    //try testing.expectError(error.InvalidWaylandXML, scanner.parse(testing.allocator, &xml));
    //try testing.expectEqual(SourceInvalidError.unsupported_tag, scanner.source_invalid_err);
}

fn expectTreeWithStringsEqual(expected: anytype, actual: anytype) error{TestExpectedEqual}!void {
    const T = @TypeOf(expected, actual);
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            switch (pointer.size) {
                .one => try expectTreeWithStringsEqual(expected.*, actual.*),
                .slice => {
                    if (pointer.child == u8) {
                        try testing.expectEqualStrings(expected, actual);
                    } else {
                        for (expected, actual) |exp, act|
                            try expectTreeWithStringsEqual(exp, act);
                    }
                },
                else => @compileError(std.fmt.comptimePrint(
                    "unsupported pointer type {s} (must be single or slice)",
                    .{ @typeName(T) },
                )),
            }
        },

        .@"struct" => {
            inline for (comptime std.meta.fieldNames(T)) |field_name| {
                try expectTreeWithStringsEqual(
                    @field(expected, field_name),
                    @field(actual, field_name),
                );
            }
        },

        .@"union" => |@"union"| {
            const TTag: type = @"union".tag_type orelse @compileError(std.fmt.comptimePrint(
                "unsupported untagged union {s}",
                .{ @typeName(T) },
            ));
            const expected_tag: TTag = expected;
            const actual_tag: TTag = actual;
            if (expected_tag == actual_tag) {
                switch (expected_tag) {
                    inline else => |exp_tag| {
                        const Inner = @FieldType(T, @tagName(exp_tag));
                        const expected_inner: Inner = @field(expected, @tagName(exp_tag));
                        const actual_inner: Inner = @field(actual, @tagName(exp_tag));
                        try expectTreeWithStringsEqual(expected_inner, actual_inner);
                    },
                }
            } else {
                testingPrint("expected {t} field, found {t}", .{
                    expected_tag,
                    actual_tag,
                });
                return error.TestExpectedEqual;
            }
        },

        else => {
            switch (T) {
                []u8, []const u8 => try testing.expectEqualStrings(expected, actual),

                ?[]u8, ?[]const u8 => {
                    if (expected != null and actual != null) {
                        try testing.expectEqualStrings(expected.?, actual.?);
                    } else if (!(expected == null and actual == null)) {
                        if (expected) |expected_str| {
                            testingPrint("expected {s}, found null\n", .{ expected_str });
                        } else {
                            testingPrint("expected null, found {s}\n", .{ actual.? });
                        }
                        return error.TestExpectedEqual;
                    }
                },

                else => try testing.expectEqual(expected, actual),
            }
        },
    }
}

fn expectParseEqual(
    scanner: *Scanner,
    expected: []const Protocol,
    xml: []const u8,
) !void {
    var reader: Io.Reader = .fixed(xml);
    scanner.newStream();
    const result = scanner.parse(testing.allocator, &reader);
    if (result) |protocols| {
        defer {
            for (protocols) |protocol| protocol.deinit(testing.allocator);
            testing.allocator.free(protocols);
        }
        for (expected, protocols) |expected_protocol, actual_protocol| {
            try expectTreeWithStringsEqual(expected_protocol, actual_protocol);
        }
    } else |err| {
        if (err == error.InvalidWaylandXML) {
            scanner.logSourceInvalidError(testingPrint, "test xml");
            testingPrint("\n", .{});
        }
        return err;
    }
}

fn expectSourceInvalid(
    scanner: *Scanner,
    allocator: Allocator,
    err: SourceInvalidError,
    source: []const u8,
) !void {
    var xml: Io.Reader = .fixed(source);
    scanner.newStream();
    const result = scanner.parse(allocator, &xml);
    if (result) |protocols| {
        testingPrint("expected SourceInvalidError.{s}, found {d} protocol{s}\n", .{
            @tagName(err),
            protocols.len,
            if (protocols.len == 1) "" else "s",
        });
        for (protocols) |protocol| protocol.deinit(allocator);
        allocator.free(protocols);
        return error.TestExpectedError;
    } else |actual| {
        if (actual == error.InvalidWaylandXML) {
            if (scanner.source_invalid_err != err) {
                if (scanner.source_invalid_err) |e| {
                    testingPrint("expected SourceInvalidError.{t}, found SourceInvalidError.{t}\n", .{ err, e });
                } else {
                    testingPrint("expected SourceInvalidError.{t}, found null\n", .{ err });
                }
                return error.TestUnexpectedError;
            }
        } else {
            return actual;
        }
    }
}

fn expectParseError(
    scanner: *Scanner,
    allocator: Allocator,
    err: anyerror,
    source: []const u8,
) !void {
    var xml: Io.Reader = .fixed(source);
    scanner.newStream();
    const result = scanner.parse(allocator, &xml);
    if (result) |protocols| {
        testingPrint("expected error.{s}, found {d} protocols\n", .{
            @errorName(err),
            protocols.len,
        });
        for (protocols) |protocol| protocol.deinit(allocator);
        allocator.free(protocols);
        return error.TestExpectedError;
    } else |actual| {
        if (err != actual) {
            testingPrint("expected error.{s}, found error.{s}\n", .{
                @errorName(err),
                @errorName(actual),
            });
            return error.TestUnexpectedError;
        }
    }
}

/// Duplicated due to not being `pub` as of 0.16.0-dev.1522+95f93a0b2
/// TODO proper way for user to print in tests
fn testingPrint(comptime format: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(format, args));
    } else if (testing.backend_can_print) {
        std.debug.print(format, args);
    }
}

/// A simple dynamic string list for collecting attribute names and values
const StringList = struct {
    strings: Strings,
    concatenated: ByteArrayList,

    pub const initial_total_byte_capacity = 512;
    pub const initial_string_count_capacity = 16;

    const Strings = std.ArrayList(StringEntry);
    const StringEntry = struct { idx: usize, len: usize };

    pub fn create(allocator: Allocator) Allocator.Error!StringList {
        var list: StringList = undefined;
        try list.init(allocator);
        return list;
    }

    pub fn init(list: *StringList, allocator: Allocator) Allocator.Error!void {
        list.concatenated = try .initCapacity(allocator, initial_total_byte_capacity);
        list.strings = try .initCapacity(allocator, initial_string_count_capacity);
    }

    pub fn deinit(list: *StringList, allocator: Allocator) void {
        list.concatenated.deinit(allocator);
        list.strings.deinit(allocator);
        list.* = undefined;
    }

    pub fn clear(list: *StringList) void {
        list.concatenated.clearRetainingCapacity();
        list.strings.clearRetainingCapacity();
    }

    pub fn add(list: *StringList, allocator: Allocator, string: []const u8) Allocator.Error!void {
        const new_string: StringEntry = .{
            .idx = list.concatenated.items.len,
            .len = string.len,
        };
        try list.concatenated.appendSlice(allocator, string);
        try list.strings.append(allocator, new_string);
        assert(mem.eql(u8, string, list.concatenated.items[new_string.idx..][0..new_string.len]));
    }

    /// Assumes entry validity
    pub fn stringFromEntry(list: StringList, entry: StringEntry) []const u8 {
        return list.concatenated.items[entry.idx..][0..entry.len];
    }

    pub fn at(list: StringList, idx: usize) ?[]const u8 {
        if (idx < list.strings.items.len) {
            const entry = list.strings.items[idx];
            assert(entry.idx + entry.len <= list.concatenated.items.len);
            return list.stringFromEntry(entry);
        } else {
            return null;
        }
    }
};

const Scanner = @This();

const ByteArrayList = std.ArrayList(u8);
const TagStack = std.ArrayList(Tag);
const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mem = std.mem;
const fmt = std.fmt;
const log = std.log;
const testing = std.testing;

const std = @import("std");
