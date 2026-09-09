//! Видимая эклиптическая долгота Солнца (Meeus, «Astronomical Algorithms», гл. 25).
//! Точность ~0.01°. Функция непрерывна и не нормируется в [0, 360) —
//! это важно для монотонных решателей.

const ang = @import("angles.zig");

pub fn longitudeRaw(jd: f64) f64 {
    const T = (jd - 2451545.0) / 36525.0;
    const L0 = 280.46646 + 36000.76983 * T + 0.0003032 * T * T;
    const M = 357.52911 + 35999.05029 * T - 0.0001537 * T * T;
    const C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * ang.sinD(M) +
        (0.019993 - 0.000101 * T) * ang.sinD(2 * M) +
        0.000289 * ang.sinD(3 * M);
    const omega = 125.04 - 1934.136 * T;
    // nutation + aberration
    return L0 + C - 0.00569 - 0.00478 * ang.sinD(omega);
}
