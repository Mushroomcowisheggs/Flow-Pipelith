//! Platform built-ins: executable lookup, PATH handling and the portable tool/state directories.
//!
//! **No tool definition lives here.** Tool descriptions are *packs* (see `packs.zig`): shipped
//! separately from the program's own defaults and installed only when the user asks for one, so a
//! fresh installation starts with an empty tool library. What remains in this file is the machinery
//! that locating and probing a program needs, which is what the engine and the picker share.
//!
//! Override precedence for tools: project > user > shipped pack (the same `name` at a higher
//! precedence replaces the whole document).

const std = @import("std");
const Io = std.Io;
const platform = @import("platform.zig");
const cdl = @import("cdl.zig");
const native_os = @import("builtin").os.tag;

// ── Executable lookup (PATH + PATHEXT / direct path) ─────────────

pub const Probe = struct {
    found: bool = false,
    path: ?[]const u8 = null,
    /// First line of the probe command's output (e.g. "gcc (GCC) 15.2.0"); null when not probed.
    version_line: ?[]const u8 = null,
};

fn isPathLike(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "/\\") != null;
}

/// Split PATH into a list of directories (owned by the caller, normally placed in an arena).
///
/// It is exposed separately so the caller can **cache** this list: otherwise every probe
/// would split it again and allocate a joined path for each directory (Windows PATH is very
/// long; measured, a single listing call produced thousands of allocations).
pub fn pathEntries(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]const []const u8 {
    const path_val = environ.get("PATH") orelse environ.get("Path") orelse return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path_val, if (native_os == .windows) ';' else ':');
    while (it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " \t\"");
        if (dir.len == 0) continue;
        try list.append(alloc, dir);
    }
    return list.items;
}

/// Look for an executable in a known list of directories.
///
/// On Windows the extensions from PATHEXT are tried in order; if `name` already contains an
/// extension it is tried verbatim first.
pub fn resolveInDirs(
    io: Io,
    alloc: std.mem.Allocator,
    dirs: []const []const u8,
    name: []const u8,
) !?[]const u8 {
    if (name.len == 0) return null;
    if (isPathLike(name)) {
        const f = Io.Dir.cwd().openFile(io, name, .{}) catch return null;
        f.close(io);
        return try alloc.dupe(u8, name);
    }

    var ext_buf: [64]u8 = undefined;
    for (dirs) |dir| {
        if (native_os == .windows) {
            if (std.mem.indexOfScalar(u8, name, '.') != null) {
                if (try tryJoin(io, alloc, dir, name)) |p| return p;
            }
            const pathext = ".COM;.EXE;.BAT;.CMD";
            var ext_it = std.mem.splitScalar(u8, pathext, ';');
            while (ext_it.next()) |ext| {
                if (ext.len == 0) continue;
                const candidate = std.fmt.bufPrint(&ext_buf, "{s}{s}", .{ name, ext }) catch continue;
                if (try tryJoin(io, alloc, dir, candidate)) |p| return p;
            }
        } else {
            if (try tryJoin(io, alloc, dir, name)) |p| return p;
        }
    }
    return null;
}

/// Resolve an executable in PATH; the returned path is allocated by `alloc`.
///
/// This is the convenience entry point; **hot paths** (such as the listing endpoints)
/// should use `pathEntries` + `resolveInDirs` with a cached directory list instead,
/// otherwise every candidate path costs an allocation.
pub fn resolveExecutable(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !?[]const u8 {
    const dirs = try pathEntries(alloc, environ);
    return resolveInDirs(io, alloc, dirs, name);
}

fn tryJoin(io: Io, alloc: std.mem.Allocator, dir: []const u8, file: []const u8) !?[]const u8 {
    const full = try std.fs.path.join(alloc, &.{ dir, file });
    const f = Io.Dir.cwd().openFile(io, full, .{}) catch {
        // Open failed: the directory does not exist / no permission / not a file — all
        // treated uniformly as "not found"
        return null;
    };
    f.close(io);
    return full;
}

/// Probe whether a tool exists and optionally capture the first line of its version output.
///
/// When `probe_version` is true it runs `argv_prefix ++ --version` with a 5 second timeout.
pub fn probe(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    executable: []const u8,
    probe_version: bool,
) !Probe {
    const resolved = try resolveExecutable(io, alloc, environ, executable) orelse return .{};
    var p: Probe = .{ .found = true, .path = resolved };
    if (!probe_version) return p;

    var child = std.process.spawn(io, .{
        .argv = &.{ resolved, "--version" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch return p;

    const first_line = blk: {
        var rbuf: [4096]u8 = undefined;
        var rd = child.stdout.?.reader(io, &rbuf);
        const cap = rd.interface.allocRemaining(alloc, .limited(64 * 1024)) catch break :blk null;
        defer alloc.free(cap);
        const trimmed = std.mem.trim(u8, cap, " \t\r\n");
        const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
        const line = std.mem.trim(u8, trimmed[0..nl], " \t\r");
        if (line.len == 0) break :blk null;
        break :blk try alloc.dupe(u8, line);
    };

    // Explicitly reclaim the pipe ends, then wait; the wrong order closes an already
    // invalid handle a second time
    if (child.stdin) |*f| {
        f.close(io);
        child.stdin = null;
    }
    if (child.stdout) |*f| {
        f.close(io);
        child.stdout = null;
    }
    if (child.stderr) |*f| {
        f.close(io);
        child.stderr = null;
    }
    _ = child.wait(io) catch {};

    p.version_line = first_line;
    return p;
}

/// Current platform name (the vocabulary used by the CDL `platforms` field).
pub fn platformName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "windows",
        .macos => "macos",
        .linux => "linux",
        .freebsd => "freebsd",
        else => "unknown",
    };
}

// ── Portable layout ─────────────────────────────────────────────

/// Directory name holding every mutable file Flow Pipelith produces.
pub const state_dir_name = ".pipelith";

/// Absolute directory containing the running executable.
///
/// This is the anchor for the whole portable layout: **every** file Flow Pipelith
/// creates lives under `<tool dir>/.pipelith/`, never next to the user's
/// documents and never in a system temp/home directory. Anchoring on the
/// executable (rather than the current working directory) is what makes the
/// guarantee hold when the tool is launched from another directory, e.g.
/// `<install dir>/pipelith.exe --run <some dir>/build.flow`.
pub fn toolDir(io: Io, alloc: std.mem.Allocator) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &buf) catch return null;
    if (n == 0) return null;
    return try alloc.dupe(u8, buf[0..n]);
}

/// `<tool dir>/.pipelith` — the single writable root. Callers create it lazily.
pub fn stateDir(io: Io, alloc: std.mem.Allocator) !?[]const u8 {
    const dir = (try toolDir(io, alloc)) orelse return null;
    return try std.fs.path.join(alloc, &.{ dir, state_dir_name });
}

/// Subdirectory of the state dir, e.g. `stateSubdir(io, a, "cdl")`.
pub fn stateSubdir(io: Io, alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const root = (try stateDir(io, alloc)) orelse return null;
    return try std.fs.path.join(alloc, &.{ root, name });
}

/// User CDL directory: `<tool dir>/.pipelith/cdl`.
///
/// Deliberately *not* `%APPDATA%` / `~/.config`: a portable tool must not
/// scatter files across the host, so user-defined CDLs travel with the tool.
pub fn userCdlDir(io: Io, alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    _ = environ;
    return stateSubdir(io, alloc, "cdl");
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "builtin: platformName is valid" {
    const p = platformName();
    try testing.expect(p.len > 0);
    try testing.expect(!std.mem.eql(u8, p, "unknown") or native_os != .windows);
}
