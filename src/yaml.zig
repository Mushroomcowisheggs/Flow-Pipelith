//! Zero-dependency YAML subset parser, producing exactly the same `Value` model as `json.zig`.
//!
//! Supported (covering every real requirement of CDL description files):
//!   - block mappings     `key: value`
//!   - block sequences    `- item`, `- key: value` (compact nested mapping)
//!   - nesting            `parent:\n  child: 1`, `-\n  - a`
//!   - flow collections   `[a, b]`, `{a: 1, b: 2}` (including JSON-style quoted keys)
//!   - scalars            int / float / bool / null / string
//!   - quoted strings     `"..."` (with escapes), `'...'` (`''` means a single quote)
//!   - folded & literal blocks  `>` and `|`
//!   - comments           `#` (only at the start of a line or after leading whitespace, outside quotes)
//!   - multi-document separators  `---` (the first document is taken, the rest ignored)
//!
//! Not supported (a clear error is raised instead of silently misparsing):
//!   anchors/aliases `&`/`*`, tags `!!`, complex keys `?`, tab indentation, multi-document merging.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Error = struct {
    message: []const u8,
    line: usize,
    path: []const u8 = "",
};

pub const Result = union(enum) {
    ok: Value,
    err: Error,
};

const Line = struct {
    indent: usize,
    text: []const u8,
    number: usize,
};

const Parser = struct {
    gpa: std.mem.Allocator,
    lines: []Line,
    i: usize = 0,
    err: Error = .{ .message = "", .line = 0 },
    path: std.ArrayListUnmanaged([]const u8) = .empty,

    fn fail(self: *Parser, line_no: usize, msg: []const u8) error{Parse} {
        self.err = .{ .message = msg, .line = line_no, .path = self.pathString() };
        return error.Parse;
    }

    fn pathString(self: *Parser) []const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        out.appendSlice(gpa, "$") catch return "";
        for (self.path.items) |seg| {
            if (seg.len > 0 and seg[0] == '[') {
                out.appendSlice(gpa, seg) catch return "";
            } else {
                out.append(gpa, '.') catch return "";
                out.appendSlice(gpa, seg) catch return "";
            }
        }
        return out.items;
    }

    fn pushPath(self: *Parser, seg: []const u8) void {
        self.path.append(self.gpa, seg) catch {};
    }

    fn popPath(self: *Parser) void {
        if (self.path.items.len > 0) _ = self.path.pop();
    }

    fn peek(self: *Parser) ?Line {
        if (self.i >= self.lines.len) return null;
        return self.lines[self.i];
    }

    /// Parse a node: the indentation of its first line has already been fixed to `min_indent`;
    /// returns the fully consumed value.
    fn parseNode(self: *Parser, min_indent: usize) error{ Parse, OutOfMemory }!Value {
        const line = self.peek() orelse return .null;
        if (line.indent < min_indent) return .null;
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) {
            return self.parseSequence(line.indent);
        }
        return self.parseMapping(line.indent);
    }

    fn parseSequence(self: *Parser, indent: usize) error{ Parse, OutOfMemory }!Value {
        var items: std.ArrayListUnmanaged(Value) = .empty;
        const gpa = self.gpa;
        var idx: usize = 0;
        while (self.peek()) |line| {
            if (line.indent < indent) break;
            if (line.indent > indent) return self.fail(line.number, "inconsistent indentation of sequence item");
            if (!(std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-"))) break;

            var idx_buf: [24]u8 = undefined;
            const seg = std.fmt.bufPrint(&idx_buf, "[{d}]", .{idx}) catch "[?]";
            self.pushPath(seg);
            defer self.popPath();
            defer idx += 1;

            const rest_raw = if (line.text.len > 1) line.text[2..] else "";
            const rest = std.mem.trim(u8, rest_raw, " \t");
            if (rest.len == 0) {
                // the value is on a following line (deeper indentation)
                self.i += 1;
                const child_indent = self.nextIndent(indent);
                if (child_indent == null) {
                    try items.append(gpa, .null);
                    continue;
                }
                try items.append(gpa, try self.parseNode(child_indent.?));
                continue;
            }

            // Content on the same line: it may be `key: value` (compact mapping) or a plain scalar.
            // Note: tryParseInlineMapping already advances the line pointer (and consumes the whole
            // mapping body), so we must never add +1 here or we would swallow the next sequence item.
            if (try self.tryParseInlineMapping(rest, line.number)) |obj_val| {
                try items.append(gpa, obj_val);
                continue;
            }

            self.i += 1;
            const scalar = try self.parseScalar(rest, line.number);
            // a folded scalar may keep consuming following lines
            try items.append(gpa, scalar);
        }
        return .{ .array = items.items };
    }

    /// Handle the `- name: value` / `- name:` form: treat the remainder of the line as the first
    /// line of a mapping.
    fn tryParseInlineMapping(self: *Parser, rest: []const u8, line_no: usize) error{ Parse, OutOfMemory }!?Value {
        const colon = findKeyColon(rest) orelse return null;
        const key_raw = std.mem.trim(u8, rest[0..colon], " \t");
        if (key_raw.len == 0) return null;
        const key = try self.decodeKey(key_raw, line_no);

        const gpa = self.gpa;
        const obj = try gpa.create(Value.Object);
        obj.* = .{};

        const after = std.mem.trim(u8, rest[colon + 1 ..], " \t");
        // the "effective indentation" of this mapping = the column where list item content starts (after the -)
        const content_indent = self.lines[self.i].indent + 2;
        self.pushPath(key);
        if (after.len == 0) {
            self.i += 1;
            const child_indent = self.nextIndent(content_indent - 1);
            if (child_indent) |ci| {
                if (ci >= content_indent) {
                    try obj.put(gpa, key, try self.parseNode(ci));
                } else {
                    // same level: empty value
                    try obj.put(gpa, key, .null);
                }
            } else {
                try obj.put(gpa, key, .null);
            }
        } else {
            self.i += 1;
            try obj.put(gpa, key, try self.parseScalar(after, line_no));
        }
        self.popPath();

        // keep consuming the remaining keys at the same level as this mapping
        while (self.peek()) |l| {
            if (l.indent < content_indent) break;
            if (l.indent > content_indent) return self.fail(l.number, "inconsistent indentation of mapping entry");
            if (std.mem.startsWith(u8, l.text, "- ") or std.mem.eql(u8, l.text, "-")) break;
            const c2 = findKeyColon(l.text) orelse return self.fail(l.number, "expected `key: value`");
            const k2 = try self.decodeKey(std.mem.trim(u8, l.text[0..c2], " \t"), l.number);
            const v2raw = std.mem.trim(u8, l.text[c2 + 1 ..], " \t");
            self.pushPath(k2);
            if (v2raw.len == 0) {
                self.i += 1;
                if (self.nextIndent(content_indent)) |ci| {
                    if (ci > content_indent) {
                        try obj.put(gpa, k2, try self.parseNode(ci));
                    } else {
                        try obj.put(gpa, k2, .null);
                    }
                } else {
                    try obj.put(gpa, k2, .null);
                }
            } else {
                self.i += 1;
                try obj.put(gpa, k2, try self.parseScalar(v2raw, l.number));
            }
            self.popPath();
        }
        return .{ .object = obj };
    }

    fn parseMapping(self: *Parser, indent: usize) error{ Parse, OutOfMemory }!Value {
        const gpa = self.gpa;
        const obj = try gpa.create(Value.Object);
        obj.* = .{};
        while (self.peek()) |line| {
            if (line.indent < indent) break;
            if (line.indent > indent) return self.fail(line.number, "unexpected extra indentation");
            if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) break;

            const colon = findKeyColon(line.text) orelse return self.fail(line.number, "expected `key: value`");
            const key = try self.decodeKey(std.mem.trim(u8, line.text[0..colon], " \t"), line.number);
            const val_raw = std.mem.trim(u8, line.text[colon + 1 ..], " \t");

            self.pushPath(key);
            if (val_raw.len == 0) {
                self.i += 1;
                if (self.nextIndent(indent)) |ci| {
                    if (ci > indent) {
                        try obj.put(gpa, key, try self.parseNode(ci));
                    } else {
                        try obj.put(gpa, key, .null);
                    }
                } else {
                    try obj.put(gpa, key, .null);
                }
            } else {
                self.i += 1;
                try obj.put(gpa, key, try self.parseScalar(val_raw, line.number));
            }
            self.popPath();
            // a single key may appear in multiple sibling blocks (last write wins is preserved)
        }
        return .{ .object = obj };
    }

    fn nextIndent(self: *Parser, current: usize) ?usize {
        const l = self.peek() orelse return null;
        if (l.indent <= current) return null;
        return l.indent;
    }

    fn decodeKey(self: *Parser, raw: []const u8, line_no: usize) error{ Parse, OutOfMemory }![]const u8 {
        if (raw.len == 0) return self.fail(line_no, "empty key");
        if (raw[0] == '"' or raw[0] == '\'') {
            const v = try self.parseScalar(raw, line_no);
            return v.asString() orelse return self.fail(line_no, "key must be a string");
        }
        if (raw[0] == '&' or raw[0] == '*') return self.fail(line_no, "YAML anchors/aliases are not supported");
        if (raw[0] == '!') return self.fail(line_no, "YAML tags are not supported");
        return raw;
    }

    /// Parse a scalar; `>` / `|` will consume the following lines.
    fn parseScalar(self: *Parser, raw: []const u8, line_no: usize) error{ Parse, OutOfMemory }!Value {
        const s = std.mem.trim(u8, raw, " \t");
        if (s.len == 0) return .null;

        if (s[0] == '&') return self.fail(line_no, "YAML anchors are not supported");
        if (s[0] == '*') return self.fail(line_no, "YAML aliases are not supported");
        if (s[0] == '!') return self.fail(line_no, "YAML tags are not supported");
        if (s[0] == '"') return self.parseDoubleQuoted(s, line_no);
        if (s[0] == '\'') return self.parseSingleQuoted(s, line_no);
        if (s[0] == '[' or s[0] == '{') return self.parseFlow(s, line_no);
        if (s[0] == '>' or s[0] == '|') return self.parseBlockScalar(s[0], line_no, s);
        if (s[0] == '?') return self.fail(line_no, "YAML complex keys are not supported");

        return self.parsePlain(s);
    }

    fn parsePlain(self: *Parser, s: []const u8) error{ Parse, OutOfMemory }!Value {
        _ = self;
        if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~") or std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL")) return .null;
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "TRUE")) return .{ .bool = true };
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "FALSE")) return .{ .bool = false };

        // numbers: integers first, anything with . / e goes through the float path
        const looks_numeric = blk: {
            if (s.len == 0) break :blk false;
            var k: usize = 0;
            if (s[0] == '-' or s[0] == '+') k = 1;
            if (k >= s.len) break :blk false;
            break :blk std.ascii.isDigit(s[k]);
        };
        if (looks_numeric) {
            const neg = s[0] == '-';
            const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
            const has_dot = std.mem.indexOfScalar(u8, body, '.') != null;
            const has_exp = std.mem.indexOfAny(u8, body, "eE") != null;
            if (!has_dot and !has_exp) {
                if (std.fmt.parseInt(i64, s, 10)) |n| {
                    return .{ .int = n };
                } else |_| {}
            }
            if (std.fmt.parseFloat(f64, s)) |f| {
                _ = neg;
                return .{ .float = f };
            } else |_| {}
        }

        // unquoted string: trailing comments are dropped (`#` must be preceded by whitespace)
        const cut = findCommentStart(s);
        const body = std.mem.trim(u8, s[0..cut], " \t");
        return .{ .string = body };
    }

    fn parseDoubleQuoted(self: *Parser, s: []const u8, line_no: usize) error{ Parse, OutOfMemory }!Value {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        var i: usize = 1;
        while (i < s.len) {
            const c = s[i];
            if (c == '"') return .{ .string = out.items };
            if (c == '\\') {
                i += 1;
                if (i >= s.len) break;
                switch (s[i]) {
                    'n' => try out.append(gpa, '\n'),
                    't' => try out.append(gpa, '\t'),
                    'r' => try out.append(gpa, '\r'),
                    '"' => try out.append(gpa, '"'),
                    '\\' => try out.append(gpa, '\\'),
                    '0' => try out.append(gpa, 0),
                    '/' => try out.append(gpa, '/'),
                    'u' => {
                        if (i + 4 >= s.len) return self.fail(line_no, "incomplete \\u escape");
                        var cp: u21 = 0;
                        for (s[i + 1 .. i + 5]) |hc| {
                            const d: u21 = switch (hc) {
                                '0'...'9' => hc - '0',
                                'a'...'f' => hc - 'a' + 10,
                                'A'...'F' => hc - 'A' + 10,
                                else => return self.fail(line_no, "\\u escape contains an invalid character"),
                            };
                            cp = cp * 16 + d;
                        }
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return self.fail(line_no, "invalid Unicode code point");
                        try out.appendSlice(gpa, buf[0..n]);
                        i += 4;
                    },
                    else => try out.append(gpa, s[i]),
                }
                i += 1;
                continue;
            }
            try out.append(gpa, c);
            i += 1;
        }
        return .{ .string = out.items };
    }

    fn parseSingleQuoted(self: *Parser, s: []const u8, line_no: usize) error{ Parse, OutOfMemory }!Value {
        _ = line_no;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        var i: usize = 1;
        while (i < s.len) {
            if (s[i] == '\'') {
                if (i + 1 < s.len and s[i + 1] == '\'') {
                    try out.append(gpa, '\'');
                    i += 2;
                    continue;
                }
                return .{ .string = out.items };
            }
            try out.append(gpa, s[i]);
            i += 1;
        }
        return .{ .string = out.items };
    }

    /// Flow collections `[a, b]` / `{a: 1}`: reuses the JSON parser (YAML flow style is a superset
    /// of JSON; the only difference is unquoted scalars, which are lightly normalized here before
    /// being handed to the JSON parser).
    fn parseFlow(self: *Parser, s: []const u8, line_no: usize) error{ Parse, OutOfMemory }!Value {
        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        var i: usize = 0;
        var quote: u8 = 0;
        while (i < s.len) {
            const c = s[i];
            if (quote != 0) {
                try normalized.append(gpa, c);
                if (c == '\\' and quote == '"' and i + 1 < s.len) {
                    try normalized.append(gpa, s[i + 1]);
                    i += 2;
                    continue;
                }
                if (c == quote) quote = 0;
                i += 1;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                try normalized.append(gpa, '"');
                i += 1;
                continue;
            }
            // unquoted scalar -> add quotes (numbers/booleans/null stay as they are)
            if (isBareScalarStart(c)) {
                const start = i;
                while (i < s.len and !isFlowDelim(s[i])) i += 1;
                const tok = std.mem.trim(u8, s[start..i], " \t");
                if (isReservedScalar(tok)) {
                    try normalized.appendSlice(gpa, tok);
                } else {
                    try appendJsonEscaped(gpa, &normalized, tok);
                }
                continue;
            }
            try normalized.append(gpa, c);
            i += 1;
        }
        const enc = std.json.Stringify.encodeJsonString;
        _ = enc;
        const r = Value.parseJson(gpa, normalized.items);
        switch (r) {
            .ok => |v| return v,
            .err => |e| return self.fail(line_no, e.message),
        }
    }

    fn parseBlockScalar(self: *Parser, kind: u8, line_no: usize, header: []const u8) error{ Parse, OutOfMemory }!Value {
        _ = header;
        const gpa = self.gpa;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const base_indent = self.lines[self.i - 1].indent;
        var block_indent: ?usize = null;
        var first = true;
        while (self.peek()) |l| {
            if (l.indent <= base_indent) break;
            const bi = block_indent orelse blk: {
                block_indent = l.indent;
                break :blk l.indent;
            };
            if (!first) try out.append(gpa, '\n');
            first = false;
            const text = if (l.text.len + l.indent > bi) l.text[(bi - l.indent)..] else "";
            try out.appendSlice(gpa, text);
            self.i += 1;
        }
        if (kind == '>') {
            // folding: a single newline becomes a space
            for (out.items) |*ch| {
                if (ch.* == '\n') ch.* = ' ';
            }
        }
        if (out.items.len > 0) try out.append(gpa, '\n');
        _ = line_no;
        return .{ .string = out.items };
    }
};

fn isBareScalarStart(c: u8) bool {
    return !(c == ',' or c == ']' or c == '}' or c == ':' or c == '[' or c == '{' or c == ' ' or c == '\t');
}

fn isFlowDelim(c: u8) bool {
    return c == ',' or c == ']' or c == '}' or c == ':';
}

fn isReservedScalar(tok: []const u8) bool {
    if (tok.len == 0) return true;
    if (std.mem.eql(u8, tok, "true") or std.mem.eql(u8, tok, "false") or std.mem.eql(u8, tok, "null")) return true;
    const looks_num = blk: {
        var k: usize = 0;
        if (tok[0] == '-' or tok[0] == '+') k = 1;
        if (k >= tok.len) break :blk false;
        break :blk std.ascii.isDigit(tok[k]);
    };
    return looks_num;
}

fn appendJsonEscaped(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

/// Find the colon separating key and value: skips colons inside quotes and flow collections.
fn findKeyColon(text: []const u8) ?usize {
    var quote: u8 = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                if (depth == 0) {
                    // `key: value` or `key:` (end of line); do not treat the colon in `http://x` as a separator
                    if (i + 1 >= text.len) return i;
                    if (text[i + 1] == ' ' or text[i + 1] == '\t') return i;
                }
            },
            '#' => {
                if (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t') return null;
            },
            else => {},
        }
    }
    return null;
}

fn findCommentStart(text: []const u8) usize {
    var quote: u8 = 0;
    for (text, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t')) return i;
    }
    return text.len;
}

/// Preprocessing: drop blank lines (outside block scalars), comments and document markers, and
/// compute indentation.
fn preprocess(gpa: std.mem.Allocator, text: []const u8) ![]Line {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var no: usize = 0;
    var seen_doc_start = false;
    while (it.next()) |raw_line| {
        no += 1;
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (std.mem.indexOfScalar(u8, line, '\t') != null) {
            // only report an error when the tab appears in the indentation
            var k: usize = 0;
            while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {
                if (line[k] == '\t') return error.TabIndent;
            }
        }
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        const body = line[indent..];

        if (body.len == 0) continue;
        if (body[0] == '#') continue;
        if (std.mem.eql(u8, body, "---")) {
            if (seen_doc_start and lines.items.len > 0) break; // take only the first document
            seen_doc_start = true;
            continue;
        }
        if (std.mem.eql(u8, body, "...")) break;
        if (std.mem.startsWith(u8, body, "%YAML")) continue;

        try lines.append(gpa, .{ .indent = indent, .text = body, .number = no });
    }
    return lines.items;
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) Result {
    const lines = preprocess(gpa, text) catch |e| switch (e) {
        error.TabIndent => return .{ .err = .{ .message = "tab indentation is not supported (the YAML spec requires spaces)", .line = 0 } },
        else => return .{ .err = .{ .message = "preprocessing failed", .line = 0 } },
    };
    if (lines.len == 0) return .{ .ok = .null };

    var p: Parser = .{ .gpa = gpa, .lines = lines };
    const first_indent = lines[0].indent;
    const v = p.parseNode(first_indent) catch |e| switch (e) {
        error.Parse => return .{ .err = p.err },
        else => return .{ .err = .{ .message = "out of memory", .line = 0 } },
    };
    return .{ .ok = v };
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn parseOk(gpa: std.mem.Allocator, text: []const u8) !Value {
    const r = parse(gpa, text);
    switch (r) {
        .ok => |v| return v,
        .err => |e| {
            std.debug.print("YAML parse failed line={d} path={s}: {s}\n", .{ e.line, e.path, e.message });
            return error.ParseFailed;
        },
    }
}

test "yaml: scalar type inference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\s: hello
        \\n: 42
        \\f: 1.5
        \\b: true
        \\z: null
        \\q: "quoted: value"
        \\sq: 'it''s'
        \\neg: -7
    );
    try testing.expectEqualStrings("hello", v.field("s").?.asString().?);
    try testing.expectEqual(@as(i64, 42), v.field("n").?.asInt().?);
    try testing.expectEqual(@as(f64, 1.5), v.field("f").?.asFloat().?);
    try testing.expectEqual(true, v.field("b").?.asBool().?);
    try testing.expect(v.field("z").? == .null);
    try testing.expectEqualStrings("quoted: value", v.field("q").?.asString().?);
    try testing.expectEqualStrings("it's", v.field("sq").?.asString().?);
    try testing.expectEqual(@as(i64, -7), v.field("neg").?.asInt().?);
}

test "yaml: comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\# top comment
        \\name: ffmpeg   # trailing comment
        \\
        \\version: "6.0"
    );
    try testing.expectEqualStrings("ffmpeg", v.field("name").?.asString().?);
    try testing.expectEqualStrings("6.0", v.field("version").?.asString().?);
}

test "yaml: nested mappings and sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\pipes:
        \\  stdin: none
        \\  stdout: text
        \\platforms:
        \\  - windows
        \\  - macos
        \\  - linux
    );
    try testing.expectEqualStrings("none", v.field("pipes").?.field("stdin").?.asString().?);
    const plats = v.field("platforms").?.asArray().?;
    try testing.expectEqual(@as(usize, 3), plats.len);
    try testing.expectEqualStrings("macos", plats[1].asString().?);
}

test "yaml: compact mappings inside sequences (the core CDL shape)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\actions:
        \\  - name: convert
        \\    label: Convert format
        \\    args:
        \\      - value: "-i"
        \\      - value: "{input}"
        \\    variables:
        \\      - name: codec
        \\        type: enum
        \\        options:
        \\          - value: libx264
        \\            label: H.264
        \\  - name: extract
        \\    label: Extract audio
        \\    args:
        \\      - value: "-vn"
    );
    const actions = v.field("actions").?.asArray().?;
    try testing.expectEqual(@as(usize, 2), actions.len);
    try testing.expectEqualStrings("convert", actions[0].field("name").?.asString().?);
    try testing.expectEqualStrings("Convert format", actions[0].field("label").?.asString().?);
    const args = actions[0].field("args").?.asArray().?;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("{input}", args[1].field("value").?.asString().?);
    const vars = actions[0].field("variables").?.asArray().?;
    try testing.expectEqualStrings("codec", vars[0].field("name").?.asString().?);
    const opts = vars[0].field("options").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), opts.len);
    try testing.expectEqualStrings("libx264", opts[0].field("value").?.asString().?);
    try testing.expectEqualStrings("H.264", opts[0].field("label").?.asString().?);
    // the second action is independent
    try testing.expectEqualStrings("extract", actions[1].field("name").?.asString().?);
    try testing.expectEqual(@as(usize, 1), actions[1].field("args").?.asArray().?.len);
}

test "yaml: flow collections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\filters: ["*.mp4", "*.mkv"]
        \\nums: [1, 2, 3]
        \\obj: {value: libx264, label: H.264}
        \\empty: []
    );
    try testing.expectEqual(@as(usize, 2), v.field("filters").?.asArray().?.len);
    try testing.expectEqualStrings("*.mkv", v.field("filters").?.asArray().?[1].asString().?);
    try testing.expectEqual(@as(usize, 3), v.field("nums").?.asArray().?.len);
    try testing.expectEqualStrings("H.264", v.field("obj").?.field("label").?.asString().?);
    try testing.expectEqual(@as(usize, 0), v.field("empty").?.asArray().?.len);
}

test "yaml: block scalars and multiple lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a,
        \\literal: |
        \\  first line
        \\  second line
        \\folded: >
        \\  folded into one line
    );
    try testing.expectEqualStrings("first line\nsecond line\n", v.field("literal").?.asString().?);
    try testing.expectEqualStrings("folded into one line\n", v.field("folded").?.asString().?);
}

test "yaml: unsupported features raise clear errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r1 = parse(a, "k: &anchor value");
    try testing.expect(r1 == .err);

    const r2 = parse(a, "k: *ref");
    try testing.expect(r2 == .err);

    const r3 = parse(a, "k: !!str value");
    try testing.expect(r3 == .err);
}

test "yaml: line number reporting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = parse(a,
        \\a: 1
        \\b: 2
        \\   bad_indent: 3
    );
    try testing.expect(r == .err);
    try testing.expect(r.err.line == 3);
}
