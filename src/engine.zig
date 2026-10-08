//! Execution engine: DAG scheduling, real pipes, output forwarding, timeouts and cancellation.
//!
//! ── Processes and pipes all go through `platform.zig` ──
//! `std.process.spawn` is not used: on Windows it cannot hand a pipe handle to another
//! child process (see the empirical notes at the top of `platform.zig`). This module
//! therefore depends only on `platform.Process`, whose handle semantics we control.
//!
//! ── Execution flow (the order must not be reversed) ──
//!   1. Execute layer by layer; nodes in the same layer run in parallel.
//!   2. **Spawn**: downstream nodes fed data by this layer are spawned in the same batch,
//!      with their stdin connected directly to the read end of the upstream stdout
//!      (cross-process handle sharing is guaranteed by the platform layer); downstream
//!      starts suspended so upstream and downstream do not wait on each other when the
//!      thread pool is saturated.
//!   3. **Concurrent pumping**: stdout draining (and forwarding to downstream), stderr
//!      draining, text/file stdin injection, timeout watchdog.
//!   4. **Wait only after pumping finishes**: this guarantees that "close downstream stdin
//!      to deliver EOF" happens first.
//!   5. Wrap-up: close every handle held by this process and aggregate the status.

const std = @import("std");
const Io = std.Io;
const Value = @import("value.zig");
const cdl = @import("cdl.zig");
const graph_mod = @import("graph.zig");
const builtin = @import("builtin.zig");
const platform = @import("platform.zig");

pub const NodeStatus = enum {
    pending,
    running,
    success,
    failed,
    skipped,
    cancelled,
    timed_out,

    pub fn wire(self: NodeStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .success => "success",
            .failed => "failed",
            .skipped => "skipped",
            .cancelled => "cancelled",
            .timed_out => "timedOut",
        };
    }
};

pub const StreamName = enum {
    stdout,
    stderr,

    pub fn wire(self: StreamName) []const u8 {
        return switch (self) {
            .stdout => "stdout",
            .stderr => "stderr",
        };
    }
};

// ── Events ─────────────────────────────────────────────────────────

pub const Event = union(enum) {
    run_started: struct { run_id: []const u8, node_ids: []const []const u8 },
    node_started: struct { run_id: []const u8, node_id: []const u8, argv: []const []const u8 },
    node_output: struct {
        run_id: []const u8,
        node_id: []const u8,
        stream: StreamName,
        text: []const u8,
    },
    node_finished: struct {
        run_id: []const u8,
        node_id: []const u8,
        status: NodeStatus,
        exit_code: ?i32,
        duration_ms: u64,
        message: ?[]const u8,
    },
    run_finished: struct {
        run_id: []const u8,
        status: NodeStatus,
        duration_ms: u64,
        failed: []const []const u8,
        skipped: []const []const u8,
    },
    log: struct { level: cdl.Level, message: []const u8 },
};

pub const EventFn = *const fn (ctx: ?*anyopaque, event: Event) void;

/// Execution tracing switch (off by default; set to true when diagnosing hang-type problems).
pub var trace_enabled: bool = false;

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!trace_enabled) return;
    std.debug.print("[pipelith] " ++ fmt ++ "\n", args);
}

// ── Execution plan ─────────────────────────────────────────────────────

pub const PlanNode = struct {
    id: []const u8,
    cdl_name: []const u8,
    action: []const u8,
    title: []const u8,
    executable: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const cdl.Action.EnvPair = &.{},
    /// Upstream pipe source node id
    pipe_from: ?[]const u8 = null,
    /// Downstream pipe consumer node id
    pipe_to: ?[]const u8 = null,
    /// Downstream node id wired with `seq` (run it only after this node succeeds)
    seq_to: ?[]const u8 = null,
    /// Upstream node id wired with `seq` (run this node only if that one succeeds)
    seq_from: ?[]const u8 = null,
    /// stdin content when there is no upstream pipe (CDL `stdin: text`)
    stdin_text: ?[]const u8 = null,
    /// stdin file when there is no upstream pipe (CDL `stdin: file:{var}`)
    stdin_file: ?[]const u8 = null,
    capture_stdout: bool = true,
    capture_stderr: bool = true,
    timeout_ms: ?u64 = null,
    retry: u32 = 0,
    /// Names of required variables that are missing
    missing: []const []const u8 = &.{},

    pub fn command(self: *const PlanNode, alloc: std.mem.Allocator) ![]const u8 {
        return formatCommand(alloc, self.argv);
    }
};

pub const Plan = struct {
    nodes: []const PlanNode,
    order: []const []const u8,
    layers: []const []const []const u8,

    pub fn find(self: *const Plan, id: []const u8) ?*const PlanNode {
        for (self.nodes) |*n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }
};

pub const PlanResult = union(enum) {
    ok: Plan,
    err: struct { message: []const u8, node_id: ?[]const u8 = null },
};

// ── Placeholder resolution ───────────────────────────────────────────────────

pub const Resolver = struct {
    alloc: std.mem.Allocator,
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    cwd: []const u8 = ".",

    pub fn init(alloc: std.mem.Allocator) Resolver {
        return .{ .alloc = alloc };
    }

    pub fn set(self: *Resolver, key: []const u8, val: []const u8) !void {
        try self.values.put(self.alloc, key, val);
    }

    pub fn get(self: *const Resolver, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }

    /// Variable "is true" test: false/no/off/0/empty/unset all count as false.
    pub fn truthy(self: *const Resolver, key: []const u8) bool {
        const v = self.get(key) orelse return false;
        if (v.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(v, "false")) return false;
        if (std.ascii.eqlIgnoreCase(v, "no")) return false;
        if (std.ascii.eqlIgnoreCase(v, "off")) return false;
        if (std.mem.eql(u8, v, "0")) return false;
        return true;
    }

    /// Expand `{name}` / `{name_dir}` / `{name_base}` / `{name_stem}` / `{__cwd}`.
    pub fn expand(self: *const Resolver, template: []const u8) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const a = self.alloc;
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] != '{') {
                try out.append(a, template[i]);
                i += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse {
                try out.appendSlice(a, template[i..]);
                break;
            };
            try out.appendSlice(a, try self.resolveOne(template[i + 1 .. close]));
            i = close + 1;
        }
        return out.items;
    }

    fn resolveOne(self: *const Resolver, name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, name, "__cwd")) return self.cwd;
        if (name.len > 4 and std.mem.endsWith(u8, name, "_dir")) {
            if (self.get(name[0 .. name.len - 4])) |v| return dirName(v);
        }
        if (name.len > 5 and std.mem.endsWith(u8, name, "_base")) {
            if (self.get(name[0 .. name.len - 5])) |v| return std.fs.path.basename(v);
        }
        if (name.len > 5 and std.mem.endsWith(u8, name, "_stem")) {
            if (self.get(name[0 .. name.len - 5])) |v| return stemName(v);
        }
        if (self.get(name)) |v| return v;
        // Undefined placeholders are kept verbatim so problems can be pinpointed from the
        // output (CDL validation has already rejected them up front)
        return std.fmt.allocPrint(self.alloc, "{{{s}}}", .{name});
    }
};

fn dirName(path: []const u8) []const u8 {
    if (std.fs.path.dirname(path)) |d| {
        if (d.len > 0) return d;
    }
    return ".";
}

fn stemName(path: []const u8) []const u8 {
    const b = std.fs.path.basename(path);
    const e = std.fs.path.extension(b);
    if (e.len == 0) return b;
    return b[0 .. b.len - e.len];
}

// ── Plan construction ─────────────────────────────────────────────────────

pub const BuildOptions = struct {
    overrides: ?*const std.StringArrayHashMapUnmanaged([]const u8) = null,
    cwd: []const u8 = ".",
    resolve_executable: bool = false,
    environ: ?*const std.process.Environ.Map = null,
    io: ?Io = null,
};

pub fn buildPlan(
    alloc: std.mem.Allocator,
    g: *const graph_mod.Graph,
    docs_by_name: *const std.StringArrayHashMapUnmanaged(cdl.Doc),
    opts: BuildOptions,
) error{OutOfMemory}!PlanResult {
    const sched = graph_mod.schedule(alloc, g) catch |e| switch (e) {
        error.Cycle => return .{ .err = .{ .message = "the workflow contains a cycle, cannot produce an execution order" } },
        error.OutOfMemory => return error.OutOfMemory,
    };

    var plan_nodes: std.ArrayListUnmanaged(PlanNode) = .empty;

    for (g.nodes.items) |*node| {
        if (node.disabled) continue;

        // ── raw command node ────────────────────────────────────────────────
        // No CDL, no action, no variables: argv is taken verbatim, argv[0] being the executable.
        // Streams default to "capture both, no implicit stdin", which is the safe choice for an
        // unknown program (a process that never reads stdin must not be handed one).
        if (node.argv.len > 0) {
            const raw_exe = node.argv[0];
            var raw_executable: []const u8 = try alloc.dupe(u8, raw_exe);
            if (opts.resolve_executable and opts.environ != null and opts.io != null) {
                if (try builtin.resolveExecutable(opts.io.?, alloc, opts.environ.?, raw_exe)) |abs| {
                    raw_executable = abs;
                }
            }
            // Keep argv[0] as the user typed it unless resolution actually found something; the
            // displayed command should read the way the user wrote it.
            var raw_argv: std.ArrayListUnmanaged([]const u8) = .empty;
            try raw_argv.append(alloc, raw_executable);
            for (node.argv[1..]) |rest| try raw_argv.append(alloc, try alloc.dupe(u8, rest));

            var raw_pipe_from: ?[]const u8 = null;
            if (g.pipeUpstream(node.id)) |e| raw_pipe_from = e.from;
            var raw_pipe_to: ?[]const u8 = null;
            for (g.edges.items) |e| {
                if (e.kind == .pipe and std.mem.eql(u8, e.from, node.id)) {
                    raw_pipe_to = e.to;
                    break;
                }
            }
            var raw_seq_to: ?[]const u8 = null;
            for (g.edges.items) |e| {
                if (e.kind == .seq and std.mem.eql(u8, e.from, node.id)) {
                    raw_seq_to = e.to;
                    break;
                }
            }
            var raw_seq_from: ?[]const u8 = null;
            for (g.edges.items) |e| {
                if (e.kind == .seq and std.mem.eql(u8, e.to, node.id)) {
                    raw_seq_from = e.from;
                    break;
                }
            }
            try plan_nodes.append(alloc, .{
                .id = node.id,
                .cdl_name = "",
                .action = "",
                .title = node.title,
                .executable = raw_executable,
                .argv = raw_argv.items,
                .cwd = opts.cwd,
                .pipe_from = raw_pipe_from,
                .pipe_to = raw_pipe_to,
                .seq_to = raw_seq_to,
                .seq_from = raw_seq_from,
                .timeout_ms = node.timeout_ms,
                .retry = node.retry,
            });
            continue;
        }

        const doc = docs_by_name.getPtr(node.cdl_name) orelse {
            return .{ .err = .{
                .message = try std.fmt.allocPrint(alloc, "node \"{s}\" references a CDL that was not found: {s}", .{ node.title, node.cdl_name }),
                .node_id = node.id,
            } };
        };
        const act = doc.findAction(node.action) orelse {
            return .{ .err = .{
                .message = try std.fmt.allocPrint(
                    alloc,
                    "node \"{s}\" references an action that does not exist in {s}: {s}",
                    .{ node.title, node.cdl_name, node.action },
                ),
                .node_id = node.id,
            } };
        };

        var res = Resolver.init(alloc);
        res.cwd = opts.cwd;
        const vars = try act.allVars(doc, alloc);
        for (vars) |v| {
            if (v.default) |d| try res.set(v.name, d);
        }
        for (node.values.keys(), node.values.values()) |k, v| {
            try res.set(k, v);
        }
        if (opts.overrides) |ov| {
            for (ov.keys(), ov.values()) |k, v| {
                if (std.mem.indexOfScalar(u8, k, '.') == null) try res.set(k, v);
            }
        }

        var missing: std.ArrayListUnmanaged([]const u8) = .empty;
        for (vars) |v| {
            if (!v.required) continue;
            const val = res.get(v.name) orelse "";
            if (val.len == 0) try missing.append(alloc, v.name);
        }

        // A per-node override wins over the action's own executable, so one node can use a specific
        // build while its neighbours keep the PATH default.
        const exe_name = if (node.executable.len > 0) node.executable else act.exe(doc);
        var executable: []const u8 = try alloc.dupe(u8, exe_name);
        if (opts.resolve_executable and opts.environ != null and opts.io != null) {
            if (try builtin.resolveExecutable(opts.io.?, alloc, opts.environ.?, exe_name)) |abs| {
                executable = abs;
            }
        }

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(alloc, executable);
        for (act.args) |arg| {
            if (arg.when) |w| {
                if (!res.truthy(w)) continue;
            }
            if (arg.repeat) |r| {
                const list = res.get(r) orelse continue;
                var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
                while (it.next()) |item| {
                    if (arg.prefix) |p| {
                        try argv.append(alloc, try std.fmt.allocPrint(alloc, "{s}{s}", .{ p, item }));
                    } else {
                        try argv.append(alloc, try alloc.dupe(u8, item));
                    }
                }
                continue;
            }
            if (arg.var_name) |vn| {
                const val = res.get(vn) orelse "";
                if (val.len == 0) continue;
                try argv.append(alloc, try res.expand(try std.fmt.allocPrint(alloc, "{{{s}}}", .{vn})));
                continue;
            }
            const expanded = try res.expand(arg.value);
            if (expanded.len == 0) continue;
            try argv.append(alloc, expanded);
        }

        var env_pairs: std.ArrayListUnmanaged(cdl.Action.EnvPair) = .empty;
        for (act.env) |pair| {
            try env_pairs.append(alloc, .{ .key = pair.key, .value = try res.expand(pair.value) });
        }

        var pipe_from: ?[]const u8 = null;
        if (g.pipeUpstream(node.id)) |e| pipe_from = e.from;
        var pipe_to: ?[]const u8 = null;
        for (g.edges.items) |e| {
            if (e.kind == .pipe and std.mem.eql(u8, e.from, node.id)) {
                pipe_to = e.to;
                break;
            }
        }
        // Sequential edges (`seq`): used to decide failure propagation
        var seq_to: ?[]const u8 = null;
        var seq_from: ?[]const u8 = null;
        for (g.edges.items) |e| {
            if (e.kind != .seq and e.kind != .cond) continue;
            if (std.mem.eql(u8, e.from, node.id) and seq_to == null) seq_to = e.to;
            if (std.mem.eql(u8, e.to, node.id) and seq_from == null) seq_from = e.from;
        }

        var stdin_text: ?[]const u8 = null;
        var stdin_file: ?[]const u8 = null;
        if (pipe_from == null) {
            switch (act.stdin.mode) {
                .text => stdin_text = try res.expand(act.stdin.raw),
                .file_var => {
                    if (act.stdin.var_name) |vn| {
                        if (res.get(vn)) |p| stdin_file = try res.expand(p);
                    }
                },
                else => {},
            }
        }

        var cwd: ?[]const u8 = null;
        if (act.cwd) |c| cwd = try res.expand(c);

        var timeout_ms: ?u64 = null;
        if (node.timeout_ms) |t| {
            timeout_ms = t;
        } else if (act.timeout) |secs| {
            timeout_ms = @as(u64, secs) * 1000;
        }

        try plan_nodes.append(alloc, .{
            .id = node.id,
            .cdl_name = node.cdl_name,
            .action = node.action,
            .title = node.title,
            .executable = executable,
            .argv = argv.items,
            .cwd = cwd,
            .env = env_pairs.items,
            .pipe_from = pipe_from,
            .pipe_to = pipe_to,
            .seq_to = seq_to,
            .seq_from = seq_from,
            .stdin_text = stdin_text,
            .stdin_file = stdin_file,
            .capture_stdout = act.stdout.mode != .discard,
            .capture_stderr = act.stderr.mode != .discard,
            .timeout_ms = timeout_ms,
            .retry = node.retry,
            .missing = missing.items,
        });
    }

    return .{ .ok = .{ .nodes = plan_nodes.items, .order = sched.order, .layers = sched.layers } };
}

/// Human-readable command (no shell semantics; arguments containing whitespace are
/// quoted for readability).
pub fn formatCommand(alloc: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i > 0) try out.append(alloc, ' ');
        const quote = std.mem.indexOfAny(u8, a, " \t\"'") != null;
        if (quote) try out.append(alloc, '"');
        try out.appendSlice(alloc, a);
        if (quote) try out.append(alloc, '"');
    }
    return out.items;
}

// ── Runtime state ───────────────────────────────────────────────────

/// One per node, **heap-allocated** (the address must stay stable: concurrent tasks
/// hold a pointer to it).
const NodeRun = struct {
    plan: *const PlanNode,
    proc: ?platform.Process = null,
    spawned: bool = false,
    /// Upstream pipe source (path of its temporary output file)
    feed_file_path: ?[]const u8 = null,
    /// Upstream temporary file opened by this node (closed when it finishes)
    opened_stdin: ?Io.File = null,
    /// Path of this node's temporary output file (opened by downstream via `.file`)
    out_file_path: ?[]const u8 = null,
    started_ms: i64 = 0,
    /// A **copy** of this node's stdout read end (used for reading only; closing must go
    /// through `proc.closeStdout()`).
    ///
    /// Beware of aliasing: `platform.Pipe` wraps an `Io.File`, and copying it by value
    /// leaves two copies holding **the same kernel handle**. Closing it here and again
    /// via `proc.stdout` would close one handle twice → a native `STATUS_INVALID_HANDLE`
    /// crash on Windows.
    out_pipe: ?platform.Pipe = null,
    catch_out: std.ArrayListUnmanaged(u8) = .empty,
    catch_err: std.ArrayListUnmanaged(u8) = .empty,
    timed_out: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    status: NodeStatus = .pending,
    term: ?platform.Process.Term = null,
    message: ?[]const u8 = null,

    /// Close the stdout read end held by the parent process (idempotent; always routed
    /// through `proc` to avoid a duplicate close through the alias).
    fn closeOutPipe(self: *NodeRun) void {
        if (self.proc) |*p| p.closeStdout();
        self.out_pipe = null;
    }
};

/// io reference used by `Io.File.close` (set in `Engine.init`).
var io_ref: ?Io = null;

pub const RunOptions = struct {
    run_id: []const u8,
};

pub const Engine = struct {
    alloc: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    event_fn: EventFn,
    event_ctx: ?*anyopaque,

    mutex: Io.Mutex = .init,
    cancelled: bool = false,
    running: std.ArrayListUnmanaged(*NodeRun) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        environ: std.process.Environ,
        event_fn: EventFn,
        event_ctx: ?*anyopaque,
    ) Engine {
        platform.setDefaultIo(io);
        io_ref = io;
        return .{
            .alloc = gpa,
            .io = io,
            .environ = environ,
            .event_fn = event_fn,
            .event_ctx = event_ctx,
        };
    }

    fn emit(self: *Engine, event: Event) void {
        self.event_fn(self.event_ctx, event);
    }

    /// Cancel the run: flag it and terminate every process still running (idempotent).
    pub fn cancel(self: *Engine) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        self.cancelled = true;
        for (self.running.items) |run| {
            if (run.proc) |*p| p.kill();
        }
    }

    fn register(self: *Engine, run: *NodeRun) !void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        try self.running.append(self.alloc, run);
    }

    fn unregister(self: *Engine, run: *NodeRun) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        for (self.running.items, 0..) |r, i| {
            if (r == run) {
                _ = self.running.swapRemove(i);
                return;
            }
        }
    }

    fn isCancelled(self: *Engine) bool {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        return self.cancelled;
    }

    /// Execute the whole workflow.
    pub fn execute(self: *Engine, plan: *const Plan, opts: RunOptions) error{OutOfMemory}!NodeStatus {
        const a = self.alloc;
        const io = self.io;
        const started = Io.Clock.Timestamp.now(io, .awake);

        var node_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        for (plan.nodes) |n| try node_ids.append(a, n.id);
        self.emit(.{ .run_started = .{ .run_id = opts.run_id, .node_ids = node_ids.items } });

        // Spill directory for pipe edges: always inside the tool directory.
        // Falls back to a relative path only if the executable directory cannot
        // be resolved (nothing we can do about that), and the fallback is still
        // reported in the log rather than silently used.
        const pipeDir: ?[]const u8 = builtin.stateSubdir(io, a, "pipe") catch null;

        var runs: std.StringArrayHashMapUnmanaged(*NodeRun) = .empty;
        for (plan.nodes) |*pn| {
            const r = try a.create(NodeRun);
            r.* = .{ .plan = pn };
            try runs.put(a, pn.id, r);
        }

        var failed: std.ArrayListUnmanaged([]const u8) = .empty;
        var skipped_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var overall: NodeStatus = .success;

        // Each node's own environment overrides need a separate Map; the same Map is
        // reused here, overwritten per node: first write the env declared by the action,
        // then remove it after spawning, so a new Map is not created for every node
        // (which would leak).
        var env = std.process.Environ.createMap(self.environ, a) catch return error.OutOfMemory;
        defer env.deinit();
        var env_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer env_keys.deinit(a);

        for (plan.layers) |layer| {
            trace("layer begin size={d}", .{layer.len});

            // ── 1. Decide which nodes to spawn in this batch ───────
            var batch: std.ArrayListUnmanaged(*NodeRun) = .empty;
            for (layer) |id| {
                const run = runs.get(id) orelse continue;
                if (run.spawned) continue;
                // Data handover for pipe edges: take the "temporary output file" path
                // from the upstream node
                // (the upstream node is always in an earlier layer, and its file has
                // already been fully written and flushed by now)
                if (run.plan.pipe_from) |from_id| {
                    if (runs.get(from_id)) |up| {
                        if (up.out_file_path) |p| run.feed_file_path = p;
                    }
                }
                try batch.append(a, run);
            }

            // ── 2. Spawn ───────────────────────────────────────────
            var to_run: std.ArrayListUnmanaged(*NodeRun) = .empty;
            for (batch.items) |run| {
                if (run.spawned) continue;
                if (self.isCancelled()) {
                    run.status = .cancelled;
                    continue;
                }

                // A dependency did not succeed → skip.
                // Pipe upstreams live in earlier layers, and so do `seq` upstreams; as
                // soon as any upstream failed/timed out/was cancelled, this node must not
                // run (MVP semantics: "sequential = run B after A finishes", so if A did
                // not succeed then B does not run).
                if (self.firstFailedDependency(plan, &runs, run.plan.id)) |dep_id| {
                    const msg = try std.fmt.allocPrint(a, "upstream node \"{s}\" did not succeed, node skipped", .{dep_id});
                    run.status = .skipped;
                    run.message = msg;
                    try skipped_list.append(a, run.plan.id);
                    // Keep the most severe outcome: a run in which something was skipped
                    // because it could not run is not a success.
                    overall = mergeOverall(overall, .skipped);
                    self.emit(.{ .node_finished = .{
                        .run_id = opts.run_id,
                        .node_id = run.plan.id,
                        .status = .skipped,
                        .exit_code = null,
                        .duration_ms = 0,
                        .message = msg,
                    } });
                    continue;
                }

                if (run.plan.missing.len > 0) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "missing required values: {s}",
                        .{try joinNames(a, run.plan.missing)},
                    );
                    run.status = .failed;
                    run.message = msg;
                    try failed.append(a, run.plan.id);
                    // A node that never started because its inputs are missing is still a
                    // failure of the run: without this the overall status stayed `success`
                    // while a node was reported failed, so `run.finished` lied and the
                    // CLI exited 0.
                    overall = mergeOverall(overall, .failed);
                    self.emit(.{ .node_finished = .{
                        .run_id = opts.run_id,
                        .node_id = run.plan.id,
                        .status = .failed,
                        .exit_code = null,
                        .duration_ms = 0,
                        .message = msg,
                    } });
                    continue;
                }

                // Write this node's environment overrides (removed after spawning so
                // nodes never pollute each other)
                for (run.plan.env) |pair| {
                    try env.put(pair.key, pair.value);
                    try env_keys.append(a, pair.key);
                }
                self.spawnRun(run, &env) catch |e| {
                    run.status = .failed;
                    run.message = try std.fmt.allocPrint(a, "cannot start `{s}`: {t}", .{ run.plan.executable, e });
                    try failed.append(a, run.plan.id);
                    self.emit(.{ .node_finished = .{
                        .run_id = opts.run_id,
                        .node_id = run.plan.id,
                        .status = .failed,
                        .exit_code = null,
                        .duration_ms = 0,
                        .message = run.message,
                    } });
                    for (env_keys.items) |k| _ = env.swapRemove(k);
                    env_keys.clearRetainingCapacity();
                    continue;
                };
                for (env_keys.items) |k| _ = env.swapRemove(k);
                env_keys.clearRetainingCapacity();
                run.started_ms = nowMs(io);
                self.emit(.{ .node_started = .{
                    .run_id = opts.run_id,
                    .node_id = run.plan.id,
                    .argv = run.plan.argv,
                } });
                try to_run.append(a, run);
            }

            // ── 3. stdio wiring after spawning ─────────────────────
            // stdin text / file injection and the watchdog are both handled in the
            // synchronous phase
            for (to_run.items) |run| {
                // With no stdin demand, close the write end immediately so the child sees
                // EOF right away
                const has_feed = run.plan.stdin_text != null or run.plan.stdin_file != null or run.plan.pipe_from != null;
                if (!has_feed) {
                    if (run.proc) |*p| p.closeStdin();
                }
                if (!run.plan.capture_stdout) run.closeOutPipe();
                if (!run.plan.capture_stderr) {
                    if (run.proc) |*p| p.closeStderr();
                }
            }

            // ── 4. Per-node synchronous drain + reaping ────────────
            // Note: `io.concurrent` is deliberately **not** used here for concurrent
            // draining. Measured on this machine with Zig 0.17-dev + Windows,
            // `Io.Future.await` blocks forever in the "read a pipe from another thread"
            // scenario (measured: the drain loop has already printed its end, yet the
            // matching future's `await` never returns).
            // So instead: first read this node's stdout/stderr to EOF (blocking read),
            // then `wait`. The cost is no parallelism within a layer; what we get in
            // return is deterministic behaviour that never hangs.
            for (to_run.items) |run| {
                // stdin injection (text / file) — close the write end afterwards to
                // deliver EOF
                if (run.plan.stdin_text) |text| {
                    writeStdinSync(self, run, .{ .text = text });
                } else if (run.plan.stdin_file) |path| {
                    writeStdinSync(self, run, .{ .file = path });
                }

                // Timeout watchdog: an ordinary thread; on timeout it calls TerminateProcess
                var watchdog: ?std.Thread = null;
                if (run.plan.timeout_ms) |ms| {
                    watchdog = std.Thread.spawn(.{}, watchdogThread, .{ self, run, ms }) catch null;
                }

                drainSync(self, opts.run_id, run, .stdout);
                drainSync(self, opts.run_id, run, .stderr);

                const term = if (run.proc) |*p| p.wait(io) else null;
                run.term = term;
                run.finished.store(true, .monotonic);
                if (watchdog) |t| t.join();

                run.closeOutPipe();
                if (run.proc) |*p| {
                    p.closePipes();
                    p.deinit();
                }
                self.unregister(run);

                const st = classify(run, term);
                run.status = st;
                if (st == .failed or st == .timed_out) try failed.append(a, run.plan.id);
                if (st == .cancelled) overall = .cancelled;
                // Keep the most severe outcome. A timed-out node must NOT be reported as a
                // plain `failed` run: the node's own status is `timed_out`, and the run
                // status has to agree with the nodes it contains (`mergeOverall` below
                // orders the states so this cannot be downgraded).
                if (st == .failed or st == .timed_out) overall = mergeOverall(overall, st);

                // Pipe edge: spill the captured stdout to disk so the downstream
                // node can open it with `.file`.
                //
                // The spill directory lives under `<tool dir>/.pipelith/pipe`, not
                // under the launch cwd, so a run started from anywhere still writes
                // only inside the tool directory (portability guarantee).
                if (run.plan.pipe_to != null and st == .success) {
                    const base = pipeDir orelse ".pipelith/pipe";
                    const path = try std.fmt.allocPrint(
                        a,
                        "{s}/{s}-{s}.out",
                        .{ base, opts.run_id, run.plan.id },
                    );
                    const dir = pipeDir orelse ".pipelith/pipe";
                    Io.Dir.cwd().createDirPath(io, dir) catch {};
                    const f = Io.Dir.cwd().createFile(io, path, .{}) catch null;
                    if (f) |file| {
                        file.writeStreamingAll(io, run.catch_out.items) catch {};
                        file.close(io);
                        run.out_file_path = path;
                    } else {
                        self.emit(.{ .log = .{
                            .level = .@"error",
                            .message = try std.fmt.allocPrint(
                                a,
                                "node \"{s}\": cannot write pipe spill file {s}; downstream will receive no data",
                                .{ run.plan.title, path },
                            ),
                        } });
                    }
                }

                // Close the upstream temporary file this node opened
                if (run.opened_stdin) |f| {
                    f.close(io);
                    run.opened_stdin = null;
                }

                const duration: u64 = @intCast(@max(0, nowMs(io) - run.started_ms));
                self.emit(.{ .node_finished = .{
                    .run_id = opts.run_id,
                    .node_id = run.plan.id,
                    .status = st,
                    .exit_code = exitCodeOf(term),
                    .duration_ms = duration,
                    .message = run.message orelse try defaultMessage(a, run, st),
                } });
            }

            trace("layer done", .{});
        }

        const ended = Io.Clock.Timestamp.now(io, .awake);
        const duration_ms: u64 = @intCast(@max(0, @divTrunc(
            ended.raw.nanoseconds - started.raw.nanoseconds,
            std.time.ns_per_ms,
        )));
        self.emit(.{ .run_finished = .{
            .run_id = opts.run_id,
            .status = overall,
            .duration_ms = duration_ms,
            .failed = failed.items,
            .skipped = skipped_list.items,
        } });

        // Reclaim every node's runtime state (`NodeRun` is heap-allocated, see a.create above)
        var rit = runs.iterator();
        while (rit.next()) |entry| {
            const r = entry.value_ptr.*;
            r.catch_out.deinit(a);
            r.catch_err.deinit(a);
            a.destroy(r);
        }
        runs.deinit(a);

        return overall;
    }

    /// Find the first direct upstream dependency (pipe or sequential) that did not
    /// succeed; return null if there is none.
    ///
    /// The check runs **after the previous layer finished**, so the upstream states in
    /// `runs` are already final.
    fn firstFailedDependency(
        self: *Engine,
        plan: *const Plan,
        runs: *const std.StringArrayHashMapUnmanaged(*NodeRun),
        node_id: []const u8,
    ) ?[]const u8 {
        _ = self;
        for (plan.nodes) |*cand| {
            const is_dep = (cand.pipe_to != null and std.mem.eql(u8, cand.pipe_to.?, node_id)) or
                (cand.seq_to != null and std.mem.eql(u8, cand.seq_to.?, node_id));
            if (!is_dep) continue;
            if (runs.get(cand.id)) |up| {
                switch (up.status) {
                    .failed, .timed_out, .cancelled => return cand.id,
                    else => {},
                }
            }
        }
        return null;
    }

    /// Spawn one node's process with stdin/stdout/stderr wired up.
    ///
    /// Pipe edges (A.stdout → B.stdin) are implemented through a **temporary file
    /// relay**, see the file header: when an upstream
    /// has `pipe_to`, its stdout is captured to a temporary file, and the downstream
    /// opens that file as stdin with `.file` (both mechanisms were verified to work
    /// empirically).
    fn spawnRun(self: *Engine, run: *NodeRun, env: *const std.process.Environ.Map) !void {
        const io = self.io;
        const pn = run.plan;

        // stdin: prefer the upstream temporary file; otherwise follow the CDL declaration
        var stdin_spec: platform.Stdio = .inherit;
        var opened_stdin: ?Io.File = null;
        if (run.feed_file_path) |path| {
            if (Io.Dir.cwd().openFile(io, path, .{})) |f| {
                opened_stdin = f;
                stdin_spec = .{ .file = f };
            } else |_| {
                // The upstream output file does not exist: hand over an empty stdin and
                // let the downstream report the error itself
                stdin_spec = .inherit;
            }
        } else if (pn.stdin_text != null or pn.stdin_file != null) {
            stdin_spec = .pipe;
        }

        const stdout_spec: platform.Stdio = if (pn.capture_stdout) .pipe else .ignore;
        const stderr_spec: platform.Stdio = if (pn.capture_stderr) .pipe else .ignore;

        const proc = try platform.spawn(self.alloc, .{
            .argv = pn.argv,
            .cwd = pn.cwd,
            .env = env,
            .stdin = stdin_spec,
            .stdout = stdout_spec,
            .stderr = stderr_spec,
        }, self.alloc);
        run.proc = proc;
        run.out_pipe = proc.stdout;
        run.opened_stdin = opened_stdin;
        run.spawned = true;
        try self.register(run);
    }
};

fn reportConcurrency(eng: *Engine, run_id: []const u8, node_id: []const u8, err: anyerror, fatal: bool) void {
    _ = run_id;
    // Note: the format string of `allocPrint` is a comptime parameter, so a runtime
    // condition cannot select it; the call has to be split into two compile-time known
    // calls.
    const msg = if (fatal)
        std.fmt.allocPrint(
            eng.alloc,
            "node {s}: could not start the output pumping task ({t}); the node was terminated to avoid a pipe deadlock",
            .{ node_id, err },
        ) catch return
    else
        std.fmt.allocPrint(
            eng.alloc,
            "node {s}: could not start the timeout watchdog ({t}); the watchdog was skipped this time",
            .{ node_id, err },
        ) catch return;
    eng.emit(.{ .log = .{ .level = if (fatal) .@"error" else .warning, .message = msg } });
}

fn joinNames(a: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, std.time.ns_per_ms));
}

fn exitCodeOf(term: ?platform.Process.Term) ?i32 {
    const t = term orelse return null;
    if (t.killed) return null;
    return @intCast(t.code);
}

fn classify(run: *NodeRun, term: ?platform.Process.Term) NodeStatus {
    if (run.timed_out.load(.monotonic)) return .timed_out;
    const t = term orelse return .failed;
    if (t.killed) return .failed;
    if (t.exited) |code| {
        if (code == 0) return .success;
        return .failed;
    }
    return .failed;
}

/// Combine two node outcomes into the outcome of the whole run.
///
/// Order of severity: `cancelled` > `timed_out` > `failed` > `skipped` > `success`.
/// The overall run status must never claim to be *less* severe than the worst node it
/// contains - that is the bug this function exists to prevent (a timed-out node was
/// previously reported as a plain `failed` run, and a skipped node as a `success` run).
fn mergeOverall(current: NodeStatus, node: NodeStatus) NodeStatus {
    return if (severity(node) > severity(current)) node else current;
}

fn severity(s: NodeStatus) u8 {
    return switch (s) {
        .pending => 0,
        .running => 0,
        .success => 0,
        .skipped => 1,
        .failed => 2,
        .timed_out => 3,
        .cancelled => 4,
    };
}

fn defaultMessage(a: std.mem.Allocator, run: *NodeRun, st: NodeStatus) !?[]const u8 {
    if (st == .success or st == .skipped or st == .cancelled) {
        if (st == .cancelled) return "cancelled by the user";
        return null;
    }
    if (st == .timed_out) {
        const ms = run.plan.timeout_ms orelse 0;
        if (ms >= 1000) {
            return try std.fmt.allocPrint(a, "execution timed out after {d} seconds, process terminated", .{ms / 1000});
        }
        return try std.fmt.allocPrint(a, "execution timed out after {d} milliseconds, process terminated", .{ms});
    }
    if (run.term) |t| {
        if (t.killed) return "process was terminated";
        return try std.fmt.allocPrint(a, "process exited with code {d}", .{t.code});
    }
    return "process could not be started";
}

// ── Synchronous draining and stdin injection ─────────────────────
//
// `io.concurrent` is not used: measured on this machine with Zig 0.17-dev + Windows,
// `Io.Future.await` blocks forever in the "read a pipe from another thread" scenario
// (the drain loop has already finished but await never returns). Here we instead block
// on the driving thread until EOF, which is deterministic and never hangs.

/// Block until EOF, forwarding the content as events.
fn drainSync(engine: *Engine, run_id: []const u8, run: *NodeRun, stream: StreamName) void {
    const io = engine.io;
    const pipe: platform.Pipe = switch (stream) {
        .stdout => run.out_pipe orelse return,
        .stderr => if (run.proc) |p| (p.stderr orelse return) else return,
    };
    const file = pipe.asFile();
    var rbuf: [32 * 1024]u8 = undefined;
    var rd = file.reader(io, &rbuf);
    const sink = switch (stream) {
        .stdout => &run.catch_out,
        .stderr => &run.catch_err,
    };
    while (true) {
        // Any read error is treated as end of stream (the child exiting early is normal)
        const n = rd.interface.readSliceShort(&rbuf) catch break;
        if (n == 0) break;
        sink.appendSlice(engine.alloc, rbuf[0..n]) catch {};
        engine.emit(.{ .node_output = .{
            .run_id = run_id,
            .node_id = run.plan.id,
            .stream = stream,
            .text = rbuf[0..n],
        } });
    }
}

const StdinSource = union(enum) {
    text: []const u8,
    file: []const u8,
};

/// Write text or file content into the child's stdin, then close the write end (EOF).
fn writeStdinSync(engine: *Engine, run: *NodeRun, source: StdinSource) void {
    const io = engine.io;
    const p = if (run.proc) |*pp| pp else return;
    const wp = if (p.stdin) |f| f else return;
    var wfd = wp.asFile();

    var wbuf: [64 * 1024]u8 = undefined;
    var wr = wfd.writer(io, &wbuf);

    switch (source) {
        .text => |t| {
            wr.interface.writeAll(t) catch {};
            wr.interface.flush() catch {};
        },
        .file => |path| {
            const f = Io.Dir.cwd().openFile(io, path, .{}) catch {
                p.closeStdin();
                return;
            };
            defer f.close(io);
            var rbuf: [64 * 1024]u8 = undefined;
            var rd = f.reader(io, &rbuf);
            var broken = false;
            while (!broken) {
                const n = rd.interface.readSliceShort(&rbuf) catch break;
                if (n == 0) break;
                broken = blk: {
                    wr.interface.writeAll(rbuf[0..n]) catch break :blk true;
                    wr.interface.flush() catch break :blk true;
                    break :blk false;
                };
            }
        },
    }

    // Close the write end: this is how the child receives EOF
    p.closeStdin();
}

/// Timeout watchdog (an ordinary thread): polls in slices so it reacts promptly to
/// "process already finished" and to cancellation.
fn watchdogThread(engine: *Engine, run: *NodeRun, timeout_ms: u64) void {
    const io = engine.io;
    const slice_ms: u64 = 50;
    var waited: u64 = 0;
    while (waited < timeout_ms) {
        if (run.finished.load(.monotonic)) return;
        if (engine.isCancelled()) return;
        const step = @min(slice_ms, timeout_ms - waited);
        Io.sleep(io, .{ .nanoseconds = @as(i96, @intCast(step)) * std.time.ns_per_ms }, .awake) catch return;
        waited += step;
    }
    if (run.finished.load(.monotonic)) return;
    run.timed_out.store(true, .monotonic);
    engine.mutex.lock(io) catch {};
    if (run.proc) |*p| p.kill();
    engine.mutex.unlock(io);
}


// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "engine/resolver: placeholder expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Resolver.init(a);
    try r.set("input", "C:/work/clip.mp4");
    try r.set("codec", "libx264");
    try r.set("opt", "true");
    try r.set("off", "false");
    r.cwd = "C:/work";

    try testing.expectEqualStrings("C:/work/clip.mp4", try r.expand("{input}"));
    try testing.expectEqualStrings("-c:v libx264", try r.expand("-c:v {codec}"));
    try testing.expectEqualStrings("C:/work", try r.expand("{input_dir}"));
    try testing.expectEqualStrings("clip.mp4", try r.expand("{input_base}"));
    try testing.expectEqualStrings("clip", try r.expand("{input_stem}"));
    try testing.expectEqualStrings("C:/work", try r.expand("{__cwd}"));
    try testing.expect(r.truthy("opt"));
    try testing.expect(!r.truthy("off"));
    try testing.expect(!r.truthy("nope"));
}

test "engine/resolver2: undefined placeholders are kept verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = Resolver.init(arena.allocator());
    try testing.expectEqualStrings("{missing}", try r.expand("{missing}"));
}

test "engine/format: formatCommand quoting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try formatCommand(a, &.{ "gcc", "-o", "my file.exe", "src.c" });
    try testing.expectEqualStrings("gcc -o \"my file.exe\" src.c", cmd);
}
