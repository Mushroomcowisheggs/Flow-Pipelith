//! RPC service layer: implements the frontend/backend contract defined in `docs/RPC.md`.
//!
//! Transport and payload are decoupled: this module only handles "receive one JSON request -> produce some JSON messages";
//! whether that travels over stdio (headless tests) or over WebView2 postMessage / ExecuteScript is up to the caller.
//!
//! Design notes:
//!   - Every request/response/event is allocated in the **same arena** and released as a whole once a frame is handled,
//!     so callers never have to worry about the lifetime of intermediate objects;
//!   - Events are pushed through the `Sink` callback, which lets the same code serve headless mode and the GUI alike;
//!   - Runs are **asynchronous**: `run.start` returns a runId immediately, the real execution happens on a worker thread,
//!     and events are pushed from that thread to the UI (it must go through a thread-safe Sink implementation).

const std = @import("std");
const Io = std.Io;
const Value = @import("value.zig").Value;
const emit = @import("emit.zig");
const cdl = @import("cdl.zig");
const builtin = @import("builtin.zig");
const packs = @import("packs.zig");
const graph_mod = @import("graph.zig");
const engine = @import("engine.zig");
const picker = @import("picker.zig");

/// Error codes (identical to `docs/RPC.md`).
pub const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const engine_error: i32 = -32000;
    pub const not_found: i32 = -32001;
    pub const busy: i32 = -32002;
    pub const cancelled: i32 = -32003;
    /// No usable picker backend for `fs.pick` (see docs/PICKER.md 2.3).
    pub const no_picker: i32 = -32004;
};

/// Message outlet: the RPC layer hands it the JSON text destined for the frontend.
pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Send one message (complete JSON text, no trailing newline). The implementation must be thread-safe.
    send_fn: *const fn (ctx: ?*anyopaque, json: []const u8) void,

    pub fn send(self: Sink, json: []const u8) void {
        self.send_fn(self.ctx, json);
    }
};

/// Service state: CDL library, current run, event sequence number.
pub const Service = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: std.process.Environ,
    arena: std.heap.ArenaAllocator,

    /// CDL name -> document. **Empty at startup**: tools exist only after the user installs a pack
    /// (`pack.load`) or writes a CDL into the tool directory — nothing is loaded by default.
    docs: std.StringArrayHashMapUnmanaged(cdl.Doc) = .empty,
    /// CDL name -> source (user / project)
    sources: std.StringArrayHashMapUnmanaged(cdl.Source) = .empty,
    /// Available tool packs, filled by `refreshPacks` from the directories that are searched.
    packs: []const packs.Pack = &.{},
    /// Extra directories named on the command line (`--packs-dir`), highest precedence.
    packs_extra_dirs: []const []const u8 = &.{},
    /// Tool availability cache: executable -> probe result
    probes: std.StringArrayHashMapUnmanaged(builtin.Probe) = .empty,
    /// PATH directory list (split only once; `null` means not initialized yet)
    path_dirs: ?[]const []const u8 = null,

    sink: Sink,
    mutex: Io.Mutex = .init,
    event_seq: u64 = 0,
    /// Current run (only one is allowed at a time)
    current_run_id: ?[]const u8 = null,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    /// Whether a run is in progress (read across threads)
    running: std.atomic.Value(bool) = .init(false),

    cwd: []const u8 = ".",
    /// Environment snapshot as a map, built lazily on first use (needed by `fs.pick`
    /// to resolve `PIPELITH_PICKER` and to locate helper executables on PATH).
    env_map: ?std.process.Environ.Map = null,
    /// Transport identifier (`app.info.transport`). The frontend uses it to tell WebView2 from WebSocket.
    transport: ?[]const u8 = null,
    /// Run mode (`app.info.mode`), e.g. `http`. `null` means the field is not emitted.
    mode: ?[]const u8 = null,
    /// User data directory (`app.info.userDir`).
    user_dir: ?[]const u8 = null,
    /// Directory scanned for user-authored tools (`<state dir>/tools`). Null disables the feature,
    /// which is what the unit tests that do not care about it leave it as.
    tools_dir: ?[]const u8 = null,

    /// The environment map, created on first call. Returns `null` if it cannot be built.
    pub fn envMap(self: *Service) ?*const std.process.Environ.Map {
        if (self.env_map == null) {
            self.env_map = std.process.Environ.createMap(self.environ, self.gpa) catch return null;
        }
        return &self.env_map.?;
    }

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        environ: std.process.Environ,
        sink: Sink,
    ) Service {
        platformInit(io);
        return .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .sink = sink,
        };
    }

    fn platformInit(io: Io) void {
        @import("platform.zig").setDefaultIo(io);
    }

    pub fn deinit(self: *Service) void {
        // The keys of `probes` are allocated with gpa and must be freed explicitly
        for (self.probes.keys()) |k| self.gpa.free(k);
        self.probes.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        self.sources.deinit(self.gpa);
        if (self.env_map) |*m| m.deinit();
        self.arena.deinit();
    }

    /// Discover the available tool packs. Cheap, and it is the **only** thing the engine does with
    /// packs on its own: listing what could be installed. Nothing is installed or loaded by it.
    ///
    /// The search uses this service's state directory, so a `--state-dir` run lists the packs it can
    /// actually install into.
    pub fn refreshPacks(self: *Service) void {
        self.packs = packs.discover(self.io, self.arena.allocator(), self.user_dir, self.packs_extra_dirs);
    }

    /// Install one pack's tools into the CDL directory and make them live in this session.
    ///
    /// The tools become ordinary user tools: they live in `<state dir>/cdl/`, the one directory the
    /// engine loads from, so an installed tool is editable and deletable like any other. Returns null
    /// when the id is unknown or the tool directory is unavailable.
    pub fn installPack(self: *Service, a: std.mem.Allocator, id: []const u8) ?packs.Report {
        const pack = packs.find(self.packs, id) orelse return null;
        const dir = self.tools_dir orelse return null;
        const report = packs.install(self.io, a, pack, dir);
        self.loadUserTools();
        return report;
    }

    /// Load the pack *sources* from a directory into the tool table, without installing anything.
    ///
    /// This exists for the test suite and the self-test, which need real tool definitions in memory
    /// and must not write into a tool directory. The application never calls it: a user's tools come
    /// from `loadUserTools` after an explicit `pack.load`, which is the whole point of keeping the
    /// packs outside the program. Returns how many tools were loaded, so a caller can tell "the
    /// sources are not here" (0) from "they are here and valid".
    pub fn loadPackSourcesForTests(self: *Service, root: []const u8) !usize {
        const a = self.arena.allocator();
        const loaded = try packs.loadAll(self.io, a, self.gpa, root, &self.docs);
        var it = self.docs.iterator();
        while (it.next()) |e| self.sources.put(self.gpa, e.key_ptr.*, .user) catch continue;
        return loaded;
    }

    /// Loads every `*.cdl` in the user tools directory, so a tool the user wrote or the GUI saved is
    /// a first-class library entry. A user tool **shadows** a built-in of the same name: that is the
    /// point of the directory, and it is how someone replaces `python` with their own build without
    /// editing anything that ships.
    ///
    /// A broken file is skipped rather than failing startup — one bad hand-written tool must not make
    /// the whole application unusable. Failures are recorded so `cdl.list` can report them.
    pub fn loadUserTools(self: *Service) void {
        const dir_path = self.tools_dir orelse return;
        const a = self.arena.allocator();
        var dir = Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".cdl")) continue;
            const full = std.fs.path.join(a, &.{ dir_path, entry.name }) catch continue;
            const text = Io.Dir.cwd().readFileAlloc(self.io, full, a, .limited(1024 * 1024)) catch continue;
            const r = cdl.load(a, text) catch continue;
            if (r == .err or r.ok.hasErrors()) continue;
            // The doc's own `name` is the identity, so the file name does not have to match it.
            // An allocation failure skips this tool rather than aborting startup.
            self.docs.put(self.gpa, r.ok.doc.name, r.ok.doc) catch continue;
            self.sources.put(self.gpa, r.ok.doc.name, .user) catch continue;
        }
    }

    /// Path a user tool is stored at: `<tools dir>/<name>.cdl`.
    fn userToolPath(self: *Service, a: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const dir_path = self.tools_dir orelse return null;
        return std.fs.path.join(a, &.{ dir_path, name }) catch null;
    }

    fn nextSeq(self: *Service) u64 {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        self.event_seq += 1;
        return self.event_seq;
    }

    /// Push one event: `{"method":"event.<name>","params":{...}}`
    fn pushEvent(self: *Service, arena: std.mem.Allocator, name: []const u8, params: Value) void {
        const a = arena;
        const o = a.create(Value.Object) catch return;
        o.* = .{};
        const method = std.fmt.allocPrint(a, "event.{s}", .{name}) catch return;
        o.put(a, "method", .{ .string = method }) catch return;
        o.put(a, "seq", .{ .int = @intCast(self.nextSeq()) }) catch return;
        o.put(a, "params", params) catch return;

        var aw: std.Io.Writer.Allocating = .init(a);
        emit.writeValue(&aw.writer, .{ .object = o }, .{}, 0) catch return;
        self.sink.send(aw.written());
    }
};

/// Handle one request text, returning the set of responses that must be emitted (the caller sends them).
///
/// Why "return a set" instead of sending directly: headless mode writes to stdout, GUI mode uses ExecuteScript,
/// so the caller decides the outlet uniformly; it also makes test assertions easier.
pub fn handleRequest(svc: *Service, arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;

    const parsed = Value.parseJson(arena, text);
    if (parsed == .err) {
        try out.append(arena, try errorResponse(arena, .null, ErrorCode.parse_error, "request is not valid JSON"));
        return out.items;
    }

    const root = parsed.ok;
    const obj = root.asObject() orelse {
        try out.append(arena, try errorResponse(arena, .null, ErrorCode.invalid_request, "request must be a JSON object"));
        return out.items;
    };

    const id: Value = obj.get("id") orelse .null;
    const method = (obj.get("method") orelse {
        try out.append(arena, try errorResponse(arena, id, ErrorCode.invalid_request, "missing method field"));
        return out.items;
    }).asString() orelse {
        try out.append(arena, try errorResponse(arena, id, ErrorCode.invalid_request, "method must be a string"));
        return out.items;
    };

    const params: Value = obj.get("params") orelse Value.null;

    const result = dispatch(svc, arena, method, params) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => Result{ .err = .{ .code = ErrorCode.engine_error, .message = "internal error" } },
    };
    switch (result) {
        .ok => |v| try out.append(arena, try okResponse(arena, id, v)),
        .err => |e| try out.append(arena, try errorResponse(arena, id, e.code, e.message)),
    }
    return out.items;
}

const Result = union(enum) {
    ok: Value,
    err: struct { code: i32, message: []const u8 },
};

fn fail(code: i32, message: []const u8) Result {
    return .{ .err = .{ .code = code, .message = message } };
}

fn ok(v: Value) Result {
    return .{ .ok = v };
}

fn dispatch(svc: *Service, a: std.mem.Allocator, method: []const u8, params: Value) !Result {
    if (std.mem.eql(u8, method, "app.info")) return appInfo(svc, a);
    if (std.mem.eql(u8, method, "cdl.list")) return cdlList(svc, a, params);
    if (std.mem.eql(u8, method, "cdl.get")) return cdlGet(svc, a, params);
    if (std.mem.eql(u8, method, "cdl.validate")) return cdlValidate(svc, a, params);
    if (std.mem.eql(u8, method, "cdl.save")) return cdlSave(svc, a, params);
    if (std.mem.eql(u8, method, "cdl.delete")) return cdlDelete(svc, a, params);
    if (std.mem.eql(u8, method, "pack.list")) return packList(svc, a);
    if (std.mem.eql(u8, method, "pack.load")) return packLoad(svc, a, params);
    if (std.mem.eql(u8, method, "tool.probe")) return toolProbe(svc, a, params);
    // `tool.help` is deliberately absent: the GUI never probes a program to learn its interface
    // (zero guessing: nothing is probed, nothing is run implicitly).
    if (std.mem.eql(u8, method, "fs.pick")) return fsPick(svc, a, params);
    if (std.mem.eql(u8, method, "flow.build")) return flowBuild(svc, a, params);
    if (std.mem.eql(u8, method, "run.preview")) return runPreview(svc, a, params);
    if (std.mem.eql(u8, method, "run.start")) return runStart(svc, a, params);
    if (std.mem.eql(u8, method, "run.cancel")) return runCancel(svc, a);
    if (std.mem.eql(u8, method, "ping")) {
        const o = try a.create(Value.Object);
        o.* = .{};
        try o.put(a, "pong", .{ .bool = true });
        return ok(.{ .object = o });
    }
    return fail(ErrorCode.method_not_found, try std.fmt.allocPrint(a, "method not found: {s}", .{method}));
}

// ── Method implementations ───────────────────────────────────────

/// Stand-in environment for the (rare) case where the real map cannot be built.
/// An empty map means "no `PIPELITH_PICKER`, no PATH", which the picker reports
/// honestly as an unavailable backend instead of guessing.
var empty_env_storage: ?std.process.Environ.Map = null;

fn emptyEnv() *const std.process.Environ.Map {
    if (empty_env_storage == null) {
        empty_env_storage = std.process.Environ.Map.init(std.heap.page_allocator);
    }
    return &empty_env_storage.?;
}

fn appInfo(svc: *Service, a: std.mem.Allocator) !Result {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = "Flow Pipelith" });
    try o.put(a, "version", .{ .string = "0.1.0" });
    try o.put(a, "cdlVersion", .{ .string = cdl.cdl_version });
    try o.put(a, "platform", .{ .string = builtin.platformName() });
    try o.put(a, "arch", .{ .string = @tagName(@import("builtin").cpu.arch) });
    try o.put(a, "cdlCount", .{ .int = @intCast(svc.docs.count()) });
    // Packs: what *could* be installed. Emitted so a frontend can say "no tools yet, N packs
    // available" without a second call, and so a headless run can be asserted on.
    if (svc.packs.len == 0) svc.refreshPacks();
    try o.put(a, "packCount", .{ .int = @intCast(svc.packs.len) });
    try o.put(a, "workDir", .{ .string = svc.cwd });
    if (svc.transport) |t| try o.put(a, "transport", .{ .string = t });
    if (svc.mode) |m| try o.put(a, "mode", .{ .string = m });
    if (svc.user_dir) |u| try o.put(a, "userDir", .{ .string = u });
    // Portable layout: the frontend shows these so the user can see exactly where
    // the tool keeps its files, and the picker backend currently in force.
    if (try builtin.toolDir(svc.io, a)) |dir| try o.put(a, "toolDir", .{ .string = dir });
    if (try builtin.stateDir(svc.io, a)) |dir| try o.put(a, "stateDir", .{ .string = dir });
    const env = svc.envMap();
    try o.put(a, "pickerBackend", .{ .string = picker.resolveBackend(env orelse emptyEnv(), "").wire() });
    try o.put(a, "runInProgress", .{ .bool = svc.running.load(.monotonic) });
    return ok(.{ .object = o });
}

fn cdlList(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const query = if (params.field("query")) |q| (q.asString() orelse "") else "";
    const category = if (params.field("category")) |c| (c.asString() orelse "") else "";

    var items: std.ArrayListUnmanaged(Value) = .empty;
    var it = svc.docs.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr;
        if (category.len > 0 and !std.mem.eql(u8, doc.category, category)) continue;
        if (query.len > 0 and !docMatches(doc, query)) continue;
        try items.append(a, try cdlSummaryValue(svc, a, doc));
    }

    const cats = [_][]const u8{ "media", "development", "data", "network", "system", "science", "other" };
    const root = try a.create(Value.Object);
    root.* = .{};
    try root.put(a, "items", .{ .array = items.items });
    try root.put(a, "categories", try emit.Builder.init(a).strArray(&cats));
    // The unfiltered tool count, so a frontend can tell "no tools are installed yet" (an empty
    // library, which is the state of a fresh installation) apart from "this search matched nothing":
    // the two need different words and a different next step.
    try root.put(a, "total", .{ .int = @intCast(svc.docs.count()) });
    return ok(.{ .object = root });
}

/// `pack.list`: the tool packs this installation can install, with what is already installed.
///
/// A pack is *available*, never active: this call installs nothing. `installed`/`installedCount` let
/// the library show which packs the user has already taken.
fn packList(svc: *Service, a: std.mem.Allocator) !Result {
    svc.refreshPacks();
    var items: std.ArrayListUnmanaged(Value) = .empty;
    for (svc.packs) |*p| {
        const st = packs.state(svc.io, a, p, svc.tools_dir);
        const o = try a.create(Value.Object);
        o.* = .{};
        try o.put(a, "id", .{ .string = p.id });
        try o.put(a, "label", .{ .string = p.label });
        try o.put(a, "description", .{ .string = p.description });
        try o.put(a, "platforms", try emit.Builder.init(a).strArray(p.platforms));
        try o.put(a, "origin", .{ .string = p.origin });
        try o.put(a, "source", .{ .string = p.source.wire() });
        try o.put(a, "dir", if (p.dir) |d| .{ .string = d } else .null);
        try o.put(a, "toolCount", .{ .int = @intCast(p.tools.len) });
        try o.put(a, "installedCount", .{ .int = @intCast(st.installed) });
        try o.put(a, "modifiedCount", .{ .int = @intCast(st.modified) });
        try o.put(a, "installed", .{ .bool = st.complete() });
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (p.tools) |t| try names.append(a, packs.stem(t.file));
        try o.put(a, "tools", try emit.Builder.init(a).strArray(names.items));
        try items.append(a, .{ .object = o });
    }
    const root = try a.create(Value.Object);
    root.* = .{};
    try root.put(a, "packs", .{ .array = items.items });
    try root.put(a, "count", .{ .int = @intCast(svc.packs.len) });
    // Where packs are looked for, so a frontend can tell the user exactly where to put one (and can
    // show that an empty list means "no pack directory has anything", not "the feature is off").
    try root.put(a, "dirs", try emit.Builder.init(a).strArray(packs.searchPaths(
        svc.io,
        a,
        svc.user_dir,
        svc.packs_extra_dirs,
    )));
    if (svc.tools_dir) |d| try root.put(a, "cdlDir", .{ .string = d });
    return ok(.{ .object = root });
}

/// `pack.load`: install one pack's tools into the tool directory and make them live.
///
/// The tools land in the same directory a hand-written tool lives in, so they are immediately
/// editable and deletable. A file that already exists with different bytes is reported as a conflict
/// and left untouched (rule 2 — a pack never overwrites the user's own version of a tool).
fn packLoad(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const id = if (params.field("id")) |x| (x.asString() orelse "") else "";
    if (id.len == 0) return fail(ErrorCode.invalid_params, "missing id parameter");
    svc.refreshPacks();
    const report = svc.installPack(a, id) orelse {
        if (svc.tools_dir == null) return fail(ErrorCode.invalid_params, "no tool directory is configured");
        return fail(ErrorCode.not_found, try std.fmt.allocPrint(a, "unknown pack: {s}", .{id}));
    };

    const root = try a.create(Value.Object);
    root.* = .{};
    try root.put(a, "id", .{ .string = id });
    try root.put(a, "written", try stemArray(a, report.written.items));
    try root.put(a, "skipped", try stemArray(a, report.skipped.items));
    try root.put(a, "conflicts", try stemArray(a, report.conflicts.items));
    try root.put(a, "failed", try stemArray(a, report.failed.items));
    try root.put(a, "cdlCount", .{ .int = @intCast(svc.docs.count()) });
    return ok(.{ .object = root });
}

fn stemArray(a: std.mem.Allocator, files: []const []const u8) !Value {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files) |f| try names.append(a, packs.stem(f));
    return emit.Builder.init(a).strArray(names.items);
}

fn docMatches(doc: *const cdl.Doc, query: []const u8) bool {
    if (containsIgnoreCase(doc.name, query)) return true;
    if (containsIgnoreCase(doc.display_name, query)) return true;
    if (doc.description) |d| {
        if (containsIgnoreCase(d, query)) return true;
    }
    for (doc.tags) |t| {
        if (containsIgnoreCase(t, query)) return true;
    }
    for (doc.actions) |act| {
        if (containsIgnoreCase(act.label, query)) return true;
    }
    // The tool sheet is searchable too: it is the object the "look up" tax is paid against, so it
    // has to be findable by what it contains.
    for (doc.vocabulary) |entry| {
        if (vocabMatches(entry, query)) return true;
    }
    return false;
}

fn vocabMatches(entry: cdl.VocabEntry, query: []const u8) bool {
    if (containsIgnoreCase(entry.label, query)) return true;
    if (entry.description) |d| {
        if (containsIgnoreCase(d, query)) return true;
    }
    for (entry.tokens) |t| {
        if (containsIgnoreCase(t, query)) return true;
    }
    for (entry.children) |c| {
        if (vocabMatches(c, query)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn cdlSummaryValue(svc: *Service, a: std.mem.Allocator, doc: *const cdl.Doc) !Value {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = doc.name });
    try o.put(a, "displayName", .{ .string = doc.display_name });
    try o.put(a, "description", if (doc.description) |d| .{ .string = d } else .null);
    try o.put(a, "version", if (doc.version) |v| .{ .string = v } else .null);
    try o.put(a, "category", .{ .string = doc.category });
    try o.put(a, "tags", try emit.Builder.init(a).strArray(doc.tags));
    // How many pickable sheet entries the tool carries. A tool may be described by presets, a sheet,
    // or both, so a frontend needs to see which without fetching the whole document.
    try o.put(a, "vocabularyCount", .{ .int = @intCast(doc.vocabulary.len) });
    const src = svc.sources.get(doc.name) orelse .unknown;
    try o.put(a, "source", .{ .string = @tagName(src) });
    try o.put(a, "path", if (doc.path) |p| .{ .string = p } else .null);

    var acts: std.ArrayListUnmanaged(Value) = .empty;
    for (doc.actions) |act| {
        const ao = try a.create(Value.Object);
        ao.* = .{};
        try ao.put(a, "name", .{ .string = act.name });
        try ao.put(a, "label", .{ .string = act.label });
        try acts.append(a, .{ .object = ao });
    }
    try o.put(a, "actions", .{ .array = acts.items });

    // Tool availability: probe results are cached so that listing does not rescan PATH every time
    const probe = try probeOf(svc, a, doc.name);
    // The program a free command node for this tool starts with: the first action's executable
    // when it overrides one (a user tool often names its real program there), else the tool name.
    const exe_name = if (doc.actions.len > 0) doc.actions[0].exe(doc) else doc.name;
    try o.put(a, "executable", .{ .string = exe_name });
    try o.put(a, "available", .{ .bool = probe.found });
    var issues: std.ArrayListUnmanaged(Value) = .empty;
    for (doc.dependencies) |dep| {
        if (dep.optional) continue;
        const dp = try probeOf(svc, a, dep.name);
        if (!dp.found) {
            const msg = try std.fmt.allocPrint(a, "dependency tool {s} is not installed", .{dep.name});
            try issues.append(a, .{ .string = msg });
        }
    }
    if (!probe.found) {
        const msg = try std.fmt.allocPrint(a, "tool {s} is not on PATH, the node will not be able to run", .{doc.name});
        try issues.append(a, .{ .string = msg });
    }
    try o.put(a, "issues", .{ .array = issues.items });
    return .{ .object = o };
}

fn cdlGet(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const name = strParam(params, "name") orelse
        return fail(ErrorCode.invalid_params, "missing name parameter");
    const doc = svc.docs.getPtr(name) orelse
        return fail(ErrorCode.not_found, try std.fmt.allocPrint(a, "CDL not found: {s}", .{name}));

    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = doc.name });
    const src = svc.sources.get(name) orelse .unknown;
    try o.put(a, "source", .{ .string = @tagName(src) });
    try o.put(a, "path", if (doc.path) |p| .{ .string = p } else .null);
    try o.put(a, "raw", .{ .string = doc.raw });
    try o.put(a, "format", .{ .string = "json" });
    try o.put(a, "doc", try cdlDocValue(a, doc));

    var issues: std.ArrayListUnmanaged(Value) = .empty;
    const probe = try probeOf(svc, a, doc.name);
    if (!probe.found) {
        const io_ = try a.create(Value.Object);
        io_.* = .{};
        try io_.put(a, "level", .{ .string = "warning" });
        try io_.put(a, "message", .{ .string = try std.fmt.allocPrint(a, "tool {s} is not on PATH", .{doc.name}) });
        try io_.put(a, "path", .{ .string = "" });
        try issues.append(a, .{ .object = io_ });
    }
    try o.put(a, "issues", .{ .array = issues.items });
    return ok(.{ .object = o });
}

/// Normalize `cdl.Doc` into the shape of the frontend contract (camelCase, see `docs/RPC.md`).
fn cdlDocValue(a: std.mem.Allocator, doc: *const cdl.Doc) !Value {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = doc.name });
    try o.put(a, "displayName", .{ .string = doc.display_name });
    try o.put(a, "description", if (doc.description) |d| .{ .string = d } else .null);
    try o.put(a, "version", if (doc.version) |v| .{ .string = v } else .null);
    try o.put(a, "cdlVersion", .{ .string = doc.doc_cdl_version });
    try o.put(a, "icon", if (doc.icon) |i| .{ .string = i } else .null);
    try o.put(a, "category", .{ .string = doc.category });
    try o.put(a, "author", if (doc.author) |x| .{ .string = x } else .null);
    try o.put(a, "license", if (doc.license) |x| .{ .string = x } else .null);
    try o.put(a, "homepage", if (doc.homepage) |x| .{ .string = x } else .null);
    try o.put(a, "tags", try emit.Builder.init(a).strArray(doc.tags));
    try o.put(a, "platforms", try emit.Builder.init(a).strArray(doc.platforms));

    // permissions
    const perms: std.ArrayListUnmanaged(Value) = .empty;
    var pl = perms;
    if (doc.permissions.filesystem) try pl.append(a, .{ .string = "filesystem" });
    if (doc.permissions.network) try pl.append(a, .{ .string = "network" });
    if (doc.permissions.process) try pl.append(a, .{ .string = "process" });
    try o.put(a, "permissions", .{ .array = pl.items });

    // dependencies
    var deps: std.ArrayListUnmanaged(Value) = .empty;
    for (doc.dependencies) |dep| {
        const d = try a.create(Value.Object);
        d.* = .{};
        try d.put(a, "name", .{ .string = dep.name });
        try d.put(a, "version", if (dep.version) |v| .{ .string = v } else .null);
        try d.put(a, "optional", .{ .bool = dep.optional });
        try deps.append(a, .{ .object = d });
    }
    try o.put(a, "dependencies", .{ .array = deps.items });

    // pipes
    const pipes = try a.create(Value.Object);
    pipes.* = .{};
    try pipes.put(a, "stdin", .{ .string = doc.pipes.stdin.mode.wire() });
    try pipes.put(a, "stdout", .{ .string = doc.pipes.stdout.mode.wire() });
    try pipes.put(a, "stderr", .{ .string = doc.pipes.stderr.mode.wire() });
    try pipes.put(a, "encoding", .{ .string = doc.pipes.encoding });
    try o.put(a, "pipes", .{ .object = pipes });

    try o.put(a, "inputs", try varsValue(a, doc.inputs));
    try o.put(a, "outputs", try varsValue(a, doc.outputs));
    try o.put(a, "vocabulary", try vocabValue(a, doc.vocabulary));

    var acts: std.ArrayListUnmanaged(Value) = .empty;
    for (doc.actions) |*act| try acts.append(a, try actionValue(a, doc, act));
    try o.put(a, "actions", .{ .array = acts.items });
    return .{ .object = o };
}

fn varsValue(a: std.mem.Allocator, vars: []const cdl.Var) !Value {
    var list: std.ArrayListUnmanaged(Value) = .empty;
    for (vars) |v| try list.append(a, try varValue(a, v));
    return .{ .array = list.items };
}

/// The tool sheet as the frontend contract sees it (camelCase, `docs/RPC.md`): one object per
/// entry, recursively, so a picker can walk subcommands and their children without a second call.
fn vocabValue(a: std.mem.Allocator, entries: []const cdl.VocabEntry) !Value {
    var list: std.ArrayListUnmanaged(Value) = .empty;
    for (entries) |e| {
        const o = try a.create(Value.Object);
        o.* = .{};
        try o.put(a, "kind", .{ .string = e.kind.wire() });
        try o.put(a, "tokens", try emit.Builder.init(a).strArray(e.tokens));
        try o.put(a, "label", .{ .string = e.label });
        try o.put(a, "description", if (e.description) |d| .{ .string = d } else .null);
        try o.put(a, "takes", if (e.takes) |t| .{ .string = t.wire() } else .null);
        try o.put(a, "options", try emit.Builder.init(a).strArray(e.options));
        try o.put(a, "children", try vocabValue(a, e.children));
        try list.append(a, .{ .object = o });
    }
    return .{ .array = list.items };
}

fn varValue(a: std.mem.Allocator, v: cdl.Var) !Value {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = v.name });
    try o.put(a, "type", .{ .string = v.var_type.wire() });
    try o.put(a, "label", .{ .string = v.label });
    try o.put(a, "required", .{ .bool = v.required });
    try o.put(a, "default", if (v.default) |d| .{ .string = d } else .null);
    try o.put(a, "filters", try emit.Builder.init(a).strArray(v.filters));
    try o.put(a, "placeholder", if (v.placeholder) |p| .{ .string = p } else .null);
    try o.put(a, "multiline", .{ .bool = v.multiline });
    try o.put(a, "min", if (v.min) |x| .{ .float = x } else .null);
    try o.put(a, "max", if (v.max) |x| .{ .float = x } else .null);
    try o.put(a, "step", if (v.step) |x| .{ .float = x } else .null);
    try o.put(a, "save", .{ .bool = v.save });
    try o.put(a, "description", if (v.description) |d| .{ .string = d } else .null);

    if (v.options.len > 0) {
        var opts: std.ArrayListUnmanaged(Value) = .empty;
        for (v.options) |opt| {
            const oo = try a.create(Value.Object);
            oo.* = .{};
            try oo.put(a, "value", .{ .string = opt.value });
            try oo.put(a, "label", .{ .string = opt.label });
            try opts.append(a, .{ .object = oo });
        }
        try o.put(a, "options", .{ .array = opts.items });
    } else {
        try o.put(a, "options", .null);
    }

    if (v.validation) |val| {
        const vo = try a.create(Value.Object);
        vo.* = .{};
        try vo.put(a, "min", if (val.min) |x| .{ .float = x } else .null);
        try vo.put(a, "max", if (val.max) |x| .{ .float = x } else .null);
        try vo.put(a, "pattern", if (val.pattern) |p| .{ .string = p } else .null);
        try vo.put(a, "message", if (val.message) |m| .{ .string = m } else .null);
        try o.put(a, "validation", .{ .object = vo });
    } else {
        try o.put(a, "validation", .null);
    }
    return .{ .object = o };
}

fn actionValue(a: std.mem.Allocator, doc: *const cdl.Doc, act: *const cdl.Action) !Value {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = act.name });
    try o.put(a, "label", .{ .string = act.label });
    try o.put(a, "description", if (act.description) |d| .{ .string = d } else .null);
    try o.put(a, "icon", if (act.icon) |i| .{ .string = i } else .null);
    try o.put(a, "executable", .{ .string = act.exe(doc) });

    var args: std.ArrayListUnmanaged(Value) = .empty;
    for (act.args) |arg| {
        const ao = try a.create(Value.Object);
        ao.* = .{};
        try ao.put(a, "value", .{ .string = arg.value });
        try ao.put(a, "var", if (arg.var_name) |x| .{ .string = x } else .null);
        try ao.put(a, "when", if (arg.when) |x| .{ .string = x } else .null);
        try ao.put(a, "repeat", if (arg.repeat) |x| .{ .string = x } else .null);
        try ao.put(a, "prefix", if (arg.prefix) |x| .{ .string = x } else .null);
        try args.append(a, .{ .object = ao });
    }
    try o.put(a, "args", .{ .array = args.items });
    try o.put(a, "variables", try varsValue(a, act.variables));
    try o.put(a, "cwd", if (act.cwd) |c| .{ .string = c } else .null);

    const env = try a.create(Value.Object);
    env.* = .{};
    for (act.env) |pair| try env.put(a, pair.key, .{ .string = pair.value });
    try o.put(a, "env", .{ .object = env });

    try o.put(a, "stdin", .{ .string = act.stdin.mode.wire() });
    try o.put(a, "stdout", .{ .string = act.stdout.mode.wire() });
    try o.put(a, "stderr", .{ .string = act.stderr.mode.wire() });
    try o.put(a, "encoding", if (act.encoding) |e| .{ .string = e } else .null);
    try o.put(a, "timeout", if (act.timeout) |t| .{ .int = @intCast(t) } else .null);
    try o.put(a, "retry", .{ .int = @intCast(act.retry) });
    try o.put(a, "confirm", .{ .bool = act.confirm });
    try o.put(a, "danger", .{ .bool = act.danger });
    return .{ .object = o };
}

/// Read a string parameter; returns null when it is missing or not a string.
///
/// Why not `(v orelse .null).asString()`: Zig's type inference fails for `orelse` plus an
/// enum literal (it reports "incompatible types: *const Value and *const @EnumLiteral()"),
/// so an explicit `if` unwrap is the most reliable.
fn strParam(params: Value, key: []const u8) ?[]const u8 {
    const v = params.field(key) orelse return null;
    return v.asString();
}

fn cdlValidate(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    _ = svc;
    const raw = strParam(params, "raw") orelse
        return fail(ErrorCode.invalid_params, "missing raw parameter");

    const r = try cdl.load(a, raw);
    const o = try a.create(Value.Object);
    o.* = .{};
    var issues: std.ArrayListUnmanaged(Value) = .empty;

    switch (r) {
        .err => |e| {
            try o.put(a, "ok", .{ .bool = false });
            try o.put(a, "doc", .null);
            const io_ = try a.create(Value.Object);
            io_.* = .{};
            try io_.put(a, "level", .{ .string = "error" });
            try io_.put(a, "message", .{ .string = e.message });
            try io_.put(a, "path", .{ .string = e.path });
            try issues.append(a, .{ .object = io_ });
        },
        .ok => |loaded| {
            try o.put(a, "ok", .{ .bool = !loaded.hasErrors() });
            // `Value.null` must be written instead of `.null`: otherwise Zig infers the if result
            // as the union's tag type, which produces an "incompatible types" error.
            const doc_val: Value = if (loaded.hasErrors()) Value.null else try cdlDocValue(a, &loaded.doc);
            try o.put(a, "doc", doc_val);
            for (loaded.issues) |i| {
                const io_ = try a.create(Value.Object);
                io_.* = .{};
                try io_.put(a, "level", .{ .string = @tagName(i.level) });
                try io_.put(a, "message", .{ .string = i.message });
                try io_.put(a, "path", .{ .string = i.path });
                try issues.append(a, .{ .object = io_ });
            }
        },
    }

    try o.put(a, "issues", .{ .array = issues.items });
    return ok(.{ .object = o });
}

/// `cdl.save`: validate a tool definition, then write it into the user tools directory and make it
/// live. Validation happens **before** anything touches the disk, so a broken tool can never be
/// saved and then quietly skipped on the next start.
fn cdlSave(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const raw = strParam(params, "raw") orelse
        return fail(ErrorCode.invalid_params, "missing raw parameter");

    // Validation comes first, before the directory is even considered: a malformed document is the
    // more actionable complaint, and it guarantees nothing reaches the disk for an invalid tool.
    const loaded = try cdl.load(a, raw);
    switch (loaded) {
        .err => |e| return fail(ErrorCode.invalid_params, e.message),
        .ok => |l| {
            for (l.issues) |i| {
                if (i.level == .@"error") return fail(ErrorCode.invalid_params, i.message);
            }
            const name = l.doc.name;
            if (name.len == 0) return fail(ErrorCode.invalid_params, "missing required field name");
            // The name becomes a file name, so keep the directory flat and traversal impossible.
            for (name) |c| {
                const allowed = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
                if (!allowed) return fail(
                    ErrorCode.invalid_params,
                    "a tool name may only contain letters, digits, '-', '_' and '.'",
                );
            }
            const dir_path = svc.tools_dir orelse
                return fail(ErrorCode.engine_error, "no user tools directory is configured");
            Io.Dir.cwd().createDirPath(svc.io, dir_path) catch
                return fail(ErrorCode.engine_error, "cannot create the user tools directory");
            const file_name = try std.fmt.allocPrint(a, "{s}.cdl", .{name});
            const full = svc.userToolPath(a, file_name) orelse
                return fail(ErrorCode.engine_error, "cannot build the tool path");
            const f = Io.Dir.cwd().createFile(svc.io, full, .{}) catch
                return fail(ErrorCode.engine_error, "cannot write the tool file");
            defer f.close(svc.io);
            var buf: [8192]u8 = undefined;
            var fw = f.writer(svc.io, &buf);
            fw.interface.writeAll(raw) catch
                return fail(ErrorCode.engine_error, "cannot write the tool file");
            fw.interface.flush() catch
                return fail(ErrorCode.engine_error, "cannot write the tool file");

            // Live immediately: the caller does not have to restart or reload.
            try svc.docs.put(svc.gpa, l.doc.name, l.doc);
            try svc.sources.put(svc.gpa, l.doc.name, .user);

            const o = try a.create(Value.Object);
            o.* = .{};
            try o.put(a, "name", .{ .string = name });
            try o.put(a, "path", .{ .string = full });
            return ok(.{ .object = o });
        },
    }
}

/// `cdl.delete`: remove a **user** tool. A built-in cannot be deleted, only shadowed by a user tool
/// of the same name — deleting something that ships with the program would be invisible and could
/// not be undone.
fn cdlDelete(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const name = strParam(params, "name") orelse
        return fail(ErrorCode.invalid_params, "missing name parameter");
    const src = svc.sources.get(name) orelse
        return fail(ErrorCode.not_found, try std.fmt.allocPrint(a, "CDL not found: {s}", .{name}));
    if (src != .user) return fail(ErrorCode.invalid_params, "only a user tool can be deleted");

    const file_name = try std.fmt.allocPrint(a, "{s}.cdl", .{name});
    const full = svc.userToolPath(a, file_name) orelse
        return fail(ErrorCode.engine_error, "cannot build the tool path");
    Io.Dir.cwd().deleteFile(svc.io, full) catch
        return fail(ErrorCode.engine_error, "cannot delete the tool file");
    _ = svc.docs.swapRemove(name);
    _ = svc.sources.swapRemove(name);

    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "name", .{ .string = name });
    return ok(.{ .object = o });
}

fn toolProbe(svc: *Service, a: std.mem.Allocator, params: Value) !Result {    const exe = strParam(params, "executable") orelse
        return fail(ErrorCode.invalid_params, "missing executable parameter");
    const probe = try probeOf(svc, a, exe);
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "found", .{ .bool = probe.found });
    try o.put(a, "path", if (probe.path) |p| .{ .string = p } else .null);
    try o.put(a, "versionLine", if (probe.version_line) |v| .{ .string = v } else .null);
    return ok(.{ .object = o });
}

/// `fs.pick`: ask the operating system for a path.
///
/// Product rules this implements (docs/PICKER.md):
///   * the path is returned **verbatim** - no quoting, no trimming, no separator rewriting;
///   * the backend is resolved explicitly (request -> `PIPELITH_PICKER` -> platform default) and
///     reported back in the result, so the caller always knows what answered;
///   * when the resolved backend is missing the call **fails** with `no_picker` naming it. It never
///     quietly switches to a different mechanism.
///
/// Cancelling is a normal outcome (`cancelled: true`), not an error.
fn fsPick(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    // `kind` is the name the frontend uses; `mode` is accepted as an alias.
    const kind_text = strParam(params, "kind") orelse strParam(params, "mode") orelse "file";
    const mode = picker.Mode.parse(kind_text) orelse
        return fail(ErrorCode.invalid_params, try std.fmt.allocPrint(
            a,
            "invalid kind `{s}`: expected `file` or `folder`",
            .{kind_text},
        ));

    const requested = strParam(params, "backend") orelse "";
    const env = svc.envMap() orelse emptyEnv();
    const backend = picker.resolveBackend(env, requested);

    const start_dir = strParam(params, "startDir") orelse "";
    const filter = strParam(params, "filter") orelse "";

    const res = picker.pick(svc.io, a, env, backend, mode, start_dir, filter) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unavailable => return fail(ErrorCode.no_picker, try std.fmt.allocPrint(
            a,
            "picker backend `{s}` is not available on this system; set PIPELITH_PICKER to choose another one, or type the path directly",
            .{backend.wire()},
        )),
    };

    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "path", if (res.path) |p| .{ .string = p } else .null);
    try o.put(a, "cancelled", .{ .bool = res.cancelled });
    try o.put(a, "backend", .{ .string = res.backend });
    try o.put(a, "kind", .{ .string = mode.wire() });
    return ok(.{ .object = o });
}

fn flowBuild(svc: *Service, a: std.mem.Allocator, params: Value) !Result {    const flow = params.field("flow") orelse
        return fail(ErrorCode.invalid_params, "missing flow parameter");

    const loaded = try graph_mod.loadFromValue(a, flow);
    if (loaded == .err) {
        return fail(ErrorCode.engine_error, try std.fmt.allocPrint(a, "failed to parse the flow: {s}", .{loaded.err.message}));
    }
    var g = loaded.ok.graph;

    var env_for_build = try envMapOf(svc, a);
    const plan_res = try engine.buildPlan(a, &g, &svc.docs, .{
        .cwd = svc.cwd,
        .environ = &env_for_build,
        .io = svc.io,
    });

    const o = try a.create(Value.Object);
    o.* = .{};

    var issues: std.ArrayListUnmanaged(Value) = .empty;
    for (loaded.ok.issues) |i| {
        const io_ = try a.create(Value.Object);
        io_.* = .{};
        try io_.put(a, "level", .{ .string = @tagName(i.level) });
        try io_.put(a, "message", .{ .string = i.message });
        try io_.put(a, "nodeId", if (i.node_id) |n| .{ .string = n } else .null);
        try issues.append(a, .{ .object = io_ });
    }

    switch (plan_res) {
        .err => |e| {
            try o.put(a, "ok", .{ .bool = false });
            try o.put(a, "order", .{ .array = &.{} });
            try o.put(a, "layers", .{ .array = &.{} });
            try o.put(a, "plan", .{ .array = &.{} });
            const io_ = try a.create(Value.Object);
            io_.* = .{};
            try io_.put(a, "level", .{ .string = "error" });
            try io_.put(a, "message", .{ .string = e.message });
            try io_.put(a, "nodeId", if (e.node_id) |n| .{ .string = n } else .null);
            try issues.append(a, .{ .object = io_ });
        },
        .ok => |plan| {
            var has_error = false;
            var plan_items: std.ArrayListUnmanaged(Value) = .empty;
            for (plan.nodes) |*pn| {
                const po = try a.create(Value.Object);
                po.* = .{};
                try po.put(a, "id", .{ .string = pn.id });
                try po.put(a, "cdl", .{ .string = pn.cdl_name });
                try po.put(a, "action", .{ .string = pn.action });
                try po.put(a, "title", .{ .string = pn.title });
                try po.put(a, "executable", .{ .string = pn.executable });
                try po.put(a, "argv", try emit.Builder.init(a).strArray(pn.argv));
                try po.put(a, "cwd", if (pn.cwd) |c| .{ .string = c } else .null);
                try po.put(a, "stdin", .{ .string = if (pn.pipe_from != null) "pipe" else if (pn.stdin_text != null) "text" else "none" });
                try po.put(a, "stdout", .{ .string = if (pn.capture_stdout) "capture" else "discard" });
                try po.put(a, "stderr", .{ .string = if (pn.capture_stderr) "capture" else "discard" });
                try po.put(a, "pipedFrom", if (pn.pipe_from) |x| .{ .string = x } else .null);
                try po.put(a, "seqAfter", if (pn.seq_to) |x| .{ .string = x } else .null);
                try po.put(a, "missing", try emit.Builder.init(a).strArray(pn.missing));
                try plan_items.append(a, .{ .object = po });

                if (pn.missing.len > 0) {
                    has_error = true;
                    const io_ = try a.create(Value.Object);
                    io_.* = .{};
                    try io_.put(a, "level", .{ .string = "error" });
                    try io_.put(a, "message", .{ .string = try std.fmt.allocPrint(
                        a,
                        "node \"{s}\" is missing required fields: {s}",
                        .{ pn.title, try joinMissing(a, pn.missing) },
                    ) });
                    try io_.put(a, "nodeId", .{ .string = pn.id });
                    try issues.append(a, .{ .object = io_ });
                }
            }
            for (issues.items) |iv| {
                if (std.mem.eql(u8, iv.field("level").?.asString().?, "error")) has_error = true;
            }

            var layers: std.ArrayListUnmanaged(Value) = .empty;
            for (plan.layers) |layer| {
                try layers.append(a, try emit.Builder.init(a).strArray(layer));
            }

            try o.put(a, "ok", .{ .bool = !has_error });
            try o.put(a, "order", try emit.Builder.init(a).strArray(plan.order));
            try o.put(a, "layers", .{ .array = layers.items });
            try o.put(a, "plan", .{ .array = plan_items.items });
        },
    }

    try o.put(a, "issues", .{ .array = issues.items });
    return ok(.{ .object = o });
}

fn joinMissing(a: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

fn runPreview(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    const built = try flowBuild(svc, a, params);
    switch (built) {
        .err => |e| return fail(e.code, e.message),
        .ok => |v| {
            const o = try a.create(Value.Object);
            o.* = .{};
            var cmds: std.ArrayListUnmanaged(Value) = .empty;
            var affected: std.ArrayListUnmanaged(Value) = .empty;
            if (v.field("plan")) |plan_val| {
                if (plan_val.asArray()) |items| {
                    for (items) |item| {
                        const id = item.field("id").?.asString().?;
                        const argv_val = item.field("argv").?;
                        const argv = argv_val.asArray().?;
                        var strs = try a.alloc([]const u8, argv.len);
                        for (argv, 0..) |x, i| strs[i] = x.asString().?;
                        const display = try engine.formatCommand(a, strs);

                        const co = try a.create(Value.Object);
                        co.* = .{};
                        try co.put(a, "id", .{ .string = id });
                        try co.put(a, "display", .{ .string = display });
                        try co.put(a, "argv", argv_val);
                        try cmds.append(a, .{ .object = co });

                        // Treat output-like arguments as "paths that will be affected"
                        if (item.field("cwd")) |_| {}
                        for (strs) |s| {
                            if (s.len > 0 and s[0] != '-' and
                                (std.mem.endsWith(u8, s, ".exe") or std.mem.endsWith(u8, s, ".o") or
                                    std.mem.endsWith(u8, s, ".mp4") or std.mem.endsWith(u8, s, ".txt") or
                                    std.mem.endsWith(u8, s, ".zip") or std.mem.endsWith(u8, s, ".out")))
                            {
                                try affected.append(a, .{ .string = s });
                            }
                        }
                    }
                }
            }
            try o.put(a, "commands", .{ .array = cmds.items });
            try o.put(a, "affectedPaths", .{ .array = affected.items });
            try o.put(a, "missingTools", .{ .array = &.{} });
            return ok(.{ .object = o });
        },
    }
}

fn runStart(svc: *Service, a: std.mem.Allocator, params: Value) !Result {
    if (svc.running.load(.monotonic)) {
        return fail(ErrorCode.busy, "a run is already in progress");
    }

    const flow = params.field("flow") orelse
        return fail(ErrorCode.invalid_params, "missing flow parameter");

    // ⚠ Lifetime: the request arena is released as a whole once the request has been handled,
    // but the worker thread is still using the plan. Therefore **all data** needed by the execution
    // must be allocated in the "run-time arena" (owned by RunContext), otherwise the worker thread
    // reads freed memory (observed in practice as a segfault).
    const ctx = try svc.gpa.create(RunContext);
    ctx.* = .{
        .svc = svc,
        .plan = undefined,
        .run_id = "run-1",
        .done = std.atomic.Value(bool).init(false),
        .arena = std.heap.ArenaAllocator.init(svc.gpa),
    };
    const ra = ctx.arena.allocator();

    const loaded = try graph_mod.loadFromValue(ra, flow);
    if (loaded == .err) {
        ctx.arena.deinit();
        svc.gpa.destroy(ctx);
        return fail(ErrorCode.engine_error, try std.fmt.allocPrint(a, "failed to parse the flow: {s}", .{loaded.err.message}));
    }
    if (loaded.ok.hasErrors()) {
        var first_msg: []const u8 = "flow validation failed";
        for (loaded.ok.issues) |i| {
            if (i.level == .@"error") {
                first_msg = i.message;
                break;
            }
        }
        ctx.arena.deinit();
        svc.gpa.destroy(ctx);
        return fail(ErrorCode.engine_error, try std.fmt.allocPrint(a, "{s}", .{first_msg}));
    }
    var g = loaded.ok.graph;

    var env_map = try envMapOf(svc, ra);
    const plan_res = try engine.buildPlan(ra, &g, &svc.docs, .{
        .cwd = svc.cwd,
        .environ = &env_map,
        .io = svc.io,
    });
    switch (plan_res) {
        .err => |e| {
            const msg = try std.fmt.allocPrint(a, "{s}", .{e.message});
            ctx.arena.deinit();
            svc.gpa.destroy(ctx);
            return fail(ErrorCode.engine_error, msg);
        },
        .ok => |plan| {
            ctx.plan = plan;
            ctx.run_id = try ra.dupe(u8, "run-1");
            svc.running.store(true, .monotonic);
            svc.cancel_flag.store(false, .monotonic);
            svc.current_run_id = ctx.run_id;

            const t = std.Thread.spawn(.{}, runWorker, .{ctx}) catch {
                svc.running.store(false, .monotonic);
                ctx.arena.deinit();
                svc.gpa.destroy(ctx);
                return fail(ErrorCode.engine_error, "cannot start the execution thread");
            };
            t.detach();

            const o = try a.create(Value.Object);
            o.* = .{};
            try o.put(a, "runId", .{ .string = ctx.run_id });
            return ok(.{ .object = o });
        },
    }
}

const RunContext = struct {
    svc: *Service,
    plan: engine.Plan,
    run_id: []const u8,
    done: std.atomic.Value(bool),
    /// Execution-time arena: owns the plan, the graph and the environment copy; released as a whole when the run ends.
    arena: std.heap.ArenaAllocator,
};

/// Execution thread: runs the whole workflow; events are pushed out through the sink.
fn runWorker(ctx: *RunContext) void {
    const svc = ctx.svc;

    // The engine must allocate from the **run's** arena, not from the process
    // allocator. `execute` frees each `NodeRun` itself, but it also allocates
    // per-run scratch that is never individually freed (the `running` registry,
    // the batch lists, the pipe spill path). With the general allocator those
    // showed up as a leak report after every run; tied to the arena, which is
    // released as a whole a few lines below, they cost nothing to clean up.
    var eng = engine.Engine.init(
        ctx.arena.allocator(),
        svc.io,
        svc.environ,
        eventCallback,
        svc,
    );
    _ = eng.execute(&ctx.plan, .{ .run_id = ctx.run_id }) catch {};

    svc.mutex.lock(svc.io) catch {};
    svc.running.store(false, .monotonic);
    svc.current_run_id = null;
    svc.mutex.unlock(svc.io);

    ctx.done.store(true, .monotonic);
    ctx.arena.deinit();
    svc.gpa.destroy(ctx);
}

/// Engine events -> RPC event pushes.
fn eventCallback(ctx: ?*anyopaque, event: engine.Event) void {
    const svc: *Service = @ptrCast(@alignCast(ctx.?));
    // Each event gets its own arena: events are use-and-discard, and they may come from the execution thread
    var arena = std.heap.ArenaAllocator.init(svc.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    switch (event) {
        .run_started => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "runId", .{ .string = e.run_id }) catch return;
            p.put(a, "nodeIds", emit.Builder.init(a).strArray(e.node_ids) catch return) catch return;
            p.put(a, "startedAt", .{ .int = @intCast(@divTrunc(Io.Clock.Timestamp.now(svc.io, .awake).raw.nanoseconds, std.time.ns_per_ms)) }) catch return;
            svc.pushEvent(a, "run.started", .{ .object = p });
        },
        .node_started => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "runId", .{ .string = e.run_id }) catch return;
            p.put(a, "nodeId", .{ .string = e.node_id }) catch return;
            p.put(a, "argv", emit.Builder.init(a).strArray(e.argv) catch return) catch return;
            svc.pushEvent(a, "node.started", .{ .object = p });
        },
        .node_output => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "runId", .{ .string = e.run_id }) catch return;
            p.put(a, "nodeId", .{ .string = e.node_id }) catch return;
            p.put(a, "stream", .{ .string = e.stream.wire() }) catch return;
            p.put(a, "text", .{ .string = e.text }) catch return;
            svc.pushEvent(a, "node.output", .{ .object = p });
        },
        .node_finished => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "runId", .{ .string = e.run_id }) catch return;
            p.put(a, "nodeId", .{ .string = e.node_id }) catch return;
            p.put(a, "status", .{ .string = e.status.wire() }) catch return;
            p.put(a, "exitCode", if (e.exit_code) |c| .{ .int = c } else .null) catch return;
            p.put(a, "durationMs", .{ .int = @intCast(e.duration_ms) }) catch return;
            p.put(a, "message", if (e.message) |m| .{ .string = m } else .null) catch return;
            svc.pushEvent(a, "node.finished", .{ .object = p });
        },
        .run_finished => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "runId", .{ .string = e.run_id }) catch return;
            p.put(a, "status", .{ .string = e.status.wire() }) catch return;
            p.put(a, "durationMs", .{ .int = @intCast(e.duration_ms) }) catch return;
            p.put(a, "failed", emit.Builder.init(a).strArray(e.failed) catch return) catch return;
            p.put(a, "skipped", emit.Builder.init(a).strArray(e.skipped) catch return) catch return;
            svc.pushEvent(a, "run.finished", .{ .object = p });
        },
        .log => |e| {
            const p = a.create(Value.Object) catch return;
            p.* = .{};
            p.put(a, "level", .{ .string = @tagName(e.level) }) catch return;
            p.put(a, "message", .{ .string = e.message }) catch return;
            svc.pushEvent(a, "log", .{ .object = p });
        },
    }
}

fn runCancel(svc: *Service, a: std.mem.Allocator) !Result {
    svc.cancel_flag.store(true, .monotonic);
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "cancelled", .{ .bool = svc.running.load(.monotonic) });
    return ok(.{ .object = o });
}

// ── Helpers ──────────────────────────────────────────────────────

/// Build a mutable copy of the current process environment (used when changes are needed; the caller uses it inside the request arena).
fn envMapOf(svc: *Service, a: std.mem.Allocator) !std.process.Environ.Map {
    return std.process.Environ.createMap(svc.environ, a);
}

/// Tool probing (cached, so that listing does not rescan PATH every time).
///
/// Key point: **the PATH directory list is split only once and cached in `Service.arena`**,
/// so afterwards each probe only allocates one path on a hit. Otherwise a single `cdl.list` would
/// cause thousands of allocations (measured: 8504 leaked places), which is both slow and dirty.
fn probeOf(svc: *Service, a: std.mem.Allocator, exe: []const u8) !builtin.Probe {
    _ = a;
    if (svc.probes.get(exe)) |cached| return cached;

    if (svc.path_dirs == null) {
        var em = try std.process.Environ.createMap(svc.environ, svc.arena.allocator());
        svc.path_dirs = try builtin.pathEntries(svc.arena.allocator(), &em);
    }

    const resolved = try builtin.resolveInDirs(svc.io, svc.arena.allocator(), svc.path_dirs.?, exe);
    // Watch out for allocator consistency: the `probes` table and its keys must both use `gpa`
    // (`deinit` frees with `gpa`); only caches such as `path_dirs` go into the arena.
    const key = try svc.gpa.dupe(u8, exe);
    const stable: builtin.Probe = .{ .found = resolved != null, .path = resolved };
    try svc.probes.put(svc.gpa, key, stable);
    return stable;
}

// ── Response encoding ────────────────────────────────────────────

fn okResponse(a: std.mem.Allocator, id: Value, result: Value) ![]const u8 {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "id", id);
    try o.put(a, "result", result);
    return try serialize(a, .{ .object = o });
}

fn errorResponse(a: std.mem.Allocator, id: Value, code: i32, message: []const u8) ![]const u8 {
    const o = try a.create(Value.Object);
    o.* = .{};
    try o.put(a, "id", id);
    const eo = try a.create(Value.Object);
    eo.* = .{};
    try eo.put(a, "code", .{ .int = code });
    try eo.put(a, "message", .{ .string = message });
    try o.put(a, "error", .{ .object = eo });
    return try serialize(a, .{ .object = o });
}

pub fn serialize(a: std.mem.Allocator, v: Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try emit.writeValue(&aw.writer, v, .{}, 0);
    return aw.written();
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn testService(a: std.mem.Allocator, io: Io) !Service {
    _ = a;
    var svc = Service.init(testing.allocator, io, .{ .block = .global }, .{
        .ctx = null,
        .send_fn = struct {
            fn f(_: ?*anyopaque, _: []const u8) void {}
        }.f,
    });
    _ = try svc.loadPackSourcesForTests("assets/packs");
    return svc;
}

test "rpc/cdl.list: returns every shipped tool with the correct shape" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const responses = try handleRequest(&svc, a, "{\"id\":1,\"method\":\"cdl.list\",\"params\":{}}");
    try testing.expectEqual(@as(usize, 1), responses.len);

    const parsed = Value.parseJson(a, responses[0]);
    try testing.expect(parsed == .ok);
    const result = parsed.ok.field("result").?;
    const items = result.field("items").?.asArray().?;
    try testing.expect(items.len >= 10);
    // `total` is the unfiltered count: with an empty query it equals the number of items, which is
    // what lets a frontend tell "no tools installed" apart from "nothing matched".
    try testing.expectEqual(@as(i64, @intCast(items.len)), result.field("total").?.asInt().?);

    // Must contain at least gcc and ffmpeg, with all fields present. A tool is described by presets,
    // a tool sheet, or both — a sheet-only tool is a first-class entry, not a missing one.
    var found_gcc = false;
    var sheet_tools: usize = 0;
    for (items) |item| {
        const name = item.field("name").?.asString().?;
        try testing.expect(item.field("displayName") != null);
        try testing.expect(item.field("available") != null);
        try testing.expect(item.field("actions").?.asArray() != null);
        const sheet = item.field("vocabularyCount").?.asInt().?;
        if (sheet > 0) sheet_tools += 1;
        if (std.mem.eql(u8, name, "gcc")) found_gcc = true;
    }
    try testing.expect(found_gcc);
    try testing.expect(sheet_tools > 0);
}

test "rpc/cdl.get: returns the normalized document and action variables" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const responses = try handleRequest(&svc, a, "{\"id\":2,\"method\":\"cdl.get\",\"params\":{\"name\":\"gcc\"}}");
    const parsed = Value.parseJson(a, responses[0]);
    const result = parsed.ok.field("result").?;
    try testing.expectEqualStrings("gcc", result.field("name").?.asString().?);
    const doc = result.field("doc").?;
    try testing.expectEqualStrings("GCC", doc.field("displayName").?.asString().?);
    const actions = doc.field("actions").?.asArray().?;
    try testing.expect(actions.len >= 3);
    // The variables of compile_cpp must carry type/label/required
    const act0 = actions[0];
    const vars = act0.field("variables").?.asArray().?;
    try testing.expect(vars.len >= 1);
    try testing.expectEqualStrings("file", vars[0].field("type").?.asString().?);
}

test "rpc/cdlDocValue: exposes the tool sheet (vocabulary) for pick-and-assemble" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"name":"git","display_name":"Git","vocabulary":[
        \\  {"kind":"subcommand","tokens":["clone"],"label":"Clone","children":[
        \\    {"kind":"option","tokens":["--depth","<n>"],"takes":"number"}]},
        \\  {"kind":"option","tokens":["-C","DIRECTORY"],"takes":"directory"},
        \\  {"kind":"note","label":"Reminder","description":"output goes last"}]}
    ;
    const loaded = try cdl.load(a, src);
    try testing.expect(loaded == .ok);
    const v = try cdlDocValue(a, &loaded.ok.doc);
    const vocab = v.field("vocabulary").?.asArray().?;
    try testing.expectEqual(@as(usize, 3), vocab.len);

    try testing.expectEqualStrings("subcommand", vocab[0].field("kind").?.asString().?);
    const toks = vocab[0].field("tokens").?.asArray().?;
    try testing.expectEqualStrings("clone", toks[0].asString().?);
    const children = vocab[0].field("children").?.asArray().?;
    try testing.expectEqualStrings("number", children[0].field("takes").?.asString().?);

    try testing.expectEqualStrings("directory", vocab[1].field("takes").?.asString().?);
    try testing.expectEqualStrings("note", vocab[2].field("kind").?.asString().?);
    try testing.expect(vocab[2].field("takes").? == .null);
}

test "rpc: error codes for an unknown method and an unknown CDL" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const rs = try handleRequest(&svc, a, "{\"id\":1,\"method\":\"nope\"}");
        const parsed = Value.parseJson(a, rs[0]);
        try testing.expectEqual(@as(i64, ErrorCode.method_not_found), parsed.ok.field("error").?.field("code").?.asInt().?);
    }
    {
        const rs = try handleRequest(&svc, a, "{\"id\":2,\"method\":\"cdl.get\",\"params\":{\"name\":\"nope\"}}");
        const parsed = Value.parseJson(a, rs[0]);
        try testing.expectEqual(@as(i64, ErrorCode.not_found), parsed.ok.field("error").?.field("code").?.asInt().?);
    }
    {
        const rs = try handleRequest(&svc, a, "not json at all");
        const parsed = Value.parseJson(a, rs[0]);
        try testing.expectEqual(@as(i64, ErrorCode.parse_error), parsed.ok.field("error").?.field("code").?.asInt().?);
    }
}

test "rpc/cdl.save: an invalid tool is refused on its own merits, with no directory involved" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No `tools_dir` is configured (the tests leave it null so they never touch the real state
    // directory), which makes the two failure modes distinguishable:
    var valid = Value.Object{};
    try valid.put(a, "raw", .{ .string = "{\"name\":\"t\",\"display_name\":\"T\",\"actions\":[{\"name\":\"run\",\"label\":\"R\",\"args\":[]}]}" });
    const ok_res = try cdlSave(&svc, a, .{ .object = &valid });
    try testing.expect(ok_res == .err);
    // A well-formed tool gets past validation and reports the missing configuration...
    try testing.expectEqual(ErrorCode.engine_error, ok_res.err.code);

    var bad = Value.Object{};
    try bad.put(a, "raw", .{ .string = "{}" });
    const bad_res = try cdlSave(&svc, a, .{ .object = &bad });
    try testing.expect(bad_res == .err);
    // ...while a malformed one is rejected as invalid input, which is the proof that validation runs
    // first and that nothing can be written for a document that does not parse.
    try testing.expectEqual(ErrorCode.invalid_params, bad_res.err.code);
}

test "rpc/cdl.delete: refuses a tool that is not the user's own, and reports an unknown one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A project-local document is not the user's own file, so it cannot be deleted from here (there
    // is no built-in source any more: a shipped tool becomes the user's file when it is installed).
    svc.sources.put(svc.gpa, "gcc", .project) catch return error.OutOfMemory;
    var project_params = Value.Object{};
    try project_params.put(a, "name", .{ .string = "gcc" });
    const res = try cdlDelete(&svc, a, .{ .object = &project_params });
    try testing.expect(res == .err);
    try testing.expectEqual(ErrorCode.invalid_params, res.err.code);
    // The refused delete must not have removed anything.
    try testing.expect(svc.docs.get("gcc") != null);

    var missing_params = Value.Object{};
    try missing_params.put(a, "name", .{ .string = "does-not-exist" });
    const missing = try cdlDelete(&svc, a, .{ .object = &missing_params });
    try testing.expect(missing == .err);
    try testing.expectEqual(ErrorCode.not_found, missing.err.code);
}

test "rpc/flow.build: produces argv and layers, reports error when required fields are missing" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req =
        \\{"id":1,"method":"flow.build","params":{"flow":{"nodes":[
        \\ {"id":"c1","cdl":"gcc","action":"compile_cpp","title":"compile",
        \\  "values":{"source":"main.cpp","output":"main.exe","optimize":"true","debug_info":"false"}}],
        \\ "edges":[]}}}
    ;
    const rs = try handleRequest(&svc, a, req);
    const parsed = Value.parseJson(a, rs[0]);
    const result = parsed.ok.field("result").?;
    try testing.expect(result.field("ok").?.asBool().?);
    const plan = result.field("plan").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), plan.len);
    const argv = plan[0].field("argv").?.asArray().?;
    var saw_O2 = false;
    var saw_source = false;
    for (argv) |x| {
        const s = x.asString().?;
        if (std.mem.eql(u8, s, "-O2")) saw_O2 = true;
        if (std.mem.eql(u8, s, "main.cpp")) saw_source = true;
    }
    try testing.expect(saw_O2 and saw_source);

    // Missing required fields
    const req2 =
        \\{"id":2,"method":"flow.build","params":{"flow":{"nodes":[
        \\ {"id":"c1","cdl":"gcc","action":"compile_c","title":"compile","values":{}}],
        \\ "edges":[]}}}
    ;
    const rs2 = try handleRequest(&svc, a, req2);
    const parsed2 = Value.parseJson(a, rs2[0]);
    const result2 = parsed2.ok.field("result").?;
    try testing.expect(!result2.field("ok").?.asBool().?);
    try testing.expect(result2.field("plan").?.asArray().?[0].field("missing").?.asArray().?.len >= 1);
}

test "rpc/run.preview: returns a readable command line" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var svc = try testService(testing.allocator, io);
    defer svc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req =
        \\{"id":1,"method":"run.preview","params":{"flow":{"nodes":[
        \\ {"id":"c1","cdl":"gcc","action":"compile_c","title":"compile",
        \\  "values":{"source":"hello.c","output":"hello.exe"}}],
        \\ "edges":[]}}}
    ;
    const rs = try handleRequest(&svc, a, req);
    const parsed = Value.parseJson(a, rs[0]);
    const cmds = parsed.ok.field("result").?.field("commands").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), cmds.len);
    const display = cmds[0].field("display").?.asString().?;
    try testing.expect(std.mem.indexOf(u8, display, "hello.c") != null);
    try testing.expect(std.mem.indexOf(u8, display, "hello.exe") != null);
}
