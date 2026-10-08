// GUID definitions used by the WebView2 shell shim and the native picker helper.
//
// Why this file exists (see build.zig): Zig 0.17's mingw sysroot keeps GUID definitions in
// source form (libsrc/*-uuid.c) and no longer ships a `uuid` library, but
// WebView2LoaderStatic.lib (built with MSVC) still carries the linker directive
// `/DEFAULTLIB:"uuid.lib"`, and pl_pick.c references the shell dialog GUIDs. This file is
// compiled into a static library named `uuid`, so the linker's search resolves that
// directive and the referenced GUIDs exist.
//
// Archive member semantics make these definitions safe: any GUID already provided by
// another archive is simply never pulled in from here, so no duplicate-symbol conflict is
// possible. Values come from the Windows SDK (shobjidl.h) and from WebView2.idl.

#include <guiddef.h>

const IID IID_IUnknown =
    { 0x00000000, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

// ── WebView2 handler interfaces (values from WebView2.idl) ─────────────────

const IID IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler =
    { 0x6c4819f3, 0xc9b7, 0x4260, { 0x81, 0x27, 0xC9, 0xF5, 0xBD, 0xE7, 0xF6, 0x8C } };

const IID IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler =
    { 0x4e8a3389, 0xc9d8, 0x4bd2, { 0xB6, 0xB5, 0x12, 0x4F, 0xEE, 0x6C, 0xC1, 0x4D } };

const IID IID_ICoreWebView2WebMessageReceivedEventHandler =
    { 0x57213f19, 0x00e6, 0x49fa, { 0x8E, 0x07, 0x89, 0x8E, 0xA0, 0x1E, 0xCB, 0xD2 } };

const IID IID_ICoreWebView2WebResourceRequestedEventHandler =
    { 0xab00b74c, 0x15f1, 0x4646, { 0x80, 0xE8, 0xE7, 0x63, 0x41, 0xD2, 0x5D, 0x71 } };

// ── Shell dialog GUIDs (values from the Windows SDK's shobjidl.h) ───────────

const CLSID CLSID_FileOpenDialog =
    { 0xDC1C5A9C, 0xE88A, 0x4DDE, { 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };

const IID IID_IFileOpenDialog =
    { 0xD57C7288, 0xD4AD, 0x4768, { 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };

const IID IID_IShellItem =
    { 0x43826D1E, 0xE718, 0x42EE, { 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };
