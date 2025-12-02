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

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;

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
    var output_writer = out_file.writer(&stdout_buffer);
    defer { if (out_file_path) |_| out_file.close(io); }

    var parser: Parser = try .init(allocator);
    defer parser.deinit(allocator);

    for (in_file_list.items) |path| {
        stdin_buffer = undefined;

        const file = try cwd.openFile(path, .{ .mode = .read_only });
        defer file.close();

        var in_reader = file.reader(io, &stdin_buffer);
        parser.newStream();
        parser.stream(&output_writer.interface, &in_reader.interface, allocator) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.WriteFailed => return output_writer.seek_error.?,
            error.ReadFailed => log.err("{t} while reading {s}", .{ in_reader.seek_error.?, path }),
            error.InvalidWaylandXML => |e| log.err(
                "{t}: {s}:{d}:{d}: {s}",
                .{ e, path, parser.line, parser.column, parser.source_invalid_err.?.explain() },
            ),
        };
    }

    output_writer.interface.flush() catch return output_writer.seek_error.?;
}

const Parser = struct {
    const State = enum {
        /// Plain text outside of any tags
        plaintext,
        tag_name,
        attribute_name,
        attribute_value,
        end_tag,
        /// Literal text content (i.e. within a '<description> ...')
        text,

        pub const initial: State = .plaintext;
    };

    pub const SourceInvalidError = enum {
        unexpected_eof,

        pub fn explain(err: SourceInvalidError) [:0]const u8 {
            return switch (err) {
                .unexpected_eof => "TODO",
            };
        }
    };

    pub const Error = error{ WriteFailed, ReadFailed, InvalidWaylandXML } || Allocator.Error;

    token_buffer: ByteArrayList,
    last_byte: ?u8,
    line: u32,
    column: u32,
    source_invalid_err: ?SourceInvalidError,

    pub fn init(allocator: Allocator) Allocator.Error!Parser {
        return .{
            .token_buffer = try .initCapacity(allocator, 512),
            .last_byte = null,
            .line = 0,
            .column = 0,
            .source_invalid_err = null,
        };
    }

    pub fn deinit(parser: *Parser, allocator: Allocator) void {
        parser.token_buffer.deinit(allocator);
        parser.* = undefined;
    }

    pub fn newStream(parser: *Parser) void {
        parser.token_buffer.clearRetainingCapacity();
        parser.last_byte = null;
        parser.line = 0;
        parser.column = 0;
    }

    pub fn stream(parser: *Parser, writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator) Error!void {
        parse: switch (State.initial) {
            .plaintext => {
                const char = try parser.nextByte(reader) orelse return;
                if (char == '<') {
                    continue :parse .tag_name;
                } else {
                    continue :parse .plaintext;
                }
            },

            .tag_name => {
                if (try parser.nextByte(reader)) |char| {
                } else {
                    parser.source_invalid_err = .{
                        .issue = .unexpected_eof,
                    };
                    return error.InvalidWaylandXML;
                }
            },
        }
        unreachable;
    }

    pub fn nextByte(parser: *Parser, reader: *Io.Reader) !?u8 {
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
};

fn isNewline(char: u8, last_char: u8) bool {
    return char=='\r' or ( char=='\n' and last_char!='\r' );
}

fn isWhitespace(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r',
        std.ascii.control_code.vt,
        std.ascii.control_code.ff => return true,
        else => return false,
    };
}

const ByteArrayList = std.ArrayList(u8);

const Io = std.Io;
const Allocator = std.mem.Allocator;

const mem = std.mem;
const log = std.log;

const std = @import("std");
