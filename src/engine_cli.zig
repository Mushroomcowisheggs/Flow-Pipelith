//! Headless execution tool: read a `.flow` from a file, execute it, and write the events
//! to stdout as JSON lines.
//!
//! Purpose:
//!   1. End-to-end verification of the execution engine without a GUI: this mode is what
//!      `zig build test` and the GUI harness drive;
//!   2. A command-line entry point for users who want to "run workflows without a GUI";
//!   3. A baseline for comparison when debugging GUI problems (the same `.flow` should
//!      behave identically along both paths).
//!
//! Exit codes: 0 = all succeeded; 1 = a node failed; 2 = argument/load error; 3 = cancelled; 4 = timed out.

const std = @import("std");
const Io = std.Io;
const pipelith = @import("pipelith");

const value = pipelith.value;
const cdl = pipelith.cdl;
const builtin = pipelith.builtin;
const graph_mod = pipelith.graph;
const engine = pipelith.engine;
const emit = pipelith.emit;

const Value = value.Value;

/// Event sink: encodes engine events as JSON lines written to stdout.
const Emitter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: Io.File,
    mutex: Io.Mutex = .init,
    /// Event sequence number matching the real RPC layer, so tests can assert ordering
    seq: u64 = 0,
    /// Both the value tree and the serialization of a single event happen in this arena,
    /// which is reset immediately afterwards. Events are fire-and-forget; allocating each
    /// one from `gpa` would accumulate leaks (measured by a debugging allocator).
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator, io: Io, file: Io.File) Emitter {
        return .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    fn deinit(self: *Emitter) void {
        self.arena.deinit();
    }

    fn callback(ctx: ?*anyopaque, event: engine.Event) void {
        const self: *Emitter = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        // Reset the arena after each event: the peak only depends on a single event's size
        defer _ = self.arena.reset(.retain_capacity);

        const a = self.arena.allocator();
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        const v = self.eventToValue(a, event) catch return;
        emit.writeValue(&aw.writer, v, .{}, 0) catch return;
        aw.writer.writeByte('\n') catch return;
        aw.writer.flush() catch {};
        self.file.writeStreamingAll(self.io, aw.written()) catch {};
    }

    fn eventToValue(self: *Emitter, gpa: std.mem.Allocator, event: engine.Event) !Value {
        self.seq += 1;
        const o = try gpa.create(Value.Object);
        o.* = .{};
        try o.put(gpa, "seq", .{ .int = @intCast(self.seq) });

        switch (event) {
            .run_started => |e| {
                try o.put(gpa, "event", .{ .string = "run.started" });
                try o.put(gpa, "runId", .{ .string = e.run_id });
                try o.put(gpa, "nodeIds", try strArray(gpa, e.node_ids));
            },
            .node_started => |e| {
                try o.put(gpa, "event", .{ .string = "node.started" });
                try o.put(gpa, "runId", .{ .string = e.run_id });
                try o.put(gpa, "nodeId", .{ .string = e.node_id });
                try o.put(gpa, "argv", try strArray(gpa, e.argv));
            },
            .node_output => |e| {
                try o.put(gpa, "event", .{ .string = "node.output" });
                try o.put(gpa, "runId", .{ .string = e.run_id });
                try o.put(gpa, "nodeId", .{ .string = e.node_id });
                try o.put(gpa, "stream", .{ .string = e.stream.wire() });
                try o.put(gpa, "text", .{ .string = e.text });
            },
            .node_finished => |e| {
                try o.put(gpa, "event", .{ .string = "node.finished" });
                try o.put(gpa, "runId", .{ .string = e.run_id });
                try o.put(gpa, "nodeId", .{ .string = e.node_id });
                try o.put(gpa, "status", .{ .string = e.status.wire() });
                try o.put(gpa, "exitCode", if (e.exit_code) |c| .{ .int = c } else .null);
                try o.put(gpa, "durationMs", .{ .int = @intCast(e.duration_ms) });
                try o.put(gpa, "message", if (e.message) |m| .{ .string = m } else .null);
            },
            .run_finished => |e| {
                try o.put(gpa, "event", .{ .string = "run.finished" });
                try o.put(gpa, "runId", .{ .string = e.run_id });
                try o.put(gpa, "status", .{ .string = e.status.wire() });
                try o.put(gpa, "durationMs", .{ .int = @intCast(e.duration_ms) });
                try o.put(gpa, "failed", try strArray(gpa, e.failed));
            },
            .log => |e| {
                try o.put(gpa, "event", .{ .string = "log" });
                try o.put(gpa, "level", .{ .string = @tagName(e.level) });
                try o.put(gpa, "message", .{ .string = e.message });
            },
        }
        return .{ .object = o };
    }
};

fn strArray(gpa: std.mem.Allocator, items: []const []const u8) !Value {
    const buf = try gpa.alloc(Value, items.len);
    for (items, 0..) |s, i| buf[i] = .{ .string = s };
    return .{ .array = buf };
}

/// Standalone executable entry point: `pipelith-run <flow file> [--dry-run]`
pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return run(init, args);
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var errw = Io.File.stderr().writer(io, &stderr_buf);
    const ew = &errw.interface;

    if (args.len < 2) {
        try ew.writeAll("usage: pipelith run <flow file> [--dry-run]\n");
        try ew.flush();
        return 2;
    }
    const path = std.mem.sliceTo(args[1], 0);
    var dry_run = false;
    var state_override: ?[]const u8 = null;
    var arg_i: usize = 2;
    while (arg_i < args.len) : (arg_i += 1) {
        const s = std.mem.sliceTo(args[arg_i], 0);
        if (std.mem.eql(u8, s, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, s, "--state-dir")) {
            // Same override the GUI uses, so a scripted or hermetic run reads the tools it installed
            // instead of whatever happens to sit next to the executable.
            arg_i += 1;
            if (arg_i < args.len) state_override = std.mem.sliceTo(args[arg_i], 0);
        }
    }

    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |e| {
        try ew.print("cannot read {s}: {t}\n", .{ path, e });
        try ew.flush();
        return 2;
    };

    // Tools come from the tool directory only — the packs the user installed plus any CDL they wrote
    // there. The program's own defaults are never loaded (a fresh installation has an empty tool
    // library), so a flow whose nodes reference a preset needs that tool installed first.
    const state_dir: ?[]const u8 = state_override orelse (try builtin.stateDir(io, arena));
    var docs: std.StringArrayHashMapUnmanaged(cdl.Doc) = .empty;
    if (state_dir) |state| {
        const cdl_dir = try std.fs.path.join(arena, &.{ state, pipelith.packs.installed_dir_name });
        _ = try pipelith.packs.loadDir(io, arena, arena, cdl_dir, &docs);
    }

    // Assemble an event sink + engine
    var emitter: Emitter = .init(init.gpa, io, Io.File.stdout());
    defer emitter.deinit();

    // flow parsing
    const flow_res = try graph_mod.loadFromJson(arena, text);
    if (flow_res == .err) {
        try ew.print("workflow failed to parse: {s} @ {s}\n", .{ flow_res.err.message, flow_res.err.path });
        try ew.flush();
        return 2;
    }
    if (flow_res.ok.hasErrors()) {
        for (flow_res.ok.issues) |i| {
            if (i.level == .@"error") try ew.print("error: {s}\n", .{i.message});
        }
        try ew.flush();
        return 2;
    }
    var g = flow_res.ok.graph;
    for (flow_res.ok.issues) |i| {
        if (i.level == .warning) try ew.print("warning: {s}\n", .{i.message});
    }

    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const cwd = cwd_buf[0..cwd_len];

    const plan_res = try engine.buildPlan(arena, &g, &docs, .{
        .cwd = cwd,
        .resolve_executable = false,
        .environ = init.environ_map,
        .io = io,
    });
    if (plan_res == .err) {
        try ew.print("cannot build the execution plan: {s}\n", .{plan_res.err.message});
        try ew.flush();
        return 2;
    }
    const plan = plan_res.ok;

    if (dry_run) {
        for (plan.nodes) |n| {
            const cmd = try engine.formatCommand(arena, n.argv);
            try ew.print("[dry-run] {s}: {s}\n", .{ n.title, cmd });
        }
        try ew.flush();
        return 0;
    }

    // The engine must allocate from a **run-scoped** arena, not from the process allocator.
    // `execute` frees each `NodeRun` itself but also allocates per-run scratch it never frees
    // individually (the running registry, the batch lists, the pipe spill path); with the general
    // allocator that surfaced as a leak report after every `--run`. Tied to an arena released a few
    // lines below, the scratch costs nothing to clean up. This mirrors `rpc.runWorker`, which is
    // where the GUI gets the same behaviour.
    var run_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer run_arena.deinit();
    var eng = engine.Engine.init(run_arena.allocator(), io, init.minimal.environ, Emitter.callback, &emitter);
    const status = try eng.execute(&plan, .{ .run_id = "cli" });
    return switch (status) {
        .success => 0,
        .cancelled => 3,
        .timed_out => 4,
        else => 1,
    };
}
