//! Ретроградность: станции и «тени» для любой планеты.
//! Скорость долготы оценивается центральной разностью; знак скорости
//! меняется плавно, поэтому станции ищутся сканом + бисекцией.

const time = @import("time.zig");
const ang = @import("angles.zig");
const planets = @import("planets.zig");

pub const max_windows = 4;

pub const Window = struct {
    /// Начало ретро-периода (станция директ -> ретро), Unix-секунды.
    start: i64,
    /// Конец ретро-периода (станция ретро -> директ).
    end: i64,
    /// Пред-тень: последний проход по градусу будущей станции.
    pre_shadow: i64,
    /// Пост-тень: возвращение к градусу начала ретро.
    post_shadow: i64,

    pub fn contains(self: Window, t: i64) bool {
        return self.start <= t and t <= self.end;
    }
};

const SpeedFn = struct {
    body: planets.Body,
    h: f64 = 0.25,
    pub fn eval(self: @This(), jd: f64) f64 {
        const hi = planets.longitude(self.body, jd + self.h);
        const lo = planets.longitude(self.body, jd - self.h);
        return ang.wrap180(hi - lo) / (2.0 * self.h);
    }
};

const LonFn = struct {
    body: planets.Body,
    target: f64,
    pub fn eval(self: @This(), jd: f64) f64 {
        return ang.wrap180(planets.longitude(self.body, jd) - self.target);
    }
};

pub fn isRetro(body: planets.Body, now_unix: i64) bool {
    const speed = SpeedFn{ .body = body };
    return speed.eval(time.jdFromUnix(now_unix)) < 0;
}

/// Окна ретро-периодов начиная с from_unix (первое может уже идти).
/// Возвращает количество заполненных окон.
pub fn upcoming(body: planets.Body, from_unix: i64, out: *[max_windows]?Window) usize {
    const speed = SpeedFn{ .body = body };
    const jd0 = time.jdFromUnix(from_unix);
    var in_retro = speed.eval(jd0) < 0;
    var start_jd = jd0;

    if (in_retro) {
        // ищем фактическую станцию назад: ретро Меркурия ~3 недели, внешних
        // планет — до ~5 месяцев (Плутон), окно 200 суток покрывает всех
        var found = false;
        var tb = jd0;
        while (jd0 - tb < 200.0) : (tb -= 0.5) {
            if (speed.eval(tb) >= 0) {
                start_jd = ang.bisectSign(SpeedFn, speed, tb, tb + 0.5);
                found = true;
                break;
            }
        }
        if (!found) start_jd = jd0;
    }

    var count: usize = 0;
    var prev = speed.eval(jd0);
    var t = jd0;
    const horizon = jd0 + 420.0;
    while (t < horizon and count < max_windows) {
        t += 1.0;
        const s = speed.eval(t);
        if (!in_retro and prev > 0 and s <= 0) {
            start_jd = ang.bisectSign(SpeedFn, speed, t - 1.0, t);
            in_retro = true;
        } else if (in_retro and prev < 0 and s >= 0) {
            const end_jd = ang.bisectSign(SpeedFn, speed, t - 1.0, t);
            out[count] = makeWindow(body, start_jd, end_jd);
            count += 1;
            in_retro = false;
        }
        prev = s;
    }
    return count;
}

fn makeWindow(body: planets.Body, start_jd: f64, end_jd: f64) Window {
    const lam_start = planets.longitude(body, start_jd);
    const lam_end = planets.longitude(body, end_jd);

    // Тени длятся дольше ретро: медленная дуга обратно для внешних планет
    // занимает месяцы (Венера ~32 сут, Плутон ~100+). Окно 200 суток —
    // иначе тени «схлопывались» в границы ретро-периода (было у 7 из 8 тел).
    const pre_fn = LonFn{ .body = body, .target = lam_end };
    var pre_jd = start_jd;
    var tp = start_jd - 1.0;
    while (start_jd - tp < 200.0) : (tp -= 1.0) {
        if (pre_fn.eval(tp) < 0) {
            pre_jd = ang.bisectSign(LonFn, pre_fn, tp, tp + 1.0);
            break;
        }
    }

    // Пост-тень: вперёд до градуса станции ретро (лам_старт).
    const post_fn = LonFn{ .body = body, .target = lam_start };
    var post_jd = end_jd;
    var tq = end_jd + 1.0;
    while (tq - end_jd < 200.0) : (tq += 1.0) {
        if (post_fn.eval(tq) > 0) {
            post_jd = ang.bisectSign(LonFn, post_fn, tq - 1.0, tq);
            break;
        }
    }

    return .{
        .start = time.unixFromJd(start_jd),
        .end = time.unixFromJd(end_jd),
        .pre_shadow = time.unixFromJd(pre_jd),
        .post_shadow = time.unixFromJd(post_jd),
    };
}
