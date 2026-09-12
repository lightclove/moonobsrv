//! Минимальный HTTPS-клиент: TLS 1.3 из std.crypto поверх TCP или SOCKS5
//! (Tor), HTTP/1.1 с keep-alive на одном соединении. Своя реализация вместо
//! std.http.Client — тот не умеет SOCKS, а выброшенный из бинарника код
//! клиентской библиотеки (чанкованный парсер на все случаи, пул, редиректы)
//! не нужен боту, который ходит ровно на один хост.
//!
//! Один Client = одно соединение (у бота их два: основной, при заданном
//! прокси идущий через Tor, и direct для алертов — без прокси).

const std = @import("std");
const config = @import("../config.zig");
const socks5 = @import("socks5.zig");

const tls = std.crypto.tls;

/// Буферы: каждый ≥ tls.min_buffer_len (~16.7 КБ) — TLS-писатель требует
/// столько у сокет-писателя под один шифрокадр (меньше = UB в релизе).
const sock_rbuf_len = 17 * 1024;
const sock_wbuf_len = 17 * 1024;
const tls_rbuf_len = 17 * 1024 + 8 * 1024;
const tls_wbuf_len = 17 * 1024;

pub const Response = struct {
    status: u16,
    /// Тело ответа (ссылается на память Allocating-писателя вызывающего).
    body: []const u8,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    proxy: ?config.Config.Socks,
    ca: std.crypto.Certificate.Bundle = .{},
    ca_ready: bool = false,
    ca_mutex: std.Thread.Mutex = .{},

    // Соединение (восстанавливается лениво).
    stream: ?std.net.Stream = null,
    tls_client: ?tls.Client = null,
    stream_reader: std.net.Stream.Reader = undefined,
    stream_writer: std.net.Stream.Writer = undefined,
    sock_rbuf: [sock_rbuf_len]u8 = undefined,
    sock_wbuf: [sock_wbuf_len]u8 = undefined,
    tls_rbuf: [tls_rbuf_len]u8 = undefined,
    tls_wbuf: [tls_wbuf_len]u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, proxy: ?config.Config.Socks) Client {
        return .{ .alloc = alloc, .proxy = proxy };
    }

    pub fn deinit(self: *Client) void {
        self.disconnect();
        self.ca.deinit(self.alloc);
    }

    pub fn disconnect(self: *Client) void {
        if (self.stream) |s| s.close();
        self.stream = null;
        self.tls_client = null;
    }

    fn ensureConnected(self: *Client, host: []const u8, port: u16) !void {
        if (self.stream != null) return;
        dbg("connect: {s}:{d} proxy={s}", .{ host, port, if (self.proxy != null) "да" else "нет" });
        const stream = if (self.proxy) |p| blk: {
            const s = try std.net.tcpConnectToHost(self.alloc, p.host, p.port);
            setSocketTimeout(s, 30);
            dbg("tcp до прокси ок, socks handshake", .{});
            socks5.handshake(s, host, port) catch |e| {
                s.close();
                return e;
            };
            dbg("socks ок", .{});
            break :blk s;
        } else try std.net.tcpConnectToHost(self.alloc, host, port);
        setSocketTimeout(stream, 75); // > long poll (50 с) с запасом
        errdefer {
            stream.close();
            self.stream = null;
        }
        self.stream_reader = std.net.Stream.reader(stream, &self.sock_rbuf);
        self.stream_writer = std.net.Stream.writer(stream, &self.sock_wbuf);
        dbg("ca rescan", .{});
        if (!self.ca_ready) {
            self.ca_mutex.lock();
            defer self.ca_mutex.unlock();
            if (!self.ca_ready) {
                self.ca.rescan(self.alloc) catch {}; // пустой набор → ошибка TLS ниже
                self.ca_ready = true;
            }
        }
        dbg("tls handshake", .{});
        self.tls_client = try tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = self.ca },
                .read_buffer = &self.tls_rbuf,
                .write_buffer = &self.tls_wbuf,
                .allow_truncation_attacks = true, // длину проверяет HTTP
            },
        );
        dbg("tls ок", .{});
        self.stream = stream;
    }

    fn reader(self: *Client) *std.Io.Reader {
        return if (self.tls_client) |*t| &t.reader else self.stream_reader.interface();
    }

    fn writer(self: *Client) *std.Io.Writer {
        return if (self.tls_client) |*t| &t.writer else &self.stream_writer.interface;
    }

    pub const RequestOptions = struct {
        method: []const u8 = "GET",
        host: []const u8,
        port: u16 = 443,
        path: []const u8 = "/",
        body: ?[]const u8 = null,
        content_type: []const u8 = "application/json",
    };

    /// Выполняет запрос, тело пишется в `out`. При сетевой ошибке один раз
    /// пересоединяется и повторяет — «connection reset after idle» не должен
    /// валить long poll. Частичное тело первой попытки сбрасывается: иначе
    /// повтор дописывал бы ответ к обрывку (мусор в getUpdates).
    pub fn request(self: *Client, opts: RequestOptions, out: *std.Io.Writer.Allocating) !u16 {
        if (self.requestOnce(opts, out)) |code| {
            return code;
        } else |_| {
            self.disconnect();
            out.shrinkRetainingCapacity(0);
            return self.requestOnce(opts, out);
        }
    }

    fn requestOnce(self: *Client, opts: RequestOptions, out: *std.Io.Writer.Allocating) !u16 {
        try self.ensureConnected(opts.host, opts.port);
        const w = self.writer();
        dbg("req: пишу заголовки", .{});
        try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: moonobsrv/1\r\nAccept: application/json\r\nConnection: keep-alive\r\n", .{ opts.method, opts.path, opts.host });
        if (opts.body) |b| {
            try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ opts.content_type, b.len });
        }
        try w.writeAll("\r\n");
        if (opts.body) |b| try w.writeAll(b);
        dbg("req: flush", .{});
        try w.flush();
        // flush TLS-писателя только кладёт шифротекст в буфер сокет-писателя —
        // вытолкиваем его в сокет (для plain-режима повторный flush пуст и безвреден)
        try self.stream_writer.interface.flush();
        dbg("req: отправлено, читаю статус", .{});
        const r = self.reader();
        // Статус-строка: HTTP/1.1 200 OK (takeDelimiterInclusive съедает \n)
        const status_line = r.takeDelimiterInclusive('\n') catch return error.HttpReadFailed;
        dbg("req: статус: {s}", .{status_line[0..@min(status_line.len, 20)]});
        if (status_line.len < 12 or !std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadStatusLine;
        const status = std.fmt.parseInt(u16, std.mem.trim(u8, status_line[9..12], " "), 10) catch return error.BadStatusLine;

        // Заголовки до пустой строки.
        var content_length: ?usize = null;
        var chunked = false;
        var server_close = false;
        var hcount: usize = 0;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch return error.HttpReadFailed;
            hcount += 1;
            if (hcount > 128) return error.HttpHeadersOversize;
            const h = std.mem.trimRight(u8, line, "\r\n");
            if (h.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const name = std.mem.trim(u8, h[0..colon], " ");
            const value = std.mem.trim(u8, h[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.indexOfIgnoreCase(value, "close") != null) server_close = true;
            }
        }

        if (chunked) {
            try readChunked(r, out);
        } else if (content_length) |n| {
            try readInto(r, out, n);
        } else {
            // ни длины, ни чанков — читаем до закрытия соединения
            var b: [4096]u8 = undefined;
            while (true) {
                const got = r.readSliceShort(&b) catch break;
                if (got == 0) break;
                out.writer.writeAll(b[0..got]) catch return error.OutOfMemory;
            }
            self.disconnect();
            return status;
        }
        if (server_close) self.disconnect();
        return status;
    }

};

fn readChunked(r: *std.Io.Reader, out: *std.Io.Writer.Allocating) !void {
    while (true) {
        const size_line = r.takeDelimiterInclusive('\n') catch return error.HttpReadFailed;
        const s = std.mem.trimRight(u8, size_line, "\r\n");
        const semi = std.mem.indexOfScalar(u8, s, ';') orelse s.len;
        const size = std.fmt.parseInt(usize, s[0..semi], 16) catch return error.BadChunkHeader;
        if (size == 0) {
            // trailer-строки до пустой
            while (true) {
                const t = r.takeDelimiterInclusive('\n') catch return error.HttpReadFailed;
                if (std.mem.trimRight(u8, t, "\r\n").len == 0) return;
            }
        }
        try readInto(r, out, size);
        var crlf: [2]u8 = undefined;
        r.readSliceAll(&crlf) catch return error.HttpReadFailed;
    }
}

fn readInto(r: *std.Io.Reader, out: *std.Io.Writer.Allocating, n: usize) !void {
    var b: [4096]u8 = undefined;
    var remaining: usize = n;
    while (remaining > 0) {
        const want = @min(remaining, b.len);
        r.readSliceAll(b[0..want]) catch return error.HttpReadFailed;
        out.writer.writeAll(b[0..want]) catch return error.OutOfMemory;
        remaining -= want;
    }
}

/// SO_RCVTIMEO/SO_SNDTIMEO: блокирующий сокет не должен висеть вечно.
fn setSocketTimeout(stream: std.net.Stream, seconds: u32) void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const ms: u32 = seconds * 1000;
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&ms)) catch {};
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&ms)) catch {};
    } else {
        const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (!dbgEnabled()) return;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[net] " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(w.buffered()) catch {};
}

fn dbgEnabled() bool {
    if (dbg_cached) |v| return v;
    const v = std.process.hasEnvVar(std.heap.page_allocator, "MOONOBSRV_NET_DEBUG") catch false;
    dbg_cached = v;
    return v;
}

var dbg_cached: ?bool = null;

test "readChunked: кадры и trailer" {
    var sr = std.Io.Reader.fixed("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try readChunked(&sr, &aw);
    try std.testing.expectEqualStrings("hello world", aw.written());
}

test "readChunked: расширения после размера игнорируются" {
    var sr = std.Io.Reader.fixed("4;foo=bar\r\nabcd\r\n0\r\n\r\n");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try readChunked(&sr, &aw);
    try std.testing.expectEqualStrings("abcd", aw.written());
}

test "parseStatusLine и заголовки" {
    const line = "HTTP/1.1 409 Conflict\r";
    const code = try std.fmt.parseInt(u16, std.mem.trim(u8, line[9..12], " "), 10);
    try std.testing.expectEqual(@as(u16, 409), code);
    try std.testing.expect(std.ascii.indexOfIgnoreCase("keep-alive, close", "close") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase("keep-alive", "close") == null);
}
