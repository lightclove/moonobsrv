//! Клиент Telegram Bot API на собственном HTTPS-транспорте (net/https):
//! прямое соединение или через SOCKS5/Tor. Один клиент с прокси (основной
//! трафик), один без (алерты при падении Tor). Все вызовы под мьютексом —
//! боту хватает последовательного доступа (как в rbot: один long poll).
//!
//! 409 Conflict фатален: один токен = один polling — вызывающий код
//! завершает процесс с кодом 2.

const std = @import("std");
const https = @import("../net/https.zig");
const config = @import("../config.zig");

const api_host = "api.telegram.org";
// Один список апдейтов для polling и webhook: без callback_query в webhook-
// режиме молча умирают все кнопки (гид, меню, заявки).
const allowed_updates_list = [_][]const u8{ "message", "callback_query" };
const allowed_updates_enc = "%5B%22message%22%2C%22callback_query%22%5D"; // ["message","callback_query"]

pub const From = struct {
    id: i64,
    username: ?[]const u8 = null,
    first_name: ?[]const u8 = null,
};

pub const Update = struct {
    update_id: i64,
    message: ?struct {
        chat: struct { id: i64 },
        from: ?From = null,
        text: ?[]const u8 = null,
        date: i64 = 0,
    } = null,
    callback_query: ?struct {
        id: []const u8,
        from: From,
        message: ?struct {
            chat: struct { id: i64 },
            message_id: i64,
        } = null,
        data: ?[]const u8 = null,
    } = null,
};

pub const Button = struct {
    text: []const u8,
    data: []const u8,
};

/// inline-клавиатура: строки кнопок → JSON-строка (не экранированный объект).
pub fn ik(out: *std.Io.Writer, rows: []const []const Button) !void {
    try out.writeAll("{\"inline_keyboard\":[");
    for (rows, 0..) |row, ri| {
        if (ri > 0) try out.writeByte(',');
        try out.writeByte('[');
        for (row, 0..) |btn, bi| {
            if (bi > 0) try out.writeByte(',');
            try out.writeAll("{\"text\":");
            try std.json.Stringify.value(btn.text, .{}, out);
            try out.writeAll(",\"callback_data\":");
            try std.json.Stringify.value(btn.data, .{}, out);
            try out.writeByte('}');
        }
        try out.writeByte(']');
    }
    try out.writeAll("]}");
}

pub const Api = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    main: https.Client,
    direct: https.Client,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, token: []const u8, proxy: ?config.Config.Socks) Api {
        return .{
            .allocator = allocator,
            .token = token,
            .main = https.Client.init(allocator, proxy),
            .direct = https.Client.init(allocator, null),
        };
    }

    pub fn deinit(self: *Api) void {
        self.main.deinit();
        self.direct.deinit();
    }

    /// Вызов метода через основной (проксированный) клиент; тело ответа —
    /// выделенная строка (освобождается вызывающим через alloc.free).
    pub fn requestOwned(self: *Api, method: []const u8, query: ?[]const u8, payload: ?[]const u8) ![]u8 {
        var pbuf: [512]u8 = undefined;
        var path: std.Io.Writer = .fixed(&pbuf);
        try path.print("/bot{s}/{s}", .{ self.token, method });
        if (query) |q| try path.print("?{s}", .{q});
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        const status = try self.main.request(.{
            .method = if (payload != null) "POST" else "GET",
            .host = api_host,
            .path = path.buffered(),
            .body = payload,
        }, &aw);
        if (status != 200) {
            const conflict = std.mem.indexOf(u8, aw.written(), "\"error_code\":409") != null or
                std.mem.indexOf(u8, aw.written(), "\"error_code\": 409") != null or status == 409;
            if (conflict) return error.TelegramConflict;
            return error.TelegramHttp;
        }
        return try aw.toOwnedSlice();
    }

    /// Тело ответа getUpdates (JSON) как выделенная строка.
    pub fn getUpdatesOwned(self: *Api, offset: i64, timeout_s: u32) ![]u8 {
        var qbuf: [96]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "timeout={d}&offset={d}&allowed_updates={s}", .{ timeout_s, offset, allowed_updates_enc }) catch return error.OutOfMemory;
        return self.requestOwned("getUpdates", q, null);
    }

    /// Подтверждение очереди до offset-1 без ожидания (стоп-кран/ACK перед
    /// рестартом — иначе Telegram пришлёт те же апдейты снова).
    pub fn ack(self: *Api, offset: i64) !void {
        var qbuf: [64]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "timeout=0&offset={d}", .{offset}) catch return error.OutOfMemory;
        const resp = self.requestOwned("getUpdates", q, null) catch return;
        self.allocator.free(resp);
    }

    pub fn sendMessage(self: *Api, chat_id: i64, text: []const u8) !void {
        _ = try self.sendMessageOpts(chat_id, text, false, null);
    }

    /// sendMessage с HTML и/или клавиатурой; возвращает message_id.
    pub fn sendMessageOpts(self: *Api, chat_id: i64, text: []const u8, html: bool, kb: ?[]const u8) !i64 {
        var bbuf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&bbuf);
        try w.print("{{\"chat_id\":{d},\"text\":", .{chat_id});
        try std.json.Stringify.value(text, .{}, &w);
        try w.writeAll(",\"disable_web_page_preview\":true");
        if (html) try w.writeAll(",\"parse_mode\":\"HTML\"");
        if (kb) |k| {
            try w.writeAll(",\"reply_markup\":");
            try w.writeAll(k);
        }
        try w.writeByte('}');
        const resp = try self.requestOwned("sendMessage", null, w.buffered());
        defer self.allocator.free(resp);
        try expectOk(resp);
        return messageIdOf(resp) orelse 0;
    }

    /// editMessageText; false — сообщение не найдено/не текст (вызывающий
    /// откатывается на отправку нового).
    pub fn editMessageText(self: *Api, chat_id: i64, message_id: i64, text: []const u8, html: bool, kb: ?[]const u8) !bool {
        var bbuf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&bbuf);
        try w.print("{{\"chat_id\":{d},\"message_id\":{d},\"text\":", .{ chat_id, message_id });
        try std.json.Stringify.value(text, .{}, &w);
        try w.writeAll(",\"disable_web_page_preview\":true");
        if (html) try w.writeAll(",\"parse_mode\":\"HTML\"");
        if (kb) |k| {
            try w.writeAll(",\"reply_markup\":");
            try w.writeAll(k);
        }
        try w.writeByte('}');
        const resp = self.requestOwned("editMessageText", null, w.buffered()) catch return false;
        defer self.allocator.free(resp);
        const P = struct { ok: bool = false };
        const parsed = std.json.parseFromSlice(P, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch return false;
        defer parsed.deinit();
        return parsed.value.ok;
    }

    /// Гасит «часики» на кнопке; text показывается тостом или модалькой.
    pub fn answerCallbackQuery(self: *Api, cb_id: []const u8, text: []const u8, alert: bool) void {
        var bbuf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&bbuf);
        w.writeAll("{\"callback_query_id\":") catch return;
        std.json.Stringify.value(cb_id, .{}, &w) catch return;
        if (text.len > 0) {
            w.writeAll(",\"text\":") catch return;
            std.json.Stringify.value(text, .{}, &w) catch return;
        }
        if (alert) w.writeAll(",\"show_alert\":true") catch return;
        w.writeByte('}') catch return;
        const resp = self.requestOwned("answerCallbackQuery", null, w.buffered()) catch return;
        self.allocator.free(resp);
    }

    /// Алерт админу в обход прокси (Tor упал, а сеть жива): direct-клиент.
    pub fn alertDirect(self: *Api, chat_id: i64, text: []const u8) void {
        var pbuf: [256]u8 = undefined;
        var path: std.Io.Writer = .fixed(&pbuf);
        path.print("/bot{s}/sendMessage", .{self.token}) catch return;
        var bbuf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&bbuf);
        w.print("{{\"chat_id\":{d},\"text\":", .{chat_id}) catch return;
        std.json.Stringify.value(text, .{}, &w) catch return;
        w.writeByte('}') catch return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.direct.request(.{
            .method = "POST",
            .host = api_host,
            .path = path.buffered(),
            .body = w.buffered(),
        }, &aw) catch return;
    }

    pub fn setWebhook(self: *Api, url: []const u8, secret: []const u8) ![]u8 {
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .url = url,
            .secret_token = if (secret.len > 0) secret else null,
            .allowed_updates = allowed_updates_list,
            .drop_pending_updates = false,
        }, .{});
        defer self.allocator.free(body);
        return self.requestOwned("setWebhook", null, body);
    }

    pub fn deleteWebhook(self: *Api) ![]u8 {
        return self.requestOwned("deleteWebhook", null, "{}");
    }

    pub fn getWebhookInfoOwned(self: *Api) ![]u8 {
        return self.requestOwned("getWebhookInfo", null, null);
    }

    fn expectOk(resp: []const u8) !void {
        const P = struct { ok: bool = false };
        const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, resp, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        if (!parsed.value.ok) return error.TelegramApi;
    }

    fn messageIdOf(resp: []const u8) ?i64 {
        const P = struct { result: ?struct { message_id: i64 = 0 } = null };
        const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, resp, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        return parsed.value.result.?.message_id;
    }
};

/// Разбирает ответ getUpdates. Все строки копируются в арены вызывающего
/// (арены цикла хватает на всю обработку пачки) — поэтому Leaky: собственная
/// арена parseFromSlice умерла бы ВМЕСТЕ со строками, и msg.text стал бы
/// висячим указателем (краш на первом же сообщении — ловили на проде).
pub fn parseUpdates(alloc: std.mem.Allocator, bytes: []const u8) ![]Update {
    const P = struct { ok: bool = false, result: []Update = &.{} };
    const parsed = try std.json.parseFromSliceLeaky(P, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always, // не ссылаться на буфер ответа
    });
    if (!parsed.ok) return error.TelegramApi;
    return parsed.result;
}

/// Разбирает тело webhook-запроса (одиночный объект Update).
/// Строки ссылаются на `bytes`.
pub fn parseUpdate(alloc: std.mem.Allocator, bytes: []const u8) !Update {
    return std.json.parseFromSliceLeaky(Update, alloc, bytes, .{ .ignore_unknown_fields = true });
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "ik: клавиатура собирается в валидный JSON" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const rows = [_][]const Button{
        &.{ .{ .text = "⬅️ Назад", .data = "wiz:p:0" }, .{ .text = "Далее ➡️", .data = "wiz:p:2" } },
        &.{.{ .text = "📚 Оглавление", .data = "wiz:toc" }},
    };
    try ik(&w, &rows);
    const s = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, s, "{\"inline_keyboard\":[[{\"text\":\"⬅️ Назад\",\"callback_data\":\"wiz:p:0\"}"));
    try std.testing.expect(std.mem.indexOf(u8, s, "[{\"text\":\"📚 Оглавление\",\"callback_data\":\"wiz:toc\"}]") != null);
    try std.testing.expect(std.mem.endsWith(u8, s, "]}"));
    // валидный JSON целиком
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, s, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "parseUpdates: сообщения и callback_query" {
    const body =
        \\{"ok":true,"result":[
        \\ {"update_id":10,"message":{"chat":{"id":42},"from":{"id":42,"first_name":"Аня"},"text":"/voc","date":1700000000}},
        \\ {"update_id":11,"callback_query":{"id":"cb1","from":{"id":7,"username":"bob"},"message":{"chat":{"id":7},"message_id":55},"data":"wiz:p:3"}}
        \\]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ups = try parseUpdates(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), ups.len);
    try std.testing.expectEqual(@as(i64, 10), ups[0].update_id);
    try std.testing.expectEqualStrings("/voc", ups[0].message.?.text.?);
    try std.testing.expectEqual(@as(i64, 42), ups[0].message.?.from.?.id);
    const cb = ups[1].callback_query.?;
    try std.testing.expectEqualStrings("cb1", cb.id);
    try std.testing.expectEqual(@as(i64, 7), cb.from.id);
    try std.testing.expectEqual(@as(i64, 55), cb.message.?.message_id);
    try std.testing.expectEqualStrings("wiz:p:3", cb.data.?);
}

test "parseUpdates: not ok → ошибка" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.TelegramApi, parseUpdates(arena.allocator(), "{\"ok\":false,\"error_code\":409}"));
}

test "parseUpdates: строки живут в арены вызывающего, а не в буфере ответа" {
    // регрессия прод-краша: parseFromSlice+deinit оставляли msg.text висячим.
    // Здесь: портили буфер ПОСЛЕ парсинга — строки обязаны уцелеть.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = try a.dupe(u8, "{\"ok\":true,\"result\":[{\"update_id\":7,\"message\":{\"chat\":{\"id\":1},\"from\":{\"id\":1,\"first_name\":\"Аня\"},\"text\":\"/start\"}}]}");
    const ups = try parseUpdates(a, buf);
    try std.testing.expectEqual(@as(usize, 1), ups.len);
    // затираем исходный буфер — строки спрятаны в арене
    @memset(buf, 'X');
    try std.testing.expectEqualStrings("/start", ups[0].message.?.text.?);
    try std.testing.expectEqualStrings("Аня", ups[0].message.?.from.?.first_name.?);
}

test "конфликт 409 ищется в теле ответа" {
    const body = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict: terminated by other getUpdates request\"}";
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error_code\":409") != null);
}

test "webhook подписан и на callback_query (BUG-021)" {
    try std.testing.expectEqual(@as(usize, 2), allowed_updates_list.len);
    try std.testing.expectEqualStrings("message", allowed_updates_list[0]);
    try std.testing.expectEqualStrings("callback_query", allowed_updates_list[1]);
    // и кодированная форма для getUpdates соответствует тому же списку
    try std.testing.expect(std.mem.indexOf(u8, allowed_updates_enc, "callback_query") != null);
}
