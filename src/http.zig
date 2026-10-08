//! `--http`: local HTTP/1.1 + WebSocket server that exposes the real engine to a browser.
//!
//! A development/debug transport only — rule 9 forbids using it as the GUI.
//!   GET /            -> static assets (default `web/` directory, with an index.html fallback)
//!   GET /rpc         -> WebSocket upgrade; JSON-RPC 2.0 (protocol in docs/RPC.md)
//!
//! Every request is really handled by the Zig engine (built-in CDL parsing, real process execution,
//! real events), with `app.info.transport = "ws"` and `app.info.mode = "http"`. A Node stand-in that
//! matched this contract byte for byte (`dev/mock-rpc.mjs`) was retired along with the web frontend
//! and is no longer part of the tree.
//!
//! Implementation constraints (all forced by the environment, not design choices):
//!   - One `std.Thread` per connection: `std.Io.Threaded` may be called across threads,
//!     but it has nothing to do with the WebView2/Win32 message loop, so a plain blocking model is used
//!     here and no selector is introduced;
//!   - The event outlet (`rpc.Sink`) needs **global broadcast**: `Service` is a singleton,
//!     so every connected client receives events (a reasonable semantic for a single-user local tool,
//!     and it also solves "which connection should the execution thread write back to" for free);
//!   - Frame writes are serialized with a mutex: events come from the execution thread, responses from the connection thread.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const rpc = @import("rpc.zig");
const builtin = @import("builtin.zig");

pub const default_port: u16 = 8791;
pub const default_web_dir = "web";

/// RFC6455 handshake magic string.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Single WebSocket frame payload limit (1 MiB): plenty for a local tool, and it keeps malformed frames from exhausting memory.
const max_frame_len = 1024 * 1024;
/// HTTP request head limit (32 KiB).
const max_head_len = 32 * 1024;

// ── Entry point ─────────────────────────────────────────────────

pub const Config = struct {
    port: u16 = default_port,
    web_dir: []const u8 = default_web_dir,
    host: []const u8 = "127.0.0.1",
};

/// Start the service and block until the process is terminated. Returns the process exit code.
pub fn run(init: std.process.Init, cfg: Config) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();

    var ctx = try a.create(Context);
    ctx.* = .{ .gpa = gpa, .io = io, .web_dir = cfg.web_dir };

    // Working directory (needed by `{__cwd}` and by dry-run)
    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const cwd = try a.dupe(u8, cwd_buf[0..cwd_len]);

    ctx.svc = rpc.Service.init(gpa, io, init.minimal.environ, .{
        .ctx = &ctx.clients,
        .send_fn = Broadcaster.sendFn,
    });
    ctx.svc.cwd = cwd;
    ctx.svc.transport = "ws";
    ctx.svc.mode = "http";
    // Rule 4 (fully portable): the writable root is `<tool dir>/.pipelith`, anchored on
    // the running executable (builtin.stateDir), never on the current working directory.
    ctx.svc.user_dir = (try builtin.stateDir(io, a)) orelse return error.ToolDirUnavailable;
    ctx.svc.tools_dir = try builtin.userCdlDir(io, a, &ctx.svc.env_map.?);
    // Tools come only from the tool directory (installed packs + hand-written CDLs): this transport
    // loads no defaults either.
    ctx.svc.loadUserTools();

    const addr = try net.IpAddress.parseIp4(cfg.host, cfg.port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const bound = server.socket.address.getPort();

    printBanner(io, cfg, ctx, bound);

    while (true) {
        const stream = server.accept(io) catch |e| switch (e) {
            error.Canceled => return 0,
            else => continue,
        };
        // One **separate Io.Threaded** per connection.
        //
        // Measured behaviour: on Windows the networking operations of `Io.Threaded` go through the AFD
        // device plus an APC alertable wait, and APCs depend on thread-local state
        // (`threadlocal var current`). Handing the main thread's `Io` straight to a connection thread makes
        // `netRead` fail. Giving the connection thread its own io avoids the problem entirely, because
        // init and use then happen on the same thread and never cross a thread boundary.
        const t = std.Thread.spawn(.{}, connThreadMain, .{ ctx, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// Connection thread entry point: create an io for **this thread**, then handle the connection.
///
/// `Io.Threaded` must not be shared across threads (see the comment above), so the io is created
/// here, used here, and released when the thread ends.
fn connThreadMain(ctx: *Context, stream: net.Stream) void {
    var threaded: std.Io.Threaded = .init(ctx.gpa, .{});
    defer threaded.deinit();
    Conn.run(ctx, threaded.io(), stream);
}

fn printBanner(io: Io, cfg: Config, ctx: *Context, bound: u16) void {
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    w.print(
        \\Flow Pipelith {s} — HTTP server started
        \\  UI:          http://{s}:{d}/
        \\  RPC:         ws://{s}:{d}/rpc
        \\  Static root: {s}
        \\  Built-in CDL: {d}
        \\  Stop:        Ctrl+C
        \\
        \\
    , .{ "0.1.0", cfg.host, bound, cfg.host, bound, cfg.web_dir, ctx.svc.docs.count() }) catch {};
    w.flush() catch {};
}

// ── Global context ──────────────────────────────────────────────

const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Static asset root directory
    web_dir: []const u8 = default_web_dir,
    svc: rpc.Service = undefined,
    /// Connected WebSocket clients (event broadcast outlet)
    clients: Broadcaster = .{},
};

// ── Connection handling ─────────────────────────────────────────

const Conn = struct {
    ctx: *Context,
    /// This connection thread's own io (**must not** use the main thread's io stored in ctx; see the comment in run())
    io: Io,
    stream: net.Stream,

    fn run(ctx: *Context, io: Io, stream: net.Stream) void {
        const self: Conn = .{ .ctx = ctx, .io = io, .stream = stream };
        var wbuf: [8 * 1024]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        self.writeHead(&sw.interface) catch {};
        stream.close(io);
    }

    fn writeHead(self: Conn, w: *Io.Writer) !void {
        const io = self.io;
        const gpa = self.ctx.gpa;

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var rbuf: [16 * 1024]u8 = undefined;
        var rd = self.stream.reader(io, &rbuf);
        var consumed: usize = 0;

        const head = (try readHead(&rd.interface, &consumed, &rbuf)) orelse return;
        const parsed = parseRequest(head) orelse {
            try respondText(w, 400, "Bad Request", "request could not be parsed\n");
            return;
        };

        // WebSocket upgrade
        if (isUpgrade(parsed)) {
            if (!std.mem.eql(u8, parsed.path, "/rpc")) {
                try respondText(w, 404, "Not Found", "unknown WebSocket endpoint\n");
                return;
            }
            const key = headerValue(parsed.headers, "sec-websocket-key") orelse {
                try respondText(w, 400, "Bad Request", "missing Sec-WebSocket-Key\n");
                return;
            };
            try self.serveWs(a, &rd, rbuf[0..consumed], key, w);
            return;
        }

        // Static assets
        if (!std.mem.eql(u8, parsed.method, "GET") and !std.mem.eql(u8, parsed.method, "HEAD")) {
            try respondText(w, 405, "Method Not Allowed", "only GET is supported\n");
            return;
        }
        try self.serveStatic(a, parsed.path, std.mem.eql(u8, parsed.method, "HEAD"), w);
    }

    fn serveStatic(self: Conn, a: std.mem.Allocator, raw_path: []const u8, head_only: bool, w: *Io.Writer) !void {
        const io = self.io;
        const web_dir = self.ctx.web_dir;

        // Safety: only serve files under web/, reject any `..` outright (the minimum defence line for a local debug server)
        if (std.mem.indexOf(u8, raw_path, "..") != null) {
            try respondText(w, 403, "Forbidden", "path traversal is forbidden\n");
            return;
        }
        const decoded = try percentDecode(a, raw_path);
        var rel = decoded;
        if (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
        if (rel.len == 0) rel = "index.html";

        const full = try std.fs.path.join(a, &.{ web_dir, rel });
        const body = Io.Dir.cwd().readFileAlloc(io, full, a, .limited(64 * 1024 * 1024)) catch {
            try respondText(w, 404, "Not Found", try std.fmt.allocPrint(
                a,
                "404 {s}\n\n(--http only serves static assets under {s}/, please make sure {s}/index.html exists)\n",
                .{ decoded, web_dir, web_dir },
            ));
            return;
        };

        try w.print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ mimeOf(rel), body.len });
        if (!head_only) try w.writeAll(body);
        try w.flush();
    }

    /// WebSocket session: handshake -> frame loop -> unregister.
    fn serveWs(self: Conn, a: std.mem.Allocator, rd: *net.Stream.Reader, initial: []const u8, key: []const u8, w: *Io.Writer) !void {
        const io = self.io;
        const gpa = self.ctx.gpa;
        _ = a;

        // Handshake response
        var sha: [20]u8 = undefined;
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(key);
        h.update(ws_guid);
        h.final(&sha);
        var accept_buf: [64]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&accept_buf, &sha);

        try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
        try w.flush();

        // Register as an event outlet
        const out = try WsWriter.create(gpa, io, self.stream);
        try self.ctx.clients.add(gpa, out);
        defer {
            self.ctx.clients.remove(out);
            out.sendClose();
            gpa.destroy(out);
        }

        // The upgrade request may already have carried frame data
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(gpa);
        if (initial.len > 0) try pending.appendSlice(gpa, initial);

        var rbuf: [16 * 1024]u8 = undefined;
        while (true) {
            var payload: std.ArrayListUnmanaged(u8) = .empty;
            defer payload.deinit(gpa);
            const opcode = (try readFrame(&rd.interface, gpa, &pending, &rbuf, &payload)) orelse return;
            switch (opcode) {
                0x1, 0x2 => {
                    const text = std.mem.trim(u8, payload.items, " \t\r\n");
                    if (text.len == 0) continue;
                    // One arena per frame; responses are sent first (which guarantees the intuitive ordering "a response precedes the events it triggers")
                    var frame_arena = std.heap.ArenaAllocator.init(gpa);
                    defer frame_arena.deinit();
                    const fa = frame_arena.allocator();
                    const responses = rpc.handleRequest(&self.ctx.svc, fa, text) catch |e| switch (e) {
                        error.OutOfMemory => return,
                        else => continue,
                    };
                    for (responses) |resp| out.sendText(resp);
                },
                0x8 => return, // close
                0x9 => {
                    // ping -> pong (echoed back verbatim)
                    out.sendFrame(0xA, payload.items);
                },
                else => {}, // pong / continuation: ignore
            }
        }
    }
};

// ── Event broadcast ─────────────────────────────────────────────

/// Registry of connected WebSocket clients; the implementation of `rpc.Sink`.
const Broadcaster = struct {
    gpa: std.mem.Allocator = undefined,
    mutex: Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*WsWriter) = .empty,
    /// Required for broadcasting, filled in by `Context` during initialization (`Sink.ctx` can only carry one pointer)
    io: Io = undefined,

    fn sendFn(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Broadcaster = @ptrCast(@alignCast(ctx.?));
        self.broadcast(json);
    }

    fn add(self: *Broadcaster, gpa: std.mem.Allocator, w: *WsWriter) !void {
        self.gpa = gpa;
        self.io = w.io;
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        try self.entries.append(gpa, w);
    }

    fn remove(self: *Broadcaster, w: *WsWriter) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        for (self.entries.items, 0..) |e, i| {
            if (e == w) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Note: sending happens while the lock is held. Frame writes carry their own lock as well,
    /// but a local tool has only one execution thread, so the serialization cost is negligible and it
    /// buys "the registry and the send order stay consistent".
    fn broadcast(self: *Broadcaster, json: []const u8) void {
        if (self.entries.items.len == 0) return;
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        for (self.entries.items) |w| w.sendText(json);
    }
};

/// Message outlet of a single WebSocket connection (thread-safe: both the event thread and the connection thread call it).
const WsWriter = struct {
    io: Io,
    stream: net.Stream,
    /// Frame writes are serialized: events come from the execution thread, responses from the connection thread.
    mutex: Io.Mutex = .init,

    fn create(gpa: std.mem.Allocator, io: Io, stream: net.Stream) !*WsWriter {
        const w = try gpa.create(WsWriter);
        w.* = .{ .io = io, .stream = stream };
        return w;
    }

    fn sendText(self: *WsWriter, json: []const u8) void {
        self.sendFrame(0x1, json);
    }

    fn sendClose(self: *WsWriter) void {
        self.sendFrame(0x8, "");
    }

    fn sendFrame(self: *WsWriter, opcode: u8, payload: []const u8) void {
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        var buf: [8 * 1024]u8 = undefined;
        var sw = self.stream.writer(self.io, &buf);
        const w = &sw.interface;
        var hdr: [10]u8 = undefined;
        const n = encodeHeader(&hdr, opcode, payload.len);
        w.writeAll(hdr[0..n]) catch return;
        if (payload.len > 0) w.writeAll(payload) catch return;
        w.flush() catch {};
    }
};

// ── HTTP parsing ────────────────────────────────────────────────

const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: []const u8, // raw header block (without the request line)
};

/// Read one complete request head (`\r\n\r\n` or `\n\n`).
/// The returned slice points at the **start of the header block** -- that way, after upgrading
/// to WebSocket, any extra bytes read past the header block can be treated as frame data unchanged.
fn readHead(rd: *Io.Reader, consumed: *usize, buf: []u8) !?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const got = rd.readSliceShort(buf[n..]) catch return null;
        if (got == 0) break;
        n += got;
        const end = findHeadEnd(buf[0..n]) orelse continue;
        consumed.* = n;
        return buf[0..end];
    }
    consumed.* = n;
    return null;
}

/// Returns the index of the end of the header block (**including the terminating empty line**).
/// The empty line must be included, otherwise after a WebSocket upgrade the frame data following
/// the empty line would be mixed together with the header block.
fn findHeadEnd(b: []const u8) ?usize {
    if (std.mem.indexOf(u8, b, "\r\n\r\n")) |i| return i + 4;
    if (std.mem.indexOf(u8, b, "\n\n")) |i| return i + 2;
    return null;
}

fn parseRequest(head: []const u8) ?Request {
    const line_end = std.mem.indexOfAny(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    const target = it.next() orelse return null;
    const version = it.next() orelse "HTTP/1.0";
    // Drop the query string (this service does not use a query)
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const after = if (line_end + 2 <= head.len) head[line_end + 2 ..] else "";
    return .{ .method = method, .path = path, .version = version, .headers = after };
}

fn isUpgrade(r: Request) bool {
    const up = headerValue(r.headers, "upgrade") orelse return false;
    return containsIgnoreCase(up, "websocket");
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, headers, "\r\n");
    while (lines.next()) |ln| {
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const k = std.mem.trim(u8, ln[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(k, name)) return std.mem.trim(u8, ln[colon + 1 ..], " \t");
    }
    return null;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(a, s[i]);
                i += 1;
                continue;
            };
            try out.append(a, hi * 16 + lo);
            i += 3;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn mimeOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
        .{ ".map", "application/json; charset=utf-8" },
        .{ ".cdl", "text/plain; charset=utf-8" },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, ext, e[0])) return e[1];
    }
    return "application/octet-stream";
}

fn respondText(w: *Io.Writer, code: u16, reason: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, reason, body.len });
    try w.writeAll(body);
    try w.flush();
}

// ── RFC6455 frames ──────────────────────────────────────────────

/// Encode a server->client frame header (no mask). Returns the header length.
fn encodeHeader(out: *[10]u8, opcode: u8, len: usize) usize {
    out[0] = 0x80 | (opcode & 0x0F);
    if (len < 126) {
        out[1] = @intCast(len);
        return 2;
    }
    if (len < 65536) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        return 4;
    }
    out[1] = 127;
    std.mem.writeInt(u64, out[2..10], @intCast(len), .big);
    return 10;
}

/// Read one frame (client -> server). Returns the opcode; returns null when the connection ends
/// or the frame is malformed. The payload is appended to `payload`; `pending` caches bytes left
/// over across calls (frame data read past the upgrade request also enters through here).
fn readFrame(
    rd: *Io.Reader,
    gpa: std.mem.Allocator,
    pending: *std.ArrayListUnmanaged(u8),
    rbuf: []u8,
    payload: *std.ArrayListUnmanaged(u8),
) !?u8 {
    while (true) {
        if (attemptDecode(gpa, pending.items, payload) catch return null) |res| {
            consume(pending, res.consumed);
            return res.opcode;
        }
        const got = rd.readSliceShort(rbuf) catch return null;
        if (got == 0) return null;
        // Malformed/oversized frame protection: a frame whose declared length already exceeds the limit is never "completed"
        if (pending.items.len + got > max_frame_len + 1024) return null;
        try pending.appendSlice(gpa, rbuf[0..got]);
    }
}

fn consume(buf: *std.ArrayListUnmanaged(u8), n: usize) void {
    const rest = buf.items.len - n;
    if (rest > 0) std.mem.copyForwards(u8, buf.items[0..rest], buf.items[n..]);
    buf.shrinkRetainingCapacity(rest);
}

const FrameResult = struct { opcode: u8, consumed: usize };
const FrameError = error{ Malformed, OutOfMemory };

fn attemptDecode(a: std.mem.Allocator, buf: []const u8, payload: *std.ArrayListUnmanaged(u8)) FrameError!?FrameResult {
    if (buf.len < 2) return null;
    const opcode = buf[0] & 0x0F;
    const masked = (buf[1] & 0x80) != 0;
    var len: u64 = buf[1] & 0x7F;
    var off: usize = 2;
    if (len == 126) {
        if (buf.len < off + 2) return null;
        len = std.mem.readInt(u16, buf[off..][0..2], .big);
        off += 2;
    } else if (len == 127) {
        if (buf.len < off + 8) return null;
        len = std.mem.readInt(u64, buf[off..][0..8], .big);
        off += 8;
    }
    // RFC6455 §5.1: client -> server frames **must** be masked; the length must be bounded as well
    if (!masked) return error.Malformed;
    if (len > max_frame_len) return error.Malformed;
    if (buf.len < off + 4) return null;
    const mask = buf[off..][0..4].*;
    off += 4;
    const n: usize = @intCast(len);
    if (buf.len < off + n) return null;

    const start = payload.items.len;
    try payload.appendSlice(a, buf[off .. off + n]);
    for (payload.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];
    return .{ .opcode = opcode, .consumed = off + n };
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "mimeOf" {
    try testing.expectEqualStrings("text/html; charset=utf-8", mimeOf("index.html"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeOf("a/b/app.js"));
    try testing.expectEqualStrings("text/css; charset=utf-8", mimeOf("styles.css"));
    try testing.expectEqualStrings("application/octet-stream", mimeOf("x.bin"));
}

test "parseRequest + headerValue" {
    const head = "GET /rpc HTTP/1.1\r\nHost: 127.0.0.1:8791\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc==\r\n\r\n";
    const r = parseRequest(head) orelse return error.ParseFailed;
    try testing.expectEqualStrings("GET", r.method);
    try testing.expectEqualStrings("/rpc", r.path);
    try testing.expect(isUpgrade(r));
    try testing.expectEqualStrings("abc==", headerValue(r.headers, "sec-websocket-key").?);
    // Header names are case-insensitive
    try testing.expectEqualStrings("127.0.0.1:8791", headerValue(r.headers, "HOST").?);
}

test "parseRequest strips the query string" {
    const r = parseRequest("GET /index.html?a=1 HTTP/1.1\r\n\r\n") orelse return error.ParseFailed;
    try testing.expectEqualStrings("/index.html", r.path);
}

test "findHeadEnd supports CRLF and LF" {
    // What is returned is the index of the "end of the header block" (including the terminating empty line),
    // so the following bytes can be used as frame data unchanged
    try testing.expectEqual(@as(?usize, 18), findHeadEnd("GET / HTTP/1.1\r\n\r\nrest"));
    try testing.expectEqual(@as(?usize, 16), findHeadEnd("GET / HTTP/1.1\n\nrest"));
    try testing.expectEqual(@as(?usize, null), findHeadEnd("GET / HTTP/1.1\r\nHost: x\r\n"));

    const buf = "GET / HTTP/1.1\r\nHost: x\r\n\r\nFRAME";
    const end = findHeadEnd(buf).?;
    try testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: x\r\n\r\n", buf[0..end]);
    try testing.expectEqualStrings("FRAME", buf[end..]);
}

test "percentDecode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/a b", try percentDecode(arena.allocator(), "/a%20b"));
    try testing.expectEqualStrings("/a%zz", try percentDecode(arena.allocator(), "/a%zz"));
}

test "encodeHeader three lengths" {
    var b: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), encodeHeader(&b, 0x1, 5));
    try testing.expectEqual(@as(u8, 0x81), b[0]);
    try testing.expectEqual(@as(u8, 5), b[1]);

    try testing.expectEqual(@as(usize, 4), encodeHeader(&b, 0x1, 200));
    try testing.expectEqual(@as(u8, 126), b[1]);
    try testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, b[2..4], .big));

    try testing.expectEqual(@as(usize, 10), encodeHeader(&b, 0x1, 70000));
    try testing.expectEqual(@as(u8, 127), b[1]);
    try testing.expectEqual(@as(u64, 70000), std.mem.readInt(u64, b[2..10], .big));
}

test "attemptDecode small frame + mask restoration" {
    // "hi" masked with 0x01 0x02 0x03 0x04
    const mask = [4]u8{ 1, 2, 3, 4 };
    const raw = [2]u8{ 'h', 'i' };
    var frame: [8]u8 = .{ 0x81, 0x80 | 2, 1, 2, 3, 4, 0, 0 };
    for (raw, 0..) |c, i| frame[6 + i] = c ^ mask[i % 4];

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(testing.allocator);
    const res = (try attemptDecode(testing.allocator, &frame, &payload)) orelse return error.DecodeFailed;
    try testing.expectEqual(@as(u8, 0x1), res.opcode);
    try testing.expectEqual(@as(usize, 8), res.consumed);
    try testing.expectEqualStrings("hi", payload.items);
}

test "attemptDecode returns null when the data is incomplete" {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(testing.allocator);
    try testing.expectEqual(@as(?FrameResult, null), try attemptDecode(testing.allocator, &[_]u8{0x81}, &payload));
    try testing.expectEqual(@as(?FrameResult, null), try attemptDecode(testing.allocator, &[_]u8{ 0x81, 0x85, 1, 2 }, &payload));
}

test "attemptDecode rejects unmasked client frames" {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(testing.allocator);
    // 0x81 0x02 "hi": the mask bit is 0, which makes it an illegal client frame
    try testing.expectError(error.Malformed, attemptDecode(testing.allocator, &[_]u8{ 0x81, 0x02, 'h', 'i' }, &payload));
}

test "Sec-WebSocket-Accept computation (RFC6455 example vector)" {
    // The example from RFC6455 §1.3: key = "dGhlIHNhbXBsZSBub25jZQ==" -> accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    var sha: [20]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(ws_guid);
    h.final(&sha);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", std.base64.standard.Encoder.encode(&buf, &sha));
}
