//! Сторожевой слой: heartbeat-файл (healthcheck контейнера + watchdog),
//! маркер рестарта (анти-бутлуп), курсор offset в файле, inflight-«яд»
//! (процесс умер посреди апдейта), бэкофф, пробы Tor/WAN, Docker Engine API
//! через /var/run/docker.sock сырым HTTP/1.0 — как в rbot, без библиотек.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

/// Пороги и интервалы (калиброваны по rbot).
pub const HUNG_SECS: i64 = 300; // зависание: нет heartbeat столько — abort
pub const FAIL_NEED: u32 = 3; // подряд неудачных getUpdates до рестарта Tor
pub const ALERT_COOLDOWN_S: i64 = 600; // алерт админу не чаще раза в 10 мин
pub const TOR_RESTART_COOLDOWN_S: i64 = 90; // между принудительными Tor-рестартами
pub const START_GRACE_S: i64 = 60; // после старта Tor не дёргаем
pub const SEND_RETRY_S: i64 = 20; // повтор недоставленного алерта
pub const WATCHDOG_TICK_S: u32 = 20;
pub const PROBE_TIMEOUT_MS: u32 = 3000;
pub const DOCKER_SOCK = "/var/run/docker.sock";

/// Сэмпл здоровья слоёв (layer_sample): битовая маска на момент времени.
pub const Sample = struct { ts: i64, mask: i32 };

// ─── Runtime-файлы ──────────────────────────────────────────────────────────

/// Каталог runtime-файлов: /tmp на Unix, %TEMP% на Windows.
pub fn runtimeDir(buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TEMP")) |v| {
            defer std.heap.page_allocator.free(v);
            if (v.len < buf.len) {
                @memcpy(buf[0..v.len], v);
                return buf[0..v.len];
            }
        } else |_| {}
        return ".";
    }
    return "/tmp";
}

fn fileWrite(dir: []const u8, name: []const u8, data: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return;
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    f.writeAll(data) catch {};
}

fn fileRead(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var pbuf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return null;
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return buf[0..n];
}

fn fileRemove(dir: []const u8, name: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, name }) catch return;
    std.fs.cwd().deleteFile(p) catch {};
}

pub fn beat() void {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var vbuf: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{std.time.timestamp()}) catch return;
    fileWrite(dir, "moonobsrv.hb", v);
}

pub fn lastBeat() i64 {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var buf: [24]u8 = undefined;
    const v = fileRead(dir, "moonobsrv.hb", &buf) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n"), 10) catch 0;
}

pub fn noteBounce() void {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var vbuf: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{std.time.timestamp()}) catch return;
    fileWrite(dir, "moonobsrv.bounce", v);
}

pub fn bounceAge() ?i64 {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var buf: [24]u8 = undefined;
    const v = fileRead(dir, "moonobsrv.bounce", &buf) orelse return null;
    const t = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n"), 10) catch return null;
    return std.time.timestamp() - t;
}

pub fn saveTgOffset(n: i64) void {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var vbuf: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{n}) catch return;
    fileWrite(dir, "moonobsrv.offset", v);
}

pub fn loadTgOffset() i64 {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var buf: [24]u8 = undefined;
    const v = fileRead(dir, "moonobsrv.offset", &buf) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n"), 10) catch 0;
}

/// «Яд»: перед обработкой апдейта пишем его id; после — стираем. Найденный
/// при старте файл означает смерть посреди апдейта.
pub fn setInflight(id: i64) void {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var vbuf: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{id}) catch return;
    fileWrite(dir, "moonobsrv.inflight", v);
}

pub fn clearInflight() void {
    var dbuf: [512]u8 = undefined;
    fileRemove(runtimeDir(&dbuf), "moonobsrv.inflight");
}

pub fn takeInflight() ?i64 {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var buf: [24]u8 = undefined;
    const v = fileRead(dir, "moonobsrv.inflight", &buf) orelse return null;
    fileRemove(dir, "moonobsrv.inflight");
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \r\n"), 10) catch null;
}

pub fn noteHang() void {
    var dbuf: [512]u8 = undefined;
    const dir = runtimeDir(&dbuf);
    var vbuf: [24]u8 = undefined;
    const v = std.fmt.bufPrint(&vbuf, "{d}", .{std.time.timestamp()}) catch return;
    fileWrite(dir, "moonobsrv.hang", v);
}

// ─── Бэкофф и классификация ─────────────────────────────────────────────────

/// Пауза после N подряд неудач: 2, 2, 4, 8, 15, 30, 30… (как rbot).
pub fn backoffSecs(consec: u32) u32 {
    return switch (consec) {
        0, 1 => 2,
        2 => 4,
        3 => 8,
        4 => 15,
        else => 30,
    };
}

pub const FailKind = enum { tor, host_net, unknown };

pub const Probes = struct {
    tor_configured: bool,
    tor_socks: bool,
    host_net: bool,
};

pub const Socks = config.Config.Socks;

/// TCP-коннект с дедлайном: поток с атомарным флагом — main ждёт не дольше
/// timeout_ms (мёртвый DNS/getaddrinfo не блокирует вызывающего). Если
/// коннект не успел — поток продолжает жить независимо (state в куче).
pub fn tcpProbe(host: []const u8, port: u16, timeout_ms: u32) bool {
    if (std.net.Address.parseIp(host, port)) |addr| {
        return tcpProbeAddr(addr, timeout_ms);
    } else |_| {}
    const addr_list = std.net.getAddressList(std.heap.page_allocator, host, port) catch return false;
    defer addr_list.deinit();
    if (addr_list.addrs.len == 0) return false;
    return tcpProbeAddr(addr_list.addrs[0], timeout_ms);
}

const ProbeState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ok: bool = false,
    addr: std.net.Address,
};

fn tcpProbeAddr(addr: std.net.Address, timeout_ms: u32) bool {
    const st = std.heap.page_allocator.create(ProbeState) catch return false;
    st.* = .{ .addr = addr };
    const th = std.Thread.spawn(.{}, struct {
        fn run(s: *ProbeState) void {
            defer s.done.store(true, .release);
            const conn = std.net.tcpConnectToAddress(s.addr) catch return;
            conn.close();
            s.ok = true;
        }
    }.run, .{st}) catch {
        std.heap.page_allocator.destroy(st);
        return false;
    };
    var waited: u32 = 0;
    while (waited < timeout_ms) {
        if (st.done.load(.acquire)) {
            th.join();
            const ok = st.ok;
            std.heap.page_allocator.destroy(st);
            return ok;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
    }
    th.detach(); // поток догорит сам; state живёт в куче до его конца
    return false; // не успел — считаем слой мёртвым
}

pub fn probes(proxy: ?Socks) Probes {
    const wan1 = tcpProbe("1.1.1.1", 443, PROBE_TIMEOUT_MS);
    const wan = wan1 or tcpProbe("8.8.8.8", 443, PROBE_TIMEOUT_MS);
    if (proxy) |p| {
        return .{ .tor_configured = true, .tor_socks = tcpProbe(p.host, p.port, PROBE_TIMEOUT_MS), .host_net = wan };
    }
    return .{ .tor_configured = false, .tor_socks = false, .host_net = wan };
}

/// Грубая классификация сбоя: лучше лишний рестарт Tor, чем час тишины.
pub fn classify(err_text: []const u8, pr: Probes) FailKind {
    if (pr.tor_configured and !pr.tor_socks) return .tor;
    if (!pr.host_net) return .host_net;
    var lower_buf: [128]u8 = undefined;
    const n = @min(err_text.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], err_text[0..n]);
    if (std.mem.indexOf(u8, lower, "socks") != null or std.mem.indexOf(u8, lower, "proxy") != null) return .tor;
    if (pr.tor_configured and containsAny(lower, &.{ "timed out", "timeout", "connection", "reset", "eof" })) return .tor;
    if (containsAny(lower, &.{ "timed out", "timeout", "unreachable", "dns", "network" })) return .host_net;
    return .unknown;
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

// ─── Docker Engine API (unix-сокет) ─────────────────────────────────────────

pub const DockerResp = struct {
    status: u16,
    body: []const u8, // память арены вызывающего
};

pub const has_docker_socket = builtin.os.tag != .windows;

/// Сырой HTTP/1.0 запрос к Docker Engine API. null — сокета нет/обрыв.
/// Ввод-вывод сырыми write/read: путь компилируется только на Unix.
pub fn dockerHttp(arena: std.mem.Allocator, method: []const u8, path: []const u8, body: ?[]const u8, read_timeout_s: u32) ?DockerResp {
    _ = read_timeout_s; // блокирующий сокет; watchdog страхует от зависаний
    if (comptime !has_docker_socket) return null;
    const stream = std.net.connectUnixSocket(DOCKER_SOCK) catch return null;
    defer stream.close();
    var wbuf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    w.print("{s} {s} HTTP/1.0\r\nHost: docker\r\n", .{ method, path }) catch return null;
    if (body) |b| {
        w.print("Content-Length: {d}\r\n", .{b.len}) catch return null;
    }
    w.writeAll("\r\n") catch return null;
    if (body) |b| w.writeAll(b) catch return null;
    stream.writeAll(w.buffered()) catch return null;

    // HTTP/1.0: тело до конца потока (блокирующее чтение, EOF по close).
    var buf: [64 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = stream.read(buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    if (n < 12 or !std.mem.startsWith(u8, buf[0..n], "HTTP/1.")) return null;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, buf[9..12], " "), 10) catch return null;
    const sep = std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") orelse return null;
    const body_out = arena.dupe(u8, buf[sep + 4 .. n]) catch return null;
    return .{ .status = status, .body = body_out };
}

pub const Container = struct {
    name: []const u8,
    service: []const u8,
    running: bool,
    healthy: bool, // false если unhealthy; running без healthcheck → true
};

/// Разбор /containers/json?all=1: фильтр по compose-проекту.
pub fn parseContainers(arena: std.mem.Allocator, body: []const u8, project: []const u8) ![]Container {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return &.{};
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return &.{},
    };
    var list: std.ArrayList(Container) = .empty;
    for (arr.items) |item| {
        const obj = item.object;
        const labels = (obj.get("Labels") orelse continue).object;
        const proj = (labels.get("com.docker.compose.project") orelse continue).string;
        if (!std.mem.eql(u8, proj, project)) continue;
        const svc = if (labels.get("com.docker.compose.service")) |v| v.string else "";
        var name: []const u8 = "?";
        if (obj.get("Names")) |names| {
            if (names.array.items.len > 0) name = std.mem.trimLeft(u8, names.array.items[0].string, "/");
        }
        const state = if (obj.get("State")) |v| v.string else "";
        const status = if (obj.get("Status")) |v| v.string else "";
        const running = std.mem.eql(u8, state, "running");
        const healthy = running and std.mem.indexOf(u8, status, "unhealthy") == null;
        try list.append(arena, .{ .name = name, .service = svc, .running = running, .healthy = healthy });
    }
    std.mem.sort(Container, list.items, {}, struct {
        fn less(_: void, a: Container, b: Container) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return list.items;
}

/// Id контейнера compose-сервиса (bot/db/tor).
pub fn composeId(arena: std.mem.Allocator, project: []const u8, service: []const u8) ?[]const u8 {
    const resp = dockerHttp(arena, "GET", "/containers/json?all=1", null, 5) orelse return null;
    if (resp.status != 200) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{}) catch return null;
    for (parsed.value.array.items) |item| {
        const obj = item.object;
        const labels = (obj.get("Labels") orelse continue).object;
        const proj = (labels.get("com.docker.compose.project") orelse continue).string;
        const svc = (labels.get("com.docker.compose.service") orelse continue).string;
        if (std.mem.eql(u8, proj, project) and std.mem.eql(u8, svc, service)) {
            return obj.get("Id").?.string;
        }
    }
    return null;
}

/// IP-адрес контейнера в сети compose (для hostwatch: socks тор-контейнера).
pub fn containerIp(arena: std.mem.Allocator, id: []const u8) ?[]const u8 {
    var pbuf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/containers/{s}/json", .{id}) catch return null;
    const resp = dockerHttp(arena, "GET", path, null, 5) orelse return null;
    if (resp.status != 200) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, resp.body, .{}) catch return null;
    const ns = parsed.value.object.get("NetworkSettings") orelse return null;
    if (ns.object.get("Networks")) |nets| {
        var it = nets.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.object.get("IPAddress")) |ip| {
                if (ip.string.len > 0) return ip.string;
            }
        }
    }
    if (ns.object.get("IPAddress")) |ip| {
        if (ip.string.len > 0) return ip.string;
    }
    return null;
}

pub const Bounce = enum { ok, fail, sent, no_docker, missing };

/// docker restart контейнера (t=8 — секунд на остановку).
pub fn dockerRestart(arena: std.mem.Allocator, id: []const u8) Bounce {
    var pbuf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "/containers/{s}/restart?t=8", .{id}) catch return .fail;
    const resp = dockerHttp(arena, "POST", path, null, 25) orelse return .sent;
    return if (resp.status >= 200 and resp.status < 300) .ok else .fail;
}

pub fn dockerPing(arena: std.mem.Allocator) bool {
    const resp = dockerHttp(arena, "GET", "/_ping", null, 5) orelse return false;
    return resp.status == 200;
}

/// Ждёт, пока socks Tor снова примет соединения (после рестарта слоя).
pub fn waitSocks(proxy: ?Socks) bool {
    const p = proxy orelse return true;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        beat();
        if (tcpProbe(p.host, p.port, 2000)) return true;
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    return false;
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "backoffSecs: таблица как в rbot" {
    try std.testing.expectEqual(@as(u32, 2), backoffSecs(0));
    try std.testing.expectEqual(@as(u32, 2), backoffSecs(1));
    try std.testing.expectEqual(@as(u32, 4), backoffSecs(2));
    try std.testing.expectEqual(@as(u32, 8), backoffSecs(3));
    try std.testing.expectEqual(@as(u32, 15), backoffSecs(4));
    try std.testing.expectEqual(@as(u32, 30), backoffSecs(5));
    try std.testing.expectEqual(@as(u32, 30), backoffSecs(50));
}

test "classify: прокси недоступен → tor; сети нет → host_net" {
    try std.testing.expectEqual(FailKind.tor, classify("boom", .{ .tor_configured = true, .tor_socks = false, .host_net = true }));
    try std.testing.expectEqual(FailKind.host_net, classify("boom", .{ .tor_configured = true, .tor_socks = true, .host_net = false }));
    try std.testing.expectEqual(FailKind.tor, classify("socks handshake failed", .{ .tor_configured = true, .tor_socks = true, .host_net = true }));
    try std.testing.expectEqual(FailKind.tor, classify("ConnectionResetByPeer", .{ .tor_configured = true, .tor_socks = true, .host_net = true }));
    try std.testing.expectEqual(FailKind.unknown, classify("strange", .{ .tor_configured = false, .tor_socks = false, .host_net = true }));
}

test "parseContainers: фильтр по проекту, статусы, сортировка" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\[{"Id":"a1","Names":["/moonobsrv-bot-1"],"State":"running","Status":"Up 2 hours (healthy)","Labels":{"com.docker.compose.project":"moonobsrv","com.docker.compose.service":"bot"}},
        \\ {"Id":"a2","Names":["/moonobsrv-db-1"],"State":"running","Status":"Up 2 hours","Labels":{"com.docker.compose.project":"moonobsrv","com.docker.compose.service":"db"}},
        \\ {"Id":"a3","Names":["/moonobsrv-tor-1"],"State":"exited","Status":"Exited (0)","Labels":{"com.docker.compose.project":"moonobsrv","com.docker.compose.service":"tor"}},
        \\ {"Id":"a4","Names":["/other-bot-1"],"State":"running","Status":"Up","Labels":{"com.docker.compose.project":"lightcloves_fin_bot","com.docker.compose.service":"bot"}}]
    ;
    const list = try parseContainers(arena, body, "moonobsrv");
    try std.testing.expectEqual(@as(usize, 3), list.len);
    // сортировка по имени: bot, db, tor
    try std.testing.expectEqualStrings("moonobsrv-bot-1", list[0].name);
    try std.testing.expect(list[0].running and list[0].healthy);
    try std.testing.expectEqualStrings("db", list[1].service);
    try std.testing.expect(list[1].healthy); // running без healthcheck — здоров
    try std.testing.expect(!list[2].running and !list[2].healthy);
}

test "runtime-файлы: запись/чтение/удаление" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    // beat/offset/inflight используют runtimeDir() — тестируем примитивы
    fileWrite(dir, "t.hb", "12345");
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("12345", fileRead(dir, "t.hb", &buf).?);
    fileRemove(dir, "t.hb");
    try std.testing.expect(fileRead(dir, "t.hb", &buf) == null);
}

test "tcpProbe: localhost отвечает, мусорный хост — нет" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    try std.testing.expect(tcpProbe("127.0.0.1", server.listen_address.getPort(), 2000));
    try std.testing.expect(!tcpProbe("10.255.255.1", 65001, 500)); // чёрная дыра
}
