//! Перезапуск слоёв и стоп-краны: парсинг /restart*, план рестарта
//! (анти-бутлуп), /reset //hardreset. Механика перенесена из rbot:
//! ACK до docker-restart, маркер «уже перезапускались», пачка getUpdates
//! просматривается целиком до выполнения любого /restart.

const std = @import("std");
const wd = @import("wd.zig");
const mon = @import("mon.zig");
const tg = @import("telegram.zig");

pub const Target = enum {
    all,
    bot,
    postgres,
    tor,
    telegram, // не процесс — честный отказ
    wan,
    docker,
    disk,
    help,
};

/// /restart [все|bot|postgres|tor|...] и суффиксные формы /restartbot и т.д.
pub fn parseTarget(name: []const u8, args: []const u8) ?Target {
    if (!std.mem.startsWith(u8, name, "/restart")) return null;
    const suffix = name["/restart".len..];
    if (suffix.len == 0) {
        const arg = std.mem.trim(u8, args, " \t");
        if (arg.len == 0) return .all;
        if (eqAny(arg, &.{ "all", "все", "всё" })) return .all;
        if (eqAny(arg, &.{ "bot", "proc", "процесс" })) return .bot;
        if (eqAny(arg, &.{ "postgres", "pg", "db", "бд" })) return .postgres;
        if (eqAny(arg, &.{"tor"})) return .tor;
        if (eqAny(arg, &.{ "telegram", "tg" })) return .telegram;
        if (eqAny(arg, &.{"wan"})) return .wan;
        if (eqAny(arg, &.{"docker"})) return .docker;
        if (eqAny(arg, &.{ "disk", "диск" })) return .disk;
        return .help;
    }
    if (eqAny(suffix, &.{ "all", "все" })) return .all;
    if (eqAny(suffix, &.{ "bot", "proc", "process" })) return .bot;
    if (eqAny(suffix, &.{ "postgres", "pg", "db" })) return .postgres;
    if (eqAny(suffix, &.{"tor"})) return .tor;
    if (eqAny(suffix, &.{ "telegram", "tg" })) return .telegram;
    if (eqAny(suffix, &.{"wan"})) return .wan;
    if (eqAny(suffix, &.{"docker"})) return .docker;
    if (eqAny(suffix, &.{ "disk", "диск" })) return .disk;
    if (eqAny(suffix, &.{ "help", "хелп" })) return .help;
    return .help;
}

fn eqAny(s: []const u8, variants: []const []const u8) bool {
    for (variants) |v| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

/// Таргет требует работы с Docker.
pub fn needsWork(t: Target) bool {
    return switch (t) {
        .all, .bot, .postgres, .tor => true,
        else => false,
    };
}

/// Рестарт убьёт сам процесс бота.
pub fn killsSelf(t: Target) bool {
    return t == .all or t == .bot;
}

pub fn targetName(t: Target) []const u8 {
    return switch (t) {
        .all => "все слои",
        .bot => "процесс",
        .postgres => "postgres",
        .tor => "tor",
        .telegram => "telegram",
        .wan => "wan",
        .docker => "docker",
        .disk => "диск",
        .help => "справка",
    };
}

/// Маска битов, сбрасываемых перед рестартом (сэмпл для /idle*).
pub fn downMask(t: Target) i32 {
    return switch (t) {
        .all => mon.BIT_PG | mon.BIT_TOR | mon.BIT_TG,
        .bot => mon.BIT_TG,
        .postgres => mon.BIT_PG,
        .tor => mon.BIT_TOR | mon.BIT_TG, // вместе с tor рвётся long poll
        else => 0,
    };
}

pub const RestartPlan = union(enum) {
    /// Повтор из очереди: команда пришла до старта процесса, либо рестарт
    /// был только что — не крутим снова.
    skip_stale,
    bounce: struct { kills_self: bool },
    reply_only,
};

/// Решение по рестарту: replay-команды (msg_date < started) пропускаем;
/// без даты — свежесть маркера рестарта (< 90 с).
pub fn planRestart(t: Target, started: i64, msg_date: i64, bounce_age: ?i64) RestartPlan {
    if (needsWork(t) and skipRepeat(started, msg_date, bounce_age)) return .skip_stale;
    if (t == .help or !needsWork(t)) return .reply_only;
    return .{ .bounce = .{ .kills_self = killsSelf(t) } };
}

pub fn skipRepeat(started: i64, msg_date: i64, bounce_age: ?i64) bool {
    if (msg_date > 0) return msg_date < started;
    if (bounce_age) |age| return age < wd.TOR_RESTART_COOLDOWN_S;
    return false;
}

pub fn pendingText(t: Target) []const u8 {
    return switch (t) {
        .all => "принудительно перезапускаю слои…",
        .bot => "перезапускаю процесс…",
        .postgres => "перезапускаю postgres…",
        .tor => "перезапускаю tor…",
        else => "перезапускаю…",
    };
}

// ─── Стоп-краны ─────────────────────────────────────────────────────────────

pub const Brake = enum { reset, hard };

pub fn brakeFromCmd(name: []const u8) ?Brake {
    if (eqAny(name, &.{ "/reset", "/flush" })) return .reset;
    if (eqAny(name, &.{ "/hardreset", "/hard" })) return .hard;
    return null;
}

pub fn preferBrake(a: ?Brake, b: Brake) Brake {
    if (a == null) return b;
    if (a.? == .hard or b == .hard) return .hard;
    return .reset;
}

pub fn drainOffset(max_update_id: i64) i64 {
    return max_update_id +| 1;
}

pub const BatchBrake = struct {
    kind: Brake,
    chat_id: i64,
    max_id: i64,
    offset: i64,
};

/// Сканирует пачку getUpdates целиком ДО обработки: если от админа есть
/// /reset или /hardreset — весь пакет сбрасывается, /restart из него не
/// выполнится (иначе процесс умрёт в голове, до стоп-крана в хвосте).
pub fn batchBrake(updates: []const tg.Update, admin: i64) ?BatchBrake {
    if (admin == 0) return null;
    var found: ?Brake = null;
    var chat: i64 = 0;
    var max_id: i64 = 0;
    for (updates) |u| {
        if (u.update_id > max_id) max_id = u.update_id;
        const msg = u.message orelse continue;
        const from = msg.from orelse continue;
        if (from.id != admin) continue;
        const text = msg.text orelse continue;
        if (text.len == 0 or text[0] != '/') continue;
        var name = text;
        if (std.mem.indexOfScalar(u8, name, ' ')) |i| name = name[0..i];
        if (std.mem.indexOfScalar(u8, name, '@')) |i| name = name[0..i];
        if (brakeFromCmd(name)) |b| {
            found = if (found) |prev| preferBrake(prev, b) else b;
            chat = msg.chat.id;
        }
    }
    if (found) |b| return .{ .kind = b, .chat_id = chat, .max_id = max_id, .offset = drainOffset(max_id) };
    return null;
}

pub fn resetText(w: *std.Io.Writer, n: usize, hard: bool) !void {
    if (hard) {
        try w.print("🛑 <b>Жёсткий сброс</b>\nочередь Telegram подтверждена ({d}). /restart из пачки не выполняю.\nНепрочитанные команды из этой очереди потеряны.\nПерезапускаю процесс бота один раз.", .{n});
    } else {
        try w.print("🛑 <b>Сброс очереди</b>\nподтверждено апдейтов: {d}. /restart из пачки не выполняю.\nПроцесс не убиваю. Непрочитанные команды из этой очереди потеряны.\nЖивой срез: /monitor", .{n});
    }
}

// ─── Выполнение рестартов ───────────────────────────────────────────────────

pub const RestartResult = struct {
    ok: bool = false,
    /// Сообщение для строки отчёта.
    msg: []const u8 = "",
};

pub const RunOut = struct {
    /// Строка postgres (для .all) или рестартуемого слоя.
    first: RestartResult = .{},
    /// Строка tor (только для .all).
    tor: RestartResult = .{},
    /// Рестартуем сами себя — после отчёта процесс должен умереть.
    self_kill: bool = false,
};

/// Рестарт слоёв через Docker Engine API. Порядок (all): postgres → tor
/// (с ожиданием socks) → бот (сам, после ответа).
pub fn run(arena: std.mem.Allocator, t: Target, project: []const u8, proxy: ?wd.Socks) RunOut {
    switch (t) {
        .postgres => {
            const id = wd.composeId(arena, project, "db") orelse return .{ .first = missing(arena) };
            return .{ .first = bounceMsg(wd.dockerRestart(arena, id)) };
        },
        .tor => {
            const id = wd.composeId(arena, project, "tor") orelse return .{ .first = missing(arena) };
            const res = bounceMsg(wd.dockerRestart(arena, id));
            _ = wd.waitSocks(proxy);
            return .{ .first = res };
        },
        .bot => {
            return .{ .first = .{ .ok = true, .msg = "сейчас, после этого сообщения" }, .self_kill = true };
        },
        .all => {
            var out: RunOut = .{};
            if (wd.composeId(arena, project, "db")) |id| {
                out.first = bounceMsg(wd.dockerRestart(arena, id));
            } else {
                out.first = missing(arena);
            }
            wd.beat();
            if (wd.composeId(arena, project, "tor")) |id| {
                out.tor = bounceMsg(wd.dockerRestart(arena, id));
            } else {
                out.tor = missing(arena);
            }
            _ = wd.waitSocks(proxy);
            wd.beat();
            out.self_kill = true;
            return out;
        },
        else => return .{},
    }
}

fn bounceMsg(b: wd.Bounce) RestartResult {
    return switch (b) {
        .ok => .{ .ok = true, .msg = "OK, docker restart" },
        .fail => .{ .ok = false, .msg = "Docker API ответил ошибкой" },
        .sent => .{ .ok = true, .msg = "команда ушла в Docker (ответа нет — так бывает, если рестартуем себя)" },
        .no_docker => .{ .ok = false, .msg = "нет docker.sock — из этого процесса контейнеры не видны" },
        .missing => .{ .ok = false, .msg = "контейнер не найден" },
    };
}

fn missing(arena: std.mem.Allocator) RestartResult {
    if (comptime wd.has_docker_socket) {
        _ = arena;
        return .{ .ok = false, .msg = "контейнер не найден" };
    }
    return .{ .ok = false, .msg = "нет docker.sock — из этого процесса контейнеры не видны" };
}

pub fn unsupportedText(w: *std.Io.Writer, t: Target) !void {
    try w.print("🔄 Слой <b>{s}</b> перезапустить нельзя.\n", .{targetName(t)});
    switch (t) {
        .telegram => try w.writeAll("это внешний Bot API, своего процесса нет. Переподключить long poll: /restartbot"),
        .wan => try w.writeAll("это сеть хоста (пробы 1.1.1.1 / 8.8.8.8). Из бота интерфейс не поднять."),
        .disk => try w.writeAll("это файловая система хоста, не сервис."),
        .docker => try w.writeAll("демон Docker из контейнера не перезапускается. Контейнеры стека: /restartbot /restartpostgres /restarttor"),
        else => try w.writeAll("не процесс."),
    }
    try w.print("\n\nЖивой срез: /monitor", .{});
}

pub fn reportOne(w: *std.Io.Writer, t: Target, res: RestartResult) !void {
    try w.print("🔄 <b>Перезапуск · {s}</b>\n\n• {s} — {s}\n\nЖивой срез: /monitor", .{ targetName(t), targetName(t), res.msg });
}

pub fn reportAll(w: *std.Io.Writer, pg: RestartResult, tor: RestartResult) !void {
    try w.print("🔄 <b>Принудительный перезапуск слоёв</b>\n\n• postgres — {s}\n• tor — {s}\n• процесс — сейчас, после этого сообщения\n\nЖивой срез после подъёма: /monitor", .{ pg.msg, tor.msg });
}

pub fn helpText(w: *std.Io.Writer) !void {
    try w.print("🔄 <b>Перезапуск слоёв</b> (только админ)\n\n<code>/restart</code> — принудительно все, что можно: postgres, tor, процесс\n<code>/restartbot</code> · <code>/restartproc</code> — контейнер бота\n<code>/restartpostgres</code> · <code>/restartpg</code> — Postgres\n<code>/restarttor</code> — Tor\n\nСтоп-кран бутлупа (пачку Telegram смотрим целиком, до любого /restart):\n<code>/reset</code> — подтвердить очередь, /restart не крутить\n<code>/hardreset</code> — то же + один рестарт процесса бота\n\nНе процессы (команда ответит отказом):\n<code>/restarttelegram</code> · <code>/restartwan</code> · <code>/restartdocker</code> · <code>/restartdisk</code>", .{});
}

/// Убить себя: даём ответу уйти и выходим — restart-политика Docker поднимет.
pub fn bounceSelf() noreturn {
    std.Thread.sleep(400 * std.time.ns_per_ms);
    std.process.exit(1);
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "parseTarget: формы и суффиксы" {
    try std.testing.expectEqual(Target.all, parseTarget("/restart", "").?);
    try std.testing.expectEqual(Target.all, parseTarget("/restart", "all").?);
    try std.testing.expectEqual(Target.all, parseTarget("/restart", "все").?);
    try std.testing.expectEqual(Target.tor, parseTarget("/restart", "tor").?);
    try std.testing.expectEqual(Target.tor, parseTarget("/restarttor", "").?);
    try std.testing.expectEqual(Target.postgres, parseTarget("/restartpostgres", "").?);
    try std.testing.expectEqual(Target.postgres, parseTarget("/restartpg", "").?);
    try std.testing.expectEqual(Target.bot, parseTarget("/restartbot", "").?);
    try std.testing.expectEqual(Target.bot, parseTarget("/restartproc", "").?);
    try std.testing.expectEqual(Target.telegram, parseTarget("/restarttelegram", "").?);
    try std.testing.expectEqual(Target.disk, parseTarget("/restart", "диск").?);
    try std.testing.expectEqual(Target.help, parseTarget("/restart", "чтото").?);
    try std.testing.expectEqual(Target.help, parseTarget("/restartfoo", "").?);
    try std.testing.expect(parseTarget("/voc", "") == null);
    try std.testing.expect(parseTarget("/reset", "") == null);
}

test "needsWork/killsSelf/downMask" {
    try std.testing.expect(needsWork(.all) and needsWork(.tor));
    try std.testing.expect(!needsWork(.telegram) and !needsWork(.help));
    try std.testing.expect(killsSelf(.all) and killsSelf(.bot));
    try std.testing.expect(!killsSelf(.postgres) and !killsSelf(.tor));
    try std.testing.expectEqual(mon.BIT_PG, downMask(.postgres));
    try std.testing.expectEqual(mon.BIT_TOR | mon.BIT_TG, downMask(.tor));
    try std.testing.expectEqual(@as(i32, 0), downMask(.wan));
}

test "planRestart: replay и cooldown" {
    // сообщение пришло до старта процесса — скип
    try std.testing.expectEqual(@as(std.meta.Tag(RestartPlan), .skip_stale), @as(std.meta.Tag(RestartPlan), planRestart(.all, 1000, 500, null)));
    // свежий рестарт был 10 с назад, даты нет — скип
    try std.testing.expectEqual(@as(std.meta.Tag(RestartPlan), .skip_stale), @as(std.meta.Tag(RestartPlan), planRestart(.tor, 1000, 0, 10)));
    // давно — работаем
    const p = planRestart(.tor, 1000, 0, 500);
    try std.testing.expect(p == .bounce);
    // не процесс — только ответ
    try std.testing.expect(planRestart(.wan, 1000, 0, null) == .reply_only);
}

test "стоп-краны: парсинг, приоритет, offset" {
    try std.testing.expectEqual(Brake.reset, brakeFromCmd("/reset").?);
    try std.testing.expectEqual(Brake.reset, brakeFromCmd("/flush").?);
    try std.testing.expectEqual(Brake.hard, brakeFromCmd("/hardreset").?);
    try std.testing.expectEqual(Brake.hard, brakeFromCmd("/hard").?);
    try std.testing.expect(brakeFromCmd("/restart") == null);
    try std.testing.expectEqual(Brake.hard, preferBrake(.reset, .hard));
    try std.testing.expectEqual(Brake.hard, preferBrake(null, .hard));
    try std.testing.expectEqual(Brake.reset, preferBrake(.reset, .reset));
    try std.testing.expectEqual(@as(i64, 101), drainOffset(100));
    // сатурация
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), drainOffset(std.math.maxInt(i64)));
}

test "resetText" {
    var b: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try resetText(&w, 5, false);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "подтверждено апдейтов: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Процесс не убиваю") != null);
    var w2: std.Io.Writer = .fixed(&b);
    try resetText(&w2, 3, true);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "Жёсткий сброс") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "один раз") != null);
}

test "unsupportedText: причины" {
    var b: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try unsupportedText(&w, .telegram);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "/restartbot") != null);
    var w2: std.Io.Writer = .fixed(&b);
    try unsupportedText(&w2, .disk);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "не сервис") != null);
}

test "pendingText" {
    try std.testing.expectEqualStrings("перезапускаю postgres…", pendingText(.postgres));
    try std.testing.expectEqualStrings("принудительно перезапускаю слои…", pendingText(.all));
}

test "batchBrake: стоп-кран в хвосте пачки побеждает /restart в голове" {
    const admin: i64 = 42;
    const ups = [_]tg.Update{
        .{ .update_id = 10, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 42 }, .text = "/restart" } },
        .{ .update_id = 11, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 42 }, .text = "просто текст" } },
        .{ .update_id = 12, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 7 }, .text = "/hardreset" } }, // не админ
        .{ .update_id = 13, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 42 }, .text = "/hardreset" } },
        .{ .update_id = 14, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 42 }, .text = "/flush@moon" } },
    };
    const b = batchBrake(&ups, admin).?;
    try std.testing.expectEqual(Brake.hard, b.kind); // hard побеждает
    try std.testing.expectEqual(@as(i64, 42), b.chat_id);
    try std.testing.expectEqual(@as(i64, 14), b.max_id);
    try std.testing.expectEqual(@as(i64, 15), b.offset);

    // без стоп-кранов — null
    const ups2 = [_]tg.Update{
        .{ .update_id = 20, .message = .{ .chat = .{ .id = 42 }, .from = .{ .id = 42 }, .text = "/restart" } },
    };
    try std.testing.expect(batchBrake(&ups2, admin) == null);
    // без админа стоп-кранов нет вовсе
    try std.testing.expect(batchBrake(&ups, 0) == null);
    // /flush один — reset
    const ups3 = [_]tg.Update{
        .{ .update_id = 30, .message = .{ .chat = .{ .id = 9 }, .from = .{ .id = 42 }, .text = "/flush" } },
    };
    try std.testing.expectEqual(Brake.reset, batchBrake(&ups3, admin).?.kind);
}
