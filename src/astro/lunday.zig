//! Лунные дни: N-й лунный день начинается, когда элонгация Луна–Солнце
//! пересекает (N-1)*12° (30-я часть лунного месяца, как в тибетско-индийской
//! традиции и большинстве «лунных календарей»). 1-й день — новолуние.
//!
//! Элонгация непрерывна и строго растёт (≥ ~10.5°/сутки) — считаем бисекцией.

const time = @import("time.zig");
const ang = @import("angles.zig");
const moonmod = @import("moon.zig");
const sunmod = @import("sun.zig");
const voc = @import("voc.zig");

pub const Info = struct {
    number: u8, // 1..30
    started: i64,
    ends: i64,
    sign: voc.Sign,
    illum_pct: f64,
    phase: []const u8,
};

const ElongFn = struct {
    pub fn eval(_: @This(), t: f64) f64 {
        return moonmod.longitudeRaw(t) - sunmod.longitudeRaw(t);
    }
};

pub fn assess(now_unix: i64) Info {
    const f = ElongFn{};
    const jd0 = time.jdFromUnix(now_unix);
    const e = f.eval(jd0);
    const e_wrapped = ang.wrap360(e);
    const number: u8 = @intFromFloat(@floor(e_wrapped / 12.0) + 1);

    const lower = @floor(e / 12.0) * 12.0; // граница текущего лунного дня
    const started_jd = ang.bisectRising(ElongFn, f, jd0 - 1.6, jd0, lower);
    const ends_jd = ang.bisectRising(ElongFn, f, jd0, jd0 + 1.6, lower + 12.0);

    return .{
        .number = number,
        .started = time.unixFromJd(started_jd),
        .ends = time.unixFromJd(ends_jd),
        .sign = voc.Sign.fromLongitude(moonmod.longitudeRaw(jd0)),
        .illum_pct = (1.0 - ang.cosD(e_wrapped)) / 2.0 * 100.0,
        .phase = phaseName(e_wrapped),
    };
}

pub fn phaseName(e: f64) []const u8 {
    if (e < 15.0 or e > 345.0) return "новолуние";
    if (e < 75.0) return "молодая луна";
    if (e < 105.0) return "первая четверть";
    if (e < 165.0) return "растущая луна";
    if (e < 195.0) return "полнолуние";
    if (e < 255.0) return "убывающая луна";
    if (e < 285.0) return "последняя четверть";
    return "старая луна";
}
