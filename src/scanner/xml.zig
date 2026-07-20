/// Validation-light XML parsing for a generic schema.
/// Simple scanning through opening tags, closing tags, attributes, and skipping comments and whitespace.
/// Helper functions for printing parse trees as Zig source.
///
/// Disallows comments within literal text sections.
const xml_parsing = @This();

pub const ParseError = error{
    /// A tag name, attribute token, or literal text section could not fit
    /// in the reader's buffer.
    StreamTooLong,
    /// Encountered an unexpected character where a delimiter was required.
    /// E.g., when `'/'` is the first byte of the next token inside of a tag,
    /// the next byte after any amount of whitespace must be `'>'`.
    XmlInvalid,
    /// Encountered a tag name or attribute not specified as possible at that node,
    /// or an attribute value that does not fit the specified attribute type,
    /// or an attribute declared twice,
    /// or a tag was missing non-optional attributes.
    SchemaViolation,
    /// Encountered end of stream while expecting more tokens
    /// (source incomplete).
    EndOfStream,
} || Io.Reader.Error || Allocator.Error;

/// Returns error if the reader seek lies at a byte order mark
/// and it marks an unsupported encoding.
pub fn tryPeekBom(reader: *Io.Reader) (error{UnsupportedEncoding} || Io.Reader.Error)!void {
    const bom: [2]u8 = (try reader.peekArray(2)).*;
    if (mem.eql(u8, &bom, &.{ 0xFF, 0xFE })) {
        log.err("encountered BOM 0xFFFE (UTF-16 Little Endian)", .{});
        return error.UnsupportedEncoding;
    }
    if (mem.eql(u8, &bom, &.{ 0xFE, 0xFF })) {
        log.err("encountered BOM 0xFEFF (UTF-16 Big Endian)", .{});
        return error.UnsupportedEncoding;
    }
    // Third possibility is 0xEFBBBF (UTF-8), which is assumed.
}

/// Returns an iterator which returns the text block line by line,
/// with leading and trailing whitespace trimmed from each.
pub fn splitTextLines(text: []const u8) TextLineIterator {
    return .init(text);
}

pub const TextLineIterator = struct {
    inner: mem.TokenIterator(u8, .any),

    pub fn init(text: []const u8) TextLineIterator {
        return .{ .inner = .{
            .buffer = text,
            .delimiter = &.{ '\n', '\r' },
            .index = 0,
        } };
    }

    pub fn next(iter: *TextLineIterator) ?[]const u8 {
        const full_line = iter.inner.next() orelse return null;
        return mem.trim(u8, full_line, &ascii.whitespace);
    }
};

/// Advance seek to point to the next `'<'` that is not the start of a comment.
pub fn discardPlaintext(reader: *Io.Reader) Io.Reader.Error!void {
    while (cont: {
        const was_plaintext = ( try reader.discardDelimiterExclusive('<') ) > 0;
        const was_empty_text = try discardEmptyText(reader);
        break :cont was_plaintext or was_empty_text;
    }) {}
}

pub fn isValidZigIdentifier(str: []const u8) bool {
    if (std.zig.Token.keywords.get(str)) |_| return false;
    return str.len >= 1 and
        ( ascii.isLower(str[0]) or str[0] == '_' ) and
        ( for (str[1..]) |c| {
            switch (c) {
                '0'...'9', 'a'...'z', '_' => {},
                else => break false,
            }
        } else true )
    ;
}

/// If the `str` is an invalid Zig identifier,
/// allocates and returns `"@\"" ++ str ++ "\""`.
pub fn decollideIdentifier(arena: Allocator, str: []const u8) (error{EmptyValue} || Allocator.Error)![]const u8 {
    if (str.len == 0) return error.EmptyValue;
    if (isValidZigIdentifier(str)) return str;
    const buf = try arena.alloc(u8, str.len + 3);
    buf[0..2].* = "@\"".*;
    @memcpy(buf[2..][0..str.len], str);
    buf[buf.len-1] = '"';
    return buf;
}

pub fn decollideIdentifierNonempty(arena: Allocator, str: []const u8) Allocator.Error![]const u8 {
    const id = decollideIdentifier(arena, str) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.EmptyValue => unreachable,
    };
    return id;
}

// TODO could be an {f} wrapper
pub fn caseSnakeToPascal(gpa: Allocator, str: []const u8) Allocator.Error![]const u8 {
    const pascal_len = str.len - count: {
        var count: usize = 0;
        for (str) |c| {
            if (c == '_') count += 1;
        }
        break :count count;
    };
    const pascal = try gpa.alloc(u8, pascal_len);
    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    while (dst_idx < pascal.len) {
        if (str[src_idx] != '_') {
            pascal[dst_idx] =
                if (src_idx == 0 or str[src_idx-1] == '_')
                    ascii.toUpper(str[src_idx])
                else
                    str[src_idx];
            dst_idx += 1;
        }
        src_idx += 1;
    }
    return pascal;
}

/// Assumes the reader seek begins in plaintext
/// (will seek forward to the first `'<'`).
///
/// Takes any of the `possible_schema` as a valid next tag,
/// and returns a tagged union containing the parsed result.
///
/// A general-purpose allocator is needed
/// to buffer space for dynamic numbers of child nodes,
/// as well as allocate the returned parse tree.
/// The caller takes ownership of the returned parse tree.
/// The returned parse tree can be freed with `freeNode` or `freeNodeUnion`.
pub fn takeNode(
    gpa: Allocator,
    reader: *Io.Reader,
    comptime possible_schema: []const Schema,
) ParseError!Schema.ParsedUnion(possible_schema) {
    if (possible_schema.len == 0) @compileError("expected 1 or more possible schema");

    try discardPlaintext(reader);
    if (( try reader.takeByte() ) != '<') unreachable;

    const tag_name: []const u8 = try peekAnyDelimiterExclusive(reader, &([2]u8{ '>', '/' } ++ ascii.whitespace));
    reader.toss(tag_name.len);
    if (mem.eql(u8, "?xml", tag_name)) {
        try takeDeclaration(gpa, reader);
        return takeNode(gpa, reader, possible_schema);
    }
    inline for (possible_schema) |schema| {
        if (mem.eql(u8, schema.tag_name, tag_name)) {
            const parsed = try parseNodeAtAttrs(gpa, reader, schema);
            return @unionInit(Schema.ParsedUnion(possible_schema), schema.tag_name, parsed);
        }
    }

    log.err("unexpected tag name: \"{s}\"", .{ tag_name });
    for (possible_schema) |schema| log.info("expected possible tag name: \"{s}\"", .{ schema.tag_name });
    return error.SchemaViolation;
}

/// Assumes the reader seek points to immediately after the tag name.
fn parseNodeAtAttrs(
    gpa: Allocator,
    reader: *Io.Reader,
    comptime schema: Schema,
) ParseError!schema.Parsed() {
    var parsing: schema.Parsing() = undefined;
    try schema.parsingInit(gpa, &parsing);
    errdefer schema.parsingDeinit(gpa, &parsing);

    // Repeatedly seek to the next token
    // as long as that next token is not the tag close.
    var tag_close: TagClose = undefined;
    while (cont: {
        if (try tryTakeTagClose(reader, '/')) |close| {
            tag_close = close;
            break :cont false;
        } else {
            break :cont true;
        }
    }) {
        const attr_name: []const u8 = try takeAndDupeAttrName(gpa, reader);
        defer gpa.free(attr_name);
        const attr_value: []const u8 = try takeAttrValue(reader);
        try schema.parsingAddAttribute(gpa, &parsing, attr_name, attr_value);
    }
    try schema.parsingValidateAttrs(parsing);

    switch (tag_close) {
        .self_close => {
            // If self-closing, we have finished parsing this node.
            // If there is a content field, its initial value is equivalent to no content.
        },
        .close => {
            if (comptime schema.parsingDynamicChildren()) {
                while (cont: {
                    _ = try reader.discardDelimiterExclusive('<');
                    // Break the loop if seek points at "</"...
                    const tag_is_closing = try tagIsClosing(reader);
                    break :cont !tag_is_closing;
                }) {
                    const child_node = try takeNode(gpa, reader, schema.content.child_nodes);
                    try schema.parsingAddChild(gpa, &parsing, child_node);
                }
                try checkDiscardTagClose(reader, schema.tag_name);
            } else if (schema.content == .literal_text) {
                // Would need to modify this block if comments are allowed in literal text.
                // accumulate chunks of literal text in an ArrayList(u8),
                // delimited by comments,
                // and detect the difference between a comment and the closing block of this tag
                const text = try reader.takeDelimiterExclusive('<');
                try schema.parsingAddLiteralText(gpa, &parsing, text);
                try checkDiscardTagClose(reader, schema.tag_name);
            } else {
                @field(parsing, Schema.content_field_name) = {};
                _ = try reader.discardDelimiterExclusive('<');
                try checkDiscardTagClose(reader, schema.tag_name);
            }
        },
    }

    const parsed = try schema.parsingToParsed(gpa, &parsing);
    return parsed;
}

fn takeDeclaration(gpa: Allocator, reader: *Io.Reader) ParseError!void {
    var tag_close: TagClose = undefined;
    while (cont: {
        if (try tryTakeTagClose(reader, '?')) |close| {
            tag_close = close;
            break :cont false;
        } else {
            break :cont true;
        }
    }) {
        gpa.free(try takeAndDupeAttrName(gpa, reader));
        _ = try takeAttrValue(reader);
        // TODO check for encoding = UTF-8
    }
    switch (tag_close) {
        .self_close => {},
        .close => {
            log.err("expected \"<?xml>\" declaration to end in \"?>\"", .{});
            return error.XmlInvalid;
        },
    }
}

pub fn freeNode(
    gpa: Allocator,
    comptime schema: Schema,
    node: schema.Parsed(),
) void {
    if (comptime schema.parsingDynamicChildren()) {
        // Deinit the child nodes in the slice, then the slice itself
        var child_iter = mem.reverseIterator(@field(node, Schema.content_field_name));
        while (child_iter.next()) |child| freeNodeUnion(gpa, schema.content.child_nodes, child);
        gpa.free(@field(node, Schema.content_field_name));
    } else if (schema.content == .literal_text) {
        if (@field(node, Schema.content_field_name).len != 0) {
            gpa.free(@field(node, Schema.content_field_name));
        }
    } else {
        if (@FieldType(schema.Parsed(), Schema.content_field_name) != void) comptime unreachable;
    }

    const reverse_attrs = comptime rev: {
        var attrs: [schema.attributes.len]Schema.Attribute = undefined;
        @memcpy(&attrs, schema.attributes);
        mem.reverse(Schema.Attribute, &attrs);
        break :rev attrs;
    };
    inline for (reverse_attrs) |attr| {
        switch (attr.value) {
            .string => {
                if (attr.optional) {
                    if (@field(node, attr.name)) |string| gpa.free(string);
                } else {
                    gpa.free(@field(node, attr.name));
                }
            },
            .int => {},
            .@"enum" => {},
        }
    }
}

pub fn freeNodeUnion(
    gpa: Allocator,
    comptime possible_schema: []const Schema,
    node_union: Schema.ParsedUnion(possible_schema),
) void {
    switch (node_union) {
        inline else => |node, tag| {
            const schema_name = @tagName(tag);
            const schema: Schema = comptime for (possible_schema) |s| {
                if (mem.eql(u8, schema_name, s.tag_name)) break s;
            } else unreachable;
            freeNode(gpa, schema, node);
        },
    }
}

pub const Schema = struct {
    tag_name: []const u8,
    attributes: []const Attribute = &.{},
    content: union(enum) {
        child_nodes: []const Schema,
        literal_text: void,
    } = .{ .child_nodes = &.{} },
    /// Hint for how many child nodes to initially buffer space for,
    /// if `.content == .child_nodes and .content.child_nodes.len != 0`.
    init_child_capacity: usize = 8,

    const content_field_name = "content";

    pub const Attribute = struct {
        name: []const u8,
        value: Value,
        optional: bool = false,

        pub const Value = union(enum) {
            string,
            int: Type.Int,
            @"enum": []const []const u8,

            pub fn ToField(comptime attr: Value) type {
                switch (attr) {
                    .string => return []const u8,
                    .int => |int| return @Int(int.signedness, int.bits),
                    .@"enum" => |@"enum"| {
                        const Tag = std.math.IntFittingRange(0, @"enum".len);
                        const names: []const []const u8 = @"enum";
                        var values: [names.len]Tag = undefined;
                        for (&values, 0..) |*value, i| value.* = @intCast(i);
                        return @Enum(Tag, .exhaustive, names, &values);
                    },
                }
            }

            pub fn parse(
                comptime attr: Value,
                gpa: Allocator,
                raw: []const u8,
            ) (error{SchemaViolation} || Allocator.Error)!attr.ToField() {
                switch (attr) {
                    .string => {
                        const val = try gpa.dupe(u8, raw);
                        return val;
                    },
                    .int => {
                        const Int = attr.ToField();
                        if (std.fmt.parseInt(Int, raw, 0)) |val| {
                            return val;
                        } else |err| {
                            log.err("{t} parsing attribute value \"{s}\" to {s}", .{ err, raw, @typeName(Int) });
                            return error.SchemaViolation;
                        }
                    },
                    .@"enum" => {
                        const Enum = attr.ToField();
                        if (std.meta.stringToEnum(Enum, raw)) |val| {
                            return val;
                        } else {
                            log.err("invalid enum attribute value \"{s}\"", .{ raw });
                            for (std.enums.values(Enum)) |possible| log.info("expected attribute value: \"{t}\"", .{ possible });
                            return error.SchemaViolation;
                        }
                    },
                }
            }
        };
    };

    pub fn Parsed(comptime schema: Schema) type {
        const field_len = schema.attributes.len + 1;
        var names: [field_len][]const u8 = undefined;
        var types: [field_len]type = undefined;
        const attrs: [field_len]Type.StructField.Attributes = @splat(.{});
        for (schema.attributes, names[0..names.len-1], types[0..types.len-1]) |attribute, *name, *@"type"| {
            if (mem.eql(u8, content_field_name, attribute.name)) {
                @compileError(std.fmt.comptimePrint(
                    "tag \"{s}\" has attribute name conflict with node content field name \"{s}\"",
                    .{ schema.tag_name, content_field_name },
                ));
            }
            name.* = attribute.name;
            const Field = attribute.value.ToField();
            @"type".* = if (attribute.optional) ?Field else Field;
        }
        names[names.len-1] = content_field_name;
        types[types.len-1] = switch (schema.content) {
            .child_nodes => |possible_children|
                if (possible_children.len == 0)
                    void
                else
                    []const ParsedUnion(possible_children),
            .literal_text => []const u8,
        };
        return @Struct(
            .auto,
            null,
            &names,
            &types,
            &attrs,
        );
    }

    pub fn ParsedUnion(comptime possible_schema: []const Schema) type {
        if (possible_schema.len == 0) return void;
        const TagInt = std.math.IntFittingRange(0, possible_schema.len);
        var names: [possible_schema.len][]const u8 = undefined;
        var types: [possible_schema.len]type = undefined;
        var tags: [possible_schema.len]TagInt = undefined;
        const attrs: [possible_schema.len]Type.UnionField.Attributes = @splat(.{});
        for (possible_schema, &names, &types, &tags, 0..) |schema, *name, *@"type", *tag, i| {
            name.* = schema.tag_name;
            @"type".* = schema.Parsed();
            tag.* = @intCast(i);
        }
        return @Union(
            .auto,
            @Enum(TagInt, .exhaustive, &names, &tags),
            &names,
            &types,
            &attrs,
        );
    }

    fn Parsing(comptime schema: Schema) type {
        const field_len = schema.attributes.len + 1;
        var names: [field_len][]const u8 = undefined;
        var types: [field_len]type = undefined;
        const attrs: [field_len]Type.StructField.Attributes = @splat(.{});
        for (schema.attributes, names[0..names.len-1], types[0..types.len-1]) |attribute, *name, *@"type"| {
            name.* = attribute.name;
            const Field = attribute.value.ToField();
            @"type".* = ?Field;
        }
        names[names.len-1] = content_field_name;
        types[types.len-1] = switch (schema.content) {
            .child_nodes => |possible_children|
                if (possible_children.len == 0)
                    void
                else
                    ArrayList(ParsedUnion(possible_children)),
            .literal_text => []const u8,
        };
        return @Struct(
            .auto,
            null,
            &names,
            &types,
            &attrs,
        );
    }

    fn parsingDynamicChildren(comptime schema: Schema) bool {
        return switch (schema.content) {
            .child_nodes => |possible_children| possible_children.len != 0,
            .literal_text => false,
        };
    }

    fn parsingInit(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
    ) Allocator.Error!void {
        inline for (schema.attributes) |attr| @field(parsing, attr.name) = null;
        if (comptime schema.parsingDynamicChildren()) {
            @field(parsing, content_field_name) = try .initCapacity(gpa, schema.init_child_capacity);
        } else if (schema.content == .literal_text) {
            @field(parsing, content_field_name) = @as([]const u8, &.{});
        } else {
            @field(parsing, content_field_name) = {};
        }
    }

    fn parsingDeinit(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
    ) void {
        if (comptime schema.parsingDynamicChildren()) {
            // Deinit the child nodes in the ArrayList, and then the ArrayList itself
            var child_iter = mem.reverseIterator(@field(parsing, content_field_name).items);
            while (child_iter.next()) |child| freeNodeUnion(gpa, schema.content.child_nodes, child);
            @field(parsing, content_field_name).deinit(gpa);
        } else if (schema.content == .literal_text) {
            if (@field(parsing, content_field_name).len != 0) {
                gpa.free(@field(parsing, content_field_name));
            }
        } else {
            if (@FieldType(schema.Parsing(), content_field_name) != void) comptime unreachable;
        }

        const reverse_attrs = comptime rev: {
            var attrs: [schema.attributes.len]Attribute = undefined;
            @memcpy(&attrs, schema.attributes);
            mem.reverse(Attribute, &attrs);
            break :rev attrs;
        };
        inline for (reverse_attrs) |attr| {
            switch (attr.value) {
                .string => if (@field(parsing, attr.name)) |string| gpa.free(string),
                .int => {},
                .@"enum" => {},
            }
        }

        parsing.* = undefined;
    }

    fn parsingValidateAttrs(comptime schema: Schema, parsing: schema.Parsing()) (error{SchemaViolation})!void {
        var missing: bool = false;
        inline for (schema.attributes) |attr| {
            if (!attr.optional) {
                if (@field(parsing, attr.name) == null) {
                    log.err("\"{s}\" attribute \"{s}\" is non-optional and missing from tag", .{ schema.tag_name, attr.name });
                    missing = true;
                }
            }
        }
        if (missing) return error.SchemaViolation;
    }

    fn parsingAddAttribute(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
        name: []const u8,
        value: []const u8,
    ) (error{SchemaViolation} || Allocator.Error)!void {
        inline for (schema.attributes) |attr| {
            if (mem.eql(u8, attr.name, name)) {
                if (@field(parsing, attr.name) != null) {
                    log.err("\"{s}\" attribute \"{s}\" invalidly appears twice", .{ schema.tag_name, attr.name });
                    return error.SchemaViolation;
                }
                if (attr.value.parse(gpa, value)) |val| {
                    @field(parsing, attr.name) = val;
                    return;
                } else |err| {
                    switch (err) {
                        error.SchemaViolation => log.err("invalid \"{s}\" attribute \"{s}\" value: \"{s}\"", .{ schema.tag_name, attr.name, value }),
                        error.OutOfMemory => {},
                    }
                    return err;
                }
            }
        }
        log.err("invalid attribute \"{s}\" for tag \"{s}\"", .{ name, schema.tag_name });
        for (schema.attributes) |attr| log.info("expected attribute name: \"{s}\"", .{ attr.name });
        return error.SchemaViolation;
    }

    fn parsingAddChild(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
        node: ParsedUnion(schema.content.child_nodes),
    ) Allocator.Error!void {
        if (comptime !schema.parsingDynamicChildren()) comptime unreachable;
        try @field(parsing, content_field_name).append(gpa, node);
    }

    fn parsingAddLiteralText(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
        text: []const u8,
    ) Allocator.Error!void {
        if (schema.content != .literal_text) comptime unreachable;
        if (@field(parsing, content_field_name).len != 0) unreachable; // clobber
        if (text.len != 0) {
            @branchHint(.likely);
            @field(parsing, content_field_name) = try gpa.dupe(u8, text);
        }
    }

    fn parsingToParsed(
        comptime schema: Schema,
        gpa: Allocator,
        parsing: *schema.Parsing(),
    ) (error{SchemaViolation} || Allocator.Error)!schema.Parsed() {
        var parsed: schema.Parsed() = undefined;
        inline for (schema.attributes) |attr| {
            if (attr.optional) {
                @field(parsed, attr.name) = @field(parsing, attr.name);
            } else {
                if (@field(parsing, attr.name)) |field| {
                    @field(parsed, attr.name) = field;
                } else {
                    log.err("\"{s}\" attribute \"{s}\" is non-optional and missing from tag", .{ schema.tag_name, attr.name });
                    return error.SchemaViolation;
                }
            }
        }
        if (comptime schema.parsingDynamicChildren()) {
            @field(parsed, content_field_name) = try @field(parsing, content_field_name).toOwnedSlice(gpa);
        } else {
            @field(parsed, content_field_name) = @field(parsing, content_field_name);
        }
        return parsed;
    }
};

/// Assumes the reader seek sits at the beginning of the next attribute name.
/// Parses, allocates, and returns it,
/// advancing seek up to the attribute value
/// (the next non-whitespace character after the `'='`).
fn takeAndDupeAttrName(
    gpa: Allocator,
    reader: *Io.Reader,
) (error{XmlInvalid} || Io.Reader.DelimiterError || Allocator.Error)![]u8 {
    const name_in_buffer = try peekAnyDelimiterExclusive(reader, &([1]u8{'='} ++ ascii.whitespace));
    const name = try gpa.dupe(u8, name_in_buffer);
    errdefer gpa.free(name);
    reader.toss(name_in_buffer.len);
    _ = try discardWhitespace(reader);
    const delim = try reader.takeByte();
    if (delim != '=') {
        log.err("expected '=' token after attribute name, found '{c}'", .{ delim });
        return error.XmlInvalid;
    }
    _ = try discardWhitespace(reader);
    return name;
}

/// Checks that the reader seek sits at the beginning of an attribute value.
/// Takes the full attribute value string, including the ending quotation mark,
/// and returns the inner value (without quotation marks).
/// The returned memory is valid until the next read.
fn takeAttrValue(reader: *Io.Reader) (error{XmlInvalid} || Io.Reader.DelimiterError)![]u8 {
    switch (try reader.peekByte()) {
        '\'', '\"' => |c| {
            reader.toss(1);
            const value = try reader.takeDelimiterExclusive(c);
            reader.toss(1);
            return value;
        },
        else => |c| {
            log.err("expected first token of attribute value as ''' or '\"', found '{c}'", .{ c });
            return error.XmlInvalid;
        },
    }
}

/// Asserts the reader seek sits at a `'<'`.
/// Returns `error.XmlInvalid` if this is not the `tag` close (`"</tag>"`).
/// Otherwise, advances seek past the tag close.
fn checkDiscardTagClose(reader: *Io.Reader, tag: []const u8) (error{XmlInvalid} || Io.Reader.DelimiterError)!void {
    if (( try reader.takeByte() ) != '<') unreachable;
    _ = try discardWhitespace(reader);
    const next = try reader.takeByte();
    if (next != '/') {
        log.err("expected '/' token before \"{s}\" closing tag, found '{c}'", .{ tag, next });
        return error.XmlInvalid;
    }
    _ = try discardWhitespace(reader);
    const name_str = try peekAnyDelimiterExclusive(reader, &([1]u8{'>'} ++ ascii.whitespace));
    if (!mem.eql(u8, tag, name_str)) {
        log.err("expected \"{s}\" closing tag, found \"<{s}/>\"", .{ tag, name_str });
        return error.XmlInvalid;
    }
    reader.toss(name_str.len);
    _ = try discardWhitespace(reader);
    const last = try reader.takeByte();
    if (last != '>') {
        log.err("expected '>' token after closing tag, found '{c}'", .{ last });
        return error.XmlInvalid;
    }
}

/// Asserts the reader seek sits at a `'<'`.
/// Peeks forward to inspect this tag.
/// If this is a closing tag (`"</"` ...), returns `true`.
/// If not (any next char after whitespace other than `'/'` is encountered), returns `false`.
///
/// See `Io.Reader.peekDelimiterInclusive`
fn tagIsClosing(reader: *Io.Reader) Io.Reader.DelimiterError!bool {
    const first = try reader.peekByte();
    if (first != '<') unreachable;

    {
        const contents = reader.buffer[0..reader.end];
        const start = reader.seek + 1;
        if (findNextNonWhitespace(contents, start)) |pos| {
            @branchHint(.likely);
            return contents[pos] == '/';
        }
    }
    while (reader.buffer.len - (reader.end - reader.seek) != 0) {
        try reader.fillMore();
        const start = reader.seek + 1;
        const contents = reader.buffer[0..reader.end];
        if (findNextNonWhitespace(contents, start)) |pos| {
            return contents[pos] == '/';
        }
    }
    var failing_writer = Io.Writer.failing;
    while (reader.vtable.stream(reader, &failing_writer, .limited(1))) |n| {
        if (n != 0) unreachable;
    } else |err| switch (err) {
        error.WriteFailed => return error.StreamTooLong,
        error.ReadFailed => |e| return e,
        error.EndOfStream => |e| return e,
    }
}

const TagClose = enum { close, self_close };

/// Seek up to the next token.
/// If the next token is the beginning of the tag close,
/// take the tag close.
fn tryTakeTagClose(reader: *Io.Reader, comptime preclose_char: u8) (error{XmlInvalid} || Io.Reader.Error)!?TagClose {
    _ = try discardWhitespace(reader);
    const first = try reader.peekByte();
    switch (first) {
        '>' => {
            reader.toss(1);
            return .close;
        },
        preclose_char => {
            reader.toss(1);
            // It is valid for there to be whitespace, like this: `"<tag_name   /   >"`
            _ = try discardWhitespace(reader);
            const second = try reader.peekByte();
            if (second != '>') {
                log.err("expected token after '{c}' to be '>', found '{c}'", .{ preclose_char, second });
                return error.XmlInvalid;
            }
            reader.toss(1);
            return .self_close;
        },
        else => return null,
    }
}

/// Seeks past all whitespace and comments.
pub fn discardEmptyText(reader: *Io.Reader) Io.Reader.Error!bool {
    var discarded = false;
    while (cont: {
        const was_comment = try discardComment(reader);
        const was_whitespace = try discardWhitespace(reader);
        const was = was_comment or was_whitespace;
        if (was) discarded = true;
        break :cont was;
    }) {}
    return discarded;
}

/// If seek sits at a comment, discards it and returns `true`.
pub fn discardComment(reader: *Io.Reader) Io.Reader.Error!bool {
    const first_four = reader.peekArray(4) catch |err| switch (err) {
        error.EndOfStream => return false,
        error.ReadFailed => |e| return e,
    };
    if (!mem.eql(u8, "<!--", first_four)) return false;
    reader.toss(4);
    while (cont: {
        _ = try reader.discardDelimiterInclusive('-');
        const next_two = try reader.peekArray(2);
        if (mem.eql(u8, "->", next_two)) {
            reader.toss(2);
            break :cont false;
        }
        break :cont true;
    }) {}
    return true;
}

pub fn discardWhitespace(reader: *Io.Reader) Io.Reader.Error!bool {
    var discarded: bool = false;
    while (ascii.isWhitespace(try reader.peekByte())) {
        reader.toss(1);
        discarded = true;
    }
    return discarded;
}

fn findNextNonWhitespace(buffer: []const u8, start: usize) ?usize {
    if (start > buffer.len) return null;
    return for (buffer[start..], start..) |char, i| {
        if (!ascii.isWhitespace(char)) break i;
    } else null;
}

/// See `std.Io.Reader.peekDelimiterInclusive`
fn peekAnyDelimiterExclusive(reader: *Io.Reader, delimiters: []const u8) Io.Reader.DelimiterError![]u8 {
    {
        const contents = reader.buffer[0..reader.end];
        const seek = reader.seek;
        if (mem.findAnyPos(u8, contents, seek, delimiters)) |end| {
            @branchHint(.likely);
            return contents[seek..end];
        }
    }
    while (true) {
        const content_len = reader.end - reader.seek;
        if (reader.buffer.len - content_len == 0) break;
        try reader.fillMore();
        const seek = reader.seek;
        const contents = reader.buffer[0..reader.end];
        if (mem.findAnyPos(u8, contents, seek + content_len, delimiters)) |end| {
            return contents[seek..end];
        }
    }
    var failing_writer = Io.Writer.failing;
    while (reader.vtable.stream(reader, &failing_writer, .limited(1))) |n| {
        if (n != 0) unreachable;
    } else |err| switch (err) {
        error.WriteFailed => return error.StreamTooLong,
        error.ReadFailed => |e| return e,
        error.EndOfStream => |e| return e,
    }
}

fn expectParsedSchema(
    comptime possible_schema: []const Schema,
    expected: Schema.ParsedUnion(possible_schema),
    actual: Schema.ParsedUnion(possible_schema),
) (error{TestExpectedEqual})!void {
    if (possible_schema.len == 0) return;
    const ChildUnion = Schema.ParsedUnion(possible_schema);
    const ChildTag = @typeInfo(ChildUnion).@"union".tag_type orelse unreachable;
    inline for (possible_schema) |schema| {
        const name = schema.tag_name;
        const expected_tag: ChildTag = @field(ChildTag, name);
        if (expected == expected_tag) {
            try testing.expectEqual(expected_tag, meta.activeTag(actual));
            return expectParsedNodesEqual(schema, @field(expected, name), @field(actual, name));
        }
    }
    unreachable;
}

fn expectParsedNodesEqual(
    comptime schema: Schema,
    expected: schema.Parsed(),
    actual: schema.Parsed(),
) (error{TestExpectedEqual})!void {
    const Node = schema.Parsed();
    inline for (@typeInfo(Node).@"struct".field_names) |field_name| {
        try testing.expectEqualDeep(@field(expected, field_name), @field(actual, field_name));
    }
    switch (schema.content) {
        .child_nodes => |child_nodes| {
            const expected_children = @field(expected, Schema.content_field_name);
            const actual_children = @field(actual, Schema.content_field_name);
            for (expected_children, actual_children) |expected_child, actual_child| {
                try expectParsedSchema(child_nodes, expected_child, actual_child);
            }
        },
        .literal_text => {
            const expected_text: []const u8 = @field(expected, Schema.content_field_name);
            const actual_text: []const u8 = @field(actual, Schema.content_field_name);
            try testing.expectEqualSlices(u8, expected_text, actual_text);
        },
    }
}

const test_schema: Schema = .{
    .tag_name = "top",
    .attributes = &.{
        .{ .name = "top_attr", .value = .string, .optional = true },
    },
    .content = .{ .child_nodes = &.{
        .{
            .tag_name = "no-attrs",
        },
        .{
            .tag_name = "one_4ttr",
            .attributes = &.{
                .{ .name = "int_attr", .value = .{ .int = .{ .signedness = .signed, .bits = 16 } } },
            },
        },
        .{
            .tag_name = "two_attrs",
            .attributes = &.{
                .{ .name = "int_attr", .value = .{ .int = .{ .signedness = .unsigned, .bits = 8 } } },
                .{ .name = "enum_attr", .value = .{ .@"enum" = &.{
                    "foo",
                    "bar",
                } } },
            },
        },
        .{
            .tag_name = "literal",
            .content = .literal_text,
        },
        .{
            .tag_name = "sub_children",
            .content = .{ .child_nodes = &.{
                .{ .tag_name = "sub_child_one" },
                .{ .tag_name = "sub_child_two" },
            } },
        },
    } },
};

// TODO more extensive tests

test "full test schema correct" {
    var test_input: Io.Reader = .fixed(
        \\<top>
        \\    <no-attrs  /  >
        \\    <no-attrs ><  /  no-attrs>
        \\    <two_attrs int_attr  =  "124"  enum_attr="foo"   />
        \\    <literal>  I am literal text!    </literal>
        \\    <sub_children>
        \\        <sub_child_one/>
        \\        <sub_child_two/>
        \\        <sub_child_one/>
        \\        <sub_child_two/>
        \\        <sub_child_two/>
        \\        <sub_child_one/>
        \\    </sub_children>
        \\</top>
        \\
    );
    const schemas: []const Schema = &.{ test_schema };
    const Result = Schema.ParsedUnion(schemas);
    const expect: Result = .{ .top = .{
        .top_attr = null,
        .content = &.{
            .{ .@"no-attrs" = .{ .content = {} } },
            .{ .@"no-attrs" = .{ .content = {} } },
            .{ .two_attrs = .{
                .int_attr = 124,
                .enum_attr = .foo,
                .content = {},
            } },
            .{ .literal = .{ .content = "  I am literal text!    " } },
            .{ .sub_children = .{ .content = &.{
                .{ .sub_child_one = .{ .content = {} } },
                .{ .sub_child_two = .{ .content = {} } },
                .{ .sub_child_one = .{ .content = {} } },
                .{ .sub_child_two = .{ .content = {} } },
                .{ .sub_child_two = .{ .content = {} } },
                .{ .sub_child_one = .{ .content = {} } },
            } } },
        },
    } };
    const actual: ParseError!Result = takeNode(testing.allocator, &test_input, schemas);
    defer {
        if (actual) |result| {
            freeNodeUnion(testing.allocator, schemas, result);
        } else |_| {}
    }
    try testing.expectEqualDeep(expect, actual);
}

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Type = std.builtin.Type;
const testing = std.testing;
const meta = std.meta;
const Io = std.Io;
const ascii = std.ascii;
const log = std.log;
const mem = std.mem;
const std = @import("std");
