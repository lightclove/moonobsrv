//! Хаб астрономического ядра. Ядро чистое: только f64 на входе/выходе,
//! без аллокаций (буферы передаются вызывающим) и без зависимостей от бота.

pub const time = @import("astro/time.zig");
pub const angles = @import("astro/angles.zig");
pub const aspects = @import("astro/aspects.zig");
pub const sun = @import("astro/sun.zig");
pub const moon = @import("astro/moon.zig");
pub const planets = @import("astro/planets.zig");
pub const retro = @import("astro/retro.zig");
pub const voc = @import("astro/voc.zig");
pub const lunday = @import("astro/lunday.zig");
