//! Tool packs — optional tool definitions that live as **files outside the program**.
//!
//! Nothing about a tool is compiled into the binary, and nothing is installed next to it either: a
//! fresh installation offers **zero** packs and loads **zero** tools. Packs are directories holding a
//! `pack.json` manifest plus `*.cdl` files, and they are read from exactly these places, in this
//! order (rule 3 — the search path is named, never guessed):
//!
//!   1. `<tool dir>/packs/<id>/`  — shared packs, if an administrator put any beside the executable
//!   2. `<state dir>/packs/<id>/` — the user's own packs, inside `.pipelith` (rule 4)
//!   3. every directory named with `--packs-dir <dir>` (repeatable) — the highest precedence, and how
//!                                  a run can point at a pack collection it keeps elsewhere
//!
//! A later source with the same id replaces an earlier one in full: the same precedence rule the CDL
//! loader uses (explicit > user > shared).
//!
//! Listing installs nothing. Installing a pack (`pack.load`, the library's Load button, `--load-pack`)
//! copies its CDL files into `<state dir>/cdl/`, the one directory the engine loads tools from, so an
//! installed tool is an ordinary user tool: editable, deletable, and shadowed by a project-local CDL
//! of the same name. An existing file whose bytes differ is reported as a conflict and left exactly
//! as it was — a pack never overwrites the user's own version of a tool (rule 2).

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin.zig");
const cdl = @import("cdl.zig");
const value = @import("value.zig");

/// File name of a pack's manifest inside its directory.
pub const manifest_name = "pack.json";

/// Directory name packs live in, both next to the executable and under the state directory.
pub const packs_dir_name = "packs";

/// Directory (under the state directory) that installed tools are written to. It is also the one the
/// engine scans at startup, so "installed" and "loaded" can never disagree.
pub const installed_dir_name = "cdl";

pub const Source = enum {
    /// A directory next to the executable (empty unless someone put packs there).
    exe_dir,
    /// A directory inside the state directory (`<tool dir>/.pipelith/packs`).
    state_dir,
    /// A directory named on the command line (`--packs-dir`).
    explicit,

    pub fn wire(self: Source) []const u8 {
        return switch (self) {
            .exe_dir => "exe-dir",
            .state_dir => "state-dir",
            .explicit => "explicit",
        };
    }
};

/// One tool file offered by a pack: the name it is installed as, and its CDL source.
pub const Tool = struct {
    file: []const u8,
    text: []const u8,
};

pub const Pack = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    platforms: []const []const u8 = &.{},
    /// Where the pack came from, as declared by its manifest ("curated", "machine", "os-base", ...).
    origin: []const u8 = "",
    /// Which named directory the pack was found in.
    source: Source,
    /// Filesystem directory the pack was read from. Every pack is a directory on disk — nothing is
    /// compiled into the program — so `discover` always sets this; it stays optional only for tests
    /// that build a `Pack` by hand.
    dir: ?[]const u8 = null,
    tools: []const Tool = &.{},
};

/// The manifest fields of one `pack.json`, with the caller's fallbacks applied.
pub const Meta = struct {
    label: []const u8,
    description: []const u8 = "",
    platforms: []const []const u8 = &.{},
    origin: []const u8 = "",
};

/// Parse `pack.json`. A pack whose manifest is missing or unparsable still works — its directory name
/// is the id and the label — because a manifest must not be able to hide tools the user dropped in.
pub fn parseMeta(a: std.mem.Allocator, text: []const u8, fallback: []const u8) Meta {
    const parsed = value.Value.parseJson(a, text);
    if (parsed != .ok) return .{ .label = fallback };
    const root = parsed.ok;
    var meta = Meta{
        .label = if (root.field("label")) |x| (x.asString() orelse fallback) else fallback,
        .description = if (root.field("description")) |x| (x.asString() orelse "") else "",
        .origin = if (root.field("origin")) |x| (x.asString() orelse "") else "",
    };
    if (root.field("platforms")) |p| {
        if (p.asArray()) |arr| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |item| {
                if (item.asString()) |s| list.append(a, s) catch break;
            }
            meta.platforms = list.items;
        }
    }
    return meta;
}

/// A tool file's name without its `.cdl` extension — the name a user sees in the library and the
/// name the pack's tools are reported under. Pack files keep the two identical (the test suite
/// asserts it), so this is also the CDL's own `name`.
pub fn stem(file: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file, ".cdl")) file[0 .. file.len - ".cdl".len] else file;
}

/// Scan a directory of packs (`<dir_path>/<id>/…`). A missing directory simply has no packs.
pub fn scanDir(io: Io, a: std.mem.Allocator, dir_path: []const u8, source: Source) []const Pack {
    var list: std.ArrayListUnmanaged(Pack) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const id = a.dupe(u8, entry.name) catch break;
        const pack_dir = std.fs.path.join(a, &.{ dir_path, id }) catch break;
        const pack = readPackDir(io, a, id, pack_dir, source) orelse continue;
        list.append(a, pack) catch break;
    }
    return list.items;
}

fn readPackDir(io: Io, a: std.mem.Allocator, id: []const u8, pack_dir: []const u8, source: Source) ?Pack {
    var dir = Io.Dir.cwd().openDir(io, pack_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var tools: std.ArrayListUnmanaged(Tool) = .empty;
    var meta_text: []const u8 = "";
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cdl") and !std.mem.eql(u8, entry.name, manifest_name)) continue;
        const full = std.fs.path.join(a, &.{ pack_dir, entry.name }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(io, full, a, .limited(1024 * 1024)) catch continue;
        if (std.mem.eql(u8, entry.name, manifest_name)) {
            meta_text = text;
            continue;
        }
        tools.append(a, .{ .file = a.dupe(u8, entry.name) catch continue, .text = text }) catch break;
    }
    const meta = if (meta_text.len > 0) parseMeta(a, meta_text, id) else Meta{ .label = id };
    return .{
        .id = id,
        .label = meta.label,
        .description = meta.description,
        .platforms = meta.platforms,
        .origin = meta.origin,
        .source = source,
        .dir = pack_dir,
        .tools = tools.items,
    };
}

/// Every available pack, lowest precedence first: `<tool dir>/packs`, `<state dir>/packs`, then each
/// `--packs-dir` in the order given. A later pack with the same id replaces the earlier one in full.
///
/// `state_dir` is passed in rather than looked up so the caller's state directory wins — the GUI,
/// the CLI and a hermetic `--state-dir` run must all search the same place they install into.
pub fn discover(
    io: Io,
    a: std.mem.Allocator,
    state_dir: ?[]const u8,
    extra_dirs: []const []const u8,
) []const Pack {
    var by_id: std.StringArrayHashMapUnmanaged(Pack) = .empty;
    for ([_]struct { dir: ?[]const u8, source: Source }{
        .{ .dir = tryPacksDir(io, a, builtin.toolDir(io, a) catch null), .source = .exe_dir },
        .{ .dir = tryPacksDir(io, a, state_dir), .source = .state_dir },
    }) |root| {
        const dir_path = root.dir orelse continue;
        for (scanDir(io, a, dir_path, root.source)) |p| by_id.put(a, p.id, p) catch {};
    }
    // A named directory is a pack collection as it stands (not `<dir>/packs`): the user points at the
    // folder that holds the packs.
    for (extra_dirs) |dir_path| {
        for (scanDir(io, a, dir_path, .explicit)) |p| by_id.put(a, p.id, p) catch {};
    }
    var list: std.ArrayListUnmanaged(Pack) = .empty;
    var it = by_id.iterator();
    while (it.next()) |entry| list.append(a, entry.value_ptr.*) catch break;
    std.mem.sort(Pack, list.items, {}, struct {
        fn lessThan(_: void, lhs: Pack, rhs: Pack) bool {
            return std.mem.lessThan(u8, lhs.id, rhs.id);
        }
    }.lessThan);
    return list.items;
}

/// The directories `discover` searches, for the UI to show and for `pack.list` to report.
pub fn searchPaths(
    io: Io,
    a: std.mem.Allocator,
    state_dir: ?[]const u8,
    extra_dirs: []const []const u8,
) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (tryPacksDir(io, a, builtin.toolDir(io, a) catch null)) |d| list.append(a, d) catch {};
    if (tryPacksDir(io, a, state_dir)) |d| list.append(a, d) catch {};
    for (extra_dirs) |d| list.append(a, d) catch {};
    return list.items;
}

fn tryPacksDir(io: Io, a: std.mem.Allocator, base: ?[]const u8) ?[]const u8 {
    _ = io;
    const b = base orelse return null;
    return std.fs.path.join(a, &.{ b, packs_dir_name }) catch null;
}

/// Every `*.cdl` in `dir_path`, loaded into `map` (document name → document).
///
/// This is the one place the engine reads tools from disk, shared by the service and the CLI so the
/// two can never disagree about what is installed. A file that fails to parse or validate is skipped
/// rather than aborting: one bad hand-written tool must not make the program unusable. `a` is scratch
/// (an arena); `map_gpa` is the allocator `map` itself was created with. Returns how many loaded.
pub fn loadDir(
    io: Io,
    a: std.mem.Allocator,
    map_gpa: std.mem.Allocator,
    dir_path: []const u8,
    map: *std.StringArrayHashMapUnmanaged(cdl.Doc),
) !usize {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var loaded: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cdl")) continue;
        const full = std.fs.path.join(a, &.{ dir_path, entry.name }) catch continue;
        const text = Io.Dir.cwd().readFileAlloc(io, full, a, .limited(1024 * 1024)) catch continue;
        const r = cdl.load(a, text) catch continue;
        if (r == .err or r.ok.hasErrors()) continue;
        // The document's own `name` is the identity, so the file name need not match it.
        map.put(map_gpa, r.ok.doc.name, r.ok.doc) catch continue;
        loaded += 1;
    }
    return loaded;
}

/// Every tool of every pack under `root`, loaded into `map` (document name → document).
///
/// A dev-time helper: the tests validate the pack sources in the repository (`assets/packs`) and the
/// self-test loads real definitions, without either of them needing an installed tool directory. The
/// application never reads the source tree — it loads the packs named by `discover`.
pub fn loadAll(
    io: Io,
    a: std.mem.Allocator,
    map_gpa: std.mem.Allocator,
    root: []const u8,
    map: *std.StringArrayHashMapUnmanaged(cdl.Doc),
) !usize {
    var loaded: usize = 0;
    for (scanDir(io, a, root, .exe_dir)) |pack| {
        for (pack.tools) |tool| {
            const r = cdl.load(a, tool.text) catch continue;
            if (r == .err or r.ok.hasErrors()) continue;
            map.put(map_gpa, r.ok.doc.name, r.ok.doc) catch continue;
            loaded += 1;
        }
    }
    return loaded;
}

pub fn find(packs: []const Pack, id: []const u8) ?*const Pack {
    for (packs) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

/// What a pack's tools currently look like on disk, for the library's "installed" mark.
pub const State = struct {
    /// Tool files already present with exactly the pack's bytes.
    installed: usize = 0,
    /// Tool files present with *different* bytes: the user's own version, never overwritten.
    modified: usize = 0,
    total: usize = 0,

    pub fn complete(self: State) bool {
        return self.total > 0 and self.installed + self.modified == self.total;
    }
};

pub fn state(io: Io, a: std.mem.Allocator, pack: *const Pack, cdl_dir: ?[]const u8) State {
    var st = State{ .total = pack.tools.len };
    const dir_path = cdl_dir orelse return st;
    for (pack.tools) |tool| {
        const target = std.fs.path.join(a, &.{ dir_path, tool.file }) catch continue;
        const existing = Io.Dir.cwd().readFileAlloc(io, target, a, .limited(1024 * 1024)) catch continue;
        if (std.mem.eql(u8, existing, tool.text)) {
            st.installed += 1;
        } else {
            st.modified += 1;
        }
    }
    return st;
}

/// The outcome of installing one pack. Names are the installed file names.
pub const Report = struct {
    written: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Already present with identical bytes — nothing to do.
    skipped: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Present with different bytes (the user's own tool of that name): left untouched, reported.
    conflicts: std.ArrayListUnmanaged([]const u8) = .empty,
    failed: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Install a pack's tools into `cdl_dir` (the directory the engine loads tools from).
pub fn install(io: Io, a: std.mem.Allocator, pack: *const Pack, cdl_dir: []const u8) Report {
    var report: Report = .{};
    Io.Dir.cwd().createDirPath(io, cdl_dir) catch {};
    for (pack.tools) |tool| {
        const target = std.fs.path.join(a, &.{ cdl_dir, tool.file }) catch {
            report.failed.append(a, tool.file) catch {};
            continue;
        };
        if (Io.Dir.cwd().readFileAlloc(io, target, a, .limited(1024 * 1024))) |existing| {
            if (std.mem.eql(u8, existing, tool.text)) {
                report.skipped.append(a, tool.file) catch {};
            } else {
                // Rule 2: the bytes on disk are the user's; a pack never overwrites them.
                report.conflicts.append(a, tool.file) catch {};
            }
            continue;
        } else |_| {}
        Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = tool.text }) catch {
            report.failed.append(a, tool.file) catch {};
            continue;
        };
        report.written.append(a, tool.file) catch {};
    }
    return report;
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

/// Scratch directory under `.zig-cache/test-work`, the same hermetic convention the engine tests use
/// (tests run from the build root).
fn testWorkDir(a: std.mem.Allocator, sub: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".zig-cache/test-work/{s}", .{sub});
}

test "packs: every shipped pack source has a manifest, tools, and only valid CDLs" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The pack *sources* in the repository. They are external files, so the test reads them from the
    // tree exactly as a user's pack directory would be read (tests run from the build root).
    const all = scanDir(io, a, "assets/packs", .exe_dir);
    try testing.expect(all.len >= 1);

    var total: usize = 0;
    for (all) |p| {
        try testing.expect(p.id.len > 0);
        try testing.expect(p.label.len > 0);
        try testing.expect(p.description.len > 0);
        try testing.expect(p.tools.len > 0);
        for (p.tools) |t| {
            total += 1;
            const r = try cdl.load(a, t.text);
            if (r == .err) {
                std.debug.print("pack {s}: {s} failed to parse: {s} @ {s}:{d}\n", .{ p.id, t.file, r.err.message, r.err.path, r.err.line });
                return error.PackParseFailed;
            }
            if (r.ok.hasErrors()) {
                std.debug.print("pack {s}: {s} has validation errors:\n", .{ p.id, t.file });
                for (r.ok.issues) |i| {
                    if (i.level == .@"error") std.debug.print("  [error] {s} @ {s}\n", .{ i.message, i.path });
                }
                return error.PackValidationFailed;
            }
            // The file name is what `install` writes and what the library shows, and the document's
            // own `name` is the identity the engine keys on: the two must agree, or a pack would
            // install a file whose content claims a different tool.
            try testing.expectEqualStrings(stem(t.file), r.ok.doc.name);
            try testing.expect(r.ok.doc.display_name.len > 0);
            // A tool is presets, a sheet, or both — never neither (an empty row in the library).
            try testing.expect(r.ok.doc.actions.len > 0 or r.ok.doc.vocabulary.len > 0);
            // Content rules the schema cannot express: English only (rule 5 — the one Chinese in the
            // tree is the translation table), and no machine-specific absolute path, because a pack
            // ships to every machine and a path from the author's disk is noise to everyone else.
            var has_non_ascii = false;
            var has_machine_path = false;
            for (t.text, 0..) |c, i| {
                if (c > 127) has_non_ascii = true;
                // A drive-qualified path with a backslash separator, or a Unix home directory. A URL
                // (`https://…`) is not a path, so a drive letter followed by `//` is ignored.
                if (i + 2 < t.text.len and std.ascii.isAlphabetic(c) and t.text[i + 1] == ':') {
                    if (t.text[i + 2] == '\\') has_machine_path = true;
                }
                if (std.mem.startsWith(u8, t.text[i..], "/Users/") or
                    std.mem.startsWith(u8, t.text[i..], "/home/")) has_machine_path = true;
            }
            if (has_non_ascii) {
                std.debug.print("pack {s}: {s} contains non-ASCII characters\n", .{ p.id, t.file });
                return error.PackNotEnglish;
            }
            if (has_machine_path) {
                std.debug.print("pack {s}: {s} contains an absolute path from one machine\n", .{ p.id, t.file });
                return error.PackMachineSpecific;
            }
        }
    }
    // The migrated built-ins are all still shipped, just no longer loaded by default.
    try testing.expect(total >= 11);
}

test "packs: a manifest is optional and falls back to the directory name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = parseMeta(
        a,
        "{\"label\":\"My tools\",\"description\":\"d\",\"platforms\":[\"linux\",\"macos\"],\"origin\":\"machine\"}",
        "fallback",
    );
    try testing.expectEqualStrings("My tools", meta.label);
    try testing.expectEqualStrings("machine", meta.origin);
    try testing.expectEqual(@as(usize, 2), meta.platforms.len);

    // Unparsable or absent: the directory name is the label, and nothing else is invented.
    const broken = parseMeta(a, "not json at all", "fallback");
    try testing.expectEqualStrings("fallback", broken.label);
    try testing.expectEqualStrings("", broken.description);
    try testing.expectEqual(@as(usize, 0), broken.platforms.len);
}

test "packs: scanDir finds a pack directory with its manifest and tools" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try testWorkDir(a, "packs-scan");
    Io.Dir.cwd().deleteTree(io, root) catch {};
    const pack_dir = try std.fs.path.join(a, &.{ root, "my-pack" });
    try Io.Dir.cwd().createDirPath(io, pack_dir);
    const manifest = try std.fs.path.join(a, &.{ pack_dir, manifest_name });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest,
        .data = "{\"label\":\"My pack\",\"description\":\"scan test\",\"origin\":\"machine\"}",
    });
    const tool_path = try std.fs.path.join(a, &.{ pack_dir, "alpha.cdl" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = tool_path,
        .data = "{\"name\":\"alpha\",\"display_name\":\"Alpha\",\"category\":\"other\",\"actions\":[{\"name\":\"go\",\"label\":\"Go\",\"executable\":\"alpha\",\"args\":[{\"value\":\"--now\"}]}]}",
    });
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    const found = scanDir(io, a, root, .state_dir);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("my-pack", found[0].id);
    try testing.expectEqualStrings("My pack", found[0].label);
    try testing.expectEqualStrings("machine", found[0].origin);
    try testing.expectEqual(Source.state_dir, found[0].source);
    try testing.expectEqual(@as(usize, 1), found[0].tools.len);
    try testing.expectEqualStrings("alpha.cdl", found[0].tools[0].file);
}

test "packs: install writes once, skips identical files and never overwrites a changed one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir_path = try testWorkDir(a, "packs-install");
    Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const tool_text =
        \\{"name":"demo","display_name":"Demo","category":"other",
        \\ "actions":[{"name":"go","label":"Go","executable":"demo","args":[{"value":"--now"}]}]}
    ;
    const pack = Pack{
        .id = "demo-pack",
        .label = "Demo pack",
        .source = .exe_dir,
        .tools = &.{.{ .file = "demo.cdl", .text = tool_text }},
    };

    const first = install(io, a, &pack, dir_path);
    try testing.expectEqual(@as(usize, 1), first.written.items.len);
    try testing.expectEqual(@as(usize, 0), first.conflicts.items.len);
    const target = try std.fs.path.join(a, &.{ dir_path, "demo.cdl" });
    try testing.expectEqualStrings(tool_text, try Io.Dir.cwd().readFileAlloc(io, target, a, .limited(64 * 1024)));

    // Installing twice is a no-op, not a rewrite.
    const second = install(io, a, &pack, dir_path);
    try testing.expectEqual(@as(usize, 0), second.written.items.len);
    try testing.expectEqual(@as(usize, 1), second.skipped.items.len);
    const st_before = state(io, a, &pack, dir_path);
    try testing.expectEqual(@as(usize, 1), st_before.installed);
    try testing.expect(st_before.complete());

    // The user edits their copy: the next install reports a conflict and leaves the bytes alone
    // (rule 2 — a pack never overwrites the user's own version of a tool).
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = target,
        .data = "{\"name\":\"demo\",\"display_name\":\"Mine\",\"category\":\"other\",\"actions\":[]}",
    });
    const third = install(io, a, &pack, dir_path);
    try testing.expectEqual(@as(usize, 0), third.written.items.len);
    try testing.expectEqual(@as(usize, 1), third.conflicts.items.len);
    const after = try Io.Dir.cwd().readFileAlloc(io, target, a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, after, "Mine") != null);

    const st_after = state(io, a, &pack, dir_path);
    try testing.expectEqual(@as(usize, 0), st_after.installed);
    try testing.expectEqual(@as(usize, 1), st_after.modified);
    try testing.expect(st_after.complete());
}

test "packs: loadDir reads the installed tools and skips a broken file" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir_path = try testWorkDir(a, "packs-loaddir");
    Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    try Io.Dir.cwd().createDirPath(io, dir_path);

    const good = try std.fs.path.join(a, &.{ dir_path, "demo.cdl" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = good,
        .data = "{\"name\":\"demo\",\"display_name\":\"Demo\",\"category\":\"other\",\"actions\":[{\"name\":\"go\",\"label\":\"Go\",\"executable\":\"demo\",\"args\":[]}]}",
    });
    const broken = try std.fs.path.join(a, &.{ dir_path, "broken.cdl" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = broken, .data = "{ this is not a CDL" });
    const ignored = try std.fs.path.join(a, &.{ dir_path, "notes.txt" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ignored, .data = "not a tool" });

    var map: std.StringArrayHashMapUnmanaged(cdl.Doc) = .empty;
    const loaded = try loadDir(io, a, a, dir_path, &map);
    try testing.expectEqual(@as(usize, 1), loaded);
    try testing.expect(map.get("demo") != null);
    try testing.expect(map.count() == 1);
}
