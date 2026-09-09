//! Минимальный загрузчик .env: строки KEY=VALUE, '#'-комментарии,
//! необязательные кавычки вокруг значения. Ключи, уже присутствующие в карте
//! окружения (т.е. реальные переменные), не перезаписываются — файл только
//! заполняет пробелы.
//!
//! Значения ссылаются на содержимое файла, поэтому память под него не
//! освобождается: загрузка выполняется один раз при старте, строки живут
//! в конфиге весь срок работы процесса.

const std = @import("std");

/// Читает файл и применяет его к карте окружения. Отсутствие файла — норма.
pub fn apply(alloc: std.mem.Allocator, env: *std.process.EnvMap, path: []const u8) void {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return;
    parseInto(env, bytes);
}

/// .env рядом с исполняемым файлом — чтобы работало при запуске не из
/// каталога проекта (двойной клик, ярлык, сервис).
pub fn applyNearExe(alloc: std.mem.Allocator, env: *std.process.EnvMap) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.selfExeDirPath(&buf) catch return;
    const path = std.fs.path.join(alloc, &.{ dir, ".env" }) catch return;
    defer alloc.free(path);
    apply(alloc, env, path);
}

/// Разбор содержимого env-файла. Слайсы ссылаются на `bytes`.
pub fn parseInto(env: *std.process.EnvMap, bytes_in: []const u8) void {
    // Windows PowerShell пишет UTF-8 с BOM — первые три байта ломали бы ключ.
    const bytes = if (std.mem.startsWith(u8, bytes_in, "\xEF\xBB\xBF")) bytes_in[3..] else bytes_in;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
            val = val[1 .. val.len - 1];
        }
        if (key.len == 0) continue;
        if (env.get(key) != null) continue; // реальное окружение приоритетнее
        env.put(key, val) catch {};
    }
}

test "parseInto: BOM от PowerShell не ломает первый ключ" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    parseInto(&env, "\xEF\xBB\xBFMOONOBSRV_TZ=5\nTELEGRAM_TOKEN=t\n");
    try std.testing.expectEqualStrings("5", env.get("MOONOBSRV_TZ").?);
    try std.testing.expectEqualStrings("t", env.get("TELEGRAM_TOKEN").?);
}

test "parseInto: комментарии, кавычки, приоритет окружения" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("REAL", "from-env");

    parseInto(&env, "# комментарий\n" ++
        "TOKEN=abc\n" ++
        "  SPACED = 42  \n" ++
        "QUOTED=\"значение с пробелами\"\n" ++
        "SINGLE='одинарные'\n" ++
        "REAL=from-file\n" ++
        "строка без знака равно\n" ++
        "EMPTY=\n" ++
        "\n");
    try std.testing.expectEqualStrings("abc", env.get("TOKEN").?);
    try std.testing.expectEqualStrings("42", env.get("SPACED").?);
    try std.testing.expectEqualStrings("значение с пробелами", env.get("QUOTED").?);
    try std.testing.expectEqualStrings("одинарные", env.get("SINGLE").?);
    try std.testing.expectEqualStrings("from-env", env.get("REAL").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expect(env.get("строка") == null);
}
