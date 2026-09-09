//! Геоцентрические долготы планет по кеплеровским элементам
//! (JPL/Standish, «Approximate Positions of the Major Planets», табл. 1,
//! точность 1800–2050 — угловые минуты). Долгота приводится к эклиптике даты
//! линейной прецессией, чтобы совпадать с рамкой формул Солнца и Луны.

const std = @import("std");
const time = @import("time.zig");
const ang = @import("angles.zig");
const sunmod = @import("sun.zig");

pub const Body = enum(u8) {
    sun,
    mercury,
    venus,
    mars,
    jupiter,
    saturn,
    uranus,
    neptune,
    pluto,

    pub fn nameRu(self: Body) []const u8 {
        return switch (self) {
            .sun => "Солнце",
            .mercury => "Меркурий",
            .venus => "Венера",
            .mars => "Марс",
            .jupiter => "Юпитер",
            .saturn => "Сатурн",
            .uranus => "Уран",
            .neptune => "Нептун",
            .pluto => "Плутон",
        };
    }

    pub fn glyph(self: Body) []const u8 {
        return switch (self) {
            .sun => "☉",
            .mercury => "☿",
            .venus => "♀",
            .mars => "♂",
            .jupiter => "♃",
            .saturn => "♄",
            .uranus => "♅",
            .neptune => "♆",
            .pluto => "♇",
        };
    }
};

/// Классические тела для расчёта Void of Course (видимые невооружённым глазом).
pub const classical = [_]Body{ .sun, .mercury, .venus, .mars, .jupiter, .saturn };

const El = struct {
    a: f64,
    e: f64,
    i: f64,
    L: f64,
    wbar: f64, // долгота перигелия
    om: f64, // долгота узла
    da: f64,
    de: f64,
    di: f64,
    dL: f64,
    dwbar: f64,
    dom: f64,
};

// Элементы на эпоху J2000 и их скорости за столетие (Standish, табл. 1).
const earth_el = El{
    .a = 1.00000261,
    .e = 0.01671123,
    .i = -0.00001531,
    .L = 100.46457166,
    .wbar = 102.93768193,
    .om = 0.0,
    .da = 0.00000562,
    .de = -0.00004392,
    .di = -0.01294668,
    .dL = 35999.37244981,
    .dwbar = 0.32327364,
    .dom = 0.0,
};

fn elements(b: Body) El {
    return switch (b) {
        .sun => unreachable, // долгота Солнца считается отдельно
        .mercury => .{
            .a = 0.38709927,
            .e = 0.20563593,
            .i = 7.00497902,
            .L = 252.25032350,
            .wbar = 77.45779628,
            .om = 48.33076593,
            .da = 0.00000037,
            .de = 0.00001906,
            .di = -0.00594749,
            .dL = 149472.67411175,
            .dwbar = 0.16047689,
            .dom = -0.12534081,
        },
        .venus => .{
            .a = 0.72333566,
            .e = 0.00677672,
            .i = 3.39467605,
            .L = 181.97909950,
            .wbar = 131.60246718,
            .om = 76.67984255,
            .da = 0.00000390,
            .de = -0.00004107,
            .di = -0.00078890,
            .dL = 58517.81538729,
            .dwbar = 0.00268329,
            .dom = -0.27769418,
        },
        .mars => .{
            .a = 1.52371034,
            .e = 0.09339410,
            .i = 1.84969142,
            .L = -4.55343205,
            .wbar = -23.94362959,
            .om = 49.55953891,
            .da = 0.00001847,
            .de = 0.00007882,
            .di = -0.00813131,
            .dL = 19140.30268499,
            .dwbar = 0.44441088,
            .dom = -0.29257343,
        },
        .jupiter => .{
            .a = 5.20288700,
            .e = 0.04838624,
            .i = 1.30439695,
            .L = 34.39644051,
            .wbar = 14.72847983,
            .om = 100.47390909,
            .da = -0.00011607,
            .de = -0.00013253,
            .di = -0.00183714,
            .dL = 3034.74612775,
            .dwbar = 0.21252668,
            .dom = 0.20469106,
        },
        .saturn => .{
            .a = 9.53667594,
            .e = 0.05386179,
            .i = 2.48599187,
            .L = 49.95424423,
            .wbar = 92.59887831,
            .om = 113.66242448,
            .da = -0.00125060,
            .de = -0.00050991,
            .di = 0.00193609,
            .dL = 1222.49362201,
            .dwbar = -0.41897216,
            .dom = -0.28867794,
        },
        .uranus => .{
            .a = 19.18916464,
            .e = 0.04725744,
            .i = 0.77263783,
            .L = 313.23810451,
            .wbar = 170.95427630,
            .om = 74.01692503,
            .da = -0.00196176,
            .de = -0.00004397,
            .di = -0.00242939,
            .dL = 428.48202785,
            .dwbar = 0.40805281,
            .dom = 0.04240589,
        },
        .neptune => .{
            .a = 30.06992276,
            .e = 0.00859048,
            .i = 1.77004347,
            .L = -55.12002969,
            .wbar = 44.96476227,
            .om = 131.78422574,
            .da = 0.00026291,
            .de = 0.00005105,
            .di = 0.00035372,
            .dL = 218.45945325,
            .dwbar = -0.32241464,
            .dom = -0.00508664,
        },
        .pluto => .{
            .a = 39.48211675,
            .e = 0.24882730,
            .i = 17.14001206,
            .L = 238.92903833,
            .wbar = 224.06891629,
            .om = 110.30393684,
            .da = -0.00031596,
            .de = 0.00005170,
            .di = 0.00004818,
            .dL = 145.20780515,
            .dwbar = -0.04062942,
            .dom = -0.01183482,
        },
    };
}

const Vec = struct { x: f64, y: f64, z: f64 };

fn heliocentric(el: El, T: f64) Vec {
    const a = el.a + el.da * T;
    const e = el.e + el.de * T;
    const inc = el.i + el.di * T;
    const L = el.L + el.dL * T;
    const wbar = el.wbar + el.dwbar * T;
    const om = el.om + el.dom * T;
    const w = wbar - om;
    const M = ang.wrap180(L - wbar);

    // Кеплер: E - e*sin(E) = M, метод Ньютона.
    var E = M * ang.DEG;
    const Mr = M * ang.DEG;
    for (0..12) |_| {
        const f = E - e * @sin(E) - Mr;
        E -= f / (1.0 - e * @cos(E));
    }

    const xp = a * (@cos(E) - e);
    const yp = a * @sqrt(1.0 - e * e) * @sin(E);

    const cw = @cos(w * ang.DEG);
    const sw = @sin(w * ang.DEG);
    const co = @cos(om * ang.DEG);
    const so = @sin(om * ang.DEG);
    const ci = @cos(inc * ang.DEG);
    const si = @sin(inc * ang.DEG);

    return .{
        .x = (cw * co - sw * so * ci) * xp + (-sw * co - cw * so * ci) * yp,
        .y = (cw * so + sw * co * ci) * xp + (-sw * so + cw * co * ci) * yp,
        .z = (sw * si) * xp + (cw * si) * yp,
    };
}

/// Геоцентрическая долгота тела в [0, 360), эклиптика даты.
pub fn longitude(b: Body, jd: f64) f64 {
    if (b == .sun) return ang.wrap360(sunmod.longitudeRaw(jd));
    const T = time.centuriesSinceJ2000(jd);
    const p = heliocentric(elements(b), T);
    const e = heliocentric(earth_el, T);
    const x = p.x - e.x;
    const y = p.y - e.y;
    var lam = std.math.atan2(y, x) / ang.DEG;
    lam += 1.3972 * T; // общая прецессия ~50.3"/год к дате
    return ang.wrap360(lam);
}
