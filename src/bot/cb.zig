//! Роутер callback_query: wiz:* (гид), menu:* (меню команд), acl:* (заявки).
//! Каждый колбэк обязан получить answerCallbackQuery — иначе на кнопке
//! навсегда останутся «часики». Гид редактирует то же сообщение.

const std = @import("std");
const router = @import("router.zig");
const tg = @import("telegram.zig");
const access = @import("access.zig");
const wizard = @import("../features/wizard.zig");
const features = @import("../features/features.zig");
const storemod = @import("store.zig");

/// Обработка одного callback_query. true — распознан.
pub fn handle(base: router.Base, cb_id: []const u8, from_id: i64, chat_id: ?i64, message_id: ?i64, data: []const u8) bool {
    // заявки обрабатываются до проверки whitelist: админ и так «свой»
    if (access.onAclCallback(base, cb_id, from_id, data)) return true;

    const api = base.api;
    if (base.cfg.adminMode() and base.store.dbMode()) {
        const uid_ok = from_id == base.cfg.admin_id or base.store.isActive(from_id);
        if (!uid_ok) {
            api.answerCallbackQuery(cb_id, "Нет доступа", true);
            return true;
        }
    }

    const admin = base.cfg.admin_id != 0 and from_id == base.cfg.admin_id;

    if (std.mem.eql(u8, data, "wiz:close")) {
        if (chat_id != null and message_id != null) {
            var buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            wizard.closeText(&w) catch {};
            const edited = api.editMessageText(chat_id.?, message_id.?, w.buffered(), true, null) catch false;
            if (!edited) _ = api.sendMessageOpts(chat_id.?, w.buffered(), true, null) catch {};
        }
        api.answerCallbackQuery(cb_id, "Закрыто", false);
        return true;
    }
    if (std.mem.eql(u8, data, "wiz:toc")) {
        showToc(base, cb_id, chat_id, message_id, 0, admin);
        return true;
    }
    if (std.mem.startsWith(u8, data, "wiz:toc:")) {
        const page = std.fmt.parseInt(usize, data[8..], 10) catch 0;
        showToc(base, cb_id, chat_id, message_id, page, admin);
        return true;
    }
    if (std.mem.startsWith(u8, data, "wiz:p:")) {
        const i = std.fmt.parseInt(usize, data[6..], 10) catch 0;
        if (chat_id != null and message_id != null) {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            wizard.render(&w, i, admin) catch {};
            var kb: [1024]u8 = undefined;
            var kw: std.Io.Writer = .fixed(&kb);
            wizard.nav(&kw, i, admin) catch {};
            const edited = api.editMessageText(chat_id.?, message_id.?, w.buffered(), true, kw.buffered()) catch false;
            if (!edited) _ = api.sendMessageOpts(chat_id.?, w.buffered(), true, kw.buffered()) catch {};
        }
        api.answerCallbackQuery(cb_id, "", false);
        return true;
    }
    if (std.mem.eql(u8, data, "menu:main") or std.mem.startsWith(u8, data, "menu:")) {
        onMenu(base, cb_id, chat_id, message_id, data, admin);
        return true;
    }
    api.answerCallbackQuery(cb_id, "", false); // неизвестный — просто гасим часики
    return true;
}

fn showToc(base: router.Base, cb_id: []const u8, chat_id: ?i64, message_id: ?i64, page: usize, admin: bool) void {
    const api = base.api;
    if (chat_id != null and message_id != null) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        wizard.renderToc(&w, page, admin) catch {};
        var kb: [2048]u8 = undefined;
        var kw: std.Io.Writer = .fixed(&kb);
        wizard.tocKb(&kw, page, admin) catch {};
        const edited = api.editMessageText(chat_id.?, message_id.?, w.buffered(), true, kw.buffered()) catch false;
        if (!edited) _ = api.sendMessageOpts(chat_id.?, w.buffered(), true, kw.buffered()) catch {};
    }
    api.answerCallbackQuery(cb_id, "", false);
}

/// menu:main — список быстрых команд; menu:cmd:<имя> — исполнить команду.
fn onMenu(base: router.Base, cb_id: []const u8, chat_id: ?i64, message_id: ?i64, data: []const u8, admin: bool) void {
    const api = base.api;
    if (std.mem.eql(u8, data, "menu:main")) {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        wizard.helpText(&w, admin) catch {};
        var kb: [512]u8 = undefined;
        var kw: std.Io.Writer = .fixed(&kb);
        menuKb(&kw) catch {};
        if (chat_id != null and message_id != null) {
            const edited = api.editMessageText(chat_id.?, message_id.?, w.buffered(), true, kw.buffered()) catch false;
            if (!edited) _ = api.sendMessageOpts(chat_id.?, w.buffered(), true, kw.buffered()) catch {};
        }
        api.answerCallbackQuery(cb_id, "", false);
        return;
    }
    if (std.mem.startsWith(u8, data, "menu:cmd:")) {
        const cmd_name = data[9..];
        if (chat_id == null) {
            api.answerCallbackQuery(cb_id, "Нет чата", true);
            return;
        }
        if (router.match(&features.commands, cmd_name)) |m| {
            var arena = std.heap.ArenaAllocator.init(base.alloc);
            defer arena.deinit();
            var aw: std.Io.Writer.Allocating = .init(arena.allocator());
            var ctx = router.Ctx{
                .base = .{
                    .alloc = arena.allocator(),
                    .now = std.time.timestamp(),
                    .cfg = base.cfg,
                    .store = base.store,
                    .api = base.api,
                },
                .chat_id = chat_id.?,
                .from_id = null,
                .reply = &aw.writer,
                .cmd = m.cmd,
                .args = m.args,
            };
            m.cmd.handler(&ctx) catch {
                api.answerCallbackQuery(cb_id, "Ошибка", true);
                return;
            };
            const out = aw.written();
            if (out.len == 0) {
                api.answerCallbackQuery(cb_id, "", false);
                return;
            }
            var kb: [512]u8 = undefined;
            var kw: std.Io.Writer = .fixed(&kb);
            menuKb(&kw) catch {};
            if (message_id != null) {
                const edited = api.editMessageText(chat_id.?, message_id.?, out, false, kw.buffered()) catch false;
                if (edited) {
                    api.answerCallbackQuery(cb_id, "", false);
                    return;
                }
            }
            _ = api.sendMessageOpts(chat_id.?, out, false, kw.buffered()) catch {};
            api.answerCallbackQuery(cb_id, "", false);
            return;
        }
        api.answerCallbackQuery(cb_id, "Неизвестная команда", true);
        return;
    }
    api.answerCallbackQuery(cb_id, "", false);
}

/// Меню быстрых команд — пункты, которых нет в rbot.
pub fn menuKb(w: *std.Io.Writer) !void {
    try w.writeAll("{\"inline_keyboard\":[[");
    try btn(w, "🌑 Луна сейчас", "menu:cmd:/voc");
    try w.writeAll("],[");
    try btn(w, "☿ Меркурий", "menu:cmd:/mercury");
    try w.writeAll("],[");
    try btn(w, "🌗 Лунный день", "menu:cmd:/day");
    try w.writeAll("],[");
    try btn(w, "🪐 Планеты", "menu:cmd:/planets");
    try w.writeAll("],[");
    try btn(w, "🔔 Подписка", "menu:cmd:/subscribe");
    try w.writeAll("],[");
    try btn(w, "🚀 Гид", "wiz:p:0");
    try w.writeAll("]]}");
}

fn btn(w: *std.Io.Writer, text: []const u8, data: []const u8) !void {
    try w.writeAll("{\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.print(",\"callback_data\":\"{s}\"}}", .{data});
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "menuKb: валидный JSON с короткими callback_data" {
    var kb: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&kb);
    try menuKb(&w);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "menu:cmd:/voc") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "menu:cmd:/subscribe") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "wiz:p:0") != null);
}
