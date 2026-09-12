//! SOCKS5-клиент (RFC 1928) — ровно столько, сколько нужно Tor:
//! CONNECT без аутентификации, адрес цели — всегда домен (ATYP=0x03),
//! т.е. DNS резолвит сам Tor (семантика socks5h). Кадры собираются
//! чистыми функциями — тривиально тестируются байт-в-байт.

const std = @import("std");

pub const greet = [_]u8{ 0x05, 0x01, 0x00 }; // VER=5, 1 метод: без аутентификации

/// Ответ на приветствие: [VER, METHOD]. 0x00 — no auth; 0xFF — нет методов.
pub fn methodOk(reply: []const u8) bool {
    return reply.len >= 2 and reply[0] == 0x05 and reply[1] == 0x00;
}

/// Запрос CONNECT: VER CMD RSV ATYP ADDR PORT(BE).
/// null — домен длиннее 255 (лимит байта длины) или пуст.
/// IPv6-литерал кодируется ATYP=0x04 (RFC 1928; скобки из URL уже сняты
/// config.parseSocks), домен — ATYP=0x03 (socks5h: DNS резолвит прокси).
pub fn buildConnect(buf: []u8, host: []const u8, port: u16) ?[]const u8 {
    if (host.len == 0) return null;
    if (std.net.Address.parseIp(host, port)) |addr| {
        if (addr.any.family == std.posix.AF.INET6) {
            if (buf.len < 4 + 16 + 2) return null;
            buf[0] = 0x05; // VER
            buf[1] = 0x01; // CMD: CONNECT
            buf[2] = 0x00; // RSV
            buf[3] = 0x04; // ATYP: IPv6
            @memcpy(buf[4..20], addr.in6.sa.addr[0..16]);
            std.mem.writeInt(u16, buf[20..22], port, .big);
            return buf[0..22];
        }
    } else |_| {}
    if (host.len > 255) return null;
    if (buf.len < 7 + host.len) return null;
    buf[0] = 0x05; // VER
    buf[1] = 0x01; // CMD: CONNECT
    buf[2] = 0x00; // RSV
    buf[3] = 0x03; // ATYP: домен
    buf[4] = @intCast(host.len);
    @memcpy(buf[5 .. 5 + host.len], host);
    std.mem.writeInt(u16, buf[5 + host.len ..][0..2], port, .big);
    return buf[0 .. 7 + host.len];
}

pub const ConnectResult = enum { ok, refused, denied, network_unreachable, host_unreachable, ttl, cmd_not_supported, addr_not_supported, generic_fail };

/// Ответ сервера: VER REP RSV ATYP BND.ADDR BND.PORT. Возвращает null,
/// если данных ещё меньше минимальных 10 байт (ATYP=1) — доли кадра.
/// Коды REP — по RFC 1928.
pub fn parseReply(data: []const u8) ?ConnectResult {
    if (data.len < 4 or data[0] != 0x05) return null;
    const full = switch (data[3]) {
        0x01 => data.len >= 10, // VER REP RSV ATYP + 4 + 2
        0x03 => data.len >= 5 + data[4] + 2, // + LEN + домен + порт
        0x04 => data.len >= 22, // + 16 + 2
        else => false,
    };
    if (!full) return null;
    return switch (data[1]) {
        0x00 => .ok,
        0x01 => .generic_fail, // general SOCKS server failure
        0x02 => .denied, // connection not allowed by ruleset
        0x03 => .network_unreachable,
        0x04 => .host_unreachable,
        0x05 => .refused,
        0x06 => .ttl,
        0x07 => .cmd_not_supported,
        0x08 => .addr_not_supported,
        else => .generic_fail,
    };
}

/// Полный обмен по уже открытому TCP-потоку к прокси.
/// Ввод-вывод — только через интерфейсы Stream.Reader/Writer: сырой
/// stream.read (ReadFile) на сокетах Windows не работает.
pub fn handshake(stream: std.net.Stream, host: []const u8, port: u16) !void {
    var sbuf: [2048]u8 = undefined; // буфер потока
    var wbuf: [512]u8 = undefined;
    var sr = std.net.Stream.reader(stream, &sbuf);
    var sw = std.net.Stream.writer(stream, &wbuf);
    const ri = sr.interface();
    const wi = &sw.interface;

    try wi.writeAll(&greet);
    try wi.flush();
    var mbuf: [2]u8 = undefined;
    ri.readSliceAll(&mbuf) catch return error.SocksReadFailed;
    if (!methodOk(&mbuf)) return error.SocksNoAcceptableAuth;

    var cbuf: [7 + 255]u8 = undefined;
    try wi.writeAll(buildConnect(&cbuf, host, port) orelse return error.SocksBadHost);
    try wi.flush();

    // Ответ ≤ 262 байт (ATYP=3 с доменом 255); копим по байту, пока кадр
    // не станет полным — recv отдаёт данные порциями.
    var rpl: [262]u8 = undefined;
    var n: usize = 0;
    var one: [1]u8 = undefined;
    while (n < rpl.len) {
        ri.readSliceAll(&one) catch return error.SocksReadFailed;
        rpl[n] = one[0];
        n += 1;
        if (parseReply(rpl[0..n])) |res| {
            return switch (res) {
                .ok => {},
                else => error.SocksConnectRejected,
            };
        }
    }
    return error.SocksBadReply;
}

test "кадры: приветствие и выбор метода" {
    try std.testing.expect(methodOk(&.{ 0x05, 0x00 }));
    try std.testing.expect(!methodOk(&.{ 0x05, 0xFF }));
    try std.testing.expect(!methodOk(&.{ 0x04, 0x00 }));
    try std.testing.expect(!methodOk(&.{0x05}));
}

test "кадры: CONNECT собирается байт-в-байт" {
    var buf: [262]u8 = undefined;
    const req = buildConnect(&buf, "api.telegram.org", 443).?;
    const expect = [_]u8{
        0x05, 0x01, 0x00, 0x03, 16, 'a', 'p', 'i', '.', 't', 'e', 'l', 'e',
        'g', 'r', 'a', 'm', '.', 'o', 'r', 'g', 0x01, 0xBB,
    };
    try std.testing.expectEqualSlices(u8, &expect, req);
}

test "кадры: домен вне лимита протокола — null, не UB" {
    var buf: [7 + 255]u8 = undefined;
    const host = "a" ** 300;
    try std.testing.expect(buildConnect(&buf, host, 443) == null);
    try std.testing.expect(buildConnect(&buf, "", 443) == null);
    // короткий буфер — тоже null
    var small: [8]u8 = undefined;
    try std.testing.expect(buildConnect(&small, "example.org", 443) == null);
}

test "кадры: IPv6-литерал — ATYP=4 (RFC 1928)" {
    var buf: [64]u8 = undefined;
    const req = buildConnect(&buf, "::1", 443).?;
    try std.testing.expectEqual(@as(usize, 22), req.len);
    try std.testing.expectEqual(@as(u8, 0x04), req[3]);
    for (req[4..19]) |b| try std.testing.expectEqual(@as(u8, 0), b); // первые 15 байт ::1
    try std.testing.expectEqual(@as(u8, 1), req[19]); // 16-й байт ::1
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xBB }, req[20..22]);
}

test "кадры: разбор ответа CONNECT (REP по RFC 1928)" {
    // REP=0, ATYP=1, addr 0.0.0.0, port 0
    try std.testing.expectEqual(ConnectResult.ok, parseReply(&.{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    // REP=3 network unreachable, REP=4 host unreachable, REP=5 refused, REP=6 TTL
    try std.testing.expectEqual(ConnectResult.network_unreachable, parseReply(&.{ 0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    try std.testing.expectEqual(ConnectResult.host_unreachable, parseReply(&.{ 0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    try std.testing.expectEqual(ConnectResult.refused, parseReply(&.{ 0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    try std.testing.expectEqual(ConnectResult.ttl, parseReply(&.{ 0x05, 0x06, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    // REP=1 generic
    try std.testing.expectEqual(ConnectResult.generic_fail, parseReply(&.{ 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }).?);
    // ATYP=3 домен: неполный кадр → null, полный → ok
    const dom = [_]u8{ 0x05, 0x00, 0x00, 0x03, 4, 't', 'o', 'r', 0, 0, 0, 0 };
    try std.testing.expect(parseReply(dom[0 .. dom.len - 2]) == null);
    try std.testing.expectEqual(ConnectResult.ok, parseReply(&dom).?);
    // ATYP=4 ipv6: 22 байта
    var v6: [22]u8 = undefined;
    v6[0] = 0x05;
    v6[1] = 0x00;
    v6[2] = 0;
    v6[3] = 0x04;
    try std.testing.expectEqual(ConnectResult.ok, parseReply(&v6).?);
    try std.testing.expect(parseReply(v6[0 .. v6.len - 1]) == null);
    // чужая версия протокола
    try std.testing.expect(parseReply(&.{ 0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }) == null);
}

test "handshake: обмен с фейковым прокси" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const listen_addr = server.listen_address;
    const th = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.net.Server) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();
            const st = conn.stream;
            var srb: [1024]u8 = undefined;
            var swb: [1024]u8 = undefined;
            var srd = std.net.Stream.reader(st, &srb);
            const ri = srd.interface();
            var swr = std.net.Stream.writer(st, &swb);
            const wi = &swr.interface;

            var b: [3]u8 = undefined;
            ri.readSliceAll(&b) catch return; // приветствие
            wi.writeAll(&.{ 0x05, 0x00 }) catch return; // no-auth
            wi.flush() catch return;
            var req: [18]u8 = undefined; // 7 + len("example.org")
            ri.readSliceAll(&req) catch return; // CONNECT
            // проверяем домен и порт в запросе
            if (req[3] != 0x03) return;
            if (!std.mem.eql(u8, req[5 .. 5 + req[4]], "example.org")) return;
            const port = std.mem.readInt(u16, req[5 + req[4] ..][0..2], .big);
            if (port != 443) return;
            wi.writeAll(&.{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }) catch return;
            wi.flush() catch return;
        }
    }.run, .{&server});
    defer th.join();

    const stream = try std.net.tcpConnectToAddress(listen_addr);
    defer stream.close();
    try handshake(stream, "example.org", 443);
}
