//! Контроль доступа: whitelist в Postgres, заявки админу с кнопками
//! «Пустить / Отклонить» (acl:allow:ID / acl:deny:ID). Без БД бот открыт —
//! режим разработки. Порт механики rbot: denied молчит до /start,
//! повторные заявки не спамят админа.

const std = @import("std");
const router = @import("router.zig");
const tg = @import("telegram.zig");
const storemod = @import("store.zig");
const log = @import("../log.zig").log;

/// Метка пользователя для карточки: @username → имя → id:N.
pub fn displayLabel(username: ?[]const u8, first_name: ?[]const u8, id: i64, buf: []u8) []const u8 {
    if (username) |u| {
        if (u.len > 0) return std.fmt.bufPrint(buf, "@{s}", .{u}) catch fallback(id, buf);
    }
    if (first_name) |f| {
        if (f.len > 0) return std.fmt.bufPrint(buf, "{s}", .{f}) catch fallback(id, buf);
    }
    return fallback(id, buf);
}

fn fallback(id: i64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "id:{d}", .{id}) catch "?";
}

/// Экранирование HTML (&, <, >) — для пользовательских строк.
pub fn htmlEscape(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            else => try out.writeByte(ch),
        }
    }
}

pub const UnknownFlow = enum { pass_through, handled };

/// Сообщение от неизвестного пользователя (личный чат): либо вежливый отказ,
/// либо заявка админу. pass_through — пользователь уже «свой», обрабатывать
/// команду обычно.
pub fn handleUnknown(ctx: *router.Ctx) !UnknownFlow {
    const cfg = ctx.base.cfg;
    if (!cfg.adminMode() or !ctx.base.store.dbMode()) {
        // нет админского контура — бот открыт (разработка)
        return .pass_through;
    }
    if (ctx.from_id == null) return .pass_through;
    const uid = ctx.from_id.?;

    var sbuf: [128]u8 = undefined;
    switch (ctx.base.store.statusOf(uid, &sbuf)) {
        .active => return .pass_through, // уже внутри — обычная обработка
        .denied => {
            try ctx.reply.writeAll("Доступ отклонён.");
            return .handled;
        },
        .pending => {
            try ctx.reply.writeAll("Заявка уже на рассмотрении. Ждите решения.");
            return .handled;
        },
    }

    const notify = ctx.base.store.requestAccess(uid, ctx.from_label);
    if (!notify) {
        try ctx.reply.writeAll("Заявка отправлена админу. Ждите решения.");
        return .handled;
    }

    // карточка админу
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("Заявка на доступ\n\nкто: ");
    try htmlEscape(&w, ctx.from_label);
    try w.print("\nid: <code>{d}</code>\nсообщение:\n<code>", .{uid});
    var preview = ctx.raw_text;
    if (preview.len == 0) preview = "(без текста)";
    if (preview.len > 200) preview = preview[0..200];
    try htmlEscape(&w, preview);
    try w.writeAll("</code>");
    var kb: [256]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kb);
    var ab: [48]u8 = undefined;
    var db: [48]u8 = undefined;
    const allow = std.fmt.bufPrint(&ab, "acl:allow:{d}", .{uid}) catch "";
    const deny = std.fmt.bufPrint(&db, "acl:deny:{d}", .{uid}) catch "";
    try kw.print("{{\"inline_keyboard\":[[{{\"text\":\"Пустить\",\"callback_data\":\"{s}\"}},{{\"text\":\"Отклонить\",\"callback_data\":\"{s}\"}}]]}}", .{ allow, deny });
    _ = ctx.base.api.sendMessageOpts(cfg.admin_id, w.buffered(), true, kw.buffered()) catch {
        log("заявка: не доставлена админу", .{});
    };
    try ctx.reply.writeAll("Заявка отправлена админу. Ждите решения.");
    return .handled;
}

/// Обработка acl:allow:ID / acl:deny:ID. true — колбэк распознан.
pub fn onAclCallback(base: router.Base, cb_id: []const u8, from_id: i64, data: []const u8) bool {
    const api = base.api;
    const cfg = base.cfg;
    if (!std.mem.startsWith(u8, data, "acl:")) return false;
    if (cfg.admin_id == 0 or from_id != cfg.admin_id) {
        api.answerCallbackQuery(cb_id, "Только админ", true);
        return true;
    }
    const body = data[4..];
    const allow = std.mem.startsWith(u8, body, "allow:");
    const deny = std.mem.startsWith(u8, body, "deny:");
    if (!allow and !deny) {
        api.answerCallbackQuery(cb_id, "Неверный id", true);
        return true;
    }
    const id_str = body[if (allow) 6 else 4 ..];
    const uid = std.fmt.parseInt(i64, id_str, 10) catch {
        api.answerCallbackQuery(cb_id, "Неверный id", true);
        return true;
    };
    if (uid == cfg.admin_id) {
        api.answerCallbackQuery(cb_id, "Это админ", true);
        return true;
    }
    if (allow) {
        if (!base.store.allowUser(uid)) {
            api.answerCallbackQuery(cb_id, "Ошибка БД", true);
            return true;
        }
        api.answerCallbackQuery(cb_id, "Пущено", false);
        api.sendMessage(uid, "Доступ открыт. Небо на сейчас: /voc\nГид: /wizard") catch {};
    } else {
        if (base.store.isActive(uid)) {
            // denial не понижает active — только /revoke (защита от промаха)
            api.answerCallbackQuery(cb_id, "Уже в whitelist. Снять: /revoke", true);
            return true;
        }
        _ = base.store.denyUser(uid);
        api.answerCallbackQuery(cb_id, "Отклонено", false);
        api.sendMessage(uid, "Доступ отклонён.") catch {};
    }
    return true;
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "displayLabel: username > имя > id" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("@bob", displayLabel("bob", "Роберт", 7, &b));
    try std.testing.expectEqualStrings("Роберт", displayLabel(null, "Роберт", 7, &b));
    try std.testing.expectEqualStrings("Роберт", displayLabel("", "Роберт", 7, &b));
    try std.testing.expectEqualStrings("id:7", displayLabel(null, null, 7, &b));
    try std.testing.expectEqualStrings("id:7", displayLabel("", "", 7, &b));
}

test "htmlEscape" {
    var b: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try htmlEscape(&w, "a<b>&c");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;c", w.buffered());
    var w2: std.Io.Writer = .fixed(&b);
    try htmlEscape(&w2, "просто текст");
    try std.testing.expectEqualStrings("просто текст", w2.buffered());
}

test "callback-данные заявок ≤ 64 байт" {
    var b: [48]u8 = undefined;
    const d = std.fmt.bufPrint(&b, "acl:allow:{d}", .{-100200300400500}) catch "";
    try std.testing.expect(d.len <= 64);
}
