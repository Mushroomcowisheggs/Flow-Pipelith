//! Platform adaptation layer: process spawning and process termination.
//!
//! ── Why this layer exists, and which route it currently takes ──
//!
//! The design goal is "upstream stdout becomes downstream stdin directly". Three routes
//! were tried for this, all measured empirically:
//!
//! 1. `std.process.spawn(StdIo.file = pipe handle)`: on Windows the std library
//!    **re-opens** the device the handle points to via `NtOpenFile(dir = handle)`, and a
//!    pipe object cannot be reopened that way → `NoDevice` (anonymous pipes, inheritable
//!    duplicates and named pipes were all tried, all failed; an ordinary file handle
//!    succeeds).
//! 2. Hand-rolled `CreateProcessW` + `STARTUPINFOEXW` + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`:
//!    the process starts and the child reports `stdout_filetype=0x3` (a pipe), but the
//!    parent's `ReadFile` never reads a single byte.
//! 3. Hand-rolled `CreateProcessW` + classic `STARTUPINFOW` (the pipe is created
//!    non-inheritable, only the child side is marked inheritable, and the child-side
//!    handle is closed after spawning): again "the child runs successfully, stdout is a
//!    pipe, the parent's read end is valid, but no bytes can be read".
//!    (Measured on this machine: within the same run an inline probe reliably reads
//!    183–192 bytes while `platform.spawn` reads 0; the child writing a 267-byte file
//!    proves it really executed.)
//!
//! Conclusion: with this machine's Zig 0.17-dev `std.Io.Threaded` plus Windows named
//! pipes, the "cross-process pipe handle inheritance" chain is unreliable. So by default
//! we switch to the **two mechanisms proven to work with std**:
//!   - `.pipe` → std creates the pipe and captures stdout/stderr (verified working)
//!   - `.file` → hand an **ordinary file** handle to the child's stdin (verified working)
//! Pipe edges (A.stdout → B.stdin) are implemented one layer up by relaying through a
//! temporary file, see `engine.zig`.
//!
//! The hand-rolled `CreateProcessW` path is kept in `spawnWindowsManual`, enabled via
//! `use_manual_spawn` (for locating or fixing that defect in the future).
//!
//! Non-Windows platforms go through `std.process.spawn` (on POSIX `.file` is a direct
//! dup, so the problem above does not exist), but the current verification environment is
//! Windows, so the POSIX path has not been measured.

const std = @import("std");
const Io = std.Io;
const native_os = @import("builtin").os.tag;

pub const is_windows = native_os == .windows;

/// Whether to use the hand-rolled `CreateProcessW` path (off by default, see the file header).
pub var use_manual_spawn: bool = false;

/// Stdio target: three possibilities plus discard.
pub const Stdio = union(enum) {
    /// Create a new pipe; the parent holds the read end (stdout/stderr) or the write end (stdin)
    pipe,
    /// Use a handle supplied by the caller (the parent still holds that handle)
    file: Io.File,
    /// Discard: NUL on Windows, /dev/null on POSIX
    ignore,
    /// Inherit the parent's corresponding stream
    inherit,
};

pub const Spec = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: Stdio = .ignore,
    stdout: Stdio = .pipe,
    stderr: Stdio = .pipe,
    /// Start suspended and release it later via `resume()` (avoids pipe deadlock with a
    /// single-threaded pool)
    suspended: bool = false,
};

/// Convert a `Stdio` into the StdIo option of `std.process`.
fn stdIoOf(target: Stdio) std.process.SpawnOptions.StdIo {
    return switch (target) {
        .pipe => .pipe,
        .file => |f| .{ .file = f },
        .ignore => .ignore,
        .inherit => .inherit,
    };
}

/// Reasons spawning can fail.
pub const SpawnError = error{
    CreateProcessFailed,
    OutOfMemory,
};

/// Spawn a child process.
///
/// The implementation goes through `std.process.spawn`: `.pipe` captures stdout/stderr,
/// and `.file` hands an **ordinary file** handle to the child's stdin. Both mechanisms
/// were measured to work; "handing a pipe handle to another child process" is not usable
/// on Windows (see the file header), so pipe edges are implemented in `engine.zig` by
/// relaying through a temporary file.
pub fn spawn(
    alloc: std.mem.Allocator,
    spec: Spec,
    arena: std.mem.Allocator,
) SpawnError!Process {
    _ = arena;
    return spawnViaStd(alloc, spec);
}

fn spawnViaStd(alloc: std.mem.Allocator, spec: Spec) SpawnError!Process {
    var proc: Process = .{ .os = .{}, .alloc = alloc };

    const io = default_io orelse return error.CreateProcessFailed;
    var child = std.process.spawn(io, .{
        .argv = spec.argv,
        .cwd = if (spec.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = spec.env,
        .stdin = stdIoOf(spec.stdin),
        .stdout = stdIoOf(spec.stdout),
        .stderr = stdIoOf(spec.stderr),
        .create_no_window = true,
    }) catch return error.CreateProcessFailed;

    // Handle ownership moves to this module: they must be nulled out on `Child` first,
    // otherwise `Child.wait`'s internal cleanup closes the same handle a second time →
    // native Windows crash (`STATUS_INVALID_HANDLE`). This is the other face of the
    // same double-close hazard: one handle with two owners.
    const in_file: ?Io.File = child.stdin;
    const out_file: ?Io.File = child.stdout;
    const err_file: ?Io.File = child.stderr;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;

    if (in_file) |f| proc.stdin = .{ .file = f };
    if (out_file) |f| proc.stdout = .{ .file = f };
    if (err_file) |f| proc.stderr = .{ .file = f };

    if (is_windows) {
        proc.os = .{ .pid = 0, .child = child };
    } else {
        proc.os = .{ .pid = @intCast(child.id.?) };
    }
    return proc;
}

/// A pipe end handle: `null` means "the parent does not hold this end".
///
/// **It must hold the `Io.File` directly, not just a handle that is reassembled later**:
/// `Io.File.flags` carries critical information such as `nonblocking` / the positioning
/// mode, and the read end of a pipe created by std is an asynchronous handle
/// (`nonblocking = true`). Reassembling it into a file with `nonblocking = false` makes a
/// read hit std's `unreachable: wrong File nonblocking flag` and panic outright (measured).
pub const Pipe = struct {
    file: ?Io.File = null,

    pub fn isValid(self: Pipe) bool {
        return self.file != null;
    }

    pub fn asFile(self: Pipe) Io.File {
        return self.file orelse unreachable;
    }

    /// Only used by the hand-rolled path: constructed from a Win32 handle (handles are all
    /// synchronous on that path).
    pub fn fromHandle(h: AllowZeroHandle) Pipe {
        return .{ .file = .{ .handle = @ptrCast(h), .flags = .{ .nonblocking = false } } };
    }

    pub fn close(self: *Pipe) void {
        const f = self.file orelse return;
        self.file = null; // Clear first: if close triggers an error internally it will not be closed a second time
        f.close(default_io orelse unreachable);
    }
};

/// An already spawned child process. Its fields are accessed directly only inside this module.
pub const Process = struct {
    os: OsProcess,
    /// The parent-side pipe ends (only set for the `pipe` target)
    stdin: ?Pipe = null,
    stdout: ?Pipe = null,
    stderr: ?Pipe = null,
    alloc: std.mem.Allocator,

    pub const Term = struct {
        exited: ?u8 = null,
        /// Forcefully terminated (timeout or cancellation)
        killed: bool = false,
        code: u32 = 0,
    };

    pub fn pid(self: *const Process) u32 {
        return self.os.pid;
    }

    /// Close one end held by the parent and null it out (idempotent).
    pub fn closeStdin(self: *Process) void {
        if (self.stdin) |*p| p.close();
        self.stdin = null;
    }

    pub fn closeStdout(self: *Process) void {
        if (self.stdout) |*p| p.close();
        self.stdout = null;
    }

    pub fn closeStderr(self: *Process) void {
        if (self.stderr) |*p| p.close();
        self.stderr = null;
    }

    /// Close every pipe end held by this process (does not clear the OS process handle).
    pub fn closePipes(self: *Process) void {
        self.closeStdin();
        self.closeStdout();
        self.closeStderr();
    }

    /// Close the stdin write end — this is the only way the downstream sees EOF.
    pub fn eofStdin(self: *Process) void {
        self.closeStdin();
    }

    pub fn kill(self: *Process) void {
        self.os.kill();
    }

    pub fn resumeChild(self: *Process) void {
        self.os.resumeChild();
    }

    /// Wait for exit; returns the termination information. Closes the OS process handle.
    pub fn wait(self: *Process, io: Io) Term {
        return self.os.wait(io);
    }

    /// Release: close the OS handle (idempotent).
    pub fn deinit(self: *Process) void {
        self.os.deinit();
    }
};

/// Closing a pipe end does not need io; this entry point is kept so callers stay consistent.
var default_io: ?Io = null;

pub fn setDefaultIo(io: Io) void {
    default_io = io;
}

// ── Windows implementation ─────────────────────────────────────────────────

const OsProcess = if (is_windows) WindowsProcess else PosixProcess;

const WindowsProcess = struct {
    /// The child process handle held by the default path (`std.process.spawn`).
    /// Handle ownership: `Child`'s stdin/stdout/stderr have already been moved out (see
    /// `spawnViaStd`), so `Child.wait` only closes the process/thread handles and never
    /// closes our pipe ends a second time.
    child: ?std.process.Child = null,
    /// Process/thread handles of the hand-rolled path
    process_handle: AllowZeroHandle = null_handle,
    thread_handle: AllowZeroHandle = null_handle,
    pid: u32 = 0,

    fn kill(self: *WindowsProcess) void {
        if (self.child) |*c| {
            if (c.id != null) c.kill(default_io orelse unreachable);
            return;
        }
        if (self.process_handle == null_handle) return;
        _ = TerminateProcess(handleOf(self.process_handle), 1);
    }

    fn resumeChild(self: *WindowsProcess) void {
        if (self.thread_handle == null_handle) return;
        _ = ResumeThread(handleOf(self.thread_handle));
    }

    fn wait(self: *WindowsProcess, io: Io) Process.Term {
        var term: Process.Term = .{};

        if (self.child) |*c| {
            const t = c.wait(io) catch return term;
            self.child = null;
            switch (t) {
                .exited => |code| {
                    term.code = code;
                    term.exited = code;
                },
                else => term.killed = true,
            }
            return term;
        }

        if (self.process_handle == null_handle) return term;
        const r = WaitForSingleObject(handleOf(self.process_handle), INFINITE);
        if (r == WAIT_OBJECT_0) {
            var code: w.DWORD = 0;
            if (GetExitCodeProcess(handleOf(self.process_handle), &code) != .FALSE) {
                term.code = code;
                if (code <= 255) term.exited = @intCast(code);
            }
        }
        self.deinit();
        return term;
    }

    fn deinit(self: *WindowsProcess) void {
        if (self.process_handle != null_handle) {
            _ = CloseHandle(handleOf(self.process_handle));
            self.process_handle = null_handle;
        }
        if (self.thread_handle != null_handle) {
            _ = CloseHandle(handleOf(self.thread_handle));
            self.thread_handle = null_handle;
        }
    }
};

/// `allowzero` pointer → the `HANDLE` Win32 expects.
// ── Windows implementation ─────────────────────────────────────────────────

const w = std.os.windows;

// Only the Win32 bindings still in use are kept (the hand-rolled spawn path has been
// removed, see the file header)
extern "kernel32" fn TerminateProcess(hProcess: w.HANDLE, uExitCode: u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn ResumeThread(hThread: w.HANDLE) callconv(.winapi) w.DWORD;
extern "kernel32" fn WaitForSingleObject(hHandle: w.HANDLE, dwMilliseconds: w.DWORD) callconv(.winapi) w.DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: w.HANDLE, lpExitCode: *w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.winapi) w.BOOL;

const WAIT_OBJECT_0: w.DWORD = 0;
const INFINITE: w.DWORD = 0xFFFFFFFF;

// ── Console text encoding ───────────────────────────────────────────────────
//
// A child process writes bytes in its own idea of the text encoding, and on Windows that is the
// system ANSI code page, not UTF-8. This is not hypothetical: a Chinese-localized `make` prints its
// headings in GBK (`选项：` is `d1 a1 cf ee a1 a3`), and reading those bytes as UTF-8 yields
// mojibake. Anything that consumes a tool's real output has to account for it.

extern "kernel32" fn MultiByteToWideChar(
    code_page: w.UINT,
    flags: w.DWORD,
    multi_byte_str: [*]const u8,
    cb_multi_byte: c_int,
    wide_char_str: ?[*]u16,
    cch_wide_char: c_int,
) callconv(.winapi) c_int;

extern "kernel32" fn WideCharToMultiByte(
    code_page: w.UINT,
    flags: w.DWORD,
    wide_char_str: [*]const u16,
    cch_wide_char: c_int,
    multi_byte_str: ?[*]u8,
    cb_multi_byte: c_int,
    default_char: ?[*]const u8,
    used_default_char: ?*w.BOOL,
) callconv(.winapi) c_int;

const CP_ACP: w.UINT = 0;
const CP_UTF8: w.UINT = 65001;

/// Converts text captured from a child process into UTF-8, whatever the child actually emitted.
///
/// Returns the input unchanged when it is already valid UTF-8, which is the case on every POSIX
/// system and for tools that write UTF-8 on Windows. Only when it is *not* valid UTF-8 is the
/// system ANSI code page assumed — a heuristic, but the correct one for a localized Windows tool,
/// and strictly better than handing the UI broken text.
pub fn toUtf8(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return bytes;
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    if (@import("builtin").os.tag != .windows) {
        // No code page to consult; keep the bytes rather than dropping them, so the raw text the
        // user can inspect is still what the tool printed.
        return bytes;
    }
    if (bytes.len > std.math.maxInt(c_int)) return bytes;

    const wide_len = MultiByteToWideChar(CP_ACP, 0, bytes.ptr, @intCast(bytes.len), null, 0);
    if (wide_len <= 0) return bytes;
    const wide = try alloc.alloc(u16, @intCast(wide_len));
    const written = MultiByteToWideChar(CP_ACP, 0, bytes.ptr, @intCast(bytes.len), wide.ptr, wide_len);
    if (written <= 0) return bytes;

    const utf8_len = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, written, null, 0, null, null);
    if (utf8_len <= 0) return bytes;
    const out = try alloc.alloc(u8, @intCast(utf8_len));
    const converted = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, written, out.ptr, utf8_len, null, null);
    if (converted <= 0) return bytes;
    return out[0..@intCast(converted)];
}

/// The "empty" sentinel value for a handle.
///
/// `w.HANDLE` is `*anyopaque`, which is neither optional nor allows address 0, so a
/// separate `allowzero` pointer type is used here to express "no handle".
const AllowZeroHandle = *allowzero anyopaque;
const null_handle: AllowZeroHandle = @ptrFromInt(0);

fn handleOf(h: AllowZeroHandle) w.HANDLE {
    return @ptrCast(h);
}

const PosixProcess = struct {
    pid: i32 = 0,
    reaped: bool = false,

    fn kill(self: *PosixProcess) void {
        if (self.reaped) return;
        _ = std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
    }

    fn resumeChild(self: *PosixProcess) void {
        // POSIX does not use suspended startup
        _ = self;
    }

    fn wait(self: *PosixProcess, io: Io) Process.Term {
        _ = io;
        var term: Process.Term = .{};
        const res = std.posix.waitpid(self.pid, 0);
        self.reaped = true;
        const status = res.status;
        if (std.posix.W.IFEXITED(status)) {
            const c = std.posix.W.EXITSTATUS(status);
            term.code = c;
            if (c <= 255) term.exited = @intCast(c);
        } else {
            term.killed = true;
        }
        return term;
    }

    fn deinit(self: *PosixProcess) void {
        _ = self;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "platform: Stdio → std.process option mapping" {
    const mapped_pipe = stdIoOf(.pipe);
    try testing.expect(mapped_pipe == .pipe);

    const mapped_ignore = stdIoOf(.ignore);
    try testing.expect(mapped_ignore == .ignore);

    const mapped_inherit = stdIoOf(.inherit);
    try testing.expect(mapped_inherit == .inherit);
}

test "platform: Pipe holds Io.File and close is idempotent" {
    // A Pipe that is not held can be closed safely
    var empty: Pipe = .{};
    try testing.expect(!empty.isValid());
    empty.close();
    try testing.expect(!empty.isValid());

    // A Pipe built by fromHandle (used by the platform self-test and by tests) has a non-null handle
    const p = Pipe.fromHandle(@ptrFromInt(0x1234));
    try testing.expect(p.isValid());
    try testing.expect(@intFromPtr(p.asFile().handle) == 0x1234);
}
