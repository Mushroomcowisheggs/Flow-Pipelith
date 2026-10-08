//! Native GUI palette.
//!
//! The values are lifted verbatim from the web design system's tokens (`web/styles.css`, `:root`
//! and `:root[data-theme="light"]`) so the native window keeps the same "Blueprint Night" look and
//! the light theme matches what the browser build shows. Keeping one source of truth per theme
//! means the canvas draw-list colours and the widget style cannot drift apart.

pub inline fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return r | (g << 8) | (b << 16) | (a << 24);
}

pub const Kind = enum {
    dark,
    light,

    pub fn label(self: Kind) [:0]const u8 {
        return switch (self) {
            .dark => "☾",
            .light => "☀",
        };
    }

    pub fn other(self: Kind) Kind {
        return switch (self) {
            .dark => .light,
            .light => .dark,
        };
    }
};

pub const Palette = struct {
    kind: Kind,
    /// Window background; also the renderer clear colour.
    bg: u32,
    /// Child-window / panel background.
    panel: u32,
    /// Input and sunken surfaces.
    sunken: u32,
    border: u32,
    text: u32,
    text_dim: u32,
    accent: u32,
    danger: u32,
    warn: u32,
    success: u32,
    /// Canvas node card body and its header text.
    node_bg: u32,
    node_header_text: u32,
    /// Edge colours by kind (pipe / sequential).
    edge_pipe: u32,
    edge_seq: u32,
    /// Canvas grid dots.
    grid: u32,
    /// Node status indicator colours (mirrors --status-* in the web design system).
    status_idle: u32,
    status_running: u32,
    status_success: u32,
    status_failed: u32,
};

pub const dark = Palette{
    .kind = .dark,
    .bg = rgba(11, 17, 29, 255), // #0b111d
    .panel = rgba(16, 24, 39, 255), // #101827
    .sunken = rgba(7, 12, 22, 255), // #070c16
    .border = rgba(34, 48, 73, 255), // #223049
    .text = rgba(227, 234, 247, 255), // #e3eaf7
    .text_dim = rgba(147, 165, 199, 255), // #93a5c7
    .accent = rgba(91, 148, 255, 255), // #5b94ff
    .danger = rgba(255, 122, 118, 255), // #ff7a76
    .warn = rgba(245, 184, 77, 255), // #f5b84d
    .success = rgba(74, 222, 155, 255), // #4ade9b
    .node_bg = rgba(18, 27, 46, 255), // #121b2e
    .node_header_text = rgba(16, 18, 24, 255),
    .edge_pipe = rgba(77, 141, 255, 255), // #4d8dff
    .edge_seq = rgba(61, 220, 151, 255), // #3ddc97
    .grid = rgba(34, 48, 73, 255),
    .status_idle = rgba(143, 163, 200, 255), // #8fa3c8
    .status_running = rgba(245, 184, 77, 255), // #f5b84d
    .status_success = rgba(61, 220, 151, 255), // #3ddc97
    .status_failed = rgba(255, 122, 118, 255), // #ff7a76
};

pub const light = Palette{
    .kind = .light,
    .bg = rgba(238, 241, 247, 255), // #eef1f7
    .panel = rgba(255, 255, 255, 255), // #ffffff
    .sunken = rgba(228, 233, 242, 255), // #e4e9f2
    .border = rgba(211, 219, 232, 255), // #d3dbe8
    .text = rgba(26, 35, 51, 255), // #1a2333
    .text_dim = rgba(90, 107, 133, 255), // #5a6b85
    .accent = rgba(47, 109, 246, 255), // #2f6df6
    .danger = rgba(220, 74, 82, 255), // #dc4a52
    .warn = rgba(185, 125, 16, 255), // #b97d10
    .success = rgba(30, 158, 106, 255), // #1e9e6a
    .node_bg = rgba(255, 255, 255, 255), // #ffffff
    .node_header_text = rgba(16, 18, 24, 255),
    .edge_pipe = rgba(47, 109, 246, 255), // #2f6df6
    .edge_seq = rgba(30, 158, 106, 255), // #1e9e6a
    .grid = rgba(211, 219, 232, 255),
    .status_idle = rgba(135, 149, 171, 255), // #8795ab
    .status_running = rgba(201, 138, 18, 255), // #c98a12
    .status_success = rgba(30, 158, 106, 255), // #1e9e6a
    .status_failed = rgba(220, 74, 82, 255), // #dc4a52
};

pub fn of(kind: Kind) Palette {
    return switch (kind) {
        .dark => dark,
        .light => light,
    };
}
