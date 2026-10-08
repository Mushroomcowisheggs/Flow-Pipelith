//! Native GUI — first ported slice: the app shell plus the tool library panel.
//!
//! The native single-process window. The GUI runs in the same process as the engine and reaches it
//! through `rpc.Service` directly (no bridge, no IPC, no browser). The panel layout mirrors the web design: topbar, tool library, canvas, inspector,
//! output, statusbar.
//!
//! Deliberately NOT ported yet (see the port plan): node graph interaction, the CDL-driven forms in
//! the inspector, run/output streaming, theming and zh/en i18n. Those panels are placeholders here.
//!
//! Run:
//!   zig build gui
//!   zig-out/bin/pipelith-gui                          # interactive
//!   zig-out/bin/pipelith-gui --frames 60 --shot a.bmp  # render, screenshot, exit

const std = @import("std");
const Io = std.Io;
const pipelith = @import("pipelith");
const rpc = pipelith.rpc;
const builtin = pipelith.builtin;
const i18n = @import("i18n.zig");
const theme = @import("theme.zig");

const Lang = i18n.Lang;
const StrKey = i18n.StrKey;

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
extern fn pl_gui_text_heading(text: [*:0]const u8) void;
extern fn pl_gui_text_wrapped(text: [*:0]const u8) void;
extern fn pl_gui_text_dim_wrapped(text: [*:0]const u8) void;
extern fn pl_gui_separator() void;
extern fn pl_gui_separator_text(text: [*:0]const u8) void;
extern fn pl_gui_same_line() void;
extern fn pl_gui_dummy(w: f32, h: f32) void;
extern fn pl_gui_set_next_item_width(w: f32) void;
extern fn pl_gui_button_row_reserve(label: [*:0]const u8) f32;
extern fn pl_gui_begin_child(id: [*:0]const u8, w: f32, h: f32, border: c_int) void;
extern fn pl_gui_end_child() void;
extern fn pl_gui_content_avail(out_w: *f32, out_h: *f32) void;
extern fn pl_gui_cursor_pos(out_x: *f32, out_y: *f32) void;
extern fn pl_gui_set_cursor_screen_pos(x: f32, y: f32) void;
extern fn pl_gui_invisible_button(id: [*:0]const u8, w: f32, h: f32, buttons: c_int) c_int;
extern fn pl_gui_item_hovered() c_int;
extern fn pl_gui_item_active() c_int;
extern fn pl_gui_mouse_wheel() f32;
extern fn pl_gui_mouse_delta(out_dx: *f32, out_dy: *f32) void;
extern fn pl_gui_dl_rect_filled(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, round_top: c_int) void;
extern fn pl_gui_dl_rect(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, rounding: f32, thickness: f32) void;
extern fn pl_gui_dl_bezier(x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, col: c_uint, thickness: f32) void;
extern fn pl_gui_dl_circle_filled(cx: f32, cy: f32, radius: f32, col: c_uint) void;
extern fn pl_gui_dl_line(x0: f32, y0: f32, x1: f32, y1: f32, col: c_uint, thickness: f32) void;
extern fn pl_gui_dl_text(x: f32, y: f32, col: c_uint, text: [*:0]const u8) void;
extern fn pl_gui_button(label: [*:0]const u8, w: f32, h: f32) c_int;
extern fn pl_gui_selectable(label: [*:0]const u8, selected: c_int) c_int;
extern fn pl_gui_input_text_hint(id: [*:0]const u8, hint: [*:0]const u8, buf: [*]u8, buf_len: c_int) c_int;
extern fn pl_gui_input_text_multiline(id: [*:0]const u8, buf: [*]u8, buf_len: c_int, w: f32, h: f32) c_int;
extern fn pl_gui_checkbox(label: [*:0]const u8, value: c_int) c_int;
extern fn pl_gui_combo(id: [*:0]const u8, current: c_int, items: [*]const [*:0]const u8, count: c_int) c_int;
extern fn pl_gui_text_error(text: [*:0]const u8) void;
extern fn pl_gui_text_colored(text: [*:0]const u8, col: c_uint) void;
extern fn pl_gui_begin_disabled(disabled: c_int) void;
extern fn pl_gui_end_disabled() void;
extern fn pl_gui_scroll_to_bottom() void;
extern fn pl_gui_calc_text_width(text: [*:0]const u8) f32;
extern fn pl_gui_apply_theme(bg: c_uint, panel: c_uint, sunken: c_uint, border: c_uint, text: c_uint, text_dim: c_uint, accent: c_uint, light: c_int) void;
extern fn pl_gui_delay_ms(ms: c_int) void;
// Semantic key codes from gui_shim.h (PL_GUI_KEY_*).
extern fn pl_gui_key_pressed(key: c_int) c_int;
extern fn pl_gui_key_ctrl() c_int;
extern fn pl_gui_key_shift() c_int;
extern fn pl_gui_want_text_input() c_int;
extern fn pl_gui_item_deactivated_after_edit() c_int;
extern fn pl_gui_set_keyboard_focus_here() void;
extern fn pl_gui_new_line() void;
extern fn pl_gui_error_count() c_int;
extern fn pl_gui_set_synthetic_mouse(x: f32, y: f32) void;
extern fn pl_gui_mouse_pos(out_x: *f32, out_y: *f32) void;
extern fn pl_gui_mouse_down(button: c_int) c_int;

const key_z: c_int = 1;
const key_y: c_int = 2;
const key_delete: c_int = 3;
const key_escape: c_int = 4;
const key_enter: c_int = 5;
const key_d: c_int = 6;
const key_n: c_int = 7;
const key_o: c_int = 8;
const key_s: c_int = 9;
const key_f: c_int = 10;
const key_l: c_int = 11;
const key_minus: c_int = 12;
const key_equal: c_int = 13;
const key_zero: c_int = 14;
const key_a: c_int = 15;
const key_c: c_int = 16;
const key_v: c_int = 17;

/// IM_COL32 packing lives in theme.zig (one source of truth with the palettes).
const rgba = theme.rgba;

/// Candidate UI fonts, most preferred first (a CJK face is needed for the Chinese UI).
///
/// Two rules make this portable rather than machine-specific:
///   - the list is chosen by **platform** at compile time, so a build only ever looks at paths that
///     exist on the system it runs on;
///   - the Windows entries are built from the `SystemRoot` / `WINDIR` environment variable instead of
///     assuming `C:\Windows`, because Windows may be installed on another drive. `C:/Windows` is only
///     the fallback for the (unusual) case where neither variable is visible.
///
/// Every entry is an OS-standard location, so the same binary finds a suitable font on any machine;
/// if none of them exists, `runGui` reports it and ImGui's built-in font is used (the program still
/// runs — it just cannot draw CJK glyphs).
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
                "/Fonts/simsun.ttc", // SimSun
            }) |tail| {
                const full = std.fmt.allocPrint(a, "{s}{s}", .{ root, tail }) catch continue;
                list.append(a, full) catch {};
            }
        },
        .macos => {
            for ([_][]const u8{
                "/System/Library/Fonts/PingFang.ttc",
                "/System/Library/Fonts/STHeiti Light.ttc",
                "/Library/Fonts/Arial Unicode.ttf",
            }) |p| list.append(a, p) catch {};
        },
        else => {
            for ([_][]const u8{
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
                "/usr/share/fonts/truetype/arphic/uming.ttc",
            }) |p| list.append(a, p) catch {};
        },
    }
    return list.items;
}

fn dupeZ(a: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try a.allocSentinel(u8, s.len, 0);
    @memcpy(buf, s);
    return buf;
}

/// Formats into a caller-owned buffer and NUL-terminates it (fmt.bufPrintZ was removed in 0.17).
/// The buffer must outlive the returned pointer.
fn fmtZ(buf: []u8, comptime f: []const u8, args: anytype) [*:0]const u8 {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], f, args) catch {
        buf[0] = 0;
        return @ptrCast(buf.ptr);
    };
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Same, but allocated from `a` (normally a per-frame scratch arena) so the result can outlive the
/// statement it was built in.
fn allocZ(a: std.mem.Allocator, comptime f: []const u8, args: anytype) ?[:0]u8 {
    const s = std.fmt.allocPrint(a, f, args) catch return null;
    const out = a.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(out, s);
    return out;
}

/// Free width on the row the layout cursor is on. ImGui's content region already excludes the
/// panel's scrollbar, so this is the width a widget may really occupy.
fn rowAvailWidth() f32 {
    var w: f32 = 0;
    var h: f32 = 0;
    pl_gui_content_avail(&w, &h);
    return w;
}

/// Width to reserve on this row for a button carrying `label`, or null when reserving it would
/// leave less than `min_input` for the input beside it. `label` includes its `##id` suffix (ImGui
/// measures only the visible part). Null means "give the input the full width and put the button on
/// the next line": a button that cannot fit must move, because one that overflows the content
/// region is clipped by the panel's scrollbar — which is exactly how a long localized label like
/// 选择可执行文件 / "Pick executable" lost its last glyph.
fn inlineReserve(label: [*:0]const u8, min_input: f32) ?f32 {
    const reserve = pl_gui_button_row_reserve(label);
    if (rowAvailWidth() < reserve + min_input) return null;
    return reserve;
}

/// True when a button carrying `label` still fits on the current row. Callers use it to choose
/// between `pl_gui_same_line()` and starting a new line, so a row of buttons wraps instead of
/// running under the scrollbar.
fn buttonFitsOnRow(label: [*:0]const u8) bool {
    return rowAvailWidth() >= pl_gui_button_row_reserve(label);
}

/// An integer field of a JSON object; 0 when absent, not a number, or negative.
fn intField(v: pipelith.value.Value, name: []const u8) usize {
    const x = v.field(name) orelse return 0;
    const n = x.asInt() orelse return 0;
    return if (n < 0) 0 else @intCast(n);
}

/// Copies `s` into a fixed NUL-terminated buffer (truncating), returning the length written.
fn copyZ(buf: []u8, s: []const u8) usize {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return n;
}

/// Joins a JSON array of names into a fixed buffer ("git, make"), returning the length written.
fn joinNames(buf: []u8, names: []const pipelith.value.Value) usize {
    var used: usize = 0;
    for (names, 0..) |n, i| {
        const s = n.asString() orelse continue;
        const sep = if (i == 0) "" else ", ";
        if (used + sep.len + s.len + 1 >= buf.len) break;
        @memcpy(buf[used..][0..sep.len], sep);
        used += sep.len;
        @memcpy(buf[used..][0..s.len], s);
        used += s.len;
    }
    buf[used] = 0;
    return used;
}

/// Escapes the two characters that would break a JSON string. Enough for a search box; anything
/// richer should go through the value model's serializer.
fn jsonEscape(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    for (src) |c| {
        const esc = c == '"' or c == '\\';
        if (n + (if (esc) @as(usize, 2) else 1) >= dst.len) break;
        if (esc) {
            dst[n] = '\\';
            n += 1;
        }
        dst[n] = c;
        n += 1;
    }
    return dst[0..n];
}

/// Appends `s` to `out` as a JSON string body. CDL values, titles and paths are arbitrary text, so
/// the flow payload cannot be assembled with plain concatenation.
fn jsonEscapeInto(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [8]u8 = undefined;
                    const t = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                    try out.appendSlice(a, t);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
}

/// Engine -> UI events arrive from run worker threads, so they are queued under a mutex and drained
/// on the UI thread. Wired now (even though nothing emits yet) so the run panel needs no refactor.
const Sink = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    /// Set by deinit so a late push from a run worker is dropped instead of touching freed memory.
    closed: bool = false,

    fn send(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        const copy = self.gpa.dupe(u8, json) catch return;
        self.mutex.lock(self.io) catch {
            self.gpa.free(copy);
            return;
        };
        defer self.mutex.unlock(self.io);
        if (self.closed) {
            self.gpa.free(copy);
            return;
        }
        self.queue.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    /// Moves the queued messages to the caller. The bytes are COPIED into `a` (the frame arena)
    /// and the sink's own copies are released here: returning the same pointers and freeing them
    /// would hand the caller freed memory.
    fn drain(self: *Sink, a: std.mem.Allocator) []const []u8 {
        self.mutex.lock(self.io) catch return &[_][]u8{};
        defer self.mutex.unlock(self.io);
        var out: std.ArrayListUnmanaged([]u8) = .empty;
        for (self.queue.items) |item| {
            defer self.gpa.free(item);
            const copy = a.dupe(u8, item) catch continue;
            out.append(a, copy) catch continue;
        }
        self.queue.clearRetainingCapacity();
        return out.items;
    }

    /// Releases whatever the UI never got around to draining (the last events of a run).
    fn deinit(self: *Sink) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.closed = true;
        for (self.queue.items) |item| self.gpa.free(item);
        self.queue.deinit(self.gpa);
    }
};

const Item = struct {
    name: []const u8,
    display: []const u8,
    desc: []const u8,
    version: []const u8,
    category: []const u8,
    available: bool,
    action_name: []const u8,
    action_label: []const u8,
    /// "builtin" or "user" — a user tool can be deleted, a built-in cannot.
    source: []const u8 = "builtin",
    /// The program a free command node for this tool starts with (the tool's effective
    /// executable from `cdl.list`), so picking a tool gives a runnable command, not a bare name.
    exe: []const u8 = "",
};

/// One tool-sheet gesture as a script item for the verification harness — each flag value is one
/// click, replayed through the same handlers the panel buttons call, in command-line order.
const SheetOp = union(enum) {
    pick: usize,
    back,
    fill: []const u8,
    filter: []const u8,
    insert: []const u8,
};

/// One row of a tool sheet (CDL `vocabulary`) as the GUI holds it. Picking a row appends its
/// tokens to the node's argv; `takes` marks the value slot (the named slot rule in
/// `docs/CDL.md` — last token's `<...>` span, else the last token, else one appended element).
const SheetEntry = struct {
    kind: []const u8, // "subcommand" | "option" | "note"
    tokens: []const []const u8 = &.{},
    label: []const u8 = "",
    desc: []const u8 = "",
    takes: []const u8 = "", // "" | file | directory | text | number | enum
    options: []const []const u8 = &.{},
    children: []const SheetEntry = &.{},
};

/// A preset (CDL action) as the tool sheet offers it: a pre-assembled command template.
const SheetPreset = struct {
    name: []const u8,
    label: []const u8,
    exe: []const u8,
    args: []const []const u8 = &.{},
    /// `{name}` placeholders the template may reference, with their defaults ("" when none).
    vars: []const SheetVar = &.{},
};

const SheetVar = struct { name: []const u8, default: []const u8 };

/// A value slot waiting to be filled after a pick with `takes`. The slot is bound to the argv
/// revision it was created at: any argv edit made elsewhere dismisses it instead of silently
/// filling the wrong element (rule 2 — no rewriting the user's bytes behind their back).
const SheetSlot = struct {
    argv_idx: usize,
    serial: u32,
    /// `.span` replaces the first `<...>` span inside the element; `.replace` replaces it whole.
    mode: enum { span, replace },
    span_start: usize = 0,
    span_len: usize = 0,
    takes: []const u8,
    options: []const []const u8 = &.{},
    label: []const u8 = "",
};

/// The first `<...>` span inside a token — where the author put the value slot (the named slot
/// rule in `docs/CDL.md`). Returns the span bounds including the brackets; null when the token
/// carries no slot, which is what makes the rule's third case (an appended element) possible.
fn findSlotSpan(tok: []const u8) ?[2]usize {
    const open = std.mem.indexOfScalar(u8, tok, '<') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, tok, open + 1, '>') orelse return null;
    return .{ open, close - open + 1 };
}

/// Case-insensitive substring match for the tool sheet's filter box.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn parseSheetEntries(a: std.mem.Allocator, arr: []const pipelith.value.Value) []const SheetEntry {
    var list: std.ArrayListUnmanaged(SheetEntry) = .empty;
    for (arr) |item| {
        if (parseSheetEntry(a, item)) |e| list.append(a, e) catch break;
    }
    return list.items;
}

fn parseSheetEntry(a: std.mem.Allocator, v: pipelith.value.Value) ?SheetEntry {
    const kind = (v.field("kind") orelse return null).asString() orelse return null;
    var e = SheetEntry{ .kind = kind };
    if (v.field("tokens")) |tv| {
        if (tv.asArray()) |arr| {
            var toks: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |t| {
                if (t.asString()) |s| toks.append(a, s) catch break;
            }
            e.tokens = toks.items;
        }
    }
    e.label = if (v.field("label")) |x| (x.asString() orelse "") else "";
    e.desc = if (v.field("description")) |x| (x.asString() orelse "") else "";
    e.takes = if (v.field("takes")) |x| (x.asString() orelse "") else "";
    if (v.field("options")) |ov| {
        if (ov.asArray()) |arr| {
            var opts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |t| {
                if (t.asString()) |s| opts.append(a, s) catch break;
            }
            e.options = opts.items;
        }
    }
    if (v.field("children")) |cv| {
        if (cv.asArray()) |arr| e.children = parseSheetEntries(a, arr);
    }
    return e;
}

fn parseSheetPreset(a: std.mem.Allocator, v: pipelith.value.Value, base_vars: []const SheetVar) ?SheetPreset {
    const name = (v.field("name") orelse return null).asString() orelse return null;
    var p = SheetPreset{
        .name = name,
        .label = if (v.field("label")) |x| (x.asString() orelse name) else name,
        .exe = if (v.field("executable")) |x| (x.asString() orelse "") else "",
    };
    if (v.field("args")) |av| {
        if (av.asArray()) |arr| {
            var args: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |item| {
                if (item.asString()) |s| {
                    args.append(a, s) catch break;
                    continue;
                }
                // The `var` form is a placeholder for that variable; keep it in `{name}` shape so
                // the same expansion rule applies to both forms.
                if (item.field("var")) |vv| {
                    if (vv.asString()) |vn| {
                        if (std.fmt.allocPrint(a, "{{{s}}}", .{vn})) |z| {
                            args.append(a, z) catch break;
                        } else |_| {}
                        continue;
                    }
                }
                const val = if (item.field("value")) |x| (x.asString() orelse "") else "";
                args.append(a, val) catch break;
            }
            p.args = args.items;
        }
    }
    // The template's variables: document-level inputs/outputs first, then the action's own.
    var vars: std.ArrayListUnmanaged(SheetVar) = .empty;
    vars.appendSlice(a, base_vars) catch return p;
    if (v.field("variables")) |vv| {
        if (vv.asArray()) |arr| {
            for (arr) |item| {
                const n = (item.field("name") orelse continue).asString() orelse continue;
                const d = if (item.field("default")) |x| (x.asString() orelse "") else "";
                vars.append(a, .{ .name = n, .default = d }) catch break;
            }
        }
    }
    p.vars = vars.items;
    return p;
}

// ── flow graph (the canvas) ──────────────────────────────────────────────────
// Mirrors the engine's wire contract (src/graph.zig): nodes are {id, cdl, action, title, values},
// edges are {from, to, fromPort, toPort, kind}. Nothing is sent to the engine yet; `flow.build`
// will serialize this shape when the run panel lands.

const EdgeKind = pipelith.graph.EdgeKind;

const ValueMap = std.StringArrayHashMapUnmanaged([]const u8);

const GNode = struct {
    id: []const u8,
    cdl: []const u8,
    action: []const u8,
    title: []const u8,
    category: []const u8,
    x: f32,
    y: f32,
    w: f32 = 230,
    h: f32 = 104,
    /// variable name -> value. Keys are owned by graph_arena; values are gpa-owned and must be
    /// freed on replacement (see App.setValue) so typing does not grow an arena without bound.
    values: ValueMap = .empty,
    /// Port plan derived from the action's stream modes: `stdin: none` drops the stdin port and
    /// `stdout: discard` drops the stdout port — the same rule as web/form.js `portPlan`.
    has_stdin: bool = true,
    has_stdout: bool = true,
    /// Carried through open → save unchanged. The native UI has no widgets for these yet, but
    /// dropping them would silently rewrite a flow authored elsewhere (or by the web frontend), so
    /// they round-trip even while uneditable.
    disabled: bool = false,
    timeout_ms: ?u64 = null,
    retry: u32 = 0,
    note: []const u8 = "",
    /// Overrides the action's executable (graph.Node.executable). Without carrying it the GUI would
    /// rewrite an overridden node back to the CDL's default program on save.
    executable: []const u8 = "",
    /// Free-form command; non-empty makes this a *raw command* node, which needs no CDL at all
    /// (graph.Node.argv). The slice and its strings are owned by graph_arena.
    argv: []const []const u8 = &.{},
    /// Run state, updated from the engine's node.* events.
    status: NodeStatus = .idle,
    exit_code: ?i32 = null,
    duration_ms: u64 = 0,
};

/// One line in the output panel. Text and node id are gpa-owned so the ring can evict them.
const OutLine = struct {
    node: []const u8,
    stream: StreamKind,
    text: []const u8,
};

const PreviewCmd = struct { id: []const u8, display: []const u8 };

/// One action of the selected node's CDL, for the inspector's action selector.
const ActionRef = struct { name: []const u8, label: []const u8 };

/// Bounded log ring. A plain ArrayList with an O(n) shift on every line would be quadratic under
/// a chatty command, so this keeps a fixed slice plus a head index.
const log_capacity = 1024;

const Option = struct { value: []const u8, label: []const u8 };

/// One CDL variable, shaped for the inspector. Field names mirror the `cdl.get` wire form.
const VarSpec = struct {
    name: []const u8,
    label: []const u8,
    vtype: []const u8 = "text",
    required: bool = false,
    default: []const u8 = "",
    placeholder: []const u8 = "",
    multiline: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    save: bool = false,
    description: []const u8 = "",
    options: []const Option = &.{},
    filters: []const []const u8 = &.{},
};

/// True when the value parses as a number (the engine keeps every value stringified).
fn asNumber(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn truthy(s: []const u8) bool {
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "1");
}

// ── run state ────────────────────────────────────────────────────────────────

/// Mirrors `engine.NodeStatus` (wire: pending/running/success/failed/skipped/cancelled/timedOut).
const NodeStatus = enum {
    idle,
    pending,
    running,
    success,
    failed,
    skipped,
    cancelled,
    timed_out,

    fn parse(s: []const u8) NodeStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "success")) return .success;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, s, "timedOut") or std.mem.eql(u8, s, "timed_out")) return .timed_out;
        return .idle;
    }

    fn label(self: NodeStatus, lang: Lang) [:0]const u8 {
        return switch (self) {
            .idle => StrKey.status_idle.get(lang),
            .pending => StrKey.status_pending.get(lang),
            .running => StrKey.status_running.get(lang),
            .success => StrKey.status_success.get(lang),
            .failed => StrKey.status_failed.get(lang),
            .skipped => StrKey.status_skipped.get(lang),
            .cancelled => StrKey.status_cancelled.get(lang),
            .timed_out => StrKey.status_timed_out.get(lang),
        };
    }

    fn tint(self: NodeStatus, p: theme.Palette) c_uint {
        return switch (self) {
            .idle, .pending, .skipped => p.status_idle,
            .running => p.status_running,
            .success => p.status_success,
            .failed => p.status_failed,
            .cancelled, .timed_out => p.warn,
        };
    }
};

const StreamKind = enum {
    stdout,
    stderr,
    system,

    fn parse(s: []const u8) StreamKind {
        if (std.mem.eql(u8, s, "stdout")) return .stdout;
        if (std.mem.eql(u8, s, "stderr")) return .stderr;
        return .system;
    }

    fn tint(self: StreamKind, p: theme.Palette) c_uint {
        return switch (self) {
            .stdout => p.text,
            .stderr => p.danger,
            .system => p.text_dim,
        };
    }
};

const GEdge = struct {
    from: []const u8,
    to: []const u8,
    from_port: []const u8,
    to_port: []const u8,
    kind: EdgeKind,
};

// ── undo / redo ──────────────────────────────────────────────────────────────
// State-based history: each entry is a full graph snapshot in its own arena, and a cursor marks the
// current state. At this scale (a flow holds tens of nodes) snapshots are far cheaper to get right
// than inverse commands, and they make every mutation one line: mutate, then `commit()`.

const history_capacity = 64;

const ValueSnap = struct { key: []const u8, value: []const u8 };

const NodeSnap = struct {
    id: []const u8,
    cdl: []const u8,
    action: []const u8,
    title: []const u8,
    category: []const u8,
    x: f32,
    y: f32,
    has_stdin: bool,
    has_stdout: bool,
    disabled: bool = false,
    timeout_ms: ?u64 = null,
    retry: u32 = 0,
    note: []const u8 = "",
    executable: []const u8 = "",
    argv: []const []const u8 = &.{},
    values: []ValueSnap,
};

const EdgeSnap = struct {
    from: []const u8,
    to: []const u8,
    from_port: []const u8,
    to_port: []const u8,
    kind: EdgeKind,
};

const HistoryEntry = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []NodeSnap = &.{},
    edges: []EdgeSnap = &.{},
    next_node: u32 = 1,
    /// Workflow name at this state, so renaming is undoable like every other mutation.
    name: []const u8 = "",
};

/// Which rail a port sits on, and which edge kind it carries.
const PortSide = enum { left, right };
const PortKind = enum { pipe, seq };

/// A port under the pointer, in screen space.
const PortHit = struct {
    node: usize,
    side: PortSide,
    kind: PortKind,
    x: f32,
    y: f32,
};

/// Vertical offset of a port inside a node card; the same rows the dots are painted on.
fn portOffset(kind: PortKind) f32 {
    return if (kind == .pipe) 40 else 74;
}

/// Category colours, matching the web design system's per-category accents.
fn categoryTint(category: []const u8, p: theme.Palette) c_uint {
    const map = .{
        .{ "media", rgba(236, 132, 164, 255) },
        .{ "development", rgba(120, 170, 255, 255) },
        .{ "data", rgba(150, 200, 130, 255) },
        .{ "network", rgba(120, 200, 210, 255) },
        .{ "system", rgba(230, 180, 90, 255) },
        .{ "science", rgba(190, 150, 240, 255) },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, category, entry[0])) return entry[1];
    }
    return p.text_dim;
}

fn edgeTint(kind: EdgeKind, p: theme.Palette) c_uint {
    return switch (kind) {
        .pipe => p.edge_pipe,
        .seq => p.edge_seq,
        else => p.warn,
    };
}

const max_items = 256;
const max_marked = 64;
const max_packs = 32;

/// One available tool pack, as the library lists it. A pack is only *available*: its tools become
/// real when the user installs it, and installing writes them into the user's own CDL directory
/// (where they stay editable), which is the one directory the engine loads tools from.
const PackItem = struct {
    id: []const u8,
    label: []const u8,
    desc: []const u8 = "",
    /// Which named directory the pack was found in (`exe-dir` / `state-dir`) — a pack is always an
    /// external file, so this is what tells a shipped pack from one the user dropped in `.pipelith`.
    source: []const u8 = "",
    tools: usize = 0,
    /// Tool files already present with the pack's own bytes.
    installed: usize = 0,
    /// Tool files present with different bytes — the user's own version, which a pack never replaces.
    modified: usize = 0,
    complete: bool = false,
};

/// Why the command line does not currently parse. The argv keeps its previous value in every case
/// (rule 3: an ambiguous line is reported, never reinterpreted).
const CmdLineError = enum { none, unterminated_quote, trailing_backslash };

/// Localized name of a theme, for the toggle button. Lives here rather than in theme.zig so the
/// palette module stays independent of the string catalogue.
fn themeLabelKey(k: theme.Kind) StrKey {
    return switch (k) {
        .dark => .theme_dark,
        .light => .theme_light,
    };
}

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    svc: *rpc.Service,
    sink: *Sink,

    search: [128]u8 = std.mem.zeroes([128]u8),
    category: [64]u8 = std.mem.zeroes([64]u8),
    category_len: usize = 0,
    categories: [10][]const u8 = undefined,
    category_count: usize = 0,
    items: [max_items]Item = undefined,
    item_count: usize = 0,
    list_arena: std.heap.ArenaAllocator,
    /// Every tool the engine holds, before the search/category filter. The difference between this
    /// and `item_count` is what tells "no tools are installed yet" (the state of a fresh
    /// installation) apart from "this filter matched nothing" — the two need different words.
    tool_total: usize = 0,

    // ── tool packs (available, installed on request) ───────────────────────
    packs: [max_packs]PackItem = undefined,
    pack_count: usize = 0,
    /// Directories the engine looks for packs in, as reported by `pack.list` — shown when there is no
    /// pack at all, so the user can see exactly where one may be put.
    pack_dirs: [6][]const u8 = undefined,
    pack_dir_count: usize = 0,
    pack_arena: std.heap.ArenaAllocator,
    /// Result of the last install, shown under the pack list: the tool names that were written, or
    /// the ones that were kept because the user's own copy differs.
    pack_status: [192]u8 = std.mem.zeroes([192]u8),
    pack_status_len: usize = 0,
    pack_status_key: StrKey = .pack_loaded,

    flow_title: [:0]const u8 = "",
    /// Workflow name backing the inspector's name field. Held in a fixed buffer so the ImGui text
    /// field has stable storage across frames; empty means "unnamed" (the placeholder shows).
    flow_name: [128]u8 = std.mem.zeroes([128]u8),
    /// True only while `flow_title` points at a heap copy; the untitled label is a literal.
    flow_title_owned: bool = false,
    /// UI language and theme. `pal` is the resolved palette the canvas draws with.
    lang: Lang = .zh,
    theme_kind: theme.Kind = .dark,
    pal: theme.Palette = theme.dark,
    version: []const u8 = "",
    /// True only when `version` was duplicated with gpa; freeing the literal default would be UB.
    version_owned: bool = false,
    engine_ok: bool = false,

    // ── canvas / flow graph ──
    graph_arena: std.heap.ArenaAllocator,
    nodes: std.ArrayListUnmanaged(GNode) = .empty,
    edges: std.ArrayListUnmanaged(GEdge) = .empty,
    next_node: u32 = 1,
    selected: ?usize = null,
    /// Multi-selection, held as node **ids** rather than indices: deleting a node renumbers every
    /// index after it, so an index set would silently start pointing at the wrong nodes. `selected`
    /// is the inspector's node and is always a member when it is set. Ids live in graph_arena.
    marked: [max_marked][]const u8 = undefined,
    marked_count: usize = 0,
    /// Copy buffer: the selected subgraph serialized in the `.flow` shape, so paste can go through
    /// the engine's own loader instead of a second, parallel format. gpa-owned.
    clipboard: ?[]u8 = null,
    /// Pointer travel during the current empty-canvas drag: a click clears the selection, a pan must
    /// not, and the distance is the only thing that distinguishes them.
    bg_travel: f32 = 0,
    /// User tool open in the source editor (its name), and the working copy of its text. A user tool
    /// is a plain CDL file, so "editable" means exactly this: the document, not a form that can only
    /// express part of it.
    editing_tool: ?[]const u8 = null,
    edit_source: []u8 = &.{},
    edit_error: []const u8 = "",
    /// One-line command editor state. `cmd_line` holds the text **as the user typed it** — it is
    /// never re-rendered from argv while being edited, because the line and argv only round-trip
    /// once the line is complete (an open quote or a trailing backslash is not argv yet). It is
    /// re-seeded from argv only when the node changes or argv changed behind the editor's back,
    /// which `argv_serial` makes precise.
    cmd_line: [2048]u8 = std.mem.zeroes([2048]u8),
    cmd_line_for: ?usize = null,
    cmd_line_serial: u32 = 0,
    /// Bumped on every argv mutation; the line editor compares it against `cmd_line_serial`.
    argv_serial: u32 = 0,
    cmd_line_error: CmdLineError = .none,
    // ── tool sheet (CDL `vocabulary`) of the tool a free command is bound to ──
    /// The tool the sheet below belongs to ("" = no sheet; a command node keeps its binding in
    /// `GNode.cdl`, which round-trips through `.flow` and means nothing to the engine).
    sheet_tool: []const u8 = "",
    sheet_root: []const SheetEntry = &.{},
    sheet_presets: []const SheetPreset = &.{},
    /// Drill-down path into `children`, as indices into each level's entry list.
    sheet_depth: usize = 0,
    sheet_path: [8]usize = [8]usize{ 0, 0, 0, 0, 0, 0, 0, 0 },
    sheet_filter: [128]u8 = std.mem.zeroes([128]u8),
    sheet_slot: ?SheetSlot = null,
    /// Pending text for a text/number value slot.
    sheet_slot_text: [512]u8 = std.mem.zeroes([512]u8),
    view_pan_x: f32 = 28,
    view_pan_y: f32 = 20,
    view_zoom: f32 = 1,

    // ── inspector form for the selected node ──
    form_node: ?usize = null,
    form_loaded: bool = false,
    form_vars: [48]VarSpec = undefined,
    form_var_count: usize = 0,
    form_action_label: []const u8 = "",
    form_actions: [32]ActionRef = undefined,
    form_action_count: usize = 0,
    form_desc: []const u8 = "",
    form_danger: bool = false,
    /// The selected action's own executable, shown next to the override field so it is obvious what
    /// the node will run when the override is empty.
    form_exe_default: []const u8 = "",
    /// Last non-fatal message from an interaction (e.g. the native picker being unavailable).
    form_status: [:0]const u8 = "",

    // ── run / output ──
    /// Fixed-capacity ring of output lines (see pushLog); empty until the first line arrives.
    log: []OutLine = &.{},
    log_head: usize = 0,
    log_count: usize = 0,
    last_log_count: usize = 0,
    running: bool = false,
    run_id: []const u8 = "",
    run_status: NodeStatus = .idle,
    run_duration_ms: u64 = 0,
    run_error: []const u8 = "",
    /// -1 = the "all nodes" tab, otherwise a node index.
    output_tab: i32 = -1,
    autoscroll: bool = true,
    scroll_pending: bool = false,

    // ── undo/redo + canvas interaction ──
    history: [history_capacity]?HistoryEntry = @splat(null),
    history_len: usize = 0,
    history_cursor: usize = 0,
    /// Node currently being dragged; committed (one undo step) when the drag ends.
    dragging_node: ?usize = null,
    /// Port the user is dragging a connection from.
    drag_from: ?PortHit = null,
    /// Transient status-bar message (connection feedback, undo/redo).
    hint_text: [:0]const u8 = "",
    hint_frames: u32 = 0,
    /// Disabled for scripted verification runs so they neither read nor write the autosave, which
    /// keeps those runs hermetic and deterministic. Also gates the preferences file.
    autosave_enabled: bool = true,
    /// Library → canvas drag in progress (index into `items`) and whether it has moved far enough to
    /// count as a drag rather than a click.
    drag_tool: ?usize = null,
    drag_moved: bool = false,
    /// Canvas viewport in screen space, captured each frame so the toolbar and drag-and-drop can map
    /// screen → world without re-deriving the layout.
    canvas_rect: [4]f32 = .{ 0, 0, 0, 0 },
    /// Set by Ctrl+F; consumed by the search box on the next frame (SetKeyboardFocusHere applies to
    /// the next widget submitted, and nothing is mid-submission inside the shortcut handler).
    focus_search: bool = false,
    /// User tool awaiting a second click on "delete", so a single stray click cannot remove one.
    tool_pending_delete: ?[]const u8 = null,

    fn init(gpa: std.mem.Allocator, io: Io, svc: *rpc.Service, sink: *Sink) App {
        var app = App{
            .gpa = gpa,
            .io = io,
            .svc = svc,
            .sink = sink,
            .list_arena = std.heap.ArenaAllocator.init(gpa),
            .pack_arena = std.heap.ArenaAllocator.init(gpa),
            .graph_arena = std.heap.ArenaAllocator.init(gpa),
        };
        app.flow_title = StrKey.untitled_workflow.get(app.lang);
        return app;
    }

    /// Translated string, ready to hand straight to the C ABI.
    fn tr(self: *App, key: StrKey) [*:0]const u8 {
        return key.get(self.lang).ptr;
    }

    /// Translated string as a slice, for storing in state or comparing.
    fn trs(self: *App, key: StrKey) []const u8 {
        return std.mem.span(self.tr(key));
    }

    /// Pushes the current palette into the widget style and remembers the frame clear colour.
    fn applyTheme(self: *App) void {
        self.pal = theme.of(self.theme_kind);
        const p = self.pal;
        pl_gui_apply_theme(
            p.bg,
            p.panel,
            p.sunken,
            p.border,
            p.text,
            p.text_dim,
            p.accent,
            if (self.theme_kind == .light) 1 else 0,
        );
    }

    fn toggleLang(self: *App) void {
        self.lang = self.lang.other();
        // Only the *untitled* placeholder follows the language. A workflow the user actually named
        // keeps its name, which is why the owned flag is checked rather than overwriting blindly.
        if (self.flowName().len == 0) self.flow_title = StrKey.untitled_workflow.get(self.lang);
    }

    fn flowName(self: *App) []const u8 {
        return std.mem.sliceTo(&self.flow_name, 0);
    }

    /// Rebuilds the displayed title from the name buffer. Separate from `setFlowName` because the
    /// ImGui field writes into the buffer in place, and copying a slice onto itself is undefined.
    fn syncFlowTitle(self: *App) void {
        const name = self.flowName();
        if (name.len == 0) {
            if (self.flow_title_owned) self.gpa.free(self.flow_title);
            self.flow_title_owned = false;
            self.flow_title = StrKey.untitled_workflow.get(self.lang);
            return;
        }
        const copy = self.gpa.allocSentinel(u8, name.len, 0) catch return;
        @memcpy(copy, name);
        if (self.flow_title_owned) self.gpa.free(self.flow_title);
        self.flow_title = copy;
        self.flow_title_owned = true;
    }

    /// Sets the workflow name from an external string (open, new, history restore).
    fn setFlowName(self: *App, s: []const u8) void {
        const n = @min(s.len, self.flow_name.len - 1);
        @memcpy(self.flow_name[0..n], s[0..n]);
        self.flow_name[n] = 0;
        self.syncFlowTitle();
    }

    /// ArrayListUnmanaged needs its backing memory released explicitly, and the arenas own every
    /// string the RPC layer and the graph handed back. Without this the debug allocator reports
    /// the CDL list and the graph as leaked at exit.
    fn deinit(self: *App) void {
        self.clearLog();
        if (self.log.len > 0) self.gpa.free(self.log);
        // History entries own their snapshots' arenas.
        for (&self.history) |*slot| self.freeEntry(slot);
        // Per-node value strings are gpa-owned, so release them before the list itself.
        for (self.nodes.items, 0..) |_, i| self.freeNodeValues(i);
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        if (self.version_owned) self.gpa.free(self.version);
        if (self.flow_title_owned) self.gpa.free(self.flow_title);
        if (self.clipboard) |cb| self.gpa.free(cb);
        if (self.edit_source.len > 0) self.gpa.free(self.edit_source);
        self.list_arena.deinit();
        self.pack_arena.deinit();
        self.graph_arena.deinit();
    }

    /// Adds a node for a library item at the next free grid slot (the click-to-add path).
    fn addNode(self: *App, item: Item) void {
        const col = self.nodes.items.len % 2;
        const row = self.nodes.items.len / 2;
        self.addNodeAt(
            item,
            @as(f32, @floatFromInt(col)) * 270,
            @as(f32, @floatFromInt(row)) * 150,
        );
    }

    /// Adds a node for a library item at an explicit world position (the drag-and-drop path).
    fn addNodeAt(self: *App, item: Item, wx: f32, wy: f32) void {
        const a = self.graph_arena.allocator();
        const id = std.fmt.allocPrint(a, "n{d}", .{self.next_node}) catch return;
        self.next_node += 1;
        self.nodes.append(self.gpa, .{
            .id = id,
            .cdl = a.dupe(u8, item.name) catch return,
            .action = a.dupe(u8, item.action_name) catch return,
            .title = a.dupe(u8, if (item.action_label.len > 0) item.action_label else item.display) catch return,
            .category = a.dupe(u8, item.category) catch return,
            .x = wx,
            .y = wy,
        }) catch return;
        self.selected = self.nodes.items.len - 1;
        // Fill the CDL defaults immediately: it keeps a node self-describing for the canvas body and
        // makes a saved file self-contained instead of depending on the node having been selected.
        self.fetchSpec(self.selected.?);
        self.commit();
    }

    /// Adds a **free command** node for a library tool — the primary way a tool enters the canvas.
    /// The node starts as the tool's program and stays bound to the tool (`GNode.cdl` names the
    /// sheet) so the inspector offers the tool's vocabulary to pick from. A tool is a command
    /// surface, not a menu of fixed actions: actions are presets on top of this.
    fn addFreeNode(self: *App, item: Item) void {
        const col = self.nodes.items.len % 2;
        const row = self.nodes.items.len / 2;
        self.addFreeNodeAt(
            item,
            @as(f32, @floatFromInt(col)) * 270,
            @as(f32, @floatFromInt(row)) * 150,
        );
    }

    fn addFreeNodeAt(self: *App, item: Item, wx: f32, wy: f32) void {
        const a = self.graph_arena.allocator();
        const id = std.fmt.allocPrint(a, "n{d}", .{self.next_node}) catch return;
        self.next_node += 1;
        const prog = if (item.exe.len > 0) item.exe else item.name;
        const argv = a.alloc([]const u8, 1) catch return;
        argv[0] = a.dupe(u8, prog) catch return;
        self.nodes.append(self.gpa, .{
            .id = id,
            .cdl = a.dupe(u8, item.name) catch return,
            .action = "",
            .title = a.dupe(u8, item.display) catch return,
            .category = a.dupe(u8, item.category) catch return,
            .x = wx,
            .y = wy,
            .has_stdin = true,
            .has_stdout = true,
            .argv = argv,
        }) catch return;
        self.selected = self.nodes.items.len - 1;
        self.form_loaded = false;
        self.commit();
        self.hint(.command_added);
    }

    /// Clones a node (values included) next to the original. The value entries are copied out before
    /// the list is appended to: `append` may reallocate, which would leave an iterator dangling.
    fn duplicateNode(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        var vals: [64]ValueSnap = undefined;
        var nvals: usize = 0;
        var it = self.nodes.items[idx].values.iterator();
        while (it.next()) |e| {
            if (nvals >= vals.len) break;
            vals[nvals] = .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
            nvals += 1;
        }
        const src = self.nodes.items[idx];

        const a = self.graph_arena.allocator();
        const id = std.fmt.allocPrint(a, "n{d}", .{self.next_node}) catch return;
        self.next_node += 1;
        self.nodes.append(self.gpa, .{
            .id = id,
            .cdl = src.cdl,
            .action = src.action,
            .title = src.title,
            .category = src.category,
            .x = src.x + 34,
            .y = src.y + 34,
            .has_stdin = src.has_stdin,
            .has_stdout = src.has_stdout,
        }) catch return;
        const new_idx = self.nodes.items.len - 1;
        for (vals[0..nvals]) |v| self.setValue(new_idx, v.key, v.value);

        self.selected = new_idx;
        self.form_loaded = false;
        self.commit();
        self.hint(.node_duplicated);
    }

    /// Single place for the zoom clamp, so the toolbar, the shortcuts and the tests cannot drift.
    fn zoomBy(self: *App, factor: f32) void {
        self.view_zoom = std.math.clamp(self.view_zoom * factor, 0.35, 2.5);
    }

    /// Frames the whole graph inside the canvas viewport.
    fn fitView(self: *App) void {        if (self.nodes.items.len == 0) {
            self.view_pan_x = 28;
            self.view_pan_y = 20;
            self.view_zoom = 1;
            return;
        }
        var minx: f32 = std.math.floatMax(f32);
        var miny: f32 = std.math.floatMax(f32);
        var maxx: f32 = -std.math.floatMax(f32);
        var maxy: f32 = -std.math.floatMax(f32);
        for (self.nodes.items) |n| {
            minx = @min(minx, n.x);
            miny = @min(miny, n.y);
            maxx = @max(maxx, n.x + n.w);
            maxy = @max(maxy, n.y + n.h);
        }
        const r = self.canvas_rect;
        const w = @max(r[2] - r[0], 100);
        const h = @max(r[3] - r[1], 100);
        const pad: f32 = 48;
        const zx = (w - pad) / @max(maxx - minx, 1);
        const zy = (h - pad) / @max(maxy - miny, 1);
        self.view_zoom = std.math.clamp(@min(zx, zy), 0.35, 2.5);
        const z = self.view_zoom;
        self.view_pan_x = (w / z - (maxx - minx)) / 2 - minx;
        self.view_pan_y = (h / z - (maxy - miny)) / 2 - miny;
    }

    /// Layered auto layout, mirroring web/model.js `autoLayout` + `topoOrder` exactly: nodes are
    /// layered by **sequential** (`seq`) edges only — a pipe edge means data flow, not ordering, so
    /// it must not constrain the grid — then placed left → right by layer and top → bottom within a
    /// layer. Nodes inside a cycle never reach in-degree 0, so they are parked in a trailing column
    /// in their original order. One `commit()` makes the whole rearrangement a single undo step.
    fn autoLayout(self: *App) void {
        const n = self.nodes.items.len;
        if (n == 0) return;

        // Scratch is allocated per call rather than kept in the struct: nodes are an unbounded list
        // (the 256 cap applies to the *library*), and this runs once per button click.
        const indeg = self.gpa.alloc(u32, n) catch return;
        defer self.gpa.free(indeg);
        const layer_of = self.gpa.alloc(usize, n) catch return;
        defer self.gpa.free(layer_of);
        const placed = self.gpa.alloc(bool, n) catch return;
        defer self.gpa.free(placed);
        @memset(indeg, 0);
        @memset(layer_of, 0);
        @memset(placed, false);

        for (self.edges.items) |e| {
            if (e.kind != .seq) continue;
            const to = self.nodeById(e.to) orelse continue;
            if (self.nodeById(e.from) == null) continue;
            indeg[to] += 1;
        }

        // Kahn's algorithm, one layer per frontier. The frontier is collected *before* any in-degree
        // is decremented: doing both in one pass would let a successor whose last in-edge is removed
        // by an earlier member of the same frontier join that same layer, collapsing the grid.
        const frontier = self.gpa.alloc(usize, n) catch return;
        defer self.gpa.free(frontier);

        var layer: usize = 0;
        var remaining = n;
        while (remaining > 0) {
            var fcount: usize = 0;
            for (0..n) |i| {
                if (placed[i] or indeg[i] != 0) continue;
                frontier[fcount] = i;
                fcount += 1;
            }
            // Nothing reached in-degree 0: every remaining node is in a cycle. Stop, so the trailing
            // column below picks them up instead of spinning.
            if (fcount == 0) break;

            for (frontier[0..fcount]) |i| {
                placed[i] = true;
                layer_of[i] = layer;
                remaining -= 1;
            }
            for (frontier[0..fcount]) |i| {
                for (self.edges.items) |e| {
                    if (e.kind != .seq) continue;
                    if (!std.mem.eql(u8, e.from, self.nodes.items[i].id)) continue;
                    if (self.nodeById(e.to)) |to| {
                        if (indeg[to] > 0) indeg[to] -= 1;
                    }
                }
            }
            layer += 1;
        }

        // Same spacing as the web implementation (paddingX/paddingY/origin).
        const pad_x: f32 = 300;
        const pad_y: f32 = 190;
        const origin_x: f32 = 60;
        const origin_y: f32 = 60;

        // Row cursor per layer, so each layer stacks from the top independently. Layer count is
        // bounded by the node count, hence `layer_of`'s length is a safe upper bound for the keys.
        const rows = self.gpa.alloc(usize, n) catch return;
        defer self.gpa.free(rows);
        @memset(rows, 0);
        for (0..n) |i| {
            if (!placed[i]) continue;
            const li = layer_of[i];
            const row = rows[li];
            rows[li] += 1;
            self.nodes.items[i].x = origin_x + @as(f32, @floatFromInt(li)) * pad_x;
            self.nodes.items[i].y = origin_y + @as(f32, @floatFromInt(row)) * pad_y;
        }

        // Anything unplaced is in a cycle: park it in the column after the last real one.
        var extra: usize = 0;
        var max_layer: usize = 0;
        for (0..n) |i| {
            if (placed[i]) max_layer = @max(max_layer, layer_of[i] + 1);
        }
        for (0..n) |i| {
            if (placed[i]) continue;
            self.nodes.items[i].x = origin_x + @as(f32, @floatFromInt(max_layer)) * pad_x;
            self.nodes.items[i].y = origin_y + @as(f32, @floatFromInt(extra)) * pad_y;
            extra += 1;
        }

        self.commit();
        self.hint(.layout_applied);
    }

    /// Library → canvas drag-and-drop, driven from raw mouse state rather than ImGui's drag-drop
    /// API: the canvas already hit-tests that way, and the payload never leaves the process.
    fn drawToolDrag(self: *App) void {
        const idx = self.drag_tool orelse return;
        var mx: f32 = 0;
        var my: f32 = 0;
        pl_gui_mouse_pos(&mx, &my);

        if (pl_gui_mouse_down(1) == 1) {
            if (!self.drag_moved) {
                var dx: f32 = 0;
                var dy: f32 = 0;
                pl_gui_mouse_delta(&dx, &dy);
                // A small threshold keeps a click from registering as a drag.
                if (@abs(dx) + @abs(dy) > 1.2) self.drag_moved = true;
            }
            if (self.drag_moved and idx < self.item_count) {
                var gb: [160]u8 = undefined;
                pl_gui_dl_rect_filled(mx + 12, my + 10, mx + 190, my + 34, self.pal.sunken, 6, 0);
                pl_gui_dl_rect(mx + 12, my + 10, mx + 190, my + 34, self.pal.accent, 6, 1);
                pl_gui_dl_text(mx + 20, my + 15, self.pal.text, fmtZ(&gb, "+ {s}", .{self.items[idx].display}));
            }
            return;
        }

        // Released: a drop inside the canvas adds the node where the pointer is.
        const moved = self.drag_moved;
        self.drag_tool = null;
        self.drag_moved = false;
        if (!moved or idx >= self.item_count) return;

        const r = self.canvas_rect;
        if (mx < r[0] or mx > r[2] or my < r[1] or my > r[3]) return;
        // Offset by half a card so the node lands centred under the cursor.
        const wx = (mx - r[0]) / self.view_zoom - self.view_pan_x - 110;
        const wy = (my - r[1]) / self.view_zoom - self.view_pan_y - 40;
        self.addFreeNodeAt(self.items[idx], wx, wy);
    }

    /// Connects two nodes with the edge kind that matches their ports, refusing duplicates and
    /// self-loops. Kept next to addNode so the canvas has a real graph to draw in --demo runs.
    /// Adds an edge. Returns false when the connection is a duplicate or a self-loop, so callers can
    /// report why nothing happened.
    fn connect(self: *App, from_id: []const u8, to_id: []const u8, kind: EdgeKind) bool {
        if (std.mem.eql(u8, from_id, to_id)) return false;
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from, from_id) and std.mem.eql(u8, e.to, to_id) and e.kind == kind) return false;
        }
        // The ids are already owned by graph_arena (they come from addNode), so nothing is copied.
        self.edges.append(self.gpa, .{
            .from = from_id,
            .to = to_id,
            .from_port = if (kind == .pipe) "stdout" else "done",
            .to_port = if (kind == .pipe) "stdin" else "run",
            .kind = kind,
        }) catch return false;
        self.commit();
        return true;
    }

    fn nodeById(self: *App, id: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.id, id)) return i;
        }
        return null;
    }

    /// Seeds a small graph so the canvas can be verified without an interactive click.
    ///
    /// The nodes are **free commands** — argv with no tool binding. The program ships no tool
    /// definition, so a fixture that needed the library would render an empty canvas on a fresh
    /// installation; commands always work, which is also the model the canvas is built on
    /// One pipe edge and one sequence edge are wired between them, so both edge
    /// kinds are visible.
    fn seedDemo(self: *App) void {
        _ = self.addRawNodeAt(&.{ "git", "log", "--oneline", "-n", "20" }, "git log", 0, 0);
        _ = self.addRawNodeAt(&.{ "grep", "-i", "fix" }, "grep -i", 300, 0);
        // Interleaved exactly like the graph the verification ladder expects: each add and each
        // connection closes its own undo step, so one undo drops the last edge and two drop the third
        // node (see the ladder in `dev/test-native-gui.mjs`).
        if (self.nodes.items.len >= 2) _ = self.connect(self.nodes.items[0].id, self.nodes.items[1].id, .pipe);
        _ = self.addRawNodeAt(&.{ "wc", "-l" }, "wc -l", 0, 170);
        if (self.nodes.items.len >= 3) _ = self.connect(self.nodes.items[0].id, self.nodes.items[2].id, .seq);
        // Select the first node so the inspector shows a populated form in --demo runs.
        self.selected = if (self.nodes.items.len > 0) 0 else null;
    }

    // ── node values ─────────────────────────────────────────────────────────

    /// Every stored value is gpa-owned so the old one can be released on replacement; leaking each
    /// keystroke into the graph arena would grow it without bound while typing.
    fn setValue(self: *App, idx: usize, name: []const u8, value: []const u8) void {
        if (idx >= self.nodes.items.len) return;
        const owned = self.gpa.dupe(u8, value) catch return;
        const map = &self.nodes.items[idx].values;
        if (map.getPtr(name)) |p| {
            self.gpa.free(p.*);
            p.* = owned;
        } else {
            // The key comes from the parsed doc, which lives in graph_arena for the session.
            map.put(self.gpa, name, owned) catch self.gpa.free(owned);
        }
    }

    fn nodeValue(self: *App, idx: usize, name: []const u8) []const u8 {
        if (idx >= self.nodes.items.len) return "";
        return self.nodes.items[idx].values.get(name) orelse "";
    }

    /// True when the node is a free-form command rather than a CDL action.
    fn isRaw(n: *const GNode) bool {
        return n.argv.len > 0;
    }

    // ── multi-selection + clipboard ─────────────────────────────────────────

    fn isMarked(self: *App, id: []const u8) bool {
        for (self.marked[0..self.marked_count]) |m| {
            if (std.mem.eql(u8, m, id)) return true;
        }
        return false;
    }

    fn clearMarks(self: *App) void {
        self.marked_count = 0;
    }

    /// Makes `id` the whole selection (a plain click).
    fn markOnly(self: *App, id: []const u8) void {
        self.marked_count = 0;
        self.marked[0] = id;
        self.marked_count = 1;
    }

    /// Adds or removes one node (a Ctrl+click).
    fn toggleMark(self: *App, id: []const u8) void {
        var i: usize = 0;
        while (i < self.marked_count) : (i += 1) {
            if (!std.mem.eql(u8, self.marked[i], id)) continue;
            var k = i;
            while (k + 1 < self.marked_count) : (k += 1) self.marked[k] = self.marked[k + 1];
            self.marked_count -= 1;
            return;
        }
        if (self.marked_count < self.marked.len) {
            self.marked[self.marked_count] = id;
            self.marked_count += 1;
        }
    }

    fn markAll(self: *App) void {
        self.marked_count = 0;
        for (self.nodes.items) |n| {
            if (self.marked_count >= self.marked.len) break;
            self.marked[self.marked_count] = n.id;
            self.marked_count += 1;
        }
    }

    /// Copies the marked nodes — and the edges *between* them — into the clipboard as `.flow` JSON.
    fn copySelection(self: *App) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(a, "{\"nodes\":[") catch return;
        var first = true;
        for (self.nodes.items) |n| {
            if (!self.isMarked(n.id)) continue;
            if (!first) out.append(a, ',') catch return;
            first = false;
            out.appendSlice(a, "{\"id\":\"") catch return;
            jsonEscapeInto(a, &out, n.id) catch return;
            out.appendSlice(a, "\",\"cdl\":\"") catch return;
            jsonEscapeInto(a, &out, n.cdl) catch return;
            out.appendSlice(a, "\",\"action\":\"") catch return;
            jsonEscapeInto(a, &out, n.action) catch return;
            out.appendSlice(a, "\",\"title\":\"") catch return;
            jsonEscapeInto(a, &out, n.title) catch return;
            out.appendSlice(a, "\",\"values\":{") catch return;
            var vit = n.values.iterator();
            var vfirst = true;
            while (vit.next()) |e| {
                if (!vfirst) out.append(a, ',') catch return;
                vfirst = false;
                out.append(a, '"') catch return;
                jsonEscapeInto(a, &out, e.key_ptr.*) catch return;
                out.appendSlice(a, "\":\"") catch return;
                jsonEscapeInto(a, &out, e.value_ptr.*) catch return;
                out.append(a, '"') catch return;
            }
            var nb: [320]u8 = undefined;
            out.appendSlice(a, std.mem.span(fmtZ(&nb, "}},\"x\":{d},\"y\":{d},\"disabled\":{s},\"retry\":{d}", .{
                n.x,
                n.y,
                if (n.disabled) "true" else "false",
                n.retry,
            }))) catch return;
            if (n.timeout_ms) |t| {
                var tb: [48]u8 = undefined;
                out.appendSlice(a, std.mem.span(fmtZ(&tb, ",\"timeoutMs\":{d}", .{t}))) catch return;
            }
            if (n.note.len > 0) {
                out.appendSlice(a, ",\"note\":\"") catch return;
                jsonEscapeInto(a, &out, n.note) catch return;
                out.append(a, '"') catch return;
            }
            if (n.executable.len > 0) {
                out.appendSlice(a, ",\"executable\":\"") catch return;
                jsonEscapeInto(a, &out, n.executable) catch return;
                out.append(a, '"') catch return;
            }
            if (n.argv.len > 0) {
                out.appendSlice(a, ",\"argv\":[") catch return;
                for (n.argv, 0..) |arg, k| {
                    if (k > 0) out.append(a, ',') catch return;
                    out.append(a, '"') catch return;
                    jsonEscapeInto(a, &out, arg) catch return;
                    out.append(a, '"') catch return;
                }
                out.append(a, ']') catch return;
            }
            out.append(a, '}') catch return;
        }
        // Only edges with both ends in the selection: an edge to a node that was not copied would
        // dangle, and the loader would drop it anyway.
        out.appendSlice(a, "],\"edges\":[") catch return;
        var efirst = true;
        for (self.edges.items) |e| {
            if (!self.isMarked(e.from) or !self.isMarked(e.to)) continue;
            if (!efirst) out.append(a, ',') catch return;
            efirst = false;
            out.appendSlice(a, "{\"from\":\"") catch return;
            jsonEscapeInto(a, &out, e.from) catch return;
            out.appendSlice(a, "\",\"to\":\"") catch return;
            jsonEscapeInto(a, &out, e.to) catch return;
            out.appendSlice(a, "\",\"fromPort\":\"") catch return;
            jsonEscapeInto(a, &out, e.from_port) catch return;
            out.appendSlice(a, "\",\"toPort\":\"") catch return;
            jsonEscapeInto(a, &out, e.to_port) catch return;
            out.appendSlice(a, "\",\"kind\":\"") catch return;
            out.appendSlice(a, e.kind.wire()) catch return;
            out.appendSlice(a, "\"}") catch return;
        }
        out.appendSlice(a, "]}") catch return;

        if (self.clipboard) |old| self.gpa.free(old);
        self.clipboard = self.gpa.dupe(u8, out.items) catch null;
        self.hint(.copied);
    }

    /// Pastes the clipboard, offset so the copies are visible on top of the originals, with fresh
    /// ids. Parsing goes through the engine's own flow loader, so anything copyable is also loadable.
    fn pasteClipboard(self: *App) void {
        const text = self.clipboard orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const loaded = pipelith.graph.loadFromValue(a, parsed.ok) catch return;
        if (loaded != .ok) return;
        const g = loaded.ok.graph;

        const ga = self.graph_arena.allocator();
        var id_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer id_map.deinit(a);

        const pasted_from = self.nodes.items.len;
        for (g.nodes.items) |n| {
            const new_id = allocZ(ga, "n{d}", .{self.next_node}) orelse return;
            self.next_node += 1;
            id_map.put(a, n.id, new_id) catch return;
            self.nodes.append(self.gpa, .{
                .id = new_id,
                .cdl = ga.dupe(u8, n.cdl_name) catch "",
                .action = ga.dupe(u8, n.action) catch "",
                .title = ga.dupe(u8, n.title) catch "",
                .category = self.categoryOf(n.cdl_name, ga) orelse "",
                .x = @as(f32, @floatCast(n.x)) + 34,
                .y = @as(f32, @floatCast(n.y)) + 34,
                .disabled = n.disabled,
                .timeout_ms = n.timeout_ms,
                .retry = n.retry,
                .note = ga.dupe(u8, n.note) catch "",
                .executable = ga.dupe(u8, n.executable) catch "",
                .argv = blk: {
                    if (n.argv.len == 0) break :blk &.{};
                    const parts = ga.alloc([]const u8, n.argv.len) catch break :blk &.{};
                    for (n.argv, 0..) |p, k| parts[k] = ga.dupe(u8, p) catch "";
                    break :blk parts;
                },
            }) catch return;
            const idx = self.nodes.items.len - 1;
            var vit = n.values.iterator();
            while (vit.next()) |e| {
                const key = ga.dupe(u8, e.key_ptr.*) catch continue;
                self.setValue(idx, key, e.value_ptr.*);
            }
            self.fetchSpec(idx);
        }
        for (g.edges.items) |e| {
            const from = id_map.get(e.from) orelse continue;
            const to = id_map.get(e.to) orelse continue;
            self.edges.append(self.gpa, .{
                .from = from,
                .to = to,
                .from_port = ga.dupe(u8, e.from_port) catch continue,
                .to_port = ga.dupe(u8, e.to_port) catch continue,
                .kind = e.kind,
            }) catch continue;
        }

        // The paste becomes the new selection, so it can be moved straight away.
        self.clearMarks();
        for (self.nodes.items[pasted_from..]) |n| {
            if (self.marked_count >= self.marked.len) break;
            self.marked[self.marked_count] = n.id;
            self.marked_count += 1;
        }
        self.selected = if (self.nodes.items.len > pasted_from) pasted_from else null;
        self.form_loaded = false;
        self.commit();
        self.hint(.pasted);
    }

    /// Deletes every marked node, back to front so the indices stay valid while removing, and as
    /// **one** history entry — undoing a three-node delete should not take three undos.
    fn deleteMarked(self: *App) void {
        if (self.marked_count == 0) {
            if (self.selected) |i| self.deleteNode(i);
            return;
        }
        var removed: usize = 0;
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.isMarked(self.nodes.items[i].id)) continue;
            self.removeNodeNoCommit(i);
            removed += 1;
        }
        self.clearMarks();
        self.selected = null;
        self.form_loaded = false;
        if (removed > 0) {
            self.commit();
            self.hint(.node_deleted);
        }
    }

    /// Replaces a node's argv from the inspector's "one argument per line" text. The executable
    /// line is kept separate from the arguments, so the caller passes the arguments only; the
    /// stored argv is rebuilt as `[executable] ++ arguments`, which is the shape the engine reads.
    fn setNodeArgv(self: *App, idx: usize, text: []const u8) void {
        if (idx >= self.nodes.items.len) return;
        const ga = self.graph_arena.allocator();
        const exe = if (self.nodes.items[idx].argv.len > 0) self.nodes.items[idx].argv[0] else "";

        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        if (exe.len > 0) parts.append(ga, exe) catch return;
        // Blank lines are skipped rather than becoming empty arguments: an empty argv element is
        // almost never intended and is invisible in the editor.
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) continue;
            parts.append(ga, ga.dupe(u8, trimmed) catch return) catch return;
        }
        if (parts.items.len == 0) return;
        self.nodes.items[idx].argv = parts.items;
        self.argv_serial += 1;
    }

    /// Replaces argv wholesale (program included) from already-split elements — the shape the
    /// one-line command editor produces. Elements are duped into the graph arena like every other
    /// argv mutation.
    fn setNodeArgvFromParts(self: *App, idx: usize, parts_in: []const []const u8) void {
        if (idx >= self.nodes.items.len) return;
        const ga = self.graph_arena.allocator();
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (parts_in) |p| parts.append(ga, ga.dupe(u8, p) catch return) catch return;
        if (parts.items.len == 0) return;
        self.nodes.items[idx].argv = parts.items;
        self.argv_serial += 1;
    }

    /// Replaces argv[0] — the program a raw node runs.
    fn setNodeExecutable(self: *App, idx: usize, exe: []const u8) void {
        if (idx >= self.nodes.items.len) return;
        const ga = self.graph_arena.allocator();
        const copy = ga.dupe(u8, exe) catch return;
        const old = self.nodes.items[idx].argv;
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        parts.append(ga, copy) catch return;
        if (old.len > 1) parts.appendSlice(ga, old[1..]) catch return;
        self.nodes.items[idx].argv = parts.items;
        self.argv_serial += 1;
    }

    /// Seeds the one-line editor from argv. Called when the inspected node changes or when argv
    /// changed from anywhere other than the line editor itself (`argv_serial` says exactly that).
    fn seedCommandLine(self: *App, idx: usize) void {
        self.cmd_line = std.mem.zeroes(@TypeOf(self.cmd_line));
        const argv = if (idx < self.nodes.items.len) self.nodes.items[idx].argv else &.{};
        const ga = self.graph_arena.allocator();
        const line = pipelith.cmdline.format(ga, argv, .posix_quotes) catch "";
        const n = @min(line.len, self.cmd_line.len - 1);
        @memcpy(self.cmd_line[0..n], line[0..n]);
        self.cmd_line_for = idx;
        self.cmd_line_serial = self.argv_serial;
        self.cmd_line_error = .none;
    }

    /// Applies what the user typed in the one-line editor.
    ///
    /// Only a line that parses **completely** under the named convention becomes argv. An open
    /// quote or a trailing backslash leaves the command untouched and reports why — the text the
    /// user is typing is kept as-is (it is not argv yet), and nothing is guessed (rule 3).
    fn applyCommandLine(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        const line = std.mem.sliceTo(&self.cmd_line, 0);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const argv = pipelith.cmdline.tokenize(scratch.allocator(), line, .posix_quotes) catch |err| {
            self.cmd_line_error = switch (err) {
                error.UnterminatedQuote => .unterminated_quote,
                error.TrailingBackslash => .trailing_backslash,
                error.OutOfMemory => return,
            };
            return;
        };
        self.setNodeArgvFromParts(idx, argv);
        // The buffer is the source of this revision, so it must not be re-seeded from it.
        self.cmd_line_serial = self.argv_serial;
        self.cmd_line_error = .none;
    }

    /// Materializes a preset node's command and drops the template: a CDL action becomes a free
    /// command carrying the argv it would have run with the current values.
    ///
    /// This is the escape hatch that makes actions a convenience rather than a boundary
    /// It is one-way and explicit: expanding is a normal, undoable mutation,
    /// and nothing is inferred — the argv is exactly what `run.preview` would execute.
    fn expandToCommand(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        if (self.nodes.items[idx].argv.len > 0) return; // already a free command
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const flow = self.flowJson(a) catch return;
        const params = std.fmt.allocPrint(a, "{{\"flow\":{s}}}", .{flow}) catch return;
        const text = self.call(a, "run.preview", params) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;
        const cmds = (result.field("commands") orelse return).asArray() orelse return;

        const want = self.nodes.items[idx].id;
        for (cmds) |c| {
            const id = if (c.field("id")) |x| (x.asString() orelse "") else "";
            if (!std.mem.eql(u8, id, want)) continue;
            const arr = (c.field("argv") orelse return).asArray() orelse return;
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr) |x| {
                const s = x.asString() orelse return;
                parts.append(a, s) catch return;
            }
            // Keep the title the user sees and the tool binding (`cdl` is the sheet reference —
            // the command is still that tool's); drop the preset action and its values.
            self.freeNodeValues(idx);
            self.nodes.items[idx].action = "";
            self.setNodeArgvFromParts(idx, parts.items);
            self.form_loaded = false;
            self.hint(.expanded_to_command);
            self.commit();
            return;
        }
    }

    /// Harness-driven sheet pick: clicks the n-th row exactly as the panel shows it (after the
    /// filter), so what a test asserts is what a user's click does.
    fn pickSheetRow(self: *App, n: usize) void {
        const idx = self.selected orelse return;
        const ctx = self.sheetContext();
        var vis: usize = 0;
        for (ctx, 0..) |*entry, i| {
            if (!self.sheetMatches(entry)) continue;
            if (vis == n) {
                self.pickSheetEntry(idx, entry, i);
                return;
            }
            vis += 1;
        }
    }

    /// Appends a picked tool-sheet entry to the node's command — the "pick and assemble" half of
    /// the command surface. Tokens become argv elements one per token, under the
    /// named **value slot rule** (`docs/CDL.md`): with `takes`, the first `<...>` span of the last
    /// token is the slot; without one, a multi-token entry's last token is the slot; a single-token
    /// entry appends the value as a new element carrying a visible `<type>` placeholder.
    fn pickSheetEntry(self: *App, idx: usize, entry: *const SheetEntry, pos: usize) void {
        if (idx >= self.nodes.items.len) return;
        if (std.mem.eql(u8, entry.kind, "note")) return;

        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.nodes.items[idx].argv) |x| parts.append(a, x) catch return;
        for (entry.tokens) |t| parts.append(a, t) catch return;

        var slot: ?SheetSlot = null;
        if (entry.takes.len > 0) {
            const last_i = parts.items.len - 1;
            const last_tok = entry.tokens[entry.tokens.len - 1];
            if (findSlotSpan(last_tok)) |span| {
                slot = .{
                    .argv_idx = last_i,
                    .serial = self.argv_serial + 1, // setNodeArgvFromParts bumps it next
                    .mode = .span,
                    .span_start = span[0],
                    .span_len = span[1],
                    .takes = entry.takes,
                    .options = entry.options,
                    .label = entry.label,
                };
            } else if (entry.tokens.len >= 2) {
                slot = .{
                    .argv_idx = last_i,
                    .serial = self.argv_serial + 1,
                    .mode = .replace,
                    .takes = entry.takes,
                    .options = entry.options,
                    .label = entry.label,
                };
            } else {
                // A bare flag (`-c:v`): the value is one new element, with a visible placeholder so
                // an unfilled slot cannot sneak into a run unnoticed.
                const ph = std.fmt.allocPrint(a, "<{s}>", .{entry.takes}) catch return;
                parts.append(a, ph) catch return;
                slot = .{
                    .argv_idx = parts.items.len - 1,
                    .serial = self.argv_serial + 1,
                    .mode = .replace,
                    .takes = entry.takes,
                    .options = entry.options,
                    .label = entry.label,
                };
            }
        }
        self.setNodeArgvFromParts(idx, parts.items);
        self.sheet_slot = slot;
        // A pick is a normal, undoable mutation; the line editor re-seeds from the new argv.
        self.commit();
        // A file or directory slot opens its picker immediately — the value shape exists precisely
        // to trigger the matching picker. Cancelled: the slot stays, fillable.
        if (self.sheet_slot) |s| {
            if (std.mem.eql(u8, s.takes, "file") or std.mem.eql(u8, s.takes, "directory")) {
                self.fillSlotFromPicker(idx);
            }
        }
        // A subcommand drills down: its own children are what comes next in the command.
        if (std.mem.eql(u8, entry.kind, "subcommand") and entry.children.len > 0 and
            self.sheet_depth < self.sheet_path.len)
        {
            self.sheet_path[self.sheet_depth] = pos;
            self.sheet_depth += 1;
        }
    }

    fn fillSlotFromPicker(self: *App, idx: usize) void {
        const slot = self.sheet_slot orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const want_dir = std.mem.eql(u8, slot.takes, "directory");
        if (self.askPath(scratch.allocator(), if (want_dir) "directory" else "file", false)) |picked| {
            self.applySlotValue(idx, picked);
        }
    }

    /// Fills the pending value slot with `value`. Only valid while the argv is still the revision
    /// the slot was cut at: if the user edited the command since, the slot is dismissed instead of
    /// silently rewriting the wrong element (rule 2).
    fn applySlotValue(self: *App, idx: usize, value: []const u8) void {
        const slot = self.sheet_slot orelse return;
        if (slot.serial != self.argv_serial) {
            self.sheet_slot = null;
            return;
        }
        if (idx >= self.nodes.items.len) return;
        const argv = self.nodes.items[idx].argv;
        if (slot.argv_idx >= argv.len) {
            self.sheet_slot = null;
            return;
        }
        const a = self.graph_arena.allocator();
        const el = argv[slot.argv_idx];
        var new_el: []const u8 = undefined;
        switch (slot.mode) {
            .replace => new_el = a.dupe(u8, value) catch return,
            .span => {
                if (slot.span_start + slot.span_len > el.len) {
                    self.sheet_slot = null;
                    return;
                }
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                buf.appendSlice(a, el[0..slot.span_start]) catch return;
                buf.appendSlice(a, value) catch return;
                buf.appendSlice(a, el[slot.span_start + slot.span_len ..]) catch return;
                new_el = buf.items;
            },
        }
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (argv, 0..) |x, i| parts.append(a, if (i == slot.argv_idx) new_el else x) catch return;
        self.nodes.items[idx].argv = parts.items;
        self.argv_serial += 1;
        self.sheet_slot = null;
        self.commit();
    }

    /// Inserts a preset (a CDL action template) into the command — a shortcut on top of the sheet,
    /// never the boundary. `{name}` spans take the variable's default where there is one and stay
    /// literally visible where there is not, so every unfilled slot is right there in the command.
    fn insertSheetPreset(self: *App, idx: usize, preset: *const SheetPreset) void {
        if (idx >= self.nodes.items.len) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const prog = if (preset.exe.len > 0) preset.exe else if (self.nodes.items[idx].argv.len > 0) self.nodes.items[idx].argv[0] else return;
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        parts.append(a, prog) catch return;
        for (preset.args) |t| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            var i: usize = 0;
            while (i < t.len) {
                if (t[i] == '{') {
                    if (std.mem.indexOfScalarPos(u8, t, i + 1, '}')) |close| {
                        const name = t[i + 1 .. close];
                        var filled = false;
                        for (preset.vars) |v| {
                            if (std.mem.eql(u8, v.name, name) and v.default.len > 0) {
                                out.appendSlice(a, v.default) catch return;
                                filled = true;
                                break;
                            }
                        }
                        // No default: keep `{name}` as the visible slot it is.
                        if (!filled) out.appendSlice(a, t[i .. close + 1]) catch return;
                        i = close + 1;
                        continue;
                    }
                }
                out.append(a, t[i]) catch return;
                i += 1;
            }
            parts.append(a, out.items) catch return;
        }
        self.setNodeArgvFromParts(idx, parts.items);
        self.sheet_slot = null;
        self.commit();
    }

    /// Opens a preset as a form node (the classic view): the node stops being a free command and
    /// becomes the action's template with its variables. The reverse — expanding the form back
    /// into a free command — is `expandToCommand`.
    fn applyPresetForm(self: *App, idx: usize, preset: *const SheetPreset) void {
        if (idx >= self.nodes.items.len) return;
        self.nodes.items[idx].action = preset.name;
        self.nodes.items[idx].argv = &.{};
        self.sheet_slot = null;
        self.form_loaded = false;
        self.commit();
    }

    /// Sets or clears the per-node executable override on an ordinary CDL node.
    fn setNodeExeOverride(self: *App, idx: usize, exe: []const u8) void {
        if (idx >= self.nodes.items.len) return;
        const ga = self.graph_arena.allocator();
        if (exe.len == 0) {
            self.nodes.items[idx].executable = "";
            return;
        }
        const copy = ga.dupe(u8, exe) catch return;
        self.nodes.items[idx].executable = copy;
    }

    /// Creates a raw-command node from an executable path (the "add a tool the library does not
    /// know" entry point). Returns the new node index.
    fn addCommandNode(self: *App, exe: []const u8, wx: f32, wy: f32) ?usize {
        if (exe.len == 0) return null;
        // The label is the program's basename, which is what distinguishes two raw nodes at a glance.
        const base = std.fs.path.basename(exe);
        return self.addRawNodeAt(&.{exe}, if (base.len > 0) base else exe, wx, wy);
    }

    /// Creates a raw-command node from a whole argv (the shared implementation; the demo fixture uses
    /// it too). The arguments are copied into the graph arena, so callers may pass temporaries.
    fn addRawNodeAt(self: *App, argv: []const []const u8, title: []const u8, wx: f32, wy: f32) ?usize {
        if (argv.len == 0 or argv[0].len == 0) return null;
        const ga = self.graph_arena.allocator();
        const id = allocZ(ga, "n{d}", .{self.next_node}) orelse return null;
        self.next_node += 1;
        const copy = ga.alloc([]const u8, argv.len) catch return null;
        for (argv, 0..) |arg, i| copy[i] = ga.dupe(u8, arg) catch return null;
        self.nodes.append(self.gpa, .{
            .id = id,
            .cdl = "",
            .action = "",
            .title = ga.dupe(u8, title) catch "",
            .category = "",
            .x = wx,
            .y = wy,
            .has_stdin = true,
            .has_stdout = true,
            .argv = copy,
        }) catch return null;
        const idx = self.nodes.items.len - 1;
        self.selected = idx;
        self.form_loaded = false;
        self.commit();
        self.hint(.command_added);
        return idx;
    }

    fn freeNodeValues(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        var it = self.nodes.items[idx].values.iterator();
        while (it.next()) |entry| self.gpa.free(entry.value_ptr.*);
        self.nodes.items[idx].values.deinit(self.gpa);
        self.nodes.items[idx].values = .empty;
    }

    // ── verification dumps ───────────────────────────────────────────────────
    // These turn what the panels *show* into text, which is the native replacement for asserting
    // against a DOM. `dev/test-native-gui.mjs` is the only consumer.

    fn writeTextFile(self: *App, io: Io, path: []const u8, bytes: []const u8) void {
        _ = self;
        const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer f.close(io);
        var buf: [8192]u8 = undefined;
        var fw = f.writer(io, &buf);
        fw.interface.writeAll(bytes) catch return;
        fw.interface.flush() catch {};
    }

    /// The tool library as currently filtered (search + category applied).
    fn dumpLibrary(self: *App, io: Io, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(a, "[") catch return;
        for (self.items[0..self.item_count], 0..) |it, i| {
            if (i > 0) out.append(a, ',') catch return;
            out.appendSlice(a, "{\"name\":\"") catch return;
            jsonEscapeInto(a, &out, it.name) catch return;
            out.appendSlice(a, "\",\"display\":\"") catch return;
            jsonEscapeInto(a, &out, it.display) catch return;
            out.appendSlice(a, "\",\"category\":\"") catch return;
            jsonEscapeInto(a, &out, it.category) catch return;
            out.appendSlice(a, "\",\"action\":\"") catch return;
            jsonEscapeInto(a, &out, it.action_name) catch return;
            out.appendSlice(a, "\",\"available\":") catch return;
            out.appendSlice(a, if (it.available) "true" else "false") catch return;
            out.append(a, '}') catch return;
        }
        out.append(a, ']') catch return;
        self.writeTextFile(io, path, out.items);
    }

    /// The tool packs the library offers, as JSON — what the harness asserts "nothing is loaded by
    /// default, and these packs are available to load" against. `tools` is the installed tool count,
    /// so an empty library is machine-checkable rather than a matter of reading the panel.
    fn dumpPacks(self: *App, io: Io, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(a, std.fmt.allocPrint(
            a,
            "{{\"tools\":{d},\"packCount\":{d},\"dirs\":[",
            .{ self.tool_total, self.pack_count },
        ) catch return) catch return;
        for (self.pack_dirs[0..self.pack_dir_count], 0..) |dir, i| {
            if (i > 0) out.append(a, ',') catch return;
            out.append(a, '"') catch return;
            jsonEscapeInto(a, &out, dir) catch return;
            out.append(a, '"') catch return;
        }
        out.appendSlice(a, "],\"packs\":[") catch return;
        for (self.packs[0..self.pack_count], 0..) |p, i| {
            if (i > 0) out.append(a, ',') catch return;
            out.appendSlice(a, "{\"id\":\"") catch return;
            jsonEscapeInto(a, &out, p.id) catch return;
            out.appendSlice(a, "\",\"label\":\"") catch return;
            jsonEscapeInto(a, &out, p.label) catch return;
            out.appendSlice(a, "\",\"description\":\"") catch return;
            jsonEscapeInto(a, &out, p.desc) catch return;
            out.appendSlice(a, "\",\"source\":\"") catch return;
            jsonEscapeInto(a, &out, p.source) catch return;
            out.appendSlice(a, std.fmt.allocPrint(
                a,
                "\",\"toolCount\":{d},\"installedCount\":{d},\"modifiedCount\":{d},\"installed\":{}}}",
                .{ p.tools, p.installed, p.modified, p.complete },
            ) catch return) catch return;
        }
        out.appendSlice(a, "]}") catch return;
        self.writeTextFile(io, path, out.items);
    }

    /// The canvas graph plus each node's port plan (the native equivalent of the web suite's
    /// "how many port labels are on this card" assertions).
    fn dumpGraph(self: *App, io: Io, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(a, "{\"name\":\"") catch return;
        jsonEscapeInto(a, &out, self.flowName()) catch return;
        out.appendSlice(a, std.fmt.allocPrint(a, "\",\"viewport\":{{\"x\":{d},\"y\":{d},\"zoom\":{d}}},\"nodes\":[", .{
            self.view_pan_x,
            self.view_pan_y,
            self.view_zoom,
        }) catch return) catch return;
        for (self.nodes.items, 0..) |n, i| {
            if (i > 0) out.append(a, ',') catch return;
            out.appendSlice(a, "{\"id\":\"") catch return;
            jsonEscapeInto(a, &out, n.id) catch return;
            out.appendSlice(a, "\",\"cdl\":\"") catch return;
            jsonEscapeInto(a, &out, n.cdl) catch return;
            out.appendSlice(a, "\",\"action\":\"") catch return;
            jsonEscapeInto(a, &out, n.action) catch return;
            out.appendSlice(a, "\",\"title\":\"") catch return;
            jsonEscapeInto(a, &out, n.title) catch return;
            out.appendSlice(a, "\",\"hasStdin\":") catch return;
            out.appendSlice(a, if (n.has_stdin) "true" else "false") catch return;
            out.appendSlice(a, ",\"hasStdout\":") catch return;
            out.appendSlice(a, if (n.has_stdout) "true" else "false") catch return;
            // Positions are part of the graph (they are saved in the .flow), so the dump carries
            // them too — that is what lets the harness check drag-and-drop placement and cloning.
            out.appendSlice(a, std.fmt.allocPrint(a, ",\"x\":{d},\"y\":{d}", .{ n.x, n.y }) catch return) catch return;
            // Carried-through fields, so the harness can prove open → save does not rewrite them.
            out.appendSlice(a, ",\"disabled\":") catch return;
            out.appendSlice(a, if (n.disabled) "true" else "false") catch return;
            out.appendSlice(a, std.fmt.allocPrint(a, ",\"retry\":{d}", .{n.retry}) catch return) catch return;
            if (n.timeout_ms) |t| {
                out.appendSlice(a, std.fmt.allocPrint(a, ",\"timeoutMs\":{d}", .{t}) catch return) catch return;
            } else {
                out.appendSlice(a, ",\"timeoutMs\":null") catch return;
            }
            out.appendSlice(a, ",\"note\":\"") catch return;
            jsonEscapeInto(a, &out, n.note) catch return;
            out.append(a, '"') catch return;
            // The raw-command escape hatch and the executable override are what let the GUI run
            // something the built-in tool library does not describe, so the dump carries them.
            out.appendSlice(a, ",\"executable\":\"") catch return;
            jsonEscapeInto(a, &out, n.executable) catch return;
            out.append(a, '"') catch return;
            out.appendSlice(a, ",\"argv\":[") catch return;
            for (n.argv, 0..) |p, k| {
                if (k > 0) out.append(a, ',') catch return;
                out.append(a, '"') catch return;
                jsonEscapeInto(a, &out, p) catch return;
                out.append(a, '"') catch return;
            }
            out.append(a, ']') catch return;
            out.append(a, '}') catch return;
        }
        out.appendSlice(a, "],\"edges\":[") catch return;
        for (self.edges.items, 0..) |e, i| {
            if (i > 0) out.append(a, ',') catch return;
            out.appendSlice(a, "{\"from\":\"") catch return;
            jsonEscapeInto(a, &out, e.from) catch return;
            out.appendSlice(a, "\",\"to\":\"") catch return;
            jsonEscapeInto(a, &out, e.to) catch return;
            out.appendSlice(a, "\",\"fromPort\":\"") catch return;
            jsonEscapeInto(a, &out, e.from_port) catch return;
            out.appendSlice(a, "\",\"toPort\":\"") catch return;
            jsonEscapeInto(a, &out, e.to_port) catch return;
            out.appendSlice(a, "\",\"kind\":\"") catch return;
            out.appendSlice(a, e.kind.wire()) catch return;
            out.appendSlice(a, "\"}") catch return;
        }
        out.appendSlice(a, "]}") catch return;
        self.writeTextFile(io, path, out.items);
    }

    /// The inspector form for the selected node: variable specs, current values, and the
    /// validation verdict as a language-independent code.
    fn dumpForm(self: *App, io: Io, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(a, "{\"selected\":") catch return;
        const idx = self.form_node;
        if (idx == null) {
            out.appendSlice(a, "null,\"vars\":[]}") catch return;
            self.writeTextFile(io, path, out.items);
            return;
        }
        const n = self.nodes.items[idx.?];
        out.appendSlice(a, "{\"cdl\":\"") catch return;
        jsonEscapeInto(a, &out, n.cdl) catch return;
        out.appendSlice(a, "\",\"action\":\"") catch return;
        jsonEscapeInto(a, &out, n.action) catch return;
        out.appendSlice(a, "\"},\"vars\":[") catch return;
        for (self.form_vars[0..self.form_var_count], 0..) |spec, i| {
            if (i > 0) out.append(a, ',') catch return;
            const value = self.nodeValue(idx.?, spec.name);
            out.appendSlice(a, "{\"name\":\"") catch return;
            jsonEscapeInto(a, &out, spec.name) catch return;
            out.appendSlice(a, "\",\"type\":\"") catch return;
            jsonEscapeInto(a, &out, spec.vtype) catch return;
            out.appendSlice(a, "\",\"required\":") catch return;
            out.appendSlice(a, if (spec.required) "true" else "false") catch return;
            out.appendSlice(a, ",\"value\":\"") catch return;
            jsonEscapeInto(a, &out, value) catch return;
            out.appendSlice(a, "\",\"error\":") catch return;
            if (validateCode(spec, value)) |code| {
                out.append(a, '"') catch return;
                out.appendSlice(a, codeName(code)) catch return;
                out.append(a, '"') catch return;
            } else {
                out.appendSlice(a, "null") catch return;
            }
            out.appendSlice(a, ",\"optionCount\":") catch return;
            out.appendSlice(a, std.fmt.allocPrint(a, "{d}", .{spec.options.len}) catch return) catch return;
            out.appendSlice(a, ",\"min\":") catch return;
            if (spec.min) |mn| {
                out.appendSlice(a, std.fmt.allocPrint(a, "{d}", .{mn}) catch return) catch return;
            } else out.appendSlice(a, "null") catch return;
            out.appendSlice(a, ",\"max\":") catch return;
            if (spec.max) |mx| {
                out.appendSlice(a, std.fmt.allocPrint(a, "{d}", .{mx}) catch return) catch return;
            } else out.appendSlice(a, "null") catch return;
            out.append(a, '}') catch return;
        }
        out.appendSlice(a, "]}") catch return;
        self.writeTextFile(io, path, out.items);
    }

    // ── workflow files ───────────────────────────────────────────────────────
    // Rule 4: the only writable location is `<tool dir>/.pipelith`, so the fallback path (used when
    // no file dialog is available) lives there rather than in the working directory.

    fn flowPath(self: *App, a: std.mem.Allocator) ?[]const u8 {
        const dir = self.svc.user_dir orelse return null;
        return std.fs.path.join(a, &.{ dir, "flow.flow" }) catch null;
    }

    fn autosavePath(self: *App, a: std.mem.Allocator) ?[]const u8 {
        const dir = self.svc.user_dir orelse return null;
        return std.fs.path.join(a, &.{ dir, "autosave.flow" }) catch null;
    }

    // ── preferences ──────────────────────────────────────────────────────────
    // Theme and language survive a restart: the native equivalent of the web build's
    // `pipelith.theme.v1` / language localStorage entries, kept under the tool directory (rule 4).

    fn prefsPath(self: *App, a: std.mem.Allocator) ?[]const u8 {
        const dir = self.svc.user_dir orelse return null;
        return std.fs.path.join(a, &.{ dir, "prefs.json" }) catch null;
    }

    fn savePrefs(self: *App) void {
        if (!self.autosave_enabled) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = self.prefsPath(a) orelse return;
        const json = std.fmt.allocPrint(a, "{{\"theme\":\"{s}\",\"lang\":\"{s}\"}}", .{
            @tagName(self.theme_kind),
            @tagName(self.lang),
        }) catch return;
        self.writeTextFile(self.io, path, json);
    }

    fn loadPrefs(self: *App) void {
        if (!self.autosave_enabled) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = self.prefsPath(a) orelse return;
        if (!self.fileExists(path)) return;
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024)) catch return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        if (parsed.ok.field("theme")) |t| {
            if (t.asString()) |s| self.theme_kind = if (std.mem.eql(u8, s, "light")) .light else .dark;
        }
        if (parsed.ok.field("lang")) |l| {
            if (l.asString()) |s| {
                self.lang = if (std.mem.eql(u8, s, "en")) .en else .zh;
                // Only retranslate the placeholder; a real name is not language-dependent.
                if (self.flowName().len == 0) self.flow_title = StrKey.untitled_workflow.get(self.lang);
            }
        }
    }

    fn fileExists(self: *App, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    fn writeFlow(self: *App, path: []const u8) bool {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const json = self.flowJson(scratch.allocator()) catch return false;
        const f = Io.Dir.cwd().createFile(self.io, path, .{}) catch return false;
        defer f.close(self.io);
        var buf: [8192]u8 = undefined;
        var fw = f.writer(self.io, &buf);
        fw.interface.writeAll(json) catch return false;
        fw.interface.flush() catch return false;
        return true;
    }

    /// Loads a `.flow` file. The parse goes through the engine's own graph loader, so a file that
    /// opens here is exactly a file that will run.
    fn readFlow(self: *App, path: []const u8) bool {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        const text = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(8 * 1024 * 1024)) catch {
            self.hint(.open_failed);
            return false;
        };
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) {
            self.hint(.open_failed);
            return false;
        }
        const loaded = pipelith.graph.loadFromValue(a, parsed.ok) catch {
            self.hint(.open_failed);
            return false;
        };
        if (loaded != .ok) {
            self.hint(.open_failed);
            return false;
        }
        const g = loaded.ok.graph;

        for (self.nodes.items, 0..) |_, i| self.freeNodeValues(i);
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();

        const ga = self.graph_arena.allocator();
        for (g.nodes.items) |n| {
            self.nodes.append(self.gpa, .{
                .id = ga.dupe(u8, n.id) catch continue,
                .cdl = ga.dupe(u8, n.cdl_name) catch continue,
                .action = ga.dupe(u8, n.action) catch continue,
                .title = ga.dupe(u8, n.title) catch continue,
                .category = self.categoryOf(n.cdl_name, ga) orelse "",
                .x = @floatCast(n.x),
                .y = @floatCast(n.y),
                .disabled = n.disabled,
                .timeout_ms = n.timeout_ms,
                .retry = n.retry,
                .note = ga.dupe(u8, n.note) catch "",
                .executable = ga.dupe(u8, n.executable) catch "",
                .argv = blk: {
                    if (n.argv.len == 0) break :blk &.{};
                    const parts = ga.alloc([]const u8, n.argv.len) catch break :blk &.{};
                    for (n.argv, 0..) |p, k| parts[k] = ga.dupe(u8, p) catch "";
                    break :blk parts;
                },
            }) catch continue;
            const idx = self.nodes.items.len - 1;
            var it = n.values.iterator();
            while (it.next()) |e| {
                const key = ga.dupe(u8, e.key_ptr.*) catch continue;
                self.setValue(idx, key, e.value_ptr.*);
            }
            // Derives the port plan (and fills any variable a hand-written file left out) from the
            // CDL, exactly as adding the node from the library would.
            self.fetchSpec(idx);
        }
        for (g.edges.items) |e| {
            self.edges.append(self.gpa, .{
                .from = ga.dupe(u8, e.from) catch continue,
                .to = ga.dupe(u8, e.to) catch continue,
                .from_port = ga.dupe(u8, e.from_port) catch continue,
                .to_port = ga.dupe(u8, e.to_port) catch continue,
                .kind = e.kind,
            }) catch continue;
        }

        // Keep generated ids clear of the ones that just arrived.
        var max_n: u32 = 0;
        for (self.nodes.items) |n| {
            if (n.id.len > 1 and n.id[0] == 'n') {
                const v = std.fmt.parseInt(u32, n.id[1..], 10) catch continue;
                if (v > max_n) max_n = v;
            }
        }
        self.next_node = max_n + 1;
        // The engine defaults an unnamed document to `graph.default_name`; treat that as "no name" so
        // the placeholder keeps showing and the sentinel is not re-saved as if the user typed it.
        self.setFlowName(if (std.mem.eql(u8, g.name, pipelith.graph.default_name)) "" else g.name);
        // Restore the viewport too: without this, reopening a workflow would re-frame the canvas and
        // the saved positions would be the only thing surviving the round trip.
        self.view_pan_x = @floatCast(g.viewport_x);
        self.view_pan_y = @floatCast(g.viewport_y);
        self.view_zoom = std.math.clamp(@as(f32, @floatCast(g.viewport_zoom)), 0.35, 2.5);
        self.selected = null;
        self.form_node = null;
        self.form_loaded = false;
        self.form_var_count = 0;
        self.commit();
        self.hint(.opened);
        return true;
    }

    /// The category a CDL belongs to, taken from the already-loaded library list.
    fn categoryOf(self: *App, cdl_name: []const u8, a: std.mem.Allocator) ?[]const u8 {
        for (self.items[0..self.item_count]) |it| {
            if (std.mem.eql(u8, it.name, cdl_name)) return a.dupe(u8, it.category) catch null;
        }
        return null;
    }

    /// Native file dialog through the engine's `fs.pick`. Unavailable in the sandbox (it needs the
    /// pl_pick child process), which is why callers fall back to the tool directory.
    fn askPath(self: *App, a: std.mem.Allocator, kind: []const u8, save: bool) ?[]const u8 {
        const params = std.fmt.allocPrint(a, "{{\"kind\":\"{s}\",\"save\":{s}}}", .{
            kind,
            if (save) "true" else "false",
        }) catch return null;
        const text = self.call(a, "fs.pick", params) orelse return null;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return null;
        const result = parsed.ok.field("result") orelse return null;
        const path = result.field("path") orelse return null;
        const s = path.asString() orelse return null;
        if (s.len == 0) return null;
        return s;
    }

    fn doSave(self: *App) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = self.askPath(a, "file", true) orelse (self.flowPath(a) orelse {
            self.hint(.save_failed);
            return;
        });
        if (self.writeFlow(path)) {
            self.hint(.saved);
        } else {
            self.hint(.save_failed);
        }
    }

    fn doOpen(self: *App) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const path = self.askPath(a, "file", false) orelse (self.flowPath(a) orelse {
            self.hint(.open_failed);
            return;
        });
        _ = self.readFlow(path);
    }

    fn doNew(self: *App) void {
        for (self.nodes.items, 0..) |_, i| self.freeNodeValues(i);
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.selected = null;
        self.form_node = null;
        self.form_loaded = false;
        self.form_var_count = 0;
        // A new workflow starts unnamed, so the title falls back to the placeholder.
        self.setFlowName("");
        self.commit();
    }

    /// Mirrors the web build's autosave (which used localStorage) onto the tool directory.
    fn autosave(self: *App) void {
        if (!self.autosave_enabled) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const path = self.autosavePath(scratch.allocator()) orelse return;
        _ = self.writeFlow(path);
    }

    /// Restores the autosaved workflow when the app starts without a scripted flow, so a restart
    /// does not lose the canvas.
    fn tryRestoreAutosave(self: *App) bool {
        if (!self.autosave_enabled) return false;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const path = self.autosavePath(scratch.allocator()) orelse return false;
        if (!self.fileExists(path)) return false;
        if (self.nodes.items.len > 0) return false; // never clobber an explicit flow
        if (!self.readFlow(path)) return false;
        self.hint(.autosave_restored);
        return true;
    }

    // ── undo / redo ─────────────────────────────────────────────────────────

    /// Transient status-bar message.
    fn hint(self: *App, key: StrKey) void {
        self.hint_text = key.get(self.lang);
        self.hint_frames = 200; // ~3 s at 60 fps, ~5 s at the 12 ms frame cap
    }

    /// Writes the collected output-panel lines to a file. Doubles as the panel's "save output"
    /// action and as the machine-checkable view of a run for `dev/test-native-gui.mjs`.
    fn dumpLog(self: *App, io: Io, path: []const u8) void {
        const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
        defer f.close(io);
        var buf: [8192]u8 = undefined;
        var fw = f.writer(io, &buf);
        const w = &fw.interface;
        var i: usize = 0;
        while (i < self.log_count) : (i += 1) {
            const line = self.logLine(i);
            if (line.node.len > 0) {
                w.print("[{s}] {s}\n", .{ line.node, line.text }) catch return;
            } else {
                w.print("{s}\n", .{line.text}) catch return;
            }
        }
        w.flush() catch {};
    }

    fn captureInto(self: *App, entry: *HistoryEntry) void {
        entry.arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = entry.arena.allocator();

        const nodes = a.alloc(NodeSnap, self.nodes.items.len) catch return;
        for (self.nodes.items, 0..) |n, i| {
            const vals = a.alloc(ValueSnap, n.values.count()) catch return;
            var it = n.values.iterator();
            var vi: usize = 0;
            while (it.next()) |e| : (vi += 1) {
                vals[vi] = .{
                    .key = a.dupe(u8, e.key_ptr.*) catch "",
                    .value = a.dupe(u8, e.value_ptr.*) catch "",
                };
            }
            nodes[i] = .{
                .id = a.dupe(u8, n.id) catch "",
                .cdl = a.dupe(u8, n.cdl) catch "",
                .action = a.dupe(u8, n.action) catch "",
                .title = a.dupe(u8, n.title) catch "",
                .category = a.dupe(u8, n.category) catch "",
                .x = n.x,
                .y = n.y,
                .has_stdin = n.has_stdin,
                .has_stdout = n.has_stdout,
                .disabled = n.disabled,
                .timeout_ms = n.timeout_ms,
                .retry = n.retry,
                .note = a.dupe(u8, n.note) catch "",
                .executable = a.dupe(u8, n.executable) catch "",
                .argv = blk: {
                    if (n.argv.len == 0) break :blk &.{};
                    const parts = a.alloc([]const u8, n.argv.len) catch break :blk &.{};
                    for (n.argv, 0..) |p, k| parts[k] = a.dupe(u8, p) catch "";
                    break :blk parts;
                },
                .values = vals,
            };
        }
        const edges = a.alloc(EdgeSnap, self.edges.items.len) catch return;
        for (self.edges.items, 0..) |e, i| {
            edges[i] = .{
                .from = a.dupe(u8, e.from) catch "",
                .to = a.dupe(u8, e.to) catch "",
                .from_port = a.dupe(u8, e.from_port) catch "",
                .to_port = a.dupe(u8, e.to_port) catch "",
                .kind = e.kind,
            };
        }
        entry.nodes = nodes;
        entry.edges = edges;
        entry.next_node = self.next_node;
        entry.name = a.dupe(u8, self.flowName()) catch "";
    }

    fn freeEntry(self: *App, slot: *?HistoryEntry) void {
        _ = self;
        if (slot.*) |*e| e.arena.deinit();
        slot.* = null;
    }

    /// Records the current graph as the newest state and drops any redo branch. Call after a
    /// mutation; discrete actions commit immediately, a drag or a typing burst commits once at the
    /// end (see `dragging_node` and `pl_gui_item_deactivated_after_edit`).
    fn commit(self: *App) void {
        var i = self.history_cursor + 1;
        while (i < self.history_len) : (i += 1) self.freeEntry(&self.history[i]);
        self.history_len = self.history_cursor + 1;

        if (self.history_len >= history_capacity) {
            // Slide the window: drop the oldest state.
            self.freeEntry(&self.history[0]);
            var k: usize = 1;
            while (k < history_capacity) : (k += 1) self.history[k - 1] = self.history[k];
            self.history[history_capacity - 1] = null;
            self.history_len = history_capacity - 1;
            self.history_cursor -= 1;
        }

        var entry: HistoryEntry = .{ .arena = undefined };
        self.captureInto(&entry);
        self.history[self.history_len] = entry;
        self.history_len += 1;
        self.history_cursor = self.history_len - 1;

        // Every mutation is also the natural autosave point (commit granularity is already coarse).
        self.autosave();
    }

    fn canUndo(self: *App) bool {
        return self.history_cursor > 0;
    }

    fn canRedo(self: *App) bool {
        return self.history_cursor + 1 < self.history_len;
    }

    fn applyEntry(self: *App, entry: *const HistoryEntry) void {
        for (self.nodes.items, 0..) |_, i| self.freeNodeValues(i);
        self.nodes.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();

        const a = self.graph_arena.allocator();
        for (entry.nodes) |n| {
            self.nodes.append(self.gpa, .{
                .id = a.dupe(u8, n.id) catch continue,
                .cdl = a.dupe(u8, n.cdl) catch continue,
                .action = a.dupe(u8, n.action) catch continue,
                .title = a.dupe(u8, n.title) catch continue,
                .category = a.dupe(u8, n.category) catch continue,
                .x = n.x,
                .y = n.y,
                .has_stdin = n.has_stdin,
                .has_stdout = n.has_stdout,
                .disabled = n.disabled,
                .timeout_ms = n.timeout_ms,
                .retry = n.retry,
                .note = a.dupe(u8, n.note) catch "",
                .executable = a.dupe(u8, n.executable) catch "",
                .argv = blk: {
                    if (n.argv.len == 0) break :blk &.{};
                    const parts = a.alloc([]const u8, n.argv.len) catch break :blk &.{};
                    for (n.argv, 0..) |p, k| parts[k] = a.dupe(u8, p) catch "";
                    break :blk parts;
                },
            }) catch continue;
            const idx = self.nodes.items.len - 1;
            for (n.values) |v| {
                // `setValue` keys must live in graph_arena, so re-home them: the snapshot's strings
                // die with the history entry.
                const key = a.dupe(u8, v.key) catch continue;
                self.setValue(idx, key, v.value);
            }
        }
        for (entry.edges) |e| {
            self.edges.append(self.gpa, .{
                .from = a.dupe(u8, e.from) catch continue,
                .to = a.dupe(u8, e.to) catch continue,
                .from_port = a.dupe(u8, e.from_port) catch continue,
                .to_port = a.dupe(u8, e.to_port) catch continue,
                .kind = e.kind,
            }) catch continue;
        }
        self.next_node = entry.next_node;
        self.setFlowName(entry.name);
        // Selection indexes into the old graph, so drop it rather than point at a different node.
        self.selected = null;
        self.form_node = null;
        self.form_loaded = false;
        self.form_var_count = 0;
    }

    fn undo(self: *App) void {
        if (!self.canUndo()) return;
        self.history_cursor -= 1;
        if (self.history[self.history_cursor]) |*e| self.applyEntry(e);
        self.hint(.undone);
    }

    fn redo(self: *App) void {
        if (!self.canRedo()) return;
        self.history_cursor += 1;
        if (self.history[self.history_cursor]) |*e| self.applyEntry(e);
        self.hint(.redone);
    }

    /// Keyboard shortcuts. Text fields keep the keyboard while focused, so a Ctrl+Z inside an input
    /// edits text rather than the graph.
    fn handleShortcuts(self: *App) void {
        const ctrl = pl_gui_key_ctrl() == 1;
        const shift = pl_gui_key_shift() == 1;

        // Ctrl+Enter is checked *before* the text-input guard on purpose: starting a run is not a
        // text edit, and it is the shortcut a user reaches for immediately after typing a parameter.
        if (ctrl and pl_gui_key_pressed(key_enter) == 1) {
            if (!self.running) self.doRun();
            return;
        }

        // Everything below would corrupt a field the user is typing into, so it waits for the
        // keyboard to be free.
        if (pl_gui_want_text_input() == 1) return;

        if (ctrl and pl_gui_key_pressed(key_a) == 1) {
            self.markAll();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_c) == 1) {
            self.copySelection();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_v) == 1) {
            self.pasteClipboard();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_z) == 1) {
            if (shift) self.redo() else self.undo();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_y) == 1) {
            self.redo();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_d) == 1) {
            if (self.selected) |idx| self.duplicateNode(idx);
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_n) == 1) {
            self.doNew();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_o) == 1) {
            self.doOpen();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_s) == 1) {
            self.doSave();
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_f) == 1) {
            self.focus_search = true;
            return;
        }
        if (ctrl and shift and pl_gui_key_pressed(key_l) == 1) {
            self.autoLayout();
            return;
        }
        // Ctrl+= is what "Ctrl and the + key" actually reports: + needs Shift on most layouts.
        if (ctrl and (pl_gui_key_pressed(key_equal) == 1)) {
            self.zoomBy(1.18);
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_minus) == 1) {
            self.zoomBy(0.85);
            return;
        }
        if (ctrl and pl_gui_key_pressed(key_zero) == 1) {
            self.fitView();
            return;
        }
        if (pl_gui_key_pressed(key_delete) == 1 and !ctrl) {
            self.deleteMarked();
            return;
        }
        if (pl_gui_key_pressed(key_escape) == 1) self.doStop();
    }

    // ── inspector form ──────────────────────────────────────────────────────

    fn syncForm(self: *App) void {
        if (self.selected) |idx| {
            if (self.form_loaded and self.form_node != null and self.form_node.? == idx) return;
            self.form_node = idx;
            self.fetchSpec(idx);
            self.form_loaded = true;
        } else {
            self.form_node = null;
            self.form_loaded = false;
            self.form_var_count = 0;
        }
    }

    fn parseVar(a: std.mem.Allocator, v: pipelith.value.Value) ?VarSpec {
        var spec = VarSpec{ .name = "", .label = "" };
        spec.name = if (v.field("name")) |x| (x.asString() orelse "") else "";
        if (spec.name.len == 0) return null;
        spec.label = if (v.field("label")) |x| (x.asString() orelse spec.name) else spec.name;
        spec.vtype = if (v.field("type")) |x| (x.asString() orelse "text") else "text";
        spec.required = if (v.field("required")) |x| (x.asBool() orelse false) else false;
        spec.default = if (v.field("default")) |x| (x.asString() orelse "") else "";
        spec.placeholder = if (v.field("placeholder")) |x| (x.asString() orelse "") else "";
        spec.multiline = if (v.field("multiline")) |x| (x.asBool() orelse false) else false;
        spec.min = if (v.field("min")) |x| x.asFloat() else null;
        spec.max = if (v.field("max")) |x| x.asFloat() else null;
        spec.step = if (v.field("step")) |x| x.asFloat() else null;
        spec.save = if (v.field("save")) |x| (x.asBool() orelse false) else false;
        spec.description = if (v.field("description")) |x| (x.asString() orelse "") else "";
        if (v.field("options")) |ov| {
            if (ov.asArray()) |arr| {
                var opts: std.ArrayListUnmanaged(Option) = .empty;
                for (arr) |o| {
                    const val = if (o.field("value")) |x| (x.asString() orelse "") else "";
                    const lab = if (o.field("label")) |x| (x.asString() orelse val) else val;
                    opts.append(a, .{ .value = val, .label = lab }) catch {};
                }
                spec.options = opts.items;
            }
        }
        if (v.field("filters")) |fv| {
            if (fv.asArray()) |arr| {
                var fl: std.ArrayListUnmanaged([]const u8) = .empty;
                for (arr) |f| {
                    if (f.asString()) |s| fl.append(a, s) catch {};
                }
                spec.filters = fl.items;
            }
        }
        return spec;
    }

    /// Reads the node's CDL document, builds the form spec for its action, derives the port plan
    /// from the action's stream modes, and fills any variable that has no value yet from its
    /// default. Values belong to the node and survive re-selection.
    /// Fetches the bound tool's sheet (CDL `vocabulary`) and its presets into the panel cache.
    /// Parsed once per selection from `cdl.get`, exactly like the form's variable specs. The sheet
    /// is the tool's curated knowledge — nothing here ever runs or probes the tool (rule 6, 4.5).
    fn fetchSheet(self: *App, idx: usize) void {
        self.sheet_tool = "";
        self.sheet_root = &.{};
        self.sheet_presets = &.{};
        self.sheet_depth = 0;
        self.sheet_slot = null;
        if (idx >= self.nodes.items.len) return;
        const cdl_name = self.nodes.items[idx].cdl;
        if (cdl_name.len == 0) return;

        const a = self.graph_arena.allocator();
        const params = std.fmt.allocPrint(a, "{{\"name\":\"{s}\"}}", .{cdl_name}) catch return;
        const text = self.call(a, "cdl.get", params) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;
        const doc = result.field("doc") orelse return;

        self.sheet_tool = cdl_name;
        if (doc.field("vocabulary")) |vv| {
            if (vv.asArray()) |arr| self.sheet_root = parseSheetEntries(a, arr);
        }

        // Inputs and outputs are variables too: their defaults fill a preset's `{name}` spans.
        var base: std.ArrayListUnmanaged(SheetVar) = .empty;
        for ([_][]const u8{ "inputs", "outputs" }) |key| {
            if (doc.field(key)) |kv| {
                if (kv.asArray()) |arr| {
                    for (arr) |item| {
                        const n = (item.field("name") orelse continue).asString() orelse continue;
                        const d = if (item.field("default")) |x| (x.asString() orelse "") else "";
                        base.append(a, .{ .name = n, .default = d }) catch break;
                    }
                }
            }
        }
        if (doc.field("actions")) |av| {
            if (av.asArray()) |arr| {
                var list: std.ArrayListUnmanaged(SheetPreset) = .empty;
                for (arr) |act| {
                    const p = parseSheetPreset(a, act, base.items) orelse continue;
                    list.append(a, p) catch break;
                }
                self.sheet_presets = list.items;
            }
        }
    }

    /// The current drill-down level of the sheet: the root list, or a subcommand's children.
    fn sheetContext(self: *const App) []const SheetEntry {
        var level = self.sheet_root;
        for (self.sheet_path[0..self.sheet_depth]) |i| {
            if (i >= level.len) return level;
            level = level[i].children;
        }
        return level;
    }

    fn sheetContextLabel(self: *const App) []const u8 {
        var level = self.sheet_root;
        var label = self.sheet_tool;
        for (self.sheet_path[0..self.sheet_depth]) |i| {
            if (i >= level.len) break;
            label = level[i].label;
            level = level[i].children;
        }
        return label;
    }

    fn fetchSpec(self: *App, idx: usize) void {
        self.form_var_count = 0;
        self.form_action_label = "";
        self.form_desc = "";
        self.form_danger = false;
        self.form_status = "";
        self.form_exe_default = "";
        if (idx >= self.nodes.items.len) return;

        // A raw command has no CDL form to fetch. Its ports are both available (a pipe edge can feed
        // it and its output is captured), and the inspector draws its own editor. A free command
        // bound to a tool still gets that tool's sheet — the binding is `GNode.cdl`.
        if (isRaw(&self.nodes.items[idx])) {
            self.nodes.items[idx].has_stdin = true;
            self.nodes.items[idx].has_stdout = true;
            self.fetchSheet(idx);
            return;
        }

        const a = self.graph_arena.allocator();
        const cdl_name = self.nodes.items[idx].cdl;
        const action_name = self.nodes.items[idx].action;

        const params = std.fmt.allocPrint(a, "{{\"name\":\"{s}\"}}", .{cdl_name}) catch return;
        const text = self.call(a, "cdl.get", params) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;
        // Accept the document either wrapped in `doc` or returned directly.
        const doc = result.field("doc") orelse result;

        const actions = if (doc.field("actions")) |x| (x.asArray() orelse return) else return;
        // Collect every action so the inspector can offer a selector (the web version has one too).
        self.form_action_count = 0;
        for (actions) |cand| {
            if (self.form_action_count >= self.form_actions.len) break;
            const n = if (cand.field("name")) |v| (v.asString() orelse "") else "";
            if (n.len == 0) continue;
            const l = if (cand.field("label")) |v| (v.asString() orelse n) else n;
            self.form_actions[self.form_action_count] = .{ .name = n, .label = l };
            self.form_action_count += 1;
        }
        var chosen: ?pipelith.value.Value = null;
        for (actions) |cand| {
            if (chosen == null) chosen = cand; // fall back to the first action
            const n = if (cand.field("name")) |v| (v.asString() orelse "") else "";
            if (std.mem.eql(u8, n, action_name)) {
                chosen = cand;
                break;
            }
        }
        const act = chosen orelse return;

        if (act.field("label")) |v| {
            if (v.asString()) |s| self.form_action_label = s;
        }
        if (act.field("description")) |v| {
            if (v.asString()) |s| self.form_desc = s;
        }
        if (act.field("danger")) |v| self.form_danger = v.asBool() orelse false;
        if (act.field("executable")) |v| {
            if (v.asString()) |s| self.form_exe_default = s;
        }

        const stdin_mode = if (act.field("stdin")) |v| (v.asString() orelse "none") else "none";
        const stdout_mode = if (act.field("stdout")) |v| (v.asString() orelse "capture") else "capture";
        self.nodes.items[idx].has_stdin = !std.mem.eql(u8, stdin_mode, "none");
        self.nodes.items[idx].has_stdout = !std.mem.eql(u8, stdout_mode, "discard");

        const vars = if (act.field("variables")) |v| (v.asArray() orelse return) else return;
        for (vars) |entry| {
            if (self.form_var_count >= self.form_vars.len) break;
            const spec = parseVar(a, entry) orelse continue;
            self.form_vars[self.form_var_count] = spec;
            self.form_var_count += 1;
            if (self.nodes.items[idx].values.get(spec.name) == null) {
                self.setValue(idx, spec.name, spec.default);
            }
        }
    }

    /// Removes one node and every edge touching it, without recording history — so a multi-delete
    /// can collapse into a single undo step.
    fn removeNodeNoCommit(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        const id = self.nodes.items[idx].id;

        var i: usize = 0;
        while (i < self.edges.items.len) {
            const e = self.edges.items[i];
            if (std.mem.eql(u8, e.from, id) or std.mem.eql(u8, e.to, id)) {
                _ = self.edges.swapRemove(i);
            } else i += 1;
        }
        self.freeNodeValues(idx);
        _ = self.nodes.swapRemove(idx);

        self.selected = null;
        self.form_node = null;
        self.form_loaded = false;
        self.form_var_count = 0;
    }

    fn deleteNode(self: *App, idx: usize) void {
        if (idx >= self.nodes.items.len) return;
        self.removeNodeNoCommit(idx);
        self.commit();
        self.hint(.node_deleted);
    }

    // ── user tools: saving a command as a reusable tool ──────────────────────

    /// Opens a user tool's source in the inspector. Only user tools can be edited: a built-in lives
    /// inside the binary, and "editing" it would mean writing a shadowing copy, which is a different
    /// decision than the one the user just made by clicking Edit on a tool they created.
    fn beginEditTool(self: *App, name: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var params: std.ArrayListUnmanaged(u8) = .empty;
        params.appendSlice(a, "{\"name\":\"") catch return;
        jsonEscapeInto(a, &params, name) catch return;
        params.appendSlice(a, "\"}") catch return;

        const text = self.call(a, "cdl.get", params.items) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;
        const raw = if (result.field("raw")) |r| (r.asString() orelse "") else "";

        if (self.edit_source.len > 0) self.gpa.free(self.edit_source);
        self.edit_source = self.gpa.dupe(u8, raw) catch &.{};
        const ga = self.graph_arena.allocator();
        self.editing_tool = ga.dupe(u8, name) catch null;
        self.edit_error = "";
    }

    fn closeToolEditor(self: *App) void {
        if (self.edit_source.len > 0) self.gpa.free(self.edit_source);
        self.edit_source = &.{};
        self.editing_tool = null;
        self.edit_error = "";
    }

    /// Validates and writes the edited tool. `cdl.save` refuses an invalid document before touching
    /// the disk, so a failed save leaves the previous version intact and the error is shown in place.
    fn saveEditedTool(self: *App) void {
        const name = self.editing_tool orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var params: std.ArrayListUnmanaged(u8) = .empty;
        params.appendSlice(a, "{\"raw\":\"") catch return;
        jsonEscapeInto(a, &params, self.edit_source) catch return;
        params.appendSlice(a, "\"}") catch return;

        const text = self.call(a, "cdl.save", params.items) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        if (parsed.ok.field("error")) |err| {
            const msg = if (err.field("message")) |m| (m.asString() orelse "") else "";
            const ga = self.graph_arena.allocator();
            self.edit_error = ga.dupe(u8, msg) catch "";
            return;
        }
        _ = name;
        self.closeToolEditor();
        self.reloadLibrary();
        self.hint(.tool_saved_edited);
    }

    /// Deletes a user tool. Built-ins are refused by the engine; the button is not even drawn for
    /// them, so this is only reachable for tools the user created.
    fn deleteTool(self: *App, name: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var params: std.ArrayListUnmanaged(u8) = .empty;
        params.appendSlice(a, "{\"name\":\"") catch return;
        jsonEscapeInto(a, &params, name) catch return;
        params.appendSlice(a, "\"}") catch return;
        _ = self.call(a, "cdl.delete", params.items);
        self.tool_pending_delete = null;
        self.reloadLibrary();
    }

    /// Native file/folder dialog through the engine's `fs.pick` (the pl_pick helper). Requires the
    /// child process, so it cannot be exercised inside the agent sandbox — see ARCHITECTURE §10.
    fn pickPath(self: *App, idx: usize, spec: VarSpec) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const kind = if (std.mem.eql(u8, spec.vtype, "directory")) "directory" else "file";
        const params = std.fmt.allocPrint(a, "{{\"kind\":\"{s}\",\"save\":{s}}}", .{
            kind,
            if (spec.save) "true" else "false",
        }) catch return;
        const text = self.call(a, "fs.pick", params) orelse {
            self.form_status = StrKey.picker_cannot_open.get(self.lang);
            return;
        };
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse {
            self.form_status = StrKey.picker_unavailable.get(self.lang);
            return;
        };
        if (result.field("path")) |p| {
            if (p.asString()) |s| {
                if (s.len > 0) self.setValue(idx, spec.name, s);
            }
        }
    }

    /// Mirrors the checks the web front end applies (web/form.js). Messages are Chinese because
    /// the native strings are not yet routed through the i18n table; they are all literals in this
    /// one function so the i18n slice has a single place to lift them from.
    /// Language-independent validation verdict: the *code* is the contract (asserted by the test
    /// harness), the message is presentation.
    fn validateCode(spec: VarSpec, value: []const u8) ?StrKey {
        if (spec.required and value.len == 0) return .err_required;
        if (value.len == 0) return null;
        if (std.mem.eql(u8, spec.vtype, "number")) {
            const n = asNumber(value) orelse return .err_not_a_number;
            if (spec.min) |mn| {
                if (n < mn) return .err_below_min;
            }
            if (spec.max) |mx| {
                if (n > mx) return .err_above_max;
            }
        }
        if (std.mem.eql(u8, spec.vtype, "enum") and spec.options.len > 0) {
            for (spec.options) |o| {
                if (std.mem.eql(u8, o.value, value)) return null;
            }
            return .err_invalid_option;
        }
        if (spec.filters.len > 0) {
            const base = std.fs.path.basename(value);
            for (spec.filters) |f| {
                // "*.mp4" style filters compare the extension; anything else must match exactly.
                if (f.len > 2 and f[0] == '*' and f[1] == '.') {
                    if (std.mem.endsWith(u8, base, f[1..])) return null;
                } else if (std.mem.eql(u8, base, f)) return null;
            }
            return .err_filter_mismatch;
        }
        return null;
    }

    fn validate(self: *App, spec: VarSpec, value: []const u8) ?[:0]const u8 {
        const code = validateCode(spec, value) orelse return null;
        return code.get(self.lang);
    }

    /// Stable wire name for a validation code, so the test harness never depends on UI language.
    fn codeName(key: StrKey) []const u8 {
        return switch (key) {
            .err_required => "required",
            .err_not_a_number => "not_a_number",
            .err_below_min => "below_min",
            .err_above_max => "above_max",
            .err_invalid_option => "invalid_option",
            else => "filter_mismatch",
        };
    }

    /// One JSON-RPC round trip against the in-process service. The response text is owned by `a`.
    fn call(self: *App, a: std.mem.Allocator, method: []const u8, params_json: []const u8) ?[]const u8 {
        const req = std.fmt.allocPrint(
            a,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        ) catch return null;
        const responses = rpc.handleRequest(self.svc, a, req) catch return null;
        if (responses.len == 0) return null;
        return responses[0];
    }

    fn refresh(self: *App) void {
        _ = self.list_arena.reset(.retain_capacity);
        const a = self.list_arena.allocator();
        self.item_count = 0;

        var esc_buf: [256]u8 = undefined;
        const raw_query = std.mem.sliceTo(&self.search, 0);
        const query = jsonEscape(&esc_buf, raw_query);
        var esc_cat: [128]u8 = undefined;
        const cat = jsonEscape(&esc_cat, self.category[0..self.category_len]);

        const params = std.fmt.allocPrint(a, "{{\"query\":\"{s}\",\"category\":\"{s}\"}}", .{ query, cat }) catch return;
        const text = self.call(a, "cdl.list", params) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;

        if (result.field("categories")) |cats| {
            if (cats.asArray()) |arr| {
                self.category_count = 0;
                for (arr) |c| {
                    if (self.category_count >= self.categories.len) break;
                    self.categories[self.category_count] = c.asString() orelse continue;
                    self.category_count += 1;
                }
            }
        }

        if (result.field("total")) |t| self.tool_total = @intCast(t.asInt() orelse 0);

        const list = result.field("items") orelse return;
        const arr = list.asArray() orelse return;
        for (arr) |entry| {
            if (self.item_count >= max_items) break;
            const obj = entry;
            // A node needs a concrete action; take the CDL's first one as the default.
            var action_name: []const u8 = "";
            var action_label: []const u8 = "";
            if (obj.field("actions")) |acts| {
                if (acts.asArray()) |al| {
                    if (al.len > 0) {
                        if (al[0].field("name")) |x| action_name = x.asString() orelse "";
                        if (al[0].field("label")) |x| action_label = x.asString() orelse "";
                    }
                }
            }
            self.items[self.item_count] = .{
                .name = obj.field("name").?.asString() orelse "",
                .display = obj.field("displayName").?.asString() orelse "",
                .desc = if (obj.field("description")) |d| (d.asString() orelse "(no description)") else "(no description)",
                .version = if (obj.field("version")) |v| (v.asString() orelse "") else "",
                .category = obj.field("category").?.asString() orelse "other",
                .available = if (obj.field("available")) |av| (av.asBool() orelse false) else false,
                .action_name = action_name,
                .action_label = action_label,
                .source = if (obj.field("source")) |sv| (sv.asString() orelse "builtin") else "builtin",
                // The program a free command node starts with (the tool's effective executable).
                .exe = if (obj.field("executable")) |x| (x.asString() orelse "") else "",
            };
            self.item_count += 1;
        }
    }

    fn loadInfo(self: *App) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = self.call(a, "app.info", "{}") orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;
        if (result.field("version")) |v| {
            if (v.asString()) |s| {
                if (self.gpa.dupe(u8, s)) |copy| {
                    // Release the previous copy: reloadLibrary() calls this repeatedly, and without
                    // this the old string would be orphaned on every reload.
                    if (self.version_owned) self.gpa.free(self.version);
                    self.version = copy;
                    self.version_owned = true;
                } else |_| {}
            }
        }
        // A real answer from the engine means the in-process service is live.
        self.engine_ok = true;
    }

    /// Reads the tool packs this installation offers. Nothing here is active: the list is what the
    /// user may install, and it is refreshed after every install so the "installed" marks stay true.
    fn loadPacks(self: *App) void {
        _ = self.pack_arena.reset(.retain_capacity);
        const a = self.pack_arena.allocator();
        self.pack_count = 0;

        const text = self.call(a, "pack.list", "{}") orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        const result = parsed.ok.field("result") orelse return;

        if (result.field("dirs")) |dirs| {
            if (dirs.asArray()) |arr| {
                self.pack_dir_count = 0;
                for (arr) |d| {
                    if (self.pack_dir_count >= self.pack_dirs.len) break;
                    self.pack_dirs[self.pack_dir_count] = d.asString() orelse continue;
                    self.pack_dir_count += 1;
                }
            }
        }

        const arr = (result.field("packs") orelse return).asArray() orelse return;
        for (arr) |entry| {
            if (self.pack_count >= max_packs) break;
            self.packs[self.pack_count] = .{
                .id = if (entry.field("id")) |x| (x.asString() orelse "") else "",
                .label = if (entry.field("label")) |x| (x.asString() orelse "") else "",
                .desc = if (entry.field("description")) |x| (x.asString() orelse "") else "",
                .source = if (entry.field("source")) |x| (x.asString() orelse "") else "",
                .tools = intField(entry, "toolCount"),
                .installed = intField(entry, "installedCount"),
                .modified = intField(entry, "modifiedCount"),
                .complete = if (entry.field("installed")) |x| (x.asBool() orelse false) else false,
            };
            self.pack_count += 1;
        }
    }

    /// Installs one pack — the user's explicit "load these tools" action.
    ///
    /// The tools are written into the user's CDL directory, where they stay as editable as anything
    /// they wrote by hand, and the library is refreshed. A tool whose file already exists with
    /// different bytes is *kept*: the pack reports it instead of overwriting (rule 2).
    fn installPack(self: *App, id: []const u8) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();

        var esc: [160]u8 = undefined;
        const params = std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{jsonEscape(&esc, id)}) catch return;
        const text = self.call(a, "pack.load", params) orelse return;
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        if (parsed.ok.field("error") != null) {
            self.pack_status_key = .pack_failed;
            self.pack_status_len = copyZ(&self.pack_status, id);
            self.reloadLibrary();
            return;
        }
        const result = parsed.ok.field("result") orelse return;
        const written = if (result.field("written")) |x| (x.asArray() orelse &.{}) else &.{};
        const conflicts = if (result.field("conflicts")) |x| (x.asArray() orelse &.{}) else &.{};

        // One line that names exactly what happened, tool by tool: written, or kept because the
        // user's own copy of that tool differs.
        const names = if (conflicts.len > 0) conflicts else if (written.len > 0) written else &.{};
        self.pack_status_key = if (conflicts.len > 0)
            .pack_kept
        else if (written.len > 0)
            .pack_loaded
        else
            .pack_already;
        self.pack_status_len = joinNames(&self.pack_status, names);
        self.reloadLibrary();
    }

    /// Re-reads the engine's app info and CDL list. The engine watches its CDL directories, but the
    /// library shown here is a snapshot taken at startup, so this is how a newly added or edited CDL
    /// becomes visible without restarting the GUI.
    fn reloadLibrary(self: *App) void {
        self.loadInfo();
        self.refresh();
        self.loadPacks();
        self.form_loaded = false;
        self.hint(.library_reloaded);
    }

    // ── run / output ────────────────────────────────────────────────────────

    fn ensureLog(self: *App) void {
        if (self.log.len == 0) self.log = self.gpa.alloc(OutLine, log_capacity) catch &.{};
    }

    fn freeLogLine(self: *App, line: OutLine) void {
        self.gpa.free(line.node);
        self.gpa.free(line.text);
    }

    fn clearLog(self: *App) void {
        var i: usize = 0;
        while (i < self.log_count) : (i += 1) self.freeLogLine(self.logLine(i));
        self.log_count = 0;
        self.log_head = 0;
        self.last_log_count = 0;
    }

    /// Appends one line, evicting the oldest once the ring is full.
    fn pushLog(self: *App, node: []const u8, stream: StreamKind, text: []const u8) void {
        self.ensureLog();
        if (self.log.len == 0) return;
        const node_copy = self.gpa.dupe(u8, node) catch return;
        const text_copy = self.gpa.dupe(u8, text) catch {
            self.gpa.free(node_copy);
            return;
        };
        const entry = OutLine{ .node = node_copy, .stream = stream, .text = text_copy };
        if (self.log_count < self.log.len) {
            self.log[(self.log_head + self.log_count) % self.log.len] = entry;
            self.log_count += 1;
        } else {
            self.freeLogLine(self.log[self.log_head]);
            self.log[self.log_head] = entry;
            self.log_head = (self.log_head + 1) % self.log.len;
        }
    }

    fn logLine(self: *App, i: usize) OutLine {
        return self.log[(self.log_head + i) % self.log.len];
    }

    /// Serializes the canvas into the engine's flow contract:
    ///   nodes: [{id, cdl, action, title, values:{name:value}}]
    ///   edges: [{from, to, fromPort, toPort, kind}]
    /// This is the same shape `flow.build` / `run.start` accept and that src/graph.zig parses.
    /// Serializes the canvas to the engine's flow schema. This is both the payload for `flow.run`
    /// and the bytes written by `writeFlow`, so it has to carry everything `graph.loadFromValue`
    /// reads back: the name, the viewport and each node's position. Omitting the positions would
    /// mean a round trip silently discards the user's arrangement, and the viewport would be
    /// re-framed on every open.
    fn flowJson(self: *App, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(a, "{\"name\":\"");
        try jsonEscapeInto(a, &out, self.flowName());
        var vpbuf: [160]u8 = undefined;
        try out.appendSlice(a, std.mem.span(fmtZ(&vpbuf, "\",\"viewport\":{{\"x\":{d},\"y\":{d},\"zoom\":{d}}}", .{
            self.view_pan_x,
            self.view_pan_y,
            self.view_zoom,
        })));
        try out.appendSlice(a, ",\"nodes\":[");
        for (self.nodes.items, 0..) |n, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, "{\"id\":\"");
            try jsonEscapeInto(a, &out, n.id);
            try out.appendSlice(a, "\",\"cdl\":\"");
            try jsonEscapeInto(a, &out, n.cdl);
            try out.appendSlice(a, "\",\"action\":\"");
            try jsonEscapeInto(a, &out, n.action);
            try out.appendSlice(a, "\",\"title\":\"");
            try jsonEscapeInto(a, &out, n.title);
            var nb: [320]u8 = undefined;
            try out.appendSlice(a, std.mem.span(fmtZ(&nb, "\",\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}", .{
                n.x,
                n.y,
                n.w,
                n.h,
            })));
            try out.appendSlice(a, ",\"values\":{");
            var vit = n.values.iterator();
            var first = true;
            while (vit.next()) |entry| {
                if (!first) try out.append(a, ',');
                first = false;
                try out.append(a, '"');
                try jsonEscapeInto(a, &out, entry.key_ptr.*);
                try out.appendSlice(a, "\":\"");
                try jsonEscapeInto(a, &out, entry.value_ptr.*);
                try out.append(a, '"');
            }
            try out.appendSlice(a, "},\"disabled\":");
            try out.appendSlice(a, if (n.disabled) "true" else "false");
            if (n.timeout_ms) |t| {
                var tb: [48]u8 = undefined;
                try out.appendSlice(a, std.mem.span(fmtZ(&tb, ",\"timeoutMs\":{d}", .{t})));
            } else {
                try out.appendSlice(a, ",\"timeoutMs\":null");
            }
            var rb: [48]u8 = undefined;
            try out.appendSlice(a, std.mem.span(fmtZ(&rb, ",\"retry\":{d},\"note\":\"", .{n.retry})));
            try jsonEscapeInto(a, &out, n.note);
            try out.append(a, '"');
            // Only emitted when set, so an ordinary node's document is unchanged.
            if (n.executable.len > 0) {
                try out.appendSlice(a, ",\"executable\":\"");
                try jsonEscapeInto(a, &out, n.executable);
                try out.append(a, '"');
            }
            if (n.argv.len > 0) {
                try out.appendSlice(a, ",\"argv\":[");
                for (n.argv, 0..) |p, k| {
                    if (k > 0) try out.append(a, ',');
                    try out.append(a, '"');
                    try jsonEscapeInto(a, &out, p);
                    try out.append(a, '"');
                }
                try out.append(a, ']');
            }
            // Closes the node object. The note string was already closed above, so this is the
            // brace only — emitting `"}` here would leave a stray quote and invalidate the file.
            try out.append(a, '}');
        }
        try out.appendSlice(a, "],\"edges\":[");
        for (self.edges.items, 0..) |e, i| {
            if (i > 0) try out.append(a, ',');
            try out.appendSlice(a, "{\"from\":\"");
            try jsonEscapeInto(a, &out, e.from);
            try out.appendSlice(a, "\",\"to\":\"");
            try jsonEscapeInto(a, &out, e.to);
            try out.appendSlice(a, "\",\"fromPort\":\"");
            try jsonEscapeInto(a, &out, e.from_port);
            try out.appendSlice(a, "\",\"toPort\":\"");
            try jsonEscapeInto(a, &out, e.to_port);
            try out.appendSlice(a, "\",\"kind\":\"");
            try out.appendSlice(a, e.kind.wire());
            try out.appendSlice(a, "\"}");
        }
        try out.appendSlice(a, "]}");
        return out.items;
    }

    /// Reports a JSON-RPC failure from a run call into the output panel, so the reason is visible
    /// instead of the panel silently staying empty.
    fn reportCallError(self: *App, parsed: pipelith.value.Value) bool {
        const err = parsed.field("error") orelse return false;
        const msg = if (err.field("message")) |m| (m.asString() orelse self.trs(.run_failed)) else self.trs(.run_failed);
        self.pushLog("", .system, msg);
        self.run_error = msg;
        return true;
    }

    fn doPreview(self: *App) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        self.clearLog();
        self.run_error = "";
        if (self.nodes.items.len == 0) {
            self.run_error = self.trs(.canvas_is_empty);
            self.pushLog("", .system, self.trs(.canvas_is_empty_hint));
            return;
        }

        const flow = self.flowJson(a) catch return;
        const params = std.fmt.allocPrint(a, "{{\"flow\":{s}}}", .{flow}) catch return;
        const text = self.call(a, "run.preview", params) orelse {
            self.run_error = self.trs(.preview_failed);
            return;
        };
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        if (self.reportCallError(parsed.ok)) return;

        const result = parsed.ok.field("result") orelse return;
        const cmds = if (result.field("commands")) |c| (c.asArray() orelse return) else return;
        self.pushLog("", .system, self.trs(.preview_commands));
        for (cmds) |c| {
            const id = if (c.field("id")) |x| (x.asString() orelse "") else "";
            const disp = if (c.field("display")) |x| (x.asString() orelse "") else "";
            self.pushLog(id, .stdout, disp);
        }
        if (cmds.len == 0) self.pushLog("", .system, self.trs(.no_commands));
        if (result.field("affectedPaths")) |p| {
            if (p.asArray()) |arr| {
                if (arr.len > 0) {
                    self.pushLog("", .system, self.trs(.affected_paths));
                    for (arr) |x| {
                        if (x.asString()) |s| self.pushLog("", .system, s);
                    }
                }
            }
        }
        self.output_tab = -1;
    }

    fn doRun(self: *App) void {
        if (self.running) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        self.clearLog();
        self.run_error = "";
        if (self.nodes.items.len == 0) {
            self.run_error = self.trs(.canvas_is_empty);
            self.pushLog("", .system, self.trs(.canvas_is_empty_hint));
            return;
        }

        const flow = self.flowJson(a) catch return;
        const params = std.fmt.allocPrint(a, "{{\"flow\":{s}}}", .{flow}) catch return;
        const text = self.call(a, "run.start", params) orelse {
            self.run_error = self.trs(.cannot_start_run);
            return;
        };
        const parsed = pipelith.value.Value.parseJson(a, text);
        if (parsed != .ok) return;
        if (self.reportCallError(parsed.ok)) return;

        const result = parsed.ok.field("result") orelse return;
        if (result.field("runId")) |r| {
            if (r.asString()) |s| {
                // Run ids are few and short; graph_arena keeps them valid for the session.
                self.run_id = self.graph_arena.allocator().dupe(u8, s) catch self.run_id;
            }
        }
        self.running = true;
        self.run_status = .running;
        self.run_duration_ms = 0;
        for (self.nodes.items) |*n| {
            n.status = .pending;
            n.exit_code = null;
            n.duration_ms = 0;
        }
        self.output_tab = -1;
    }

    fn doStop(self: *App) void {
        if (!self.running) return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        _ = self.call(scratch.allocator(), "run.cancel", "{}");
        self.pushLog("", .system, self.trs(.stop_requested));
    }

    /// Consumes everything the engine pushed through the sink since the last frame. Each message is
    /// `{"method":"event.<name>","seq":N,"params":{...}}` (see rpc.pushEvent).
    fn drainEvents(self: *App, a: std.mem.Allocator) void {
        const events = self.sink.drain(a);
        for (events) |raw| {
            const parsed = pipelith.value.Value.parseJson(a, raw);
            if (parsed != .ok) continue;
            const method = if (parsed.ok.field("method")) |m| (m.asString() orelse "") else "";
            const params = parsed.ok.field("params") orelse continue;
            const node_id = if (params.field("nodeId")) |x| (x.asString() orelse "") else "";

            if (std.mem.eql(u8, method, "event.node.started")) {
                if (self.nodeById(node_id)) |idx| self.nodes.items[idx].status = .running;
                self.pushLog(node_id, .system, self.trs(.exec_started));
            } else if (std.mem.eql(u8, method, "event.node.output")) {
                const stream = StreamKind.parse(if (params.field("stream")) |x| (x.asString() orelse "system") else "system");
                const text = if (params.field("text")) |x| (x.asString() orelse "") else "";
                // A stdout chunk can carry several lines; the panel is line-oriented, so split it.
                // Keeping the newlines embedded would render (and dump) one line plus a blank one.
                var rest = text;
                while (rest.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    const piece = if (nl) |k| rest[0..k] else rest;
                    const trimmed = std.mem.trimEnd(u8, piece, "\r");
                    if (trimmed.len > 0) self.pushLog(node_id, stream, trimmed);
                    rest = if (nl) |k| rest[k + 1 ..] else "";
                }
            } else if (std.mem.eql(u8, method, "event.node.finished")) {
                const st = NodeStatus.parse(if (params.field("status")) |x| (x.asString() orelse "") else "");
                const dur: u64 = if (params.field("durationMs")) |x| (if (x.asInt()) |v| @as(u64, @intCast(@max(v, 0))) else 0) else 0;
                if (self.nodeById(node_id)) |idx| {
                    self.nodes.items[idx].status = st;
                    self.nodes.items[idx].duration_ms = dur;
                    self.nodes.items[idx].exit_code = if (params.field("exitCode")) |x|
                        (if (x.asInt()) |v| @as(i32, @intCast(v)) else null)
                    else
                        null;
                }
                var b: [192]u8 = undefined;
                // fmtZ yields a sentinel pointer; pushLog takes a slice.
                self.pushLog(node_id, .system, std.mem.span(fmtZ(&b, "■ {s} ({d} ms)", .{ st.label(self.lang), dur })));
                if (params.field("message")) |m| {
                    if (m.asString()) |s| {
                        if (s.len > 0) self.pushLog(node_id, .stderr, s);
                    }
                }
            } else if (std.mem.eql(u8, method, "event.run.finished")) {
                self.running = false;
                self.run_status = NodeStatus.parse(if (params.field("status")) |x| (x.asString() orelse "") else "");
                const dur: u64 = if (params.field("durationMs")) |x| (if (x.asInt()) |v| @as(u64, @intCast(@max(v, 0))) else 0) else 0;
                self.run_duration_ms = dur;
                var b: [192]u8 = undefined;
                self.pushLog("", .system, std.mem.span(fmtZ(&b, "{s}{s} ({d} ms)", .{ self.tr(.run_finished), self.run_status.label(self.lang), dur })));
            } else if (std.mem.eql(u8, method, "event.run.started")) {
                self.pushLog("", .system, self.trs(.run_started));
            } else if (std.mem.eql(u8, method, "event.log")) {
                const msg = if (params.field("message")) |x| (x.asString() orelse "") else "";
                self.pushLog("", .system, msg);
            }
        }
    }

    // ── panels ──────────────────────────────────────────────────────────────

    fn drawTopbar(self: *App) void {
        pl_gui_text_heading("Flow Pipelith");
        pl_gui_same_line();
        pl_gui_text_dim(self.flow_title);
        pl_gui_same_line();
        pl_gui_dummy(24, 0);
        pl_gui_same_line();
        // Only the global actions live here. The search box moved into the library panel (that is
        // what it filters) and the view controls onto the canvas, because a single row of all of
        // them overflowed the window and pushed the theme/language toggles out of reach.
        pl_gui_begin_disabled(if (self.canUndo()) 0 else 1);
        if (pl_gui_button(self.tr(.undo), 0, 0) == 1) self.undo();
        pl_gui_end_disabled();
        pl_gui_same_line();
        pl_gui_begin_disabled(if (self.canRedo()) 0 else 1);
        if (pl_gui_button(self.tr(.redo), 0, 0) == 1) self.redo();
        pl_gui_end_disabled();
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.new_workflow), 0, 0) == 1) self.doNew();
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.open), 0, 0) == 1) self.doOpen();
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.save), 0, 0) == 1) self.doSave();
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.preview), 0, 0) == 1) self.doPreview();
        pl_gui_same_line();
        pl_gui_begin_disabled(if (self.running) 1 else 0);
        if (pl_gui_button(self.tr(.run), 0, 0) == 1) self.doRun();
        pl_gui_end_disabled();
        pl_gui_same_line();
        pl_gui_begin_disabled(if (self.running) 0 else 1);
        if (pl_gui_button(self.tr(.stop), 0, 0) == 1) self.doStop();
        pl_gui_end_disabled();
        pl_gui_same_line();
        pl_gui_dummy(16, 0);
        pl_gui_same_line();
        // The label shows what clicking switches *to*.
        if (pl_gui_button(self.tr(themeLabelKey(self.theme_kind.other())), 0, 0) == 1) {
            self.theme_kind = self.theme_kind.other();
            self.applyTheme();
            self.savePrefs();
        }
        pl_gui_same_line();
        if (pl_gui_button(self.lang.other().label().ptr, 0, 0) == 1) {
            self.toggleLang();
            self.savePrefs();
        }
    }

    fn drawLibrary(self: *App, body_h: f32) void {
        pl_gui_begin_child("##library", 300, body_h, 1);

        var buf: [128]u8 = undefined;
        const title = fmtZ(&buf, "{s}  {d}", .{ self.tr(.tool_library), self.item_count });
        pl_gui_separator_text(title);
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.reload_library), 0, 0) == 1) self.reloadLibrary();

        // The escape hatch, right where the tool list is: anything the library does not describe can
        // still be added, by pointing at the program itself.
        if (pl_gui_button(self.tr(.add_command), 0, 0) == 1) {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            if (self.askPath(scratch.allocator(), "file", false)) |picked| {
                if (self.addCommandNode(picked, 60, 60)) |_| {
                    self.form_loaded = false;
                }
            } else {
                self.hint(.picker_unavailable);
            }
        }

        // The search box lives here because it filters this list (it is a `cdl.list` query). In the
        // topbar it competed with the action buttons for one row and pushed the theme and language
        // toggles past the window edge.
        pl_gui_set_next_item_width(-1);
        // Ctrl+F lands here: SetKeyboardFocusHere applies to the next widget submitted, so the flag
        // is consumed the frame after the shortcut fires.
        if (self.focus_search) {
            pl_gui_set_keyboard_focus_here();
            self.focus_search = false;
        }
        if (pl_gui_input_text_hint("##search", self.tr(.search_placeholder), &self.search, self.search.len) == 1) {
            self.refresh();
        }

        // The category filter is only meaningful once something is loaded: with an empty library it
        // would occupy the panel with rows that cannot match anything and push the pack list — the
        // one thing a fresh installation needs to see — below the visible area.
        if (self.tool_total > 0) {
            if (pl_gui_selectable(self.tr(.all), if (self.category_len == 0) 1 else 0) == 1) {
                self.category_len = 0;
                self.refresh();
            }
            for (self.categories[0..self.category_count]) |c| {
                const selected: c_int = if (std.mem.eql(u8, c, self.category[0..self.category_len])) 1 else 0;
                const z = dupeZ(self.gpa, c) catch continue;
                defer self.gpa.free(z);
                if (pl_gui_selectable(z.ptr, selected) == 1) {
                    const n = @min(c.len, self.category.len);
                    @memcpy(self.category[0..n], c[0..n]);
                    self.category_len = n;
                    self.refresh();
                }
            }
        }

        pl_gui_separator();

        // Both lists get a bounded height instead of the tool list swallowing the panel: a child that
        // fills the remaining space would push the pack list below the visible area, which is exactly
        // where a fresh installation has to look. With an empty library the tool list holds one hint,
        // so the pack section — including the directories a pack may be put in — gets the room.
        const empty_library = self.tool_total == 0;
        const list_h: f32 = if (empty_library)
            118
        else if (body_h > 420)
            body_h * 0.45
        else
            160;
        const pack_h: f32 = if (empty_library)
            (if (body_h > 320) body_h * 0.56 else 160)
        else if (body_h > 420)
            body_h * 0.32
        else
            120;
        pl_gui_begin_child("##liblist", 0, list_h, 0);
        // "Nothing here" has two very different causes: no tool is installed at all (the state of a
        // fresh installation — the packs below are the way out) or the filter matched none of the
        // tools that are installed. They get different words.
        if (self.item_count == 0 and self.tool_total > 0) {
            pl_gui_text_dim(self.tr(.no_matching_tools));
        }
        if (self.item_count == 0 and self.tool_total == 0) {
            pl_gui_text_dim_wrapped(self.tr(.no_tools_loaded));
        }
        for (self.items[0..self.item_count], 0..) |item, i| {
            const z = dupeZ(self.gpa, item.display) catch continue;
            defer self.gpa.free(z);
            // A click adds the node at a free slot; a press-and-drag drops it where released (see
            // drawToolDrag). A completed drag suppresses the click so it cannot add twice. Either
            // way the node is a free command bound to the tool — its sheet, not a fixed action,
            // is what the tool brings to the canvas.
            if (pl_gui_selectable(z.ptr, 0) == 1 and !self.drag_moved) self.addFreeNode(item);
            if (pl_gui_item_active() == 1) self.drag_tool = i;
            var nb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&nb, "{s}", .{item.name}));
            if (item.version.len > 0) {
                pl_gui_same_line();
                var vb: [64]u8 = undefined;
                pl_gui_text_dim(fmtZ(&vb, "v{s}", .{item.version}));
            }
            // User tools are marked, and only they can be deleted: a built-in is replaced by saving a
            // tool of the same name, not by removing something that ships with the program.
            if (std.mem.eql(u8, item.source, "user")) {
                pl_gui_same_line();
                var ub: [32]u8 = undefined;
                pl_gui_text_dim(fmtZ(&ub, "[{s}]", .{self.tr(.user_tool)}));
                pl_gui_same_line();
                const armed = self.tool_pending_delete != null and
                    std.mem.eql(u8, self.tool_pending_delete.?, item.name);
                // Per-item ids: these buttons sit in a loop, so an identical label would collide.
                var eb2: [192]u8 = undefined;
                var db2: [192]u8 = undefined;
                if (pl_gui_button(
                    fmtZ(&eb2, "{s}##edit_{s}", .{ self.tr(.edit_tool), item.name }),
                    0,
                    0,
                ) == 1) self.beginEditTool(item.name);
                pl_gui_same_line();
                const del_label = if (armed) self.tr(.confirm_delete_tool) else self.tr(.delete_tool);
                if (pl_gui_button(fmtZ(&db2, "{s}##del_{s}", .{ del_label, item.name }), 0, 0) == 1) {
                    if (armed) {
                        self.deleteTool(item.name);
                    } else {
                        self.tool_pending_delete = item.name;
                    }
                }
            }
            const dz = dupeZ(self.gpa, item.desc) catch continue;
            defer self.gpa.free(dz);
            pl_gui_text_wrapped(dz.ptr);
            pl_gui_separator();
        }
        pl_gui_end_child();

        self.drawPacks(pack_h);
        pl_gui_end_child();
    }

    /// The pack list: what this installation *could* load, and the one control that loads it.
    ///
    /// Packs are stored separately from the program's defaults and none of them is active until the
    /// user installs one here — the tool library above stays empty until then, on purpose.
    fn drawPacks(self: *App, height: f32) void {
        pl_gui_separator();
        var hb: [128]u8 = undefined;
        pl_gui_separator_text(fmtZ(&hb, "{s}  {d}", .{ self.tr(.packs), self.pack_count }));
        pl_gui_text_dim_wrapped(self.tr(.packs_hint));
        // No pack at all is the state of a fresh installation: say where one may be put instead of
        // showing an empty list, because packs are separate items the user brings in.
        if (self.pack_count == 0) {
            pl_gui_text_dim_wrapped(self.tr(.packs_none));
            for (self.pack_dirs[0..self.pack_dir_count]) |dir| {
                const dz = dupeZ(self.gpa, dir) catch continue;
                defer self.gpa.free(dz);
                pl_gui_text_dim_wrapped(dz.ptr);
            }
        }
        if (self.pack_status_len > 0) {
            var sb: [288]u8 = undefined;
            pl_gui_text_dim_wrapped(fmtZ(&sb, "{s}: {s}", .{
                self.tr(self.pack_status_key),
                self.pack_status[0..self.pack_status_len],
            }));
        }

        pl_gui_begin_child("##packlist", 0, height, 0);
        for (self.packs[0..self.pack_count], 0..) |p, i| {
            var bb: [192]u8 = undefined;
            if (p.complete) {
                pl_gui_text_dim(self.tr(.pack_installed));
            } else if (pl_gui_button(fmtZ(&bb, "{s}##load_{d}", .{ self.tr(.pack_load), i }), 0, 0) == 1) {
                self.installPack(p.id);
            }
            pl_gui_same_line();
            const label = if (p.label.len > 0) p.label else p.id;
            const lz = dupeZ(self.gpa, label) catch continue;
            defer self.gpa.free(lz);
            pl_gui_text(lz.ptr);
            var cb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&cb, "{d} {s} · {s} {d}/{d}", .{
                p.tools,
                self.tr(.pack_tools),
                self.tr(.pack_installed),
                p.installed + p.modified,
                p.tools,
            }));
            if (p.desc.len > 0) {
                const dz = dupeZ(self.gpa, p.desc) catch continue;
                defer self.gpa.free(dz);
                pl_gui_text_dim_wrapped(dz.ptr);
            }
            pl_gui_separator();
        }
        pl_gui_end_child();
    }

    fn toScreen(self: *App, ox: f32, oy: f32, wx: f32, wy: f32) [2]f32 {
        return .{
            ox + (self.view_pan_x + wx) * self.view_zoom,
            oy + (self.view_pan_y + wy) * self.view_zoom,
        };
    }

    fn drawCanvas(self: *App, w: f32, body_h: f32) void {
        pl_gui_begin_child("##canvas", w, body_h, 1);
        pl_gui_separator_text(self.tr(.canvas));
        // View controls sit on the canvas they affect, as the web build's floating canvas toolbar
        // did. They are laid out before the canvas rect is measured, so the toolbar never overlaps
        // the drawable area.
        if (pl_gui_button(self.tr(.auto_layout), 0, 0) == 1) self.autoLayout();
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.zoom_out), 0, 0) == 1) self.zoomBy(0.85);
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.zoom_in), 0, 0) == 1) self.zoomBy(1.18);
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.fit_view), 0, 0) == 1) self.fitView();
        // No zoom readout here: the status bar already reports it, and repeating it pushed the Fit
        // button off the edge of a narrow canvas in English.
        // The canvas rect is measured from the cursor below, so the toolbar line must be closed
        // first — otherwise the drawable area would start on the toolbar's own row.
        pl_gui_new_line();

        var aw: f32 = 0;
        var ah: f32 = 0;
        pl_gui_content_avail(&aw, &ah);
        var ox: f32 = 0;
        var oy: f32 = 0;
        pl_gui_cursor_pos(&ox, &oy);
        const z = self.view_zoom;
        // Remembered so the toolbar's fit action and library drag-and-drop can map screen ↔ world
        // without re-deriving the panel layout.
        self.canvas_rect = .{ ox, oy, ox + aw, oy + ah };

        // Blueprint grid, like the web canvas background. Skipped when zoomed far out, where the
        // lines would merge into a solid block.
        {
            const step = 40 * z;
            if (step > 6) {
                var gx = ox + @mod(self.view_pan_x * z, step);
                while (gx < ox + aw) : (gx += step) {
                    pl_gui_dl_line(gx, oy, gx, oy + ah, self.pal.grid, 1);
                }
                var gy = oy + @mod(self.view_pan_y * z, step);
                while (gy < oy + ah) : (gy += step) {
                    pl_gui_dl_line(ox, gy, ox + aw, gy, self.pal.grid, 1);
                }
            }
        }

        // ── pass 1: paint edges, then node cards on top ──
        for (self.edges.items) |e| {
            const fi = self.nodeById(e.from) orelse continue;
            const ti = self.nodeById(e.to) orelse continue;
            const f = self.nodes.items[fi];
            const t = self.nodes.items[ti];
            // Leave/enter the port that matches the kind: pipe = stdout/stdin (y+40),
            // seq = done/run (y+74) — the same rows the port dots are drawn on.
            const dy: f32 = if (e.kind == .pipe) 40 else 74;
            const a0 = self.toScreen(ox, oy, f.x + f.w, f.y + dy);
            const b0 = self.toScreen(ox, oy, t.x, t.y + dy);
            const bend = 90 * z;
            pl_gui_dl_bezier(a0[0], a0[1], a0[0] + bend, a0[1], b0[0] - bend, b0[1], b0[0], b0[1], edgeTint(e.kind, self.pal), 2.2 * z);
        }

        for (self.nodes.items, 0..) |n, i| {
            const p0 = self.toScreen(ox, oy, n.x, n.y);
            const p1 = self.toScreen(ox, oy, n.x + n.w, n.y + n.h);
            const h1 = self.toScreen(ox, oy, n.x + n.w, n.y + 30);
            const tint = categoryTint(n.category, self.pal);
            const rounding = 8 * z;
            const is_sel = self.selected != null and self.selected.? == i;

            pl_gui_dl_rect_filled(p0[0], p0[1], p1[0], p1[1], self.pal.node_bg, rounding, 0);
            pl_gui_dl_rect_filled(p0[0], p0[1], h1[0], h1[1], tint, rounding, 1);
            pl_gui_dl_rect(p0[0], p0[1], p1[0], p1[1], if (is_sel) self.pal.text else tint, rounding, if (is_sel) 2.6 * z else 1.6 * z);

            // Run status: a coloured dot in the header, with its label when the node has run.
            const st_col = n.status.tint(self.pal);
            pl_gui_dl_circle_filled(h1[0] - 13 * z, p0[1] + 15 * z, 5 * z, st_col);
            if (n.status != .idle) {
                var stb: [64]u8 = undefined;
                const lbl = fmtZ(&stb, "{s}", .{n.status.label(self.lang)});
                const lbl_w = pl_gui_calc_text_width(lbl);
                pl_gui_dl_text(h1[0] - 24 * z - lbl_w, p0[1] + 7 * z, st_col, lbl);
            }

            var tb: [160]u8 = undefined;
            pl_gui_dl_text(p0[0] + 8 * z, p0[1] + 7 * z, self.pal.node_header_text, fmtZ(&tb, "{s}", .{n.title}));
            var sb: [224]u8 = undefined;
            // A raw command has no cdl/action, so `"{s} · {s}"` would draw a bare separator. Show
            // the command instead — that is the useful summary for a node with no tool behind it.
            if (isRaw(&n)) {
                var cmd: [192]u8 = undefined;
                var cw: usize = 0;
                for (n.argv[1..]) |arg| {
                    if (cw + arg.len + 2 >= cmd.len) break;
                    if (cw > 0) {
                        cmd[cw] = ' ';
                        cw += 1;
                    }
                    @memcpy(cmd[cw..][0..arg.len], arg);
                    cw += arg.len;
                }
                cmd[cw] = 0;
                pl_gui_dl_text(p0[0] + 8 * z, p0[1] + 42 * z, self.pal.text_dim, fmtZ(&sb, "{s}", .{cmd[0..cw]}));
            } else {
                pl_gui_dl_text(p0[0] + 8 * z, p0[1] + 42 * z, self.pal.text_dim, fmtZ(&sb, "{s} · {s}", .{ n.cdl, n.action }));
            }

            // Body: the first two filled values, so the card shows what the node will run with.
            var row: usize = 0;
            var vit = n.values.iterator();
            while (vit.next()) |entry| {
                if (row >= 2) break;
                if (entry.value_ptr.*.len == 0) continue;
                var vb: [224]u8 = undefined;
                const y = p0[1] + (62 + @as(f32, @floatFromInt(row)) * 18) * z;
                pl_gui_dl_text(p0[0] + 8 * z, y, self.pal.text, fmtZ(&vb, "{s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
                row += 1;
            }

            // Ports follow the action's stream modes: `stdin: none` and `stdout: discard` drop the
            // corresponding pipe port, exactly like web/form.js `portPlan`.
            const rp = 6 * z;
            if (n.has_stdin) pl_gui_dl_circle_filled(p0[0], p0[1] + 40 * z, rp, self.pal.edge_pipe);
            pl_gui_dl_circle_filled(p0[0], p0[1] + 74 * z, rp, self.pal.edge_seq);
            if (n.has_stdout) pl_gui_dl_circle_filled(p1[0], p0[1] + 40 * z, rp, self.pal.edge_pipe);
            pl_gui_dl_circle_filled(p1[0], p0[1] + 74 * z, rp, self.pal.edge_seq);
        }

        if (self.nodes.items.len == 0) {
            pl_gui_dl_text(ox + 16, oy + 18, self.pal.text, self.tr(.canvas_empty_title));
            pl_gui_dl_text(ox + 16, oy + 44, self.pal.text_dim, self.tr(.canvas_empty_pan));
            pl_gui_dl_text(ox + 16, oy + 68, self.pal.text_dim, self.tr(.canvas_empty_zoom));
            pl_gui_dl_text(ox + 16, oy + 92, self.pal.text_dim, self.tr(.canvas_empty_connect));
        }

        // ── pass 2: input. Submission order decides who owns the mouse (ImGui blocks hover for
        // later items once one has claimed it), so: ports → node bodies → canvas background. A port
        // therefore wins over the card it sits on, and a card wins over panning. ──
        var hovered_port: ?PortHit = null;
        for (self.nodes.items, 0..) |n, i| {
            if (n.has_stdin) self.portButton(i, .left, .pipe, ox, oy, &hovered_port);
            self.portButton(i, .left, .seq, ox, oy, &hovered_port);
            if (n.has_stdout) self.portButton(i, .right, .pipe, ox, oy, &hovered_port);
            self.portButton(i, .right, .seq, ox, oy, &hovered_port);
        }

        var active_node: ?usize = null;
        var clicked_node: ?usize = null;
        for (self.nodes.items, 0..) |n, i| {
            const p0 = self.toScreen(ox, oy, n.x, n.y);
            const p1 = self.toScreen(ox, oy, n.x + n.w, n.y + n.h);
            var ib: [64]u8 = undefined;
            pl_gui_set_cursor_screen_pos(p0[0], p0[1]);
            if (pl_gui_invisible_button(fmtZ(&ib, "##nd{s}", .{n.id}), p1[0] - p0[0], p1[1] - p0[1], 1) == 1) clicked_node = i;
            if (pl_gui_item_active() == 1) active_node = i;
        }

        pl_gui_set_cursor_screen_pos(ox, oy);
        _ = pl_gui_invisible_button("##canvasbg", aw, ah, 3);
        const bg_active = pl_gui_item_active() == 1;
        const bg_hovered = pl_gui_item_hovered() == 1;

        var dx: f32 = 0;
        var dy: f32 = 0;
        pl_gui_mouse_delta(&dx, &dy);

        if (active_node) |i| {
            // Dragging any member of a multi-selection moves the whole selection, which is what makes
            // a copy of several nodes usable.
            const move_all = self.isMarked(self.nodes.items[i].id) and self.marked_count > 1;
            if (move_all) {
                for (self.nodes.items) |*n| {
                    if (!self.isMarked(n.id)) continue;
                    n.x += dx / self.view_zoom;
                    n.y += dy / self.view_zoom;
                }
            } else {
                self.nodes.items[i].x += dx / self.view_zoom;
                self.nodes.items[i].y += dy / self.view_zoom;
            }
            self.selected = i;
            if (!move_all) self.markOnly(self.nodes.items[i].id);
        } else if (bg_active) {
            // Panning must not throw the selection away, but *clicking* empty space should. The
            // pointer's total travel over the drag is what tells the two apart.
            self.bg_travel += @abs(dx) + @abs(dy);
            self.view_pan_x += dx;
            self.view_pan_y += dy;
        } else if (self.bg_travel > 0) {
            if (self.bg_travel < 3 and self.marked_count > 0) {
                self.clearMarks();
                self.selected = null;
                self.form_loaded = false;
            }
            self.bg_travel = 0;
        }
        if (bg_hovered or active_node != null) {
            const wheel = pl_gui_mouse_wheel();
            if (wheel != 0) self.view_zoom = std.math.clamp(self.view_zoom * (1 + wheel * 0.12), 0.35, 2.5);
        }
        if (clicked_node) |i| {
            const id = self.nodes.items[i].id;
            // Ctrl+click extends the selection; a plain click replaces it.
            if (pl_gui_key_ctrl() == 1) {
                self.toggleMark(id);
            } else {
                self.markOnly(id);
            }
            self.selected = i;
            self.form_loaded = false;
        }

        // A drag is one undo step, so the snapshot is taken when the pointer is released rather than
        // on every frame of the movement.
        if (active_node) |i| {
            self.dragging_node = i;
        } else if (self.dragging_node != null) {
            self.dragging_node = null;
            self.commit();
        }

        self.resolvePortDrag(hovered_port);
        pl_gui_end_child();
    }

    /// Submits a hit box over one port and records it when hovered/dragged.
    fn portButton(self: *App, idx: usize, side: PortSide, kind: PortKind, ox: f32, oy: f32, out: *?PortHit) void {
        const n = self.nodes.items[idx];
        const wx = if (side == .left) n.x else n.x + n.w;
        const p = self.toScreen(ox, oy, wx, n.y + portOffset(kind));
        var ib: [96]u8 = undefined;
        const id = fmtZ(&ib, "##pt{s}{s}{d}", .{ n.id, @tagName(side), @intFromEnum(kind) });
        // A generous square around the dot, half of it sitting outside the card.
        pl_gui_set_cursor_screen_pos(p[0] - 10, p[1] - 10);
        _ = pl_gui_invisible_button(id, 20, 20, 1);
        const hit = PortHit{ .node = idx, .side = side, .kind = kind, .x = p[0], .y = p[1] };
        if (pl_gui_item_hovered() == 1) out.* = hit;
        if (pl_gui_item_active() == 1) self.drag_from = hit;
    }

    /// Finishes a port drag: an output port must meet an input port of the same kind on a different
    /// node. Anything else is reported in the status bar instead of silently doing nothing.
    fn resolvePortDrag(self: *App, hovered_port: ?PortHit) void {
        const from = self.drag_from orelse return;

        // Paint the rubber-band edge while the button is still held.
        if (pl_gui_mouse_down(1) == 1) {
            var mx: f32 = 0;
            var my: f32 = 0;
            pl_gui_mouse_pos(&mx, &my);
            const bend = 90 * self.view_zoom;
            pl_gui_dl_bezier(
                from.x,
                from.y,
                from.x + bend,
                from.y,
                mx - bend,
                my,
                mx,
                my,
                self.pal.text_dim,
                2.0 * self.view_zoom,
            );
            return;
        }

        self.drag_from = null;
        const to = hovered_port orelse {
            self.hint(.edge_rejected);
            return;
        };
        if (to.node == from.node or to.side == from.side or to.kind != from.kind) {
            self.hint(.edge_rejected);
            return;
        }
        // Normalise: the edge always leaves the output (right) port.
        const out_port = if (from.side == .right) from else to;
        const in_port = if (from.side == .right) to else from;
        const kind: EdgeKind = if (from.kind == .pipe) .pipe else .seq;
        if (self.connect(self.nodes.items[out_port.node].id, self.nodes.items[in_port.node].id, kind)) {
            self.hint(.edge_created);
        } else {
            self.hint(.edge_exists);
        }
    }

    fn drawInspector(self: *App, w: f32, h: f32) void {
        pl_gui_begin_child("##inspector", w, h, 1);
        pl_gui_separator_text(self.tr(.properties));
        self.syncForm();
        // The tool source editor takes over the panel: it is the one thing here that edits a
        // document rather than a node.
        if (self.editing_tool) |tool_name| {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const sa = scratch.allocator();
            if (allocZ(sa, "{s}: {s}", .{ self.tr(.edit_tool), tool_name })) |z| pl_gui_text_heading(z.ptr);
            pl_gui_text_dim_wrapped(self.tr(.tool_edit_hint));

            // Re-seeded from the working copy every frame; ImGui writes the edit back into it.
            var buf: [8192]u8 = std.mem.zeroes([8192]u8);
            const n = @min(self.edit_source.len, buf.len - 1);
            @memcpy(buf[0..n], self.edit_source[0..n]);
            if (pl_gui_input_text_multiline("##tool_src", &buf, buf.len, 0, 380) == 1) {
                const next = std.mem.sliceTo(&buf, 0);
                if (self.gpa.dupe(u8, next)) |copy| {
                    if (self.edit_source.len > 0) self.gpa.free(self.edit_source);
                    self.edit_source = copy;
                } else |_| {}
                self.edit_error = "";
            }
            if (self.edit_error.len > 0) pl_gui_text_error(allocZ(sa, "{s}", .{self.edit_error}) orelse "");
            pl_gui_separator();
            if (pl_gui_button(self.tr(.save_tool), 0, 0) == 1) self.saveEditedTool();
            pl_gui_same_line();
            if (pl_gui_button(self.tr(.cancel), 0, 0) == 1) self.closeToolEditor();
            pl_gui_end_child();
            return;
        }
        if (self.form_node) |idx| {
            self.drawNodeForm(idx);
        } else {
            self.drawWorkflowSettings();
        }
        pl_gui_end_child();
    }

    /// Shown when nothing is selected: the workflow-level fields and the graph stats.
    fn drawWorkflowSettings(self: *App) void {
        pl_gui_text_dim(self.tr(.workflow_name));
        pl_gui_set_next_item_width(-1);
        // ImGui edits `flow_name` in place, so the title is resynced from the buffer rather than
        // copied onto itself.
        if (pl_gui_input_text_hint("##flowname", self.tr(.untitled_workflow), &self.flow_name, self.flow_name.len) == 1) {
            self.syncFlowTitle();
        }
        // One history entry per editing session, not one per keystroke.
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
        pl_gui_dummy(0, 8);
        var nb: [64]u8 = undefined;
        pl_gui_text_dim(fmtZ(&nb, "{s}  {d}", .{ self.tr(.nodes), self.nodes.items.len }));
        var eb: [64]u8 = undefined;
        pl_gui_text_dim(fmtZ(&eb, "{s}  {d}", .{ self.tr(.edges), self.edges.items.len }));
        var pipes: usize = 0;
        for (self.edges.items) |e| {
            if (e.kind == .pipe) pipes += 1;
        }
        var pb: [64]u8 = undefined;
        pl_gui_text_dim(fmtZ(&pb, "{s}  {d}", .{ self.tr(.pipes), pipes }));
        var qb: [64]u8 = undefined;
        pl_gui_text_dim(fmtZ(&qb, "{s}  {d}", .{ self.tr(.sequences), self.edges.items.len - pipes }));
        pl_gui_separator_text(self.tr(.select_a_node));
        pl_gui_text_dim_wrapped(self.tr(.select_node_hint));
    }

    /// The CDL-driven parameter form for one node. `sa` is a per-frame scratch arena: every
    /// NUL-terminated string ImGui needs is allocated there and released when the panel closes.
    /// A numeric field that reports the new value only when the user actually edited it (`null`
    /// otherwise), so callers can distinguish "unchanged" from "set to zero".
    fn numberField(self: *App, id: [*:0]const u8, hint_z: [*:0]const u8, value: u64) ?u64 {
        _ = self;
        var buf: [32]u8 = std.mem.zeroes([32]u8);
        _ = std.fmt.bufPrint(buf[0..31], "{d}", .{value}) catch {};
        pl_gui_set_next_item_width(-1);
        if (pl_gui_input_text_hint(id, hint_z, &buf, buf.len) != 1) return null;
        return std.fmt.parseInt(u64, std.mem.trim(u8, std.mem.sliceTo(&buf, 0), " \t"), 10) catch 0;
    }

    /// Node options that apply whatever the node is: whether it runs at all, plus the run controls
    /// the engine already honours (`timeoutMs`, `retry`). They round-tripped through open/save long
    /// before this existed — this is only the missing editor for them.
    fn drawAdvanced(self: *App, idx: usize) void {
        pl_gui_separator_text(self.tr(.advanced));

        // Stored as `disabled` but presented positively, so the checkbox reads "include in run".
        const enabled = pl_gui_checkbox(self.tr(.node_enabled), if (self.nodes.items[idx].disabled) 0 else 1);
        const want_disabled = enabled == 0;
        if (want_disabled != self.nodes.items[idx].disabled) {
            self.nodes.items[idx].disabled = want_disabled;
            self.commit();
        }

        pl_gui_text_dim(self.tr(.node_note));
        var nb: [256]u8 = std.mem.zeroes([256]u8);
        const note = self.nodes.items[idx].note;
        const nn = @min(note.len, nb.len - 1);
        @memcpy(nb[0..nn], note[0..nn]);
        if (pl_gui_input_text_hint("##node_note", "", &nb, nb.len) == 1) {
            const ga = self.graph_arena.allocator();
            if (ga.dupe(u8, std.mem.sliceTo(&nb, 0))) |copy| {
                self.nodes.items[idx].note = copy;
            } else |_| {}
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();

        // Seconds, because that is the unit a human thinks in; the wire field stays milliseconds.
        pl_gui_text_dim(self.tr(.node_timeout));
        const secs: u64 = if (self.nodes.items[idx].timeout_ms) |t| t / 1000 else 0;
        if (self.numberField("##node_timeout", "0", secs)) |v| {
            self.nodes.items[idx].timeout_ms = if (v == 0) null else v * 1000;
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();

        pl_gui_text_dim(self.tr(.node_retry));
        if (self.numberField("##node_retry", "0", self.nodes.items[idx].retry)) |v| {
            self.nodes.items[idx].retry = @intCast(@min(v, 100));
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
    }

    /// The tool sheet panel: the bound tool's command surface, pickable. Picking
    /// only appends to the same argv the command line shows — this is the mechanism that removes
    /// the memorize / look-up / read-help tax, and nothing here ever runs the tool.
    fn drawToolSheet(self: *App, sa: std.mem.Allocator, idx: usize) void {
        pl_gui_separator_text(self.tr(.tool_sheet));
        if (self.sheet_root.len == 0 and self.sheet_presets.len == 0) {
            pl_gui_text_dim_wrapped(self.tr(.sheet_empty));
            return;
        }

        // Where in the tool's surface we are: a picked subcommand drills down, this comes back.
        if (self.sheet_depth > 0) {
            if (pl_gui_button(self.tr(.sheet_back), 0, 0) == 1) {
                self.sheet_depth -= 1;
                self.sheet_slot = null;
            }
            pl_gui_same_line();
            var pb: [192]u8 = undefined;
            pl_gui_text_dim(fmtZ(&pb, "{s} / {s}", .{ self.sheet_tool, self.sheetContextLabel() }));
        }

        pl_gui_set_next_item_width(-1);
        _ = pl_gui_input_text_hint("##sheet_filter", self.tr(.sheet_filter), &self.sheet_filter, self.sheet_filter.len);

        pl_gui_begin_child("##sheet_rows", 0, 210, 1);
        const ctx = self.sheetContext();
        var vis: usize = 0;
        for (ctx, 0..) |*entry, i| {
            if (!self.sheetMatches(entry)) continue;
            self.drawSheetRow(sa, idx, entry, i, vis);
            vis += 1;
        }
        if (vis == 0) pl_gui_text_dim(self.tr(.sheet_no_match));
        pl_gui_end_child();

        self.drawSlotFill(sa, idx);

        if (self.sheet_presets.len > 0) {
            // A short separator with the explanation wrapped underneath: a long separator label is
            // drawn unwrapped (ImGui's SeparatorText) and would be cut off at the panel edge.
            pl_gui_separator_text(self.tr(.presets));
            pl_gui_text_dim_wrapped(self.tr(.presets_hint));
            // A preset is a pre-assembled command template: "insert" expands it into this command
            // (defaults in, unfilled `{name}` slots left visible), "form" opens the classic
            // variable form. Both are conveniences on top of the free command — never its boundary.
            for (self.sheet_presets, 0..) |*p, i| {
                var bb: [256]u8 = undefined;
                const ins_btn = fmtZ(&bb, "{s}##ins_{d}", .{ p.label, i });
                // A preset label wider than the panel takes the whole row (its own text is clipped
                // inside the button, which reads as elided rather than vanishing under the bar).
                const ins_w: f32 = if (pl_gui_button_row_reserve(ins_btn) <= rowAvailWidth()) 0 else rowAvailWidth();
                if (pl_gui_button(ins_btn, ins_w, 0) == 1) {
                    self.insertSheetPreset(idx, p);
                }
                var fb: [192]u8 = undefined;
                const form_btn = fmtZ(&fb, "{s}##frm_{d}", .{ self.tr(.preset_form), i });
                if (buttonFitsOnRow(form_btn)) pl_gui_same_line();
                if (pl_gui_button(form_btn, 0, 0) == 1) {
                    self.applyPresetForm(idx, p);
                }
            }
        }
    }

    fn drawSheetRow(
        self: *App,
        sa: std.mem.Allocator,
        idx: usize,
        entry: *const SheetEntry,
        pos: usize,
        vis: usize,
    ) void {
        const kind: StrKey = if (std.mem.eql(u8, entry.kind, "subcommand"))
            .kind_subcommand
        else if (std.mem.eql(u8, entry.kind, "option"))
            .kind_option
        else
            .kind_note;

        var buf: [400]u8 = undefined;
        if (std.mem.eql(u8, entry.kind, "note")) {
            // A note is knowledge, not a token: readable, never inserted.
            pl_gui_text_dim(fmtZ(&buf, "[{s}] {s}", .{ self.tr(kind), entry.label }));
        } else {
            const joined = std.mem.join(sa, " ", entry.tokens) catch return;
            if (pl_gui_button(
                fmtZ(&buf, "[{s}] {s}   [{s}]##sheet_{d}", .{ self.tr(kind), entry.label, joined, vis }),
                0,
                0,
            ) == 1) {
                self.pickSheetEntry(idx, entry, pos);
            }
        }
        if (entry.desc.len > 0) {
            const dz = dupeZ(self.gpa, entry.desc) catch return;
            defer self.gpa.free(dz);
            pl_gui_text_dim_wrapped(dz.ptr);
        }
    }

    /// The fill control of a pending value slot. The slot is filled explicitly and dismissable;
    /// nothing is applied behind the user's back.
    fn drawSlotFill(self: *App, sa: std.mem.Allocator, idx: usize) void {
        _ = sa;
        const slot = self.sheet_slot orelse return;
        if (slot.serial != self.argv_serial) {
            // The command changed under the slot (it is not the argv it was cut for): dismiss it
            // instead of silently rewriting the wrong element (rule 2).
            self.sheet_slot = null;
            return;
        }
        // The separator stays short and the (arbitrarily long) entry label wraps below it: a
        // separator label is drawn unwrapped and would be clipped at the panel edge.
        pl_gui_separator_text(self.tr(.slot_fill));
        if (slot.label.len > 0) {
            const lz = dupeZ(self.gpa, slot.label) catch return;
            defer self.gpa.free(lz);
            pl_gui_text_dim_wrapped(lz.ptr);
        }

        const dismiss_label = self.tr(.slot_dismiss);
        if (std.mem.eql(u8, slot.takes, "enum")) {
            // Options flow left to right and wrap at the panel edge.
            for (slot.options, 0..) |opt, i| {
                var ob: [192]u8 = undefined;
                const opt_btn = fmtZ(&ob, "{s}##slot_{d}", .{ opt, i });
                if (i > 0 and buttonFitsOnRow(opt_btn)) pl_gui_same_line();
                if (pl_gui_button(opt_btn, 0, 0) == 1) {
                    self.applySlotValue(idx, opt);
                    return;
                }
            }
        } else if (std.mem.eql(u8, slot.takes, "file") or std.mem.eql(u8, slot.takes, "directory")) {
            const want_dir = std.mem.eql(u8, slot.takes, "directory");
            const key: StrKey = if (want_dir) .slot_pick_dir else .slot_pick_file;
            if (pl_gui_button(self.tr(key), 0, 0) == 1) {
                self.fillSlotFromPicker(idx);
                return;
            }
        } else {
            // The input shares its row with "apply", which in turn leaves room for "dismiss".
            const dismiss_reserve = pl_gui_button_row_reserve(dismiss_label);
            const reserve = inlineReserve(self.tr(.slot_apply), 120 + dismiss_reserve);
            pl_gui_set_next_item_width(if (reserve) |r| -r else -1);
            _ = pl_gui_input_text_hint("##slot_text", self.tr(.slot_text_hint), &self.sheet_slot_text, self.sheet_slot_text.len);
            if (reserve != null) pl_gui_same_line();
            if (pl_gui_button(self.tr(.slot_apply), 0, 0) == 1) {
                self.applySlotValue(idx, std.mem.sliceTo(&self.sheet_slot_text, 0));
                return;
            }
        }
        // The dismiss button shares the row when its measured width still fits there; otherwise it
        // starts a new line, because a button past the content region is cut off by the scrollbar.
        if (buttonFitsOnRow(dismiss_label)) pl_gui_same_line();
        if (pl_gui_button(dismiss_label, 0, 0) == 1) self.sheet_slot = null;
    }

    /// Filter match over an entry's own text: its label, its description and its tokens.
    fn sheetMatches(self: *const App, entry: *const SheetEntry) bool {
        const q = std.mem.sliceTo(&self.sheet_filter, 0);
        if (q.len == 0) return true;
        if (containsIgnoreCase(entry.label, q)) return true;
        if (containsIgnoreCase(entry.desc, q)) return true;
        for (entry.tokens) |t| {
            if (containsIgnoreCase(t, q)) return true;
        }
        return false;
    }

    /// Inspector for a raw-command node: one command line over a byte-exact argv. This is the
    /// surface that makes the GUI a general CLI runner rather than a viewer for the 11 built-in
    /// tools, and the answer to "restricted to actions rather than free commands": a node is a
    /// command, typed like a terminal line.
    fn drawRawCommandForm(self: *App, sa: std.mem.Allocator, idx: usize) void {
        pl_gui_text_dim_wrapped(self.tr(.command_hint));

        pl_gui_separator_text(self.tr(.command_line));
        if (self.cmd_line_for != idx or self.cmd_line_serial != self.argv_serial) self.seedCommandLine(idx);
        // Room for the pick button on the same line — measured from its (localized) label, not a
        // constant; when that would leave the input too narrow the button drops to its own line
        // instead of sliding under the panel's scrollbar.
        var rbb: [160]u8 = undefined;
        const pick_btn = fmtZ(&rbb, "{s}##b_raw", .{self.tr(.pick_executable)});
        const pick_reserve = inlineReserve(pick_btn, 140);
        pl_gui_set_next_item_width(if (pick_reserve) |r| -r else -1);
        if (pl_gui_input_text_hint("##cmd_line", "git commit -m \"…\"", &self.cmd_line, self.cmd_line.len) == 1) {
            self.applyCommandLine(idx);
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
        if (pick_reserve != null) pl_gui_same_line();
        if (pl_gui_button(pick_btn, 0, 0) == 1) {
            if (self.askPath(sa, "file", false)) |picked| {
                self.setNodeExecutable(idx, picked);
                self.commit();
            } else {
                self.form_status = StrKey.picker_unavailable.get(self.lang);
            }
        }
        // The convention is named in the hint (rule 3) and every failure is reported rather than
        // reinterpreted. Wrapped: the hint is wider than a narrow inspector, and text that does not
        // wrap is clipped at the panel edge rather than shown.
        pl_gui_text_dim_wrapped(self.tr(.command_line_hint));
        switch (self.cmd_line_error) {
            .none => {},
            .unterminated_quote => pl_gui_text_error(self.tr(.err_unterminated_quote)),
            .trailing_backslash => pl_gui_text_error(self.tr(.err_trailing_backslash)),
        }

        // The bound tool's sheet: pick vocabulary to build this same command, then keep editing it
        // anywhere — the sheet, the line, or the argv rows are all one command.
        if (self.nodes.items[idx].cdl.len > 0) self.drawToolSheet(sa, idx);

        pl_gui_separator_text(self.tr(.arguments));
        // The byte-exact escape hatch: one argument per line, no quoting rules at all. An argument
        // that no one-line form can express (e.g. one containing a newline) is typed here.
        var arg_buf: [2048]u8 = std.mem.zeroes([2048]u8);
        var used: usize = 0;
        if (self.nodes.items[idx].argv.len > 1) {
            for (self.nodes.items[idx].argv[1..]) |arg| {
                if (used + arg.len + 2 >= arg_buf.len) break;
                @memcpy(arg_buf[used..][0..arg.len], arg);
                used += arg.len;
                arg_buf[used] = '\n';
                used += 1;
            }
        }
        pl_gui_set_next_item_width(-1);
        if (pl_gui_input_text_multiline("##raw_args", &arg_buf, arg_buf.len, 0, 120) == 1) {
            self.setNodeArgv(idx, std.mem.sliceTo(&arg_buf, 0));
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
        pl_gui_text_dim_wrapped(self.tr(.arguments_hint));

        // A live preview of exactly what will be spawned, so the argv boundary is never a guess.
        pl_gui_separator();
        var pb: [1024]u8 = undefined;
        var pw: usize = 0;
        for (self.nodes.items[idx].argv, 0..) |arg, i| {
            if (pw + arg.len + 4 >= pb.len) break;
            if (i > 0) {
                pb[pw] = ' ';
                pw += 1;
            }
            pb[pw] = '"';
            pw += 1;
            @memcpy(pb[pw..][0..arg.len], arg);
            pw += arg.len;
            pb[pw] = '"';
            pw += 1;
        }
        pb[pw] = 0;
        if (allocZ(sa, "{s}", .{pb[0..pw]})) |z| pl_gui_text_dim_wrapped(z.ptr);

        if (self.form_status.len > 0) pl_gui_text_error(self.form_status.ptr);
        self.drawAdvanced(idx);
        pl_gui_separator_text(self.tr(.node_actions));
        if (pl_gui_button(self.tr(.duplicate_node), 0, 0) == 1) self.duplicateNode(idx);
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.delete_node), 0, 0) == 1) self.deleteNode(idx);
    }

    fn drawNodeForm(self: *App, idx: usize) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        if (allocZ(sa, "{s}", .{self.nodes.items[idx].title})) |z| pl_gui_text_heading(z.ptr);
        if (isRaw(&self.nodes.items[idx])) {
            pl_gui_text_dim(self.tr(.raw_command));
            self.drawRawCommandForm(sa, idx);
            return;
        }
        if (allocZ(sa, "{s} · {s}", .{ self.nodes.items[idx].cdl, self.nodes.items[idx].action })) |z| {
            pl_gui_text_dim(z.ptr);
        }
        if (self.form_desc.len > 0) {
            if (allocZ(sa, "{s}", .{self.form_desc})) |z| pl_gui_text_wrapped(z.ptr);
        }
        if (self.form_danger) pl_gui_text_error(self.tr(.danger_action));

        // Action selector: a CDL usually offers several actions for the same tool.
        if (self.form_action_count > 1) {
            pl_gui_text_dim(self.tr(.action));
            var items: [32][*:0]const u8 = undefined;
            var count: usize = 0;
            var cur: c_int = -1;
            for (self.form_actions[0..self.form_action_count], 0..) |act, i| {
                const z = allocZ(sa, "{s}", .{act.label}) orelse break;
                items[count] = z.ptr;
                if (std.mem.eql(u8, act.name, self.nodes.items[idx].action)) cur = @intCast(count);
                count += 1;
                _ = i;
            }
            pl_gui_set_next_item_width(-1);
            const sel = pl_gui_combo("##action", cur, &items, @intCast(count));
            if (sel >= 0 and sel != cur) {
                const act = self.form_actions[@intCast(sel)];
                // Action names are few and short; graph_arena keeps them valid for the session.
                if (self.graph_arena.allocator().dupe(u8, act.name)) |copy| {
                    self.nodes.items[idx].action = copy;
                } else |_| {}
                self.form_loaded = false; // rebuild the form against the new action
            }
        }

        // Executable override: "use this specific build, not the one on PATH". Empty means the
        // action's own executable, which is shown so the consequence of clearing it is visible.
        pl_gui_separator_text(self.tr(.executable));
        var ob: [512]u8 = std.mem.zeroes([512]u8);
        const cur_exe = self.nodes.items[idx].executable;
        const on = @min(cur_exe.len, ob.len - 1);
        @memcpy(ob[0..on], cur_exe[0..on]);
        // Unique id: this button shares its label with the per-field Browse buttons, and ImGui
        // derives the id from the label, so identical labels in one window collide.
        var obb: [160]u8 = undefined;
        const browse_btn = fmtZ(&obb, "{s}##b_exe", .{self.tr(.browse)});
        const browse_reserve = inlineReserve(browse_btn, 120);
        pl_gui_set_next_item_width(if (browse_reserve) |r| -r else -1);
        const hint_z = allocZ(sa, "{s}", .{self.tr(.use_default)}) orelse return;
        if (pl_gui_input_text_hint("##exe_override", hint_z.ptr, &ob, ob.len) == 1) {
            self.setNodeExeOverride(idx, std.mem.sliceTo(&ob, 0));
        }
        if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
        if (browse_reserve != null) pl_gui_same_line();
        if (pl_gui_button(browse_btn, 0, 0) == 1) {
            if (self.askPath(sa, "file", false)) |picked| {
                self.setNodeExeOverride(idx, picked);
                self.commit();
            } else {
                self.form_status = StrKey.picker_unavailable.get(self.lang);
            }
        }
        if (cur_exe.len > 0) {
            if (pl_gui_button(self.tr(.use_default), 0, 0) == 1) {
                self.setNodeExeOverride(idx, "");
                self.commit();
            }
        } else if (self.form_exe_default.len > 0) {
            var db: [256]u8 = undefined;
            pl_gui_text_dim(fmtZ(&db, "{s}: {s}", .{ self.tr(.executable_default), self.form_exe_default }));
        }

        pl_gui_separator_text(self.tr(.parameters));
        if (self.form_var_count == 0) pl_gui_text_dim(self.tr(.no_variables));
        var errors: usize = 0;
        for (self.form_vars[0..self.form_var_count]) |spec| {
            self.drawField(sa, idx, spec, &errors);
        }

        pl_gui_separator();
        if (errors == 0) {
            pl_gui_text_dim(self.tr(.params_ready));
        } else {
            var eb: [96]u8 = undefined;
            pl_gui_text_error(fmtZ(&eb, "{d} {s}", .{ errors, self.tr(.items_need_fixing) }));
        }
        if (self.form_status.len > 0) pl_gui_text_error(self.form_status.ptr);
        self.drawAdvanced(idx);
        pl_gui_separator_text(self.tr(.node_actions));
        // A preset is a convenience, not a boundary: any action node can be opened up into the
        // free command it would run and edited from there.
        if (pl_gui_button(self.tr(.expand_to_command), 0, 0) == 1) {
            self.expandToCommand(idx);
        }
        if (pl_gui_button(self.tr(.duplicate_node), 0, 0) == 1) self.duplicateNode(idx);
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.delete_node), 0, 0) == 1) self.deleteNode(idx);
    }

    fn drawField(self: *App, sa: std.mem.Allocator, idx: usize, spec: VarSpec, errors: *usize) void {
        const id = allocZ(sa, "##v_{s}", .{spec.name}) orelse return;
        // The format string must be comptime-known, so the required-marker branch is explicit.
        // Labels are wrapped: CDL labels are often too long for the panel width.
        if (spec.required) {
            if (allocZ(sa, "{s}  *", .{spec.label})) |z| pl_gui_text_dim_wrapped(z.ptr);
        } else {
            if (allocZ(sa, "{s}", .{spec.label})) |z| pl_gui_text_dim_wrapped(z.ptr);
        }
        if (spec.description.len > 0) {
            if (allocZ(sa, "{s}", .{spec.description})) |z| pl_gui_text_wrapped(z.ptr);
        }
        const cur = self.nodeValue(idx, spec.name);
        const is_bool = std.mem.eql(u8, spec.vtype, "boolean");
        const is_enum = std.mem.eql(u8, spec.vtype, "enum");
        const is_file = std.mem.eql(u8, spec.vtype, "file") or std.mem.eql(u8, spec.vtype, "directory");
        // File fields leave room for the "browse" button on the same line. The reserve is measured
        // from that button's own (localized) label, and when the two cannot share the row the input
        // takes the full width and the button moves to the next line.
        var fbb: [192]u8 = undefined;
        const browse_btn = fmtZ(&fbb, "{s}##b_{s}", .{ self.tr(.browse), spec.name });
        const browse_reserve = if (is_file) inlineReserve(browse_btn, 120) else null;
        pl_gui_set_next_item_width(if (browse_reserve) |r| -r else -1);

        if (is_bool) {
            const nv = pl_gui_checkbox(id.ptr, if (truthy(cur)) 1 else 0);
            const new_val = if (nv == 1) "true" else "false";
            if (!std.mem.eql(u8, new_val, cur)) {
                self.setValue(idx, spec.name, new_val);
                self.commit();
            }
        } else if (is_enum and spec.options.len > 0) {
            var items: [32][*:0]const u8 = undefined;
            var count: usize = 0;
            var current: c_int = -1;
            for (spec.options) |o| {
                if (count >= items.len) break;
                const z = allocZ(sa, "{s}", .{o.label}) orelse continue;
                items[count] = z.ptr;
                if (std.mem.eql(u8, o.value, cur)) current = @intCast(count);
                count += 1;
            }
            const sel = pl_gui_combo(id.ptr, current, &items, @intCast(count));
            // A combo selection is a discrete event, so it closes its own undo step.
            if (sel >= 0 and sel < @as(c_int, @intCast(count)) and sel != current) {
                self.setValue(idx, spec.name, spec.options[@intCast(sel)].value);
                self.commit();
            }
        } else {
            var buf: [512]u8 = std.mem.zeroes([512]u8);
            const n = @min(cur.len, buf.len - 1);
            @memcpy(buf[0..n], cur[0..n]);
            const hint_z: [*:0]const u8 = if (spec.placeholder.len > 0) blk: {
                const z = allocZ(sa, "{s}", .{spec.placeholder}) orelse break :blk "";
                break :blk z.ptr;
            } else "";
            var changed: c_int = 0;
            if (spec.multiline) {
                changed = pl_gui_input_text_multiline(id.ptr, &buf, buf.len, 0, 90);
            } else {
                changed = pl_gui_input_text_hint(id.ptr, hint_z, &buf, buf.len);
            }
            if (changed == 1) self.setValue(idx, spec.name, std.mem.sliceTo(&buf, 0));
            // One undo step per editing session rather than per keystroke. Checked immediately after
            // the input: the browse button below would otherwise become "the last item".
            if (pl_gui_item_deactivated_after_edit() == 1) self.commit();
            if (is_file) {
                if (browse_reserve != null) pl_gui_same_line();
                // The `##` suffix keeps this id distinct from the executable-override Browse button,
                // which carries the same visible label.
                if (pl_gui_button(browse_btn, 0, 0) == 1) {
                    self.pickPath(idx, spec);
                }
            }
        }

        // Help line: the constraints this field carries, then the validation verdict.
        if (spec.min != null and spec.max != null) {
            var hb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&hb, "{s} {d} ~ {d}", .{ self.tr(.range), spec.min.?, spec.max.? }));
        } else if (spec.min) |mn| {
            var hb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&hb, "{s} {d}", .{ self.tr(.at_least), mn }));
        } else if (spec.max) |mx| {
            var hb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&hb, "{s} {d}", .{ self.tr(.at_most), mx }));
        }
        if (spec.step) |st| {
            var hb: [128]u8 = undefined;
            pl_gui_text_dim(fmtZ(&hb, "{s} {d}", .{ self.tr(.step), st }));
        }
        if (spec.filters.len > 0) {
            if (allocZ(sa, "{s}{s}", .{ self.tr(.accepts), spec.filters[0] })) |z| pl_gui_text_dim(z.ptr);
        }
        if (self.validate(spec, self.nodeValue(idx, spec.name))) |msg| {
            errors.* += 1;
            pl_gui_text_error(msg.ptr);
        }
        pl_gui_dummy(0, 6);
    }

    fn drawOutput(self: *App, w: f32) void {
        pl_gui_begin_child("##output", w, 190, 1);

        // Tab row: "all nodes" plus one tab per node, marked with its run status.
        if (pl_gui_selectable(self.tr(.all), if (self.output_tab < 0) 1 else 0) == 1) self.output_tab = -1;
        for (self.nodes.items, 0..) |n, i| {
            pl_gui_same_line();
            var tb: [128]u8 = undefined;
            const sel: c_int = if (self.output_tab == @as(i32, @intCast(i))) 1 else 0;
            if (pl_gui_selectable(fmtZ(&tb, "{s} · {s}", .{ n.id, n.status.label(self.lang) }), sel) == 1) {
                self.output_tab = @intCast(i);
            }
        }
        pl_gui_same_line();
        const was_auto = self.autoscroll;
        self.autoscroll = pl_gui_checkbox(self.tr(.autoscroll), if (self.autoscroll) 1 else 0) == 1;
        if (!was_auto and self.autoscroll) self.scroll_pending = true;
        pl_gui_same_line();
        if (pl_gui_button(self.tr(.clear), 0, 0) == 1) self.clearLog();
        pl_gui_separator();

        pl_gui_begin_child("##outputbody", 0, 0, 0);
        if (self.log_count == 0) {
            pl_gui_text_dim(self.tr(.output_placeholder));
        }

        const filtered: ?usize = if (self.output_tab >= 0 and @as(usize, @intCast(self.output_tab)) < self.nodes.items.len)
            @intCast(self.output_tab)
        else
            null;

        for (0..self.log_count) |i| {
            const line = self.logLine(i);
            if (filtered) |idx| {
                if (!std.mem.eql(u8, line.node, self.nodes.items[idx].id)) continue;
            }
            // Prefix with the node id on the aggregate tab; per-node tabs are already scoped.
            var buf: [1024]u8 = undefined;
            const shown = if (filtered == null and line.node.len > 0)
                fmtZ(&buf, "[{s}] {s}", .{ line.node, line.text })
            else
                fmtZ(&buf, "{s}", .{line.text});
            pl_gui_text_colored(shown, line.stream.tint(self.pal));
        }

        // Autoscroll only when new lines arrived, so the user can scroll back without being yanked.
        if (self.autoscroll and self.log_count != self.last_log_count) self.scroll_pending = true;
        if (self.scroll_pending and self.log_count > 0) {
            pl_gui_scroll_to_bottom();
            self.scroll_pending = false;
        }
        pl_gui_end_child();

        if (self.run_error.len > 0) {
            var eb: [512]u8 = undefined;
            pl_gui_text_error(fmtZ(&eb, "{s}", .{self.run_error}));
        }
        pl_gui_end_child();
        self.last_log_count = self.log_count;
    }

    fn drawStatusbar(self: *App) void {
        if (self.engine_ok) {
            pl_gui_text_dim(self.tr(.engine_connected));
        } else {
            pl_gui_text_dim(self.tr(.engine_disconnected));
        }
        pl_gui_same_line();
        pl_gui_dummy(24, 0);
        pl_gui_same_line();
        var buf: [192]u8 = undefined;
        // Label-then-count, matching the inspector stats: "Nodes 1" reads correctly in English and
        // "节点 1" matches the rest of the Chinese UI (a "{d} {s}" order produces "1 Nodes").
        const line = fmtZ(&buf, "Flow Pipelith {s} · CDL {d} {s} · {s} {d} · {s} {d}", .{
            if (self.version.len > 0) self.version else "0.1.0",
            self.item_count,
            self.tr(.items),
            self.tr(.nodes),
            self.nodes.items.len,
            self.tr(.edges),
            self.edges.items.len,
        });
        pl_gui_text_dim(line);
        pl_gui_same_line();
        pl_gui_dummy(24, 0);
        pl_gui_same_line();
        // Transient feedback (undo/redo, connection accepted/rejected). Drawn in the accent colour so
        // it reads as a message rather than as another status field.
        if (self.hint_frames > 0) {
            self.hint_frames -= 1;
            pl_gui_text_colored(self.hint_text.ptr, self.pal.accent);
            pl_gui_same_line();
            pl_gui_dummy(24, 0);
            pl_gui_same_line();
        }
        var zb: [64]u8 = undefined;
        pl_gui_text_dim(fmtZ(&zb, "{d:.0}%", .{self.view_zoom * 100}));
    }

    fn draw(self: *App) void {
        // Shortcuts run before the widgets so a key press is not also consumed by a field.
        self.handleShortcuts();
        pl_gui_root_begin("##root");        self.drawTopbar();
        pl_gui_separator();

        var avail_w: f32 = 0;
        var avail_h: f32 = 0;
        pl_gui_content_avail(&avail_w, &avail_h);

        const output_h: f32 = 190;
        const status_h: f32 = 26;
        const gap: f32 = 8;
        const lib_w: f32 = 300;
        // The source editor needs room for JSON lines; the normal inspector does not. Widening it
        // only while editing keeps the canvas wide the rest of the time.
        const insp_w: f32 = if (self.editing_tool != null) 620 else 330;
        var body_h = avail_h - output_h - status_h - gap * 2;
        if (body_h < 120) body_h = 120;
        var canvas_w = avail_w - lib_w - insp_w - gap * 2;
        if (canvas_w < 160) canvas_w = 160;

        self.drawLibrary(body_h);
        pl_gui_same_line();
        self.drawCanvas(canvas_w, body_h);
        pl_gui_same_line();
        self.drawInspector(insp_w, body_h);
        self.drawOutput(avail_w);
        self.drawStatusbar();
        // Drawn last so the drag ghost floats above every panel.
        self.drawToolDrag();
        pl_gui_root_end();
    }
};

const Args = struct {
    width: c_int = 1280,
    height: c_int = 800,
    frames: u32 = 0,
    shot: ?[]const u8 = null,
    font: ?[]const u8 = null,
    /// Seeds a small graph so the canvas can be screenshotted without an interactive click.
    demo: bool = false,
    /// Index of the node to pre-select (used to capture a specific inspector form).
    select: ?usize = null,
    /// Adds a single node for this CDL and selects it. The library order comes from the engine's
    /// document map, so this is what makes a screenshot of a *specific* form reproducible.
    add_cdl: ?[]const u8 = null,
    /// Starts a run immediately after the window comes up (non-interactive verification).
    run: bool = false,
    /// Runs the dry-run preview instead (non-interactive verification).
    preview: bool = false,
    /// Sets the selected node's action (verification: the default is the CDL's first action).
    action: ?[]const u8 = null,
    /// Start in the light theme / English UI (verification of the theme + i18n toggles).
    light: bool = false,
    lang_en: bool = false,
    /// Undo this many steps before the first frame (verification of the history stack).
    undo: u32 = 0,
    /// Redo this many steps after the undos (verification of the redo branch).
    redo: u32 = 0,
    /// Write the output panel's lines here on exit (verification of run/preview text).
    dump_log: ?[]const u8 = null,
    /// Verification dumps: the library list, the canvas graph with port plans, the inspector form.
    dump_library: ?[]const u8 = null,
    /// Tool-pack inventory (`--dump-packs`): the installed tool count plus every available pack.
    dump_packs: ?[]const u8 = null,
    dump_graph: ?[]const u8 = null,
    dump_form: ?[]const u8 = null,
    /// Pre-fills the library search box before the first frame.
    search: ?[]const u8 = null,
    /// Open this `.flow` file at startup.
    open_flow: ?[]const u8 = null,
    /// Write the current workflow to this path at startup (round-trip verification).
    save_flow: ?[]const u8 = null,
    /// Duplicate the selected node at startup (verification of the clone path).
    duplicate: bool = false,
    /// Fit the view once the canvas has been laid out (verification of the toolbar action).
    fit: bool = false,
    /// Apply the auto-layout at startup (verification of the layering, via --dump-graph).
    layout: bool = false,
    /// Re-read the tool library at startup (verification of the reload path).
    reload_library: bool = false,
    /// Names the workflow at startup, before any --undo/--redo, so renaming is verifiable as an
    /// undoable step like every other mutation.
    name: ?[]const u8 = null,
    /// Creates a raw-command node for this executable at startup (verification of the custom-command
    /// path, which is otherwise driven by the file picker).
    add_command: ?[]const u8 = null,
    /// Arguments for the node created by --add-command. Repeatable, in order.
    command_args: [16][]const u8 = undefined,
    command_arg_count: usize = 0,
    /// Feeds one typed command line through the inspector's one-line editor at startup, so "the
    /// user typed a line like a terminal and it became argv" is machine-checkable.
    command_line: ?[]const u8 = null,
    /// Expands the selected preset node into a free command at startup (verification of the
    /// "an action is a convenience, not a boundary" path, which is otherwise a button).
    expand_command: bool = false,
    /// Adds a free command node bound to the named tool (the library click path), so the tool
    /// sheet's pick-and-assemble surface is machine-checkable.
    add_free: ?[]const u8 = null,
    /// Tool packs to install before the first frame (the library panel's "Load" button, driven from
    /// the command line so a scripted run can state which tools it needs). Repeatable.
    load_packs: [8][]const u8 = undefined,
    load_pack_count: usize = 0,
    /// Directories tool packs are read from (`--packs-dir`, repeatable). Without one, only the user's
    /// own `<state dir>/packs` (and a shared `<tool dir>/packs`) are searched — a fresh installation
    /// offers no pack at all, which is the point of packs being separate load items.
    packs_dirs: [4][]const u8 = undefined,
    packs_dir_count: usize = 0,
    /// Tool-sheet gestures, executed exactly in command-line order — one flag per click, so a
    /// multi-step script replays what a user's clicks would do (pick, back, pick, fill, ...).
    sheet_ops: [16]SheetOp = undefined,
    sheet_op_count: usize = 0,
    /// Selects every node at startup, then copies and/or pastes (verification of the clipboard,
    /// which otherwise needs a mouse and a keyboard).
    select_all: bool = false,
    copy: bool = false,
    paste: bool = false,
    /// Deletes everything marked at startup (verification of the multi-delete path).
    delete_marked: bool = false,
    /// Opens this user tool in the source editor at startup (verification of the editor).
    edit_tool: ?[]const u8 = null,
    /// Saves whatever the editor holds (verification of the editor's save path).
    save_tool: bool = false,
    /// Walks a synthetic pointer over a grid of the window, one position per frame. ImGui reports a
    /// conflicting-widget-id error only for the hovered item, so without this the class of bug where
    /// two widgets share a label is invisible to a headless run.
    hover_grid: bool = false,
    /// Deletes this user tool at startup (verification of `cdl.delete`).
    delete_tool_named: ?[]const u8 = null,
    /// Redirect the writable state directory (autosave, preferences). A development/test flag: it
    /// lets the harness exercise persistence without touching the real `<tool dir>/.pipelith`.
    state_dir: ?[]const u8 = null,
};

fn parseArgs(a: std.mem.Allocator, argv: []const [:0]const u8) !Args {
    var out = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (std.mem.eql(u8, arg, "--demo")) {
            out.demo = true;
        } else if (std.mem.eql(u8, arg, "--run")) {
            out.run = true;
        } else if (std.mem.eql(u8, arg, "--preview")) {
            out.preview = true;
        } else if (std.mem.eql(u8, arg, "--light")) {
            out.light = true;
        } else if (std.mem.eql(u8, arg, "--en")) {
            out.lang_en = true;
        } else if (std.mem.eql(u8, arg, "--undo")) {
            i += 1;
            if (i < argv.len) out.undo = std.fmt.parseInt(u32, argv[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--redo")) {
            i += 1;
            if (i < argv.len) out.redo = std.fmt.parseInt(u32, argv[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--dump-log")) {
            i += 1;
            if (i < argv.len) out.dump_log = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--dump-library")) {
            i += 1;
            if (i < argv.len) out.dump_library = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--dump-packs")) {
            i += 1;
            if (i < argv.len) out.dump_packs = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--dump-graph")) {
            i += 1;
            if (i < argv.len) out.dump_graph = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--dump-form")) {
            i += 1;
            if (i < argv.len) out.dump_form = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--search")) {
            i += 1;
            if (i < argv.len) out.search = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--open-flow")) {
            i += 1;
            if (i < argv.len) out.open_flow = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--save-flow")) {
            i += 1;
            if (i < argv.len) out.save_flow = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--duplicate")) {
            out.duplicate = true;
        } else if (std.mem.eql(u8, arg, "--fit")) {
            out.fit = true;
        } else if (std.mem.eql(u8, arg, "--layout")) {
            out.layout = true;
        } else if (std.mem.eql(u8, arg, "--reload-library")) {
            out.reload_library = true;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            i += 1;
            if (i < argv.len) out.state_dir = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i < argv.len) out.name = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--add-command")) {
            i += 1;
            if (i < argv.len) out.add_command = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--select-all")) {
            out.select_all = true;
        } else if (std.mem.eql(u8, arg, "--copy")) {
            out.copy = true;
        } else if (std.mem.eql(u8, arg, "--paste")) {
            out.paste = true;
        } else if (std.mem.eql(u8, arg, "--delete-marked")) {
            out.delete_marked = true;
        } else if (std.mem.eql(u8, arg, "--edit-tool")) {
            i += 1;
            if (i < argv.len) out.edit_tool = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--save-tool")) {
            out.save_tool = true;
        } else if (std.mem.eql(u8, arg, "--hover-grid")) {
            out.hover_grid = true;
        } else if (std.mem.eql(u8, arg, "--delete-tool")) {
            i += 1;
            if (i < argv.len) out.delete_tool_named = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--arg")) {
            i += 1;
            if (i < argv.len and out.command_arg_count < out.command_args.len) {
                out.command_args[out.command_arg_count] = try a.dupe(u8, argv[i]);
                out.command_arg_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--command-line")) {
            i += 1;
            if (i < argv.len) out.command_line = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--expand-command")) {
            out.expand_command = true;
        } else if (std.mem.eql(u8, arg, "--add-free")) {
            i += 1;
            if (i < argv.len) out.add_free = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--load-pack")) {
            i += 1;
            if (i < argv.len and out.load_pack_count < out.load_packs.len) {
                out.load_packs[out.load_pack_count] = try a.dupe(u8, argv[i]);
                out.load_pack_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--packs-dir")) {
            i += 1;
            if (i < argv.len and out.packs_dir_count < out.packs_dirs.len) {
                out.packs_dirs[out.packs_dir_count] = try a.dupe(u8, argv[i]);
                out.packs_dir_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--pick-token")) {
            i += 1;
            if (i < argv.len and out.sheet_op_count < out.sheet_ops.len) {
                out.sheet_ops[out.sheet_op_count] = .{ .pick = std.fmt.parseInt(usize, argv[i], 10) catch 0 };
                out.sheet_op_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--sheet-filter")) {
            i += 1;
            if (i < argv.len and out.sheet_op_count < out.sheet_ops.len) {
                out.sheet_ops[out.sheet_op_count] = .{ .filter = try a.dupe(u8, argv[i]) };
                out.sheet_op_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--sheet-back")) {
            if (out.sheet_op_count < out.sheet_ops.len) {
                out.sheet_ops[out.sheet_op_count] = .back;
                out.sheet_op_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--fill-slot")) {
            i += 1;
            if (i < argv.len and out.sheet_op_count < out.sheet_ops.len) {
                out.sheet_ops[out.sheet_op_count] = .{ .fill = try a.dupe(u8, argv[i]) };
                out.sheet_op_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--insert-preset")) {
            i += 1;
            if (i < argv.len and out.sheet_op_count < out.sheet_ops.len) {
                out.sheet_ops[out.sheet_op_count] = .{ .insert = try a.dupe(u8, argv[i]) };
                out.sheet_op_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--action")) {
            i += 1;
            if (i < argv.len) out.action = try a.dupe(u8, argv[i]);        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i < argv.len) out.select = std.fmt.parseInt(usize, argv[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--add-cdl")) {
            i += 1;
            if (i < argv.len) out.add_cdl = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i < argv.len) out.frames = std.fmt.parseInt(u32, argv[i], 10) catch 60;
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

/// Native GUI entry point. Called from `src/main.zig` for the default (no-argument) mode, so the
/// GUI is part of the one `pipelith` binary rather than a parallel program. It parses the same argv
/// the process was started with: `main.zig` ignores the GUI's own flags (they all begin with `-`),
/// so both parsers can read the one command line.
pub fn runGui(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const a = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    var err_buf: [1024]u8 = undefined;
    var errw = Io.File.stderr().writer(io, &err_buf);
    const e = &errw.interface;
    defer w.flush() catch {};
    defer e.flush() catch {};

    const argv = try init.minimal.args.toSlice(a);
    const opts = try parseArgs(a, argv);

    // Rule 4: the writable root is `<tool dir>/.pipelith`, anchored on the executable. `--state-dir`
    // overrides it for development and for hermetic tests, which must not touch the real one.
    const state_dir = if (opts.state_dir) |p| blk: {
        Io.Dir.cwd().createDirPath(io, p) catch {};
        break :blk p;
    } else (try builtin.stateDir(io, a)) orelse return error.ToolDirUnavailable;

    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;

    var sink = Sink{ .gpa = gpa, .io = io };
    defer sink.deinit();
    var svc = rpc.Service.init(gpa, io, init.minimal.environ, .{ .ctx = &sink, .send_fn = Sink.send });
    svc.cwd = try a.dupe(u8, cwd_buf[0..cwd_len]);
    svc.transport = "native";
    svc.mode = "gui";
    svc.user_dir = state_dir;
    // User tools live beside the autosave (`<state dir>/cdl`), so `--state-dir` keeps the GUI's
    // tool directory hermetic too, exactly like the autosave and preferences.
    svc.tools_dir = try std.fs.path.join(a, &.{ state_dir, "cdl" });
    svc.packs_extra_dirs = opts.packs_dirs[0..opts.packs_dir_count];
    // Nothing is loaded by default: the tool library is whatever the user's tool directory holds,
    // which is empty until a pack is installed. The pack list (what *could* be installed) is
    // discovered here so the library panel can offer it.
    svc.loadUserTools();
    svc.refreshPacks();
    // Same shutdown discipline as the WebView2 shell: cancel an in-flight run and wait briefly. If
    // it does not settle, skip deinit on purpose — leaking beats letting the run thread touch freed
    // service state.
    defer {
        svc.cancel_flag.store(true, .seq_cst);
        var waits: u32 = 0;
        while (svc.running.load(.monotonic) and waits < 100) : (waits += 1) pl_gui_delay_ms(20);
        if (!svc.running.load(.monotonic)) svc.deinit();
    }

    var app = App.init(gpa, io, &svc, &sink);
    defer app.deinit();
    // Declared after app.deinit(), so it runs *before* it: the dumps need the live state.
    defer {
        if (opts.dump_log) |p| app.dumpLog(io, p);
        if (opts.dump_library) |p| app.dumpLibrary(io, p);
        if (opts.dump_packs) |p| app.dumpPacks(io, p);
        if (opts.dump_graph) |p| app.dumpGraph(io, p);
        if (opts.dump_form) |p| app.dumpForm(io, p);
    }
    // A scripted run must be hermetic: no autosave reads or writes, so repeated verification runs
    // cannot influence each other or the user's canvas. `--load-pack` is deliberately *not* on this
    // list: installing a pack is an ordinary user gesture, not a scripted mutation, so a start that
    // only loads a pack still restores the autosave and the preferences like any interactive start.
    const scripted = opts.demo or opts.add_cdl != null or opts.open_flow != null or
        opts.undo > 0 or opts.redo > 0 or opts.save_flow != null or opts.layout or
        opts.reload_library or opts.name != null or opts.add_command != null or
        opts.command_line != null or opts.expand_command or opts.delete_tool_named != null or
        opts.add_free != null or opts.sheet_op_count > 0 or
        opts.select_all or opts.copy or opts.paste or opts.delete_marked or
        opts.edit_tool != null or opts.save_tool or opts.hover_grid;
    app.autosave_enabled = !scripted;

    app.loadInfo();
    app.refresh();
    app.loadPacks();
    // `--load-pack <id>`: install a pack before anything else looks at the library, so `--add-cdl`,
    // `--add-free` and the library dump all see the tools it brings. Repeatable, because a run may
    // want tools from several packs.
    for (opts.load_packs[0..opts.load_pack_count]) |id| {
        if (svc.installPack(a, id) != null) {
            app.pack_status_key = .pack_loaded;
        } else {
            app.pack_status_key = .pack_failed;
            w.print("unknown tool pack: {s}\n", .{id}) catch {};
        }
        app.pack_status_len = copyZ(&app.pack_status, id);
    }
    if (opts.load_pack_count > 0) app.reloadLibrary();
    if (opts.search) |q| {
        const n = @min(q.len, app.search.len - 1);
        @memcpy(app.search[0..n], q[0..n]);
        app.refresh();
    }
    if (!scripted) _ = app.tryRestoreAutosave();
    if (opts.open_flow) |p| _ = app.readFlow(p);
    // Saved theme/language, then explicit flags on top (a flag always wins over the stored value).
    app.loadPrefs();
    // First history entry must be the *empty* canvas, before any test/seed mutation, so that undo
    // can always reach a blank document.
    app.commit();
    if (opts.demo) app.seedDemo();
    if (opts.add_cdl) |want| {
        for (app.items[0..app.item_count]) |item| {
            if (std.mem.eql(u8, item.name, want)) {
                app.addNode(item);
                app.form_loaded = false;
                break;
            }
        }
    }
    if (opts.select) |s| {
        if (s < app.nodes.items.len) {
            app.selected = s;
            app.form_loaded = false; // force the inspector to rebuild for the new selection
        }
    }
    // Before the undo/redo block on purpose: naming is a normal undoable mutation, so `--name X
    // --undo 1` must land back on the unnamed state. It commits, because the UI's rename path also
    // ends in a commit (on the text field losing focus) and the flag has to model that.
    if (opts.name) |nm| {
        app.setFlowName(nm);
        app.commit();
    }
    // Seed the history with the starting state so the first mutation is undoable back to it.
    if (opts.undo > 0) {
        var i: u32 = 0;
        while (i < opts.undo) : (i += 1) app.undo();
    }
    if (opts.redo > 0) {
        var i: u32 = 0;
        while (i < opts.redo) : (i += 1) app.redo();
    }
    // Machine-checkable state line, printed after every scripted mutation so it reflects the final
    // state (undo/redo, --action, theme and language included).
    if (opts.action) |want| {
        if (app.selected) |idx| {
            if (app.graph_arena.allocator().dupe(u8, want)) |copy| {
                app.nodes.items[idx].action = copy;
                app.form_loaded = false;
            } else |_| {}
        }
    }
    if (opts.duplicate) {
        if (app.selected) |idx| app.duplicateNode(idx);
    }
    if (opts.add_command) |exe| {
        if (app.addCommandNode(exe, 60, 60)) |ci| {
            // Rebuild argv as [exe] ++ args so the flag models the inspector's editor exactly.
            var text: [1024]u8 = undefined;
            var used: usize = 0;
            for (opts.command_args[0..opts.command_arg_count]) |av| {
                if (used + av.len + 2 >= text.len) break;
                @memcpy(text[used..][0..av.len], av);
                used += av.len;
                text[used] = '\n';
                used += 1;
            }
            if (used > 0) app.setNodeArgv(ci, text[0..used]);
            app.form_loaded = false;
        }
    }
    // Models the one-line editor exactly: the text goes through the same tokenize-and-apply path
    // the widget uses, so an unparsable line leaves argv untouched just like it does in the GUI.
    if (opts.command_line) |cl| {
        if (app.selected) |si| {
            const n = @min(cl.len, app.cmd_line.len - 1);
            @memcpy(app.cmd_line[0..n], cl[0..n]);
            app.cmd_line[n] = 0;
            app.cmd_line_for = si;
            app.applyCommandLine(si);
            app.form_loaded = false;
        }
    }
    if (opts.expand_command) {
        if (app.selected) |si| app.expandToCommand(si);
    }
    // The tool sheet's click paths, driven through the same code the panel buttons call, in the
    // exact order given — one flag per gesture. The sheet is fetched on demand here because these
    // run before the first frame would.
    if (opts.add_free) |want| {
        for (app.items[0..app.item_count]) |item| {
            if (std.mem.eql(u8, item.name, want)) {
                app.addFreeNode(item);
                break;
            }
        }
    }
    if (opts.sheet_op_count > 0) {
        if (app.selected) |si| app.fetchSheet(si);
    }
    for (opts.sheet_ops[0..opts.sheet_op_count]) |op| {
        switch (op) {
            .pick => |n| app.pickSheetRow(n),
            .back => {
                if (app.sheet_depth > 0) app.sheet_depth -= 1;
                app.sheet_slot = null;
            },
            .fill => |v| {
                if (app.selected) |si| app.applySlotValue(si, v);
            },
            .filter => |q| {
                const n = @min(q.len, app.sheet_filter.len - 1);
                @memcpy(app.sheet_filter[0..n], q[0..n]);
                app.sheet_filter[n] = 0;
            },
            .insert => |want| {
                if (app.selected) |si| {
                    for (app.sheet_presets) |*p| {
                        if (std.mem.eql(u8, p.name, want)) {
                            app.insertSheetPreset(si, p);
                            break;
                        }
                    }
                }
            },
        }
    }
    if (opts.layout) app.autoLayout();
    if (opts.reload_library) app.reloadLibrary();
    if (opts.select_all) app.markAll();
    if (opts.copy) app.copySelection();
    if (opts.paste) app.pasteClipboard();
    if (opts.delete_marked) app.deleteMarked();
    if (opts.edit_tool) |tn| app.beginEditTool(tn);
    if (opts.save_tool) app.saveEditedTool();
    if (opts.delete_tool_named) |tn| app.deleteTool(tn);
    if (opts.save_flow) |p| {
        if (!app.writeFlow(p)) try e.print("failed to write {s}\n", .{p});
    }
    try w.print("engine: {s}, {d} tools loaded, {d} packs available\n", .{
        if (app.engine_ok) "in-process" else "unavailable",
        app.tool_total,
        app.pack_count,
    });

    // Theme/language flags are applied before the window so the first frame is already correct.
    if (opts.lang_en) {
        app.lang = .en;
        app.flow_title = StrKey.untitled_workflow.get(app.lang);
    }
    if (opts.light) app.theme_kind = .light;

    try w.print("state: nodes={d} edges={d} canUndo={} canRedo={} lang={s} theme={s} zoom={d:.2}\n", .{
        app.nodes.items.len,
        app.edges.items.len,
        app.canUndo(),
        app.canRedo(),
        @tagName(app.lang),
        @tagName(app.theme_kind),
        app.view_zoom,
    });

    const title: [:0]const u8 = "Flow Pipelith";
    if (pl_gui_init(title.ptr, opts.width, opts.height) != 1) {
        try e.print("pl_gui_init failed: {s}\n", .{pl_gui_last_error()});
        return error.GuiInitFailed;
    }
    defer pl_gui_shutdown();
    // ImGui's own programmer-error count, printed at exit. It is the only machine-readable signal
    // for a frame built incorrectly — most often two widgets sharing a label, hence the same id,
    // which otherwise shows up only as a tooltip a human has to notice.
    defer {
        w.print("imgui-errors: {d}\n", .{pl_gui_error_count()}) catch {};
    }
    try w.print("window {d}x{d}, SDL renderer = {s}\n", .{ opts.width, opts.height, pl_gui_renderer_name() });

    // Push the palette into the widget style before the first frame.
    app.applyTheme();

    // Font: system CJK font, nothing vendored.
    var font_loaded: ?[]const u8 = null;
    if (opts.font) |f| {
        const z = dupeZ(a, f) catch null;
        if (z) |zz| {
            if (pl_gui_load_font(zz.ptr, 18.0) == 1) font_loaded = f;
        }
    } else {
        for (fontCandidates(a, svc.envMap())) |path| {
            const z = dupeZ(a, path) catch continue;
            if (pl_gui_load_font(z.ptr, 18.0) == 1) {
                font_loaded = path;
                break;
            }
        }
    }
    if (font_loaded) |p| {
        try w.print("font: {s}\n", .{p});
    } else {
        try e.print("WARNING: no CJK font loaded; Chinese text will not render\n", .{});
    }

    const shot_z: ?[:0]u8 = if (opts.shot) |s| try dupeZ(a, s) else null;
    var frames: u32 = 0;
    const capture_at: u32 = if (shot_z != null) @max(opts.frames, 3) else 0;

    if (opts.preview) app.doPreview();
    if (opts.run) app.doRun();

    while (pl_gui_pump() == 1) {
        // Per-frame arena. Draining events allocates, and `defer` inside the loop body runs once per
        // iteration, so this cannot grow the process arena across frames.
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();

        // Events pushed by run worker threads are queued by the sink and consumed on the UI thread.
        app.drainEvents(frame.allocator());

        // Sweep the synthetic pointer over the window, one grid cell per frame. The grid is finer
        // than any widget, so every control gets hovered — a coarser grid simply steps over a
        // button-sized target and reports nothing.
        if (opts.hover_grid) {
            const cols: u32 = 64;
            const rows: u32 = 48;
            const cell = frames % (cols * rows);
            const fx = @as(f32, @floatFromInt(cell % cols)) / @as(f32, cols - 1);
            const fy = @as(f32, @floatFromInt(cell / cols)) / @as(f32, rows - 1);
            pl_gui_set_synthetic_mouse(
                0.005 * @as(f32, @floatFromInt(opts.width)) + fx * 0.99 * @as(f32, @floatFromInt(opts.width)),
                0.005 * @as(f32, @floatFromInt(opts.height)) + fy * 0.99 * @as(f32, @floatFromInt(opts.height)),
            );
        }

        pl_gui_begin_frame();
        app.draw();
        frames += 1;

        // Fit needs the canvas rectangle, which only exists after the first draw.
        if (opts.fit and frames == 2) {
            app.fitView();
            try w.print("fit: zoom={d:.2} pan={d:.1},{d:.1}\n", .{ app.view_zoom, app.view_pan_x, app.view_pan_y });
        }

        const want_shot = capture_at != 0 and frames >= capture_at;
        const saved = pl_gui_end_frame(if (want_shot) shot_z.?.ptr else null);
        if (want_shot) {
            if (saved == 1) {
                try w.print("wrote screenshot: {s}\n", .{opts.shot.?});
            } else {
                try e.print("screenshot failed: {s}\n", .{pl_gui_last_error()});
            }
            return 0;
        }
        if (opts.frames != 0 and frames >= opts.frames) return 0;
        // The hover sweep needs thousands of frames; pacing them at 12ms would make the check take a
        // minute for no benefit, since nothing here depends on wall-clock time.
        if (!opts.hover_grid) pl_gui_delay_ms(12);
    }
    return 0;
}
