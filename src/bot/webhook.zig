//! Приём webhook'ов Telegram: минимальный HTTP/1.1-сервер на std.http.Server.
//! Telegram требует HTTPS с публичным сертификатом, а std.crypto.tls не умеет
//! серверную сторону — поэтому слушаем обычный HTTP за TLS-терминатором
//! (nginx/caddy/cloudflared/облачный балансировщик), см. README.

const std = @import("std");
const config = @import("../config.zig");
const dispatch = @import("../dispatch.zig");
const log = @import("../log.zig").log;
const storemod = @import("store.zig");
const tg = @import("telegram.zig");

pub fn serve(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, api: *tg.Api) !void {
    // Ожидаемый путь запроса берём из публичного URL (например /tg/abc).
    var path: []const u8 = "/";
    if (std.mem.indexOf(u8, cfg.webhook_url, "://")) |scheme_end| {
        const rest = cfg.webhook_url[scheme_end + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| path = rest[slash..];
    }

    const addr = parseListen(cfg.listen) catch {
        log("webhook: не разобран MOONOBSRV_LISTEN={s} (формат 1.2.3.4:8080)", .{cfg.listen});
        return error.BadListen;
    };
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    log("webhook: слушаю {s}, путь {s}", .{ cfg.listen, path });

    while (true) {
        const conn = listener.accept() catch |e| {
            log("webhook: accept: {s}", .{@errorName(e)});
            std.Thread.sleep(std.time.ns_per_s);
            continue;
        };
        handleConnection(alloc, cfg, st, api, conn, path) catch |e| {
            log("webhook: соединение: {s}", .{@errorName(e)});
        };
        conn.stream.close();
    }
}

fn parseListen(s: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadListen;
    const port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10);
    const host = s[0..colon];
    if (host.len == 0) return std.net.Address.parseIp("0.0.0.0", port);
    return std.net.Address.parseIp(host, port);
}

fn handleConnection(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    st: *storemod.Store,
    api: *tg.Api,
    conn: std.net.Server.Connection,
    path: []const u8,
) !void {
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var sreader = conn.stream.reader(&rbuf);
    var swriter = conn.stream.writer(&wbuf);
    var server = std.http.Server.init(sreader.interface(), &swriter.interface);

    // keep-alive: несколько запросов на одном соединении
    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch return;
        handleRequest(alloc, cfg, st, api, &req, path) catch |e| {
            log("webhook: запрос: {s}", .{@errorName(e)});
            req.respond("error", .{ .status = .internal_server_error }) catch {};
            return;
        };
    }
}

fn handleRequest(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    st: *storemod.Store,
    api: *tg.Api,
    req: *std.http.Server.Request,
    path: []const u8,
) !void {
    if (req.head.method != .POST) {
        try req.respond("ok", .{ .status = .ok });
        return;
    }
    if (!std.mem.eql(u8, req.head.target, path)) {
        try req.respond("not found", .{ .status = .not_found });
        return;
    }

    // Секрет из setWebhook: Telegram дублирует его в заголовке каждого запроса.
    if (cfg.webhook_secret.len > 0) {
        var authed = false;
        var it = req.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-telegram-bot-api-secret-token") and
                std.mem.eql(u8, h.value, cfg.webhook_secret))
            {
                authed = true;
            }
        }
        if (!authed) {
            log("webhook: отклонён запрос с неверным секретом", .{});
            try req.respond("forbidden", .{ .status = .forbidden });
            return;
        }
    }

    var bbuf: [4096]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&bbuf);
    const body = try body_reader.allocRemaining(alloc, .limited(4 << 20));
    defer alloc.free(body);

    // Telegram ждёт быстрого 200 — подтверждаем до обработки.
    try req.respond("OK", .{ .status = .ok });

    const update = tg.parseUpdate(alloc, body) catch {
        log("webhook: не разобрано тело обновления ({d} байт)", .{body.len});
        return;
    };
    dispatch.handleUpdate(alloc, cfg, st, api, &update);
}
