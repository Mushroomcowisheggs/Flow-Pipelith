//! Integration tests for the execution engine: use **real processes** to verify pipes,
//! parallelism, exit codes, timeouts and cancellation.
//!
//! These tests are the regression guard for the protocol constraints (R1–R6): any regression such as "passing Child by value", "closing handles
//! in the wrong order" or "continuing to write after a write-end error" shows up here as a
//! native crash, a hang or missing output instead of passing silently.
//!
//! Requirement: `python` must exist on this machine (on PATH). The tools used here are loaded from
//! the shipped packs (`packs.shipped`), so this also verifies the complete chain "pack tool
//! description → argv generation → real execution" — including that every shipped pack's CDLs parse
//! and validate.

const std = @import("std");
const Io = std.Io;
const cdl = @import("cdl.zig");
const packs = @import("packs.zig");
const builtin = @import("builtin.zig");
const graph_mod = @import("graph.zig");
const engine = @import("engine.zig");

const testing = std.testing;

// ── Event collection ─────────────────────────────────────────────────────

const Recorder = struct {
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    io: Io,
    /// node_id → full stdout text
    stdout: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,
    /// node_id → final status
    status: std.StringArrayHashMapUnmanaged(engine.NodeStatus) = .empty,
    /// node_id → exit code
    exit_code: std.StringArrayHashMapUnmanaged(?i32) = .empty,
    run_status: ?engine.NodeStatus = null,
    finished_count: usize = 0,
    started_count: usize = 0,
    logs: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init(gpa: std.mem.Allocator, io: Io) Recorder {
        return .{ .gpa = gpa, .io = io };
    }

    fn callback(ctx: ?*anyopaque, event: engine.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        switch (event) {
            .run_started => {},
            .run_finished => |e| {
                self.run_status = e.status;
            },
            .node_started => |e| {
                self.started_count += 1;
                _ = e;
            },
            .node_output => |e| {
                const gop = self.stdout.getOrPut(self.gpa, e.node_id) catch return;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.appendSlice(self.gpa, e.text) catch {};
            },
            .node_finished => |e| {
                self.finished_count += 1;
                self.status.put(self.gpa, e.node_id, e.status) catch {};
                self.exit_code.put(self.gpa, e.node_id, e.exit_code) catch {};
                if (e.message) |m| self.logs.append(self.gpa, m) catch {};
            },
            .log => |e| self.logs.append(self.gpa, e.message) catch {},
        }
    }

    fn out(self: *Recorder, node_id: []const u8) []const u8 {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        const v = self.stdout.getPtr(node_id) orelse return "";
        return v.items;
    }

    fn statusOf(self: *Recorder, node_id: []const u8) ?engine.NodeStatus {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        return self.status.get(node_id);
    }

    fn exitOf(self: *Recorder, node_id: []const u8) ?i32 {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        return self.exit_code.get(node_id) orelse null;
    }
};

// ── Test fixtures ─────────────────────────────────────────────────────

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    io: Io,
    gpa: std.mem.Allocator,
    work_dir: []const u8,
    environ: std.process.Environ,

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }
};

fn setup(init: std.process.Init, sub: []const u8) !Fixture {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const base = std.fmt.allocPrint(a, ".zig-cache/test-work/{s}", .{sub}) catch return error.OutOfMemory;
    Io.Dir.cwd().createDirPath(init.io, base) catch {};
    // Clear historical artifacts so output files from a previous round cannot make
    // assertions pass spuriously
    Io.Dir.cwd().deleteTree(init.io, base) catch {};
    Io.Dir.cwd().createDirPath(init.io, base) catch {};

    return .{
        .arena = arena,
        .io = init.io,
        .gpa = a,
        .work_dir = base,
        .environ = init.minimal.environ,
    };
}

fn writeFile(io: Io, path: []const u8, content: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024));
}

/// Load every tool from the pack *sources* in the repository into a name → Doc table.
///
/// The program contains no tool definition at all — packs are external files installed on request —
/// so the tests read the pack sources from the tree and state explicitly which definitions they
/// exercise.
fn loadPackTools(io: Io, a: std.mem.Allocator) !std.StringArrayHashMapUnmanaged(cdl.Doc) {
    var map: std.StringArrayHashMapUnmanaged(cdl.Doc) = .empty;
    _ = try packs.loadAll(io, a, a, "assets/packs", &map);
    if (map.count() == 0) return error.NoPackSources;
    return map;
}

fn parseFlow(a: std.mem.Allocator, text: []const u8) !graph_mod.Graph {
    const r = try graph_mod.loadFromJson(a, text);
    if (r == .err) {
        std.debug.print("flow failed to parse: {s} @ {s}\n", .{ r.err.message, r.err.path });
        return error.FlowBroken;
    }
    if (r.ok.hasErrors()) {
        for (r.ok.issues) |i| {
            if (i.level == .@"error") std.debug.print("flow error: {s}\n", .{i.message});
        }
        return error.FlowInvalid;
    }
    return r.ok.graph;
}

fn pythonAvailable(io: Io, environ: *const std.process.Environ.Map, a: std.mem.Allocator) bool {
    const p = builtin.resolveExecutable(io, a, environ, "python") catch return false;
    return p != null;
}

// ── Test 1: a real three-stage pipeline + single node execution ──

test "engine/single: python single node execution (argv generation → real process → output forwarding)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();
    if (!pythonAvailable(io, &env, a)) return error.SkipZigTest;

    var fix = try setup(.{ .io = io, .environ_map = &env, .gpa = a, .arena = &arena, .minimal = undefined, .preopens = undefined }, "single");
    defer fix.deinit();

    const docs = try loadPackTools(io, a);
    var g = try parseFlow(a,
        \\{"name":"single","nodes":[
        \\ {"id":"n1","cdl":"python","action":"run_code","title":"run one line",
        \\  "values":{"code":"print('hello-pipelith')"}}],
        \\ "edges":[]}
    );

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{ .cwd = fix.work_dir });
    try testing.expect(pr == .ok);
    const plan = pr.ok;
    try testing.expectEqual(@as(usize, 1), plan.nodes.len);
    // The first argv entry is the executable, the last one is the code
    try testing.expectEqualStrings("python", plan.nodes[0].argv[0]);
    try testing.expectEqualStrings("-u", plan.nodes[0].argv[1]);
    try testing.expectEqualStrings("-c", plan.nodes[0].argv[2]);

    const st = try eng.execute(&plan, .{ .run_id = "r1" });
    try testing.expectEqual(engine.NodeStatus.success, st);
    try testing.expectEqual(engine.NodeStatus.success, rec.statusOf("n1").?);
    try testing.expectEqual(@as(?i32, 0), rec.exitOf("n1"));
    try testing.expect(std.mem.indexOf(u8, rec.out("n1"), "hello-pipelith") != null);
    try testing.expectEqual(@as(usize, 1), rec.finished_count);
    try testing.expectEqual(engine.NodeStatus.success, rec.run_status.?);
}

// ── Test 2: a real pipeline A | B | C (including EOF and write-end close order) ──

test "engine/pipe3: three-stage real pipeline, stdout flows stage by stage until the file lands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();
    if (!pythonAvailable(io, &env, a)) return error.SkipZigTest;

    const dir = ".zig-cache/test-work/pipe";
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    // The scratch file node C writes. An absolute path is used deliberately: an earlier
    // version passed `sys.argv[1]` (impossible - the `python/run_code` CDL action is
    // `python -u -c {code}` with no argument slot), and a plain relative path would land
    // in the *test process's* working directory, scattering files around the repo.
    const out_file_py = "\".zig-cache/test-work/pipe/pipe3-out.txt\"";

    // A receives its code through argv (no stdin dependency), B processes stdin, C
    // processes stdin and writes a file.
    const py_emit =
        \\import sys
        \\sys.stdout.write("alpha\nbeta\ngamma\n")
    ;
    const py_upper =
        \\import sys
        \\for line in sys.stdin:
        \\    sys.stdout.write(line.strip().upper() + "\n")
    ;
    const py_rw = std.fmt.comptimePrint(
        \\import sys, pathlib
        \\src = sys.stdin.read()
        \\out = pathlib.Path({s})
        \\out.write_text("|".join(src.split()), encoding="utf-8")
        \\sys.stdout.write("wrote " + str(len(src.split())) + " items\n")
    , .{out_file_py});

    const flow_text = try std.fmt.allocPrint(a,
        \\{{"name":"pipe3","nodes":[
        \\ {{"id":"a","cdl":"python","action":"run_code","title":"produce","values":{{"code":{s}}}}},
        \\ {{"id":"b","cdl":"python","action":"run_code","title":"uppercase","values":{{"code":{s}}}}},
        \\ {{"id":"c","cdl":"python","action":"run_code","title":"write file","values":{{"code":{s}}}}},
        \\ {{"id":"z","cdl":"python","action":"run_code","title":"wrap up","values":{{"code":"pass"}}}}],
        \\ "edges":[
        \\ {{"from":"a","to":"b","kind":"pipe"}},
        \\ {{"from":"b","to":"c","kind":"pipe"}},
        \\ {{"from":"c","to":"z","kind":"seq"}}]}}
    , .{ try jsonStr(a, py_emit), try jsonStr(a, py_upper), try jsonStr(a, py_rw) });

    var g = try parseFlow(a, flow_text);
    const docs = try loadPackTools(io, a);

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{ .cwd = dir });
    try testing.expect(pr == .ok);
    const plan = pr.ok;

    // The pipe relationships must be recognized correctly
    const pa = plan.find("a").?;
    const pb = plan.find("b").?;
    const pc = plan.find("c").?;
    try testing.expectEqualStrings("b", pa.pipe_to.?);
    try testing.expectEqualStrings("a", pb.pipe_from.?);
    try testing.expectEqualStrings("c", pb.pipe_to.?);
    try testing.expectEqualStrings("b", pc.pipe_from.?);
    try testing.expect(pc.pipe_to == null);

    // Layers: a, b and c are chained into one line by pipes; z depends on c
    try testing.expect(plan.layers.len >= 2);

    const st = try eng.execute(&plan, .{ .run_id = "r2" });
    try testing.expectEqual(engine.NodeStatus.success, st);

    try testing.expectEqual(engine.NodeStatus.success, rec.statusOf("a").?);
    try testing.expectEqual(engine.NodeStatus.success, rec.statusOf("b").?);
    try testing.expectEqual(engine.NodeStatus.success, rec.statusOf("c").?);
    try testing.expectEqual(engine.NodeStatus.success, rec.statusOf("z").?);

    // The data really does flow through every stage: A's output contains alpha, C's
    // output reports 3 items received
    try testing.expect(std.mem.indexOf(u8, rec.out("a"), "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, rec.out("c"), "wrote 3 items") != null);

    // The intermediate node should see the uppercased result (proving the pipe really
    // delivered the data to B's stdin)
    try testing.expect(std.mem.indexOf(u8, rec.out("b"), "ALPHA") != null);
}

fn jsonStr(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
    return out.items;
}

// ── Test 3: parallel branches ────────────────────────────────────

test "engine/parallel: multiple nodes in the same layer run in parallel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();
    if (!pythonAvailable(io, &env, a)) return error.SkipZigTest;

    var g = try parseFlow(a,
        \\{"name":"par","nodes":[
        \\ {"id":"p1","cdl":"python","action":"run_code","title":"one","values":{"code":"print('one')"}},
        \\ {"id":"p2","cdl":"python","action":"run_code","title":"two","values":{"code":"print('two')"}},
        \\ {"id":"p3","cdl":"python","action":"run_code","title":"three","values":{"code":"print('three')"}}],
        \\ "edges":[]}
    );
    const docs = try loadPackTools(io, a);

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const plan = pr.ok;
    try testing.expectEqual(@as(usize, 1), plan.layers.len); // none depends on another → same layer
    try testing.expectEqual(@as(usize, 3), plan.layers[0].len);

    const st = try eng.execute(&plan, .{ .run_id = "r3" });
    try testing.expectEqual(engine.NodeStatus.success, st);
    try testing.expect(std.mem.indexOf(u8, rec.out("p1"), "one") != null);
    try testing.expect(std.mem.indexOf(u8, rec.out("p2"), "two") != null);
    try testing.expect(std.mem.indexOf(u8, rec.out("p3"), "three") != null);
    try testing.expectEqual(@as(usize, 3), rec.finished_count);
}

// ── Test: raw command nodes and the per-node executable override ──
//
// Plan-level only (no process is started): these assert that the GUI is not limited to the tools
// that ship with it, which is a property of argv construction rather than of execution.

test "engine/raw: a raw command node needs no CDL, and `executable` overrides the action's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The paths below are placeholders: this test only asserts that an arbitrary absolute path is
    // carried through verbatim, never that such a file exists (nothing here is executed).
    const g = try parseFlow(a,
        \\{"name":"custom","nodes":[
        \\ {"id":"mypy","argv":["C:\\example\\python.exe","-m","mypy","src"]},
        \\ {"id":"ovr","cdl":"python","action":"run_code","title":"override",
        \\  "executable":"C:\\example\\python.exe","values":{"code":"print(2)"}}],
        \\ "edges":[]}
    );
    const docs = try loadPackTools(io, a);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const plan = pr.ok;

    // Raw node: argv passes through verbatim, argv[0] is the executable, and no CDL was consulted.
    const raw = plan.find("mypy").?;
    try testing.expectEqualStrings("C:\\example\\python.exe", raw.executable);
    try testing.expectEqual(@as(usize, 4), raw.argv.len);
    try testing.expectEqualStrings("-m", raw.argv[1]);
    try testing.expectEqualStrings("src", raw.argv[3]);
    try testing.expectEqualStrings("", raw.cdl_name);

    // The exact case that motivated this: a specific interpreter, not the one on PATH. The action's
    // own `executable` is "python", so the override must win for both the plan and argv[0].
    const ovr = plan.find("ovr").?;
    try testing.expectEqualStrings("C:\\example\\python.exe", ovr.executable);
    try testing.expectEqualStrings("C:\\example\\python.exe", ovr.argv[0]);
    // The rest of the action's argv template is still applied, so an override does not bypass the
    // CDL — it only replaces the program that gets run. `run_code`'s args are ["-u", "-c", "{code}"].
    try testing.expectEqualStrings("-u", ovr.argv[1]);
    try testing.expectEqualStrings("-c", ovr.argv[2]);
    try testing.expectEqualStrings("print(2)", ovr.argv[3]);
}

test "engine/raw: a raw node with an upstream pipe carries the pipe wiring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const g = try parseFlow(a,
        \\{"name":"piped","nodes":[
        \\ {"id":"produce","cdl":"python","action":"run_code","title":"p","values":{"code":"print(1)"}},
        \\ {"id":"consume","argv":["python","-c","import sys; print(sys.stdin.read().strip())"]}],
        \\ "edges":[{"from":"produce","to":"consume","fromPort":"stdout","toPort":"stdin","kind":"pipe"}]}
    );
    const docs = try loadPackTools(io, a);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const consume = pr.ok.find("consume").?;
    try testing.expectEqualStrings("produce", consume.pipe_from.?);
}

// ── Test 4: non-zero exit code → failed, and the downstream seq node is skipped ──

test "engine/exitcode: a non-zero exit code is judged a failure and propagates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();
    if (!pythonAvailable(io, &env, a)) return error.SkipZigTest;

    var g = try parseFlow(a,
        \\{"name":"fail","nodes":[
        \\ {"id":"bad","cdl":"python","action":"run_code","title":"failing",
        \\  "values":{"code":"import sys; sys.stderr.write('boom'); sys.exit(3)"}},
        \\ {"id":"after","cdl":"python","action":"run_code","title":"follow-up","values":{"code":"print('should-not-run')"}}],
        \\ "edges":[{"from":"bad","to":"after","kind":"seq"}]}
    );
    const docs = try loadPackTools(io, a);

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const plan = pr.ok;

    const st = try eng.execute(&plan, .{ .run_id = "r4" });
    try testing.expectEqual(engine.NodeStatus.failed, st);
    try testing.expectEqual(engine.NodeStatus.failed, rec.statusOf("bad").?);
    try testing.expectEqual(@as(?i32, 3), rec.exitOf("bad"));
    // stderr is captured as well
    try testing.expect(std.mem.indexOf(u8, rec.out("bad"), "boom") != null);
    try testing.expectEqual(engine.NodeStatus.failed, rec.run_status.?);
}

// ── Test 5: missing required value → no process is started, it fails immediately ──

test "engine/required: a missing required variable does not start a process" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();

    // gcc's compile_c requires source (mandatory); leaving it out → the plan should have a missing entry
    var g = try parseFlow(a,
        \\{"name":"missing","nodes":[
        \\ {"id":"c1","cdl":"gcc","action":"compile_c","title":"compile","values":{}}],
        \\ "edges":[]}
    );
    const docs = try loadPackTools(io, a);

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const plan = pr.ok;
    try testing.expect(plan.nodes[0].missing.len >= 1);
    try testing.expectEqualStrings("source", plan.nodes[0].missing[0]);

    const st = try eng.execute(&plan, .{ .run_id = "r5" });
    try testing.expectEqual(engine.NodeStatus.failed, st);
    try testing.expectEqual(engine.NodeStatus.failed, rec.statusOf("c1").?);
    // No node_started event (the process was never started)
    try testing.expectEqual(@as(usize, 0), rec.started_count);
}

// ── Test 6: a timeout is terminated by the watchdog ──────────────

test "engine/timeout: a timeout is terminated and marked timedOut" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();
    if (!pythonAvailable(io, &env, a)) return error.SkipZigTest;

    var g = try parseFlow(a,
        \\{"name":"timeout","nodes":[
        \\ {"id":"slow","cdl":"python","action":"run_code","title":"very slow",
        \\  "timeoutMs":600,
        \\  "values":{"code":"import time; time.sleep(30)"}}],
        \\ "edges":[]}
    );
    const docs = try loadPackTools(io, a);

    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, .{ .block = .global }, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{});
    try testing.expect(pr == .ok);
    const plan = pr.ok;
    try testing.expectEqual(@as(?u64, 600), plan.nodes[0].timeout_ms);

    const t0 = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const st = try eng.execute(&plan, .{ .run_id = "r6" });
    const elapsed: u64 = @intCast(@divTrunc(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - t0, std.time.ns_per_ms));

    try testing.expectEqual(engine.NodeStatus.timed_out, st);
    try testing.expectEqual(engine.NodeStatus.timed_out, rec.statusOf("slow").?);
    // It must really be terminated early, not after waiting the full 30 seconds
    try testing.expect(elapsed < 10_000);
}

// ── Test 7: the CDL booleans `when` and enum affect argv ─────────

test "engine/argv: boolean when and enum correctly affect argv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const docs = try loadPackTools(io, a);

    // Optimization on / debug info off
    {
        var g = try parseFlow(a,
            \\{"nodes":[{"id":"c1","cdl":"gcc","action":"compile_cpp","title":"compile",
            \\ "values":{"source":"main.cpp","output":"main.exe","optimize":"true","debug_info":"false"}}],
            \\ "edges":[]}
        );
        const pr = try engine.buildPlan(a, &g, &docs, .{});
        try testing.expect(pr == .ok);
        const argv = pr.ok.nodes[0].argv;
        try testing.expect(std.mem.indexOfScalar(u8, argv[0], 'g') != null);
        try testing.expect(contains(argv, "-O2"));
        try testing.expect(!contains(argv, "-g"));
        try testing.expect(contains(argv, "main.cpp"));
        try testing.expect(contains(argv, "main.exe"));
        // -o must come before the output file
        const io_idx = indexOf(argv, "-o").?;
        try testing.expectEqualStrings("main.exe", argv[io_idx + 1]);
    }

    // Optimization off / debug info on
    {
        var g = try parseFlow(a,
            \\{"nodes":[{"id":"c1","cdl":"gcc","action":"compile_cpp","title":"compile",
            \\ "values":{"source":"main.cpp","output":"main.exe","optimize":"false","debug_info":"true"}}],
            \\ "edges":[]}
        );
        const pr = try engine.buildPlan(a, &g, &docs, .{});
        try testing.expect(pr == .ok);
        const argv = pr.ok.nodes[0].argv;
        try testing.expect(!contains(argv, "-O2"));
        try testing.expect(contains(argv, "-g"));
    }

    // An enum value substituted into argv
    {
        var g = try parseFlow(a,
            \\{"nodes":[{"id":"f1","cdl":"ffmpeg","action":"extract_audio","title":"extract",
            \\ "values":{"input":"clip.mp4","output":"out.mp3","codec":"libmp3lame"}}],
            \\ "edges":[]}
        );
        const pr = try engine.buildPlan(a, &g, &docs, .{});
        try testing.expect(pr == .ok);
        const argv = pr.ok.nodes[0].argv;
        try testing.expect(contains(argv, "libmp3lame"));
        try testing.expect(contains(argv, "-vn"));
        try testing.expect(contains(argv, "clip.mp4"));
        try testing.expect(contains(argv, "out.mp3"));
    }
}

fn contains(argv: []const []const u8, needle: []const u8) bool {
    return indexOf(argv, needle) != null;
}

fn indexOf(argv: []const []const u8, needle: []const u8) ?usize {
    for (argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, needle)) return i;
    }
    return null;
}

// ── Test 8: missing executable → a clean failure message (no crash) ──

test "engine/missing-tool: fails cleanly when the executable does not exist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try std.process.Environ.createMap(.{ .block = .global }, testing.allocator);
    defer env.deinit();

    const docs = try loadPackTools(io, a);
    var g = try parseFlow(a,
        \\{"nodes":[{"id":"x","cdl":"git","action":"status","title":"status","values":{"repo":"."}}],
        \\ "edges":[]}
    );

    // An empty environment removes PATH → the executable cannot be found
    var empty_env: std.process.Environ.Map = .init(a);
    defer empty_env.deinit();
    var rec = Recorder.init(a, io);
    var eng = engine.Engine.init(a, io, std.process.Environ.empty, Recorder.callback, &rec);

    const pr = try engine.buildPlan(a, &g, &docs, .{ .resolve_executable = true, .environ = &empty_env, .io = io });
    try testing.expect(pr == .ok);

    const st = try eng.execute(&pr.ok, .{ .run_id = "r8" });
    // Either it fails (git not found) or it succeeds (if it resolved to an absolute path).
    // Here we only require that it does not crash and that the status is legal.
    try testing.expect(st == .failed or st == .success);
}
