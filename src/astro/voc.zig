//! Холостая Луна (Void of Course): Луна не образует ни одного точного
//! птолемеевского аспета к классическим телам до выхода из знака.
//!
//! Ключевое наблюдение: за окно ≤ 2.5 суток сепарация Луна–планета строго
//! растёт (скорость 10–16°/сутки), поэтому моменты точных аспектов ищутся
//! переходами wrap180(разделение) через ноль — см. angles.nextZero.

const time = @import("time.zig");
const ang = @import("angles.zig");
const moonmod = @import("moon.zig");
const sunmod = @import("sun.zig");
const planets = @import("planets.zig");
const aspects = @import("aspects.zig");

pub const Sign = enum(u8) {
    aries,
    taurus,
    gemini,
    cancer,
    leo,
    virgo,
    libra,
    scorpio,
    sagittarius,
    capricorn,
    aquarius,
    pisces,

    pub fn fromLongitude(lam: f64) Sign {
        const idx: u8 = @intFromFloat(@min(@floor(ang.wrap360(lam) / 30.0), 11));
        return @enumFromInt(idx);
    }

    pub fn next(self: Sign) Sign {
        return @enumFromInt((@intFromEnum(self) + 1) % 12);
    }

    pub fn nameRu(self: Sign) []const u8 {
        return sign_names[@intFromEnum(self)];
    }

    /// Предложный падеж с предлогом: «в Весах», «во Льве».
    pub fn inRu(self: Sign) []const u8 {
        return sign_in[@intFromEnum(self)];
    }

    /// Винительный падеж с предлогом: «в Деву», «во Льва».
    pub fn accRu(self: Sign) []const u8 {
        return sign_acc[@intFromEnum(self)];
    }

    pub fn glyph(self: Sign) []const u8 {
        return sign_glyphs[@intFromEnum(self)];
    }
};

const sign_names = [_][]const u8{ "Овен", "Телец", "Близнецы", "Рак", "Лев", "Дева", "Весы", "Скорпион", "Стрелец", "Козерог", "Водолей", "Рыбы" };
const sign_in = [_][]const u8{ "в Овне", "в Тельце", "в Близнецах", "в Раке", "во Льве", "в Деве", "в Весах", "в Скорпионе", "в Стрельце", "в Козероге", "в Водолее", "в Рыбах" };
const sign_acc = [_][]const u8{ "в Овна", "в Тельца", "в Близнецы", "в Рака", "во Льва", "в Деву", "в Весы", "в Скорпиона", "в Стрельца", "в Козерога", "в Водолея", "в Рыбы" };
const sign_glyphs = [_][]const u8{ "♈", "♉", "♊", "♋", "♌", "♍", "♎", "♏", "♐", "♑", "♒", "♓" };

pub const AspectEvent = struct {
    body: planets.Body,
    aspect: aspects.Aspect,
    t: i64, // Unix
};

pub const max_aspects = 24;

pub const Status = struct {
    now: i64,
    sign: Sign,
    /// Вход Луны в текущий знак, Unix.
    sign_entered: i64,
    /// Выход в следующий знак, Unix.
    ingress: i64,
    /// Пройдено процентов знака.
    progress_pct: f64,
    /// Все точные аспекты Луны в текущем знаке (по возрастанию времени).
    aspects: []const AspectEvent,
    /// Холостая ли Луна прямо сейчас.
    is_voc: bool,
    /// Начало текущего/ближайшего холостого периода
    /// (последний аспект или вход в знак).
    voc_started: i64,
    voc_last_aspect: ?AspectEvent,
};

const BoundaryFn = struct {
    target: f64,
    pub fn eval(self: @This(), t: f64) f64 {
        return ang.wrap180(moonmod.longitudeRaw(t) - self.target);
    }
};

const SepFn = struct {
    body: planets.Body,
    offset: f64, // +угол или -угол
    pub fn eval(self: @This(), t: f64) f64 {
        const p = if (self.body == .sun)
            sunmod.longitudeRaw(t)
        else
            planets.longitude(self.body, t);
        return ang.wrap180(moonmod.longitudeRaw(t) - p + self.offset);
    }
};

pub fn assess(now_unix: i64, buf: *[max_aspects]AspectEvent) Status {
    const jd0 = time.jdFromUnix(now_unix);
    const lam = moonmod.longitudeRaw(jd0);
    const cur = ang.wrap360(lam);
    const idx: u8 = @intFromFloat(@min(@floor(cur / 30.0), 11));
    const sign: Sign = @enumFromInt(idx);
    const b_cur = @as(f64, @floatFromInt(idx)) * 30.0;
    const b_next = b_cur + 30.0;

    // Луна пересекает 30° не медленнее чем за ~2.55 суток.
    const ingress_jd = ang.nextZero(BoundaryFn, .{ .target = b_next }, jd0, jd0 + 2.6) orelse jd0 + 1.0;
    const entered_jd = ang.prevZero(BoundaryFn, .{ .target = b_cur }, jd0 - 2.6, jd0) orelse jd0 - 1.0;

    var n: usize = 0;
    for (planets.classical) |body| {
        for (aspects.all) |asp| {
            // Соединение (0°) и оппозиция (180°) симметричны: смещения +a и −a
            // задают одну и ту же функцию (различие кратно 360°, wrap180 его
            // съедает) — ищем однократно, иначе событие попадёт в список дважды.
            const a = asp.angleOf();
            const offs: []const f64 = if (asp == .conjunction)
                &[_]f64{0.0}
            else if (asp == .opposition)
                &[_]f64{180.0}
            else
                &[_]f64{ a, -a };
            for (offs) |off| {
                const f = SepFn{ .body = body, .offset = off };
                var t = entered_jd;
                while (t < ingress_jd) {
                    const z = ang.nextZero(SepFn, f, t, ingress_jd) orelse break;
                    if (n < max_aspects) {
                        buf[n] = .{ .body = body, .aspect = asp, .t = time.unixFromJd(z) };
                        n += 1;
                    }
                    t = z + 0.02;
                }
            }
        }
    }

    // сортировка вставками по времени
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = buf[i];
        var j = i;
        while (j > 0 and buf[j - 1].t > key.t) : (j -= 1) buf[j] = buf[j - 1];
        buf[j] = key;
    }

    var last_le_now: ?AspectEvent = null;
    var any_after_now = false;
    for (buf[0..n]) |ev| {
        if (ev.t <= now_unix) last_le_now = ev else any_after_now = true;
    }

    return .{
        .now = now_unix,
        .sign = sign,
        .sign_entered = time.unixFromJd(entered_jd),
        .ingress = time.unixFromJd(ingress_jd),
        .progress_pct = (cur - b_cur) / 30.0 * 100.0,
        .aspects = buf[0..n],
        .is_voc = !any_after_now,
        .voc_started = if (last_le_now) |ev| ev.t else time.unixFromJd(entered_jd),
        .voc_last_aspect = last_le_now,
    };
}
