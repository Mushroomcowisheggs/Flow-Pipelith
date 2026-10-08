//! Path picking for `fs.pick`.
//!
//! Product rule: the user must never have to hand-type a path, and the tool
//! must never silently change the mechanism it uses to obtain one. So this
//! module:
//!
//!   * resolves a backend explicitly (request -> environment -> platform
//!     default) and reports the backend that produced a result;
//!   * fails with `error.Unavailable` when the resolved backend is not present,
//!     instead of falling back to another one;
//!   * returns the chosen path byte-for-byte, with no quoting, trimming,
//!     separator rewriting or escape processing.
//!
//! The full contract lives in docs/PICKER.md.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin.zig");
const native_os = @import("builtin").os.tag;

/// Backend identifiers are part of the RPC contract (docs/PICKER.md 2.3).
pub const Backend = enum {
    native,
    zenity,
    kdialog,
    none,

    pub fn wire(self: Backend) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Backend {
        inline for (@typeInfo(Backend).@"enum".field_names) |fname| {
            if (std.mem.eql(u8, text, fname)) return @field(Backend, fname);
        }
        return null;
    }
};

pub const Mode = enum {
    file,
    folder,

    pub fn wire(self: Mode) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Mode {
        inline for (@typeInfo(Mode).@"enum".field_names) |fname| {
            if (std.mem.eql(u8, text, fname)) return @field(Mode, fname);
        }
        return null;
    }
};

pub const PickError = error{
    /// The resolved backend is not present on this system. Never retried with a
    /// different backend: the caller reports it to the user instead.
    Unavailable,
    OutOfMemory,
};

pub const Result = struct {
    /// The chosen path, verbatim. `null` when the user cancelled.
    path: ?[]const u8 = null,
    cancelled: bool = false,
    backend: []const u8,
};

/// Read an environment variable, returning an empty slice when unset.
fn envValue(environ: *const std.process.Environ.Map, key: []const u8) []const u8 {
    return environ.get(key) orelse "";
}

/// Platform default backend, used only when neither the request nor the
/// environment names one.
pub fn defaultBackend() Backend {
    return switch (native_os) {
        .windows => .native,
        .linux => .zenity,
        else => .none,
    };
}

/// Resolve the backend to use: request override, then `PIPELITH_PICKER`, then
/// the platform default. An unrecognised override is ignored in favour of the
/// default (the caller surfaces the requested value in the error message when
/// resolution fails).
pub fn resolveBackend(
    environ: *const std.process.Environ.Map,
    requested: []const u8,
) Backend {
    if (requested.len > 0) {
        if (Backend.parse(requested)) |b| return b;
    }
    const from_env = envValue(environ, "PIPELITH_PICKER");
    if (from_env.len > 0) {
        if (Backend.parse(from_env)) |b| return b;
    }
    return defaultBackend();
}

/// Locate the Windows native picker helper.
///
/// Search order is anchored on the executable directory (portability rule)
/// with a cwd-relative fallback for running straight out of the build tree.
fn findNativeHelper(io: Io, alloc: std.mem.Allocator) !?[]const u8 {
    var candidates: [3][]const u8 = undefined;
    var count: usize = 0;

    if (try builtin.toolDir(io, alloc)) |dir| {
        candidates[count] = try std.fs.path.join(alloc, &.{ dir, "pl_pick.exe" });
        count += 1;
    }
    candidates[count] = "pl_pick.exe";
    count += 1;
    candidates[count] = "zig-out/bin/pl_pick.exe";
    count += 1;

    for (candidates[0..count]) |c| {
        const f = Io.Dir.cwd().openFile(io, c, .{}) catch continue;
        f.close(io);
        return c;
    }
    return null;
}

/// Does the resolved backend work on this machine?
///
/// `none` is always "available" in the sense that it is a deliberate choice.
/// `native` is checked with `pl_pick probe`, which never opens a window.
/// `zenity`/`kdialog` are checked by resolving the executable on `PATH`.
pub fn isAvailable(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    backend: Backend,
) bool {
    switch (backend) {
        .none => return true,
        .native => {
            const helper = (findNativeHelper(io, alloc) catch return false) orelse return false;
            var child = std.process.spawn(io, .{
                .argv = &.{ helper, "probe" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
                .create_no_window = true,
            }) catch return false;
            const term = child.wait(io) catch return false;
            return switch (term) {
                .exited => |code| code == 0,
                else => false,
            };
        },
        .zenity => return (builtin.resolveExecutable(io, alloc, environ, "zenity") catch null) != null,
        .kdialog => return (builtin.resolveExecutable(io, alloc, environ, "kdialog") catch null) != null,
    }
}

/// Collect a child's stdout, close all its pipes, then reap it.
///
/// Closing the pipes before `wait` is required: the reverse order double-closes
/// already-invalid handles.
fn collectAndReap(io: Io, child: *std.process.Child, alloc: std.mem.Allocator) ![]const u8 {
    var captured: []const u8 = "";
    if (child.stdout) |*out| {
        var rbuf: [4096]u8 = undefined;
        var rd = out.reader(io, &rbuf);
        if (rd.interface.allocRemaining(alloc, .limited(64 * 1024))) |bytes| {
            captured = bytes;
        } else |_| {}
    }
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
    return captured;
}

/// Ask the resolved backend for a path.
///
/// Returns `error.Unavailable` when the backend is missing, so the caller can
/// tell the user which backend was tried instead of quietly using another.
pub fn pick(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    backend: Backend,
    mode: Mode,
    start_dir: []const u8,
    filter: []const u8,
) PickError!Result {
    switch (backend) {
        .none => return error.Unavailable,
        .native => return pickNative(io, alloc, backend, mode, start_dir, filter),
        .zenity => return pickZenity(io, alloc, environ, backend, mode),
        .kdialog => return pickKdialog(io, alloc, environ, backend, mode),
    }
}

fn pickNative(
    io: Io,
    alloc: std.mem.Allocator,
    backend: Backend,
    mode: Mode,
    start_dir: []const u8,
    filter: []const u8,
) PickError!Result {
    const helper = (findNativeHelper(io, alloc) catch return error.OutOfMemory) orelse
        return error.Unavailable;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(alloc, helper) catch return error.OutOfMemory;
    argv.append(alloc, mode.wire()) catch return error.OutOfMemory;
    argv.append(alloc, start_dir) catch return error.OutOfMemory;
    argv.append(alloc, filter) catch return error.OutOfMemory;

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.Unavailable;

    const text = collectAndReap(io, &child, alloc) catch return error.OutOfMemory;
    const term = child.wait(io) catch return error.Unavailable;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => return error.Unavailable,
    };

    return switch (code) {
        0 => .{
            .path = try firstLine(alloc, text),
            .backend = backend.wire(),
        },
        1 => .{ .cancelled = true, .backend = backend.wire() },
        2 => error.Unavailable,
        else => error.Unavailable,
    };
}

fn pickZenity(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    backend: Backend,
    mode: Mode,
) PickError!Result {
    const exe = (builtin.resolveExecutable(io, alloc, environ, "zenity") catch
        return error.OutOfMemory) orelse return error.Unavailable;
    const argv: []const []const u8 = if (mode == .folder)
        &.{ exe, "--file-selection", "--directory" }
    else
        &.{ exe, "--file-selection" };
    return runSpawnDialog(io, alloc, argv, backend);
}

fn pickKdialog(
    io: Io,
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    backend: Backend,
    mode: Mode,
) PickError!Result {
    const exe = (builtin.resolveExecutable(io, alloc, environ, "kdialog") catch
        return error.OutOfMemory) orelse return error.Unavailable;
    const flag: []const u8 = if (mode == .folder) "--getexistingdirectory" else "--getopenfilename";
    const argv: []const []const u8 = &.{ exe, flag, "." };
    return runSpawnDialog(io, alloc, argv, backend);
}

/// Shared body for the two shell-based helpers: exit 0 with a line of output is
/// a selection, exit 1 is a cancel, anything else is treated as unavailable.
fn runSpawnDialog(
    io: Io,
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    backend: Backend,
) PickError!Result {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.Unavailable;

    const text = collectAndReap(io, &child, alloc) catch return error.OutOfMemory;
    const term = child.wait(io) catch return error.Unavailable;
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => return error.Unavailable,
    };
    if (code == 1) return .{ .cancelled = true, .backend = backend.wire() };
    if (code != 0) return error.Unavailable;
    return .{ .path = try firstLine(alloc, text), .backend = backend.wire() };
}

/// Take the first line of captured output and trim only the line terminator.
///
/// Interior spaces and trailing spaces inside the path are preserved: a path is
/// data, not something to tidy up.
fn firstLine(alloc: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const no_cr = std.mem.trimEnd(u8, text, "\r\n");
    const nl = std.mem.indexOfScalar(u8, no_cr, '\n') orelse no_cr.len;
    const line = std.mem.trimEnd(u8, no_cr[0..nl], "\r");
    if (line.len == 0) return null;
    return try alloc.dupe(u8, line);
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "picker: Backend.parse round trip and rejects unknown" {
    try testing.expectEqual(Backend.native, Backend.parse("native").?);
    try testing.expectEqual(Backend.zenity, Backend.parse("zenity").?);
    try testing.expectEqual(Backend.kdialog, Backend.parse("kdialog").?);
    try testing.expectEqual(Backend.none, Backend.parse("none").?);
    try testing.expectEqual(@as(?Backend, null), Backend.parse("powershell"));
    try testing.expectEqualStrings("native", Backend.native.wire());
}

test "picker: Mode.parse" {
    try testing.expectEqual(Mode.file, Mode.parse("file").?);
    try testing.expectEqual(Mode.folder, Mode.parse("folder").?);
    try testing.expectEqual(@as(?Mode, null), Mode.parse("directory"));
}

test "picker: request override wins over the environment variable" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PIPELITH_PICKER", "none");
    // The request asked for kdialog, so kdialog is what must be used even
    // though the environment says otherwise.
    try testing.expectEqual(Backend.kdialog, resolveBackend(&map, "kdialog"));
}

test "picker: environment variable is honoured when the request omits a backend" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PIPELITH_PICKER", "zenity");
    try testing.expectEqual(Backend.zenity, resolveBackend(&map, ""));
}

test "picker: request override beats the environment variable (reverse direction)" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PIPELITH_PICKER", "kdialog");
    try testing.expectEqual(Backend.none, resolveBackend(&map, "none"));
}

test "picker: unknown values fall back to the platform default" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PIPELITH_PICKER", "definitely-not-a-backend");
    try testing.expectEqual(defaultBackend(), resolveBackend(&map, "also-bogus"));
}

test "picker: defaultBackend matches the platform" {
    switch (native_os) {
        .windows => try testing.expectEqual(Backend.native, defaultBackend()),
        .linux => try testing.expectEqual(Backend.zenity, defaultBackend()),
        else => {},
    }
}

test "picker: firstLine keeps interior spaces and drops only the terminator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("D:\\my dir\\a b.flow", (try firstLine(a, "D:\\my dir\\a b.flow\r\n")).?);
    try testing.expectEqualStrings("C:\\x\\", (try firstLine(a, "C:\\x\\")).?);
    try testing.expectEqualStrings("/home/u/a b", (try firstLine(a, "/home/u/a b\n")).?);
    try testing.expectEqual(@as(?[]const u8, null), try firstLine(a, "\r\n"));
    try testing.expectEqual(@as(?[]const u8, null), try firstLine(a, ""));
}

test "picker: none backend is explicitly unavailable, never substituted" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    // A fake io is not needed: the `none` branch returns before touching io.
    try testing.expectError(error.Unavailable, pick(undefined, testing.allocator, &map, .none, .file, "", ""));
}

test "picker: state dir is anchored inside the tool directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = (try builtin.toolDir(io, a)) orelse return error.SkipZigTest;
    const state = (try builtin.stateDir(io, a)) orelse return error.SkipZigTest;
    try testing.expect(std.mem.startsWith(u8, state, dir));
    try testing.expect(std.mem.endsWith(u8, state, builtin.state_dir_name));

    // The guarantee that matters: nothing is rooted in a system temp or home dir.
    for ([_][]const u8{ "Temp", "tmp", "AppData", "Roaming", "home" }) |forbidden| {
        try testing.expect(std.mem.indexOf(u8, state, forbidden) == null);
    }
}
