//! JSON serialization: `Value` -> text.
//!
//! Why not `std.json.Stringify`: the RPC layer needs to build lots of CDL/graph structures by hand
//! as `Value` trees and then emit them (rather than relying on type reflection), and an explicit
//! serialization function is more controllable than a generic stringify; it also makes it easy to
//! guarantee that "the field shapes the frontend sees" match `docs/RPC.md` exactly.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Options = struct {
    /// Whether to pretty-print (2-space indent). Event pushes use the compact form, file archives use pretty.
    pretty: bool = false,
    indent: usize = 2,
};

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn writeValue(w: *std.Io.Writer, v: Value, opts: Options, depth: usize) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f) or std.math.isInf(f)) {
                try w.writeAll("null");
            } else if (f == @trunc(f) and @abs(f) < 1e15) {
                try w.print("{d}.0", .{@as(i64, @intFromFloat(f))});
            } else {
                try w.print("{d}", .{f});
            }
        },
        .string => |s| try writeString(w, s),
        .array => |arr| {
            if (arr.len == 0) {
                try w.writeAll("[]");
                return;
            }
            try w.writeByte('[');
            for (arr, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newlineIndent(w, opts, depth + 1);
                try writeValue(w, item, opts, depth + 1);
            }
            try newlineIndent(w, opts, depth);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.count() == 0) {
                try w.writeAll("{}");
                return;
            }
            try w.writeByte('{');
            for (0..o.count()) |i| {
                if (i > 0) try w.writeByte(',');
                try newlineIndent(w, opts, depth + 1);
                const e = o.at(i);
                try writeString(w, e.key);
                try w.writeByte(':');
                if (opts.pretty) try w.writeByte(' ');
                try writeValue(w, e.value, opts, depth + 1);
            }
            try newlineIndent(w, opts, depth);
            try w.writeByte('}');
        },
    }
}

fn newlineIndent(w: *std.Io.Writer, opts: Options, depth: usize) !void {
    if (!opts.pretty) return;
    try w.writeByte('\n');
    var i: usize = 0;
    while (i < depth * opts.indent) : (i += 1) try w.writeByte(' ');
}

/// Serialize into freshly allocated memory (the caller must free it).
pub fn toAlloc(gpa: std.mem.Allocator, v: Value, opts: Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try writeValue(&aw.writer, v, opts, 0);
    return aw.toOwnedSlice();
}

/// Serialize into a caller-provided buffer; returns the length, or `error.WriteFailed` when the
/// space is insufficient (matching the error set of `std.Io.Writer.fixed`).
pub fn toBuf(buf: []u8, v: Value, opts: Options) error{WriteFailed}!usize {
    var w: std.Io.Writer = .fixed(buf);
    try writeValue(&w, v, opts, 0);
    return w.end;
}

// ── Construction helpers (used heavily by the RPC layer) ─────────

pub const Builder = struct {
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn obj(self: Builder) !*Value.Object {
        const o = try self.gpa.create(Value.Object);
        o.* = .{};
        return o;
    }

    pub fn array(self: Builder, items: []const Value) !Value {
        const buf = try self.gpa.dupe(Value, items);
        return .{ .array = buf };
    }

    /// Build an array from an array of string literals.
    pub fn strArray(self: Builder, items: []const []const u8) !Value {
        const buf = try self.gpa.alloc(Value, items.len);
        for (items, 0..) |s, i| buf[i] = .{ .string = s };
        return .{ .array = buf };
    }
};

/// Convenience: `put(o, "key", .{.string = s})`
pub fn put(gpa: std.mem.Allocator, o: *Value.Object, key: []const u8, v: Value) !void {
    try o.put(gpa, key, v);
}

pub fn str(s: []const u8) Value {
    return .{ .string = s };
}

pub fn optStr(s: ?[]const u8) Value {
    return if (s) |x| .{ .string = x } else .null;
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "emit: basic types" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const o = try Builder.init(a).obj();
    try put(a, o, "s", str("hi"));
    try put(a, o, "n", .{ .int = -3 });
    try put(a, o, "f", .{ .float = 2.5 });
    try put(a, o, "b", .{ .bool = true });
    try put(a, o, "z", .null);

    const out = try toAlloc(gpa, .{ .object = o }, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("{\"s\":\"hi\",\"n\":-3,\"f\":2.5,\"b\":true,\"z\":null}", out);
}

test "emit: escaping and non-ASCII text" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const o = try Builder.init(a).obj();
    try put(a, o, "label", str("Convert format \u{20ac} \"A\"\n\tB\\C"));
    const out = try toAlloc(gpa, .{ .object = o }, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("{\"label\":\"Convert format \u{20ac} \\\"A\\\"\\n\\tB\\\\C\"}", out);
}

test "emit: pretty output" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try Builder.init(a).obj();
    try put(a, inner, "a", .{ .int = 1 });
    const arr = try a.alloc(Value, 2);
    arr[0] = .{ .object = inner };
    arr[1] = .{ .int = 2 };
    const root = try Builder.init(a).obj();
    try put(a, root, "list", .{ .array = arr });

    const out = try toAlloc(gpa, .{ .object = root }, .{ .pretty = true });
    defer gpa.free(out);
    const expected =
        \\{
        \\  "list": [
        \\    {
        \\      "a": 1
        \\    },
        \\    2
        \\  ]
        \\}
    ;
    try testing.expectEqualStrings(expected, out);
}

test "emit: empty collections and whole-number floats" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const o = try Builder.init(a).obj();
    try put(a, o, "arr", .{ .array = &.{} });
    try put(a, o, "obj", .{ .object = try Builder.init(a).obj() });
    try put(a, o, "whole", .{ .float = 3.0 });
    const out = try toAlloc(gpa, .{ .object = o }, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("{\"arr\":[],\"obj\":{},\"whole\":3.0}", out);
}

test "emit: toBuf runs out of space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try Builder.init(a).obj();
    try put(a, o, "key", str("value"));

    var small: [4]u8 = undefined;
    try testing.expectError(error.WriteFailed, toBuf(&small, .{ .object = o }, .{}));

    var big: [256]u8 = undefined;
    const n = try toBuf(&big, .{ .object = o }, .{});
    try testing.expectEqualStrings("{\"key\":\"value\"}", big[0..n]);
}
