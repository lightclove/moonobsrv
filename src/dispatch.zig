//! Общая обработка одного обновления Telegram — используется и циклом
//! long polling, и webhook-сервером. Здесь: доступ (whitelist/заявки),
//! маршрутизация команд, callback_query (гид/меню/заявки).

const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig").log;
const router = @import("bot/router.zig");
const features = @import("features/features.zig");
const storemod = @import("bot/store.zig");
const tg = @import("bot/telegram.zig");
const access = @import("bot/access.zig");
const cb = @import("bot/cb.zig");
const wizard = @import("features/wizard.zig");

/// Полное обновление (сообщение или callback_query).
pub fn handleUpdate(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    st: *storemod.Store,
    api: *tg.Api,
    upd: *const tg.Update,
) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    if (upd.callback_query) |c| {
        const chat_id: ?i64 = if (c.message) |m| m.chat.id else null;
        const message_id: ?i64 = if (c.message) |m| m.message_id else null;
        const data = c.data orelse "";
        if (data.len == 0) {
            api.answerCallbackQuery(c.id, "", false);
            return;
        }
        _ = @import("bot/wd.zig").beat();
        _ = cb.handle(
            .{ .alloc = arena.allocator(), .now = std.time.timestamp(), .cfg = cfg, .store = st, .api = api },
            c.id,
            c.from.id,
            chat_id,
            message_id,
            data,
        );
        return;
    }
    const msg = upd.message orelse return;
    const text = msg.text orelse return;
    handleMessage(alloc, cfg, st, api, msg.chat.id, if (msg.from) |f| f.id else null, msg.from, text);
}

pub fn handleMessage(
    alloc: std.mem.Allocator,
    cfg: *const config.Config,
    st: *storemod.Store,
    api: *tg.Api,
    chat_id: i64,
    from_id: ?i64,
    from: ?tg.From,
    text: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    var reply_html = false;

    const base = router.Base{
        .alloc = a,
        .now = std.time.timestamp(),
        .cfg = cfg,
        .store = st,
        .api = api,
    };

    if (router.match(&features.commands, text)) |m| {
        var label_buf: [96]u8 = undefined;
        var label: []const u8 = "";
        if (from) |f| {
            label = access.displayLabel(f.username, f.first_name, f.id, &label_buf);
        }
        var ctx = router.Ctx{
            .base = base,
            .chat_id = chat_id,
            .from_id = from_id,
            .from_label = label,
            .raw_text = text,
            .reply = &aw.writer,
            .cmd = m.cmd,
            .args = m.args,
        };

        // гейт доступа: заявки/отказы до выполнения команды
        if (cfg.adminMode() and st.dbMode() and from_id != null) {
            const uid = from_id.?;
            const known = uid == cfg.admin_id or st.isActive(uid);
            if (!known) {
                const flow = access.handleUnknown(&ctx) catch {
                    ctx.reply.print("⚠ Не удалось оформить заявку, попробуйте позже.", .{}) catch {};
                    sendReply(api, chat_id, aw.written(), false);
                    return;
                };
                if (flow == .handled) {
                    sendReply(api, chat_id, aw.written(), false);
                    return;
                }
            }
        }

        m.cmd.handler(&ctx) catch |e| {
            log("команда {s}: {s}", .{ m.cmd.name, @errorName(e) });
            // хендлер мог оставить внятный текст (подсказка о формате даты
            // из Ctx.moment и т.п.) — отправляем его, шаблонный текст только
            // когда ответ пуст
            if (aw.written().len > 0) {
                sendReply(api, chat_id, aw.written(), ctx.reply_html);
            } else {
                var ebuf: [128]u8 = undefined;
                var ew: std.Io.Writer = .fixed(&ebuf);
                ew.print("⚠ Внутренняя ошибка, попробуйте позже.", .{}) catch {};
                api.sendMessage(chat_id, ew.buffered()) catch {};
            }
            return;
        };
        reply_html = ctx.reply_html;
    } else if (text.len > 0 and text[0] == '/') {
        // неизвестная команда — предлагаем гид (как rbot)
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("Неизвестная команда.\n\nНовичкам — обучающий гид: /wizard\nКороткое меню: /help", .{}) catch return;
        var kb: [512]u8 = undefined;
        var kw: std.Io.Writer = .fixed(&kb);
        wizard.openKb(&kw) catch {};
        _ = api.sendMessageOpts(chat_id, w.buffered(), true, kw.buffered()) catch {};
        return;
    } else {
        return; // обычное сообщение — игнорируем
    }

    sendReply(api, chat_id, aw.written(), reply_html);
}

fn sendReply(api: *tg.Api, chat_id: i64, out: []const u8, html: bool) void {
    if (out.len == 0) return;
    // лимит Telegram — 4096 символов; режем с запасом на границе UTF-8
    var cut = @min(out.len, 3900);
    while (cut > 0 and (out[cut] & 0xC0) == 0x80) cut -= 1;
    _ = api.sendMessageOpts(chat_id, out[0..cut], html, null) catch |e| {
        log("sendMessage: {s}", .{@errorName(e)});
    };
}
