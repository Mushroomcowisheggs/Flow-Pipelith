const std = @import("std");
const Io = std.Io;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Tool packs are NOT part of the build's output ──
    // Nothing about a tool is compiled into the program, and nothing is copied next to it either: a
    // fresh installation offers **zero** packs and loads **zero** tools. The packs authored in this
    // repository live in `assets/packs/` as source data; the user brings them in — by copying or
    // unpacking a pack directory into `<tool dir>/.pipelith/packs/`, or by naming a directory for
    // this run (`--packs-dir`, which is how the test harness uses the repository's packs).
    //
    // (`PACKS_DIR` below is therefore only the path the dev tooling and the harness point at.)

    // ── GUID definitions: a `libuuid.a` stand-in ─────────────────────────────
    // Zig 0.17's mingw sysroot keeps GUID definitions as source (libsrc/*-uuid.c) and ships
    // no `uuid` library, but WebView2LoaderStatic.lib (MSVC) carries the linker directive
    // `/DEFAULTLIB:"uuid.lib"` and `pl_pick.c` references the shell dialog GUIDs. This tiny
    // static library is staged as `libuuid.a`/`uuid.lib` so the linker's search resolves
    // that directive, and its members define exactly the GUIDs the project references.
    const uuid_defs = b.addLibrary(.{
        .linkage = .static,
        .name = "uuid",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    uuid_defs.root_module.link_libc = true;
    uuid_defs.root_module.addCSourceFile(.{
        .file = b.path("third_party/webview2/shim_include/uuid_defs.c"),
        .flags = &.{"-std=c11"},
    });
    const uuid_stage = b.addWriteFiles();
    _ = uuid_stage.addCopyFile(uuid_defs.getEmittedBin(), "libuuid.a");
    _ = uuid_stage.addCopyFile(uuid_defs.getEmittedBin(), "uuid.lib");
    const uuid_dir = uuid_stage.getDirectory();

    // ── Native GUI (Dear ImGui + SDL3) ───────────────────────────
    //
    // Rule 9: the GUI is a single-process native window — no web engine, no browser runtime, no
    // child process. It is a *module* of the `pipelith` executable (see below) rather than a second
    // program, so there is exactly one artifact to ship and no way for the two to drift apart.
    // `gui-spike` is the reduced program that validated the approach and is kept as a minimal
    // reproduction of the risky parts (CJK, IME, node drawing, renderer-side capture).
    const GuiDeps = struct {
        // IMGUI_IMPL_API defaults to IMGUI_API (no C linkage), which clashes with gui_shim.cpp
        // reaching the backends through a plain C ABI. IMGUI_USE_WCHAR32 gives 32-bit characters,
        // which CJK text needs.
        const cpp_flags = [_][]const u8{
            "-std=c++17",
            "-DIMGUI_IMPL_API=extern \"C\"",
            "-DIMGUI_USE_WCHAR32",
        };

        // `bld` rather than `b`: a nested parameter may not shadow the outer build() parameter.
        fn attach(bld: *std.Build, m: *std.Build.Module) void {
            m.addIncludePath(bld.path("third_party/sdl3/include"));
            m.addIncludePath(bld.path("third_party/imgui"));
            m.addIncludePath(bld.path("third_party/imgui/backends"));
            m.addIncludePath(bld.path("src/native"));
            m.addLibraryPath(bld.path("third_party/sdl3/lib"));
            // SDL3's mingw package names its import library `libSDL3.dll.a`; linkSystemLibrary("SDL3")
            // probes only SDL3.dll/SDL3.lib/libSDL3.a, so hand the archive over explicitly.
            m.addObjectFile(bld.path("third_party/sdl3/lib/libSDL3.dll.a"));
            m.link_libc = true;
            m.link_libcpp = true;

            // The GUI's own C ABI shim (the Zig side only ever sees gui_shim.h).
            m.addCSourceFile(.{ .file = bld.path("src/native/gui_shim.cpp"), .flags = &cpp_flags });
            for ([_][]const u8{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp" }) |f| {
                m.addCSourceFile(.{ .file = bld.path(bld.fmt("third_party/imgui/{s}", .{f})), .flags = &cpp_flags });
            }
            for ([_][]const u8{ "imgui_impl_sdl3.cpp", "imgui_impl_sdlrenderer3.cpp" }) |f| {
                m.addCSourceFile(.{ .file = bld.path(bld.fmt("third_party/imgui/backends/{s}", .{f})), .flags = &cpp_flags });
            }
        }
    };

    // SDL3.dll ships next to the executables (the arrangement WebView2Loader.dll used to have).
    const sdl_dll = b.addInstallFileWithDir(b.path("third_party/sdl3/bin/SDL3.dll"), .bin, "SDL3.dll");

    // Core engine module (shared by the tests and the executable). It imports no asset module: the
    // tool packs are external files (see above), so the engine has no compiled-in tool definition.
    const engine = b.addModule("pipelith", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The GUI module: the engine plus the ImGui/SDL3 toolchain, imported by `src/main.zig` as
    // `native_gui`. Built here so the executable below can depend on it.
    const native_gui = b.createModule(.{
        .root_source_file = b.path("src/native/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pipelith", .module = engine },
        },
    });
    GuiDeps.attach(b, native_gui);

    // ── Executable ────────────────────────────────────────────────
    //
    // One binary serves every mode, GUI included: `pipelith` with no arguments opens the native
    // window (rule 9). The GUI is a module of this executable rather than a second program, so there
    // is exactly one artifact to ship and no way for the two to drift apart.
    const exe = b.addExecutable(.{
        .name = "pipelith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pipelith", .module = engine },
                .{ .name = "native_gui", .module = native_gui },
            },
        }),
    });
    exe.step.dependOn(&sdl_dll.step);

    const is_windows = target.result.os.tag == .windows;

    b.installArtifact(exe);

    // ── Native file / folder picker (the user must never hand-type a path) ──
    //
    // `src/picker/pl_pick.c` is a small standalone executable rather than a C file compiled into
    // `pipelith`, for two reasons:
    //   1. the dialog is a blocking, user-driven operation; running it as a child process keeps the
    //      engine's address space and its pipe/handle discipline untouched;
    //   2. its exit codes are the whole interface (0 picked / 1 cancelled / 2 unavailable / 3 error),
    //      which makes "is a native picker available?" an answerable question instead of a guess.
    // See `src/picker.zig` for the contract and the caller.
    if (is_windows) {
        const pick = b.addExecutable(.{
            .name = "pl_pick",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        pick.root_module.addCSourceFile(.{
            .file = b.path("src/picker/pl_pick.c"),
            .flags = &.{"-std=c11"},
        });
        pick.root_module.link_libc = true;
        // COM (CoCreateInstance / CoTaskMemFree), the shell item API, and the dialog itself.
        for ([_][]const u8{ "ole32", "oleaut32", "shell32", "shlwapi", "user32", "uuid" }) |lib| {
            pick.root_module.linkSystemLibrary(lib, .{});
        }
        pick.root_module.addLibraryPath(uuid_dir);
        b.installArtifact(pick);
    }

    // ── Native GUI validation spike ──────────────────────────────
    //
    // Not part of the default build. The real GUI is the `native_gui` module above, linked into
    // `pipelith`; this reduced program is kept because it isolates the risky parts (CJK font
    // loading, IME, node drawing, renderer-side capture) in a few hundred lines, which makes a
    // regression in the ImGui/SDL3 integration far easier to localise than in the full app.
    {
        const spike = b.addExecutable(.{
            .name = "gui_spike",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/native/gui_spike.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        GuiDeps.attach(b, spike.root_module);
        spike.step.dependOn(&sdl_dll.step);
        const spike_step = b.step("gui-spike", "Build the native GUI validation spike (Dear ImGui + SDL3)");
        spike_step.dependOn(&b.addInstallArtifact(spike, .{}).step);
    }

    // ── Run ─────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Pass-through arguments such as `zig build run -- --builtins` (use addPassthruArgs since 0.17)
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Build and run Flow Pipelith");
    run_step.dependOn(&run_cmd.step);

    // ── Headless execution tool (end-to-end tests and command-line execution) ──
    const cli_exe = b.addExecutable(.{
        .name = "pipelith-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pipelith", .module = engine },
            },
        }),
    });
    b.installArtifact(cli_exe);

    // ── Tests ────────────────────────────────────────────────────
    // `zig build test -Dfilter=<keyword>` runs only the matching tests (very useful when debugging a hang)
    const filter = b.option([]const u8, "filter", "only run tests whose name contains this keyword");
    const test_step = b.step("test", "run all unit tests");
    const unit_tests = b.addTest(.{
        .root_module = engine,
        .filters = if (filter) |f| &.{f} else &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pipelith", .module = engine },
                .{ .name = "native_gui", .module = native_gui },
            },
        }),
    });
    main_tests.step.dependOn(&sdl_dll.step);
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Native GUI string table. Tested on its own module: i18n.zig depends on nothing but std, so
    // this does not need the ImGui/SDL3 toolchain just to check that every key is translated.
    const i18n_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native/i18n.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(i18n_tests).step);
    if (target.result.os.tag == .windows) {
        // The GUI module links SDL3 through its import library, so SDL3.dll must be findable at
        // process start for any binary that includes it (the tests never open a window).
        const sdl_dir_abs = b.fmt("{s}\\third_party\\sdl3\\bin", .{b.root.root_dir.path orelse "."});
        run_unit_tests.setEnvironmentVariable("PATH", sdl_dir_abs);
        run_main_tests.setEnvironmentVariable("PATH", sdl_dir_abs);
    }
}

/// Where the packs authored in this repository live. The build does **not** copy them anywhere —
/// they are source data the user (or the test harness) points the program at.
const PACKS_DIR = "assets/packs";

