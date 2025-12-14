//! Parses Wayland protocol XML into Zig source
//! imported and consumed by the Spark library.
//! This module is both a valid root for an executable
//! and the object for parsing and writing.

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
        };
        // Don't try to continue with other files after one file failed,
        // because we have probably now written incomplete and invalid source
    }

    // TODO unsure if when file writers/readers fail this would ever be null
    // (also above)
    writer.interface.flush() catch return writer.err orelse error.WriteFailedMissingError;
}

pub const SourceInvalidError = enum {
    broken_tag,
    empty_tag_name,
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
};

pub fn logSourceInvalidErr(scanner: Scanner, comptime logFn: anytype, file_path: []const u8) void {
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
        }
    } else {
        logFn(
            "{s}:{d}:{d}: unspecified error (seeing this is a bug)",
            .{ file_path, scanner.line, scanner.column },
        );
    }
}

pub const Error = error{
    WriteFailed,
    ReadFailed,
    InvalidWaylandXML,
    UnsupportedEncoding,
} || Allocator.Error;

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
    scanner.text_literal_buffer.deinit(allocator);
    scanner.attribute_value_buffer.deinit(allocator);
    scanner.attribute_name_buffer.deinit(allocator);
    scanner.tag_name_buffer.deinit(allocator);
    scanner.attribute_names.deinit(allocator);
    scanner.attribute_values.deinit(allocator);
    scanner.* = undefined;
}

pub fn newStream(scanner: *Scanner) void {
    if (scanner.tag_name_buffer.items.len != 0) {
        std.log.err("discarding incomplete tag name \"{s}\"", .{ scanner.tag_name_buffer.items });
        scanner.tag_name_buffer.clearRetainingCapacity();
    }
    if (scanner.attribute_name_buffer.items.len != 0) {
        std.log.err("discarding incomplete attribute name \"{s}\"", .{ scanner.attribute_name_buffer.items });
        scanner.attribute_name_buffer.clearRetainingCapacity();
    }
    if (scanner.attribute_value_buffer.items.len != 0) {
        std.log.err("discarding incomplete attribute value \"{s}\"", .{ scanner.attribute_value_buffer.items });
        scanner.attribute_value_buffer.clearRetainingCapacity();
    }
    if (scanner.text_literal_buffer.items.len != 0) {
        std.log.err("discarding incomplete literal text \"{s}\"", .{ scanner.text_literal_buffer.items });
        scanner.text_literal_buffer.clearRetainingCapacity();
    }
    if (scanner.attribute_names.strings.items.len != 0 or scanner.attribute_names.concatenated.items.len != 0) {
        std.log.err("discarding unattributed {d} attribute names", .{ scanner.attribute_names.strings.items.len });
        scanner.attribute_names.clear();
    }
    if (scanner.attribute_values.strings.items.len != 0 or scanner.attribute_values.concatenated.items.len != 0) {
        std.log.err("discarding unattributed {d} attribute values", .{ scanner.attribute_values.strings.items.len });
        scanner.attribute_names.clear();
    }
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

/// Parses `reader` until EOF,
/// writing completed sections to `writer` as they are parsed.
pub fn stream(scanner: *Scanner, writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) Error!void {
    parse: switch (State.plaintext) {
        .plaintext => {
            const char = try scanner.nextByte(reader) orelse return;
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
            // Now we can assume UTF-8 encoding unless another is declared

            if (char == '<') {
                assert(scanner.tag_name_buffer.items.len == 0);
                continue :parse .tag_name;
            } else {
                continue :parse .plaintext;
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
                            try scanner.pushEmptyElement(writer);
                            continue :parse .plaintext;
                        } else if (scanner.last_byte == '?') {
                            try scanner.pushDeclaration();
                            continue :parse .plaintext;
                        } else {
                            try scanner.pushStartElement(writer);
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
                        // Because '<' in tag_name is a parse error, we must have "<!"
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
                            try scanner.pushEndElement(writer);
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
                            try scanner.pushEmptyElement(writer);
                            continue :parse .plaintext;
                        } else {
                            try scanner.pushStartElement(writer);
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
                        try scanner.pushLiteralText(writer);
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
fn pushEmptyElement(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("<{s}/>\n", .{ scanner.tag_name_buffer.items });
    for (
        scanner.attribute_names.strings.items,
        scanner.attribute_values.strings.items,
    ) |name_entry, value_entry| {
        try writer.print("  {s}=\"{s}\"\n", .{
            scanner.attribute_names.stringFromEntry(name_entry),
            scanner.attribute_values.stringFromEntry(value_entry),
        });
    }

    scanner.tag_name_buffer.clearRetainingCapacity();
    scanner.attribute_names.clear();
    scanner.attribute_values.clear();
}

/// A beginning element tag ('<TAGNAME>')
fn pushStartElement(scanner: *Scanner, writer: *Io.Writer) !void {
    scanner.last_opening_was_literal_text_tag =
        for (literal_text_tags) |tag_name| {
            if (mem.eql(u8, tag_name, scanner.tag_name_buffer.items)) break true;
        } else false;

    // TODO
    try writer.print("<{s}>\n", .{ scanner.tag_name_buffer.items });
    for (
        scanner.attribute_names.strings.items,
        scanner.attribute_values.strings.items,
    ) |name_entry, value_entry| {
        try writer.print("  {s}=\"{s}\"\n", .{
            scanner.attribute_names.stringFromEntry(name_entry),
            scanner.attribute_values.stringFromEntry(value_entry),
        });
    }

    scanner.tag_name_buffer.clearRetainingCapacity();
    scanner.attribute_names.clear();
    scanner.attribute_values.clear();
}

pub const literal_text_tags = [_][:0]const u8 {
    "description",
    "copyright",
};

/// An ending element tag ('</TAGNAME>')
fn pushEndElement(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("</{s}>\n", .{ scanner.tag_name_buffer.items });
    scanner.tag_name_buffer.clearRetainingCapacity();
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

fn pushLiteralText(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("literal text: \"{s}\"\n", .{ scanner.text_literal_buffer.items });
    scanner.text_literal_buffer.clearRetainingCapacity();
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
                scanner.attribute_names.stringFromEntry(scanner.attribute_names.strings.items[0]),
            )) {
                const major_string, const minor_string = mem.cutScalar(u8,
                    scanner.attribute_values.stringFromEntry(scanner.attribute_values.strings.items[0]),
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
                const name = scanner.attribute_names.stringFromEntry(
                    scanner.attribute_names.strings.items[attribute_index]);
                const value = scanner.attribute_values.stringFromEntry(
                    scanner.attribute_values.strings.items[attribute_index]);

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
    interfaces: []Interface,

    /// Recursively deinit the nested parse objects.
    /// Prefer instead to init and bulk-deinit this parse structure with an arena.
    pub fn deinit(protocol: Protocol, allocator: Allocator) void {
        if (protocol.copyright) |copyright| allocator.free(copyright);
        for (protocol.interfaces) |interface| interface.deinit(allocator);
        allocator.free(protocol.interfaces);
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

        fn finalize(parsing: Parsing, allocator: Allocator) FinalizeError!Protocol {
            const interfaces = try allocator.alloc(Interface, parsing.interfaces.items.len);
            errdefer allocator.free(interfaces);
            for (interfaces, parsing.interfaces.items) |*new, old| new.* = try old.finalize(allocator);
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
    objects: []Interface.Object,

    pub fn deinit(interface: Interface, allocator: Allocator) void {
        for (interface.objects) |object| {
            switch (object) {
                inline else => |obj| obj.deinit(allocator),
            }
        }
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

        fn finalize(parsing: Parsing, allocator: Allocator) FinalizeError!Interface {
            const objects = try allocator.alloc(Interface.Object, parsing.objects.items.len);
            errdefer allocator.free(objects);
            for (objects, parsing.objects.items) |*new, old| new.* = switch (old) {
                inline else => |obj, tag| @unionInit(
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
    args: []Arg,

    pub fn deinit(request: Request, allocator: Allocator) void {
        for (request.args) |arg| arg.deinit(allocator);
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

        fn finalize(parsing: Parsing, allocator: Allocator) FinalizeError!Request {
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
    description_short: ?[]const u8,
    description_long: ?[]const u8,
    since: ?VersionNumber,
    args: []Arg,

    pub fn deinit(event: Event, allocator: Allocator) void {
        for (event.args) |arg| arg.deinit(allocator);
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

        fn finalize(parsing: Parsing, allocator: Allocator) FinalizeError!Event {
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
    entries: []Entry,

    pub fn deinit(@"enum": Enum, allocator: Allocator) void {
        for (@"enum".entries) |entry| entry.deinit(allocator);
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

        fn finalize(parsing: Parsing, allocator: Allocator) FinalizeError!Enum {
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

        pub fn fromString(str: []const u8) ?Tag {
            return name_map.get(str);
        }

        const name_map: std.StaticStringMap(Type) = .initComptime( make: {
            const types = std.enums.values(Type);
            var list: [types.len]struct { []const u8, Type } = undefined;
            for (&list, types) |*kvs, @"type"| kvs.* = .{ @tagName(@"type", @"type" };
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

        fn finalize(parsing: Parsing) error{MissingAttribute}!Entry {
            return .{
                .name = parsing.name orelse return error.MissingAttribute,
                .value = parsing.value orelse return error.MissingAttribute,
                .summary = parsing.summary,
            };
        }
    };
};

fn validateStartTag(scanner: *Scanner, tag: Tag) !void {
    const top: ?Tag = scanner.tag_stack.getLastOrNull();
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
        .request, .event, .@"enum", .description => {
            if (top != .interface) {
                scanner.source_invalid_err = .interface_child_not;
                return error.InvalidWaylandXML;
            }
        },
        .arg => {
            if (top != .request or top != .event) {
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

/// Integer type of parsed version strings
pub const VersionNumber = u8;

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
};

const Scanner = @This();

const ByteArrayList = std.ArrayList(u8);
const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mem = std.mem;
const fmt = std.fmt;
const log = std.log;

const std = @import("std");
