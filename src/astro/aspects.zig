//! Птолемеевские аспекты.

pub const Aspect = enum(u8) {
    conjunction,
    sextile,
    square,
    trine,
    opposition,

    pub fn angleOf(self: Aspect) f64 {
        return switch (self) {
            .conjunction => 0.0,
            .sextile => 60.0,
            .square => 90.0,
            .trine => 120.0,
            .opposition => 180.0,
        };
    }

    pub fn nameRu(self: Aspect) []const u8 {
        return switch (self) {
            .conjunction => "соединение",
            .sextile => "секстиль",
            .square => "квадрат",
            .trine => "трин",
            .opposition => "оппозиция",
        };
    }

    pub fn glyph(self: Aspect) []const u8 {
        return switch (self) {
            .conjunction => "☌",
            .sextile => "✶",
            .square => "□",
            .trine => "△",
            .opposition => "☍",
        };
    }
};

pub const all = [_]Aspect{ .conjunction, .sextile, .square, .trine, .opposition };
