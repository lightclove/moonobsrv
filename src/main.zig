//! moonobsrv — телеграм-бот: холостая Луна, ретро-Меркурий, лунные дни.
//!
//! Режимы:
//!   moonobsrv                 — сервис. По умолчанию long polling;
//!                               при заданном MOONOBSRV_WEBHOOK_URL — webhook
//!   moonobsrv watch           — хостовый сторож (systemd, не polling):
//!                               алерты о docker/Tor/диске/питании в личку
//!   moonobsrv --today         — астрономическая сводка на сейчас в консоль
//!   moonobsrv --webhook-info  — показать текущее состояние webhook
//!   moonobsrv --help/--version
//!
//! Цикл polling — по механике rbot: batch-brake до обработки пачки, ACK
//! перед рестартами, dedup апдейтов, сэмплы слоёв раз в минуту, watchdog
//! на зависание, авто-рестарт Tor после серии неудач, алерты админу.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util = @import("util.zig");
const runtime = @import("runtime.zig");
const astro = @import("astro.zig");
const log = @import("log.zig").log;
const tg = @import("bot/telegram.zig");
const router = @import("bot/router.zig");
const storemod = @import("bot/store.zig");
const webhook = @import("bot/webhook.zig");
const wd = @import("bot/wd.zig");
const mon = @import("bot/mon.zig");
const rst = @import("bot/rst.zig");
const fmonitor = @import("features/monitor.zig");
const dispatch = @import("dispatch.zig");
const features = @import("features/features.zig");
const f_voc = @import("features/voc.zig");
const f_mercury = @import("features/mercury.zig");
const f_lunday = @import("features/lunday.zig");
const f_planets = @import("features/planets.zig");
const hostwatch = @import("hostwatch.zig");

pub fn main() !void {
    setUtf8Console();
    // Аллокатор страниц без libc: минимум кода в бинарнике, памяти нужно мало.
    const alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        try printUsage();
        return;
    }
    if (hasFlag(args, "--version")) {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("moonobsrv {s}\n", .{runtime.version});
        try std.fs.File.stdout().writeAll(w.buffered());
        return;
    }

    const cfg = config.Config.load(alloc);

    if (subcommand(args, "watch")) {
        return hostwatch.run(alloc, &cfg);
    }

    if (hasFlag(args, "--today")) {
        try printToday(alloc, cfg);
        return;
    }

    if (cfg.token.len == 0) {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print(
            "Ошибка: не задан TELEGRAM_TOKEN (переменная окружения или .env).\n" ++
                "Получите токен у @BotFather и запустите:\n" ++
                "  set TELEGRAM_TOKEN=123456:ABC\n" ++
                "Подробнее: moonobsrv --help\n",
            .{},
        );
        try std.fs.File.stderr().writeAll(w.buffered());
        return error.NoToken;
    }

    runtime.started_at = std.time.timestamp();
    fmonitor.runtime_tg_ok = true;
    wd.beat();
    log("запуск v{s}; режим: {s}; данные: {s}; пояс: UTC{d}; tor: {s}; бд: {s}", .{
        runtime.version,
        if (cfg.webhookMode()) "webhook" else "polling",
        cfg.data_dir,
        @divTrunc(cfg.tz_offset_sec, 3600),
        if (cfg.tor) |t| t.host else "нет",
        if (cfg.dbMode()) "postgres" else "json",
    });

    var st = storemod.Store.load(alloc, cfg.data_dir);
    bootstrapState(&st);
    f_planets.bootstrap(&st);

    // Postgres (опционально): переподключаемся, пока контейнер стартует
    if (cfg.dbMode()) {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            wd.beat();
            if (st.attachDb(cfg.db_url, cfg.admin_id)) {
                break;
            } else |_| {}
            if (attempt >= 19) {
                log("pg: не подключился за {d} с — работаю без БД", .{attempt + 1});
                break;
            }
            std.Thread.sleep(std.time.ns_per_s);
        }
    }

    var api = tg.Api.init(alloc, cfg.token, cfg.tor);
    defer api.deinit();

    registerCommands(&api);

    // курсор: max(файл, БД); яд inflight — прошлый процесс умер в обработке
    const offset0 = @max(st.updateCursor(), wd.loadTgOffset(), st.dbCursor());
    if (offset0 > st.updateCursor()) {
        st.setUpdateCursor(offset0) catch {};
    }
    if (wd.takeInflight()) |poison_id| {
        log("inflight-яд: прошлый процесс умер на {d} — пропускаю", .{poison_id});
        if (poison_id >= offset0) {
            st.setUpdateCursor(poison_id) catch {};
            api.ack(poison_id + 1) catch {};
            st.markUpdate(poison_id);
        }
    }

    if (hasFlag(args, "--webhook-info")) {
        const info = api.getWebhookInfoOwned() catch |e| {
            log("getWebhookInfo: {s}", .{@errorName(e)});
            return e;
        };
        defer alloc.free(info);
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{s}\n", .{info});
        try std.fs.File.stdout().writeAll(w.buffered());
        return;
    }

    if (cfg.webhookMode()) {
        const resp = api.setWebhook(cfg.webhook_url, cfg.webhook_secret) catch |e| blk: {
            log("setWebhook: {s} — продолжаю (webhook мог быть зарегистрирован ранее)", .{@errorName(e)});
            break :blk null;
        };
        if (resp) |r| {
            defer alloc.free(r);
            log("setWebhook: {s}", .{r});
        }
    } else {
        // при переходе webhook → polling снимаем зарегистрированный webhook
        if (api.deleteWebhook()) |r| {
            defer alloc.free(r);
        } else |e| {
            log("deleteWebhook: {s} (не критично)", .{@errorName(e)});
        }
    }

    // watchdog: heartbeat жив — иначе abort, Docker поднимет
    const watchdog = try std.Thread.spawn(.{}, watchdogLoop, .{&api, &cfg});
    watchdog.detach();

    // Фоновый поток ватчеров: уведомления о переходах не зависят
    // от прихода обновлений (особенно в webhook-режиме).
    const watcher = try std.Thread.spawn(.{}, watcherLoop, .{ alloc, &cfg, &st, &api });
    watcher.detach();

    if (cfg.webhookMode()) {
        try webhook.serve(alloc, &cfg, &st, &api);
    } else {
        runPolling(alloc, &cfg, &st, &api);
    }
}

/// Первый запуск: инициализируем флаги текущим небом, чтобы не заспамить
/// уведомлением о «переходе», которого не было. Выполняется до старта потоков.
fn bootstrapState(st: *storemod.Store) void {
    const now = std.time.timestamp();
    var changed = false;
    if (st.getFlag(.voc_active) == null) {
        var abuf: [astro.voc.max_aspects]astro.voc.AspectEvent = undefined;
        st.setFlagQuiet(.voc_active, astro.voc.assess(now, &abuf).is_voc);
        changed = true;
    }
    if (st.getFlag(.mercury_retro) == null) {
        st.setFlagQuiet(.mercury_retro, astro.retro.isRetro(.mercury, now));
        changed = true;
    }
    if (st.lunarDay() == null) {
        st.lunar_day = astro.lunday.assess(now).number;
        changed = true;
    }
    if (changed) {
        st.save() catch |e| log("bootstrap save: {s}", .{@errorName(e)});
    }
}

fn watcherLoop(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, api: *tg.Api) void {
    while (true) {
        std.Thread.sleep(@as(u64, cfg.check_interval_s) * std.time.ns_per_s);
        const now = std.time.timestamp();
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const base = router.Base{
            .alloc = arena.allocator(),
            .now = now,
            .cfg = cfg,
            .store = st,
            .api = api,
        };
        for (features.all) |f| {
            if (f.on_tick) |tick| {
                tick(base) catch |e| log("ватчер: {s}", .{@errorName(e)});
            }
        }
    }
}

/// Сторож зависаний: процесс молчит дольше HUNG_SECS — trap, Docker поднимет.
fn watchdogLoop(api: *tg.Api, cfg: *const config.Config) void {
    _ = api;
    _ = cfg;
    const start = std.time.timestamp();
    while (true) {
        std.Thread.sleep(@as(u64, wd.WATCHDOG_TICK_S) * std.time.ns_per_s);
        const hb = wd.lastBeat();
        if (hb > 0 and std.time.timestamp() - hb > wd.HUNG_SECS and std.time.timestamp() - start > wd.START_GRACE_S) {
            wd.noteHang();
            log("watchdog: heartbeat stale {d} с — trap, Docker поднимет", .{std.time.timestamp() - hb});
            @trap();
        }
    }
}

// ─── Цикл long polling (механика rbot) ──────────────────────────────────────

const PollState = struct {
    consec_fails: u32 = 0,
    tor_last_restart: i64 = 0,
    alert_last: i64 = 0,
    alert_pending: ?[]const u8 = null, // память page_allocator
    last_sample: i64 = 0,
};

fn runPolling(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, api: *tg.Api) void {
    var ps = PollState{};
    var offset: i64 = st.updateCursor() + 1;
    const start = std.time.timestamp();
    while (true) {
        wd.beat();
        const body = api.getUpdatesOwned(offset, cfg.poll_timeout_s) catch |e| {
            if (e == error.TelegramConflict) {
                log("TELEGRAM_TOKEN уже используется другим процессом. Один токен = один polling.", .{});
                std.process.exit(2);
            }
            onPollFail(alloc, cfg, st, api, &ps, e, start);
            continue;
        };
        fmonitor.runtime_tg_ok = true;
        ps.consec_fails = 0;

        var max_id: i64 = 0;
        {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const updates = tg.parseUpdates(arena.allocator(), body) catch &[_]tg.Update{};
            alloc.free(body);

            // стоп-кран: пачку смотрим целиком ДО любой обработки
            if (rst.batchBrake(updates, cfg.admin_id)) |brake| {
                drainBrake(alloc, cfg, st, api, updates, brake);
                offset = brake.offset;
                continue;
            }

            for (updates) |*u| {
                if (u.update_id > max_id) max_id = u.update_id;
                if (st.updateSeen(u.update_id)) continue;
                offset = u.update_id + 1;
                wd.setInflight(u.update_id);
                dispatch.handleUpdate(alloc, cfg, st, api, u);
                st.markUpdate(u.update_id);
                wd.clearInflight();
                st.setUpdateCursor(u.update_id) catch |e| log("save: {s}", .{@errorName(e)});
                wd.saveTgOffset(u.update_id);
                wd.beat();
            }
        }
        if (max_id > 0) api.ack(offset) catch {};
        maybeSample(alloc, cfg, st, &ps);
    }
}

const Brake = rst.BatchBrake;

/// Подтверждаем всю пачку, ничего не выполняем; Hard — плюс один рестарт.
fn drainBrake(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, api: *tg.Api, updates: []const tg.Update, brake: Brake) void {
    log("стоп-кран {s}: отбрасываю {d} апдейтов, offset={d}", .{ @tagName(brake.kind), updates.len, brake.offset });
    st.setUpdateCursor(brake.max_id) catch {};
    wd.saveTgOffset(brake.max_id);
    for (updates) |u| st.markUpdate(u.update_id);
    st.putLayerSample(std.time.timestamp(), ~rst.downMask(.bot), 0);
    wd.clearInflight();
    wd.noteBounce();
    api.ack(brake.offset) catch {};
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    rst.resetText(&w, @max(updates.len, 1), brake.kind == .hard) catch {};
    _ = api.sendMessageOpts(brake.chat_id, w.buffered(), true, null) catch {};
    if (brake.kind == .hard) {
        rst.bounceSelf();
    }
}

/// Сбой getUpdates: бэкофф, классификация, авто-рестарт Tor, алерт админу.
fn onPollFail(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, api: *tg.Api, ps: *PollState, e: anyerror, start: i64) void {
    fmonitor.runtime_tg_ok = false;
    ps.consec_fails += 1;
    log("getUpdates: {s} (неудача {d}) — пауза {d} с", .{ @errorName(e), ps.consec_fails, wd.backoffSecs(ps.consec_fails) });
    const pr = wd.probes(cfg.tor);
    const kind = wd.classify(@errorName(e), pr);

    // сэмпл сбоя (не чаще раза в 15 с)
    const now = std.time.timestamp();
    if (now - ps.last_sample >= 15) {
        ps.last_sample = now;
        const mask = mon.sampleMask(st.db_ok, false, pr, wd.dockerPing(alloc), null) & ~switch (kind) {
            .tor => mon.BIT_TOR,
            .host_net => mon.BIT_WAN,
            .unknown => 0,
        };
        st.putLayerSample(now, mask, 0);
    }

    // авто-рестарт Tor: 3+ подряд, кулдаун, не сразу после старта и админского рестарта
    const in_grace = now - start < wd.START_GRACE_S or now - runtime.started_at < wd.START_GRACE_S;
    const bounce_fresh = if (wd.bounceAge()) |a| a < wd.TOR_RESTART_COOLDOWN_S else false;
    if (kind == .tor and ps.consec_fails >= wd.FAIL_NEED and !in_grace and !bounce_fresh and now - ps.tor_last_restart >= wd.TOR_RESTART_COOLDOWN_S) {
        log("watchdog: рестарт Tor после {d} неудач", .{ps.consec_fails});
        ps.tor_last_restart = now;
        wd.noteBounce();
        st.putLayerSample(now, mon.sampleMask(st.db_ok, false, pr, false, null) & ~mon.BIT_TOR, 0);
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        if (wd.composeId(arena.allocator(), cfg.compose_project, "tor")) |id| {
            _ = wd.dockerRestart(arena.allocator(), id);
            _ = wd.waitSocks(cfg.tor);
        }
    }

    // алерт админу: один на эпизод, повтор недоставленного
    if (cfg.adminMode() and ps.consec_fails >= wd.FAIL_NEED) {
        if (ps.alert_pending == null and now - ps.alert_last >= wd.ALERT_COOLDOWN_S) {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("⚠ moonobsrv: Telegram недоступен ({d} подряд, {s}). Слой: {s}.", .{ ps.consec_fails, @errorName(e), @tagName(kind) }) catch {};
            const text = std.heap.page_allocator.dupe(u8, w.buffered()) catch null;
            if (text) |t| {
                api.alertDirect(cfg.admin_id, t);
                ps.alert_pending = t;
                ps.alert_last = now;
            }
        } else if (ps.alert_pending) |t| {
            if (now - ps.alert_last >= wd.SEND_RETRY_S) {
                api.alertDirect(cfg.admin_id, t);
                ps.alert_last = now;
            }
        }
    } else if (ps.consec_fails == 0 and ps.alert_pending != null) {
        // восстановление — уведомим и почистим
        if (cfg.adminMode()) {
            api.alertDirect(cfg.admin_id, "✅ moonobsrv: Telegram снова доступен.");
        }
        if (ps.alert_pending) |t| std.heap.page_allocator.free(t);
        ps.alert_pending = null;
    }

    std.Thread.sleep(@as(u64, wd.backoffSecs(ps.consec_fails)) * std.time.ns_per_s);
}

/// Сэмпл слоёв раз в минуту (для /idle*).
fn maybeSample(alloc: std.mem.Allocator, cfg: *const config.Config, st: *storemod.Store, ps: *PollState) void {
    const now = std.time.timestamp();
    if (now - ps.last_sample < 60) return;
    ps.last_sample = now;
    const db_ok = if (st.dbMode()) st.pingDb() else true;
    const pr = wd.probes(cfg.tor);
    const docker_ok = if (comptime wd.has_docker_socket) wd.dockerPing(alloc) else false;
    const disk: ?u8 = fmonitor.hostDiskPct();
    st.putLayerSample(now, mon.sampleMask(db_ok, fmonitor.runtime_tg_ok, pr, docker_ok, disk), @intCast(disk orelse 0));
}

/// Регистрирует список команд для автодополнения в клиентах Telegram.
/// Кириллические имена Bot API не принимает — идут только латинские.
fn registerCommands(api: *tg.Api) void {
    const Entry = struct { command: []const u8, description: []const u8 };
    var list: [64]Entry = undefined;
    var n: usize = 0;
    outer: for (features.commands) |c| {
        for (c.name[1..]) |ch| {
            if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_') continue :outer;
        }
        if (n >= list.len) break;
        list[n] = .{ .command = c.name[1..], .description = c.description };
        n += 1;
    }
    const payload = std.json.Stringify.valueAlloc(api.allocator, list[0..n], .{}) catch |e| {
        log("setMyCommands: {s}", .{@errorName(e)});
        return;
    };
    defer api.allocator.free(payload);
    const resp = api.requestOwned("setMyCommands", null, payload) catch |e| {
        log("setMyCommands: {s}", .{@errorName(e)});
        return;
    };
    defer api.allocator.free(resp);
    log("setMyCommands: зарегистрировано команд: {d}", .{n});
}

fn printToday(alloc: std.mem.Allocator, cfg: config.Config) !void {
    const now = std.time.timestamp();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try f_voc.writeStatus(now, cfg.tz_offset_sec, &aw.writer);
    try aw.writer.print("\n\n", .{});
    try f_mercury.writeStatus(now, cfg.tz_offset_sec, &aw.writer);
    try aw.writer.print("\n\n", .{});
    try f_lunday.writeStatus(now, cfg.tz_offset_sec, &aw.writer);

    var out_buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    try w.print("{s}\n", .{aw.written()});
    try std.fs.File.stdout().writeAll(w.buffered());
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print(
        \\moonobsrv v{s} — телеграм-бот: холостая Луна, ретро-Меркурий, лунные дни
        \\
        \\Использование:
        \\  moonobsrv                 сервисный режим (требует TELEGRAM_TOKEN)
        \\  moonobsrv watch           хостовый сторож: алерты админу о слоях
        \\  moonobsrv --today         сводка на сейчас в консоль, без сети
        \\  moonobsrv --webhook-info   состояние webhook в Telegram
        \\  moonobsrv --version        версия
        \\
        \\Слои (docker compose, прод — Arch через deploy.cmd):
        \\  bot + postgres + tor; связь с Telegram — через Tor (MOONOBSRV_TOR).
        \\  Админ (TELEGRAM_ACCESS_ID): /monitor /restart* /reset /hardreset
        \\  /idle* — простой слоёв; заявки на доступ — кнопками в чате.
        \\
        \\Переменные окружения (или файл .env, см. .env.example):
        \\  TELEGRAM_TOKEN           токен от @BotFather (обязателен)
        \\  TELEGRAM_ACCESS_ID       Telegram-id админа (заявки, алерты, слои)
        \\  MOONOBSRV_DB             URL Postgres (пусто — режим без БД)
        \\  MOONOBSRV_TOR            socks5://tor:9050 — Telegram через Tor
        \\  MOONOBSRV_COMPOSE_PROJECT проект docker compose (moonobsrv)
        \\  MOONOBSRV_DATA_DIR       каталог состояния (по умолчанию «data»)
        \\  MOONOBSRV_TZ             часовой пояс вывода, часов: 3, -5, 5.5
        \\  MOONOBSRV_POLL_TIMEOUT   long polling, сек (25)
        \\  MOONOBSRV_CHECK_INTERVAL период проверки неба, сек (60)
        \\  MOONOBSRV_WEBHOOK_URL    публичный https-адрес webhook
        \\  MOONOBSRV_LISTEN         локальный адрес HTTP-сервера (127.0.0.1:8080)
        \\  MOONOBSRV_WEBHOOK_SECRET секрет webhook (проверяется в заголовке)
        \\  MOONOBSRV_ENV            путь к env-файлу вместо .env
        \\
    , .{runtime.version});
    try std.fs.File.stdout().writeAll(w.buffered());
}

fn hasFlag(args: []const []u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn subcommand(args: []const []u8, name: []const u8) bool {
    if (args.len < 2) return false;
    return std.mem.eql(u8, args[1], name);
}

fn setUtf8Console() void {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.c) i32;
        };
        _ = kernel32.SetConsoleOutputCP(65001);
    }
}
