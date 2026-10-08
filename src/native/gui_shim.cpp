// gui_shim.cpp — implementation of the native GUI's C ABI (see gui_shim.h).
//
// Owns the SDL window/input/renderer and the ImGui context. Everything here is single-threaded
// and driven from the Zig main loop; the engine side is untouched.

#include "gui_shim.h"

#include "imgui.h"
// imgui_internal.h is included only to *observe* ImGui's own error counters, so a programmer error
// (the classic being two widgets sharing a label, hence the same id) becomes a number the Zig side
// can report and the test harness can assert on, instead of a tooltip only a human would notice.
// Nothing internal is written to.
#include "imgui_internal.h"
#include "imgui_impl_sdl3.h"
#include "imgui_impl_sdlrenderer3.h"

#include <SDL3/SDL.h>

#include <cstdio>
#include <cstring>

namespace {

SDL_Window*   g_window   = nullptr;
SDL_Renderer* g_renderer = nullptr;
bool          g_running  = false;
bool          g_in_frame = false;
char          g_error[512] = {0};
/// Frame clear colour; owned by pl_gui_apply_theme so the palette stays on the Zig side.
ImVec4        g_clear = ImVec4(0.043f, 0.067f, 0.114f, 1.0f);
/// Programmer errors ImGui reported (recoverable errors + conflicting widget ids), accumulated
/// across frames. Zero is the only acceptable value; see pl_gui_error_count().
int           g_error_frames = 0;
/// When set, this position is injected as the pointer before every frame, so a headless run can
/// hover things (see pl_gui_set_synthetic_mouse).
bool          g_synthetic_mouse = false;
float         g_synthetic_x = 0.0f;
float         g_synthetic_y = 0.0f;

// ImDrawFlags is not part of the flat ABI, so the shim maps its own flag.
constexpr int kRoundTop = 1;

void setError(const char* what) {
    std::snprintf(g_error, sizeof(g_error), "%s: %s", what, SDL_GetError());
}

inline ImVec2 v2(float x, float y) { return ImVec2(x, y); }

} // namespace

extern "C" {

int pl_gui_init(const char* title, int width, int height) {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        setError("SDL_Init");
        return 0;
    }

    // SDL_WINDOW_HIGH_PIXEL_DENSITY keeps the UI crisp on scaled displays; ImGui's SDL3 backend
    // reports the DPI scale through DisplayFramebufferScale.
    const SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (!SDL_CreateWindowAndRenderer(title, width, height, flags, &g_window, &g_renderer)) {
        setError("SDL_CreateWindowAndRenderer");
        SDL_Quit();
        return 0;
    }
    SDL_SetWindowPosition(g_window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    // A desktop tool must not litter: no imgui.ini, no log file next to the executable.
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    ImGui::StyleColorsDark();

    if (!ImGui_ImplSDL3_InitForSDLRenderer(g_window, g_renderer)) {
        g_error[0] = 0;
        std::snprintf(g_error, sizeof(g_error), "ImGui_ImplSDL3_InitForSDLRenderer failed");
        return 0;
    }
    if (!ImGui_ImplSDLRenderer3_Init(g_renderer)) {
        std::snprintf(g_error, sizeof(g_error), "ImGui_ImplSDLRenderer3_Init failed");
        return 0;
    }

    SDL_ShowWindow(g_window);
    g_running = true;
    return 1;
}

void pl_gui_shutdown(void) {
    if (g_renderer) {
        ImGui_ImplSDLRenderer3_Shutdown();
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        SDL_DestroyRenderer(g_renderer);
        g_renderer = nullptr;
    }
    if (g_window) {
        SDL_DestroyWindow(g_window);
        g_window = nullptr;
    }
    SDL_Quit();
    g_running = false;
}

void pl_gui_apply_theme(unsigned bg, unsigned panel, unsigned sunken, unsigned border,
                        unsigned text, unsigned text_dim, unsigned accent, int light) {
    // Stock base first, so slots this function does not name (tabs, resize grips, ...) stay
    // coherent in both themes; then the design system's own tokens on top.
    if (light) {
        ImGui::StyleColorsLight();
    } else {
        ImGui::StyleColorsDark();
    }
    ImGuiStyle& s = ImGui::GetStyle();
    const ImVec4 c_bg = ImGui::ColorConvertU32ToFloat4(bg);
    const ImVec4 c_panel = ImGui::ColorConvertU32ToFloat4(panel);
    const ImVec4 c_sunken = ImGui::ColorConvertU32ToFloat4(sunken);
    const ImVec4 c_border = ImGui::ColorConvertU32ToFloat4(border);
    const ImVec4 c_text = ImGui::ColorConvertU32ToFloat4(text);
    const ImVec4 c_dim = ImGui::ColorConvertU32ToFloat4(text_dim);
    const ImVec4 c_accent = ImGui::ColorConvertU32ToFloat4(accent);

    ImVec4 accent_soft = c_accent;
    accent_soft.w = light ? 0.18f : 0.30f;
    ImVec4 accent_mid = c_accent;
    accent_mid.w = light ? 0.26f : 0.42f;

    s.Colors[ImGuiCol_WindowBg] = c_bg;
    s.Colors[ImGuiCol_ChildBg] = c_panel;
    s.Colors[ImGuiCol_PopupBg] = c_panel;
    s.Colors[ImGuiCol_FrameBg] = c_sunken;
    s.Colors[ImGuiCol_FrameBgHovered] = c_panel;
    s.Colors[ImGuiCol_FrameBgActive] = c_panel;
    s.Colors[ImGuiCol_Border] = c_border;
    s.Colors[ImGuiCol_Text] = c_text;
    s.Colors[ImGuiCol_TextDisabled] = c_dim;
    s.Colors[ImGuiCol_CheckMark] = c_accent;
    // Selectable rows carry the "active tab / selected tool" state.
    s.Colors[ImGuiCol_Header] = accent_soft;
    s.Colors[ImGuiCol_HeaderHovered] = accent_mid;
    s.Colors[ImGuiCol_HeaderActive] = accent_mid;
    s.Colors[ImGuiCol_Button] = c_panel;
    s.Colors[ImGuiCol_ButtonHovered] = accent_soft;
    s.Colors[ImGuiCol_ButtonActive] = accent_mid;
    s.Colors[ImGuiCol_Separator] = c_border;
    s.Colors[ImGuiCol_ScrollbarBg] = c_bg;
    s.Colors[ImGuiCol_ScrollbarGrab] = c_border;
    s.Colors[ImGuiCol_ScrollbarGrabHovered] = c_dim;
    s.Colors[ImGuiCol_ScrollbarGrabActive] = c_dim;
    g_clear = c_bg;
}

int pl_gui_pump(void) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        ImGui_ImplSDL3_ProcessEvent(&event);
        if (event.type == SDL_EVENT_QUIT) g_running = false;
        if (event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED &&
            event.window.windowID == SDL_GetWindowID(g_window)) {
            g_running = false;
        }
    }
    return g_running ? 1 : 0;
}

void pl_gui_begin_frame(void) {
    ImGui_ImplSDLRenderer3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    // Injected after the backend's NewFrame, so this position is the last input event ImGui sees and
    // therefore wins over whatever the platform reported. ImGui requires input events to be queued
    // before NewFrame().
    if (g_synthetic_mouse) ImGui::GetIO().AddMousePosEvent(g_synthetic_x, g_synthetic_y);
    ImGui::NewFrame();
    g_in_frame = true;
}

void pl_gui_set_synthetic_mouse(float x, float y) {
    g_synthetic_mouse = true;
    g_synthetic_x = x;
    g_synthetic_y = y;
}

int pl_gui_end_frame(const char* shot_path) {
    if (!g_in_frame) return 0;

    ImGui::Render();

    // Sample ImGui's error state *after* Render(): the conflicting-id check runs in EndFrame(), which
    // Render() calls, so reading this earlier always saw zero. Sticky, because the caller only reads
    // it once, at shutdown.
    {
        ImGuiContext* ctx = ImGui::GetCurrentContext();
        if (ctx) {
            if (ctx->ErrorCountCurrentFrame > 0) g_error_frames += ctx->ErrorCountCurrentFrame;
            if (ctx->DebugDrawIdConflictsId != 0) g_error_frames += 1;
        }
    }

    const ImVec4 clear = g_clear;
    SDL_SetRenderDrawColorFloat(g_renderer, clear.x, clear.y, clear.z, clear.w);
    SDL_RenderClear(g_renderer);
    ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), g_renderer);

    int captured = 0;
    if (shot_path) {
        // Read back from the renderer rather than the screen: works with no visible desktop and
        // makes this path usable as a headless visual check. SDL3 returns a fresh surface.
        SDL_Surface* surf = SDL_RenderReadPixels(g_renderer, nullptr);
        if (surf) {
            captured = SDL_SaveBMP(surf, shot_path) ? 1 : 0;
            if (!captured) setError("SDL_SaveBMP");
            SDL_DestroySurface(surf);
        } else {
            setError("SDL_RenderReadPixels");
        }
    }

    SDL_RenderPresent(g_renderer);
    g_in_frame = false;
    return captured;
}

const char* pl_gui_renderer_name(void) {
    const char* name = g_renderer ? SDL_GetRendererName(g_renderer) : nullptr;
    return name ? name : "(none)";
}

const char* pl_gui_last_error(void) { return g_error; }

int pl_gui_load_font(const char* path, float size_px) {
    if (!path || !*path) return 0;
    ImFontConfig cfg;
    cfg.FontNo = 0; // .ttc collections: face 0 is the regular weight
    // ImGui 1.92 builds the atlas lazily, so no glyph-range list is needed for CJK.
    ImFont* font = ImGui::GetIO().Fonts->AddFontFromFileTTF(path, size_px, &cfg, nullptr);
    if (!font) return 0;
    ImGui::GetIO().FontDefault = font;
    return 1;
}

void pl_gui_root_begin(const char* id) {
    const ImGuiViewport* vp = ImGui::GetMainViewport();
    ImGui::SetNextWindowPos(vp->WorkPos);
    ImGui::SetNextWindowSize(vp->WorkSize);
    const ImGuiWindowFlags flags =
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBringToFrontOnFocus |
        ImGuiWindowFlags_NoNavFocus | ImGuiWindowFlags_NoScrollbar |
        ImGuiWindowFlags_NoScrollWithMouse;
    ImGui::Begin(id, nullptr, flags);
}

void pl_gui_root_end(void) { ImGui::End(); }

void pl_gui_text(const char* text) { ImGui::TextUnformatted(text); }

void pl_gui_text_dim(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_TextDisabled]);
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

int pl_gui_input_text(const char* id, char* buf, int buf_len) {
    if (buf_len <= 0) return 0;
    return ImGui::InputText(id, buf, static_cast<size_t>(buf_len)) ? 1 : 0;
}

void pl_gui_separator(void) { ImGui::Separator(); }
void pl_gui_same_line(void) { ImGui::SameLine(); }

void pl_gui_content_avail(float* out_w, float* out_h) {
    const ImVec2 a = ImGui::GetContentRegionAvail();
    if (out_w) *out_w = a.x;
    if (out_h) *out_h = a.y;
}

void pl_gui_cursor_pos(float* out_x, float* out_y) {
    const ImVec2 p = ImGui::GetCursorScreenPos();
    if (out_x) *out_x = p.x;
    if (out_y) *out_y = p.y;
}

int pl_gui_invisible_button(const char* id, float w, float h, int buttons) {
    ImGuiButtonFlags flags = 0;
    if (buttons & 1) flags |= ImGuiButtonFlags_MouseButtonLeft;
    if (buttons & 2) flags |= ImGuiButtonFlags_MouseButtonRight;
    return ImGui::InvisibleButton(id, v2(w, h), flags) ? 1 : 0;
}

int pl_gui_item_hovered(void) { return ImGui::IsItemHovered() ? 1 : 0; }
int pl_gui_item_active(void) { return ImGui::IsItemActive() ? 1 : 0; }
float pl_gui_mouse_wheel(void) { return ImGui::GetIO().MouseWheel; }

void pl_gui_mouse_delta(float* out_dx, float* out_dy) {
    const ImVec2 d = ImGui::GetIO().MouseDelta;
    if (out_dx) *out_dx = d.x;
    if (out_dy) *out_dy = d.y;
}

void pl_gui_dl_rect_filled(float x0, float y0, float x1, float y1, unsigned col, float rounding, int round_top) {
    ImGui::GetWindowDrawList()->AddRectFilled(
        v2(x0, y0), v2(x1, y1), static_cast<ImU32>(col), rounding,
        round_top == kRoundTop ? ImDrawFlags_RoundCornersTop : ImDrawFlags_RoundCornersAll);
}

void pl_gui_dl_rect(float x0, float y0, float x1, float y1, unsigned col, float rounding, float thickness) {
    ImGui::GetWindowDrawList()->AddRect(v2(x0, y0), v2(x1, y1), static_cast<ImU32>(col),
                                        rounding, ImDrawFlags_RoundCornersAll, thickness);
}

void pl_gui_dl_line(float x0, float y0, float x1, float y1, unsigned col, float thickness) {
    ImGui::GetWindowDrawList()->AddLine(v2(x0, y0), v2(x1, y1), static_cast<ImU32>(col), thickness);
}

void pl_gui_dl_circle_filled(float cx, float cy, float radius, unsigned col) {
    ImGui::GetWindowDrawList()->AddCircleFilled(v2(cx, cy), radius, static_cast<ImU32>(col));
}

void pl_gui_dl_circle(float cx, float cy, float radius, unsigned col, float thickness) {
    ImGui::GetWindowDrawList()->AddCircle(v2(cx, cy), radius, static_cast<ImU32>(col), 0, thickness);
}

void pl_gui_dl_bezier(float x0, float y0, float x1, float y1,
                      float x2, float y2, float x3, float y3,
                      unsigned col, float thickness) {
    ImGui::GetWindowDrawList()->AddBezierCubic(v2(x0, y0), v2(x1, y1), v2(x2, y2), v2(x3, y3),
                                               static_cast<ImU32>(col), thickness);
}

void pl_gui_dl_text(float x, float y, unsigned col, const char* text) {
    ImGui::GetWindowDrawList()->AddText(v2(x, y), static_cast<ImU32>(col), text);
}

void pl_gui_delay_ms(int ms) { SDL_Delay(static_cast<Uint32>(ms)); }

// Cumulative count of ImGui programmer errors. Anything above zero means the UI built itself
// incorrectly — most often two widgets with the same label and therefore the same id.
int pl_gui_error_count(void) { return g_error_frames; }

void pl_gui_new_line(void) { ImGui::NewLine(); }

// ── keyboard & pointer ──────────────────────────────────────────────────────

int pl_gui_key_pressed(int key) {
    ImGuiKey k = ImGuiKey_None;
    switch (key) {
        case PL_GUI_KEY_Z: k = ImGuiKey_Z; break;
        case PL_GUI_KEY_Y: k = ImGuiKey_Y; break;
        case PL_GUI_KEY_DELETE: k = ImGuiKey_Delete; break;
        case PL_GUI_KEY_ESCAPE: k = ImGuiKey_Escape; break;
        case PL_GUI_KEY_ENTER: k = ImGuiKey_Enter; break;
        case PL_GUI_KEY_D: k = ImGuiKey_D; break;
        case PL_GUI_KEY_N: k = ImGuiKey_N; break;
        case PL_GUI_KEY_O: k = ImGuiKey_O; break;
        case PL_GUI_KEY_S: k = ImGuiKey_S; break;
        case PL_GUI_KEY_F: k = ImGuiKey_F; break;
        case PL_GUI_KEY_L: k = ImGuiKey_L; break;
        case PL_GUI_KEY_MINUS: k = ImGuiKey_Minus; break;
        case PL_GUI_KEY_EQUAL: k = ImGuiKey_Equal; break;
        case PL_GUI_KEY_0: k = ImGuiKey_0; break;
        case PL_GUI_KEY_A: k = ImGuiKey_A; break;
        case PL_GUI_KEY_C: k = ImGuiKey_C; break;
        case PL_GUI_KEY_V: k = ImGuiKey_V; break;
        default: return 0;
    }
    return ImGui::IsKeyPressed(k) ? 1 : 0;
}

int pl_gui_key_ctrl(void) { return ImGui::GetIO().KeyCtrl ? 1 : 0; }
int pl_gui_key_shift(void) { return ImGui::GetIO().KeyShift ? 1 : 0; }
int pl_gui_want_text_input(void) { return ImGui::GetIO().WantTextInput ? 1 : 0; }
int pl_gui_item_deactivated_after_edit(void) { return ImGui::IsItemDeactivatedAfterEdit() ? 1 : 0; }

// Applies to the *next* widget submitted, which is why Ctrl+F sets a flag consumed by the search
// box rather than calling this from the shortcut handler (nothing is mid-submission there).
void pl_gui_set_keyboard_focus_here(void) { ImGui::SetKeyboardFocusHere(); }

void pl_gui_mouse_pos(float* out_x, float* out_y) {
    const ImVec2 p = ImGui::GetIO().MousePos;
    if (out_x) *out_x = p.x;
    if (out_y) *out_y = p.y;
}

int pl_gui_mouse_down(int button) {
    return ImGui::IsMouseDown(button == 2 ? ImGuiMouseButton_Right : ImGuiMouseButton_Left) ? 1 : 0;
}

// ── panels & layout ─────────────────────────────────────────────────────────

void pl_gui_begin_child(const char* id, float w, float h, int border) {
    ImGui::BeginChild(id, v2(w, h), border ? ImGuiChildFlags_Borders : 0, ImGuiWindowFlags_None);
}

void pl_gui_end_child(void) { ImGui::EndChild(); }
void pl_gui_dummy(float w, float h) { ImGui::Dummy(v2(w, h)); }
void pl_gui_set_next_item_width(float w) { ImGui::SetNextItemWidth(w); }
void pl_gui_set_cursor_screen_pos(float x, float y) { ImGui::SetCursorScreenPos(v2(x, y)); }

float pl_gui_calc_text_width(const char* text) { return ImGui::CalcTextSize(text).x; }
float pl_gui_text_line_height(void) { return ImGui::GetTextLineHeightWithSpacing(); }

// Width to reserve on the current row so a button carrying `label` fits beside a same-line input.
// ImGui sizes a button from its visible text plus FramePadding, and `##` hides the id suffix from
// that measurement, so a caller-side constant is a guess — and a reserve narrower than the
// (localized) label slides the button under the panel's scrollbar, where its last glyphs vanish.
float pl_gui_button_row_reserve(const char* label) {
    const ImGuiStyle& st = ImGui::GetStyle();
    return ImGui::CalcTextSize(label, NULL, true).x + st.FramePadding.x * 2.0f + st.ItemSpacing.x;
}

// ── more widgets ────────────────────────────────────────────────────────────

int pl_gui_button(const char* label, float w, float h) { return ImGui::Button(label, v2(w, h)) ? 1 : 0; }

int pl_gui_selectable(const char* label, int selected) {
    return ImGui::Selectable(label, selected != 0) ? 1 : 0;
}

int pl_gui_input_text_hint(const char* id, const char* hint, char* buf, int buf_len) {
    if (buf_len <= 0) return 0;
    return ImGui::InputTextWithHint(id, hint, buf, static_cast<size_t>(buf_len)) ? 1 : 0;
}

int pl_gui_input_text_multiline(const char* id, char* buf, int buf_len, float w, float h) {
    if (buf_len <= 0) return 0;
    return ImGui::InputTextMultiline(id, buf, static_cast<size_t>(buf_len), v2(w, h)) ? 1 : 0;
}

int pl_gui_checkbox(const char* label, int value) {
    bool v = value != 0;
    ImGui::Checkbox(label, &v);
    return v ? 1 : 0;
}

int pl_gui_combo(const char* id, int current, const char* const* items, int count) {
    int sel = current;
    const char* preview = (current >= 0 && current < count) ? items[current] : "";
    if (ImGui::BeginCombo(id, preview)) {
        for (int i = 0; i < count; ++i) {
            const bool is_selected = (i == current);
            if (ImGui::Selectable(items[i], is_selected)) sel = i;
            if (is_selected) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    return sel;
}

void pl_gui_text_error(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.94f, 0.42f, 0.42f, 1.0f));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

void pl_gui_text_colored(const char* text, unsigned col) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::ColorConvertU32ToFloat4(static_cast<ImU32>(col)));
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

void pl_gui_begin_disabled(int disabled) { ImGui::BeginDisabled(disabled != 0); }
void pl_gui_end_disabled(void) { ImGui::EndDisabled(); }
void pl_gui_scroll_to_bottom(void) { ImGui::SetScrollHereY(1.0f); }

void pl_gui_text_heading(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_Text]);
    ImGui::TextUnformatted(text);
    ImGui::PopStyleColor();
}

void pl_gui_separator_text(const char* text) { ImGui::SeparatorText(text); }

void pl_gui_text_wrapped(const char* text) {
    // TextUnformatted inside a wrap region: passing `text` as a format string would make any
    // '%' in a CDL description a format specifier.
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
}

void pl_gui_text_dim_wrapped(const char* text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_TextDisabled]);
    pl_gui_text_wrapped(text);
    ImGui::PopStyleColor();
}

} // extern "C"
