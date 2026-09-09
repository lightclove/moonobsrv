//! Админские команды здоровья: /monitor, /idle*, /restart*, /reset,
//! /hardreset, /users, /revoke. Механика — из rbot: ACK до рестарта,
//! сэмпл простоя перед дёрганьем слоя, placeholder-сообщение с редактированием.

const std = @import("std");
const router = @import("../bot/router.zig");
const features = @import("features.zig");
const storemod = @import("../bot/store.zig");
const mon = @import("../bot/mon.zig");
const rst = @import("../bot/rst.zig");
const wd = @import("../bot/wd.zig");
const access = @import("../bot/access.zig");
const runtime = @import("../runtime.zig");
const log = @import("../log.zig").log;

fn isAdmin(ctx: *router.Ctx) bool {
    return ctx.base.cfg.admin_id != 0 and ctx.from_id != null and ctx.from_id.? == ctx.base.cfg.admin_id;
}

fn denyAdmin(ctx: *router.Ctx) !void {
    try ctx.reply.writeAll("Команда только для админа.");
}

/// Собирает вход для /monitor: живые пробы + срез Docker + /proc и /sys.
fn monitorIn(base: router.Base, arena: std.mem.Allocator) mon.MonitorIn {
    const cfg = base.cfg;
    const pr = wd.probes(cfg.tor);
    var containers: ?[]wd.Container = null;
    if (wd.dockerPing(arena)) {
        if (wd.dockerHttp(arena, "GET", "/containers/json?all=1", null, 5)) |resp| {
            if (resp.status == 200) {
                containers = wd.parseContainers(arena, resp.body, cfg.compose_project) catch &.{};
            }
        }
    }
    return .{
        .now = base.now,
        .off = cfg.tz_offset_sec,
        .started = runtime.started_at,
        .db_mode = base.store.dbMode(),
        .db_ok = base.store.db_ok,
        .tg_ok = runtime_tg_ok,
        .tor_configured = pr.tor_configured,
        .tor_socks = pr.tor_socks,
        .wan = pr.host_net,
        .containers = containers,
        .disk_pct = hostDiskPct(),
        .mem_free = hostMemFree(),
        .mem_total = hostMemTotal(),
        .cpu_temp = hostCpuTemp(),
        .ac = hostOnAc(),
        .sshd = hostSshdOk(),
        .hb_age = std.time.timestamp() - wd.lastBeat(),
    };
}

/// Заполняется main.zig: последний getUpdates прошёл.
pub var runtime_tg_ok: bool = true;

fn cmdMonitor(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    const api = ctx.base.api;
    wd.beat();
    const mid = api.sendMessageOpts(ctx.chat_id, "собираю слои…", false, null) catch 0;
    wd.beat();
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const inp = monitorIn(ctx.base, ctx.base.alloc);
    mon.fmtMonitor(&w, inp) catch return error.OutOfMemory;
    if (mid != 0) {
        const edited = api.editMessageText(ctx.chat_id, mid, w.buffered(), true, null) catch false;
        if (edited) return;
    }
    _ = api.sendMessageOpts(ctx.chat_id, w.buffered(), true, null) catch {};
}

fn cmdIdle(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    const kind = mon.idleKindFromCmd(ctx.cmd.name[1..]) orelse {
        try ctx.reply.writeAll("Не понял окно. Формат: /idlehour /idle3 /idleday /idleweek…");
        return;
    };
    if (!ctx.base.store.dbMode()) {
        try ctx.reply.writeAll("Снимки пишутся только с Postgres (MOONOBSRV_DB). Сейчас бот в режиме без БД.\nЖивой срез: /monitor");
        return;
    }
    const win = mon.winRange(kind, ctx.base.now, ctx.base.cfg.tz_offset_sec);
    const samples = ctx.base.store.layerSamples(ctx.base.alloc, win.from, win.to);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try mon.fmtIdle(&w, kind, ctx.base.now, ctx.base.cfg.tz_offset_sec, samples);
    try ctx.reply.writeAll(w.buffered());
}

fn cmdRestart(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    const t = rst.parseTarget(ctx.cmd.name, ctx.args) orelse return denyAdmin(ctx);
    if (t == .help) {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try rst.helpText(&w);
        return ctx.reply.writeAll(w.buffered());
    }
    if (!rst.needsWork(t)) {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try rst.unsupportedText(&w, t);
        return ctx.reply.writeAll(w.buffered());
    }

    const plan = rst.planRestart(t, runtime.started_at, ctx.base.now, wd.bounceAge());
    if (plan == .skip_stale) {
        return ctx.reply.writeAll("повтор /restart из очереди Telegram пропущен — бот уже после перезапуска.\nЖивой срез: /monitor");
    }

    // ACK до docker-restart: подтверждаем очередь, иначе бутлуп
    ctx.base.api.ack(ctx.base.store.updateCursor() + 1) catch {};
    ctx.base.store.setUpdateCursor(ctx.base.store.updateCursor()) catch {};
    wd.noteBounce();
    ctx.base.store.putLayerSample(std.time.timestamp(), ~rst.downMask(t), 0);

    // сообщение-заготовка, которое переживёт наш рестарт
    const mid = ctx.base.api.sendMessageOpts(ctx.chat_id, rst.pendingText(t), false, null) catch 0;

    wd.beat();
    const out = rst.run(ctx.base.alloc, t, ctx.base.cfg.compose_project, ctx.base.cfg.tor);
    wd.beat();

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (t == .all) {
        try rst.reportAll(&w, out.first, out.tor);
    } else {
        try rst.reportOne(&w, t, out.first);
    }
    if (mid != 0) {
        _ = ctx.base.api.editMessageText(ctx.chat_id, mid, w.buffered(), true, null) catch {};
    } else {
        _ = ctx.base.api.sendMessageOpts(ctx.chat_id, w.buffered(), true, null) catch {};
    }
    if (out.self_kill) {
        log("рестарт: убиваю себя по команде админа", .{});
        rst.bounceSelf();
    }
    ctx.base.store.putLayerSample(std.time.timestamp(), mon.sampleMask(ctx.base.store.db_ok, true, wd.probes(ctx.base.cfg.tor), wd.dockerPing(ctx.base.alloc), hostDiskPct()), hostDiskPct() orelse 0);
}

fn cmdReset(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    // одиночная пачка: подтверждаем всё до текущего курсора
    const store = ctx.base.store;
    const offset = store.updateCursor() + 1;
    ctx.base.api.ack(offset) catch {};
    wd.clearInflight();
    wd.noteBounce();
    store.putLayerSample(std.time.timestamp(), ~rst.downMask(.bot), 0);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const hard = ctx.cmd.name[1] == 'h';
    try rst.resetText(&w, 1, hard);
    try ctx.reply.writeAll(w.buffered());
    if (hard) {
        log("hardreset: рестарт процесса по команде админа", .{});
        rst.bounceSelf();
    }
}

fn cmdUsers(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    if (!ctx.base.store.dbMode()) {
        return ctx.reply.writeAll("Whitelist ведётся только с Postgres. Сейчас бот в режиме без БД.");
    }
    const users = ctx.base.store.listActive(ctx.base.alloc) catch &[_]storemod.UserRow{};
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (users.len == 0) {
        return ctx.reply.writeAll("Нет пользователей в whitelist.");
    }
    try w.print("Whitelist (active):\n", .{});
    for (users) |u| {
        try w.print("• <code>{d}</code>", .{u.id});
        if (u.name.len > 0) {
            try w.writeAll(" — ");
            try access.htmlEscape(&w, u.name);
        }
        if (u.id == ctx.base.cfg.admin_id) try w.writeAll(" (admin)");
        try w.writeAll("\n");
    }
    try ctx.reply.writeAll(w.buffered());
}

fn cmdRevoke(ctx: *router.Ctx) !void {
    if (!isAdmin(ctx)) return denyAdmin(ctx);
    const id = std.fmt.parseInt(i64, std.mem.trim(u8, ctx.args, " \t"), 10) catch {
        return ctx.reply.writeAll("Формат: /revoke <telegram_id>");
    };
    if (id == ctx.base.cfg.admin_id) {
        return ctx.reply.writeAll("Нельзя отозвать доступ у админа.");
    }
    if (ctx.base.store.revokeUser(id)) {
        ctx.base.api.sendMessage(id, "Ваш доступ к боту отозван.") catch {};
        try ctx.reply.print("Доступ отозван у <code>{d}</code>.", .{id});
    } else {
        try ctx.reply.writeAll("Пользователь не найден или уже не active.");
    }
}

// ─── Данные хоста (Linux-контейнер; на Windows-разработке — null) ───────────

pub fn hostDiskPct() ?u8 {
    if (@import("builtin").os.tag == .windows) return null;
    const out = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "df", "-P", "/" },
        .max_output_bytes = 4096,
    }) catch return null;
    const stdout = switch (out) {
        .Exited => |o| o.stdout,
        else => return null,
    };
    var it = std.mem.splitScalar(u8, stdout, '\n');
    _ = it.next(); // заголовок
    const line = it.next() orelse return null;
    // поле 5 — Capacity: «dev 1024-blocks Used Available Capacity Mount»
    var f = std.mem.tokenizeAny(u8, line, " \t");
    var idx: usize = 0;
    while (f.next()) |tok| : (idx += 1) {
        if (idx == 4) {
            return std.fmt.parseInt(u8, std.mem.trim(u8, tok, "% "), 10) catch null;
        }
    }
    return null;
}

fn hostMemInfo() ?[2]u64 { // [free, total]
    if (@import("builtin").os.tag == .windows) return null;
    var buf: [4096]u8 = undefined;
    const f = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return null;
    defer f.close();
    const n = f.readAll(&buf) catch return null;
    var free: ?u64 = null;
    var total: ?u64 = null;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            free = parseKb(line);
        } else if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total = parseKb(line);
        }
    }
    if (free != null and total != null) return .{ free.?, total.? };
    return null;
}

fn parseKb(line: []const u8) ?u64 {
    var tok = std.mem.tokenizeAny(u8, line, " \t");
    _ = tok.next(); // имя
    const num = tok.next() orelse return null;
    const kb = std.fmt.parseInt(u64, num, 10) catch return null;
    return kb * 1024;
}

fn hostMemFree() ?u64 {
    const m = hostMemInfo() orelse return null;
    return m[0];
}

fn hostMemTotal() ?u64 {
    const m = hostMemInfo() orelse return null;
    return m[1];
}

fn hostCpuTemp() ?i32 {
    if (@import("builtin").os.tag == .windows) return null;
    var buf: [16]u8 = undefined;
    const f = std.fs.cwd().openFile("/sys/class/thermal/thermal_zone0/temp", .{}) catch return null;
    defer f.close();
    const n = f.readAll(&buf) catch return null;
    const milli = std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..n], " \r\n"), 10) catch return null;
    return @intCast(@divTrunc(milli, 1000));
}

fn hostOnAc() ?bool {
    if (@import("builtin").os.tag == .windows) return null;
    var dir = std.fs.cwd().openDir("/sys/class/power_supply", .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        var pbuf: [256]u8 = undefined;
        const type_path = std.fmt.bufPrint(&pbuf, "/sys/class/power_supply/{s}/type", .{entry.name}) catch continue;
        const tf = std.fs.cwd().openFile(type_path, .{}) catch continue;
        var tbuf: [32]u8 = undefined;
        const tn = tf.readAll(&tbuf) catch continue;
        tf.close();
        if (!std.mem.startsWith(u8, tbuf[0..tn], "Mains")) continue;
        var obuf: [256]u8 = undefined;
        const online_path = std.fmt.bufPrint(&obuf, "/sys/class/power_supply/{s}/online", .{entry.name}) catch continue;
        const of = std.fs.cwd().openFile(online_path, .{}) catch continue;
        var ob: [8]u8 = undefined;
        const on = of.readAll(&ob) catch continue;
        of.close();
        return std.mem.trim(u8, ob[0..on], " \r\n")[0] == '1';
    }
    return null;
}

fn hostSshdOk() ?bool {
    if (@import("builtin").os.tag == .windows) return null;
    return wd.tcpProbe("host.docker.internal", 22022, 2000);
}

pub const feature = features.Feature{
    .commands = &.{
        .{ .name = "/monitor", .description = "живой срез слоёв (админ)", .handler = cmdMonitor },
        .{ .name = "/restart", .description = "перезапуск слоёв (админ)", .handler = cmdRestart },
        .{ .name = "/restartbot", .aliases = &.{"/restartproc"}, .description = "контейнер бота", .handler = cmdRestart },
        .{ .name = "/restartpostgres", .aliases = &.{ "/restartpg", "/restartdb" }, .description = "Postgres", .handler = cmdRestart },
        .{ .name = "/restarttor", .description = "Tor", .handler = cmdRestart },
        .{ .name = "/restarttelegram", .aliases = &.{"/restarttg"}, .description = "— внешний Bot API", .handler = cmdRestart },
        .{ .name = "/restartwan", .description = "— сеть хоста", .handler = cmdRestart },
        .{ .name = "/restartdocker", .description = "— демон Docker", .handler = cmdRestart },
        .{ .name = "/restartdisk", .description = "— диск", .handler = cmdRestart },
        .{ .name = "/reset", .aliases = &.{"/flush"}, .description = "стоп-кран: сброс очереди (админ)", .handler = cmdReset },
        .{ .name = "/hardreset", .aliases = &.{"/hard"}, .description = "стоп-кран + рестарт бота (админ)", .handler = cmdReset },
        .{ .name = "/idlehour", .aliases = &.{"/idelhour"}, .description = "простой слоёв за час (админ)", .handler = cmdIdle },
        .{ .name = "/idle3", .description = "простой за 3 ч", .handler = cmdIdle },
        .{ .name = "/idle5", .description = "простой за 5 ч", .handler = cmdIdle },
        .{ .name = "/idle8", .description = "простой за 8 ч", .handler = cmdIdle },
        .{ .name = "/idle12", .description = "простой за 12 ч", .handler = cmdIdle },
        .{ .name = "/idle24", .description = "простой за 24 ч", .handler = cmdIdle },
        .{ .name = "/idleday", .aliases = &.{"/idelday"}, .description = "простой с полуночи", .handler = cmdIdle },
        .{ .name = "/idlenight", .aliases = &.{"/idelnight"}, .description = "простой за ночь", .handler = cmdIdle },
        .{ .name = "/idleweek", .aliases = &.{"/idelweek"}, .description = "простой с понедельника", .handler = cmdIdle },
        .{ .name = "/idlemonth", .aliases = &.{"/idelmonth"}, .description = "простой с 1-го числа", .handler = cmdIdle },
        .{ .name = "/idleyear", .aliases = &.{"/idelyear"}, .description = "простой с 1 января", .handler = cmdIdle },
        .{ .name = "/users", .description = "whitelist (админ)", .handler = cmdUsers },
        .{ .name = "/revoke", .description = "отозвать доступ (админ)", .handler = cmdRevoke },
    },
};
