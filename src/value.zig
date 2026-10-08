//! Dynamic value model + zero-dependency JSON parser.
//!
//! Design notes: rather than using `std.json.Value` directly, we ship our own value model, for three reasons:
//!   1. the YAML and JSON parsing paths must produce **exactly the same** value types, so the CDL layer only handles one shape;
//!   2. we need to retain the information validation requires, such as duplicate keys (better diagnostics);
//!   3. all values are allocated in a single arena, so lifetime management lives in exactly one place.

const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: *Object,

    pub const Object = struct {
        keys: std.ArrayListUnmanaged([]const u8) = .empty,
        vals: std.ArrayListUnmanaged(Value) = .empty,
        /// Key names that appeared more than once, kept for diagnostics (last write wins, but it must be reported).
        dups: std.ArrayListUnmanaged([]const u8) = .empty,

        pub fn get(self: *const Object, key: []const u8) ?Value {
            for (self.keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) return self.vals.items[i];
            }
            return null;
        }

        pub fn getPtr(self: *const Object, key: []const u8) ?*const Value {
            for (self.keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) return &self.vals.items[i];
            }
            return null;
        }

        pub fn has(self: *const Object, key: []const u8) bool {
            return self.getPtr(key) != null;
        }

        pub fn count(self: *const Object) usize {
            return self.keys.items.len;
        }

        pub const Entry = struct { key: []const u8, value: Value };

        pub fn at(self: *const Object, i: usize) Entry {
            return .{ .key = self.keys.items[i], .value = self.vals.items[i] };
        }

        /// Write a key/value pair; an existing key is overwritten and recorded as a duplicate.
        pub fn put(self: *Object, gpa: std.mem.Allocator, key: []const u8, val: Value) !void {
            for (self.keys.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) {
                    self.vals.items[i] = val;
                    for (self.dups.items) |d| {
                        if (std.mem.eql(u8, d, key)) return;
                    }
                    try self.dups.append(gpa, key);
                    return;
                }
            }
            try self.keys.append(gpa, key);
            try self.vals.append(gpa, val);
        }
    };

    // ── Convenience accessors ─────────────────────────────────────

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// Stringify: numbers/booleans are turned into text as well (in CDL, `default: 5` and `default: "5"` are treated as equivalent).
    pub fn asStringCoerce(self: Value, gpa: std.mem.Allocator) !?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .int => |i| try std.fmt.allocPrint(gpa, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(gpa, "{d}", .{f}),
            .bool => |b| if (b) "true" else "false",
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]Value {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asObject(self: Value) ?*Object {
        return switch (self) {
            .object => |o| o,
            else => null,
        };
    }

    /// Fetch an object field (returns null for non-objects).
    pub fn field(self: Value, key: []const u8) ?Value {
        const o = self.asObject() orelse return null;
        return o.get(key);
    }

    pub fn kindName(self: Value) []const u8 {
        return switch (self) {
            .null => "null",
            .bool => "boolean",
            .int, .float => "number",
            .string => "string",
            .array => "array",
            .object => "object",
        };
    }

    // ── JSON parsing ─────────────────────────────────────────────

    pub const ParseError = struct {
        message: []const u8,
        line: usize,
        column: usize,
        path: []const u8,
    };

    pub const ParseResult = union(enum) {
        ok: Value,
        err: ParseError,
    };

    /// Parse JSON text. On failure returns a diagnostic with line/column/path.
    pub fn parseJson(gpa: std.mem.Allocator, text: []const u8) ParseResult {
        var p: JsonParser = .{ .gpa = gpa, .src = text };
        p.skipWs();
        const v = p.parseValue(0) catch return .{ .err = p.diag() };
        p.skipWs();
        if (p.i < p.src.len) {
            p.err_path = p.pathBuf();
            p.err_msg = "trailing content after end of JSON";
            return .{ .err = p.diag() };
        }
        return .{ .ok = v };
    }
};

const max_depth = 64;

const JsonParser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    line: usize = 1,
    col: usize = 1,
    err_msg: []const u8 = "parse failed",
    /// Path frozen at the moment the error occurred. It must be recorded **before**
    /// stack unwinding, otherwise the paired pushPath/popPath pops would clear the
    /// path (a trap we actually hit in practice).
    err_path: []const u8 = "",
    path_stack: [max_depth][]const u8 = undefined,
    path_len: usize = 0,

    fn pathBuf(self: *JsonParser) []const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        out.appendSlice(gpa, "$") catch return "";
        for (self.path_stack[0..self.path_len]) |seg| {
            if (seg.len > 0 and seg[0] == '[') {
                out.appendSlice(gpa, seg) catch return "";
            } else {
                out.append(gpa, '.') catch return "";
                out.appendSlice(gpa, seg) catch return "";
            }
        }
        return out.items;
    }

    fn diag(self: *JsonParser) Value.ParseError {
        return .{
            .message = self.err_msg,
            .line = self.line,
            .column = self.col,
            .path = self.err_path,
        };
    }

    /// Record the diagnostic (including the frozen path) and return a parse error.
    fn bad(self: *JsonParser, msg: []const u8) error{Parse}!Value {
        self.err_path = self.pathBuf();
        self.err_msg = msg;
        return error.Parse;
    }

    /// Same as above, but for parse functions that do not return a `Value`.
    fn badVoid(self: *JsonParser, msg: []const u8) error{Parse} {
        self.err_path = self.pathBuf();
        self.err_msg = msg;
        return error.Parse;
    }

    fn pushPath(self: *JsonParser, seg: []const u8) void {
        if (self.path_len < max_depth) {
            self.path_stack[self.path_len] = seg;
            self.path_len += 1;
        }
    }

    fn popPath(self: *JsonParser) void {
        if (self.path_len > 0) self.path_len -= 1;
    }

    fn advance(self: *JsonParser) void {
        if (self.src[self.i] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.i += 1;
    }

    fn skipWs(self: *JsonParser) void {
        while (self.i < self.src.len) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r', '\n' => self.advance(),
                else => return,
            }
        }
    }

    fn parseValue(self: *JsonParser, depth: usize) error{ Parse, OutOfMemory }!Value {
        if (depth > max_depth) return self.bad("nesting depth exceeds the limit");
        if (self.i >= self.src.len) return self.bad("unexpected end of input");
        return switch (self.src[self.i]) {
            '{' => self.parseObject(depth),
            '[' => self.parseArray(depth),
            '"' => .{ .string = try self.parseString() },
            't' => self.parseLit("true", .{ .bool = true }),
            'f' => self.parseLit("false", .{ .bool = false }),
            'n' => self.parseLit("null", .null),
            '-', '0'...'9' => self.parseNumber(),
            else => self.bad("invalid character at the start of a value"),
        };
    }

    fn parseLit(self: *JsonParser, lit: []const u8, v: Value) error{ Parse, OutOfMemory }!Value {
        if (self.i + lit.len > self.src.len) return self.bad("unexpected end of input");
        if (!std.mem.eql(u8, self.src[self.i .. self.i + lit.len], lit)) return self.bad("invalid literal");
        for (0..lit.len) |_| self.advance();
        return v;
    }

    fn parseNumber(self: *JsonParser) error{ Parse, OutOfMemory }!Value {
        const start = self.i;
        if (self.src[self.i] == '-') self.advance();
        while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.advance();
        var is_float = false;
        if (self.i < self.src.len and self.src[self.i] == '.') {
            is_float = true;
            self.advance();
            while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.advance();
        }
        if (self.i < self.src.len and (self.src[self.i] == 'e' or self.src[self.i] == 'E')) {
            is_float = true;
            self.advance();
            if (self.i < self.src.len and (self.src[self.i] == '+' or self.src[self.i] == '-')) self.advance();
            while (self.i < self.src.len and std.ascii.isDigit(self.src[self.i])) self.advance();
        }
        const tok = self.src[start..self.i];
        if (tok.len == 0 or std.mem.eql(u8, tok, "-")) return self.bad("invalid number");
        if (is_float) {
            const f = std.fmt.parseFloat(f64, tok) catch return self.bad("invalid floating-point number");
            return .{ .float = f };
        }
        const n = std.fmt.parseInt(i64, tok, 10) catch {
            const f = std.fmt.parseFloat(f64, tok) catch return self.bad("invalid integer");
            return .{ .float = f };
        };
        return .{ .int = n };
    }

    fn parseString(self: *JsonParser) error{ Parse, OutOfMemory }![]const u8 {
        if (self.src[self.i] != '"') return self.badVoid("expected a string");
        self.advance();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const gpa = self.gpa;
        while (true) {
            if (self.i >= self.src.len) return self.badVoid("unterminated string");
            const c = self.src[self.i];
            if (c == '"') {
                self.advance();
                return out.items;
            }
            if (c == '\\') {
                self.advance();
                if (self.i >= self.src.len) return self.badVoid("incomplete escape sequence");
                const e = self.src[self.i];
                self.advance();
                switch (e) {
                    '"' => try out.append(gpa, '"'),
                    '\\' => try out.append(gpa, '\\'),
                    '/' => try out.append(gpa, '/'),
                    'b' => try out.append(gpa, 0x08),
                    'f' => try out.append(gpa, 0x0C),
                    'n' => try out.append(gpa, '\n'),
                    'r' => try out.append(gpa, '\r'),
                    't' => try out.append(gpa, '\t'),
                    'u' => {
                        const cp = try self.parseHex4();
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch {
                            return self.badVoid("invalid Unicode code point");
                        };
                        try out.appendSlice(gpa, buf[0..n]);
                    },
                    else => return self.badVoid("unknown escape character"),
                }
                continue;
            }
            try out.append(gpa, c);
            self.advance();
        }
    }

    fn parseHex4(self: *JsonParser) error{ Parse, OutOfMemory }!u21 {
        if (self.i + 4 > self.src.len) return self.badVoid("incomplete \\u escape");
        var cp: u21 = 0;
        for (0..4) |_| {
            const c = self.src[self.i];
            const d: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return self.badVoid("\\u escape contains a non-hexadecimal character"),
            };
            cp = cp * 16 + d;
            self.advance();
        }
        return cp;
    }

    fn parseArray(self: *JsonParser, depth: usize) error{ Parse, OutOfMemory }!Value {
        self.advance(); // [
        var list: std.ArrayListUnmanaged(Value) = .empty;
        const gpa = self.gpa;
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == ']') {
            self.advance();
            return .{ .array = list.items };
        }
        var idx: usize = 0;
        var idx_buf: [24]u8 = undefined;
        while (true) {
            self.skipWs();
            const seg = std.fmt.bufPrint(&idx_buf, "[{d}]", .{idx}) catch "[?]";
            self.pushPath(seg);
            const v = self.parseValue(depth + 1) catch |e| {
                self.popPath();
                return e;
            };
            self.popPath();
            try list.append(gpa, v);
            idx += 1;
            self.skipWs();
            if (self.i >= self.src.len) return self.bad("unterminated array");
            if (self.src[self.i] == ',') {
                self.advance();
                continue;
            }
            if (self.src[self.i] == ']') {
                self.advance();
                return .{ .array = list.items };
            }
            return self.bad("expected ',' or ']' in array");
        }
    }

    fn parseObject(self: *JsonParser, depth: usize) error{ Parse, OutOfMemory }!Value {
        self.advance(); // {
        const gpa = self.gpa;
        const obj = try gpa.create(Value.Object);
        obj.* = .{};
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == '}') {
            self.advance();
            return .{ .object = obj };
        }
        while (true) {
            self.skipWs();
            if (self.i >= self.src.len) return self.bad("unterminated object");
            if (self.src[self.i] != '"') return self.bad("object keys must be strings");
            const key = try self.parseString();
            self.skipWs();
            if (self.i >= self.src.len or self.src[self.i] != ':') return self.bad("expected ':' after object key");
            self.advance();
            self.skipWs();
            self.pushPath(key);
            const v = self.parseValue(depth + 1) catch |e| {
                self.popPath();
                return e;
            };
            self.popPath();
            try obj.put(gpa, key, v);
            self.skipWs();
            if (self.i >= self.src.len) return self.bad("unterminated object");
            if (self.src[self.i] == ',') {
                self.advance();
                continue;
            }
            if (self.src[self.i] == '}') {
                self.advance();
                return .{ .object = obj };
            }
            return self.bad("expected ',' or '}' in object");
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn parseOk(gpa: std.mem.Allocator, text: []const u8) !Value {
    const r = Value.parseJson(gpa, text);
    switch (r) {
        .ok => |v| return v,
        .err => |e| {
            std.debug.print("JSON parse failed at {d}:{d} {s} (path={s})\n", .{ e.line, e.column, e.message, e.path });
            return error.ParseFailed;
        },
    }
}

test "json: basic types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a, "{\"s\":\"hi\",\"n\":42,\"f\":1.5,\"b\":true,\"z\":null,\"arr\":[1,2,3]}");
    try testing.expectEqualStrings("hi", v.field("s").?.asString().?);
    try testing.expectEqual(@as(i64, 42), v.field("n").?.asInt().?);
    try testing.expectEqual(@as(f64, 1.5), v.field("f").?.asFloat().?);
    try testing.expectEqual(true, v.field("b").?.asBool().?);
    try testing.expectEqual(@as(usize, 3), v.field("arr").?.asArray().?.len);
    try testing.expectEqual(Value.null, v.field("z").?);
}

test "json: escapes and Unicode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a, "{\"t\":\"a\\tb\\n\\\"q\\\"\",\"u\":\"\\u20ac\"}");
    try testing.expectEqualStrings("a\tb\n\"q\"", v.field("t").?.asString().?);
    try testing.expectEqualStrings("\u{20ac}", v.field("u").?.asString().?);
}

test "json: negative numbers and exponents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a, "[-12, 1e3, -2.5e-2]");
    const arr = v.asArray().?;
    try testing.expectEqual(@as(i64, -12), arr[0].asInt().?);
    try testing.expectEqual(@as(f64, 1000), arr[1].asFloat().?);
    try testing.expectEqual(@as(f64, -0.025), arr[2].asFloat().?);
}

test "json: duplicate keys are recorded for diagnostics but the last write wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a, "{\"k\":1,\"k\":2}");
    try testing.expectEqual(@as(i64, 2), v.field("k").?.asInt().?);
    try testing.expectEqual(@as(usize, 1), v.asObject().?.dups.items.len);
}

test "json: invalid input returns a diagnostic with position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = Value.parseJson(a, "{\n  \"a\": 1\n  \"b\": 2\n}");
    try testing.expect(r == .err);
    try testing.expectEqual(@as(usize, 3), r.err.line);
    try testing.expectEqualStrings("$", r.err.path);
}

test "json: deep path location" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = Value.parseJson(a, "{\"actions\":[{\"name\":\"x\"},{\"args\":[1,oops]}]}");
    try testing.expect(r == .err);
    try testing.expectEqualStrings("$.actions[1].args[1]", r.err.path);
}

test "json: null values and empty collections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try parseOk(a, "{\"o\":{},\"a\":[],\"s\":\"\"}");
    try testing.expectEqual(@as(usize, 0), v.field("o").?.asObject().?.count());
    try testing.expectEqual(@as(usize, 0), v.field("a").?.asArray().?.len);
    try testing.expectEqualStrings("", v.field("s").?.asString().?);
}
