//! Лунные сутки «от восхода до восхода» — русская астрологическая традиция
//! (П. Глоба, массовые лунные календари): 1-е сутки — с момента новолуния до
//! первого восхода Луны, каждые следующие — от восхода до восхода, последние
//! (29-е или 30-е) обрывает новолуние. В отличие от титхи (lunday.zig) зависят
//! от места наблюдателя, длятся ~24–26 ч и к концу месяца отстают от титхи
//! на 1–2 номера.

const std = @import("std");
const time = @import("time.zig");
const lunday = @import("lunday.zig");
const rise = @import("rise.zig");

pub const Info = struct {
    number: u8, // 1..30
    started: i64,
    ends: i64,
};

/// null — Луна не восходит вовсе (полярные широты): системы «от восхода» нет.
pub fn assess(now_unix: i64, obs: rise.Observer) ?Info {
    const jd0 = time.jdFromUnix(now_unix);
    const new_moon = time.unixFromJd(lunday.lastNewMoonJd(jd0));

    var count: u8 = 0;
    var started = new_moon;
    var r = rise.nextRise(obs, new_moon) orelse return null;
    while (r <= now_unix and count < 31) {
        count += 1;
        started = r;
        // высокие широты: пауза восходов может длиться днями — текущие сутки
        // в этом случае тянутся до новолуния, а не роняют всю систему
        r = rise.nextRise(obs, r + 60) orelse {
            r = std.math.maxInt(i64);
            break;
        };
    }

    var ends = time.unixFromJd(lunday.nextNewMoonJd(jd0));
    if (r > now_unix and r < ends) ends = r;
    return .{ .number = count + 1, .started = started, .ends = ends };
}
