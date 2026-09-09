//! Фича «Планеты»: /venus /mars /jupiter /saturn — знак и ретроградность
//! на любой момент, плюс уведомления о станциях этих планет.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");
const storemod = @import("../bot/store.zig");

const planets = astro.planets;
const retro = astro.retro;
const voc = astro.voc;

const tracked = [_]struct {
    body: planets.Body,
    flag: storemod.Flag,
    cmd: []const u8,
    desc: []const u8,
}{
    .{ .body = .venus, .flag = .venus_retro, .cmd = "/venus", .desc = "Венера: знак и ретро-движение (можно с датой)" },
    .{ .body = .mars, .flag = .mars_retro, .cmd = "/mars", .desc = "Марс: знак и ретро-движение (можно с датой)" },
    .{ .body = .jupiter, .flag = .jupiter_retro, .cmd = "/jupiter", .desc = "Юпитер: знак и ретро-движение (можно с датой)" },
    .{ .body = .saturn, .flag = .saturn_retro, .cmd = "/saturn", .desc = "Сатурн: знак и ретро-движение (можно с датой)" },
};

/// Инициализация флагов при первом запуске (до старта потоков).
pub fn bootstrap(st: *storemod.Store) void {
    const now = std.time.timestamp();
    var changed = false;
    for (tracked) |t| {
        if (st.getFlag(t.flag) == null) {
            st.setFlagQuiet(t.flag, retro.isRetro(t.body, now));
            changed = true;
        }
    }
    if (changed) {
        st.save() catch {};
    }
}

fn bodyOf(name: []const u8) ?planets.Body {
    for (tracked) |t| {
        if (std.mem.eql(u8, t.cmd, name)) return t.body;
    }
    return null;
}

fn cmdPlanet(ctx: *router.Ctx) !void {
    const body = bodyOf(ctx.cmd.name) orelse return error.UnknownPlanet;
    const now = try ctx.moment();
    try writeStatus(body, now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

pub fn writeStatus(body: planets.Body, now: i64, tz: i32, w: *std.Io.Writer) !void {
    const jd = astro.time.jdFromUnix(now);
    const sign = voc.Sign.fromLongitude(planets.longitude(body, jd));
    const is_retro = retro.isRetro(body, now);
    var wb: [retro.max_windows]?retro.Window = undefined;
    const n = retro.upcoming(body, now, &wb);

    var b_dt: [64]u8 = undefined;
    var b_dt2: [64]u8 = undefined;

    try w.print("{s} {s}: {s} {s}, ", .{ body.glyph(), body.nameRu(), sign.glyph(), sign.inRu() });
    if (is_retro) {
        try w.print("ретроградное движение\n", .{});
        if (n > 0 and wb[0].?.contains(now)) {
            try w.print("Станция директа: {s}", .{util.fmtDateTime(&b_dt, wb[0].?.end, tz, now)});
        }
    } else {
        try w.print("директное движение\n", .{});
        if (n > 0) {
            const win = wb[0].?;
            const t1 = util.fmtDateTime(&b_dt, win.start, tz, now);
            const t2 = util.fmtDateTime(&b_dt2, win.end, tz, now);
            try w.print("Ближайший ретро-период: {s} — {s}", .{ t1, t2 });
        }
    }
}

pub fn onTick(base: router.Base) !void {
    const tz = base.cfg.tz_offset_sec;
    for (tracked) |t| {
        const cur = retro.isRetro(t.body, base.now);
        const prev = base.store.getFlag(t.flag) orelse cur;
        if (cur == prev) continue;
        try base.store.setFlag(t.flag, cur);

        var buf: [768]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var b_dt: [64]u8 = undefined;
        var b_dt2: [64]u8 = undefined;
        if (cur) {
            try w.print("{s} {s}: началось ретроградное движение", .{ t.body.glyph(), t.body.nameRu() });
            var wb: [retro.max_windows]?retro.Window = undefined;
            const n = retro.upcoming(t.body, base.now, &wb);
            if (n > 0) {
                const win = wb[0].?;
                const t1 = util.fmtDateTime(&b_dt, win.start, tz, base.now);
                const t2 = util.fmtDateTime(&b_dt2, win.end, tz, base.now);
                try w.print(": {s} — {s}", .{ t1, t2 });
            }
        } else {
            try w.print("{s} {s}: движение снова директное", .{ t.body.glyph(), t.body.nameRu() });
        }
        var snap: [128]i64 = undefined;
        notify.broadcast(base.api, base.store.subsSnapshot(&snap), w.buffered());
    }
}

const commands_list: [tracked.len]router.Command = blk: {
    var cmds: [tracked.len]router.Command = undefined;
    for (tracked, 0..) |t, i| {
        cmds[i] = .{ .name = t.cmd, .description = t.desc, .handler = cmdPlanet };
    }
    break :blk cmds;
};

pub const feature = features.Feature{
    .commands = &commands_list,
    .on_tick = onTick,
};
