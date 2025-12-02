//! This module parses Wayland protocol XML into Zig source.

/// A file path argument to this executable with this prefix
/// will be written to as the output sink.
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
            .leak => log.warn("memory leaks(s) detected during Wayland XML parsing"),
        },
        else => {},
    };

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    const in_file_list: std.ArrayList([:0]const u8) = .empty;
    var out_file_path: ?[:0]const u8 = null;
    defer in_file_list.deinit(allocator);
    var arg_iterator: std.process.ArgIterator = try .initWithAllocator(allocator);
    defer arg_iterator.deinit();
    while (arg_iterator.next()) |arg| {
        const o = output_arg_prefix;
        if (arg.len > o.len and mem.eql(u8, o, arg[0..o.len])) {
            if (out_file_path == null) out_file_path = arg[o.len..];
        } else {
            try in_file_list.append(allocator, arg);
        }
    }
    if (in_file_list.items.len == 0) return;

    const cwd = std.fs.Dir.cwd();

    const out_file: std.fs.File =
        if (out_file_path) |path| cwd.openFile(path, .{ .mode = .write_only})
            catch return error.OutputFileOpenFailure
        else .stdout();
    var writer = out_file.writer(&write_buffer);
    defer { if (out_file_path) |_| out_file.close(io); }

    var parser: Parser = try .init(allocator);
    defer parser.deinit(allocator);

    for (in_file_list.items) |path| {
        read_buffer = undefined;

        const file = try cwd.openFile(path, .{ .mode = .read_only });
        defer file.close();

        var reader = file.reader(io, &read_buffer);
        parser.newStream();
        parser.stream(&out_writer.interface, &reader.interface, allocator) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.WriteFailed => return writer.seek_error.?,
            error.ReadFailed => log.err("{t} while reading {s}", .{ reader.seek_error.?, path }),
            error.InvalidWaylandXML => |e| log.err(
                "{t}: {s}:{d}:{d}: {s}",
                .{ e, path, parser.line, parser.column, parser.source_invalid_err.?.explain() },
            ),
        };
    }

    writer.interface.flush() catch return writer.seek_error.?;
}

const Parser = struct {
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

        pub const initial: State = .plaintext;
    };

    pub const SourceInvalidError = enum {
        broken_tag,

        pub fn explain(err: SourceInvalidError) [:0]const u8 {
            return switch (err) {
                .broken_tag => "expected \'>'\' or \'/>\', found EOF",
            };
        }
    };

    pub const Error = error{ WriteFailed, ReadFailed, InvalidWaylandXML } || Allocator.Error;

    tag_name_buffer: ByteArrayList,
    attribute_name_buffer: ByteArrayList,
    attribute_value_buffer: ByteArrayList,
    description_buffer: ByteArrayList,
    last_byte: ?u8,
    line: u32,
    column: u32,
    source_invalid_err: ?SourceInvalidError,

    pub fn init(allocator: Allocator) Allocator.Error!Parser {
        return .{
            .tag_name_buffer = try .initCapacity(allocator, 64),
            .attribute_name_buffer = try .initCapacity(allocator, 64),
            .attribute_value_buffer = try .initCapacity(allocator, 128),
            .description_buffer = try .initCapacity(allocator, 512),
            .last_byte = undefined,
            .line = undefined,
            .column = undefined,
            .source_invalid_err = null,
        };
    }

    pub fn deinit(parser: *Parser, allocator: Allocator) void {
        parser.description_buffer.deinit(allocator);
        parser.attribute_value_buffer.deinit(allocator);
        parser.attribute_name_buffer.deinit(allocator);
        parser.tag_name_buffer.deinit(allocator);
        parser.* = undefined;
    }

    pub fn newStream(parser: *Parser) void {
        parser.tag_name_buffer.clearRetainingCapacity();
        parser.attribute_name_buffer.clearRetainingCapacity();
        parser.attribute_value_buffer.clearRetainingCapacity();
        parser.description_buffer.clearRetainingCapacity();
        parser.last_byte = null;
        parser.line = 0;
        parser.column = 0;
    }

    pub fn stream(parser: *Parser, writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) Error!void {
        parse: switch (State.initial) {
            .plaintext => {
                const char = try parser.nextByte(reader) orelse return;
                if (char == '<') {
                    assert(parser.tag_name_buffer.items.len == 0);
                    continue :parse .tag_name;
                } else {
                    continue :parse .plaintext;
                }
            },

            .tag_name => {
                if (try parser.nextByte(reader)) |char| {
                    if (parser.last_byte == '/' and char != '>') {
                        parser.source_invalid_err = .unexpected_character;
                        return error.InvalidWaylandXML;
                    }
                    switch (char) {
                        '<' => {
                            parser.source_invalid_err = .unexpected_character;
                            return error.InvalidWaylandXML;
                        },

                        '/' => {
                            if (parser.last_byte == '<') {
                                assert(parser.tag_name_buffer.items.len == 0);
                                continue :parse .end_tag;
                            } else {
                                continue :parse .tag_name;
                            }
                        },

                        '>' => {
                            if (parser.tag_name_buffer.items.len == 0) {
                                parser.source_invalid_err = .empty_tag_name;
                                return error.InvalidWaylandXML;
                            }

                            if (parser.last_byte == '/') {
                                try parser.pushEmptyElement(writer);
                                continue :parse .plaintext;
                            } else {
                                try parser.pushStartElement(writer);
                                if (parser.wantsStartDescription()) {
                                    assert(parser.description_buffer.items.len == 0);
                                    continue :parse .text;
                                } else {
                                    continue :parse .plaintext;
                                }
                            }
                        },

                        ' ', '\t', '\n', '\r',
                        std.ascii.control_code.vt,
                        std.ascii.control_code.ff => {
                            if (parser.tag_name_buffer.items.len == 0) {
                                continue :parse .tag_name;
                            } else {
                                assert(parser.attribute_name_buffer.items.len == 0);
                                continue :parse .attribute_name;
                            }
                        },

                        else => |c| {
                            try parser.tag_name_buffer.append(allocator, c);
                            continue :parse .tag_name;
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },

            .end_tag => {
                if (try parser.nextByte(reader)) |char| {
                    switch (char) {
                        ' ', '\t', '\n', '\r',
                        std.ascii.control_code.vt,
                        std.ascii.control_code.ff => continue :parse .end_tag,

                        else => |c| {
                            try parser.tag_name_buffer.append(allocator, c);
                            continue :parse .end_tag;
                        },

                        '>' => {
                            if (parser.tag_name_buffer.items.len == 0) {
                                parser.source_invalid_err = .empty_tag_name;
                                return error.InvalidWaylandXML;
                            } else {
                                try parser.pushEndElement(writer);
                                continue :parse .plaintext;
                            }
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },

            .attribute_name => {
                if (try parser.nextByte(reader)) |char| {
                    switch (char) {
                        '<' => {
                            parser.source_invalid_err = .unexpected_character;
                            return error.InvalidWaylandXML;
                        },

                        '/' => {
                            if (parser.attribute_name_buffer.items.len == 0) {
                                continue :parse .tag_name;
                            } else {
                                parser.source_invalid_err = .unexpected_character;
                                return error.InvalidWaylandXML;
                            }
                        },

                        '>' => {
                            if (parser.attribute_name_buffer.items.len != 0) {
                                parser.source_invalid_err = .unvalued_attribute;
                                return error.InvalidWaylandXML;
                            }

                            if (parser.tag_name_buffer.items.len == 0) {
                                parser.source_invalid_err = .empty_tag_name;
                            }

                            if (parser.last_byte == '/') {
                                try parser.pushEmptyElement(writer);
                                continue :parse .plaintext;
                            } else {
                                try parser.pushStartElement(writer);
                                if (parser.wantsStartDescription()) {
                                    assert(parser.description_buffer.items.len == 0);
                                    continue :parse .text;
                                } else {
                                    continue :parse .plaintext;
                                }
                            }
                        },

                        ' ', '\t', '\n', '\r',
                        std.ascii.control_code.vt,
                        std.ascii.control_code.ff => continue :parse .attribute_name,

                        '=' => {
                            if (parser.attribute_name_buffer.items.len == 0) {
                                parser.source_invalid_err = .unexpected_character;
                                return error.InvalidWaylandXML;
                            } else {
                                try parser.pushAttribute(writer);
                                continue :parse .attribute_sep;
                            }
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },

            .attribute_sep => {
                if (try parser.nextByte(reader)) |char| {
                    switch (char) {
                        ' ', '\t', '\n', '\r',
                        std.ascii.control_code.vt,
                        std.ascii.control_code.ff => continue :parse .attribute_sep,
                        '"' => {
                            assert(parser.attribute_value_buffer.items.len == 0);
                            continue :parse .attribute_value;
                        },
                        else => {
                            parser.source_invalid_err = .unexpected_character;
                            return error.InvalidWaylandXML;
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },

            .attribute_value => {
                if (try parser.nextByte(reader)) |char| {
                    switch (char) {
                        else => |c| {
                            try parser.attribute_value_buffer.append(allocator, c);
                            continue :parse .attribute_value;
                        },

                        '"' => {
                            try parser.pushAttributeValue(writer);
                            continue :parse .attribute_name;
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },

            .text => {
                if (try parser.nextByte(reader)) |char| {
                    switch (char) {
                        else => |c| {
                            try parser.description_buffer.append(allocator, c);
                            continue :parse .text;
                        },

                        '<' => {
                            try parser.pushDescription(writer);
                            continue :parse .tag_name;
                        },
                    }
                } else {
                    parser.source_invalid_err = .broken_tag;
                    return error.InvalidWaylandXML;
                }
            },
        }
        unreachable;
    }

    fn nextByte(parser: *Parser, reader: *Io.Reader) !?u8 {
        const byte = reader.takeByte() catch |err| return switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => |e| e,
        };
        defer parser.last_byte = byte;

        if ( isNewline(byte, parser.last_byte) ) {
            parser.column = 0;
            parser.line += 1;
        } else {
            parser.column += 1;
        }

        return byte;
    }

    fn pushEmptyElement(parser: *Parser, writer: *Io.Writer) !void {
        // An empty element tag ('<tagname/>')
        // TODO check for other buffers empty or return parse invalid
    }

    fn wantsStartDescription(parser: Parser) bool {
    }
};

fn isNewline(char: u8, last_char: u8) bool {
    return char=='\r' or ( char=='\n' and last_char!='\r' );
}

const ByteArrayList = std.ArrayList(u8);
const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mem = std.mem;
const log = std.log;

const std = @import("std");
