//! Native GUI spike — validates the decision to replace the WebView2 shell with a
//! cross-platform native window (Dear ImGui + SDL3).
//!
//! The four questions this program exists to answer, all of which are make-or-break:
//!   1. does a native window come up *inside the agent sandbox*, and can it be captured?
//!   2. does CJK text render (the UI ships a Chinese localisation)?
//!   3. does text input work, including IME-composed Chinese?
//!   4. can the node graph (cards, ports, bezier edges, pan/zoom) be drawn natively?
//!
//! Run:
//!   zig build gui-spike
//!   zig-out/bin/gui_spike                                  # interactive window
//!   zig-out/bin/gui_spike --frames 90 --shot out.bmp       # render N frames, dump a BMP, exit
//!
//! Everything GUI-library-specific lives behind `gui_shim.h`; this file only sees flat
//! `extern "C"` functions, the same arrangement the full GUI (`src/native/app.zig`) uses.

const std = @import("std");
const Io = std.Io;

// ── the C ABI exposed by src/native/gui_shim.cpp ─────────────────────────────
extern fn pl_gui_init(title: [*:0]const u8, width: c_int, height: c_int) c_int;
extern fn pl_gui_shutdown() void;
extern fn pl_gui_pump() c_int;
extern fn pl_gui_begin_frame() void;
extern fn pl_gui_end_frame(shot_path: ?[*:0]const u8) c_int;
extern fn pl_gui_renderer_name() [*:0]const u8;
extern fn pl_gui_last_error() [*:0]const u8;
extern fn pl_gui_load_font(path: [*:0]const u8, size_px: f32) c_int;
extern fn pl_gui_root_begin(id: [*:0]const u8) void;
extern fn pl_gui_root_end() void;
extern fn pl_gui_text(text: [*:0]const u8) void;
extern fn pl_gui_text_dim(text: [*:0]const u8) void;
extern fn pl_gui_input_text(id: [*:0]const u8, buf: [*]u8, buf_len: c_int) c_int;
extern fn pl_gui_separator() void;
extern fn pl_gui_same_line() void;
extern fn pl_gui_content_avail(out_w: *f32, out_h: *f32) void;
extern fn pl_gui_cursor_pos(out_x: *f32, out_y: *f32) void;
extern fn pl_gui_invisible_button(id: [*:0]const u8, w: f32, h: f32, buttons: c_int) c_int;
extern fn pl_gui_item_hovered() c_int;
extern fn pl_gui_item_active() c_int;
extern fn pl_gui_mouse_wheel() f32;
extern fn pl_gui_mouse_delta(out_dx: *f32, out_dy: *f32) void;
extern fn pl_gui_dl_rect_filled(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, round_top: c_int) void;
extern fn pl_gui_dl_rect(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, thickness: f32) void;
extern fn pl_gui_dl_line(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, thickness: f32) void;
extern fn pl_gui_dl_circle_filled(cx: f32, cy: f32, radius: f32, col: c_uint) void;
extern fn pl_gui_dl_bezier(
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    col: c_uint,
    thickness: f32,
) void;
extern fn pl_gui_dl_text(x: f32, y: f32, col: c_uint, text: [*:0]const u8) void;
extern fn pl_gui_delay_ms(ms: c_int) void;

/// IM_COL32 packing, recomputed here because the C macro does not cross the ABI.
inline fn rgba(r: u32, g: u32, b: u32, a: u32) c_uint {
    return @intCast(r | (g << 8) | (b << 16) | (a << 24));
}

const Args = struct {
    width: c_int = 1280,
    height: c_int = 800,
    frames: u32 = 0, // 0 = run until the window is closed
    shot: ?[]const u8 = null,
    font: ?[]const u8 = null,
};

/// CJK-capable system fonts, most-preferred first. Nothing is vendored: a font blob would add
/// 10-20 MB to the repository, and the families differ per platform anyway.
///
/// Chosen by platform at compile time, and the Windows directory comes from `SystemRoot` / `WINDIR`
/// rather than assuming `C:\Windows` (Windows may be installed on another drive); `C:/Windows` is
/// only the fallback when neither variable is visible. Every entry is an OS-standard location, so the
/// same binary finds a font on any machine — and if none exists, the spike reports it and ImGui's
/// built-in font is used.
fn fontCandidates(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (@import("builtin").os.tag) {
        .windows => {
            const root = if (env) |m|
                (m.get("SystemRoot") orelse m.get("WINDIR") orelse "C:/Windows")
            else
                "C:/Windows";
            for ([_][]const u8{
                "/Fonts/simhei.ttf", // SimHei: a single-face TTF, present on zh Windows
                "/Fonts/Deng.ttf", // DengXian
                "/Fonts/msyh.ttc", // Microsoft YaHei (collection, face 0)
                "/Fonts/simsun.ttc", // SimSun (collection)
            }) |tail| {
                const full = std.fmt.allocPrint(a, "{s}{s}", .{ root, tail }) catch continue;
                list.append(a, full) catch {};
            }
        },
        .macos => {
            for ([_][]const u8{
                "/System/Library/Fonts/PingFang.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc",
            }) |p| list.append(a, p) catch {};
        },
        else => {
            for ([_][]const u8{
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
            }) |p| list.append(a, p) catch {};
        },
    }
    return list.items;
}

fn parseArgs(a: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    var out = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i < argv.len) out.frames = std.fmt.parseInt(u32, argv[i], 10) catch 90;
        } else if (std.mem.eql(u8, arg, "--shot")) {
            i += 1;
            if (i < argv.len) out.shot = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--font")) {
            i += 1;
            if (i < argv.len) out.font = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i < argv.len) {
                const spec: []const u8 = argv[i];
                if (std.mem.indexOfScalar(u8, spec, 'x')) |x| {
                    out.width = std.fmt.parseInt(c_int, spec[0..x], 10) catch out.width;
                    out.height = std.fmt.parseInt(c_int, spec[x + 1 ..], 10) catch out.height;
                }
            }
        }
    }
    return out;
}

/// Allocator.dupeZ was removed in Zig 0.17; allocSentinel + copy is the equivalent.
fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try a.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

/// Tries each candidate until one actually loads, so a missing CJK font is an explicit
/// diagnostic instead of silently-blank Chinese text.
fn loadFont(a: std.mem.Allocator, opts: Args, env: ?*const std.process.Environ.Map, w: anytype) ?[]const u8 {
    if (opts.font) |explicit| {
        const z = dupeZ(a, explicit) catch return null;
        if (pl_gui_load_font(z.ptr, 18.0) == 1) return explicit;
        w.print("font failed to load: {s}\n", .{explicit}) catch {};
        return null;
    }
    for (fontCandidates(a, env)) |path| {
        const z = dupeZ(a, path) catch continue;
        if (pl_gui_load_font(z.ptr, 18.0) == 1) return path;
    }
    return null;
}

/// A stand-in for the real node graph: cards wired by beziers, with pan/zoom. This is the
/// riskiest drawing work, so it is proven before committing to the rewrite.
const Canvas = struct {
    pan_x: f32 = 40,
    pan_y: f32 = 30,
    zoom: f32 = 1,

    const Node = struct {
        x: f32,
        y: f32,
        w: f32 = 210,
        h: f32 = 104,
        title: [:0]const u8,
        tint: c_uint,
    };

    fn pick(self: *Canvas) void {
        if (pl_gui_item_active() == 1) {
            var dx: f32 = 0;
            var dy: f32 = 0;
            pl_gui_mouse_delta(&dx, &dy);
            self.pan_x += dx;
            self.pan_y += dy;
        }
        if (pl_gui_item_hovered() == 1) {
            const wheel = pl_gui_mouse_wheel();
            if (wheel != 0) {
                self.zoom = std.math.clamp(self.zoom * (1 + wheel * 0.12), 0.35, 2.5);
            }
        }
    }

    fn draw(self: *Canvas, origin_x: f32, origin_y: f32, avail_w: f32, avail_h: f32) void {
        _ = pl_gui_invisible_button("##canvas", avail_w, avail_h, 3);
        self.pick();

        const nodes = [_]Node{
            .{ .x = 0, .y = 0, .title = "Compile C++ / 编译 C++", .tint = rgba(90, 150, 240, 255) },
            .{ .x = 300, .y = 150, .title = "Package / 打包", .tint = rgba(120, 200, 140, 255) },
            .{ .x = 0, .y = 210, .title = "Sign / 签名", .tint = rgba(230, 180, 90, 255) },
        };

        const P = struct {
            fn at(ox: f32, oy: f32, pan_x: f32, pan_y: f32, z: f32, wx: f32, wy: f32) [2]f32 {
                return .{ ox + (pan_x + wx) * z, oy + (pan_y + wy) * z };
            }
        };

        // Edges first so the cards paint over them.
        const a_r = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, nodes[0].x + nodes[0].w, nodes[0].y + 40);
        const b_l = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, nodes[1].x, nodes[1].y + 40);
        const c_l = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, nodes[2].x, nodes[2].y + 40);
        const bend = 90 * self.zoom;
        pl_gui_dl_bezier(a_r[0], a_r[1], a_r[0] + bend, a_r[1], b_l[0] - bend, b_l[1], b_l[0], b_l[1], rgba(120, 170, 255, 255), 2.2 * self.zoom);
        pl_gui_dl_bezier(a_r[0], a_r[1], a_r[0] + bend, a_r[1], c_l[0] - bend, c_l[1], c_l[0], c_l[1], rgba(230, 180, 90, 255), 2.2 * self.zoom);

        for (nodes) |n| {
            const p0 = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, n.x, n.y);
            const p1 = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, n.x + n.w, n.y + n.h);
            const h1 = P.at(origin_x, origin_y, self.pan_x, self.pan_y, self.zoom, n.x + n.w, n.y + 30);
            const rounding = 8 * self.zoom;
            pl_gui_dl_rect_filled(p0[0], p0[1], p1[0], p1[1], rgba(30, 36, 48, 255), rounding, 0);
            pl_gui_dl_rect_filled(p0[0], p0[1], h1[0], h1[1], n.tint, rounding, 1);
            pl_gui_dl_rect(p0[0], p0[1], p1[0], p1[1], n.tint, rounding, 1.6 * self.zoom);
            pl_gui_dl_text(p0[0] + 8 * self.zoom, p0[1] + 7 * self.zoom, rgba(16, 18, 24, 255), n.title.ptr);
            pl_gui_dl_text(p0[0] + 8 * self.zoom, p0[1] + 44 * self.zoom, rgba(190, 198, 214, 255), "g++ -O2 -o a.exe main.cpp");
            pl_gui_dl_circle_filled(p1[0], p0[1] + 40 * self.zoom, 6 * self.zoom, rgba(120, 170, 255, 255));
            pl_gui_dl_circle_filled(p0[0], p0[1] + 40 * self.zoom, 6 * self.zoom, rgba(120, 200, 140, 255));
        }

        var buf: [96]u8 = undefined;
        // bufPrintZ is gone in 0.17; format into the buffer and terminate it by hand.
        const label = std.fmt.bufPrint(buf[0 .. buf.len - 1], "zoom {d:.2}x   drag to pan   wheel to zoom", .{self.zoom}) catch return;
        buf[label.len] = 0;
        pl_gui_dl_text(origin_x + 10, origin_y + avail_h - 24, rgba(150, 158, 172, 255), @ptrCast(&buf));
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    // The environment map is what the font lookup reads `SystemRoot` / `WINDIR` from, so the same
    // binary finds the system fonts on any machine instead of assuming `C:\Windows`.
    var env_map = init.minimal.environ.createMap(init.gpa) catch null;
    defer if (env_map) |*m| m.deinit();
    const env_map_ptr: ?*const std.process.Environ.Map = if (env_map) |*m| m else null;

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    var err_buf: [1024]u8 = undefined;
    var errw = Io.File.stderr().writer(io, &err_buf);
    const e = &errw.interface;
    // The std.Io writers are buffered; without this the diagnostics never reach the terminal.
    defer w.flush() catch {};
    defer e.flush() catch {};

    const argv = try init.minimal.args.toSlice(a);
    const opts = try parseArgs(a, argv);

    const title: [:0]const u8 = "Flow Pipelith - native GUI spike";
    if (pl_gui_init(title.ptr, opts.width, opts.height) != 1) {
        try e.print("pl_gui_init failed: {s}\n", .{pl_gui_last_error()});
        return error.GuiInitFailed;
    }
    defer pl_gui_shutdown();

    // Honest diagnostic for question 1: which SDL renderer backend actually came up.
    try w.print("window {d}x{d} up, SDL renderer = {s}\n", .{ opts.width, opts.height, pl_gui_renderer_name() });

    if (loadFont(a, opts, env_map_ptr, w)) |path| {
        try w.print("font: {s}\n", .{path});
    } else {
        try e.print("WARNING: no CJK font loaded; Chinese text will not render\n", .{});
    }

    const shot_z: ?[:0]u8 = if (opts.shot) |s| try dupeZ(a, s) else null;

    var canvas = Canvas{};
    var typed_buf: [256]u8 = std.mem.zeroes([256]u8);
    const seed = "Hello 你好，世界";
    @memcpy(typed_buf[0..seed.len], seed);
    const typed_id: [:0]const u8 = "##ime";

    var frames: u32 = 0;
    const capture_at: u32 = if (shot_z != null) @max(opts.frames, 3) else 0;

    while (pl_gui_pump() == 1) {
        pl_gui_begin_frame();

        pl_gui_root_begin("##root");
        pl_gui_text("1. native window: OK    2. CJK glyphs: 中文渲染测试    3. type here (IME) ->");
        pl_gui_same_line();
        _ = pl_gui_input_text(typed_id.ptr, &typed_buf, typed_buf.len);
        pl_gui_separator();

        var avail_w: f32 = 0;
        var avail_h: f32 = 0;
        pl_gui_content_avail(&avail_w, &avail_h);
        var ox: f32 = 0;
        var oy: f32 = 0;
        pl_gui_cursor_pos(&ox, &oy);
        if (avail_h > 40) canvas.draw(ox, oy, avail_w, avail_h);
        pl_gui_root_end();

        frames += 1;
        const want_shot = capture_at != 0 and frames >= capture_at;
        const saved = pl_gui_end_frame(if (want_shot) shot_z.?.ptr else null);
        if (want_shot) {
            if (saved == 1) {
                try w.print("wrote screenshot: {s}\n", .{opts.shot.?});
            } else {
                try e.print("screenshot failed: {s}\n", .{pl_gui_last_error()});
            }
            return;
        }
        if (opts.frames != 0 and frames >= opts.frames) return;
        pl_gui_delay_ms(12);
    }
}
