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

/// Буферы: максимум TLS-кадра + запас на заголовки ответа.
const sock_rbuf_len = 17 * 1024;
const sock_wbuf_len = 8 * 1024;
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
        const stream = if (self.proxy) |p| blk: {
            const s = try std.net.tcpConnectToHost(self.alloc, p.host, p.port);
            socks5.handshake(s, host, port) catch |e| {
                s.close();
                return e;
            };
            break :blk s;
        } else try std.net.tcpConnectToHost(self.alloc, host, port);
        errdefer {
            stream.close();
            self.stream = null;
        }
        self.stream_reader = std.net.Stream.reader(stream, &self.sock_rbuf);
        self.stream_writer = std.net.Stream.writer(stream, &self.sock_wbuf);
        if (!self.ca_ready) {
            self.ca_mutex.lock();
            defer self.ca_mutex.unlock();
            if (!self.ca_ready) {
                self.ca.rescan(self.alloc) catch {}; // пустой набор → ошибка TLS ниже
                self.ca_ready = true;
            }
        }
        self.tls_client = try tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = .{ .bundle = self.ca },
                .read_buffer = &self.tls_rbuf,
                .write_buffer = &self.tls_wbuf,
                .allow_truncation_attacks = true, // длина проверяет HTTP
            },
        );
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
        read_timeout_s: u32 = 75, // > таймаута long poll (50 с) с запасом
    };

    /// Выполняет запрос, тело пишется в `out`. При сетевой ошибке один раз
    /// пересоединяется и повторяет — «connection reset after idle» не должен
    /// валить long poll.
    pub fn request(self: *Client, opts: RequestOptions, out: *std.Io.Writer.Allocating) !u16 {
        if (self.requestOnce(opts, out)) |code| {
            return code;
        } else |_| {
            self.disconnect();
            return self.requestOnce(opts, out);
        }
    }

    fn requestOnce(self: *Client, opts: RequestOptions, out: *std.Io.Writer.Allocating) !u16 {
        try self.ensureConnected(opts.host, opts.port);
        const w = self.writer();
        try w.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: moonobsrv/1\r\nAccept: application/json\r\nConnection: keep-alive\r\n", .{ opts.method, opts.path, opts.host });
        if (opts.body) |b| {
            try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ opts.content_type, b.len });
        }
        try w.writeAll("\r\n");
        if (opts.body) |b| try w.writeAll(b);
        try w.flush();

        const r = self.reader();
        // Статус-строка: HTTP/1.1 200 OK (takeDelimiterInclusive съедает \n)
        const status_line = r.takeDelimiterInclusive('\n') catch return error.HttpReadFailed;
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
