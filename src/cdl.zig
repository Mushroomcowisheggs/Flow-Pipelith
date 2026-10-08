//! CDL standard layer: parsing, modeling, validation.
//!
//! CDL (Conduit Description Language) describes how a CLI tool is turned into a graphical node.
//! The full standard lives in `docs/CDL.md`. This module is responsible for:
//!   1. auto-detecting YAML / JSON and parsing it into a `Value` tree;
//!   2. normalizing the `Value` tree into a strongly typed `Doc` (camelCase field names, ready for
//!      direct RPC output);
//!   3. validating and producing diagnostics (errors block loading, warnings are informational).
//!
//! Memory strategy: `load()` uses the caller-provided arena and every string inside `Doc` points
//! into that arena or into the CDL source text; the source text must therefore outlive the `Doc`.

const std = @import("std");
const Value = @import("value.zig").Value;
const yaml = @import("yaml.zig");

pub const cdl_version = "0.1";

pub const Level = enum { @"error", warning, info };

pub const Issue = struct {
    level: Level,
    message: []const u8,
    path: []const u8 = "",
};

/// Where a loaded document came from. There is deliberately no `builtin`: tool definitions ship as
/// *packs* (see `packs.zig`) and exist only once the user installs one into the tool directory, so
/// every document the engine holds is either the user's own file or a project-local one.
pub const Source = enum { user, project, unknown };

pub const VarType = enum {
    file,
    directory,
    text,
    number,
    boolean,
    enumeration,

    pub fn parse(s: []const u8) ?VarType {
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "directory") or std.mem.eql(u8, s, "dir")) return .directory;
        if (std.mem.eql(u8, s, "text") or std.mem.eql(u8, s, "string")) return .text;
        if (std.mem.eql(u8, s, "number") or std.mem.eql(u8, s, "int") or std.mem.eql(u8, s, "float")) return .number;
        if (std.mem.eql(u8, s, "boolean") or std.mem.eql(u8, s, "bool")) return .boolean;
        if (std.mem.eql(u8, s, "enum")) return .enumeration;
        return null;
    }

    /// Name exposed to the frontend (`enum` is a Zig keyword, so `enumeration` is used internally).
    pub fn wire(self: VarType) []const u8 {
        return switch (self) {
            .file => "file",
            .directory => "directory",
            .text => "text",
            .number => "number",
            .boolean => "boolean",
            .enumeration => "enum",
        };
    }
};

pub const Option = struct {
    value: []const u8,
    label: []const u8,
};

pub const Validation = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    pattern: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Var = struct {
    name: []const u8,
    var_type: VarType,
    label: []const u8,
    required: bool = false,
    /// Default value (stored stringified; booleans/numbers are interpreted by the frontend by type).
    default: ?[]const u8 = null,
    filters: []const []const u8 = &.{},
    options: []const Option = &.{},
    placeholder: ?[]const u8 = null,
    multiline: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    /// file type only: true means "save as" semantics.
    save: bool = false,
    validation: ?Validation = null,
    description: ?[]const u8 = null,
};

pub const ArgTemplate = struct {
    /// Raw template, may contain `{name}` placeholders.
    value: []const u8 = "",
    /// Equivalent to `value: "{var}"`; mutually exclusive with value.
    var_name: ?[]const u8 = null,
    /// Keep this argument only when the given boolean variable is true.
    when: ?[]const u8 = null,
    /// List variable: every element expands into one entry.
    repeat: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
};

pub const StreamMode = enum {
    none,
    capture,
    pipe,
    discard,
    text,
    file_var,

    pub fn parse(s: []const u8) ?StreamMode {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "capture")) return .capture;
        if (std.mem.eql(u8, s, "pipe")) return .pipe;
        if (std.mem.eql(u8, s, "discard")) return .discard;
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.startsWith(u8, s, "file:")) return .file_var;
        return null;
    }

    pub fn wire(self: StreamMode) []const u8 {
        return switch (self) {
            .none => "none",
            .capture => "capture",
            .pipe => "pipe",
            .discard => "discard",
            .text => "text",
            .file_var => "file",
        };
    }
};

pub const StreamSpec = struct {
    mode: StreamMode = .capture,
    /// Variable name of the `file:{var}` form.
    var_name: ?[]const u8 = null,
    raw: []const u8 = "capture",
};

pub const Dependency = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    optional: bool = false,
};

pub const Permissions = struct {
    filesystem: bool = false,
    network: bool = false,
    process: bool = false,
};

pub const PipeSpec = struct {
    stdin: StreamSpec = .{ .mode = .none, .raw = "none" },
    stdout: StreamSpec = .{ .mode = .capture, .raw = "capture" },
    stderr: StreamSpec = .{ .mode = .capture, .raw = "capture" },
    encoding: []const u8 = "utf-8",
};

pub const VocabKind = enum {
    subcommand,
    option,
    note,

    pub fn parse(s: []const u8) ?VocabKind {
        if (std.mem.eql(u8, s, "subcommand")) return .subcommand;
        if (std.mem.eql(u8, s, "option")) return .option;
        if (std.mem.eql(u8, s, "note")) return .note;
        return null;
    }

    pub fn wire(self: VocabKind) []const u8 {
        return switch (self) {
            .subcommand => "subcommand",
            .option => "option",
            .note => "note",
        };
    }
};

/// One entry of a tool sheet (CDL `vocabulary`, v0.2): a pickable piece of a tool's command
/// surface. Picking inserts `tokens` into argv, one element per token.
///
/// **Value slot rule** (named, documented in `docs/CDL.md` — no runtime guessing): when `takes`
/// is set, the value goes where the author put the slot:
/// 1. the first `<...>` span inside the last token is replaced by the picked value
///    (`["--output=<file>"]` → `--output=photo.png`);
/// 2. else, with two or more tokens, the last token **is** the slot and is replaced whole
///    (`["-C", "DIRECTORY"]` → `-C`, `C:\pics`);
/// 3. else the value is appended as a new element (`["-c:v"]` → `-c:v`, `libx264`).
/// A cancelled picker leaves the slot exactly as the author wrote it, to be filled by hand.
pub const VocabEntry = struct {
    kind: VocabKind,
    tokens: []const []const u8 = &.{},
    label: []const u8 = "",
    description: ?[]const u8 = null,
    /// Value shape of the slot; null means the tokens are complete as-is.
    takes: ?VarType = null,
    /// Candidates for `takes: enum`.
    options: []const []const u8 = &.{},
    /// Entries that appear once this subcommand is part of the command.
    children: []const VocabEntry = &.{},
};

pub const Action = struct {
    name: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    /// Overrides the tool-level executable; `Doc.name` is used when absent.
    executable: ?[]const u8 = null,
    args: []const ArgTemplate = &.{},
    /// Variables private to this action (merged with inputs/outputs for form rendering).
    variables: []const Var = &.{},
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    stdin: StreamSpec = .{ .mode = .none, .raw = "none" },
    stdout: StreamSpec = .{ .mode = .capture, .raw = "capture" },
    stderr: StreamSpec = .{ .mode = .capture, .raw = "capture" },
    encoding: ?[]const u8 = null,
    timeout: ?u32 = null,
    retry: u32 = 0,
    confirm: bool = false,
    danger: bool = false,

    pub const EnvPair = struct { key: []const u8, value: []const u8 };

    /// The executable this action runs with.
    pub fn exe(self: Action, doc: *const Doc) []const u8 {
        return self.executable orelse doc.name;
    }

    /// All variables visible to this action (inputs + outputs + variables), in that order.
    pub fn allVars(self: Action, doc: *const Doc, alloc: std.mem.Allocator) error{OutOfMemory}![]const Var {
        var list: std.ArrayListUnmanaged(Var) = .empty;
        try list.appendSlice(alloc, doc.inputs);
        try list.appendSlice(alloc, doc.outputs);
        try list.appendSlice(alloc, self.variables);
        return list.items;
    }
};

pub const Doc = struct {
    name: []const u8,
    display_name: []const u8,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    doc_cdl_version: []const u8 = cdl_version,
    icon: ?[]const u8 = null,
    category: []const u8 = "other",
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{ "windows", "macos", "linux" },
    dependencies: []const Dependency = &.{},
    permissions: Permissions = .{},
    pipes: PipeSpec = .{},
    inputs: []const Var = &.{},
    outputs: []const Var = &.{},
    /// The tool sheet (v0.2): the tool's command surface for pick-and-assemble. This is what makes
    /// a tool usable without memorizing, looking up, or probing its CLI — `actions` are presets on
    /// top of it, never the capability boundary.
    vocabulary: []const VocabEntry = &.{},
    actions: []const Action = &.{},

    // provenance (filled in by the caller)
    source: Source = .unknown,
    path: ?[]const u8 = null,
    raw: []const u8 = "",

    pub fn findAction(self: *const Doc, name: []const u8) ?*const Action {
        for (self.actions) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    pub fn hasPlatform(self: *const Doc, plat: []const u8) bool {
        for (self.platforms) |p| {
            if (std.mem.eql(u8, p, plat)) return true;
        }
        return false;
    }
};

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
    doc: Doc,
    issues: []const Issue,
    format: Format,

    pub fn hasErrors(self: Loaded) bool {
        for (self.issues) |i| {
            if (i.level == .@"error") return true;
        }
        return false;
    }
};

pub const Format = enum { yaml, json };

/// Detect the format: a first non-whitespace character of `{` or `[` means JSON, otherwise YAML.
/// A leading UTF-8 BOM is skipped first (Windows editors often write one; treating it as content
/// would misdetect the file as YAML).
pub fn detectFormat(text: []const u8) Format {
    const body = stripBom(text);
    for (body) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[' => return .json,
            else => return .yaml,
        }
    }
    return .yaml;
}

/// Strip a leading UTF-8 BOM (EF BB BF).
pub fn stripBom(text: []const u8) []const u8 {
    if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) {
        return text[3..];
    }
    return text;
}

/// Parse and normalize one CDL text.
///
/// - `alloc`: arena allocator (owns everything inside `Doc`)
/// - `text`: the CDL source text (`Doc.raw` references it, so it must outlive `Doc`)
pub fn load(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}!LoadResult {
    const body = stripBom(text);
    const format = detectFormat(body);
    const parsed: Value = switch (format) {
        .json => switch (Value.parseJson(alloc, body)) {
            .ok => |v| v,
            .err => |e| return .{ .err = .{ .message = e.message, .line = e.line, .path = e.path } },
        },
        .yaml => switch (yaml.parse(alloc, body)) {
            .ok => |v| v,
            .err => |e| return .{ .err = .{ .message = e.message, .line = e.line, .path = e.path } },
        },
    };

    const root = parsed.asObject() orelse return .{ .err = .{ .message = "the top level of a CDL must be a mapping/object", .path = "$" } };

    var issues: std.ArrayListUnmanaged(Issue) = .empty;

    // duplicate keys: treated as an error directly (in JSON/YAML a repeated key is almost always a typo)
    for (root.dups.items) |dup| {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(alloc, "field `{s}` is defined more than once", .{dup}),
            .path = dup,
        });
    }

    var doc: Doc = .{
        .name = "",
        .display_name = "",
        .raw = text,
    };
    doc.doc_cdl_version = cdl_version;

    // ── Metadata ────────────────────────────────────────────────
    doc.name = try getStr(alloc, root, "name") orelse "";
    doc.display_name = try getStr(alloc, root, "display_name") orelse doc.name;
    doc.description = try getStr(alloc, root, "description");
    doc.version = try getStr(alloc, root, "version");
    if (try getStr(alloc, root, "cdl_version")) |cv| doc.doc_cdl_version = cv;
    doc.icon = try getStr(alloc, root, "icon");
    if (try getStr(alloc, root, "category")) |c| doc.category = c;
    doc.author = try getStr(alloc, root, "author");
    doc.license = try getStr(alloc, root, "license");
    doc.homepage = try getStr(alloc, root, "homepage");
    doc.tags = try getStrList(alloc, root, "tags", &issues);

    // ── Platforms ───────────────────────────────────────────────
    if (root.get("platforms")) |pv| {
        const list = try getStrList(alloc, root, "platforms", &issues);
        if (list.len > 0) {
            doc.platforms = list;
            for (list) |p| {
                if (!isKnownPlatform(p)) {
                    try issues.append(alloc, .{
                        .level = .warning,
                        .message = try std.fmt.allocPrint(alloc, "unknown platform `{s}` (available: windows/macos/linux)", .{p}),
                        .path = "platforms",
                    });
                }
            }
        }
        _ = pv;
    }

    // ── Dependencies ────────────────────────────────────────────
    if (root.get("dependencies")) |dv| {
        const arr = dv.asArray() orelse &.{};
        var deps: std.ArrayListUnmanaged(Dependency) = .empty;
        for (arr, 0..) |item, i| {
            const o = item.asObject() orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "every entry of dependencies must be a mapping",
                    .path = try std.fmt.allocPrint(alloc, "dependencies[{d}]", .{i}),
                });
                continue;
            };
            const dname = try getStr(alloc, o, "name") orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "a dependencies entry is missing name",
                    .path = try std.fmt.allocPrint(alloc, "dependencies[{d}]", .{i}),
                });
                continue;
            };
            try deps.append(alloc, .{
                .name = dname,
                .version = try getStr(alloc, o, "version"),
                .optional = (try getBool(alloc, o, "optional")) orelse false,
            });
        }
        doc.dependencies = deps.items;
    }

    // ── Permissions ─────────────────────────────────────────────
    for (try getStrList(alloc, root, "permissions", &issues)) |p| {
        if (std.mem.eql(u8, p, "filesystem")) {
            doc.permissions.filesystem = true;
        } else if (std.mem.eql(u8, p, "network")) {
            doc.permissions.network = true;
        } else if (std.mem.eql(u8, p, "process")) {
            doc.permissions.process = true;
        } else {
            try issues.append(alloc, .{
                .level = .warning,
                .message = try std.fmt.allocPrint(alloc, "unknown permission `{s}` (available: filesystem/network/process)", .{p}),
                .path = "permissions",
            });
        }
    }

    // ── Pipes ───────────────────────────────────────────────────
    if (root.get("pipes")) |pipes_v| {
        if (pipes_v.asObject()) |po| {
            doc.pipes.stdin = try parseStream(alloc, po, "stdin", "none", &issues);
            doc.pipes.stdout = try parseStream(alloc, po, "stdout", "text", &issues);
            doc.pipes.stderr = try parseStream(alloc, po, "stderr", "text", &issues);
            if (try getStr(alloc, po, "encoding")) |enc| doc.pipes.encoding = enc;
        } else {
            try issues.append(alloc, .{ .level = .@"error", .message = "pipes must be a mapping", .path = "pipes" });
        }
    }

    // ── Inputs / outputs ────────────────────────────────────────
    doc.inputs = try parseVars(alloc, root, "inputs", null, &issues);
    doc.outputs = try parseVars(alloc, root, "outputs", true, &issues);

    // ── Actions ─────────────────────────────────────────────────
    doc.actions = try parseActions(alloc, root, &issues);
    doc.vocabulary = try parseVocabulary(alloc, root, &issues);

    // ── Validation ──────────────────────────────────────────────
    try validate(alloc, &doc, &issues);

    return .{ .ok = .{ .doc = doc, .issues = issues.items, .format = format } };
}

fn isKnownPlatform(p: []const u8) bool {
    return std.mem.eql(u8, p, "windows") or std.mem.eql(u8, p, "macos") or
        std.mem.eql(u8, p, "linux") or std.mem.eql(u8, p, "freebsd");
}

fn getStr(alloc: std.mem.Allocator, o: *Value.Object, key: []const u8) error{OutOfMemory}!?[]const u8 {
    const v = o.get(key) orelse return null;
    return v.asStringCoerce(alloc);
}

fn getBool(alloc: std.mem.Allocator, o: *Value.Object, key: []const u8) error{OutOfMemory}!?bool {
    _ = alloc;
    const v = o.get(key) orelse return null;
    if (v.asBool()) |b| return b;
    if (v.asString()) |s| {
        if (std.mem.eql(u8, s, "true")) return true;
        if (std.mem.eql(u8, s, "false")) return false;
    }
    return null;
}

fn getNumber(alloc: std.mem.Allocator, o: *Value.Object, key: []const u8) error{OutOfMemory}!?f64 {
    _ = alloc;
    const v = o.get(key) orelse return null;
    return v.asFloat();
}

fn getStrList(
    alloc: std.mem.Allocator,
    o: *Value.Object,
    key: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}![]const []const u8 {
    const v = o.get(key) orelse return &.{};
    const arr = v.asArray() orelse {
        if (v.asString()) |s| {
            // tolerate the single-scalar spelling: `platforms: windows`
            const buf = try alloc.alloc([]const u8, 1);
            buf[0] = s;
            return buf;
        }
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(alloc, "`{s}` must be a list", .{key}),
            .path = key,
        });
        return &.{};
    };
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (arr, 0..) |item, i| {
        if (try item.asStringCoerce(alloc)) |s| {
            try list.append(alloc, s);
        } else {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "entry {d} of `{s}` is not a string", .{ i, key }),
                .path = key,
            });
        }
    }
    return list.items;
}

fn parseStream(
    alloc: std.mem.Allocator,
    o: *Value.Object,
    key: []const u8,
    default_raw: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}!StreamSpec {
    const raw = (try getStr(alloc, o, key)) orelse default_raw;
    if (std.mem.startsWith(u8, raw, "file:")) {
        // both `file:{name}` and `file:name` spellings are allowed; take the inner variable name (strip the braces)
        var var_name = raw["file:".len..];
        if (var_name.len >= 2 and var_name[0] == '{' and var_name[var_name.len - 1] == '}') {
            var_name = var_name[1 .. var_name.len - 1];
        }
        if (var_name.len == 0) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "`{s}: file:` must be followed by a variable name", .{key}),
                .path = key,
            });
            return .{ .mode = .capture, .raw = raw };
        }
        return .{ .mode = .file_var, .var_name = var_name, .raw = raw };
    }
    const mode = StreamMode.parse(raw) orelse {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(
                alloc,
                "invalid value for `{s}`: `{s}` (available: none/capture/pipe/discard/text/file:<variable>)",
                .{ key, raw },
            ),
            .path = key,
        });
        return .{ .mode = .capture, .raw = raw };
    };
    return .{ .mode = mode, .raw = raw };
}

/// Parse a variable list. When `force_save` is true (outputs), save defaults to true.
fn parseVars(
    alloc: std.mem.Allocator,
    root: *Value.Object,
    key: []const u8,
    force_save: ?bool,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}![]const Var {
    const v = root.get(key) orelse return &.{};
    const arr = v.asArray() orelse {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(alloc, "`{s}` must be a list", .{key}),
            .path = key,
        });
        return &.{};
    };
    var list: std.ArrayListUnmanaged(Var) = .empty;
    for (arr, 0..) |item, i| {
        const path = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ key, i });
        const o = item.asObject() orelse {
            try issues.append(alloc, .{ .level = .@"error", .message = "a variable must be a mapping", .path = path });
            continue;
        };
        if (try parseVar(alloc, o, path, force_save, issues)) |var_| {
            try list.append(alloc, var_);
        }
    }
    return list.items;
}

fn parseVar(
    alloc: std.mem.Allocator,
    o: *Value.Object,
    path: []const u8,
    force_save: ?bool,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}!?Var {
    const name = (try getStr(alloc, o, "name")) orelse "";
    if (name.len == 0) {
        try issues.append(alloc, .{ .level = .@"error", .message = "variable is missing name", .path = path });
        return null;
    }
    const type_str = (try getStr(alloc, o, "type")) orelse "text";
    const vt = VarType.parse(type_str) orelse {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(
                alloc,
                "invalid type for variable `{s}`: `{s}` (available: file/directory/text/number/boolean/enum)",
                .{ name, type_str },
            ),
            .path = path,
        });
        return null;
    };

    var var_: Var = .{
        .name = name,
        .var_type = vt,
        .label = (try getStr(alloc, o, "label")) orelse name,
    };

    var_.required = (try getBool(alloc, o, "required")) orelse false;
    var_.filters = try getStrList(alloc, o, "filters", issues);
    var_.placeholder = try getStr(alloc, o, "placeholder");
    var_.multiline = (try getBool(alloc, o, "multiline")) orelse false;
    var_.min = try getNumber(alloc, o, "min");
    var_.max = try getNumber(alloc, o, "max");
    var_.step = try getNumber(alloc, o, "step");
    var_.description = try getStr(alloc, o, "description");
    if (force_save) |fs| var_.save = fs;
    if (try getBool(alloc, o, "save")) |s| var_.save = s;

    // default accepts any scalar and is stringified uniformly
    if (o.get("default")) |d| {
        if (d != .null) {
            var_.default = try d.asStringCoerce(alloc);
        }
    }

    // enum options
    if (o.get("options")) |ov| {
        const opts_arr = ov.asArray() orelse &.{};
        var opts: std.ArrayListUnmanaged(Option) = .empty;
        for (opts_arr, 0..) |item, i| {
            const opath = try std.fmt.allocPrint(alloc, "{s}.options[{d}]", .{ path, i });
            if (item.asString()) |s| {
                // shorthand: `- libx264`
                try opts.append(alloc, .{ .value = s, .label = s });
                continue;
            }
            const oo = item.asObject() orelse {
                try issues.append(alloc, .{ .level = .@"error", .message = "an options entry must be a mapping or a string", .path = opath });
                continue;
            };
            const ov_val = (try getStr(alloc, oo, "value")) orelse {
                try issues.append(alloc, .{ .level = .@"error", .message = "an options entry is missing value", .path = opath });
                continue;
            };
            try opts.append(alloc, .{
                .value = ov_val,
                .label = (try getStr(alloc, oo, "label")) orelse ov_val,
            });
        }
        var_.options = opts.items;
    }

    // validation object
    if (o.get("validation")) |vv| {
        if (vv.asObject()) |vo| {
            var val: Validation = .{};
            val.min = try getNumber(alloc, vo, "min");
            val.max = try getNumber(alloc, vo, "max");
            val.pattern = try getStr(alloc, vo, "pattern");
            val.message = try getStr(alloc, vo, "message");
            var_.validation = val;
        } else {
            try issues.append(alloc, .{ .level = .warning, .message = "validation must be a mapping", .path = path });
        }
    }

    return var_;
}

fn parseActions(
    alloc: std.mem.Allocator,
    root: *Value.Object,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}![]const Action {
    const v = root.get("actions") orelse return &.{};
    const arr = v.asArray() orelse {
        try issues.append(alloc, .{ .level = .@"error", .message = "`actions` must be a list", .path = "actions" });
        return &.{};
    };
    var list: std.ArrayListUnmanaged(Action) = .empty;
    for (arr, 0..) |item, i| {
        const path = try std.fmt.allocPrint(alloc, "actions[{d}]", .{i});
        const o = item.asObject() orelse {
            try issues.append(alloc, .{ .level = .@"error", .message = "an action must be a mapping", .path = path });
            continue;
        };
        const name = (try getStr(alloc, o, "name")) orelse "";
        if (name.len == 0) {
            try issues.append(alloc, .{ .level = .@"error", .message = "action is missing name", .path = path });
            continue;
        }

        var act: Action = .{
            .name = name,
            .label = (try getStr(alloc, o, "label")) orelse name,
        };
        act.description = try getStr(alloc, o, "description");
        act.icon = try getStr(alloc, o, "icon");
        act.executable = try getStr(alloc, o, "executable");
        act.cwd = try getStr(alloc, o, "cwd");
        act.encoding = try getStr(alloc, o, "encoding");
        if (try getNumber(alloc, o, "timeout")) |t| {
            if (t > 0) act.timeout = @intFromFloat(t);
        }
        if (try getNumber(alloc, o, "retry")) |r| {
            if (r > 0) act.retry = @intFromFloat(r);
        }
        act.confirm = (try getBool(alloc, o, "confirm")) orelse false;
        act.danger = (try getBool(alloc, o, "danger")) orelse false;

        // env
        if (o.get("env")) |ev| {
            if (ev.asObject()) |eo| {
                var pairs: std.ArrayListUnmanaged(Action.EnvPair) = .empty;
                for (0..eo.count()) |k| {
                    const e = eo.at(k);
                    const val = try e.value.asStringCoerce(alloc) orelse "";
                    try pairs.append(alloc, .{ .key = e.key, .value = val });
                }
                act.env = pairs.items;
            } else {
                try issues.append(alloc, .{
                    .level = .warning,
                    .message = "env must be a mapping",
                    .path = try std.fmt.allocPrint(alloc, "{s}.env", .{path}),
                });
            }
        }

        // args (required field, an empty array is allowed)
        if (o.get("args")) |av| {
            const args_arr = av.asArray() orelse {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "`args` must be a list",
                    .path = try std.fmt.allocPrint(alloc, "{s}.args", .{path}),
                });
                break;
            };
            var args: std.ArrayListUnmanaged(ArgTemplate) = .empty;
            for (args_arr, 0..) |ai, j| {
                const apath = try std.fmt.allocPrint(alloc, "{s}.args[{d}]", .{ path, j });
                if (ai.asString()) |s| {
                    // shorthand: `- "-i"` or `- "{input}"`
                    try args.append(alloc, .{ .value = s });
                    continue;
                }
                const ao = ai.asObject() orelse {
                    try issues.append(alloc, .{ .level = .@"error", .message = "an args entry must be a mapping or a string", .path = apath });
                    continue;
                };
                var t: ArgTemplate = .{};
                t.value = (try getStr(alloc, ao, "value")) orelse "";
                t.var_name = try getStr(alloc, ao, "var");
                t.when = try getStr(alloc, ao, "when");
                t.repeat = try getStr(alloc, ao, "repeat");
                t.prefix = try getStr(alloc, ao, "prefix");
                if (t.value.len == 0 and t.var_name == null and t.repeat == null) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = "an args entry must provide one of value / var / repeat",
                        .path = apath,
                    });
                    continue;
                }
                try args.append(alloc, t);
            }
            act.args = args.items;
        } else {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "action `{s}` is missing the args field", .{name}),
                .path = path,
            });
        }

        act.variables = try parseVars(alloc, o, "variables", null, issues);

        // streams
        act.stdin = try parseStream(alloc, o, "stdin", "none", issues);
        act.stdout = try parseStream(alloc, o, "stdout", "capture", issues);
        act.stderr = try parseStream(alloc, o, "stderr", "capture", issues);

        _ = &act;
        try list.append(alloc, act);
    }
    return list.items;
}

fn parseVocabulary(
    alloc: std.mem.Allocator,
    root: *Value.Object,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}![]const VocabEntry {
    const v = root.get("vocabulary") orelse return &.{};
    const arr = v.asArray() orelse {
        try issues.append(alloc, .{ .level = .@"error", .message = "`vocabulary` must be a list", .path = "vocabulary" });
        return &.{};
    };
    return parseVocabList(alloc, arr, "vocabulary", issues);
}

fn parseVocabList(
    alloc: std.mem.Allocator,
    arr: []const Value,
    path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}![]const VocabEntry {
    var list: std.ArrayListUnmanaged(VocabEntry) = .empty;
    for (arr, 0..) |item, i| {
        const epath = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ path, i });
        const o = item.asObject() orelse {
            try issues.append(alloc, .{ .level = .@"error", .message = "a vocabulary entry must be a mapping", .path = epath });
            continue;
        };
        if (try parseVocabEntry(alloc, o, epath, issues)) |entry| {
            try list.append(alloc, entry);
        }
    }
    return list.items;
}

fn parseVocabEntry(
    alloc: std.mem.Allocator,
    o: *Value.Object,
    path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}!?VocabEntry {
    const kind_str = (try getStr(alloc, o, "kind")) orelse "";
    const kind = VocabKind.parse(kind_str) orelse {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = try std.fmt.allocPrint(
                alloc,
                "invalid or missing kind for a vocabulary entry: `{s}` (available: subcommand/option/note)",
                .{kind_str},
            ),
            .path = path,
        });
        return null;
    };

    var entry: VocabEntry = .{ .kind = kind };

    // tokens: one string or a list of strings; every element becomes one argv element on pick.
    if (o.get("tokens")) |tv| {
        if (tv.asString()) |s| {
            const one = try alloc.alloc([]const u8, 1);
            one[0] = s;
            entry.tokens = one;
        } else if (tv.asArray()) |tarr| {
            var toks: std.ArrayListUnmanaged([]const u8) = .empty;
            for (tarr, 0..) |t, ti| {
                if (t.asString()) |s| {
                    try toks.append(alloc, s);
                    continue;
                }
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "tokens must be strings (entry token {d} is not)", .{ti}),
                    .path = try std.fmt.allocPrint(alloc, "{s}.tokens", .{path}),
                });
            }
            entry.tokens = toks.items;
        } else {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = "`tokens` must be a string or a list of strings",
                .path = try std.fmt.allocPrint(alloc, "{s}.tokens", .{path}),
            });
        }
    }
    if (kind == .note) {
        if (entry.tokens.len > 0) {
            try issues.append(alloc, .{
                .level = .warning,
                .message = "a note inserts nothing; its tokens are ignored",
                .path = try std.fmt.allocPrint(alloc, "{s}.tokens", .{path}),
            });
            entry.tokens = &.{};
        }
    } else if (entry.tokens.len == 0) {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = "a vocabulary entry is missing tokens",
            .path = try std.fmt.allocPrint(alloc, "{s}.tokens", .{path}),
        });
        return null;
    }

    // label: what the picker shows. Falls back to the tokens for subcommand/option; a note has no
    // tokens to fall back to, so its label is required.
    entry.label = (try getStr(alloc, o, "label")) orelse "";
    if (entry.label.len == 0) {
        if (kind == .note) {
            try issues.append(alloc, .{ .level = .@"error", .message = "a note entry is missing label", .path = path });
            return null;
        }
        entry.label = try std.mem.join(alloc, " ", entry.tokens);
    }
    entry.description = try getStr(alloc, o, "description");

    // takes: the value shape of the slot (file/directory/text/number/enum).
    if (try getStr(alloc, o, "takes")) |ts| {
        const vt = VarType.parse(ts);
        if (vt == null or vt.? == .boolean) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(
                    alloc,
                    "invalid takes for a vocabulary entry: `{s}` (available: file/directory/text/number/enum)",
                    .{ts},
                ),
                .path = try std.fmt.allocPrint(alloc, "{s}.takes", .{path}),
            });
        } else if (kind == .note) {
            try issues.append(alloc, .{
                .level = .warning,
                .message = "a note takes no value; its takes field is ignored",
                .path = try std.fmt.allocPrint(alloc, "{s}.takes", .{path}),
            });
        } else {
            entry.takes = vt;
        }
    }

    // options: candidates for `takes: enum`.
    if (o.get("options")) |ov| {
        if (ov.asArray()) |oarr| {
            var opts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (oarr) |item| {
                if (item.asString()) |s| {
                    try opts.append(alloc, s);
                    continue;
                }
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = "vocabulary options must be strings",
                    .path = try std.fmt.allocPrint(alloc, "{s}.options", .{path}),
                });
            }
            if (entry.takes == .enumeration) {
                entry.options = opts.items;
            } else if (opts.items.len > 0) {
                try issues.append(alloc, .{
                    .level = .warning,
                    .message = "options are only used by an entry with `takes: enum`; they are ignored",
                    .path = try std.fmt.allocPrint(alloc, "{s}.options", .{path}),
                });
            }
        } else {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = "`options` must be a list of strings",
                .path = try std.fmt.allocPrint(alloc, "{s}.options", .{path}),
            });
        }
    }
    if (entry.takes == .enumeration and entry.options.len == 0) {
        try issues.append(alloc, .{
            .level = .@"error",
            .message = "a vocabulary entry with `takes: enum` is missing options",
            .path = try std.fmt.allocPrint(alloc, "{s}.options", .{path}),
        });
    }

    // children: further entries under a subcommand.
    if (o.get("children")) |cv| {
        const carr = cv.asArray() orelse {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = "`children` must be a list",
                .path = try std.fmt.allocPrint(alloc, "{s}.children", .{path}),
            });
            return entry;
        };
        if (kind != .subcommand) {
            try issues.append(alloc, .{
                .level = .warning,
                .message = "children are only meaningful on a subcommand; they are ignored",
                .path = try std.fmt.allocPrint(alloc, "{s}.children", .{path}),
            });
            return entry;
        }
        entry.children = try parseVocabList(alloc, carr, try std.fmt.allocPrint(alloc, "{s}.children", .{path}), issues);
    }

    return entry;
}

/// Validation rules are described in section 3 of `docs/CDL.md`.
fn validate(
    alloc: std.mem.Allocator,
    doc: *Doc,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}!void {
    if (doc.name.len == 0) {
        try issues.append(alloc, .{ .level = .@"error", .message = "missing required field name", .path = "name" });
    }
    if (doc.display_name.len == 0) {
        try issues.append(alloc, .{ .level = .@"error", .message = "missing required field display_name", .path = "display_name" });
    }
    // A tool sheet alone describes a usable tool (free commands assembled from `vocabulary`);
    // actions are presets on top of it, so neither section is required when the other exists.
    if (doc.actions.len == 0 and doc.vocabulary.len == 0) {
        try issues.append(alloc, .{ .level = .@"error", .message = "at least one action or vocabulary entry is required", .path = "actions" });
    }

    // unique action names + unique variable names + placeholder reference integrity
    for (doc.actions, 0..) |*act, i| {
        const apath = try std.fmt.allocPrint(alloc, "actions[{d}]", .{i});
        for (doc.actions[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, act.name)) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "duplicate action name `{s}`", .{act.name}),
                    .path = try std.fmt.allocPrint(alloc, "{s}.name", .{apath}),
                });
            }
        }
        if (act.label.len == 0) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "action `{s}` is missing label", .{act.name}),
                .path = try std.fmt.allocPrint(alloc, "{s}.label", .{apath}),
            });
        }

        const vars = try act.allVars(doc, alloc);
        for (vars, 0..) |var_, vi| {
            for (vars[0..vi]) |prev| {
                if (std.mem.eql(u8, prev.name, var_.name)) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = try std.fmt.allocPrint(alloc, "action `{s}` has a duplicate variable name `{s}`", .{ act.name, var_.name }),
                        .path = try std.fmt.allocPrint(alloc, "{s}.variables", .{apath}),
                    });
                }
            }
            if (var_.var_type == .enumeration) {
                if (var_.options.len == 0) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = try std.fmt.allocPrint(alloc, "enum variable `{s}` is missing options", .{var_.name}),
                        .path = try std.fmt.allocPrint(alloc, "{s}.variables", .{apath}),
                    });
                } else if (var_.default) |d| {
                    var found = false;
                    for (var_.options) |opt| {
                        if (std.mem.eql(u8, opt.value, d)) found = true;
                    }
                    if (!found) {
                        try issues.append(alloc, .{
                            .level = .@"error",
                            .message = try std.fmt.allocPrint(
                                alloc,
                                "enum variable `{s}` has a default `{s}` that is not among its options",
                                .{ var_.name, d },
                            ),
                            .path = try std.fmt.allocPrint(alloc, "{s}.variables", .{apath}),
                        });
                    }
                }
            }
            if (var_.required and var_.default != null and var_.default.?.len == 0) {
                try issues.append(alloc, .{
                    .level = .warning,
                    .message = try std.fmt.allocPrint(alloc, "required variable `{s}` has an empty default value", .{var_.name}),
                    .path = try std.fmt.allocPrint(alloc, "{s}.variables", .{apath}),
                });
            }
        }

        // placeholder reference integrity
        for (act.args, 0..) |arg, ai| {
            const arg_path = try std.fmt.allocPrint(alloc, "{s}.args[{d}]", .{ apath, ai });
            if (arg.when) |w| {
                if (!varExists(vars, w)) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = try std.fmt.allocPrint(alloc, "when of an args entry references a non-existent variable `{s}`", .{w}),
                        .path = arg_path,
                    });
                }
            }
            if (arg.var_name) |vn| {
                if (!varExists(vars, vn)) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = try std.fmt.allocPrint(alloc, "var of an args entry references a non-existent variable `{s}`", .{vn}),
                        .path = arg_path,
                    });
                }
            }
            if (arg.repeat) |rn| {
                if (!varExists(vars, rn)) {
                    try issues.append(alloc, .{
                        .level = .@"error",
                        .message = try std.fmt.allocPrint(alloc, "repeat of an args entry references a non-existent variable `{s}`", .{rn}),
                        .path = arg_path,
                    });
                }
            }
            if (arg.value.len > 0) {
                try checkPlaceholders(alloc, arg.value, vars, arg_path, issues);
            }
        }

        // placeholders inside cwd are validated the same way
        if (act.cwd) |cwd| {
            if (cwd.len > 0) {
                try checkPlaceholders(alloc, cwd, vars, try std.fmt.allocPrint(alloc, "{s}.cwd", .{apath}), issues);
            }
        }
    }

    // outputs default-value reminder
    for (doc.outputs) |out| {
        if (out.save and out.default == null) {
            try issues.append(alloc, .{
                .level = .warning,
                .message = try std.fmt.allocPrint(alloc, "output `{s}` is marked save but has no default value", .{out.name}),
                .path = "outputs",
            });
        }
    }
}

fn varExists(vars: []const Var, name: []const u8) bool {
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, name)) return true;
    }
    return false;
}

/// Scan for `{name}` / `{name_dir}` / `{name_base}` / `{name_stem}` / `{__cwd}`.
fn checkPlaceholders(
    alloc: std.mem.Allocator,
    template: []const u8,
    vars: []const Var,
    path: []const u8,
    issues: *std.ArrayListUnmanaged(Issue),
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '{') {
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i, '}') orelse {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "unterminated placeholder: `{s}`", .{template[i..]}),
                .path = path,
            });
            return;
        };
        const inner = template[i + 1 .. close];
        if (inner.len == 0) {
            try issues.append(alloc, .{ .level = .@"error", .message = "empty placeholder `{}`", .path = path });
        } else if (std.mem.eql(u8, inner, "__cwd")) {
            // built into the engine, always legal
        } else if (stripSuffix(inner, "_dir")) |base| {
            if (!varExists(vars, base)) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "placeholder `{{{s}}}` references a non-existent variable `{s}`", .{ inner, base }),
                    .path = path,
                });
            }
        } else if (stripSuffix(inner, "_base")) |base| {
            if (!varExists(vars, base)) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "placeholder `{{{s}}}` references a non-existent variable `{s}`", .{ inner, base }),
                    .path = path,
                });
            }
        } else if (stripSuffix(inner, "_stem")) |base| {
            if (!varExists(vars, base)) {
                try issues.append(alloc, .{
                    .level = .@"error",
                    .message = try std.fmt.allocPrint(alloc, "placeholder `{{{s}}}` references a non-existent variable `{s}`", .{ inner, base }),
                    .path = path,
                });
            }
        } else if (!varExists(vars, inner)) {
            try issues.append(alloc, .{
                .level = .@"error",
                .message = try std.fmt.allocPrint(alloc, "placeholder `{{{s}}}` references a non-existent variable", .{inner}),
                .path = path,
            });
        }
        i = close + 1;
    }
}

fn stripSuffix(s: []const u8, suffix: []const u8) ?[]const u8 {
    if (s.len > suffix.len and std.mem.endsWith(u8, s, suffix)) {
        return s[0 .. s.len - suffix.len];
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

const sample_yaml =
    \\name: ffmpeg
    \\display_name: FFmpeg
    \\description: Audio/video processing tool
    \\version: "6.0"
    \\category: media
    \\tags: [video, audio]
    \\platforms: [windows, macos, linux]
    \\pipes:
    \\  stdin: none
    \\  stdout: text
    \\  stderr: text
    \\permissions: [filesystem, process]
    \\inputs:
    \\  - name: input
    \\    type: file
    \\    label: Input file
    \\    filters: ["*.mp4", "*.mkv"]
    \\    required: true
    \\outputs:
    \\  - name: output
    \\    type: file
    \\    label: Output file
    \\    default: output.mp4
    \\actions:
    \\  - name: convert
    \\    label: Convert format
    \\    args:
    \\      - value: "-i"
    \\      - value: "{input}"
    \\      - value: "-c:v"
    \\      - value: "{codec}"
    \\      - value: "{output}"
    \\    variables:
    \\      - name: codec
    \\        type: enum
    \\        label: Video codec
    \\        default: libx264
    \\        options:
    \\          - value: libx264
    \\            label: H.264
    \\          - value: libx265
    \\            label: H.265
    \\    timeout: 600
;

test "cdl: parse a YAML sample and normalize it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try load(a, sample_yaml);
    try testing.expect(r == .ok);
    const loaded = r.ok;
    if (loaded.hasErrors()) {
        for (loaded.issues) |i| {
            std.debug.print("[{t}] {s} @ {s}\n", .{ i.level, i.message, i.path });
        }
    }
    try testing.expect(!loaded.hasErrors());
    try testing.expectEqual(Format.yaml, loaded.format);

    const doc = &loaded.doc;
    try testing.expectEqualStrings("ffmpeg", doc.name);
    try testing.expectEqualStrings("FFmpeg", doc.display_name);
    try testing.expectEqualStrings("media", doc.category);
    try testing.expectEqual(@as(usize, 2), doc.tags.len);
    try testing.expectEqualStrings("video", doc.tags[0]);
    try testing.expectEqual(@as(usize, 3), doc.platforms.len);
    try testing.expect(doc.permissions.filesystem);
    try testing.expect(doc.permissions.process);
    try testing.expect(!doc.permissions.network);
    try testing.expectEqual(StreamMode.none, doc.pipes.stdin.mode);
    // when a tool-level pipe does not declare stderr, its default is text (the tool-level pipe
    // capability description), unlike the action-level stderr default of capture.
    try testing.expectEqual(StreamMode.text, doc.pipes.stderr.mode);

    try testing.expectEqual(@as(usize, 1), doc.inputs.len);
    try testing.expectEqual(VarType.file, doc.inputs[0].var_type);
    try testing.expect(doc.inputs[0].required);
    try testing.expectEqual(@as(usize, 2), doc.inputs[0].filters.len);
    try testing.expectEqual(@as(usize, 1), doc.outputs.len);
    try testing.expect(doc.outputs[0].save);
    try testing.expectEqualStrings("output.mp4", doc.outputs[0].default.?);

    try testing.expectEqual(@as(usize, 1), doc.actions.len);
    const act = doc.findAction("convert").?;
    try testing.expectEqualStrings("Convert format", act.label);
    try testing.expectEqualStrings("ffmpeg", act.exe(doc));
    try testing.expectEqual(@as(usize, 5), act.args.len);
    try testing.expectEqualStrings("{input}", act.args[1].value);
    try testing.expectEqual(@as(u32, 600), act.timeout.?);
    try testing.expectEqual(@as(usize, 1), act.variables.len);
    try testing.expectEqual(VarType.enumeration, act.variables[0].var_type);
    try testing.expectEqualStrings("enum", act.variables[0].var_type.wire());
    try testing.expectEqual(@as(usize, 2), act.variables[0].options.len);
    try testing.expectEqualStrings("H.264", act.variables[0].options[0].label);

    // merged variables: inputs + outputs + variables
    const all = try act.allVars(doc, a);
    try testing.expectEqual(@as(usize, 3), all.len);
}

test "cdl: parse the JSON format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const json_text =
        \\{"name":"gcc","display_name":"GCC","actions":[
        \\  {"name":"version","label":"Show version","args":[{"value":"--version"}]}
        \\]}
    ;
    const r = try load(a, json_text);
    try testing.expect(r == .ok);
    try testing.expectEqual(Format.json, r.ok.format);
    try testing.expect(!r.ok.hasErrors());
    try testing.expectEqualStrings("gcc", r.ok.doc.name);
    try testing.expectEqual(@as(usize, 1), r.ok.doc.actions.len);
}

test "cdl: missing required fields are errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try load(a, "actions: []\n");
    try testing.expect(r == .ok);
    try testing.expect(r.ok.hasErrors());
    var saw_name = false;
    var saw_display = false;
    var saw_actions = false;
    for (r.ok.issues) |i| {
        if (i.level != .@"error") continue;
        if (std.mem.indexOf(u8, i.message, "name") != null) saw_name = true;
        if (std.mem.indexOf(u8, i.message, "display_name") != null) saw_display = true;
        if (std.mem.indexOf(u8, i.message, "action") != null) saw_actions = true;
    }
    try testing.expect(saw_name and saw_display and saw_actions);
}

test "cdl: vocabulary parses kinds, tokens, slot takes and children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\name: git
        \\display_name: Git
        \\vocabulary:
        \\  - kind: subcommand
        \\    tokens: ["clone"]
        \\    label: Clone
        \\    description: Clone a repository
        \\    children:
        \\      - kind: option
        \\        tokens: ["--depth", "<n>"]
        \\        takes: number
        \\  - kind: option
        \\    tokens: ["-C", "DIRECTORY"]
        \\    takes: directory
        \\  - kind: option
        \\    tokens: ["--output=<file>"]
        \\    takes: file
        \\  - kind: option
        \\    tokens: ["-c:v"]
        \\    takes: enum
        \\    options: [libx264, libx265]
        \\  - kind: note
        \\    label: Reminder
        \\    description: the output file goes last
    ;
    const r = try load(a, src);
    try testing.expect(r == .ok);
    try testing.expect(!r.ok.hasErrors());
    const v = r.ok.doc.vocabulary;
    try testing.expectEqual(@as(usize, 5), v.len);

    try testing.expectEqual(VocabKind.subcommand, v[0].kind);
    try testing.expectEqualStrings("Clone", v[0].label);
    try testing.expectEqual(@as(usize, 1), v[0].tokens.len);
    try testing.expectEqual(@as(usize, 1), v[0].children.len);
    try testing.expectEqualStrings("--depth", v[0].children[0].tokens[0]);
    try testing.expectEqual(VarType.number, v[0].children[0].takes.?);

    try testing.expectEqual(@as(usize, 2), v[1].tokens.len);
    try testing.expectEqualStrings("DIRECTORY", v[1].tokens[1]);
    try testing.expectEqual(VarType.directory, v[1].takes.?);

    try testing.expectEqual(@as(usize, 1), v[2].tokens.len);
    try testing.expectEqual(VarType.file, v[2].takes.?);

    try testing.expectEqual(VarType.enumeration, v[3].takes.?);
    try testing.expectEqual(@as(usize, 2), v[3].options.len);
    try testing.expectEqualStrings("libx265", v[3].options[1]);

    // A note inserts nothing: no tokens survive, but the prose does.
    try testing.expectEqual(VocabKind.note, v[4].kind);
    try testing.expectEqual(@as(usize, 0), v[4].tokens.len);
    try testing.expectEqualStrings("Reminder", v[4].label);
}

test "cdl: vocabulary validation reports bad kinds, empty tokens and enum without options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\name: t
        \\display_name: T
        \\vocabulary:
        \\  - kind: mystery
        \\    tokens: ["x"]
        \\  - kind: option
        \\    label: no tokens
        \\  - kind: option
        \\    tokens: ["-x"]
        \\    takes: enum
        \\  - kind: option
        \\    tokens: ["-y"]
        \\    takes: boolean
    ;
    const r = try load(a, src);
    try testing.expect(r == .ok);
    var bad_kind = false;
    var no_tokens = false;
    var enum_no_opts = false;
    var bad_takes = false;
    for (r.ok.issues) |i| {
        if (i.level != .@"error") continue;
        if (std.mem.indexOf(u8, i.message, "invalid or missing kind") != null) bad_kind = true;
        if (std.mem.indexOf(u8, i.message, "missing tokens") != null) no_tokens = true;
        if (std.mem.indexOf(u8, i.message, "takes: enum") != null) enum_no_opts = true;
        if (std.mem.indexOf(u8, i.message, "invalid takes") != null) bad_takes = true;
    }
    try testing.expect(bad_kind and no_tokens and enum_no_opts and bad_takes);
}

test "cdl: a tool sheet alone is a valid tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\name: mytool
        \\display_name: My Tool
        \\vocabulary:
        \\  - kind: option
        \\    tokens: ["--fast"]
    ;
    const r = try load(a, src);
    try testing.expect(r == .ok);
    try testing.expect(!r.ok.hasErrors());
    try testing.expectEqual(@as(usize, 0), r.ok.doc.actions.len);
    try testing.expectEqual(@as(usize, 1), r.ok.doc.vocabulary.len);
}

test "cdl: a placeholder referencing a non-existent variable is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    args:
        \\      - value: "{nope}"
    ;
    const r = try load(a, bad);
    try testing.expect(r == .ok);
    try testing.expect(r.ok.hasErrors());

    var found = false;
    for (r.ok.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "nope") != null) found = true;
    }
    try testing.expect(found);
}

test "cdl: variable modifier placeholders are legal (_dir/_base/_stem/__cwd)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    cwd: "{src_dir}"
        \\    args:
        \\      - value: "{src_base}"
        \\      - value: "{src_stem}"
        \\      - value: "{__cwd}"
        \\    variables:
        \\      - name: src
        \\        type: file
        \\        label: Source
    ;
    const r = try load(a, ok);
    try testing.expect(r == .ok);
    if (r.ok.hasErrors()) {
        for (r.ok.issues) |i| std.debug.print("[{t}] {s}\n", .{ i.level, i.message });
    }
    try testing.expect(!r.ok.hasErrors());
}

test "cdl: an enum default outside options is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    args: []
        \\    variables:
        \\      - name: mode
        \\        type: enum
        \\        label: Mode
        \\        default: zzz
        \\        options:
        \\          - value: aaa
        \\            label: AAA
    ;
    const r = try load(a, bad);
    try testing.expect(r == .ok);
    var found = false;
    for (r.ok.issues) |i| {
        if (i.level == .@"error" and std.mem.indexOf(u8, i.message, "zzz") != null) found = true;
    }
    try testing.expect(found);
}

test "cdl: duplicate action names are an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A1
        \\    args: []
        \\  - name: a
        \\    label: A2
        \\    args: []
    ;
    const r = try load(a, bad);
    try testing.expect(r == .ok);
    var found = false;
    for (r.ok.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "duplicate") != null) found = true;
    }
    try testing.expect(found);
}

test "cdl: an unknown variable type is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    args:
        \\      - value: "{v}"
        \\    variables:
        \\      - name: v
        \\        type: wat
        \\        label: V
    ;
    const r = try load(a, bad);
    try testing.expect(r == .ok);
    var found = false;
    for (r.ok.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "invalid type") != null) found = true;
    }
    try testing.expect(found);
}

test "cdl: stream mode parsing and the file: variable form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    stdin: file:{infile}
        \\    stdout: pipe
        \\    stderr: discard
        \\    args: []
        \\    variables:
        \\      - name: infile
        \\        type: file
        \\        label: Input
    ;
    const r = try load(a, text);
    try testing.expect(r == .ok);
    if (r.ok.hasErrors()) {
        for (r.ok.issues) |i| std.debug.print("[{t}] {s} @ {s}\n", .{ i.level, i.message, i.path });
    }
    try testing.expect(!r.ok.hasErrors());
    const act = r.ok.doc.findAction("a").?;
    try testing.expectEqual(StreamMode.file_var, act.stdin.mode);
    try testing.expectEqualStrings("infile", act.stdin.var_name.?);
    try testing.expectEqual(StreamMode.pipe, act.stdout.mode);
    try testing.expectEqual(StreamMode.discard, act.stderr.mode);
}

test "cdl: args boolean when and the var/repeat shorthands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\name: t
        \\display_name: T
        \\actions:
        \\  - name: a
        \\    label: A
        \\    args:
        \\      - value: "-O2"
        \\        when: opt
        \\      - var: mode
        \\      - repeat: extra
        \\        prefix: "-x"
        \\    variables:
        \\      - name: opt
        \\        type: boolean
        \\        label: Optimize
        \\      - name: mode
        \\        type: text
        \\        label: Mode
        \\      - name: extra
        \\        type: text
        \\        label: Extra
    ;
    const r = try load(a, text);
    try testing.expect(r == .ok);
    if (r.ok.hasErrors()) {
        for (r.ok.issues) |i| std.debug.print("[{t}] {s} @ {s}\n", .{ i.level, i.message, i.path });
    }
    try testing.expect(!r.ok.hasErrors());
    const act = r.ok.doc.findAction("a").?;
    try testing.expectEqualStrings("opt", act.args[0].when.?);
    try testing.expectEqualStrings("mode", act.args[1].var_name.?);
    try testing.expectEqualStrings("extra", act.args[2].repeat.?);
    try testing.expectEqualStrings("-x", act.args[2].prefix.?);
}

test "cdl: duplicate fields are an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try load(a, "{\"name\":\"a\",\"name\":\"b\",\"display_name\":\"B\",\"actions\":[{\"name\":\"x\",\"label\":\"X\",\"args\":[]}]}");
    try testing.expect(r == .ok);
    var found = false;
    for (r.ok.issues) |i| {
        if (std.mem.indexOf(u8, i.message, "defined more than once") != null) found = true;
    }
    try testing.expect(found);
}

test "cdl: format detection" {
    try testing.expectEqual(Format.yaml, detectFormat("name: x\n"));
    try testing.expectEqual(Format.json, detectFormat("  \n  {\"name\": \"x\"}"));
    try testing.expectEqual(Format.yaml, detectFormat("   \n\n # comment\nname: x"));
}
