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
            error.OutOfMemory => |e| return e,
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
            error.OutOfMemory => |e| return e,
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
    forward_slash_in_attribute_name,
    double_open_bracket,
    invalid_before_attribute_value,
    equals_before_attribute_name,
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
            .forward_slash_in_attribute_name => logFn(
                "{s}:{d}:{d}: invalid character \'/\' in attribute name",
                .{ file_path, scanner.line, scanner.column },
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
        }
    } else {
        logFn(
            "{s}:{d}:{d}: unspecified error (seeing this is a scanner bug)",
            .{ file_path, scanner.line, scanner.column },
        );
    }
}

pub const Error = error{ WriteFailed, ReadFailed, InvalidWaylandXML } || Allocator.Error;

tag_name_buffer: ByteArrayList,
attribute_name_buffer: ByteArrayList,
attribute_value_buffer: ByteArrayList,
text_literal_buffer: ByteArrayList,
last_opening_was_literal_text_tag: bool,
last_byte: ?u8,
line: u32,
column: u32,
source_invalid_err: ?SourceInvalidError,

pub fn init(allocator: Allocator) Allocator.Error!Scanner {
    return .{
        .tag_name_buffer = try .initCapacity(allocator, 64),
        .attribute_name_buffer = try .initCapacity(allocator, 64),
        .attribute_value_buffer = try .initCapacity(allocator, 128),
        .text_literal_buffer = try .initCapacity(allocator, 512),
        .last_opening_was_literal_text_tag = undefined,
        .last_byte = undefined,
        .line = undefined,
        .column = undefined,
        .source_invalid_err = null,
    };
}

pub fn deinit(scanner: *Scanner, allocator: Allocator) void {
    scanner.text_literal_buffer.deinit(allocator);
    scanner.attribute_value_buffer.deinit(allocator);
    scanner.attribute_name_buffer.deinit(allocator);
    scanner.tag_name_buffer.deinit(allocator);
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
    scanner.last_opening_was_literal_text_tag = false;
    scanner.last_byte = null;
    scanner.line = 0;
    scanner.column = 0;
}

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
};

/// Parses `reader` until EOF,
/// writing completed sections to `writer` as they are parsed.
pub fn stream(scanner: *Scanner, writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) Error!void {
    parse: switch (State.plaintext) {
        .plaintext => {
            const char = try scanner.nextByte(reader) orelse return;
            defer scanner.last_byte = char;
            if (char == '<') {
                assert(scanner.tag_name_buffer.items.len == 0);
                continue :parse .tag_name;
            } else {
                continue :parse .plaintext;
            }
        },

        .tag_name => {
            if (try scanner.nextByte(reader)) |char| {
                defer scanner.last_byte = char;
                if (scanner.last_byte == '/' and char != '>') {
                    scanner.source_invalid_err = .invalid_forward_slash;
                    return error.InvalidWaylandXML;
                }
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
                defer scanner.last_byte = char;
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
                defer scanner.last_byte = char;
                switch (char) {
                    '<' => {
                        scanner.source_invalid_err = .double_open_bracket;
                        return error.InvalidWaylandXML;
                    },

                    '/' => {
                        if (scanner.attribute_name_buffer.items.len == 0) {
                            continue :parse .tag_name;
                        } else {
                            scanner.source_invalid_err = .forward_slash_in_attribute_name;
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
                            try scanner.pushAttribute(writer);
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
                defer scanner.last_byte = char;
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
                defer scanner.last_byte = char;
                switch (char) {
                    else => |c| {
                        try scanner.attribute_value_buffer.append(allocator, c);
                        continue :parse .attribute_value;
                    },

                    '"' => {
                        try scanner.pushAttributeValue(writer);
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
                defer scanner.last_byte = char;
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
    scanner.tag_name_buffer.clearRetainingCapacity();
}

/// A beginning element tag ('<TAGNAME>')
fn pushStartElement(scanner: *Scanner, writer: *Io.Writer) !void {
    //scanner.last_opening_was_literal_text_tag = mem.eql(u8,
    //    "description",
    //    scanner.tag_name_buffer.items,
    //);
    scanner.last_opening_was_literal_text_tag =
        for (literal_text_tags) |tag_name| {
            if (mem.eql(u8, tag_name, scanner.tag_name_buffer.items)) break true;
        } else false;

    // TODO
    try writer.print("<{s}>\n", .{ scanner.tag_name_buffer.items });
    scanner.tag_name_buffer.clearRetainingCapacity();
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
fn pushAttribute(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("{s}=", .{ scanner.attribute_name_buffer.items });
    scanner.attribute_name_buffer.clearRetainingCapacity();
}

/// A tag attribute value (VALUE of '<TAGNAME ATTRIBUTE="VALUE"'(/)>)
fn pushAttributeValue(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("\"{s}\"\n", .{ scanner.attribute_value_buffer.items });
    scanner.attribute_value_buffer.clearRetainingCapacity();
}

fn pushLiteralText(scanner: *Scanner, writer: *Io.Writer) !void {
    // TODO
    try writer.print("literal text: \"{s}\"\n", .{ scanner.text_literal_buffer.items });
    scanner.text_literal_buffer.clearRetainingCapacity();
}

fn isNewline(char: u8, last_char: u8) bool {
    return char=='\r' or ( char=='\n' and last_char!='\r' );
}

const Scanner = @This();

const ByteArrayList = std.ArrayList(u8);
const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mem = std.mem;
const log = std.log;

const std = @import("std");
