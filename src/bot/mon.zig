//! Мониторинг слоёв: текст /monitor (живой срез), маски здоровья для
//! сэмплов (раз в минуту в Postgres), окна и статистика простоя /idle*.
//! Формулы и пороги перенесены из rbot: гэп 150 с, 12 промежутков на слой,
//! инциденты по падающему фронту маски.

const std = @import("std");
const util = @import("../util.zig");
const wd = @import("wd.zig");

/// Биты маски слоя (сэмплы layer_sample.mask).
pub const BIT_PG: i32 = 1;
pub const BIT_TG: i32 = 2;
pub const BIT_TOR: i32 = 4;
pub const BIT_WAN: i32 = 8;
pub const BIT_DOCKER: i32 = 32;
pub const BIT_DISK: i32 = 64;

pub const DISK_PCT: u8 = 85;
pub const GAP_SECS: i64 = 150; // сэмпл раз в минуту + long poll 25 с ⇒ два пропуска
pub const NIGHT_FROM: u8 = 22;
pub const NIGHT_TO: u8 = 8;
pub const IDLE_SPANS_SHOW: usize = 12;

/// Маска здоровья по живым показателям.
pub fn sampleMask(db_ok: bool, tg_ok: bool, pr: wd.Probes, docker_ok: bool, disk_pct: ?u8) i32 {
    var m: i32 = 0;
    if (db_ok) m |= BIT_PG;
    if (tg_ok) m |= BIT_TG;
    if (!pr.tor_configured or pr.tor_socks) m |= BIT_TOR;
    if (pr.host_net) m |= BIT_WAN;
    if (docker_ok) m |= BIT_DOCKER;
    if (disk_pct == null or disk_pct.? < DISK_PCT) m |= BIT_DISK;
    return m;
}

// ─── /monitor: живой срез ───────────────────────────────────────────────────

pub const MonitorIn = struct {
    now: i64,
    off: i32,
    started: i64,
    db_mode: bool,
    db_ok: bool,
    tg_ok: bool,
    tor_configured: bool,
    tor_socks: bool,
    wan: bool = false,
    /// null — docker.sock недоступен (Windows-разработка).
    containers: ?[]wd.Container,
    disk_pct: ?u8 = null,
    mem_free: ?u64 = null,
    mem_total: ?u64 = null,
    cpu_temp: ?i32 = null,
    ac: ?bool = null,
    sshd: ?bool = null,
    hb_age: i64 = 0,
};

pub fn fmtMonitor(w: *std.Io.Writer, inp: MonitorIn) !void {
    var buf: [64]u8 = undefined;
    const dt = util.civilFromUnix(inp.now, inp.off);
    try w.print("📊 <b>Слои moonobsrv</b>\nна {d:0>2}.{d:0>2}.{d} {s}\n\n", .{ dt.d, dt.mo, @as(u32, @intCast(dt.y)), util.fmtClock(&buf, inp.now, inp.off) });

    var dur_up: [32]u8 = undefined;
    var dur_hb: [32]u8 = undefined;
    try w.print("• процесс — OK · жив {s} · heartbeat {s} назад\n", .{ util.fmtDur(&dur_up, inp.now - inp.started), util.fmtDur(&dur_hb, inp.hb_age) });
    try w.print("• postgres — {s}\n", .{okFail(inp.db_mode and inp.db_ok)});
    try w.print("• telegram — {s}\n", .{okFail(inp.tg_ok)});
    if (inp.tor_configured) {
        try w.print("• tor — {s} · {s}\n", .{ okFail(inp.tor_socks), if (inp.tor_socks) "socks отвечает" else "socks молчит" });
    } else {
        try w.print("• tor — н/д · прокси не задан\n", .{});
    }
    try w.print("• wan — {s} · пробы 1.1.1.1 / 8.8.8.8:443\n", .{okFail(inp.wan)});
    if (inp.containers) |ctns| {
        if (ctns.len == 0) {
            try w.print("• docker — н/д · контейнеры проекта не видны\n", .{});
        } else {
            try w.print("• docker — ", .{});
            for (ctns, 0..) |c, i| {
                if (i > 0) try w.writeAll(" · ");
                try w.print("{s} {s}", .{ c.service, okFail(c.running and c.healthy) });
            }
            try w.print("\n", .{});
        }
    } else {
        try w.print("• docker — н/д · нет docker.sock\n", .{});
    }
    if (inp.disk_pct) |d| {
        try w.print("• диск — {s} · {d}% (порог {d}%)\n", .{ okFail(d < DISK_PCT), d, @as(u32, DISK_PCT) });
    } else {
        try w.print("• диск — н/д\n", .{});
    }
    if (inp.mem_total != null and inp.mem_free != null) {
        var fb: [24]u8 = undefined;
        var tb: [24]u8 = undefined;
        try w.print("• RAM — свободно {s} / {s}\n", .{ fmtGib(&fb, inp.mem_free.?), fmtGib(&tb, inp.mem_total.?) });
    } else {
        try w.print("• RAM — н/д\n", .{});
    }
    if (inp.cpu_temp) |t| {
        try w.print("• CPU — {d}°C\n", .{t});
    } else {
        try w.print("• CPU — н/д\n", .{});
    }
    if (inp.ac) |ac| {
        try w.print("• питание — {s}\n", .{if (ac) "адаптер" else "БАТАРЕЯ"});
    } else {
        try w.print("• питание — н/д\n", .{});
    }
    if (inp.sshd) |s| {
        try w.print("• sshd :22022 — {s}\n", .{okFail(s)});
    } else {
        try w.print("• sshd :22022 — н/д\n", .{});
    }
    try w.print("\n⏱ простой: /idlehour /idle3 /idle5 /idle8 /idle12 /idle24\n/idleday /idlenight /idleweek /idlemonth /idleyear\n🔄 перезапуск: /restart\n/restartbot /restartpostgres /restarttor\n🛑 стоп-кран: /reset · /hardreset", .{});
}

fn okFail(ok: bool) []const u8 {
    return if (ok) "OK" else "FAIL";
}

fn fmtGib(buf: []u8, bytes: u64) []const u8 {
    const gib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (gib >= 1.0) {
        return std.fmt.bufPrint(buf, "{d:.1} ГиБ", .{gib}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.0} МиБ", .{gib * 1024.0}) catch buf[0..0];
}

pub fn fmtSpan(buf: []u8, secs_in: i64) []const u8 {
    const s = @max(secs_in, 0);
    if (s < 60) return std.fmt.bufPrint(buf, "{d} с", .{s}) catch buf[0..0];
    const m = s / 60;
    if (s < 3600) return std.fmt.bufPrint(buf, "{d} мин", .{m}) catch buf[0..0];
    if (s < 86400) {
        if (s % 3600 == 0) return std.fmt.bufPrint(buf, "{d} ч", .{s / 3600}) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{d} ч {d} мин", .{ s / 3600, m % 60 }) catch buf[0..0];
    }
    if (s % 86400 == 0) return std.fmt.bufPrint(buf, "{d} д", .{s / 86400}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d} д {d} ч", .{ s / 86400, (s % 86400) / 3600 }) catch buf[0..0];
}

// ─── Idle-окна ──────────────────────────────────────────────────────────────

pub const IdleKind = union(enum) {
    hours: u32,
    day,
    night,
    week,
    month,
    year,
};

/// Команды /idle* (+ опечатки /idel*). null — не idle-команда.
pub fn idleKindFromCmd(name: []const u8) ?IdleKind {
    const tbl = .{
        .{ "idlehour", IdleKind{ .hours = 1 } },
        .{ "idelhour", IdleKind{ .hours = 1 } },
        .{ "idle3", IdleKind{ .hours = 3 } },
        .{ "idle5", IdleKind{ .hours = 5 } },
        .{ "idle8", IdleKind{ .hours = 8 } },
        .{ "idle12", IdleKind{ .hours = 12 } },
        .{ "idle24", IdleKind{ .hours = 24 } },
        .{ "idleday", IdleKind.day },
        .{ "idelday", IdleKind.day },
        .{ "idlenight", IdleKind.night },
        .{ "idelnight", IdleKind.night },
        .{ "idleweek", IdleKind.week },
        .{ "idelweek", IdleKind.week },
        .{ "idlemonth", IdleKind.month },
        .{ "idelmonth", IdleKind.month },
        .{ "idleyear", IdleKind.year },
        .{ "idelyear", IdleKind.year },
    };
    inline for (tbl) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

/// Обратная Хиннанту: дни от эпохи для гражданской даты.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn dayStart(now: i64, off: i32) i64 {
    const local = now + off;
    return now - @mod(local, 86400);
}

pub fn weekStart(now: i64, off: i32) i64 {
    const local = now + off;
    const days = @divFloor(local, 86400);
    const dow = @mod(days + 3, 7); // 1970-01-01 — четверг; понедельник = 0
    return now - @mod(local, 86400) - dow * 86400;
}

pub fn monthStart(now: i64, off: i32) i64 {
    const dt = util.civilFromUnix(now, off);
    const days = daysFromCivil(dt.y, dt.mo, 1);
    return days * 86400 - off;
}

pub fn yearStart(now: i64, off: i32) i64 {
    const dt = util.civilFromUnix(now, off);
    const days = daysFromCivil(dt.y, 1, 1);
    return days * 86400 - off;
}

/// Ночь 22:00–08:00 локально: текущая (если внутри) или последняя завершённая.
pub fn nightRange(now: i64, off: i32) struct { from: i64, to: i64 } {
    const dt = util.civilFromUnix(now, off);
    const today22 = dayStart(now, off) + @as(i64, NIGHT_FROM) * 3600;
    const today8 = dayStart(now, off) + @as(i64, NIGHT_TO) * 3600;
    if (dt.hh >= NIGHT_FROM) return .{ .from = today22, .to = now };
    if (dt.hh < NIGHT_TO) return .{ .from = today22 - 86400, .to = now };
    return .{ .from = today22 - 86400, .to = today8 }; // прошедшая ночь
}

pub const WinRange = struct { from: i64, to: i64, label: []const u8 };

pub fn winRange(kind: IdleKind, now: i64, off: i32) WinRange {
    return switch (kind) {
        .hours => |h| .{ .from = now - @as(i64, h) * 3600, .to = now, .label = switch (h) {
            1 => "час",
            3 => "3 ч",
            5 => "5 ч",
            8 => "8 ч",
            12 => "12 ч",
            24 => "24 ч",
            else => "N ч",
        } },
        .day => .{ .from = dayStart(now, off), .to = now, .label = "сегодня" },
        .night => blk: {
            const r = nightRange(now, off);
            break :blk .{ .from = r.from, .to = r.to, .label = "ночь" };
        },
        .week => .{ .from = weekStart(now, off), .to = now, .label = "неделя" },
        .month => .{ .from = monthStart(now, off), .to = now, .label = "месяц" },
        .year => .{ .from = yearStart(now, off), .to = now, .label = "год" },
    };
}

// ─── Статистика простоя ─────────────────────────────────────────────────────

pub const Stat = struct {
    obs: i64 = 0, // наблюдаемое время (слои), сек
    down: i64 = 0, // простой слоя
    incidents: u32 = 0,
    spans: [16]struct { from: i64, to: i64 } = undefined,
    span_n: usize = 0,
    /// Слитые промежутки сверх ёмкости spans — чтобы «… ещё N» не врало.
    spans_lost: usize = 0,

    fn addSpan(self: *Stat, from: i64, to: i64) void {
        if (self.span_n > 0 and self.spans[self.span_n - 1].to == from) {
            self.spans[self.span_n - 1].to = to; // сливаются
        } else if (self.span_n < self.spans.len) {
            self.spans[self.span_n] = .{ .from = from, .to = to };
            self.span_n += 1;
        } else {
            self.spans_lost += 1;
        }
    }
};

pub const LayerStats = struct {
    proc: Stat = .{},
    pg: Stat = .{},
    tg: Stat = .{},
    tor: Stat = .{},
    wan: Stat = .{},
    docker: Stat = .{},
    disk: Stat = .{},
    n_samples: usize,
};

/// Порт stats() из rbot: процесс считается по гэпам между сэмплами,
/// слои — по битам маски на наблюдаемых интервалах.
pub fn computeStats(samples: []const wd.Sample, from: i64, to: i64) LayerStats {
    var st = LayerStats{ .n_samples = samples.len };
    if (samples.len == 0) {
        st.proc.down = to - from;
        return st;
    }
    // ведущий гэп: и в сумму, и в список промежутков (иначе расшифровка
    // неполна — админ не видит, когда именно висело)
    if (samples[0].ts - from > GAP_SECS) {
        st.proc.down += samples[0].ts - from;
        st.proc.addSpan(from, samples[0].ts);
    }
    var i: usize = 1;
    while (i < samples.len) : (i += 1) {
        const s0 = samples[i - 1];
        const s1 = samples[i];
        const dt = s1.ts - s0.ts;
        if (dt > GAP_SECS) {
            st.proc.down += dt;
            st.proc.addSpan(s0.ts, s1.ts);
        } else {
            st.proc.obs += dt;
            addObs(&st, s0, s1, dt);
        }
    }
    // хвост: маленький — наблюдаем с последней маской
    const last = samples[samples.len - 1];
    if (to - last.ts > GAP_SECS) {
        st.proc.down += to - last.ts;
        st.proc.addSpan(last.ts, to);
    } else if (to > last.ts) {
        const dt = to - last.ts;
        st.proc.obs += dt;
        addObs(&st, last, last, dt);
    }
    return st;
}

fn addObs(st: *LayerStats, s0: wd.Sample, s1: wd.Sample, dt: i64) void {
    observeLayer(&st.pg, BIT_PG, s0, s1, dt);
    observeLayer(&st.tg, BIT_TG, s0, s1, dt);
    observeLayer(&st.tor, BIT_TOR, s0, s1, dt);
    observeLayer(&st.wan, BIT_WAN, s0, s1, dt);
    observeLayer(&st.docker, BIT_DOCKER, s0, s1, dt);
    observeLayer(&st.disk, BIT_DISK, s0, s1, dt);
}

fn observeLayer(layer: *Stat, bit: i32, s0: wd.Sample, s1: wd.Sample, dt: i64) void {
    layer.obs += dt;
    if (s0.mask & bit == 0) {
        layer.down += dt;
        layer.addSpan(s0.ts, s0.ts + dt);
    }
    if (s0.mask & bit != 0 and s1.mask & bit == 0) layer.incidents += 1;
}

pub fn fmtIdle(w: *std.Io.Writer, kind: IdleKind, now: i64, off: i32, samples: []const wd.Sample) !void {
    const win = winRange(kind, now, off);
    var fbuf: [64]u8 = undefined;
    var tbuf: [64]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    try w.print("⏱ <b>Простой слоёв · {s}</b>\nокно: {s} — {s}\nснимков: {d} · длина {s}\n\n", .{
        win.label,
        fmtDateTimeLocal(&fbuf, win.from, off, now),
        util.fmtClock(&tbuf, win.to, off),
        samples.len,
        fmtSpan(&sbuf, win.to - win.from),
    });

    if (samples.len == 0) {
        try w.print("• процесс — простой {s} · 0%\n", .{fmtSpan(&fbuf, win.to - win.from)});
        try w.print("\nПока нет снимков за это окно — бот пишет их раз в минуту.\nЖивой срез: /monitor", .{});
        return;
    }

    const st = computeStats(samples, win.from, win.to);
    const total = @max(win.to - win.from, 1);
    try writeLayerLine(w, "процесс", st.proc, total, &fbuf, true, off);
    try writeLayerLine(w, "postgres", st.pg, total, &fbuf, false, off);
    try writeLayerLine(w, "telegram", st.tg, total, &fbuf, false, off);
    try writeLayerLine(w, "tor", st.tor, total, &fbuf, false, off);
    try writeLayerLine(w, "wan", st.wan, total, &fbuf, false, off);
    try writeLayerLine(w, "docker", st.docker, total, &fbuf, false, off);
    try writeLayerLine(w, "диск", st.disk, total, &fbuf, false, off);
}

fn writeLayerLine(w: *std.Io.Writer, name: []const u8, s: Stat, denom: i64, buf: []u8, show_spans: bool, off: i32) !void {
    if (s.obs == 0 and s.down == 0) {
        try w.print("• {s} — нет данных\n", .{name});
        return;
    }
    if (s.down == 0) {
        try w.print("• {s} — 0 · 100%\n", .{name});
        return;
    }
    const pct = @divTrunc((denom - s.down) * 100, denom);
    if (s.incidents > 0) {
        try w.print("• {s} — простой {s} · {d}% · сбоев {d}\n", .{ name, fmtSpan(buf, s.down), pct, s.incidents });
    } else {
        try w.print("• {s} — простой {s} · {d}%\n", .{ name, fmtSpan(buf, s.down), pct });
    }
    if (show_spans and s.span_n > 0) {
        var fb: [64]u8 = undefined;
        var tb: [64]u8 = undefined;
        const shown = @min(s.span_n, IDLE_SPANS_SHOW);
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            try w.print("  с {s} по {s}\n", .{
                fmtDateTimeLocal(&fb, s.spans[i].from, off, 0),
                util.fmtClock(&tb, s.spans[i].to, off),
            });
        }
        if (s.span_n > IDLE_SPANS_SHOW) {
            // плюс потерянные сверх ёмкости — иначе счётчик занижен
            try w.print("  … ещё {d}\n", .{s.span_n - IDLE_SPANS_SHOW + s.spans_lost});
        }
    }
}

/// «09.09.2026 14:32» локально.
pub fn fmtDateTimeLocal(buf: []u8, secs: i64, off: i32, now_for_year: i64) []const u8 {
    const dt = util.civilFromUnix(secs, off);
    _ = now_for_year;
    return std.fmt.bufPrint(buf, "{d:0>2}.{d:0>2}.{d} {d:0>2}:{d:0>2}", .{ dt.d, dt.mo, @as(u32, @intCast(dt.y)), dt.hh, dt.mm }) catch buf[0..0];
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "sampleMask: биты по слоям" {
    const m = sampleMask(true, true, .{ .tor_configured = true, .tor_socks = true, .host_net = true }, true, 21);
    try std.testing.expectEqual(BIT_PG | BIT_TG | BIT_TOR | BIT_WAN | BIT_DOCKER | BIT_DISK, m);
    const m2 = sampleMask(false, false, .{ .tor_configured = true, .tor_socks = false, .host_net = false }, false, 99);
    try std.testing.expectEqual(@as(i32, 0), m2);
    // без прокси tor всегда «ok»
    const m3 = sampleMask(true, true, .{ .tor_configured = false, .tor_socks = false, .host_net = true }, false, null);
    try std.testing.expect(m3 & BIT_TOR != 0);
    try std.testing.expect(m3 & BIT_DOCKER == 0);
    try std.testing.expect(m3 & BIT_DISK != 0); // диск неизвестен — считаем цел
}

test "idleKindFromCmd: команды и опечатки" {
    try std.testing.expectEqual(IdleKind{ .hours = 1 }, idleKindFromCmd("idlehour").?);
    try std.testing.expectEqual(IdleKind{ .hours = 24 }, idleKindFromCmd("idle24").?);
    try std.testing.expectEqual(IdleKind.month, idleKindFromCmd("idlemonth").?);
    try std.testing.expectEqual(IdleKind.year, idleKindFromCmd("idelyear").?);
    try std.testing.expect(idleKindFromCmd("idle") == null);
    try std.testing.expect(idleKindFromCmd("restart") == null);
}

test "winRange: окна от фиксированного момента" {
    // 2026-09-09 14:30 МСК (off=3ч) — среда
    const off: i32 = 3 * 3600;
    const now = util_days(2026, 9, 9) * 86400 + 14 * 3600 + 30 * 60 - off;
    const h3 = winRange(.{ .hours = 3 }, now, off);
    try std.testing.expectEqual(now - 3 * 3600, h3.from);
    const day = winRange(.day, now, off);
    try std.testing.expectEqual(@as(i64, 0), @mod(day.from + off, 86400));
    try std.testing.expect(day.from <= now);
    // неделя начинается в понедельник 07.09.2026
    const wk = util.civilFromUnix(winRange(.week, now, off).from, off);
    try std.testing.expectEqual(@as(u8, 7), wk.d);
    try std.testing.expectEqual(@as(u8, 9), wk.mo);
    // месяц — 1 сентября
    const mo = util.civilFromUnix(monthStart(now, off), off);
    try std.testing.expectEqual(@as(u8, 1), mo.d);
    // год — 1 января
    const yr = util.civilFromUnix(yearStart(now, off), off);
    try std.testing.expectEqual(@as(u8, 1), yr.d);
    try std.testing.expectEqual(@as(u8, 1), yr.mo);
}

test "nightRange: днём — прошедшая ночь, ночью — текущая" {
    const off: i32 = 3 * 3600;
    // 14:30 днём 9 сентября
    const day_now = util_days(2026, 9, 9) * 86400 + 14 * 3600 + 30 * 60 - off;
    const past = nightRange(day_now, off);
    const past_from = util.civilFromUnix(past.from, off);
    const past_to = util.civilFromUnix(past.to, off);
    try std.testing.expectEqual(@as(u8, 22), past_from.hh);
    try std.testing.expectEqual(@as(u8, 8), past_to.hh);
    try std.testing.expectEqual(@as(u8, 8), past_from.d); // ночь с 8-го
    // 23:30 ночью 9-го
    const night_now = util_days(2026, 9, 9) * 86400 + 23 * 3600 + 30 * 60 - off;
    const cur = nightRange(night_now, off);
    const cur_from = util.civilFromUnix(cur.from, off);
    try std.testing.expectEqual(@as(u8, 22), cur_from.hh);
    try std.testing.expectEqual(night_now, cur.to);
}

fn util_days(y: i32, mo: u8, d: u8) i64 {
    return daysFromCivil(y, mo, d);
}

test "computeStats: гэпы = простой процесса, бит вниз = простой слоя" {
    // 10 минут сэмплов раз в минуту, всё живо; гэп; первый сэмпл после
    // гэпа жив, дальше tor вниз до конца окна
    const t0: i64 = 1_700_000_000;
    const full = BIT_PG | BIT_TG | BIT_TOR | BIT_WAN | BIT_DOCKER | BIT_DISK;
    var samples: [20]wd.Sample = undefined;
    var i: usize = 0;
    var t = t0;
    while (i < 10) : (i += 1) {
        samples[i] = .{ .ts = t, .mask = full };
        t += 60;
    }
    t += 600; // гэп
    samples[i] = .{ .ts = t, .mask = full }; // живой
    i += 1;
    t += 60;
    while (i < 20) : (i += 1) {
        samples[i] = .{ .ts = t, .mask = full & ~BIT_TOR }; // tor упал
        t += 60;
    }
    const st = computeStats(&samples, t0, t);
    // процесс: один гэп 660 с (наблюдение → 600 тишины → следующий сэмпл)
    try std.testing.expectEqual(@as(i64, 660), st.proc.down);
    // tor: падение наблюдено (фронт) + 8 минут вниз + хвост 60 с
    try std.testing.expectEqual(@as(i64, 540), st.tor.down);
    try std.testing.expectEqual(@as(u32, 1), st.tor.incidents);
    try std.testing.expectEqual(@as(i64, 0), st.pg.down);
    try std.testing.expectEqual(@as(usize, 20), st.n_samples);
}

test "computeStats: пустое окно — весь простой процесса" {
    const st = computeStats(&.{}, 1000, 1060);
    try std.testing.expectEqual(@as(i64, 60), st.proc.down);
    try std.testing.expectEqual(@as(usize, 0), st.n_samples);
}

test "fmtMonitor: структура отчёта" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ctns = [_]wd.Container{
        .{ .name = "moonobsrv-bot-1", .service = "bot", .running = true, .healthy = true },
        .{ .name = "moonobsrv-db-1", .service = "db", .running = true, .healthy = true },
    };
    try fmtMonitor(&w, .{
        .now = 1_700_000_000,
        .off = 3 * 3600,
        .started = 1_700_000_000 - 7200,
        .db_mode = true,
        .db_ok = true,
        .tg_ok = true,
        .tor_configured = true,
        .tor_socks = true,
        .wan = true,
        .containers = ctns[0..],
        .disk_pct = 21,
        .mem_free = 2 * 1024 * 1024 * 1024,
        .mem_total = 15 * 1024 * 1024 * 1024,
        .cpu_temp = 52,
        .ac = true,
        .sshd = true,
        .hb_age = 300,
    });
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "Слои moonobsrv") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "• postgres — OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "• tor — OK · socks отвечает") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "bot OK · db OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "21%") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "2.0 ГиБ / 15.0 ГиБ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "52°C") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "питание — адаптер") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/hardreset") != null);
    // BUG-022: аптайм не затирается возрастом heartbeat (было «жив 5 мин»)
    try std.testing.expect(std.mem.indexOf(u8, s, "жив 2 ч") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "heartbeat 5 мин назад") != null);
}

test "fmtSpan" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("45 с", fmtSpan(&b, 45));
    try std.testing.expectEqualStrings("12 мин", fmtSpan(&b, 720));
    try std.testing.expectEqualStrings("3 ч", fmtSpan(&b, 10800));
    try std.testing.expectEqualStrings("3 ч 5 мин", fmtSpan(&b, 11100));
    try std.testing.expectEqualStrings("2 д", fmtSpan(&b, 172800));
    try std.testing.expectEqualStrings("2 д 3 ч", fmtSpan(&b, 183600));
}

test "computeStats: ведущий гэп попадает и в сумму, и в список (BUG-029)" {
    const full = BIT_PG | BIT_TG | BIT_TOR | BIT_WAN | BIT_DOCKER | BIT_DISK;
    var samples: [1]wd.Sample = undefined;
    samples[0] = .{ .ts = 1600, .mask = full };
    const st = computeStats(&samples, 1000, 2000);
    // ведущий 1000→1600 и хвостовой 1600→2000 — оба гэпы, сливаются в один
    try std.testing.expectEqual(@as(i64, 1000), st.proc.down);
    try std.testing.expectEqual(@as(usize, 1), st.proc.span_n);
    try std.testing.expectEqual(@as(i64, 1000), st.proc.spans[0].from);
    try std.testing.expectEqual(@as(i64, 2000), st.proc.spans[0].to);
}

test "computeStats: слой без наблюдений — spans_lost честно считает (BUG-030)" {
    // 20 разделённых гэпов по 260 с (между ними живые интервалы по 60 с):
    // 16 влезают в массив, 4 теряются — счётчик потерь не даст соврать
    const full = BIT_PG | BIT_TG;
    var samples: [42]wd.Sample = undefined;
    var t: i64 = 0;
    var idx: usize = 0;
    for (0..21) |_| {
        samples[idx] = .{ .ts = t, .mask = full };
        idx += 1;
        t += 60; // живой интервал
        samples[idx] = .{ .ts = t, .mask = full };
        idx += 1;
        t += 260; // гэп до следующей пары
    }
    const st = computeStats(&samples, 0, t - 260);
    try std.testing.expectEqual(@as(usize, 16), st.proc.span_n);
    try std.testing.expectEqual(@as(usize, 4), st.proc.spans_lost);
    try std.testing.expectEqual(@as(i64, 20 * 260), st.proc.down);
}

test "fmtIdle: шапка с датой начала и длиной окна без наложения (BUG-023), слой без данных (BUG-028)" {
    const off: i32 = 3 * 3600;
    // окно 12 ч, два сэмпла с гэпом 600 с в середине — начало окна наблюдаемо,
    // середина нет: у слоя postgres строка «нет данных» невозможна (obs>0),
    // а процесс имеет простой; шапка обязана содержать дату и длину
    const now = util_days(2026, 9, 9) * 86400 + 14 * 3600 + 30 * 60 - off;
    const full = BIT_PG | BIT_TG | BIT_TOR | BIT_WAN | BIT_DOCKER | BIT_DISK;
    var samples: [3]wd.Sample = undefined;
    samples[0] = .{ .ts = now - 11 * 3600, .mask = full };
    samples[1] = .{ .ts = now - 10 * 3600, .mask = full };
    samples[2] = .{ .ts = now - 9 * 3600, .mask = full };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try fmtIdle(&w, .{ .hours = 12 }, now, off, &samples);
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "окно: 09.09.2026 02:30 — 14:30") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "длина 12 ч") != null);
    // все интервалы — гэпы: слои не наблюдались → «нет данных», не «0 · 100%»
    var w2buf: [4096]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&w2buf);
    var gapy: [2]wd.Sample = undefined;
    gapy[0] = .{ .ts = now - 3600, .mask = full };
    gapy[1] = .{ .ts = now - 1800, .mask = full };
    try fmtIdle(&w2, .{ .hours = 2 }, now, off, &gapy);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "postgres — нет данных") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "0 · 100%") == null);
}
