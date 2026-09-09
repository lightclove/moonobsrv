//! Конфигурация. Приоритет источников: реальные переменные окружения →
//! .env-файл → значения по умолчанию.
//!
//! TELEGRAM_TOKEN           — токен бота (обязателен для режима сервиса)
//! TELEGRAM_ACCESS_ID       — Telegram-id админа: заявки, алерты, /monitor
//!                            /restart* /reset /users (без него админских
//!                            команд нет, бот открыт всем — режим разработки)
//! MOONOBSRV_DB             — URL Postgres (postgresql://user@db:5432/name).
//!                            Пусто — режим без БД: подписчики в state.json,
//!                            whitelist отключён, /idle* отвечает «нет данных»
//! MOONOBSRV_TOR            — SOCKS5-прокси Tor: socks5://tor:9050
//!                            (синонимы окружения: HTTPS_PROXY/https_proxy/
//!                            ALL_PROXY/all_proxy; схемы socks5/socks5h)
//! MOONOBSRV_COMPOSE_PROJECT— имя проекта docker compose (для /monitor,
//!                            /restart*), по умолчанию «moonobsrv»
//! MOONOBSRV_DATA_DIR       — каталог состояния (по умолчанию «data»)
//! MOONOBSRV_TZ             — часовой пояс вывода в часах, напр. 3, -5, 5.5
//! MOONOBSRV_POLL_TIMEOUT   — таймаут long polling, сек (25)
//! MOONOBSRV_CHECK_INTERVAL — период проверки неба, сек (60)
//! MOONOBSRV_WEBHOOK_URL    — публичный https-адрес webhook (задан → режим webhook)
//! MOONOBSRV_LISTEN         — где слушать HTTP за TLS-терминатором (127.0.0.1:8080)
//! MOONOBSRV_WEBHOOK_SECRET — секрет setWebhook (проверяется заголовок)
//! MOONOBSRV_ENV            — путь к env-файлу вместо .env (только из реального окружения)

const std = @import("std");
const envfile = @import("envfile.zig");

pub const Config = struct {
    token: []const u8 = "",
    /// Telegram-id админа; 0 — админский контур выключен.
    admin_id: i64 = 0,
    /// URL Postgres; пусто — режим без БД.
    db_url: []const u8 = "",
    /// SOCKS5-прокси (Tor): хост/порт после разбора socks5://…; null — прямое соединение.
    tor: ?Socks = null,
    /// Сырое значение прокси — для логов и /monitor.
    tor_raw: []const u8 = "",
    compose_project: []const u8 = "moonobsrv",
    data_dir: []const u8 = "data",
    tz_offset_sec: i32 = 3 * 3600,
    poll_timeout_s: u32 = 25,
    check_interval_s: u32 = 60,
    /// Задан → webhook-режим: регистрируем webhook и слушаем HTTP.
    webhook_url: []const u8 = "",
    /// Адрес прослушивания для webhook-сервера: IP:порт.
    listen: []const u8 = "127.0.0.1:8080",
    /// Секрет, передаваемый в setWebhook и проверяемый в заголовке.
    webhook_secret: []const u8 = "",

    pub const Socks = struct {
        host: []const u8,
        port: u16,
        /// DNS внутри прокси (socks5h): для Tor — всегда истина.
        remote_dns: bool = true,
    };

    pub fn webhookMode(self: *const Config) bool {
        return self.webhook_url.len > 0;
    }

    pub fn adminMode(self: *const Config) bool {
        return self.admin_id != 0;
    }

    pub fn dbMode(self: *const Config) bool {
        return self.db_url.len > 0;
    }

    pub fn load(alloc: std.mem.Allocator) Config {
        var cfg = Config{};
        var env = std.process.getEnvMap(alloc) catch return cfg;
        if (env.get("MOONOBSRV_ENV")) |path| {
            envfile.apply(alloc, &env, path);
        } else {
            envfile.applyNearExe(alloc, &env);
            envfile.apply(alloc, &env, ".env");
        }
        if (env.get("TELEGRAM_TOKEN")) |v| cfg.token = alloc.dupe(u8, v) catch cfg.token;
        if (env.get("TELEGRAM_API_TOKEN")) |v| {
            if (cfg.token.len == 0) cfg.token = alloc.dupe(u8, v) catch cfg.token;
        }
        if (env.get("TELEGRAM_ACCESS_ID")) |v| {
            cfg.admin_id = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch 0;
        }
        if (env.get("MOONOBSRV_DB")) |v| cfg.db_url = alloc.dupe(u8, v) catch cfg.db_url;
        if (env.get("MOONOBSRV_COMPOSE_PROJECT")) |v| {
            cfg.compose_project = alloc.dupe(u8, v) catch cfg.compose_project;
        }
        cfg.tor_raw = firstNonEmpty(&env, &.{ "MOONOBSRV_TOR", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" });
        if (cfg.tor_raw.len > 0) cfg.tor = parseSocks(cfg.tor_raw);
        if (env.get("MOONOBSRV_DATA_DIR")) |v| cfg.data_dir = alloc.dupe(u8, v) catch cfg.data_dir;
        if (env.get("MOONOBSRV_WEBHOOK_URL")) |v| cfg.webhook_url = alloc.dupe(u8, v) catch cfg.webhook_url;
        if (env.get("MOONOBSRV_LISTEN")) |v| cfg.listen = alloc.dupe(u8, v) catch cfg.listen;
        if (env.get("MOONOBSRV_WEBHOOK_SECRET")) |v| cfg.webhook_secret = alloc.dupe(u8, v) catch cfg.webhook_secret;
        if (env.get("MOONOBSRV_TZ")) |v| {
            const hours = std.fmt.parseFloat(f64, v) catch 3.0;
            cfg.tz_offset_sec = @intFromFloat(hours * 3600.0);
        }
        if (env.get("MOONOBSRV_POLL_TIMEOUT")) |v| {
            cfg.poll_timeout_s = std.fmt.parseInt(u32, v, 10) catch cfg.poll_timeout_s;
        }
        if (env.get("MOONOBSRV_CHECK_INTERVAL")) |v| {
            cfg.check_interval_s = std.fmt.parseInt(u32, v, 10) catch cfg.check_interval_s;
        }
        return cfg;
    }

    fn firstNonEmpty(env: *std.process.EnvMap, keys: []const []const u8) []const u8 {
        for (keys) |k| {
            if (env.get(k)) |v| {
                if (v.len > 0) return v;
            }
        }
        return "";
    }
};

/// Разбирает «socks5://host:port» / «socks5h://host:port» (регистр не важен).
/// user:pass@ отбрасывается (Tor без аутентификации), путь отбрасывается.
pub fn parseSocks(raw_in: []const u8) ?Config.Socks {
    var raw = raw_in;
    const scheme_sep = std.mem.indexOf(u8, raw, "://") orelse return null;
    const scheme = raw[0..scheme_sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "socks5") and !std.ascii.eqlIgnoreCase(scheme, "socks5h")) return null;
    raw = raw[scheme_sep + 3 ..];
    if (std.mem.indexOfScalar(u8, raw, '/')) |i| raw = raw[0..i];
    if (std.mem.lastIndexOfScalar(u8, raw, '@')) |i| raw = raw[i + 1 ..];
    const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;
    const host = raw[0..colon];
    const port = std.fmt.parseInt(u16, raw[colon + 1 ..], 10) catch return null;
    if (host.len == 0 or port == 0) return null;
    return .{ .host = host, .port = port, .remote_dns = true };
}

test "parseSocks: схемы, регистр, креды, мусор" {
    const a = parseSocks("socks5://tor:9050").?;
    try std.testing.expectEqualStrings("tor", a.host);
    try std.testing.expectEqual(@as(u16, 9050), a.port);
    try std.testing.expect(a.remote_dns);
    const b = parseSocks("SOCKS5H://127.0.0.1:9050").?;
    try std.testing.expectEqualStrings("127.0.0.1", b.host);
    try std.testing.expectEqual(@as(u16, 9050), b.port);
    const with_creds = parseSocks("socks5://user:pass@tor:9050/path");
    try std.testing.expectEqualStrings("tor", with_creds.?.host);
    try std.testing.expectEqual(@as(u16, 9050), with_creds.?.port);
    try std.testing.expect(parseSocks("http://proxy:8080") == null);
    try std.testing.expect(parseSocks("socks5://tor") == null);
    try std.testing.expect(parseSocks("socks5://tor:0") == null);
    try std.testing.expect(parseSocks("") == null);
}
