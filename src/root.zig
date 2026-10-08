//! Flow Pipelith core engine module entry point.
//!
//! Layers (bottom-up):
//!   value / yaml  ->  cdl (standard layer)  ->  graph (graph model)  ->  engine (execution layer)
//!                                                  |                        |
//!                                        platform / picker (adaptation)  rpc (service layer) -> main
//!   cmdline (the named quoting convention for one-line command editing) sits beside graph

pub const value = @import("value.zig");
pub const yaml = @import("yaml.zig");
pub const emit = @import("emit.zig");
pub const cdl = @import("cdl.zig");
pub const packs = @import("packs.zig");
pub const builtin = @import("builtin.zig");
pub const graph = @import("graph.zig");
pub const cmdline = @import("cmdline.zig");
pub const help = @import("help.zig");
pub const platform = @import("platform.zig");
pub const engine = @import("engine.zig");
pub const picker = @import("picker.zig");
pub const rpc = @import("rpc.zig");
pub const rpc_stdio = @import("rpc_stdio.zig");
pub const http = @import("http.zig");
pub const selftest = @import("selftest.zig");

test {
    @import("std").testing.refAllDecls(@This());
    // Integration tests that drive real processes. They live in their own file and
    // must be imported here explicitly, otherwise `zig build test` silently never
    // compiles them.
    _ = @import("engine_test.zig");
    _ = @import("http.zig");
}