//! Угловая математика и численные решатели (бисекция).
//! Все функции принимают JD; углы — в градусах.

const std = @import("std");

pub const DEG: f64 = std.math.pi / 180.0;

pub fn wrap360(x: f64) f64 {
    return @mod(x, 360.0);
}

/// Нормализация в (-180, 180].
pub fn wrap180(x: f64) f64 {
    var v = @mod(x, 360.0);
    if (v > 180.0) v -= 360.0;
    return v;
}

pub fn sinD(x: f64) f64 {
    return @sin(x * DEG);
}

pub fn cosD(x: f64) f64 {
    return @cos(x * DEG);
}

/// Шаг сканирования при поиске нулей «пилы»: ~29 минут.
/// Разделение Луны с планетой растёт минимум на ~9.8°/сутки,
/// поэтому за шаг сепарация меняется меньше чем на градус — переход не пропустим.
const scan_step = 0.02;

/// Следующий переход через ноль функции g(t) = wrap180(f(t)).
/// g внутри периода непрерывна и возрастает (скачки только на +180 -> -180).
pub fn nextZero(comptime F: type, f: F, t0: f64, t_hi: f64) ?f64 {
    var t = t0;
    var g = f.eval(t);
    while (t < t_hi) {
        const tn = @min(t + scan_step, t_hi);
        const gn = f.eval(tn);
        if (g < 0 and gn >= 0) return bisectSigned(F, f, t, tn);
        t = tn;
        g = gn;
    }
    return null;
}

/// Предыдущий переход через ноль g(t) = wrap180(f(t)) не раньше t_lo.
pub fn prevZero(comptime F: type, f: F, t_lo: f64, t0: f64) ?f64 {
    var t = t0;
    var g = f.eval(t);
    while (t > t_lo) {
        const tp = @max(t - scan_step, t_lo);
        const gp = f.eval(tp);
        if (g >= 0 and gp < 0) return bisectSigned(F, f, tp, t);
        t = tp;
        g = gp;
    }
    return null;
}

fn bisectSigned(comptime F: type, f: F, a: f64, b: f64) f64 {
    var lo = a;
    var hi = b;
    for (0..28) |_| {
        const m = 0.5 * (lo + hi);
        if (f.eval(m) < 0) lo = m else hi = m;
    }
    return 0.5 * (lo + hi);
}

/// Бисекция строго возрастающей функции: f(a) < target <= f(b).
pub fn bisectRising(comptime F: type, f: F, a: f64, b: f64, target: f64) f64 {
    var lo = a;
    var hi = b;
    for (0..34) |_| {
        const m = 0.5 * (lo + hi);
        if (f.eval(m) < target) lo = m else hi = m;
    }
    return 0.5 * (lo + hi);
}

/// Бисекция непрерывной функции, меняющей знак на [a, b].
pub fn bisectSign(comptime F: type, f: F, a: f64, b: f64) f64 {
    var lo = a;
    var hi = b;
    const neg_lo = f.eval(lo) < 0;
    for (0..40) |_| {
        const m = 0.5 * (lo + hi);
        if ((f.eval(m) < 0) == neg_lo) lo = m else hi = m;
    }
    return 0.5 * (lo + hi);
}
