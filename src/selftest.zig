//! In-process self-test: does not depend on an external stdio driver; it walks the key paths of the RPC
//! layer and of the execution engine directly.
//!
//! Why it is needed: the verification environment of this project forbids "externally driving a child
//! process's stdio" (Node's piped spawn reports EPERM, PowerShell pipelines close stdin early), so the
//! asynchronous event stream of `--rpc-stdio` cannot be asserted reliably from the outside. The self-test
//! moves that work in-process:
//!   - it walks the RPC contract with a real `Service` + `handleRequest`;
//!   - it runs `run.start` on a real execution thread, waits for it to finish and asserts the received event sequence.
//!
//! Exit code: 0 = everything passed; 1 = something failed; 2 = could not run (no pack sources, i.e.
//! the command was not started from the repository root).

const std = @import("std");
const Io = std.Io;
const Value = @import("value.zig").Value;
const cdl = @import("cdl.zig");
const builtin = @import("builtin.zig");
const rpc = @import("rpc.zig");

var passed: usize = 0;
var failed: usize = 0;
var fail_buf: [8192]u8 = undefined;
var fail_len: usize = 0;

fn check(cond: bool, label: []const u8) void {
    if (cond) {
        passed += 1;
        return;
    }
    failed += 1;
    const msg = std.fmt.bufPrint(fail_buf[fail_len..], "  x {s}\n", .{label}) catch return;
    fail_len += msg.len;
}

/// Event collector (thread-safe across threads).
const Collector = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    methods: std.ArrayListUnmanaged([]const u8) = .empty,
    node_status: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    output: std.ArrayListUnmanaged(u8) = .empty,
    run_status: ?[]const u8 = null,
    run_done: std.atomic.Value(bool) = .init(false),
    seqs: std.ArrayListUnmanaged(u64) = .empty,
    /// Diagnostic text of non-successful nodes (printed when the self-test fails)
    diag: std.ArrayListUnmanaged([]const u8) = .empty,

    fn sendFn(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);

        // Events and responses share this one stream; only event.* is of interest here
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = Value.parseJson(a, json);
        if (parsed != .ok) return;
        const method_val = parsed.ok.field("method") orelse return;
        const method = method_val.asString() orelse return;
        if (!std.mem.startsWith(u8, method, "event.")) return;

        self.methods.append(self.gpa, self.gpa.dupe(u8, method) catch return) catch return;
        const params = parsed.ok.field("params") orelse Value.null;
        if (parsed.ok.field("seq")) |s| {
            if (s.asInt()) |n| self.seqs.append(self.gpa, @intCast(n)) catch {};
        }
        if (params.field("nodeId")) |nid| {
            if (params.field("status")) |st| {
                self.node_status.put(self.gpa, self.gpa.dupe(u8, nid.asString() orelse "?") catch return, self.gpa.dupe(u8, st.asString() orelse "?") catch return) catch {};
            }
        }
        if (params.field("text")) |t| {
            if (params.field("stream")) |s| {
                if (std.mem.eql(u8, s.asString() orelse "", "stdout")) {
                    self.output.appendSlice(self.gpa, t.asString() orelse "") catch {};
                }
            }
        }
        if (std.mem.eql(u8, method, "event.node.finished")) {
            if (params.field("status")) |st| {
                if (st.asString()) |sv| {
                    if (!std.mem.eql(u8, sv, "success")) {
                        const msg = std.fmt.allocPrint(self.gpa, "{s} -> {s}: {s}", .{
                            params.field("nodeId").?.asString() orelse "?", sv,
                            if (params.field("message")) |m| (m.asString() orelse "-") else "-",
                        }) catch "";
                        self.diag.append(self.gpa, msg) catch {};
                    }
                }
            }
        }
        if (std.mem.eql(u8, method, "event.run.finished")) {
            if (params.field("status")) |st| {
                // Free the previous value first: two runs in one process would
                // otherwise leak the first run's status string.
                if (self.run_status) |old| self.gpa.free(old);
                self.run_status = self.gpa.dupe(u8, st.asString() orelse "?") catch null;
            }
            self.run_done.store(true, .monotonic);
        }
    }

    fn countMethod(self: *Collector, name: []const u8) usize {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.methods.items) |m| {
            if (std.mem.eql(u8, m, name)) n += 1;
        }
        return n;
    }

    fn statusOf(self: *Collector, node: []const u8) ?[]const u8 {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        return self.node_status.get(node);
    }

    /// Must be cleared between two runs: otherwise the previous round's node.finished pollutes the next
    /// round's assertions (measured: a succeeding case was misjudged by leftover state from a failing case).
    fn reset(self: *Collector) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        for (self.methods.items) |m| self.gpa.free(m);
        self.methods.clearRetainingCapacity();
        var it = self.node_status.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.node_status.clearRetainingCapacity();
        self.output.clearRetainingCapacity();
        self.seqs.clearRetainingCapacity();
        for (self.diag.items) |d| self.gpa.free(d);
        self.diag.clearRetainingCapacity();
        if (self.run_status) |old| self.gpa.free(old);
        self.run_status = null;
        self.run_done.store(false, .monotonic);
    }

    /// Release everything the collector owns. Called once at the end of the
    /// self-test so the process exits without a leak report.
    fn deinit(self: *Collector) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        for (self.methods.items) |m| self.gpa.free(m);
        self.methods.deinit(self.gpa);
        var it = self.node_status.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.node_status.deinit(self.gpa);
        self.output.deinit(self.gpa);
        self.seqs.deinit(self.gpa);
        for (self.diag.items) |d| self.gpa.free(d);
        self.diag.deinit(self.gpa);
        if (self.run_status) |old| self.gpa.free(old);
        self.run_status = null;
    }
};

pub fn run(init: std.process.Init, w: *Io.Writer) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try w.writeAll("pipelith self-test\n");

    var collector: Collector = .{ .gpa = gpa, .io = io };
    var svc = rpc.Service.init(gpa, io, init.minimal.environ, .{
        .ctx = &collector,
        .send_fn = Collector.sendFn,
    });
    defer svc.deinit();

    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    svc.cwd = try a.dupe(u8, cwd_buf[0..cwd_len]);

    // ── 1. Tool packs: external files, loaded explicitly for this self-test ──
    // The program starts with an empty library and reads no tool definition from its own binary, and
    // the build puts no pack next to the executable: a pack is a directory of files on disk. What can
    // be asserted here is therefore that every pack the service offers *is* one (a real directory
    // whose manifest parsed) and that the library stays empty until a pack is installed. How many are
    // offered depends on the machine — none by default — so the count is reported, not asserted.
    svc.refreshPacks();
    for (svc.packs) |p| {
        check(p.dir != null and p.label.len > 0, "every offered pack is a directory on disk with a manifest");
    }
    check(svc.docs.count() == 0, "no tool is loaded before a pack is");
    // The repository's pack sources are what this self-test reads from; nothing is installed, so
    // running the self-test leaves a user's tool directory exactly as it was. They live in the
    // repository rather than beside an installed copy, so a run from anywhere else says that plainly
    // instead of reporting a pile of tool-dependent failures below.
    const loaded = try svc.loadPackSourcesForTests("assets/packs");
    if (loaded == 0) {
        try w.writeAll("  ! no pack sources in `assets/packs`: run --selftest from the repository root\n");
        try w.writeAll("self-test result: skipped (no tool definitions to exercise the engine with)\n");
        return 2;
    }
    check(svc.docs.count() >= 11, "at least 11 tools from the pack sources");
    try w.print("  · tool packs: {d} offered by this machine, {d} tools loaded for this test\n", .{ svc.packs.len, svc.docs.count() });

    // ── 2. RPC contract ───────────────────────────────────────────
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":1,\"method\":\"app.info\"}");
        const parsed = Value.parseJson(a, rs[0]);
        check(parsed == .ok and parsed.ok.field("result") != null, "app.info returns result");
        const count = parsed.ok.field("result").?.field("cdlCount").?.asInt().?;
        check(count >= 11, "app.info.cdlCount >= 11");
    }
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":2,\"method\":\"cdl.list\"}");
        const parsed = Value.parseJson(a, rs[0]);
        const items = parsed.ok.field("result").?.field("items").?.asArray().?;
        check(items.len >= 11, "cdl.list has at least 11 items");
        var saw_gcc = false;
        for (items) |it| {
            if (std.mem.eql(u8, it.field("name").?.asString().?, "gcc")) {
                saw_gcc = true;
                check(it.field("available") != null, "cdl.list items carry available");
            }
        }
        check(saw_gcc, "cdl.list contains gcc");
    }
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":3,\"method\":\"cdl.get\",\"params\":{\"name\":\"python\"}}");
        const parsed = Value.parseJson(a, rs[0]);
        const doc = parsed.ok.field("result").?.field("doc").?;
        try w.print("  · python: {d} actions\n", .{doc.field("actions").?.asArray().?.len});
        check(doc.field("actions").?.asArray().?.len >= 3, "python has at least 3 actions");
    }
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":4,\"method\":\"no.such.method\"}");
        const parsed = Value.parseJson(a, rs[0]);
        check(parsed.ok.field("error").?.field("code").?.asInt().? == rpc.ErrorCode.method_not_found, "unknown method -> -32601");
    }

    // ── 2b. Portable layout (nothing outside the tool directory) ──
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":5,\"method\":\"app.info\"}");
        const parsed = Value.parseJson(a, rs[0]);
        const result = parsed.ok.field("result").?;
        const tool_dir: ?[]const u8 = if (result.field("toolDir")) |v| v.asString() else null;
        const state_dir: ?[]const u8 = if (result.field("stateDir")) |v| v.asString() else null;
        check(tool_dir != null, "app.info reports toolDir");
        check(state_dir != null, "app.info reports stateDir");
        if (tool_dir != null and state_dir != null) {
            try w.print("  · tool dir:  {s}\n", .{tool_dir.?});
            try w.print("  · state dir: {s}\n", .{state_dir.?});
            // The state directory must be rooted inside the tool directory: that
            // is the whole portability guarantee, since the tool directory is the
            // directory holding the executable.
            check(std.mem.startsWith(u8, state_dir.?, tool_dir.?), "stateDir is inside toolDir");
            check(std.mem.endsWith(u8, state_dir.?, builtin.state_dir_name), "stateDir ends with .pipelith");
            // And it must not be a system temp / profile location.
            var leaked = false;
            for ([_][]const u8{ "\\Temp\\", "\\tmp\\", "AppData", "\\Roaming\\", "/tmp/" }) |forbidden| {
                if (std.mem.indexOf(u8, state_dir.?, forbidden) != null) leaked = true;
            }
            check(!leaked, "stateDir is not under a system temp or profile directory");
        }
    }

    // ── 2c. Picker: an unavailable backend must fail, never silently substitute ──
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":6,\"method\":\"fs.pick\",\"params\":{\"kind\":\"file\",\"backend\":\"none\"}}");
        const parsed = Value.parseJson(a, rs[0]);
        const err = parsed.ok.field("error");
        check(err != null, "fs.pick with the `none` backend returns an error");
        if (err) |e| {
            check(e.field("code").?.asInt().? == rpc.ErrorCode.no_picker, "unavailable picker backend -> -32004");
            const msg = e.field("message").?.asString() orelse "";
            check(std.mem.indexOf(u8, msg, "none") != null, "the error names the backend that was tried");
        }
    }
    {
        const rs = try rpc.handleRequest(&svc, a, "{\"id\":7,\"method\":\"fs.pick\",\"params\":{\"kind\":\"bogus\"}}");
        const parsed = Value.parseJson(a, rs[0]);
        check(parsed.ok.field("error").?.field("code").?.asInt().? == rpc.ErrorCode.invalid_params, "invalid kind -> -32602");
    }

    // ── 3. Real execution (RPC run.start + asynchronous events) ───
    const flow_json =
        \\{"format":"pipelith.flow","version":1,"name":"selftest","viewport":{"x":0,"y":0,"zoom":1},
        \\ "nodes":[
        \\  {"id":"emit","cdl":"python","action":"run_code","title":"produce","values":{"code":"import sys\nsys.stdout.write('alpha\\nbeta\\n')"}},
        \\  {"id":"upper","cdl":"python","action":"run_code","title":"uppercase","values":{"code":"import sys\nfor l in sys.stdin:\n    sys.stdout.write(l.strip().upper() + '\\n')"}},
        \\  {"id":"after","cdl":"python","action":"run_code","title":"finalize","values":{"code":"print('selftest-done')"}}],
        \\ "edges":[
        \\  {"id":"e1","from":"emit","fromPort":"stdout","to":"upper","toPort":"stdin","kind":"pipe"},
        \\  {"id":"e2","from":"upper","fromPort":"done","to":"after","toPort":"run","kind":"seq"}]}
    ;
    collector.reset();
    const req = try std.fmt.allocPrint(a, "{{\"id\":5,\"method\":\"run.start\",\"params\":{{\"flow\":{s}}}}}", .{flow_json});
    {
        const rs = try rpc.handleRequest(&svc, a, req);
        const parsed = Value.parseJson(a, rs[0]);
        const run_id = parsed.ok.field("result") orelse {
            check(false, "run.start returns result");
            try w.print("  ! run.start failed: {s}\n", .{rs[0]});
            return finish(w);
        };
        check(run_id.field("runId") != null, "run.start returns runId");

        // Wait for the execution thread to finish (60 seconds at most)
        const deadline = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 60 * std.time.ns_per_s;
        while (!collector.run_done.load(.monotonic)) {
            if (Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds > deadline) break;
            Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
        }
        check(collector.run_done.load(.monotonic), "event.run.finished received");
    }

    // ── 4. Assert the event contents ──────────────────────────────
    check(collector.countMethod("event.run.started") == 1, "1 run.started");
    check(collector.countMethod("event.node.started") == 3, "3 node.started");
    check(collector.countMethod("event.node.finished") == 3, "3 node.finished");
    check(collector.countMethod("event.run.finished") == 1, "1 run.finished");

    const emit_st = collector.statusOf("emit") orelse "?";
    const upper_st = collector.statusOf("upper") orelse "?";
    const after_st = collector.statusOf("after") orelse "?";
    try w.print("  · node status: emit={s} upper={s} after={s}\n", .{ emit_st, upper_st, after_st });
    check(std.mem.eql(u8, emit_st, "success"), "emit succeeded");
    check(std.mem.eql(u8, upper_st, "success"), "upper succeeded");
    check(std.mem.eql(u8, after_st, "success"), "after succeeded");

    const out = collector.output.items;
    check(std.mem.indexOf(u8, out, "ALPHA") != null, "piped data is uppercased after being relayed through a temporary file (ALPHA is visible)");
    check(std.mem.indexOf(u8, out, "selftest-done") != null, "the final node has output");
    try w.print("  · total output {d} bytes\n", .{out.len});

    // Event sequence numbers increase monotonically
    {
        var monotonic = true;
        var prev: u64 = 0;
        for (collector.seqs.items) |s| {
            if (s <= prev) monotonic = false;
            prev = s;
        }
        check(monotonic and collector.seqs.items.len > 0, "event seq increases monotonically");
    }
    check(std.mem.eql(u8, collector.run_status orelse "?", "success"), "run.finished.status = success");
    // Print diagnostics on failure (the core value of the self-test: explaining the reason for a failure clearly)
    if (collector.diag.items.len > 0) {
        try w.writeAll("  ! diagnostics for non-successful nodes:\n");
        for (collector.diag.items) |d| try w.print("      {s}\n", .{d});
    }

    // ── 5. Failure propagation ────────────────────────────────────
    collector.reset();
    {
        const bad_flow =
            \\{"format":"pipelith.flow","version":1,"name":"fail","viewport":{"x":0,"y":0,"zoom":1},
            \\ "nodes":[
            \\  {"id":"bad","cdl":"python","action":"run_code","title":"failure","values":{"code":"import sys\nsys.exit(3)"}},
            \\  {"id":"nope","cdl":"python","action":"run_code","title":"must-not-run","values":{"code":"print('SHOULD-NOT-RUN')"}}],
            \\ "edges":[{"id":"e","from":"bad","fromPort":"done","to":"nope","toPort":"run","kind":"seq"}]}
        ;
        const req2 = try std.fmt.allocPrint(a, "{{\"id\":6,\"method\":\"run.start\",\"params\":{{\"flow\":{s}}}}}", .{bad_flow});
        const rs = try rpc.handleRequest(&svc, a, req2);
        const parsed = Value.parseJson(a, rs[0]);
        check(parsed.ok.field("result") != null, "the failing case's run.start also returns a runId");

        const deadline = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 60 * std.time.ns_per_s;
        while (!collector.run_done.load(.monotonic)) {
            if (Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds > deadline) break;
            Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
        }
        check(collector.run_done.load(.monotonic), "the failing case receives run.finished");
        check(std.mem.eql(u8, collector.run_status orelse "?", "failed"), "the failing case's overall status is failed");
        const bad_st = collector.statusOf("bad") orelse "?";
        const nope_st = collector.statusOf("nope") orelse "?";
        try w.print("  · failing case: bad={s} nope={s}\n", .{ bad_st, nope_st });
        check(std.mem.eql(u8, bad_st, "failed"), "the bad node failed");
        check(std.mem.eql(u8, nope_st, "skipped"), "the seq downstream node was skipped");
        check(std.mem.indexOf(u8, collector.output.items, "SHOULD-NOT-RUN") == null, "the skipped node was not executed");
    }

    collector.deinit();
    return finish(w);
}

fn finish(w: *Io.Writer) !u8 {
    if (fail_len > 0) try w.writeAll(fail_buf[0..fail_len]);
    try w.print("\nself-test result: passed {d} / failed {d}\n", .{ passed, failed });
    try w.flush();
    return if (failed > 0) 1 else 0;
}
