//! Хостовый сторож «Arch»: docker-демон / контейнеры стека (bot, db, tor) /
//! Telegram через Tor-socks / диск / CPU-температура / питание / sshd.
//! Только sendMessage — getUpdates занят ботом (иначе 409). Дебаунс как в
//! rbot: новое состояние должно повториться дважды, одиночные дребезги
//! игнорируются; первое стабильное состояние — сводка, дальше только
//! переходы (по одному сообщению на фронт).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const tg = @import("bot/telegram.zig");
const wd = @import("bot/wd.zig");
const log = @import("log.zig").log;

const INTERVAL_S: u32 = 60;
const DISK_PCT: u8 = 85;
const TEMP_C: i32 = 80;

const Snap = struct {
    docker: bool,
    bot: bool,
    db: bool,
    tor: bool,
    tg: bool,
    disk_ok: bool,
    disk_pct: u8,
    temp_ok: bool,
    temp_c: i32,
    ac: bool,
    sshd: bool,

    fn eql(a: Snap, b: Snap) bool {
        return std.meta.eql(a, b);
    }
};

pub fn run(alloc: std.mem.Allocator, cfg: *const config.Config) !void {
    if (cfg.token.len == 0) {
        log("watch: не задан TELEGRAM_TOKEN", .{});
        return error.NoToken;
    }
    if (cfg.admin_id == 0) {
        log("watch: не задан TELEGRAM_ACCESS_ID — некому слать алерты", .{});
        return error.NoAdmin;
    }
    log("watch: хостовый сторож, интервал {d} с, проект {s}", .{ INTERVAL_S, cfg.compose_project });

    var stable: ?Snap = null;
    var candidate: ?Snap = null;

    var api = tg.Api.init(alloc, cfg.token, null);
    defer api.deinit();

    while (true) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const snap = probe(a, cfg, &api);
        if (candidate) |c| {
            if (Snap.eql(c, snap)) {
                // состояние повторилось — принимаем
                if (stable) |s| {
                    if (!Snap.eql(s, snap)) {
                        sendDiffs(&api, cfg.admin_id, s, snap);
                    }
                } else {
                    sendBoot(&api, cfg.admin_id, snap);
                }
                stable = snap;
                candidate = null;
            } else {
                candidate = snap; // дребезг — начинаем заново
            }
        } else {
            candidate = snap;
        }
        std.Thread.sleep(@as(u64, INTERVAL_S) * std.time.ns_per_s);
    }
}

fn probe(arena: std.mem.Allocator, cfg: *const config.Config, api: *tg.Api) Snap {
    _ = api;
    const docker_ok = wd.dockerPing(arena);
    var bot_ok = false;
    var db_ok = false;
    var tor_ok = false;
    if (docker_ok) {
        if (wd.dockerHttp(arena, "GET", "/containers/json?all=1", null, 5)) |resp| {
            if (resp.status == 200) {
                const ctns = wd.parseContainers(arena, resp.body, cfg.compose_project) catch &.{};
                for (ctns) |c| {
                    const ctn_ok = c.running and c.healthy;
                    if (std.mem.eql(u8, c.service, "bot")) bot_ok = ctn_ok;
                    if (std.mem.eql(u8, c.service, "db")) db_ok = ctn_ok;
                    if (std.mem.eql(u8, c.service, "tor")) tor_ok = ctn_ok;
                }
            }
        }
    }
    // Telegram через socks tor-контейнера (если поднят)
    var tg_ok = false;
    if (tor_ok) {
        if (wd.composeId(arena, cfg.compose_project, "tor")) |id| {
            if (wd.containerIp(arena, id)) |ip| {
                var b: [64]u8 = undefined;
                const url = std.fmt.bufPrint(&b, "socks5://{s}:9050", .{ip}) catch "";
                if (config.parseSocks(url)) |socks| {
                    tg_ok = wd.tcpProbe(socks.host, socks.port, 3000);
                }
            }
        }
    }
    const disk_pct = diskPct();
    const temp = cpuTemp();
    return .{
        .docker = docker_ok,
        .bot = bot_ok,
        .db = db_ok,
        .tor = tor_ok,
        .tg = tg_ok,
        .disk_ok = disk_pct == null or disk_pct.? < DISK_PCT,
        .disk_pct = disk_pct orelse 0,
        .temp_ok = temp == null or temp.? < TEMP_C,
        .temp_c = temp orelse 0,
        .ac = onAc() orelse true,
        .sshd = wd.tcpProbe("127.0.0.1", 22022, 2000),
    };
}

fn sendBoot(api: *tg.Api, admin: i64, s: Snap) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("🛰 Arch hostwatch запущен → админ\n", .{}) catch return;
    w.print("tor {s} · bot {s} · db {s} · tg {s} · диск {d}% · {s} · sshd {s} · CPU {d}°C", .{
        ok(s.tor), ok(s.bot), ok(s.db), ok(s.tg), s.disk_pct, if (s.ac) "адаптер" else "БАТАРЕЯ", ok(s.sshd), s.temp_c,
    }) catch return;
    api.alertDirect(admin, w.buffered());
    log("watch: boot-сводка отправлена", .{});
}

fn sendDiffs(api: *tg.Api, admin: i64, old: Snap, new: Snap) void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    diffs(&w, old, new);
    if (w.buffered().len > 0) {
        api.alertDirect(admin, w.buffered());
    }
}

fn diffs(w: *std.Io.Writer, old: Snap, new: Snap) void {
    edge(w, "docker-демон", old.docker, new.docker);
    edge(w, "контейнер Tor", old.tor, new.tor);
    edge(w, "контейнер бота", old.bot, new.bot);
    edge(w, "Postgres", old.db, new.db);
    edge(w, "Telegram через Tor", old.tg, new.tg);
    edge(w, "sshd :22022", old.sshd, new.sshd);
    if (old.disk_ok and !new.disk_ok) {
        w.print("moonobsrv: диск {d}% (порог {d}%)\n", .{ new.disk_pct, @as(u32, DISK_PCT) }) catch {};
    } else if (!old.disk_ok and new.disk_ok) {
        w.print("OK moonobsrv: диск {d}%\n", .{new.disk_pct}) catch {};
    }
    if (old.temp_ok and !new.temp_ok) {
        w.print("moonobsrv: жарко {d}°C (порог {d})\n", .{ new.temp_c, TEMP_C }) catch {};
    } else if (!old.temp_ok and new.temp_ok) {
        w.print("OK moonobsrv: температура в норме ({d}°C)\n", .{new.temp_c}) catch {};
    }
    if (old.ac and !new.ac) {
        w.print("moonobsrv: пропал адаптер — батарея, подключите зарядку\n", .{}) catch {};
    } else if (!old.ac and new.ac) {
        w.print("OK moonobsrv: питание — снова адаптер\n", .{}) catch {};
    }
}

fn edge(w: *std.Io.Writer, name: []const u8, was: bool, now_: bool) void {
    if (was and !now_) {
        w.print("moonobsrv: {s} упал\n", .{name}) catch {};
    } else if (!was and now_) {
        w.print("OK moonobsrv: {s}\n", .{name}) catch {};
    }
}

fn ok(v: bool) []const u8 {
    return if (v) "OK" else "FAIL";
}

// ─── Данные хоста (только Unix; на Windows-разработке всё «нормально») ──────

fn diskPct() ?u8 {
    if (builtin.os.tag == .windows) return null;
    const out = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "df", "-P", "/" },
        .max_output_bytes = 4096,
    }) catch return null;
    if (out.term != .Exited) return null;
    const stdout = out.stdout;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    _ = it.next();
    const line = it.next() orelse return null;
    var f = std.mem.tokenizeAny(u8, line, " \t");
    var idx: usize = 0;
    while (f.next()) |tok| : (idx += 1) {
        if (idx == 4) return std.fmt.parseInt(u8, std.mem.trim(u8, tok, "% "), 10) catch null;
    }
    return null;
}

fn cpuTemp() ?i32 {
    if (builtin.os.tag == .windows) return null;
    var buf: [16]u8 = undefined;
    const f = std.fs.cwd().openFile("/sys/class/thermal/thermal_zone0/temp", .{}) catch return null;
    defer f.close();
    const n = f.readAll(&buf) catch return null;
    const milli = std.fmt.parseInt(i64, std.mem.trim(u8, buf[0..n], " \r\n"), 10) catch return null;
    return @intCast(@divTrunc(milli, 1000));
}

fn onAc() ?bool {
    if (builtin.os.tag == .windows) return null;
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

// ─── Тесты дебаунса и диффов ────────────────────────────────────────────────

test "Snap.eql и diffs: фронты превращаются в сообщения" {
    const old = Snap{
        .docker = true,  .bot = true,  .db = true,  .tor = true,  .tg = true,
        .disk_ok = true, .disk_pct = 21, .temp_ok = true, .temp_c = 50,
        .ac = true,      .sshd = true,
    };
    const same = old;
    try std.testing.expect(Snap.eql(old, same));

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // всё живо → нет сообщений
    diffs(&w, old, same);
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);

    // упали tor и бот, диск почернел, батарея
    var w2: std.Io.Writer = .fixed(&buf);
    const now_snap = Snap{
        .docker = true, .bot = false, .db = true, .tor = false, .tg = false,
        .disk_ok = false, .disk_pct = 91, .temp_ok = true, .temp_c = 60,
        .ac = false, .sshd = true,
    };
    diffs(&w2, old, now_snap);
    const s = w2.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "контейнер Tor упал") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "контейнер бота упал") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Telegram через Tor упал") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "диск 91%") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "пропал адаптер") != null);

    // восстановление — OK-сообщения
    var w3: std.Io.Writer = .fixed(&buf);
    diffs(&w3, now_snap, old);
    const s3 = w3.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s3, "OK moonobsrv: контейнер Tor") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "OK moonobsrv: диск 21%") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3, "OK moonobsrv: питание") != null);
}
