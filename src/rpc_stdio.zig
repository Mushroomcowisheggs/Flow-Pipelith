//! Headless RPC transport: line-delimited JSON over stdin/stdout.
//!
//! Uses:
//!   1. End-to-end tests, which feed JSON frames in and assert the responses and events;
//!   2. A stable in-process API for third parties (the same RPC contract, no GUI required).
//!
//! Frame format: one complete JSON per line (terminated by `\n`). Events and responses share the same
//! outlet, so events may be **interleaved** between responses -- this matches `docs/RPC.md` (events carry no `id`).
//!
//! This file belongs to the `pipelith` module (same module as `rpc.zig`, which avoids Zig's
//! "one file must not belong to two modules" restriction).

const std = @import("std");
const Io = std.Io;
const rpc = @import("rpc.zig");
const builtin = @import("builtin.zig");

/// Thread-safe line output (events come from the execution thread, responses from the main thread).
const Writer = struct {
    io: Io,
    file: Io.File,
    mutex: Io.Mutex = .init,

    fn sendFn(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Writer = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        var buf: [64 * 1024]u8 = undefined;
        var w = self.file.writer(self.io, &buf);
        w.interface.writeAll(json) catch return;
        w.interface.writeByte('\n') catch return;
        w.interface.flush() catch {};
    }
};

/// Run the headless service until stdin closes. Returns the process exit code.
pub fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();

    var writer: Writer = .{ .io = io, .file = Io.File.stdout() };
    var svc = rpc.Service.init(gpa, io, init.minimal.environ, .{
        .ctx = &writer,
        .send_fn = Writer.sendFn,
    });
    defer svc.deinit();
    // No tool is loaded from the program's own defaults: the library is whatever the user installed
    // (`pack.load`) or wrote into the tool directory.
    // Headless mode sees the same user tools as the GUI, unless `PIPELITH_NO_USER_TOOLS` is set —
    // the end-to-end tests use that to stay independent of whatever is in the real state directory.
    const env = svc.envMap();
    const user_tools_disabled = if (env) |m| m.get("PIPELITH_NO_USER_TOOLS") != null else false;
    if (!user_tools_disabled) {
        if (env) |m| svc.tools_dir = try builtin.userCdlDir(io, a, m);
        svc.loadUserTools();
    }

    // Fill the working directory into the service (needed by dry-run and by {__cwd})
    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    svc.cwd = try a.dupe(u8, cwd_buf[0..cwd_len]);

    var stdin_buf: [64 * 1024]u8 = undefined;
    var rd = Io.File.stdin().reader(io, &stdin_buf);

    while (true) {
        // One arena per frame: request objects and responses are allocated here and released as a whole when handled
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        const fa = frame_arena.allocator();

        const line = (try readLine(&rd.interface, fa, 8 * 1024 * 1024)) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        const responses = try rpc.handleRequest(&svc, fa, trimmed);
        for (responses) |resp| Writer.sendFn(&writer, resp);
    }

    return 0;
}

/// Read one line (without the newline character); returns null at EOF.
fn readLine(rd: *Io.Reader, a: std.mem.Allocator, limit: usize) !?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = rd.readSliceShort(&byte) catch return null;
        if (n == 0) {
            if (out.items.len == 0) return null;
            return out.items;
        }
        if (byte[0] == '\n') return out.items;
        if (out.items.len >= limit) return out.items;
        try out.append(a, byte[0]);
    }
}
