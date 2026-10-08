// gui_shim.h — the native GUI's C ABI.
//
// Same role that `webview2_shim.c` plays for the WebView2 shell: the OS/GUI-library details stay
// on the C++ side of this boundary and Zig only sees flat, `extern "C"` functions. That keeps the
// ImGui/SDL dependency surface auditable and means no generated binding layer (cimgui) is needed —
// which also matters because Zig 0.17 removed `@cImport`.
//
// Colours are packed exactly like IM_COL32: (r) | (g << 8) | (b << 16) | (a << 24).
// All functions are single-threaded and only valid between pl_gui_init() and pl_gui_shutdown().

#ifndef PL_GUI_SHIM_H
#define PL_GUI_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// ── lifecycle ───────────────────────────────────────────────────────────────
// Returns 1 on success. `title` is UTF-8.
int pl_gui_init(const char* title, int width, int height);
void pl_gui_shutdown(void);

// Applies a palette to the widget style and remembers the colour used to clear each frame.
// Colours are packed like IM_COL32: (r) | (g << 8) | (b << 16) | (a << 24). `light` picks the
// stock light/dark base for every slot not listed, so both themes stay coherent.
void pl_gui_apply_theme(unsigned bg, unsigned panel, unsigned sunken, unsigned border,
                        unsigned text, unsigned text_dim, unsigned accent, int light);

// Drains the platform event queue. Returns 1 while the window should keep running, 0 once the
// user asked to close it.
int pl_gui_pump(void);

// ── frame ───────────────────────────────────────────────────────────────────
void pl_gui_begin_frame(void);
// Renders and presents. When `shot_path` is non-NULL the frame is also read back from the renderer
// and written as a BMP before presenting - that is what makes the GUI verifiable headlessly.
// Returns 1 if a screenshot was written.
int pl_gui_end_frame(const char* shot_path);

// ── diagnostics ─────────────────────────────────────────────────────────────
// Name of the SDL renderer backend that actually came up (e.g. "direct3d11", "software").
const char* pl_gui_renderer_name(void);
const char* pl_gui_last_error(void);
// Cumulative count of ImGui programmer errors (recoverable errors and conflicting widget ids). The
// UI is expected to produce zero; anything else is a bug in how the frame was built, and is the only
// machine-readable signal for the class of defect where two widgets share a label and therefore an id.
int pl_gui_error_count(void);

// ── fonts ───────────────────────────────────────────────────────────────────
// Loads a TTF/TTC as the default UI font at `size_px`. Returns 1 on success. ImGui 1.92 loads
// glyphs on demand, so CJK needs no explicit range declaration.
int pl_gui_load_font(const char* path, float size_px);

// ── root window ─────────────────────────────────────────────────────────────
// A borderless window covering the whole viewport; the native equivalent of `#app`.
void pl_gui_root_begin(const char* id);
void pl_gui_root_end(void);

// ── widgets ─────────────────────────────────────────────────────────────────
void pl_gui_text(const char* text);
void pl_gui_text_dim(const char* text);
int pl_gui_input_text(const char* id, char* buf, int buf_len);
void pl_gui_separator(void);
void pl_gui_same_line(void);
// Ends the current line explicitly. Needed before measuring a region that must start on a fresh
// row (the canvas measures its rect from the cursor, so an inline toolbar would otherwise make the
// drawable area begin on the toolbar's own row).
void pl_gui_new_line(void);

// ── layout / input introspection ────────────────────────────────────────────
void pl_gui_content_avail(float* out_w, float* out_h);
void pl_gui_cursor_pos(float* out_x, float* out_y);
// Full-cell interaction surface. `buttons` is a bitmask: 1 = left, 2 = right.
int pl_gui_invisible_button(const char* id, float w, float h, int buttons);
int pl_gui_item_hovered(void);
int pl_gui_item_active(void);
float pl_gui_mouse_wheel(void);
void pl_gui_mouse_delta(float* out_dx, float* out_dy);

// ── draw list (the node canvas) ─────────────────────────────────────────────
// `round` is 1 to round the top two corners, 0 to round all of them.
void pl_gui_dl_rect_filled(float x0, float y0, float x1, float y1, unsigned col, float rounding, int round_top);
void pl_gui_dl_rect(float x0, float y0, float x1, float y1, unsigned col, float rounding, float thickness);
void pl_gui_dl_line(float x0, float y0, float x1, float y1, unsigned col, float thickness);
void pl_gui_dl_circle_filled(float cx, float cy, float radius, unsigned col);
void pl_gui_dl_circle(float cx, float cy, float radius, unsigned col, float thickness);
void pl_gui_dl_bezier(float x0, float y0, float x1, float y1,
                      float x2, float y2, float x3, float y3,
                      unsigned col, float thickness);
void pl_gui_dl_text(float x, float y, unsigned col, const char* text);

// ── panels & layout ─────────────────────────────────────────────────────────
// Scrollable panel region. `border` draws a 1px frame (the equivalent of the web `.panel`).
void pl_gui_begin_child(const char* id, float w, float h, int border);
void pl_gui_end_child(void);
void pl_gui_dummy(float w, float h);
void pl_gui_set_next_item_width(float w);
// Screen-space cursor placement; the canvas positions each node's hit box from its world rect.
void pl_gui_set_cursor_screen_pos(float x, float y);
float pl_gui_calc_text_width(const char* text);
float pl_gui_text_line_height(void);
// Width to reserve on the current row for a button carrying `label`, so a `pl_gui_button(label)`
// submitted after `pl_gui_same_line()` fits beside a same-line input. Measured, not assumed: ImGui
// sizes a button from the visible text (the `##id` suffix is excluded) plus FramePadding, and this
// includes the item spacing that precedes it. Use it as `pl_gui_set_next_item_width(-reserve)`.
// A hardcoded reserve that is narrower than the localized label pushes the button past the content
// region, under the panel's scrollbar, where it is partly unreadable — the defect this prevents.
float pl_gui_button_row_reserve(const char* label);

// ── more widgets ────────────────────────────────────────────────────────────
// `w`/`h` of 0 means "size to content", matching ImGui.
int pl_gui_button(const char* label, float w, float h);
// A full-width list row; returns 1 when clicked.
int pl_gui_selectable(const char* label, int selected);
int pl_gui_input_text_hint(const char* id, const char* hint, char* buf, int buf_len);
int pl_gui_input_text_multiline(const char* id, char* buf, int buf_len, float w, float h);
// Checkbox returning the new state (0/1) instead of taking a pointer, so the Zig side can keep
// values in its own model rather than mirrored C storage.
int pl_gui_checkbox(const char* label, int value);
// Dropdown. Returns the newly selected index (or `current` when nothing was picked).
// `items` is an array of `count` NUL-terminated UTF-8 strings.
int pl_gui_combo(const char* id, int current, const char* const* items, int count);
void pl_gui_text_heading(const char* text);
void pl_gui_separator_text(const char* text);
void pl_gui_text_error(const char* text);
// Coloured one-line text: the output panel colours stdout/stderr/system differently.
void pl_gui_text_colored(const char* text, unsigned col);
// Enable/disable a block of widgets (`disabled` = 1 greys them out and blocks input).
void pl_gui_begin_disabled(int disabled);
void pl_gui_end_disabled(void);
// Pin a scrolling region to its last line (used by the output panel's autoscroll).
void pl_gui_scroll_to_bottom(void);
// Wraps at the current content width; needed for CDL descriptions and long status lines.
void pl_gui_text_wrapped(const char* text);
// Same, in the dimmed style — CDL variable labels are frequently too long for one line.
void pl_gui_text_dim_wrapped(const char* text);

// ── timing ──────────────────────────────────────────────────────────────────
// Keeps the frame loop from spinning. Exposed so the Zig side needs no SDL dependency.
void pl_gui_delay_ms(int ms);

// ── keyboard & pointer ──────────────────────────────────────────────────────
// Semantic key codes, so the Zig side never depends on ImGuiKey values.
enum {
  PL_GUI_KEY_Z = 1,
  PL_GUI_KEY_Y,
  PL_GUI_KEY_DELETE,
  PL_GUI_KEY_ESCAPE,
  PL_GUI_KEY_ENTER,
  PL_GUI_KEY_D,
  // Shortcut keys for the topbar actions (new/open/save/focus-search/auto-layout/zoom).
  PL_GUI_KEY_N,
  PL_GUI_KEY_O,
  PL_GUI_KEY_S,
  PL_GUI_KEY_F,
  PL_GUI_KEY_L,
  PL_GUI_KEY_MINUS,
  PL_GUI_KEY_EQUAL,
  PL_GUI_KEY_0,
  PL_GUI_KEY_A,
  PL_GUI_KEY_C,
  PL_GUI_KEY_V,
};

// Moves keyboard focus to the next widget submitted. Used by Ctrl+F so the search box can be
// reached without the mouse.
void pl_gui_set_keyboard_focus_here(void);

// 1 only on the frame the key transitions to down.
int pl_gui_key_pressed(int key);
int pl_gui_key_ctrl(void);
int pl_gui_key_shift(void);
// 1 while a text field owns the keyboard: shortcuts must not fire then.
int pl_gui_want_text_input(void);
// 1 on the frame an item loses focus after being edited — the idiomatic point to close an undo
// entry, so a whole typing burst collapses into one step instead of one step per keystroke.
int pl_gui_item_deactivated_after_edit(void);

// Pointer state in screen space, for hit-testing canvas ports.
void pl_gui_mouse_pos(float* out_x, float* out_y);
// `button`: 1 = left, 2 = right. 1 while held.
int pl_gui_mouse_down(int button);

// Feeds ImGui a synthetic pointer position, overriding the platform one from the next frame on.
//
// This exists because ImGui only reports a conflicting-widget-id error for the item that is
// *hovered*, so with no pointer nothing is ever hovered and that whole class of bug is invisible to
// a headless run. Hovering a grid of positions turns "the UI built itself wrongly" into a number
// (see pl_gui_error_count) that the harness can assert on.
void pl_gui_set_synthetic_mouse(float x, float y);

#ifdef __cplusplus
}
#endif

#endif // PL_GUI_SHIM_H
