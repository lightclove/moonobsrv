//! Фича «Ретроградный Меркурий»: команда /mercury и уведомления о станциях.

const std = @import("std");
const router = @import("../bot/router.zig");
const notify = @import("../bot/notify.zig");
const features = @import("features.zig");
const astro = @import("../astro.zig");
const util = @import("../util.zig");

const retro = astro.retro;

fn cmdMercury(ctx: *router.Ctx) !void {
    const now = try ctx.moment();
    try writeStatus(now, ctx.base.cfg.tz_offset_sec, ctx.reply);
}

pub fn writeStatus(now: i64, tz: i32, w: *std.Io.Writer) !void {
    const is_retro = retro.isRetro(.mercury, now);
    var wb: [retro.max_windows]?retro.Window = undefined;
    const n = retro.upcoming(.mercury, now, &wb);

    var b_dt: [64]u8 = undefined;
    var b_dt2: [64]u8 = undefined;
    var b_dur: [32]u8 = undefined;

    if (is_retro and n > 0) {
        const win = wb[0].?;
        const t1 = util.fmtDateTime(&b_dt, win.start, tz, now);
        const t2 = util.fmtDateTime(&b_dt2, win.end, tz, now);
        try w.print("☿ Меркурий РЕТРОГРАДЕН\n", .{});
        try w.print("Период: {s} — {s} (осталось {s})\n", .{ t1, t2, util.fmtDur(&b_dur, win.end - now) });
        try w.print("Пост-тень до {s} — перепроверьте важное.\n\n", .{
            util.fmtDateTime(&b_dt, win.post_shadow, tz, now),
        });
        try w.print("Договоры, крупные покупки и запуски лучше отложить; зато время возвращаться к незавершённым делам, ревизии и правкам.", .{});
        if (n > 1) {
            const nx = wb[1].?;
            const n1 = util.fmtDateTime(&b_dt, nx.start, tz, now);
            const n2 = util.fmtDateTime(&b_dt2, nx.end, tz, now);
            try w.print("\n\nСледующий ретро-период: {s} — {s}.", .{ n1, n2 });
        }
        return;
    }

    try w.print("☿ Меркурий директен (ретроградности нет)\n", .{});
    if (n > 0) {
        const win = wb[0].?;
        const t1 = util.fmtDateTime(&b_dt, win.start, tz, now);
        const t2 = util.fmtDateTime(&b_dt2, win.end, tz, now);
        try w.print("Ближайший ретро-период: {s} — {s}\n", .{ t1, t2 });
        const p1 = util.fmtDateTime(&b_dt, win.pre_shadow, tz, now);
        const p2 = util.fmtDateTime(&b_dt2, win.post_shadow, tz, now);
        try w.print("Пред-тень с {s}, пост-тень до {s}\n", .{ p1, p2 });
        if (n > 1) {
            const nx = wb[1].?;
            const n1 = util.fmtDateTime(&b_dt, nx.start, tz, now);
            const n2 = util.fmtDateTime(&b_dt2, nx.end, tz, now);
            try w.print("Затем: {s} — {s}", .{ n1, n2 });
        }
    }
}

pub fn onTick(base: router.Base) !void {
    const is_retro = retro.isRetro(.mercury, base.now);
    const prev = base.store.getFlag(.mercury_retro) orelse is_retro;
    if (is_retro == prev) return;

    try base.store.setFlag(.mercury_retro, is_retro);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var b_dt: [64]u8 = undefined;
    var b_dt2: [64]u8 = undefined;
    const tz = base.cfg.tz_offset_sec;

    if (is_retro) {
        var wb: [retro.max_windows]?retro.Window = undefined;
        const n = retro.upcoming(.mercury, base.now, &wb);
        try w.print("☿ Меркурий стал РЕТРОГРАДНЫМ", .{});
        if (n > 0) {
            const win = wb[0].?;
            const t1 = util.fmtDateTime(&b_dt, win.start, tz, base.now);
            const t2 = util.fmtDateTime(&b_dt2, win.end, tz, base.now);
            try w.print(": {s} — {s}", .{ t1, t2 });
        }
        try w.print("\n\nПроверяйте технику, договоры и данные дважды; вернитесь к отложенным делам.", .{});
    } else {
        try w.print("☿ Меркурий снова директен", .{});
        // Окно, которое только что закончилось: ищем от точки за 40 суток
        // до сейчас (ретро длится ~21 сутки, значит старт будем прямым).
        var wback: [retro.max_windows]?retro.Window = undefined;
        const nb = retro.upcoming(.mercury, base.now - 40 * 86400, &wback);
        if (nb > 0) {
            const done = wback[0].?;
            if (done.end <= base.now) {
                try w.print(". Пост-тень до {s}", .{
                    util.fmtDateTime(&b_dt, done.post_shadow, tz, base.now),
                });
            }
        }
        try w.print("\n\nПланы можно запускать, но ещё раз проверьте начатое в ретро.", .{});
    }
    var snap: [256]i64 = undefined;
    notify.broadcast(base.api, base.store.subsSnapshot(&snap), w.buffered());
}

pub const feature = features.Feature{
    .commands = &.{
        .{
            .name = "/mercury",
            .aliases = &.{ "/retro", "/меркурий" },
            .description = "ретро-Меркурий: сейчас/на дату, периоды с тенями",
            .handler = cmdMercury,
        },
    },
    .on_tick = onTick,
};
