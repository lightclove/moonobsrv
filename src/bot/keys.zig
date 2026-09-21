//! Клавиатура запросов (reply keyboard): постоянные кнопки под полем ввода.
//! Тап по кнопке присылает текст-метку как обычное сообщение, диспетчер
//! подменяет метку командой (keys.effective) — весь путь команды, включая
//! гейт доступа, работает без изменений. Отдельно от inline-кнопок
//! (гид/меню/заявки): у сообщения один reply_markup, и «всегда видимая»
//! клавиатура бывает только reply, не inline.

const std = @import("std");

/// Кнопка быстрого запроса: label — текст на кнопке (он же приходит
/// сообщением), cmd — команда из реестра, которую она запускает.
pub const Quick = struct {
    label: []const u8,
    cmd: []const u8,
};

/// Пункты те же, что в inline-меню (cb.zig menuKb) — один словарь запросов.
pub const quick = [_]Quick{
    .{ .label = "🌑 Луна сейчас", .cmd = "/voc" },
    .{ .label = "🌗 Лунный день", .cmd = "/day" },
    .{ .label = "☿ Меркурий", .cmd = "/mercury" },
    .{ .label = "🪐 Планеты", .cmd = "/planets" },
    .{ .label = "🔔 Подписка", .cmd = "/subscribe" },
    .{ .label = "🚀 Гид", .cmd = "/wizard" },
};

/// ReplyKeyboardMarkup: по две кнопки в строке, подгоняется по ширине
/// (resize_keyboard) и не сворачивается в иконку (is_persistent).
pub fn markup(w: *std.Io.Writer) !void {
    try w.writeAll("{\"keyboard\":[");
    var first = true;
    var i: usize = 0;
    while (i < quick.len) : (i += 2) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeByte('[');
        var j: usize = 0;
        while (j < 2 and i + j < quick.len) : (j += 1) {
            if (j > 0) try w.writeByte(',');
            try w.writeAll("{\"text\":");
            try std.json.Stringify.value(quick[i + j].label, .{}, w);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.writeAll("],\"resize_keyboard\":true,\"is_persistent\":true,\"input_field_placeholder\":\"или команда, напр. /voc 21.09\"}");
}

/// Метка кнопки → имя команды; null — текст не с кнопок.
pub fn resolve(text: []const u8) ?[]const u8 {
    for (quick) |q| {
        if (std.mem.eql(u8, q.label, text)) return q.cmd;
    }
    return null;
}

/// Текст, который дойдёт до роутера команд: метка кнопки подменяется
/// командой, всё остальное (включая «/…») — без изменений.
pub fn effective(text: []const u8) []const u8 {
    return resolve(text) orelse text;
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "markup: валидный ReplyKeyboardMarkup со всеми метками" {
    var kb: [768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&kb);
    try markup(&w);
    const s = w.buffered();
    // валидный JSON целиком
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, s, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.contains("keyboard"));
    // флаги постоянной клавиатуры
    try std.testing.expect(std.mem.indexOf(u8, s, "\"resize_keyboard\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"is_persistent\":true") != null);
    // каждая метка попала на клавиатуру
    for (quick) |q| {
        try std.testing.expect(std.mem.indexOf(u8, s, q.label) != null);
    }
}

test "resolve/effective: метка → команда, чужой текст не трогаем" {
    try std.testing.expectEqualStrings("/voc", resolve("🌑 Луна сейчас").?);
    try std.testing.expectEqualStrings("/wizard", resolve("🚀 Гид").?);
    try std.testing.expect(resolve("привет") == null);
    try std.testing.expect(resolve("") == null);
    try std.testing.expectEqualStrings("/voc", effective("🌑 Луна сейчас"));
    try std.testing.expectEqualStrings("/voc 21.09", effective("/voc 21.09"));
    try std.testing.expectEqualStrings("привет", effective("привет"));
}

test "кнопки ссылаются на живые команды реестра (анти-BUG-037)" {
    const features = @import("../features/features.zig");
    const router = @import("router.zig");
    for (quick) |q| {
        if (router.match(&features.commands, q.cmd)) |m| {
            try std.testing.expectEqualStrings(q.cmd, m.cmd.name);
        } else {
            std.debug.print("кнопка «{s}» ссылается на несуществующую команду {s}\n", .{ q.label, q.cmd });
            return error.StaleQuickButton;
        }
    }
}

test "метки уникальны и не выглядят командами" {
    for (quick, 0..) |q, i| {
        try std.testing.expect(q.label.len > 0 and q.label[0] != '/');
        for (quick[i + 1 ..]) |o| {
            try std.testing.expect(!std.mem.eql(u8, q.label, o.label));
        }
    }
}
