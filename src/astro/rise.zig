//! Восход Луны для наблюдателя — граница лунных суток «от восхода до восхода».
//! Эклиптика → экватор (Meeus 13), звёздное время (Meeus 12), восход как момент,
//! когда высота центра Луны проходит h0 = 0.7275·π − 34′ ≈ +0.125° (Meeus 15):
//! рефракция опускает горизонт, параллакс (~0.95°) — поднимает Луну. Параллакс
//! взят средним, поэтому точность моментов — единицы минут.

const std = @import("std");
const ang = @import("angles.zig");
const time = @import("time.zig");
const moon = @import("moon.zig");

pub const Observer = struct {
    lat_deg: f64,
    /// Восточная долгота положительна.
    lon_deg: f64,
};

/// Высота центра Луны в момент восхода/захода.
const h0: f64 = 0.125;

/// Шаг скана — 14.4 мин; высота Луны у горизонта меняется < 4° за шаг,
/// пересечение не пропустим.
const scan_step = 0.01;

/// Окно поиска восхода — до 10 суток: на высоких широтах (от ~62° с.ш.,
/// Архангельск/Салехард/Мурманск) интервалы между восходами Луны превышают
/// сутки, вплоть до многодневных пауз — окно 1.3 сут убивало всю систему
/// «от восхода» уже на 65°. Скан останавливается на первом пересечении,
/// поэтому для средних широт стоимость не меняется.
const scan_window = 10.0;

fn obliquity(jd: f64) f64 {
    const T = time.centuriesSinceJ2000(jd);
    return 23.43929111 - 0.01300416 * T - 1.639e-7 * T * T + 5.036e-7 * T * T * T;
}

/// Геоцентрическая высота центра Луны над горизонтом наблюдателя, градусы.
pub fn altitude(obs: Observer, jd: f64) f64 {
    const lam = moon.longitudeRaw(jd);
    const bet = moon.latitude(jd);
    const eps = obliquity(jd);
    const sl = ang.sinD(lam);
    const cl = ang.cosD(lam);
    const sb = ang.sinD(bet);
    const cb = ang.cosD(bet);
    const se = ang.sinD(eps);
    const ce = ang.cosD(eps);

    const sin_dec = sb * ce + cb * se * sl;
    const cos_dec = @sqrt(1.0 - sin_dec * sin_dec);
    const ra = std.math.atan2(sl * ce - (sb / cb) * se, cl) / ang.DEG;
    const hour_angle = time.gmstDeg(jd) + obs.lon_deg - ra;

    const sin_h = ang.sinD(obs.lat_deg) * sin_dec + ang.cosD(obs.lat_deg) * cos_dec * ang.cosD(hour_angle);
    return std.math.asin(sin_h) / ang.DEG;
}

const AltFn = struct {
    obs: Observer,
    pub fn eval(self: @This(), t: f64) f64 {
        return altitude(self.obs, t) - h0;
    }
};

/// Ближайший восход Луны строго после t0 (unix) в пределах ~10 суток.
/// null — восхода нет (полярные широты, многодневная пауза).
pub fn nextRise(obs: Observer, t0: i64) ?i64 {
    const f = AltFn{ .obs = obs };
    var t = time.jdFromUnix(t0);
    const t_hi = t + scan_window;
    var g = f.eval(t);
    while (t < t_hi) {
        const tn = @min(t + scan_step, t_hi);
        const gn = f.eval(tn);
        if (g < 0 and gn >= 0) return time.unixFromJd(ang.bisectSign(AltFn, f, t, tn));
        t = tn;
        g = gn;
    }
    return null;
}
