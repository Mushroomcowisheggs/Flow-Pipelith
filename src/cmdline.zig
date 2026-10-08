//! One-line command editing over a byte-exact argv.
//!
//! A command is `argv` and nothing else: each element is passed to the process byte-for-byte
//! (governing rule 2). This module is the *input surface* for the command line the user asked for —
//! "edit it like a terminal, one line, not one argument per line" — and the presentation that goes
//! back the other way.
//!
//! The splitting rules are a **named convention**, `posix-quotes`, rather than whatever shell the
//! host happens to run (governing rule 3: a mechanism is named explicitly, never guessed per
//! platform). They are deliberately small enough to hold in one's head:
//!
//!   * runs of space, tab, CR and LF separate arguments;
//!   * `'...'` is literal until the closing `'` (no escapes inside);
//!   * `"..."` is literal until the closing `"`, except that a backslash escapes the next
//!     character (`\"` -> `"`, `\\` -> `\`);
//!   * outside quotes a backslash escapes the next character literally;
//!   * `""` is an explicit empty argument;
//!   * an unterminated quote or a trailing backslash is an **error**, reported to the caller and
//!     never reinterpreted. The argv keeps its previous value; nothing is guessed.
//!
//! Quotes and backslashes are *input syntax*, not part of an argument's value: `"-m"` passes the
//! two characters `-m`. Round-tripping is stable: `format` quotes exactly the arguments that
//! `tokenize` would otherwise split or swallow, and `tokenize(format(argv)) == argv`.
//!
//! The argv rows editor (one argument per line) remains the byte-exact escape hatch for arguments
//! that no one-line form can express, e.g. an argument containing a newline.

const std = @import("std");
const testing = std.testing;

/// The one supported convention. Named so the UI can say which rules are in force
/// (rule 3) and so a future convention is an explicit, reviewed addition rather than a default
/// that drifts with the platform.
pub const Convention = enum { posix_quotes };

pub const ParseError = error{
    /// A `'` or `"` was opened and never closed.
    UnterminatedQuote,
    /// The line ends with a bare `\`, so there is nothing for it to escape.
    TrailingBackslash,
    OutOfMemory,
};

/// Splits a command line into argv under `convention`.
pub fn tokenize(alloc: std.mem.Allocator, line: []const u8, convention: Convention) ParseError![]const []const u8 {
    std.debug.assert(convention == .posix_quotes);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (out.items) |item| alloc.free(item);
        out.deinit(alloc);
    }
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    defer cur.deinit(alloc);
    var started = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (started) {
                    try out.append(alloc, try alloc.dupe(u8, cur.items));
                    cur.clearRetainingCapacity();
                    started = false;
                }
                i += 1;
            },
            '\'' => {
                started = true;
                i += 1;
                const close = std.mem.indexOfScalarPos(u8, line, i, '\'') orelse
                    return error.UnterminatedQuote;
                try cur.appendSlice(alloc, line[i..close]);
                i = close + 1;
            },
            '"' => {
                started = true;
                i += 1;
                while (i < line.len) {
                    const d = line[i];
                    if (d == '"') {
                        i += 1;
                        break;
                    }
                    if (d == '\\') {
                        if (i + 1 >= line.len) return error.TrailingBackslash;
                        // Inside double quotes a backslash escapes the next character whatever it is.
                        try cur.append(alloc, line[i + 1]);
                        i += 2;
                    } else {
                        try cur.append(alloc, d);
                        i += 1;
                    }
                } else return error.UnterminatedQuote;
            },
            '\\' => {
                started = true;
                if (i + 1 >= line.len) return error.TrailingBackslash;
                try cur.append(alloc, line[i + 1]);
                i += 2;
            },
            else => {
                started = true;
                try cur.append(alloc, c);
                i += 1;
            },
        }
    }
    if (started) try out.append(alloc, try alloc.dupe(u8, cur.items));
    return out.toOwnedSlice(alloc);
}

/// Renders argv as one copyable line under `convention`.
///
/// This is the *labelled presentation* rule 2 asks for: it is how a command is shown and typed as
/// text, never something applied to the values themselves. Only the arguments that would otherwise
/// be split, swallowed or emptied are quoted; the quoting is visible in the string the user reads.
pub fn format(alloc: std.mem.Allocator, argv: []const []const u8, convention: Convention) ![]const u8 {
    std.debug.assert(convention == .posix_quotes);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, ' ');
        if (needsQuotes(arg)) {
            try out.append(alloc, '"');
            for (arg) |c| {
                if (c == '"' or c == '\\') try out.append(alloc, '\\');
                try out.append(alloc, c);
            }
            try out.append(alloc, '"');
        } else {
            try out.appendSlice(alloc, arg);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn needsQuotes(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n', '"', '\'', '\\' => return true,
            else => {},
        }
    }
    return false;
}

// ── tests ───────────────────────────────────────────────────────────────────

fn expectArgs(expected: []const []const u8, line: []const u8) !void {
    const alloc = testing.allocator;
    const got = try tokenize(alloc, line, .posix_quotes);
    defer freeArgs(alloc, got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

fn freeArgs(alloc: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| alloc.free(a);
    alloc.free(args);
}

test "cmdline: plain words split on runs of whitespace" {
    try expectArgs(&.{ "git", "commit", "-m" }, "git   commit\t-m");
}

test "cmdline: double quotes hold spaces and pass the content byte-for-byte" {
    try expectArgs(&.{ "git", "commit", "-m", "fix the thing" }, "git commit -m \"fix the thing\"");
}

test "cmdline: single quotes are literal (no escapes inside)" {
    try expectArgs(&.{ "echo", "a\\b'c" }, "echo 'a\\b'\"'\"'c'");
}

test "cmdline: backslash escapes outside quotes" {
    try expectArgs(&.{ "echo", "a b", "c\"d" }, "echo a\\ b c\\\"d");
}

test "cmdline: an explicit empty argument survives" {
    try expectArgs(&.{ "tool", "", "x" }, "tool \"\" x");
}

test "cmdline: adjacent quotes join into one argument" {
    try expectArgs(&.{ "ab c", "d" }, "\"ab\"' 'c d");
}

test "cmdline: CR and LF separate like spaces (a pasted Windows line is not one argument)" {
    try expectArgs(&.{ "git", "status" }, "git status\r\n");
}

test "cmdline: an unterminated quote is an error, never a guess" {
    const alloc = testing.allocator;
    try testing.expectError(error.UnterminatedQuote, tokenize(alloc, "echo \"open", .posix_quotes));
    try testing.expectError(error.UnterminatedQuote, tokenize(alloc, "echo 'open", .posix_quotes));
}

test "cmdline: a trailing backslash is an error, never a guess" {
    const alloc = testing.allocator;
    try testing.expectError(error.TrailingBackslash, tokenize(alloc, "echo x\\", .posix_quotes));
    try testing.expectError(error.TrailingBackslash, tokenize(alloc, "echo \"x\\", .posix_quotes));
}

test "cmdline: format quotes only what would otherwise change" {
    const alloc = testing.allocator;
    const cases = [_]struct { arg: []const u8, want: []const u8 }{
        .{ .arg = "plain", .want = "plain" },
        .{ .arg = "has space", .want = "\"has space\"" },
        .{ .arg = "say\"hi", .want = "\"say\\\"hi\"" },
        .{ .arg = "back\\slash", .want = "\"back\\\\slash\"" },
        .{ .arg = "", .want = "\"\"" },
    };
    for (cases) |c| {
        const line = try format(alloc, &.{c.arg}, .posix_quotes);
        defer alloc.free(line);
        try testing.expectEqualStrings(c.want, line);
    }
}

test "cmdline: format then tokenize is the identity for every hard case" {
    const alloc = testing.allocator;
    const argv = [_][]const u8{
        "C:\\Program Files\\tool.exe",
        "-m",
        "message with \"quotes\" and \\backslashes\\",
        "it's",
        "",
        "tab\there",
    };
    const line = try format(alloc, &argv, .posix_quotes);
    defer alloc.free(line);
    const back = try tokenize(alloc, line, .posix_quotes);
    defer freeArgs(alloc, back);
    try testing.expectEqual(argv.len, back.len);
    for (argv, back) |e, g| try testing.expectEqualStrings(e, g);
}

test "cmdline: an empty line is an empty command, not an empty argument" {
    try expectArgs(&.{}, "");
    try expectArgs(&.{}, "   \t ");
}
