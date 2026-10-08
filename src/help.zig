//! Rule-based extraction of a tool's own interface from its `--help` output.
//!
//! Why this exists: the point of the GUI is that a user should not have to remember CLI syntax or
//! consult a help table. They pick a program, and the program tells us what it can do — so the
//! interface can be offered as something to choose from rather than something to recall.
//!
//! There is no model anywhere in this path (governing rule 6): the extraction is a set of
//! deterministic rules over the text, the argv that produced the text is reported alongside the
//! result, and the raw text is always available for review, so a wrong guess is visible rather than
//! silently trusted.
//!
//! The rules were written against the real, mutually inconsistent output of git, node, python,
//! cmake and make — not against an imagined format. Those five disagree about almost everything:
//!
//!   * python puts options at column 0 and separates with ` : `; git indents its commands by 3;
//!     cmake and node indent by 2.
//!   * make's token is `-b, -m` — a token can contain a space, so the token/description boundary is
//!     the first run of 2+ spaces, never the first space.
//!   * node and make often leave the description on the following, more-indented line.
//!   * cmake writes `-S <path-to-source>          = Explicitly specify a source directory.`
//!   * section headings are `Options:` (node, make), `Options` (cmake) and
//!     `start a working area (see also: git help tutorial)` (git) — so "ends with a colon" is not a
//!     usable test, and "the next line is an entry" is.

const std = @import("std");

pub const Kind = enum { option, command };

pub const Item = struct {
    kind: Kind,
    /// The text to insert, exactly as the help printed it (e.g. `-C DIRECTORY, --directory=DIRECTORY`).
    /// Kept verbatim rather than normalised: guessing which of several spellings the user wants is
    /// the kind of decision this module deliberately does not make.
    token: []const u8,
    description: []const u8,
    /// Nearest preceding section heading, so the UI can group items the way the tool groups them.
    section: []const u8,
};

pub const Options = struct {
    /// Bounds memory on enormous help screens (ffmpeg in particular). Items past the cap are dropped.
    max_items: usize = 400,
    /// Bounds each description; some tools wrap prose for hundreds of lines.
    max_description: usize = 512,
};

/// One non-blank line, with its indentation measured in columns.
const Line = struct { indent: usize, text: []const u8 };

/// A line's token/description boundary, when it has one.
const Split = struct { at: usize };

fn indentWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |c| {
        if (c == ' ') {
            w += 1;
        } else if (c == '\t') {
            // Tabs are treated as advancing to a 4-column stop, which is what the tools that use
            // them (make on Unix, some BSD tools) intend.
            w += 4;
        } else break;
    }
    return w;
}

/// Finds where a line's token ends and its description begins.
///
/// The boundary is the first occurrence of either a run of 2+ spaces, or a single space wrapping a
/// separator (` : `, ` = `, ` -- `). A single space alone is *not* a boundary — `-C DIRECTORY,
/// --directory=DIRECTORY` is one token — and neither is a separator without a space after it, which
/// is what keeps `-B, --always-make` intact.
fn findSplit(text: []const u8) ?Split {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ' ' and text[i] != '\t') continue;

        var j = i;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        // A run of 2+ spaces is always a boundary.
        if (j - i >= 2) return .{ .at = i };
        // Exactly one space: a boundary only when it wraps `:`, `=` or `--`. ffmpeg writes
        // `-h long -- print more options`, where the separator really is a spaced double dash.
        if (j < text.len) {
            const seps = [_][]const u8{ ":", "=", "--" };
            for (seps) |sep| {
                if (std.mem.startsWith(u8, text[j..], sep)) {
                    const after = j + sep.len;
                    if (after < text.len and (text[after] == ' ' or text[after] == '\t')) {
                        return .{ .at = i };
                    }
                }
            }
        }
        i = j - 1;
    }
    return null;
}

/// Whether a bare word can be a subcommand rather than prose. Deliberately narrow: a line like
/// `cmake [options] <path-to-source>` must not become an "item".
fn isCommandWord(t: []const u8) bool {
    if (t.len == 0 or t.len > 40) return false;
    if (!std.ascii.isAlphabetic(t[0])) return false;
    for (t) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '+';
        if (!ok) return false;
    }
    return true;
}

/// Whether the text before the boundary is a plausible token. Options may contain spaces
/// (`-S <path-to-source>`, `-b, -m`); commands may not.
///
/// Requiring the first character to be `-` is also what rejects usage-line scaffolding such as
/// `[-C <path>]` or `[--exec-path[=<path>]]`, which always starts with a bracket — so no extra
/// bracket test is needed, and adding one would wrongly discard a real option like
/// `--debug[=FLAGS]` or a multi-spelling token like `-v | --version`.
fn plausibleToken(t: []const u8) bool {
    if (t.len == 0 or t.len > 80) return false;
    if (t[0] == '-') return true;
    return isCommandWord(t);
}

fn classify(token: []const u8) Kind {
    return if (token.len > 0 and token[0] == '-') .option else .command;
}

/// Strips the separator punctuation some tools put in front of the description
/// (python's `: issue warnings`, cmake's `= Explicitly specify ...`, ffmpeg's `-- print basic options`).
fn trimDescriptionLead(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t");
    while (t.len > 0) {
        if (t[0] == ':' or t[0] == '=') {
            t = std.mem.trim(u8, t[1..], " \t");
            continue;
        }
        // A leading `--` is a separator, not content: a lone `-` is left alone, since descriptions
        // like `-1 means unlimited` are real.
        if (std.mem.startsWith(u8, t, "--")) {
            t = std.mem.trim(u8, t[2..], " \t");
            continue;
        }
        break;
    }
    return t;
}

/// Splits `text` into a token and the description that follows it on the same line.
fn splitLine(text: []const u8, opts: Options) ?struct { token: []const u8, desc: []const u8 } {
    const sp = findSplit(text) orelse {
        // No boundary on this line: only an option-looking token is accepted, and its description is
        // expected on the following lines (node and make both do this).
        if (text.len > 1 and text[0] == '-' and plausibleToken(text)) {
            return .{ .token = text, .desc = "" };
        }
        return null;
    };
    const token = std.mem.trim(u8, text[0..sp.at], " \t");
    if (!plausibleToken(token)) return null;
    const rest_raw = text[sp.at..];
    var desc = trimDescriptionLead(rest_raw);
    if (desc.len > opts.max_description) desc = desc[0..opts.max_description];
    return .{ .token = token, .desc = desc };
}

const Collector = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    items: std.ArrayListUnmanaged(Item) = .empty,
    desc: std.ArrayListUnmanaged(u8) = .empty,
    open: bool = false,
    token: []const u8 = "",
    kind: Kind = .option,
    section: []const u8 = "",
    indent: usize = 0,

    fn flush(c: *Collector) !void {
        if (!c.open) return;
        c.open = false;
        if (c.items.items.len >= c.opts.max_items) {
            c.desc.clearRetainingCapacity();
            return;
        }
        const d = try c.alloc.dupe(u8, std.mem.trim(u8, c.desc.items, " \t"));
        try c.items.append(c.alloc, .{
            .kind = c.kind,
            .token = c.token,
            .description = d,
            .section = c.section,
        });
        c.desc.clearRetainingCapacity();
    }

    fn openItem(c: *Collector, token: []const u8, desc: []const u8, indent: usize) !void {
        try c.flush();
        c.open = true;
        c.token = token;
        c.kind = classify(token);
        c.indent = indent;
        c.desc.clearRetainingCapacity();
        if (desc.len > 0) try c.desc.appendSlice(c.alloc, desc);
    }

    /// Joins a wrapped continuation line onto the description being collected.
    fn append(c: *Collector, text: []const u8) !void {
        if (!c.open) return;
        if (c.desc.items.len >= c.opts.max_description) return;
        if (c.desc.items.len > 0) try c.desc.append(c.alloc, ' ');
        try c.desc.appendSlice(c.alloc, text);
    }
};

/// Drops the colon a heading may end with. Handles the full-width `：` as well: a localized tool
/// (this machine's `make` is Chinese) uses it, and leaving it in makes the section label look broken.
fn trimSectionSuffix(s: []const u8) []const u8 {
    var t = std.mem.trimEnd(u8, s, " \t");
    while (t.len > 0) {
        const last = t[t.len - 1];
        if (last == ':') {
            t = std.mem.trimEnd(u8, t[0 .. t.len - 1], " \t");
            continue;
        }
        // U+FF1A full-width colon is three UTF-8 bytes.
        if (t.len >= 3 and std.mem.eql(u8, t[t.len - 3 ..], "\u{FF1A}")) {
            t = std.mem.trimEnd(u8, t[0 .. t.len - 3], " \t");
            continue;
        }
        break;
    }
    return t;
}

/// Extracts pickable items from help text. Pure: no process, no I/O, so it is directly testable
/// against captured real output.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, opts: Options) ![]Item {
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        try lines.append(alloc, .{ .indent = indentWidth(line), .text = std.mem.trimEnd(u8, trimmed, " \t") });
    }

    var c = Collector{ .alloc = alloc, .opts = opts };
    for (lines.items, 0..) |ln, i| {
        // Section heading: at column 0, and the next line is an entry. "Ends with a colon" is not a
        // usable test — git's headings do not have one — and neither is "is capitalised".
        const next_is_item = i + 1 < lines.items.len and
            splitLine(lines.items[i + 1].text, opts) != null;
        if (ln.indent == 0 and next_is_item and splitLine(ln.text, opts) == null) {
            try c.flush();
            c.section = trimSectionSuffix(ln.text);
            continue;
        }

        if (splitLine(ln.text, opts)) |sp| {
            try c.openItem(sp.token, sp.desc, ln.indent);
            continue;
        }

        // Not an entry: join it to the open item only if it is indented further than that item's
        // token, which is how every tool here wraps a description. Prose at column 0 (cmake's
        // paragraphs, git's usage block) is left alone rather than polluting the previous entry.
        if (c.open and ln.indent > c.indent) {
            try c.append(ln.text);
        }
    }
    try c.flush();
    return c.items.items;
}

// ── Tests: fixtures are the real output shapes of the tools on this machine ─────────────────────

const testing = std.testing;

const git_fixture =
    \\usage: git [-v | --version] [-h | --help] [-C <path>] [-c <name>=<value>]
    \\           [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]
    \\           <command> [<args>]
    \\
    \\These are common Git commands used in various situations:
    \\
    \\start a working area (see also: git help tutorial)
    \\   clone      Clone a repository into a new directory
    \\   init       Create an empty Git repository or reinitialize an existing one
    \\
    \\work on the current change (see also: git help everyday)
    \\   add        Add file contents to the index
    \\   mv         Move or rename a file, a directory, or a symlink
;

test "help: git — indented commands, headings without a colon, usage block ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, git_fixture, .{});
    try testing.expectEqual(@as(usize, 4), items.len);

    try testing.expectEqual(Kind.command, items[0].kind);
    try testing.expectEqualStrings("clone", items[0].token);
    try testing.expectEqualStrings("Clone a repository into a new directory", items[0].description);
    try testing.expectEqualStrings("start a working area (see also: git help tutorial)", items[0].section);

    try testing.expectEqualStrings("add", items[2].token);
    try testing.expectEqualStrings("work on the current change (see also: git help everyday)", items[2].section);

    // The usage block must not contribute items, and `These are common Git commands...` must not
    // become a section heading (the line after it is blank, then a heading).
    for (items) |item| {
        try testing.expect(!std.mem.startsWith(u8, item.token, "["));
        try testing.expect(!std.mem.eql(u8, item.token, "usage:"));
    }
}

const node_fixture =
    \\Usage: node [options] [ script.js ] [arguments]
    \\       node inspect [options] [ script.js | host:port ] [arguments]
    \\
    \\Options:
    \\  -                           script read from stdin (default if no
    \\                              file name is provided, interactive mode
    \\                              if a tty)
    \\  --                          indicate the end of node options
    \\  --abort-on-uncaught-exception
    \\                              aborting instead of exiting causes a
    \\                              core file to be generated for analysis
    \\  --allow-addons              allow use of addons when any
    \\                              permissions are set
;

test "help: node — description on the following line, and wrapped continuations joined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, node_fixture, .{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Options", items[0].section);

    try testing.expectEqual(Kind.option, items[0].kind);
    try testing.expectEqualStrings("-", items[0].token);
    try testing.expectEqualStrings(
        "script read from stdin (default if no file name is provided, interactive mode if a tty)",
        items[0].description,
    );

    // A token alone on its line takes its description from the lines beneath it.
    try testing.expectEqualStrings("--abort-on-uncaught-exception", items[2].token);
    try testing.expectEqualStrings(
        "aborting instead of exiting causes a core file to be generated for analysis",
        items[2].description,
    );
    try testing.expectEqualStrings("--allow-addons", items[3].token);
    try testing.expectEqualStrings("allow use of addons when any permissions are set", items[3].description);
}

const python_fixture =
    \\usage: python.exe [option] ... [-c cmd | -m mod | file | -] [arg] ...
    \\Options and arguments (and corresponding environment variables):
    \\-b     : issue warnings about str(bytes_instance), str(bytearray_instance)
    \\         and comparing bytes/bytearray with str. (-bb: issue errors)
    \\-B     : don't write .pyc files on import; also PYTHONDONTWRITEBYTECODE=x
    \\-c cmd : program passed in as string (terminates option list)
    \\-m mod : run library module as a script (terminates option list)
;

test "help: python — column-0 options, ` : ` separator, token containing a space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, python_fixture, .{});
    try testing.expectEqual(@as(usize, 4), items.len);

    try testing.expectEqualStrings("-b", items[0].token);
    try testing.expectEqualStrings(
        "issue warnings about str(bytes_instance), str(bytearray_instance) and comparing bytes/bytearray with str. (-bb: issue errors)",
        items[0].description,
    );
    // The separator punctuation is stripped rather than becoming part of the description.
    try testing.expect(!std.mem.startsWith(u8, items[0].description, ":"));
    try testing.expectEqualStrings("-B", items[1].token);

    // `-c cmd : ...` — a token with a space, split at the spaced colon, not at the first space.
    try testing.expectEqualStrings("-c cmd", items[2].token);
    try testing.expectEqualStrings("program passed in as string (terminates option list)", items[2].description);
    try testing.expectEqualStrings("-m mod", items[3].token);
}

const cmake_fixture =
    \\Usage
    \\
    \\  cmake [options] <path-to-source>
    \\  cmake [options] -S <path-to-source> -B <path-to-build>
    \\
    \\Specify a source directory to (re-)generate a build system for it in the
    \\current working directory.
    \\
    \\Options
    \\  -S <path-to-source>          = Explicitly specify a source directory.
    \\  -B <path-to-build>           = Explicitly specify a build directory.
;

test "help: cmake — bare-word heading, usage patterns and prose rejected, `= ` stripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, cmake_fixture, .{});
    try testing.expectEqual(@as(usize, 2), items.len);

    try testing.expectEqualStrings("Options", items[0].section);
    try testing.expectEqualStrings("-S <path-to-source>", items[0].token);
    try testing.expectEqualStrings("Explicitly specify a source directory.", items[0].description);
    try testing.expect(!std.mem.startsWith(u8, items[0].description, "="));

    // `cmake [options] <path-to-source>` must not become a command item, and the prose paragraph at
    // column 0 must not be appended to anything.
    for (items) |item| {
        try testing.expect(std.mem.indexOf(u8, item.token, "cmake") == null);
    }
    try testing.expectEqualStrings("-B <path-to-build>", items[1].token);
}

const make_fixture =
    \\Usage: make [options] [target] ...
    \\Options:
    \\  -b, -m                      Ignored for compatibility.
    \\  -B, --always-make           Unconditionally make all targets.
    \\  -C DIRECTORY, --directory=DIRECTORY
    \\                              Change to DIRECTORY before doing anything.
    \\  --debug[=FLAGS]             Print various types of debugging information.
;

test "help: make — a token containing a comma and space, description on the next line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, make_fixture, .{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Options", items[0].section);

    // Split at the run of spaces, so the whole comma-separated spelling stays one token.
    try testing.expectEqualStrings("-b, -m", items[0].token);
    try testing.expectEqualStrings("Ignored for compatibility.", items[0].description);
    try testing.expectEqualStrings("-B, --always-make", items[1].token);
    try testing.expectEqualStrings("-C DIRECTORY, --directory=DIRECTORY", items[2].token);
    try testing.expectEqualStrings("Change to DIRECTORY before doing anything.", items[2].description);
    try testing.expectEqualStrings("--debug[=FLAGS]", items[3].token);
}

const ffmpeg_fixture =
    \\Getting help:
    \\    -h      -- print basic options
    \\    -h long -- print more options
    \\    -h full -- print all options (including all format and codec specific options, very long)
    \\
    \\Print help / information / capabilities:
    \\    -L                  show license
    \\    -h <topic>          show help
    \\    -version            show version
;

test "help: ffmpeg — spaced double-dash separator must not become part of the token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try parse(a, ffmpeg_fixture, .{});
    try testing.expectEqual(@as(usize, 6), items.len);
    try testing.expectEqualStrings("Getting help", items[0].section);

    try testing.expectEqualStrings("-h", items[0].token);
    try testing.expectEqualStrings("print basic options", items[0].description);

    // The regression this test exists for: `-h long -- print more options` has no run of 2+ spaces,
    // so without the spaced-`--` rule the whole line was taken as one token and the description was
    // lost — offering the user an unusable token.
    try testing.expectEqualStrings("-h long", items[1].token);
    try testing.expectEqualStrings("print more options", items[1].description);
    try testing.expectEqualStrings("-h full", items[2].token);

    try testing.expectEqualStrings("Print help / information / capabilities", items[3].section);
    try testing.expectEqualStrings("-L", items[3].token);
    try testing.expectEqualStrings("-h <topic>", items[4].token);
}

test "help: a localized heading ending in a full-width colon is still a heading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This machine's `make` is Chinese-localized; the heading is `选项：`.
    const items = try parse(a,
        \\Usage: make [options] [target] ...
        \\选项：
        \\  -b, -m                      Ignored for compatibility.
        \\  -B, --always-make           Unconditionally make all targets.
    , .{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("选项", items[0].section);
    try testing.expectEqualStrings("-b, -m", items[0].token);
}

test "platform/encoding: a child's ANSI output is converted to UTF-8" {
    const platform = @import("platform.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Already UTF-8: returned untouched, no conversion attempted.
    const utf8 = "选项：-h -- help";
    try testing.expectEqualStrings(utf8, try platform.toUtf8(a, utf8));

    // Empty input is not an encoding error.
    try testing.expectEqualStrings("", try platform.toUtf8(a, ""));

    if (@import("builtin").os.tag != .windows) return; // no code page to consult elsewhere

    // The exact bytes a Chinese-localized `make` printed for `选项：`, observed on this machine:
    // 选=D1A1, 项=CFEE, full-width colon=A3BA in CP936. Read as UTF-8 these are invalid, which is
    // exactly how the bug this test guards against was found.
    const gbk = [_]u8{ 0xd1, 0xa1, 0xcf, 0xee, 0xa3, 0xba };
    try testing.expect(!std.unicode.utf8ValidateSlice(&gbk));
    const converted = try platform.toUtf8(a, &gbk);
    try testing.expect(std.unicode.utf8ValidateSlice(converted));
    try testing.expectEqualStrings("选项：", converted);
}

test "help: real CRLF-captured localized output parses as expected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Byte-for-byte what `make --help` produced on this machine: Chinese-localized, full-width
    // colons, and CRLF line endings. The LF-only fixture above passed while this failed, which is
    // the whole reason it exists.
    const captured = "用法：make.EXE [选项] [目标] ...\r\n" ++
        "选项：\r\n" ++
        "  -b, -m                      Ignored for compatibility.\r\n" ++
        "  -C DIRECTORY, --directory=DIRECTORY\r\n" ++
        "                              Change to DIRECTORY before doing anything.\r\n";

    const items = try parse(a, captured, .{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("选项", items[0].section);
    try testing.expectEqualStrings("-b, -m", items[0].token);
    try testing.expectEqualStrings("Ignored for compatibility.", items[0].description);
    try testing.expectEqualStrings("-C DIRECTORY, --directory=DIRECTORY", items[1].token);
    try testing.expectEqualStrings("Change to DIRECTORY before doing anything.", items[1].description);
}

test "help: the item cap bounds a huge help screen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (0..500) |i| {
        try text.appendSlice(a, try std.fmt.allocPrint(a, "  --flag{d}    description {d}\n", .{ i, i }));
    }
    const items = try parse(a, text.items, .{ .max_items = 10 });
    try testing.expectEqual(@as(usize, 10), items.len);
    try testing.expectEqualStrings("--flag0", items[0].token);
}

test "help: empty and prose-only input yield nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try parse(a, "", .{})).len);
    try testing.expectEqual(@as(usize, 0), (try parse(a, "no options here\njust some prose.\n", .{})).len);
}
