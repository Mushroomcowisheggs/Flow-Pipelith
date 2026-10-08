//! Flow Pipelith entry point.
//!
//! Modes (the GUI is entered by default):
//!   (no arguments)    start the native windowed GUI (rule 9: single process, Dear ImGui + SDL3)
//!   --rpc-stdio       headless mode: line-delimited JSON-RPC over stdin/stdout (end-to-end tests / in-process integration)
//!   --run <file>      execute a .flow directly, events are emitted as JSON lines (equivalent to pipelith-run)
//!   --check <file>    validate a CDL file and print diagnostics
//!   --packs           list the available tool packs and which tools are installed
//!   --http [--port N] local HTTP + WebSocket service (development/debug transport, not the GUI)
//!   --version / --help
//!
//! No mode loads a tool by default: a fresh installation starts with an empty tool library, and the
//! user installs the packs they want (`packs.load` / the library panel).

const std = @import("std");
const Io = std.Io;
const pipelith = @import("pipelith");
const native_gui = @import("native_gui");
const cdl = pipelith.cdl;
const builtin = pipelith.builtin;
const rpc_stdio = pipelith.rpc_stdio;

pub const version = "0.1.0";
pub const cdl_version = "0.1";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .gui;
    var file_arg: ?[]const u8 = null;
    var port: u16 = pipelith.http.default_port;
    var web_dir: []const u8 = pipelith.http.default_web_dir;
    // `--state-dir` is shared by every mode that reads or writes tools (`--packs`, `--run`, and the
    // GUI's own flag), so it is parsed here as well: a hermetic or scripted run must read the tool
    // directory it installed into, not whatever sits next to the executable. `--packs-dir` names the
    // directories tool packs are read from (repeatable); without one, no pack is offered at all.
    var state_dir: ?[]const u8 = null;
    var packs_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printHelp(w);
            try w.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            try w.print("pipelith {s} (CDL {s})\n", .{ version, cdl_version });
            try w.flush();
            return 0;
        } else if (std.mem.eql(u8, a, "--rpc-stdio")) {
            mode = .rpc_stdio;
        } else if (std.mem.eql(u8, a, "--state-dir")) {
            i += 1;
            if (i < args.len) state_dir = std.mem.sliceTo(args[i], 0);
        } else if (std.mem.eql(u8, a, "--packs-dir")) {
            i += 1;
            if (i < args.len) try packs_dirs.append(init.arena.allocator(), std.mem.sliceTo(args[i], 0));
        } else if (std.mem.eql(u8, a, "--packs")) {
            mode = .packs;
        } else if (std.mem.eql(u8, a, "--check")) {
            // `--check` / `--run` take a path, and the GUI owns a `--run` flag of its own (start a
            // run immediately). They are only treated as mode selectors when a path actually
            // follows; otherwise the command line belongs to the GUI. Without this lookahead the
            // two parsers fight over the one command line and a GUI invocation exits with a usage
            // error.
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') mode = .check;
        } else if (std.mem.eql(u8, a, "--run")) {
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') mode = .run;
        } else if (std.mem.eql(u8, a, "--selftest")) {
            mode = .selftest;
        } else if (std.mem.eql(u8, a, "--http")) {
            mode = .http;
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) {
                try w.writeAll("--port requires a port number\n");
                try w.flush();
                return 2;
            }
            port = std.fmt.parseInt(u16, std.mem.sliceTo(args[i], 0), 10) catch {
                try w.print("invalid port number: {s}\n", .{args[i]});
                try w.flush();
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--web")) {
            i += 1;
            if (i >= args.len) {
                try w.writeAll("--web requires a directory\n");
                try w.flush();
                return 2;
            }
            web_dir = std.mem.sliceTo(args[i], 0);
        } else if (a.len > 0 and a[0] != '-') {
            file_arg = a;
        }
    }

    switch (mode) {
        .selftest => {
            // The self-test's output is buffered like every other mode's, so it has to be flushed
            // before the exit code is returned: a short run (say, the "no pack sources" refusal)
            // would otherwise print nothing at all.
            const code = try pipelith.selftest.run(init, w);
            try w.flush();
            return code;
        },
        .rpc_stdio => return try rpc_stdio.run(init),
        .packs => return try listPacks(io, w, state_dir, packs_dirs.items),
        .check => {
            const path = file_arg orelse {
                try w.writeAll("usage: pipelith --check <cdl file>\n");
                try w.flush();
                return 2;
            };
            return try checkCdl(init, path, w);
        },
        .run => {
            const path = file_arg orelse {
                try w.writeAll("usage: pipelith --run <flow file>\n");
                try w.flush();
                return 2;
            };
            return try runFlow(init, path, state_dir, w);
        },
        .http => {
            return try pipelith.http.run(init, .{ .port = port, .web_dir = web_dir });
        },
        .gui => {
            // Rule 9: the native single-process window. `--http` remains the only mode that serves
            // the browser frontend, and it is a development transport rather than the GUI.
            return try native_gui.runGui(init);
        },
    }
    _ = gpa;
}

const Mode = enum { gui, rpc_stdio, http, check, packs, run, selftest };

fn printHelp(w: *Io.Writer) !void {
    try w.writeAll(
        \\Flow Pipelith — a graphical execution layer for the CLI
        \\
        \\Usage:
        \\  pipelith                    start the graphical interface (native window)
        \\  pipelith --http [--port N]  local HTTP + WebSocket service (development transport)
        \\  pipelith --rpc-stdio        headless RPC mode (line-delimited JSON, for tests/integration)
        \\  pipelith --run <flow>       execute a workflow, events are emitted as JSON lines
        \\  pipelith --check <cdl>      validate a CDL file
        \\  pipelith --selftest         in-process self-test (RPC contract + execution + events)
        \\  pipelith --packs            list the available tool packs (nothing is installed by default)
        \\  pipelith --version          version
        \\
        \\Options:
        \\  --port N                    service port (default 8791)
        \\  --web <dir>                 static asset directory (default web)
        \\
        \\Any flag not listed above belongs to the GUI window and is passed through to it
        \\(for example --demo, --size 1280x800, --shot out.bmp, --open-flow in.flow).
        \\`--run` and `--check` are only read as modes when a path follows them, so the GUI's own
        \\`--run` flag (start a run immediately) is not mistaken for the command-line mode.
        \\
    );
}

/// `--packs`: what this installation *could* load. Nothing here is active — a fresh installation has
/// an empty tool library, and this listing is the menu the GUI's library panel offers.
/// `--packs`: what this installation *could* load. Nothing here is active — a fresh installation has
/// an empty tool library, and this listing is the menu the GUI's library panel offers.
fn listPacks(io: Io, w: *Io.Writer, state_override: ?[]const u8, extra_dirs: []const []const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all = pipelith.packs.discover(io, a, state_override orelse (try pipelith.builtin.stateDir(io, a)), extra_dirs);
    const state = state_override orelse (try pipelith.builtin.stateDir(io, a));
    const cdl_dir: ?[]const u8 = if (state) |s|
        try std.fs.path.join(a, &.{ s, pipelith.packs.installed_dir_name })
    else
        null;

    try w.print("Tool packs ({d}) — none is loaded until you install it:\n", .{all.len});
    for (all) |*p| {
        const st = pipelith.packs.state(io, a, p, cdl_dir);
        try w.print("  {s:<14} {s:<28} {d} tools, installed {d}/{d}  [{s}{s}{s}]\n", .{
            p.id,
            p.label,
            p.tools.len,
            st.installed,
            st.total,
            p.source.wire(),
            if (p.origin.len > 0) " " else "",
            p.origin,
        });
        for (p.tools, 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(pipelith.packs.stem(t.file));
        }
        try w.writeByte('\n');
    }
    if (cdl_dir) |d| try w.print("Installed tools live in {s}\n", .{d});
    try w.writeAll("Install one from the GUI's library panel (or the `pack.load` RPC method).\n");
    try w.flush();
    return 0;
}

fn checkCdl(init: std.process.Init, path: []const u8, w: *Io.Writer) !u8 {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch |e| {
        try w.print("cannot read {s}: {t}\n", .{ path, e });
        try w.flush();
        return 2;
    };

    const r = try cdl.load(a, text);
    switch (r) {
        .err => |e| {
            try w.print("{s}:{d}  parse failed: {s}  (path={s})\n", .{ path, e.line, e.message, e.path });
            try w.flush();
            return 1;
        },
        .ok => |loaded| {
            var errors: usize = 0;
            var warnings: usize = 0;
            for (loaded.issues) |iss| {
                switch (iss.level) {
                    .@"error" => errors += 1,
                    .warning => warnings += 1,
                    .info => {},
                }
                try w.print("  [{s}] {s}", .{ @tagName(iss.level), iss.message });
                if (iss.path.len > 0) try w.print("  @ {s}", .{iss.path});
                try w.writeByte('\n');
            }
            try w.print(
                "{s}: {s} / {d} actions / errors {d} / warnings {d}\n",
                .{ path, loaded.doc.display_name, loaded.doc.actions.len, errors, warnings },
            );
            try w.flush();
            return if (errors > 0) 1 else 0;
        },
    }
}

/// `--run`: reuses the execution logic of `engine_cli` (one single implementation, so both paths behave identically).
fn runFlow(init: std.process.Init, path: []const u8, state_dir: ?[]const u8, w: *Io.Writer) !u8 {
    const engine_cli = @import("engine_cli.zig");
    _ = w;
    // `engine_cli.run` accepts arguments in the form [:0]const u8, so the sentinel is filled in here.
    // `--state-dir` is forwarded: the run reads the tools from that directory, exactly like the GUI.
    const arena = init.arena.allocator();
    const extra: usize = if (state_dir != null) 2 else 0;
    const args = try arena.alloc([:0]const u8, 2 + extra);
    args[0] = "pipelith";
    const path_z = try arena.allocSentinel(u8, path.len, 0);
    @memcpy(path_z[0..path.len], path);
    args[1] = path_z;
    if (state_dir) |dir| {
        args[2] = "--state-dir";
        const dir_z = try arena.allocSentinel(u8, dir.len, 0);
        @memcpy(dir_z[0..dir.len], dir);
        args[3] = dir_z;
    }
    return engine_cli.run(init, args);
}
