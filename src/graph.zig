//! Workflow graph model: nodes, edges, topological sort, cycle detection, parallel layering.
//!
//! A workflow (`.flow` file) represents "one canvas". This module is responsible only for
//! **the graph structure itself**: parsing, validation, sorting, layering, and queries such as
//! "which upstream nodes does a given node depend on"; argv generation and process execution
//! belong to `engine.zig`.
//!
//! Edge semantics (v0.1):
//!   - `pipe`: A.stdout -> B.stdin, the engine sets up a real pipe between the two processes
//!   - `seq` : B starts only after A finished successfully (A.done -> B.run)
//!   - `data` / `cond`: v0.4, the fields are already reserved at this layer, a warning is emitted but they are treated as seq

const std = @import("std");
const Value = @import("value.zig").Value;
const cdl = @import("cdl.zig");

pub const EdgeKind = enum {
    pipe,
    seq,
    data,
    cond,

    pub fn parse(s: []const u8) ?EdgeKind {
        if (std.mem.eql(u8, s, "pipe")) return .pipe;
        if (std.mem.eql(u8, s, "seq")) return .seq;
        if (std.mem.eql(u8, s, "data")) return .data;
        if (std.mem.eql(u8, s, "cond")) return .cond;
        return null;
    }

    pub fn wire(self: EdgeKind) []const u8 {
        return switch (self) {
            .pipe => "pipe",
            .seq => "seq",
            .data => "data",
            .cond => "cond",
        };
    }
};

/// Name a graph gets when the document does not carry one. Exported so the frontends can tell
/// "the file had no name" apart from "the user named the workflow this", since both load to the
/// same value.
pub const default_name = "Untitled workflow";

pub const Node = struct {
    id: []const u8,
    cdl_name: []const u8,
    action: []const u8,
    title: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 260,
    height: f64 = 180,
    /// variable name -> value (everything is stored as a string, the frontend interprets it by type)
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    disabled: bool = false,
    timeout_ms: ?u64 = null,
    retry: u32 = 0,
    note: []const u8 = "",
    /// Overrides the action's own `executable`. Empty means "use the CDL's". This is what lets a
    /// node use a specific build of a tool (`<another install>\python.exe`) instead of whichever one
    /// happens to be first on PATH.
    executable: []const u8 = "",
    /// A free-form command: `argv[0]` is the executable and the rest are the arguments, verbatim.
    /// When non-empty the node is a *raw command* — it needs no CDL and no action, which is the
    /// escape hatch that stops the tool library from being the limit on what can be run.
    argv: []const []const u8 = &.{},

    pub fn value(self: *const Node, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

pub const Edge = struct {
    id: []const u8,
    from: []const u8,
    from_port: []const u8 = "stdout",
    to: []const u8,
    to_port: []const u8 = "stdin",
    kind: EdgeKind = .pipe,
};

pub const Issue = struct {
    level: cdl.Level,
    message: []const u8,
    node_id: ?[]const u8 = null,
    edge_id: ?[]const u8 = null,
};

pub const Graph = struct {
    alloc: std.mem.Allocator,
    name: []const u8 = default_name,
    viewport_x: f64 = 0,
    viewport_y: f64 = 0,
    viewport_zoom: f64 = 1,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,

    pub fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc };
    }

    pub fn findNode(self: *Graph, id: []const u8) ?*Node {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    pub fn findNodeConst(self: *const Graph, id: []const u8) ?*const Node {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    /// Pipe upstream pointing at `id` (at most one; with several upstreams the first is taken and a
    /// diagnostic is emitted).
    pub fn pipeUpstream(self: *const Graph, id: []const u8) ?*const Edge {
        for (self.edges.items) |*e| {
            if (e.kind == .pipe and std.mem.eql(u8, e.to, id)) return e;
        }
        return null;
    }

    pub fn seqUpstreams(self: *const Graph, alloc: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.edges.items) |e| {
            if (e.kind == .seq and std.mem.eql(u8, e.to, id)) try list.append(alloc, e.from);
        }
        return list.items;
    }

    pub fn seqDownstreams(self: *const Graph, alloc: std.mem.Allocator, id: []const u8) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.edges.items) |e| {
            if (e.kind == .seq and std.mem.eql(u8, e.from, id)) try list.append(alloc, e.to);
        }
        return list.items;
    }

    /// Active nodes (not disabled).
    pub fn activeNodes(self: *const Graph, alloc: std.mem.Allocator) ![]const *Node {
        var list: std.ArrayListUnmanaged(*Node) = .empty;
        for (self.nodes.items) |*n| {
            if (!n.disabled) try list.append(alloc, n);
        }
        return list.items;
    }
};

// ── Parsing ──────────────────────────────────────────────────────

pub const LoadError = struct {
    message: []const u8,
    line: usize = 0,
    path: []const u8 = "",
};

pub const LoadResult = union(enum) {
    ok: Loaded,
    err: LoadError,
};

pub const Loaded = struct {
    graph: Graph,
    issues: []const Issue,

    pub fn hasErrors(self: Loaded) bool {
        for (self.issues) |i| {
            if (i.level == .@"error") return true;
        }
        return false;
    }
};

/// Parse a `.flow` from JSON text (`.flow` is JSON; see docs/RPC.md).
pub fn loadFromJson(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}!LoadResult {
    const parsed: Value = switch (Value.parseJson(alloc, text)) {
        .ok => |v| v,
        .err => |e| return .{ .err = .{ .message = e.message, .line = e.line, .path = e.path } },
    };
    return loadFromValue(alloc, parsed);
}

pub fn loadFromValue(alloc: std.mem.Allocator, root: Value) error{OutOfMemory}!LoadResult {
    const obj = root.asObject() orelse return .{ .err = .{ .message = "the top level of a .flow must be a JSON object", .path = "$" } };

    var g = Graph.init(alloc);
    var issues: std.ArrayListUnmanaged(Issue) = .empty;

    if (obj.get("format")) |f| {
        if (f.asString()) |s| {
            if (!std.mem.eql(u8, s, "pipelith.flow")) {
                try issues.append(alloc, .{
                    .level = .warning,
                    .message = try std.fmt.allocPrint(alloc, "unknown file format marker `{s}` (expected pipelith.flow)", .{s}),
                });
            }
        }
    }
    if (try strField(alloc, obj, "name")) |n| g.name = n;

    if (obj.get("viewport")) |vp| {
        if (vp.asObject()) |vo| {
            if (vo.get("x")) |x| g.viewport_x = x.asFloat() orelse 0;
            if (vo.get("y")) |y| g.viewport_y = y.asFloat() orelse 0;
            if (vo.get("zoom")) |z| {
                const zf = z.asFloat() orelse 1;
                g.viewport_zoom = if (zf <= 0.01) 1 else zf;
            }
        }
    }

    // nodes
    if (obj.get("nodes")) |nv| {
        const arr = nv.asArray() orelse &.{};
        for (arr, 0..) |item, i| {
            const path = try std.fmt.allocPrint(alloc, "nodes[{d}]", .{i});
            const no = item.asObject() orelse {
                try issues.append(alloc, .{ .level = .@"error", .message = "a node must be an object", .node_id = null });
                continue;
            };
            const id = (try strField(alloc, no, "id")) orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "{s} is missing id", .{path}),
                });
                continue;
            };
            if (g.findNodeConst(id) != null) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "duplicate node id `{s}`", .{id}),
                    .node_id = id,
                });
                continue;
            }
            var node: Node = .{
                .id = id,
                .cdl_name = (try strField(alloc, no, "cdl")) orelse "",
                .action = (try strField(alloc, no, "action")) orelse "",
                .title = (try strField(alloc, no, "title")) orelse "",
            };
            // A raw command carries its own argv and therefore needs neither a CDL nor an action;
            // requiring them would defeat the point of having an escape hatch.
            if (no.get("argv")) |av| {
                if (av.asArray()) |al| {
                    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (al) |p| {
                        const s = (try p.asStringCoerce(alloc)) orelse continue;
                        try parts.append(alloc, s);
                    }
                    if (parts.items.len > 0) node.argv = parts.items;
                }
            }
            const is_raw = node.argv.len > 0;
            if (!is_raw and node.cdl_name.len == 0) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "node is missing the cdl field",
                    .node_id = id,
                });
            }
            if (!is_raw and node.action.len == 0) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "node is missing the action field",
                    .node_id = id,
                });
            }
            if (node.title.len == 0) node.title = if (is_raw) node.argv[0] else node.action;
            if (try strField(alloc, no, "executable")) |ex| node.executable = ex;

            if (no.get("x")) |x| node.x = x.asFloat() orelse 0;
            if (no.get("y")) |y| node.y = y.asFloat() orelse 0;
            if (no.get("width")) |ww| {
                if (ww.asFloat()) |v| node.width = v;
            }
            if (no.get("height")) |hh| {
                if (hh.asFloat()) |v| node.height = v;
            }
            if (no.get("disabled")) |d| node.disabled = d.asBool() orelse false;
            if (no.get("timeoutMs")) |t| {
                if (t.asInt()) |v| {
                    if (v > 0) node.timeout_ms = @intCast(v);
                }
            }
            if (no.get("retry")) |r| {
                if (r.asInt()) |v| {
                    if (v > 0) node.retry = @intCast(v);
                }
            }
            if (try strField(alloc, no, "note")) |nt| node.note = nt;

            if (no.get("values")) |vv| {
                if (vv.asObject()) |vo| {
                    for (0..vo.count()) |k| {
                        const e = vo.at(k);
                        const s = try e.value.asStringCoerce(alloc) orelse "";
                        // Both the key and the value are copied: the Value tree lives in the
                        // caller's arena, which for an RPC call is released as soon as the request
                        // is handled, while this graph is read later on the execution thread.
                        try node.values.put(alloc, try alloc.dupe(u8, e.key), try alloc.dupe(u8, s));
                    }
                } else {
                    try issues.append(alloc, .{
                        .level = .warning,
                        .message = "values must be an object",
                        .node_id = id,
                    });
                }
            }

            try g.nodes.append(alloc, node);
        }
    }

    // edges
    if (obj.get("edges")) |ev| {
        const arr = ev.asArray() orelse &.{};
        for (arr, 0..) |item, i| {
            const path = try std.fmt.allocPrint(alloc, "edges[{d}]", .{i});
            const eo = item.asObject() orelse {
                try issues.append(alloc, .{ .level = .@"error", .message = "an edge must be an object" });
                continue;
            };
            const from = (try strField(alloc, eo, "from")) orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "{s} is missing from", .{path}),
                });
                continue;
            };
            const to = (try strField(alloc, eo, "to")) orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "{s} is missing to", .{path}),
                });
                continue;
            };
            const kind_str = (try strField(alloc, eo, "kind")) orelse "pipe";
            const kind = EdgeKind.parse(kind_str) orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "unknown edge kind `{s}` (available: pipe/seq/data/cond)", .{kind_str}),
                });
                continue;
            };
            const id = (try strField(alloc, eo, "id")) orelse try std.fmt.allocPrint(alloc, "e{d}", .{i});
            try g.edges.append(alloc, .{
                .id = id,
                .from = from,
                .from_port = (try strField(alloc, eo, "fromPort")) orelse defaultFromPort(kind),
                .to = to,
                .to_port = (try strField(alloc, eo, "toPort")) orelse defaultToPort(kind),
                .kind = kind,
            });
        }
    }

    try validate(alloc, &g, &issues);
    return .{ .ok = .{ .graph = g, .issues = issues.items } };
}

fn defaultFromPort(kind: EdgeKind) []const u8 {
    return switch (kind) {
        .pipe => "stdout",
        .seq, .cond => "done",
        .data => "var",
    };
}

fn defaultToPort(kind: EdgeKind) []const u8 {
    return switch (kind) {
        .pipe => "stdin",
        .seq, .cond => "run",
        .data => "var",
    };
}

/// Reads a string field and COPIES it into `alloc`.
///
/// The copy is load-bearing, not defensive: `loadFromValue` is called with a request arena (see
/// `rpc.runStart`) that is released as soon as the RPC call returns, while the parsed graph — and
/// the run plan built from it — is still read by the execution thread afterwards. Returning the
/// slice into the Value tree made run events report garbage node ids (`"UU"` instead of `"n1"`)
/// once the request arena had been reused.
fn strField(alloc: std.mem.Allocator, o: *Value.Object, key: []const u8) error{OutOfMemory}!?[]const u8 {
    const v = o.get(key) orelse return null;
    const s = (try v.asStringCoerce(alloc)) orelse return null;
    return try alloc.dupe(u8, s);
}

// ── Validation ───────────────────────────────────────────────────

fn validate(alloc: std.mem.Allocator, g: *Graph, issues: *std.ArrayListUnmanaged(Issue)) error{OutOfMemory}!void {
    // edge endpoint existence
    for (g.edges.items) |e| {
        if (g.findNodeConst(e.from) == null) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "edge points at a non-existent node `{s}`", .{e.from}),
                .edge_id = e.id,
            });
        }
        if (g.findNodeConst(e.to) == null) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "edge points at a non-existent node `{s}`", .{e.to}),
                .edge_id = e.id,
            });
        }
        if (std.mem.eql(u8, e.from, e.to)) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = "a node cannot connect to itself",
                .edge_id = e.id,
            });
        }
        if (e.kind == .data or e.kind == .cond) {
            try issues.append(alloc, .{
                .level = .warning,
                .message = try std.fmt.allocPrint(
                    alloc,
                    "edge kind `{s}` is not implemented yet (planned for v0.4), it is currently handled as a sequential edge",
                    .{e.kind.wire()},
                ),
                .edge_id = e.id,
            });
        }
    }

    // a node's stdin can be fed by only one pipe
    for (g.nodes.items) |n| {
        var count: usize = 0;
        for (g.edges.items) |e| {
            if (e.kind == .pipe and std.mem.eql(u8, e.to, n.id)) count += 1;
        }
        if (count > 1) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(
                    alloc,
                    "node \"{s}\" has {d} pipes connected to its stdin (only one is allowed)",
                    .{ n.title, count },
                ),
                .node_id = n.id,
            });
        }
    }

    // cycle detection (only edges involved in execution are considered: pipe and seq)
    if (try findCycle(alloc, g)) |cycle| {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(alloc, "the workflow contains a cycle: {s}", .{cycle}),
            .node_id = null,
        });
    }
}

/// Return a textual representation of the cycle (`a → b → a`), or null when there is none.
pub fn findCycle(alloc: std.mem.Allocator, g: *const Graph) error{OutOfMemory}!?[]const u8 {
    const n = g.nodes.items.len;
    if (n == 0) return null;

    const Color = enum { white, gray, black };
    const colors = try alloc.alloc(Color, n);
    defer alloc.free(colors);
    @memset(colors, .white);

    const parent = try alloc.alloc(?usize, n);
    defer alloc.free(parent);
    @memset(parent, null);

    var stack: std.ArrayListUnmanaged(usize) = .empty;
    defer stack.deinit(alloc);

    for (0..n) |start| {
        if (colors[start] != .white) continue;
        try stack.append(alloc, start);
        while (stack.items.len > 0) {
            const cur = stack.items[stack.items.len - 1];
            if (colors[cur] == .white) colors[cur] = .gray;

            var advanced = false;
            for (g.edges.items) |e| {
                if (e.kind == .data) continue; // data edges do not take part in execution order
                if (!std.mem.eql(u8, e.from, g.nodes.items[cur].id)) continue;
                const next = indexOfNode(g, e.to) orelse continue;
                switch (colors[next]) {
                    .white => {
                        parent[next] = cur;
                        try stack.append(alloc, next);
                        advanced = true;
                    },
                    .gray => {
                        // cycle found: walk parent pointers back from cur to next, then append the start once more to close the loop
                        var path: std.ArrayListUnmanaged([]const u8) = .empty;
                        var walk: ?usize = cur;
                        var guard: usize = 0;
                        while (walk) |w| {
                            try path.append(alloc, g.nodes.items[w].id);
                            if (w == next) break;
                            walk = parent[w];
                            guard += 1;
                            if (guard > n + 1) break;
                        }
                        std.mem.reverse([]const u8, path.items);
                        if (path.items.len > 0) try path.append(alloc, path.items[0]);
                        var out: std.ArrayListUnmanaged(u8) = .empty;
                        for (path.items, 0..) |id, i| {
                            if (i > 0) try out.appendSlice(alloc, " → ");
                            try out.appendSlice(alloc, id);
                        }
                        return out.items;
                    },
                    .black => {},
                }
                if (advanced) break;
            }
            if (!advanced) {
                colors[cur] = .black;
                _ = stack.pop();
            }
        }
    }
    return null;
}

fn indexOfNode(g: *const Graph, id: []const u8) ?usize {
    for (g.nodes.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return i;
    }
    return null;
}

// ── Topological sort and layering ────────────────────────────────

pub const Schedule = struct {
    /// topological order (enabled nodes only)
    order: []const []const u8,
    /// parallel layering: nodes in the same layer do not depend on each other and can start together
    layers: []const []const []const u8,
};

/// Compute the execution order and the parallel layering. If the graph has a cycle, returns `error.Cycle`.
pub fn schedule(alloc: std.mem.Allocator, g: *const Graph) !Schedule {
    var indeg: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (g.nodes.items) |n| {
        if (n.disabled) continue;
        try indeg.put(alloc, n.id, 0);
    }
    for (g.edges.items) |e| {
        if (e.kind == .data) continue;
        if (!indeg.contains(e.to) or !indeg.contains(e.from)) continue;
        indeg.putAssumeCapacity(e.to, indeg.get(e.to).? + 1);
    }

    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    var layers: std.ArrayListUnmanaged([]const []const u8) = .empty;

    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    // iterate in the original node order so the result is stable and reproducible
    for (g.nodes.items) |n| {
        if (n.disabled) continue;
        if (indeg.get(n.id).? == 0) try frontier.append(alloc, n.id);
    }

    var settled: usize = 0;
    while (frontier.items.len > 0) {
        const layer = try alloc.dupe([]const u8, frontier.items);
        try layers.append(alloc, layer);
        try order.appendSlice(alloc, layer);
        settled += layer.len;

        var next: std.ArrayListUnmanaged([]const u8) = .empty;
        for (layer) |id| {
            for (g.edges.items) |e| {
                if (e.kind == .data) continue;
                if (!std.mem.eql(u8, e.from, id)) continue;
                const d = indeg.getPtr(e.to) orelse continue;
                if (d.* == 0) continue;
                d.* -= 1;
                if (d.* == 0) try next.append(alloc, e.to);
            }
        }
        frontier = next;
    }

    if (settled != indeg.count()) return error.Cycle;

    return .{ .order = order.items, .layers = layers.items };
}

// ── Serialization ────────────────────────────────────────────────

/// Write the graph back to `.flow` JSON (value model), for `flow.save` and event pushes.
pub fn toValue(alloc: std.mem.Allocator, g: *const Graph) !Value {
    const root = try alloc.create(Value.Object);
    root.* = .{};
    try root.put(alloc, "format", .{ .string = "pipelith.flow" });
    try root.put(alloc, "version", .{ .int = 1 });
    try root.put(alloc, "name", .{ .string = g.name });

    const vp = try alloc.create(Value.Object);
    vp.* = .{};
    try vp.put(alloc, "x", .{ .float = g.viewport_x });
    try vp.put(alloc, "y", .{ .float = g.viewport_y });
    try vp.put(alloc, "zoom", .{ .float = g.viewport_zoom });
    try root.put(alloc, "viewport", .{ .object = vp });

    const nodes = try alloc.alloc(Value, g.nodes.items.len);
    for (g.nodes.items, 0..) |n, i| {
        const no = try alloc.create(Value.Object);
        no.* = .{};
        try no.put(alloc, "id", .{ .string = n.id });
        try no.put(alloc, "cdl", .{ .string = n.cdl_name });
        try no.put(alloc, "action", .{ .string = n.action });
        try no.put(alloc, "title", .{ .string = n.title });
        try no.put(alloc, "x", .{ .float = n.x });
        try no.put(alloc, "y", .{ .float = n.y });
        try no.put(alloc, "width", .{ .float = n.width });
        try no.put(alloc, "height", .{ .float = n.height });

        const vals = try alloc.create(Value.Object);
        vals.* = .{};
        for (n.values.keys(), n.values.values()) |k, v| {
            try vals.put(alloc, k, .{ .string = v });
        }
        try no.put(alloc, "values", .{ .object = vals });

        try no.put(alloc, "disabled", .{ .bool = n.disabled });
        try no.put(alloc, "timeoutMs", if (n.timeout_ms) |t| .{ .int = @intCast(t) } else .null);
        try no.put(alloc, "retry", .{ .int = @intCast(n.retry) });
        try no.put(alloc, "note", .{ .string = n.note });
        // Only emitted when set, so an ordinary CDL node's document is unchanged by these fields.
        if (n.executable.len > 0) try no.put(alloc, "executable", .{ .string = n.executable });
        if (n.argv.len > 0) {
            const parts = try alloc.alloc(Value, n.argv.len);
            for (n.argv, 0..) |p, k| parts[k] = .{ .string = p };
            try no.put(alloc, "argv", .{ .array = parts });
        }
        nodes[i] = .{ .object = no };
    }
    try root.put(alloc, "nodes", .{ .array = nodes });

    const edges = try alloc.alloc(Value, g.edges.items.len);
    for (g.edges.items, 0..) |e, i| {
        const eo = try alloc.create(Value.Object);
        eo.* = .{};
        try eo.put(alloc, "id", .{ .string = e.id });
        try eo.put(alloc, "from", .{ .string = e.from });
        try eo.put(alloc, "fromPort", .{ .string = e.from_port });
        try eo.put(alloc, "to", .{ .string = e.to });
        try eo.put(alloc, "toPort", .{ .string = e.to_port });
        try eo.put(alloc, "kind", .{ .string = e.kind.wire() });
        edges[i] = .{ .object = eo };
    }
    try root.put(alloc, "edges", .{ .array = edges });

    return .{ .object = root };
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn parseFlow(alloc: std.mem.Allocator, text: []const u8) !Loaded {
    const r = try loadFromJson(alloc, text);
    switch (r) {
        .ok => |l| return l,
        .err => |e| {
            std.debug.print("flow parse failed: {s} @ {s}:{d}\n", .{ e.message, e.path, e.line });
            return error.FlowParseFailed;
        },
    }
}

test "graph: order and layering of a linear chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"name":"chain","nodes":[
        \\ {"id":"n1","cdl":"gcc","action":"compile","title":"Compile"},
        \\ {"id":"n2","cdl":"gcc","action":"run","title":"Run"},
        \\ {"id":"n3","cdl":"jq","action":"fmt","title":"Format"}],
        \\ "edges":[
        \\ {"id":"e1","from":"n1","to":"n2","kind":"seq"},
        \\ {"id":"e2","from":"n2","to":"n3","kind":"seq"}]}
    );
    try testing.expect(!l.hasErrors());
    const s = try schedule(a, &l.graph);
    try testing.expectEqual(@as(usize, 3), s.order.len);
    try testing.expectEqualStrings("n1", s.order[0]);
    try testing.expectEqualStrings("n3", s.order[2]);
    try testing.expectEqual(@as(usize, 3), s.layers.len);
    try testing.expectEqual(@as(usize, 1), s.layers[0].len);
}

test "graph: layering of a diamond dependency (middle layer runs in parallel)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B"},
        \\ {"id":"c","cdl":"x","action":"c","title":"C"},
        \\ {"id":"d","cdl":"x","action":"d","title":"D"}],
        \\ "edges":[
        \\ {"from":"a","to":"b","kind":"seq"},
        \\ {"from":"a","to":"c","kind":"seq"},
        \\ {"from":"b","to":"d","kind":"seq"},
        \\ {"from":"c","to":"d","kind":"seq"}]}
    );
    try testing.expect(!l.hasErrors());
    const s = try schedule(a, &l.graph);
    try testing.expectEqual(@as(usize, 4), s.order.len);
    try testing.expectEqual(@as(usize, 3), s.layers.len);
    // the middle layer must contain both b and c (they can run in parallel)
    try testing.expectEqual(@as(usize, 2), s.layers[1].len);
    try testing.expectEqual(@as(usize, 1), s.layers[0].len);
    try testing.expectEqual(@as(usize, 1), s.layers[2].len);
    try testing.expectEqualStrings("a", s.layers[0][0]);
    try testing.expectEqualStrings("d", s.layers[2][0]);
}

test "graph: a cycle is detected and schedule returns error.Cycle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B"},
        \\ {"id":"c","cdl":"x","action":"c","title":"C"}],
        \\ "edges":[
        \\ {"from":"a","to":"b","kind":"seq"},
        \\ {"from":"b","to":"c","kind":"seq"},
        \\ {"from":"c","to":"a","kind":"seq"}]}
    );
    try testing.expect(l.hasErrors());
    var saw_cycle = false;
    for (l.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "cycle") != null) {
            saw_cycle = true;
            std.debug.print("cycle description: {s}\n", .{i.message});
        }
    }
    try testing.expect(saw_cycle);
    try testing.expectError(error.Cycle, schedule(a, &l.graph));
}

test "graph: isolated nodes also enter the schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"solo","cdl":"x","action":"a","title":"Solo"},
        \\ {"id":"p","cdl":"x","action":"b","title":"P"},
        \\ {"id":"q","cdl":"x","action":"c","title":"Q"}],
        \\ "edges":[{"from":"p","to":"q","kind":"seq"}]}
    );
    try testing.expect(!l.hasErrors());
    const s = try schedule(a, &l.graph);
    try testing.expectEqual(@as(usize, 3), s.order.len);
    // solo and p share a layer (neither has dependencies)
    try testing.expectEqual(@as(usize, 2), s.layers[0].len);
}

test "graph: mixed pipe and seq dependencies both take part in the sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B"},
        \\ {"id":"c","cdl":"x","action":"c","title":"C"}],
        \\ "edges":[
        \\ {"from":"a","to":"b","kind":"pipe"},
        \\ {"from":"c","to":"b","kind":"seq"}]}
    );
    try testing.expect(!l.hasErrors());
    const s = try schedule(a, &l.graph);
    try testing.expectEqual(@as(usize, 3), s.order.len);
    // b must come after both a and c
    const pos_b = indexOfStr(s.order, "b").?;
    try testing.expect(pos_b > indexOfStr(s.order, "a").?);
    try testing.expect(pos_b > indexOfStr(s.order, "c").?);
}

fn indexOfStr(list: []const []const u8, s: []const u8) ?usize {
    for (list, 0..) |item, i| {
        if (std.mem.eql(u8, item, s)) return i;
    }
    return null;
}

test "graph: disabled nodes do not take part in the schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B","disabled":true}],
        \\ "edges":[{"from":"a","to":"b","kind":"seq"}]}
    );
    try testing.expect(!l.hasErrors());
    const s = try schedule(a, &l.graph);
    try testing.expectEqual(@as(usize, 1), s.order.len);
    try testing.expectEqualStrings("a", s.order[0]);
}

test "graph: an edge pointing at a non-existent node is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[{"id":"a","cdl":"x","action":"a","title":"A"}],
        \\ "edges":[{"from":"a","to":"ghost","kind":"seq"}]}
    );
    try testing.expect(l.hasErrors());
}

test "graph: a node accepts at most one stdin pipe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B"},
        \\ {"id":"c","cdl":"x","action":"c","title":"C"}],
        \\ "edges":[
        \\ {"from":"a","to":"c","kind":"pipe"},
        \\ {"from":"b","to":"c","kind":"pipe"}]}
    );
    try testing.expect(l.hasErrors());
    var found = false;
    for (l.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "only one is allowed") != null) found = true;
    }
    try testing.expect(found);
}

test "graph: value round trip (toValue -> loadFromValue) stays equivalent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"name":"round trip","viewport":{"x":12,"y":-4,"zoom":1.5},
        \\ "nodes":[
        \\  {"id":"n1","cdl":"gcc","action":"compile_cpp","title":"Compile C++","x":100,"y":50,
        \\   "values":{"source":"main.cpp","optimize":"true"},"retry":2,"timeoutMs":5000,"note":"memo"},
        \\  {"id":"n2","cdl":"node","action":"run_script","title":"Run","disabled":true}],
        \\ "edges":[{"id":"e9","from":"n1","fromPort":"stdout","to":"n2","toPort":"stdin","kind":"pipe"}]}
    );
    try testing.expect(!l.hasErrors());
    try testing.expectEqualStrings("round trip", l.graph.name);
    try testing.expectEqual(@as(f64, 1.5), l.graph.viewport_zoom);

    const v = try toValue(a, &l.graph);
    const l2 = try loadFromValue(a, v);
    try testing.expect(l2 == .ok);
    var g2 = &l2.ok.graph;
    try testing.expect(!l2.ok.hasErrors());
    try testing.expectEqualStrings(l.graph.name, g2.name);
    try testing.expectEqual(l.graph.nodes.items.len, g2.nodes.items.len);
    try testing.expectEqual(l.graph.edges.items.len, g2.edges.items.len);

    const n1 = g2.findNodeConst("n1").?;
    try testing.expectEqualStrings("gcc", n1.cdl_name);
    try testing.expectEqualStrings("main.cpp", n1.value("source").?);
    try testing.expectEqual(@as(u64, 5000), n1.timeout_ms.?);
    try testing.expectEqual(@as(u32, 2), n1.retry);
    try testing.expectEqualStrings("memo", n1.note);
    try testing.expect(g2.findNodeConst("n2").?.disabled);
    try testing.expectEqual(EdgeKind.pipe, g2.edges.items[0].kind);
    try testing.expectEqualStrings("e9", g2.edges.items[0].id);
}

test "graph: a raw command node needs no cdl/action and round-trips its argv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"raw","argv":["python","-m","mypy","src"]},
        \\ {"id":"titled","title":"named","argv":["git","status"]},
        \\ {"id":"ovr","cdl":"python","action":"run_code","title":"o",
        \\  "executable":"C:\\example\\python.exe"}],
        \\ "edges":[]}
    );
    try testing.expect(!l.hasErrors());

    // A raw node is legal with neither `cdl` nor `action`; that is the escape hatch.
    const raw = l.graph.findNodeConst("raw").?;
    try testing.expectEqualStrings("", raw.cdl_name);
    try testing.expectEqualStrings("", raw.action);
    try testing.expectEqual(@as(usize, 4), raw.argv.len);
    try testing.expectEqualStrings("mypy", raw.argv[2]);
    // With no title given, a raw node is labelled by its program.
    try testing.expectEqualStrings("python", raw.title);
    try testing.expectEqualStrings("named", l.graph.findNodeConst("titled").?.title);
    try testing.expectEqualStrings("C:\\example\\python.exe", l.graph.findNodeConst("ovr").?.executable);

    // Both new fields must survive save → load, or a saved workflow would silently lose the ability
    // to run at all (a raw node reloading without argv has neither a CDL nor a command).
    const v = try toValue(a, &l.graph);
    const l2 = try loadFromValue(a, v);
    try testing.expect(l2 == .ok);
    try testing.expect(!l2.ok.hasErrors());
    const raw2 = l2.ok.graph.findNodeConst("raw").?;
    try testing.expectEqual(@as(usize, 4), raw2.argv.len);
    try testing.expectEqualStrings("src", raw2.argv[3]);
    try testing.expectEqualStrings("C:\\example\\python.exe", l2.ok.graph.findNodeConst("ovr").?.executable);
    // An ordinary CDL node must not gain the new fields in its document.
    const plain = try parseFlow(a,
        \\{"nodes":[{"id":"p","cdl":"gcc","action":"compile_cpp","title":"P"}],"edges":[]}
    );
    const pv = try toValue(a, &plain.graph);
    try testing.expect(pv.object.get("nodes").?.array[0].object.get("argv") == null);
    try testing.expect(pv.object.get("nodes").?.array[0].object.get("executable") == null);
}

test "graph: a data edge produces a not-implemented warning but no error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const l = try parseFlow(a,
        \\{"nodes":[
        \\ {"id":"a","cdl":"x","action":"a","title":"A"},
        \\ {"id":"b","cdl":"x","action":"b","title":"B"}],
        \\ "edges":[{"from":"a","to":"b","kind":"data"}]}
    );
    try testing.expect(!l.hasErrors());
    var warned = false;
    for (l.issues) |i| {
        if (i.level == .warning and std.mem.indexOf(u8, i.message, "v0.4") != null) warned = true;
    }
    try testing.expect(warned);
}

test "graph: loadFromValue owns its strings (request-arena lifetime)" {
    // Regression: rpc.runStart parses the flow with the *request* arena, which is released as soon
    // as the RPC call returns, while the graph and the run plan are read later by the execution
    // thread. The graph therefore has to copy every id/name/value out of the Value tree. Before the
    // fix, run events reported garbage node ids ("UU" instead of "n1").
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\{"nodes":[{"id":"n1","cdl":"gcc","action":"compile","title":"Compile",
        \\  "values":{"source":"main.cpp","optimize":"true"}}],"edges":[]}
    ;
    const parsed = Value.parseJson(a, text);
    try testing.expect(parsed == .ok);

    const loaded = try loadFromValue(a, parsed.ok);
    try testing.expect(loaded == .ok);
    const g = loaded.ok.graph;
    try testing.expectEqual(@as(usize, 1), g.nodes.items.len);

    const src_node = parsed.ok.field("nodes").?.asArray().?[0];
    const src_vals = src_node.field("values").?.asObject().?;

    // Pointer identity is the invariant: the graph must NOT alias the source Value's buffers.
    try testing.expect(g.nodes.items[0].id.ptr != src_node.field("id").?.asString().?.ptr);
    try testing.expect(g.nodes.items[0].cdl_name.ptr != src_node.field("cdl").?.asString().?.ptr);
    try testing.expect(g.nodes.items[0].title.ptr != src_node.field("title").?.asString().?.ptr);
    try testing.expectEqualStrings("n1", g.nodes.items[0].id);
    try testing.expectEqualStrings("Compile", g.nodes.items[0].title);

    const v0 = src_vals.at(0);
    try testing.expect(g.nodes.items[0].values.get(v0.key).?.ptr != v0.value.asString().?.ptr);
    try testing.expectEqualStrings("main.cpp", g.nodes.items[0].values.get("source").?);
    try testing.expectEqualStrings("true", g.nodes.items[0].values.get("optimize").?);
}
