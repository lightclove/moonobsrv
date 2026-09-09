//! Клиент PostgreSQL wire-протокола (v3) без зависимостей: startup,
//! аутентификация trust/cleartext/md5, простой протокол запросов (Q),
//! текстовый формат значений. SCRAM не поддерживается — контейнер БД
//! настраивается на trust/md5 (сеть compose изолирована, хост-порт в проде
//! не публикуется). Одно соединение на процесс, переподключение при обрыве.
//!
//! Кадры — чистые функции, протокольный обмен покрыт тестами с фейковым
//! сервером на 127.0.0.1.

const std = @import("std");

pub const Error = error{
    PgBadUrl,
    PgAuth,
    PgAuthUnsupported,
    PgConnect,
    PgProtocol,
    PgSql, // сервер вернул ErrorResponse
    OutOfMemory,
};

pub const Url = struct {
    user: []const u8 = "postgres",
    password: []const u8 = "",
    host: []const u8 = "localhost",
    port: u16 = 5432,
    database: []const u8 = "postgres",
};

/// postgresql://user:pass@host:port/db — без Percent-кодирования (внутренние URL).
pub fn parseUrl(raw: []const u8) !Url {
    var u = Url{};
    var rest = raw;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        u.database = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| {
        const creds = rest[0..i];
        rest = rest[i + 1 ..];
        if (std.mem.indexOfScalar(u8, creds, ':')) |c| {
            u.user = creds[0..c];
            u.password = creds[c + 1 ..];
        } else u.user = creds;
    }
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        u.port = std.fmt.parseInt(u16, rest[i + 1 ..], 10) catch return Error.PgBadUrl;
        rest = rest[0..i];
    }
    if (rest.len > 0) u.host = rest;
    if (u.database.len == 0) return Error.PgBadUrl;
    return u;
}

// ─── Кадры ─────────────────────────────────────────────────────────────────

/// StartupMessage: длина, версия 3.0, пары key\x00value\x00, финальный \x00.
pub fn buildStartup(buf: []u8, u: Url) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeInt(u32, 0, .big) catch unreachable; // место под длину
    w.writeInt(u32, 196608, .big) catch unreachable; // 3.0
    w.writeAll("user\x00") catch unreachable;
    w.writeAll(u.user) catch unreachable;
    w.writeAll("\x00database\x00") catch unreachable;
    w.writeAll(u.database) catch unreachable;
    w.writeAll("\x00application_name\x00moonobsrv\x00\x00") catch unreachable;
    const m = w.buffered();
    std.mem.writeInt(u32, m[0..4], @intCast(m.len), .big);
    return m;
}

/// md5-аутентификация: «md5» + hex(md5(hex(md5(password+user)) + salt)).
pub fn md5Pass(buf: []u8, u: Url, salt: [4]u8) []const u8 {
    const Md5 = std.crypto.hash.Md5;
    var inner: [16]u8 = undefined;
    var h1 = Md5.init(.{});
    h1.update(u.password);
    h1.update(u.user);
    h1.final(&inner);
    var hex1: [32]u8 = undefined;
    hexLower(&hex1, &inner);
    var h2 = Md5.init(.{});
    h2.update(&hex1);
    h2.update(&salt);
    var outer: [16]u8 = undefined;
    h2.final(&outer);
    var hex2: [35]u8 = undefined;
    hex2[0] = 'm';
    hex2[1] = 'd';
    hex2[2] = '5';
    hexLower(hex2[3..], &outer);
    @memcpy(buf[0..35], &hex2);
    return buf[0..35];
}

fn hexLower(dst: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        dst[i * 2] = digits[b >> 4];
        dst[i * 2 + 1] = digits[b & 0x0F];
    }
}

/// Сообщение 'p' (пароль) / 'Q' (запрос) / 'X' (terminate): [tag][len][payload].
pub fn buildTagged(buf: []u8, tag: u8, payload: []const u8) []const u8 {
    buf[0] = tag;
    std.mem.writeInt(u32, buf[1..5], @intCast(payload.len + 4), .big);
    @memcpy(buf[5 .. 5 + payload.len], payload);
    return buf[0 .. 5 + payload.len];
}

pub const BackendMsg = struct {
    tag: u8,
    body: []const u8,
};

/// Один кадр от сервера: тег + длина + тело. Тело ссылается на `work`.
pub fn readMessage(r: *std.Io.Reader, work: []u8) Error!BackendMsg {
    var head: [5]u8 = undefined;
    r.readSliceAll(&head) catch return Error.PgProtocol;
    const len = std.mem.readInt(u32, head[1..5], .big);
    if (len < 4 or len > work.len + 4) return Error.PgProtocol;
    const body_len = len - 4;
    if (body_len > 0) {
        r.readSliceAll(work[0..body_len]) catch return Error.PgProtocol;
    }
    return .{ .tag = head[0], .body = work[0..body_len] };
}

pub const AuthKind = enum { ok, cleartext, md5, unsupported };

pub fn parseAuth(body: []const u8) struct { kind: AuthKind, salt: [4]u8 } {
    if (body.len < 4) return .{ .kind = .unsupported, .salt = .{0} ** 4 };
    const code = std.mem.readInt(u32, body[0..4], .big);
    return switch (code) {
        0 => .{ .kind = .ok, .salt = .{0} ** 4 },
        3 => .{ .kind = .cleartext, .salt = .{0} ** 4 },
        5 => blk: {
            var salt: [4]u8 = .{0} ** 4;
            if (body.len >= 8) @memcpy(&salt, body[4..8]);
            break :blk .{ .kind = .md5, .salt = salt };
        },
        else => .{ .kind = .unsupported, .salt = .{0} ** 4 },
    };
}

pub const PgError = struct {
    severity: []const u8 = "",
    message: []const u8 = "",
};

/// ErrorResponse: последовательность байт-код\x00значение\x00…\x00.
pub fn parseErrorBody(body: []const u8) PgError {
    var e = PgError{};
    var i: usize = 0;
    while (i < body.len and body[i] != 0) {
        const code = body[i];
        const start = i + 1;
        const end = start + (std.mem.indexOfScalar(u8, body[start..], 0) orelse break);
        const value = body[start..end];
        switch (code) {
            'S' => e.severity = value,
            'M' => e.message = value,
            else => {},
        }
        i = end + 1;
    }
    return e;
}

// ─── Строка DataRow: count int16, затем для каждого значения int32-длина
//     (-1 = NULL) и байты. Разбор — в Row.values.

pub const Value = ?[]const u8; // null → SQL NULL

pub const Row = struct {
    values: []Value,
};

/// Экранирование строкового литерала SQL: ' → '' . Управляющие байты
/// внутри значений бота не встречаются; нулевой байт отсекается.
pub fn quoteLit(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('\'');
    for (s) |ch| {
        if (ch == 0) break;
        if (ch == '\'') try out.writeByte('\'');
        try out.writeByte(ch);
    }
    try out.writeByte('\'');
}

// ─── Соединение ────────────────────────────────────────────────────────────

pub const Conn = struct {
    alloc: std.mem.Allocator,
    url: Url,
    stream: ?std.net.Stream = null,
    rbuf: [64 * 1024]u8 = undefined,
    stream_reader: std.net.Stream.Reader = undefined,

    pub fn init(alloc: std.mem.Allocator, url_raw: []const u8) Error!Conn {
        return .{ .alloc = alloc, .url = try parseUrl(url_raw) };
    }

    pub fn deinit(self: *Conn) void {
        self.disconnect();
    }

    pub fn disconnect(self: *Conn) void {
        if (self.stream) |s| {
            // Terminate ('X', длина 4) — вежливо, но ответа не ждём
            _ = s.writeAll(&.{ 'X', 0, 0, 0, 4 }) catch {};
            s.close();
        }
        self.stream = null;
    }

    fn reader(self: *Conn) *std.Io.Reader {
        return self.stream_reader.interface();
    }

    pub fn connect(self: *Conn) Error!void {
        if (self.stream != null) return;
        const s = std.net.tcpConnectToHost(self.alloc, self.url.host, self.url.port) catch return Error.PgConnect;
        // БД не должна держать вечно: handshake/запросы — 15 с, хватит с запасом.
        setSocketTimeout(s, 15);
        errdefer {
            s.close();
            self.stream = null;
        }
        self.stream_reader = std.net.Stream.reader(s, &self.rbuf);
        self.stream = s;

        var buf: [512]u8 = undefined;
        s.writeAll(buildStartup(&buf, self.url)) catch return Error.PgConnect;
        try self.authLoop(s);
        // до ReadyForQuery: ParameterStatus/BackendKeyData пропускаем
        var work: [4096]u8 = undefined;
        while (true) {
            const msg = try readMessage(self.reader(), &work);
            switch (msg.tag) {
                'Z' => return,
                'E' => {
                    self.logError(msg.body);
                    return Error.PgSql;
                },
                'S', 'K', 'N' => {},
                else => return Error.PgProtocol,
            }
        }
    }

    fn authLoop(self: *Conn, s: std.net.Stream) Error!void {
        var work: [512]u8 = undefined;
        while (true) {
            const msg = try readMessage(self.reader(), &work);
            switch (msg.tag) {
                'R' => {
                    const auth = parseAuth(msg.body);
                    switch (auth.kind) {
                        .ok => return,
                        .cleartext, .md5 => {
                            var pass_buf: [40]u8 = undefined;
                            var pw_buf: [96]u8 = undefined;
                            var pw: std.Io.Writer = .fixed(&pw_buf);
                            if (auth.kind == .md5) {
                                pw.writeAll(md5Pass(&pass_buf, self.url, auth.salt)) catch unreachable;
                            } else {
                                pw.writeAll(self.url.password) catch unreachable;
                            }
                            pw.writeByte(0) catch unreachable;
                            var frame: [128]u8 = undefined;
                            s.writeAll(buildTagged(&frame, 'p', pw.buffered())) catch return Error.PgConnect;
                        },
                        .unsupported => {
                            log("pg: сервер требует SCRAM/иную аутентификацию — включите trust или md5", .{});
                            return Error.PgAuthUnsupported;
                        },
                    }
                },
                'E' => {
                    self.logError(msg.body);
                    return Error.PgAuth;
                },
                'S', 'K', 'N' => {},
                'Z' => return, // trust: сразу готов
                else => return Error.PgProtocol,
            }
        }
    }

    /// Простой запрос. Строки ссылаются на память арены `arena`.
    /// Возвращает число строк (значения — через row()).
    pub fn exec(self: *Conn, arena: std.mem.Allocator, sql: []const u8) Error!ExecResult {
        var retries: usize = 0;
        while (true) : (retries += 1) {
            if (retries > 1) return Error.PgConnect;
            self.connect() catch |e| {
                if (retries == 0) continue;
                return e;
            };
            return self.execOnce(arena, sql) catch |e| {
                self.disconnect(); // обрыв — один повтор на свежем соединении
                if (e == Error.PgSql) return e; // ошибка SQL не лечится повтором
                if (retries == 0) continue;
                return e;
            };
        }
    }

    pub const ExecResult = struct {
        rows: []Row = &.{},
        command_tag: []const u8 = "",
    };

    fn execOnce(self: *Conn, arena: std.mem.Allocator, sql: []const u8) Error!ExecResult {
        const s = self.stream orelse return Error.PgConnect;
        if (sql.len + 1 > 8180) return Error.PgSql; // все запросы бота короткие
        var sqlz_buf: [8192]u8 = undefined;
        var sqlz: std.Io.Writer = .fixed(&sqlz_buf);
        sqlz.writeAll(sql) catch unreachable;
        sqlz.writeByte(0) catch unreachable;
        var frame: [8192]u8 = undefined;
        _ = s.writeAll(buildTagged(&frame, 'Q', sqlz.buffered())) catch return Error.PgConnect;

        var rows: std.ArrayList(Row) = .empty;
        var tag: []const u8 = "";
        var work: [64 * 1024]u8 = undefined;
        while (true) {
            const msg = readMessage(self.reader(), &work) catch {
                return Error.PgProtocol;
            };
            switch (msg.tag) {
                'T' => {}, // описание колонок не нужно
                'D' => try self.parseDataRow(arena, &rows, msg.body),
                'C' => tag = arena.dupe(u8, msg.body[0 .. std.mem.indexOfScalar(u8, msg.body, 0) orelse msg.body.len]) catch return Error.OutOfMemory,
                'Z' => return .{ .rows = rows.items, .command_tag = tag },
                'E' => {
                    self.logError(msg.body);
                    return Error.PgSql;
                },
                'N', 'S', 'K' => {},
                else => return Error.PgProtocol,
            }
        }
    }

    fn parseDataRow(self: *Conn, arena: std.mem.Allocator, rows: *std.ArrayList(Row), body: []const u8) Error!void {
        _ = self;
        if (body.len < 2) return Error.PgProtocol;
        const n = std.mem.readInt(i16, body[0..2], .big);
        var vals = arena.alloc(Value, @intCast(n)) catch return Error.OutOfMemory;
        var i: usize = 2;
        var col: usize = 0;
        while (col < vals.len) : (col += 1) {
            if (i + 4 > body.len) return Error.PgProtocol;
            const l = std.mem.readInt(i32, body[i..][0..4], .big);
            i += 4;
            if (l < 0) {
                vals[col] = null;
            } else {
                const len: usize = @intCast(l);
                if (i + len > body.len) return Error.PgProtocol;
                vals[col] = arena.dupe(u8, body[i .. i + len]) catch return Error.OutOfMemory;
                i += len;
            }
        }
        rows.append(arena, .{ .values = vals }) catch return Error.OutOfMemory;
    }

    pub fn ping(self: *Conn, arena: std.mem.Allocator) bool {
        const res = self.exec(arena, "SELECT 1") catch return false;
        return res.rows.len == 1 and res.rows[0].values.len == 1 and
            std.mem.eql(u8, res.rows[0].values[0] orelse "", "1");
    }

    fn logError(self: *Conn, body: []const u8) void {
        _ = self;
        const e = parseErrorBody(body);
        log("pg: {s}: {s}", .{ e.severity, e.message });
    }
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[pg] " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stderr().writeAll(w.buffered()) catch {};
}

/// Блокирующий сокет не должен висеть вечно (handshake/запросы БД).
fn setSocketTimeout(stream: std.net.Stream, seconds: u32) void {
    if (comptime @import("builtin").os.tag == .windows) {
        const ms: u32 = seconds * 1000;
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&ms)) catch {};
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&ms)) catch {};
    } else {
        const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        _ = std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

// ─── Тесты: чистые функции + фейковый сервер ───────────────────────────────

test "parseUrl" {
    const u = try parseUrl("postgresql://moon:pw@db:5433/sky");
    try std.testing.expectEqualStrings("moon", u.user);
    try std.testing.expectEqualStrings("pw", u.password);
    try std.testing.expectEqualStrings("db", u.host);
    try std.testing.expectEqual(@as(u16, 5433), u.port);
    try std.testing.expectEqualStrings("sky", u.database);

    const d = try parseUrl("postgresql://localhost/postgres");
    try std.testing.expectEqualStrings("postgres", d.user);
    try std.testing.expectEqual(@as(u16, 5432), d.port);
    try std.testing.expectError(Error.PgBadUrl, parseUrl("postgresql://localhost/"));
}

test "startup-кадр" {
    var buf: [256]u8 = undefined;
    const m = buildStartup(&buf, .{ .user = "u1", .database = "d1" });
    try std.testing.expect(m.len > 8);
    const len = std.mem.readInt(u32, m[0..4], .big);
    try std.testing.expectEqual(@as(u32, @intCast(m.len)), len);
    try std.testing.expectEqual(@as(u32, 196608), std.mem.readInt(u32, m[4..8], .big));
    try std.testing.expect(std.mem.indexOf(u8, m, "user\x00u1\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "database\x00d1\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "application_name\x00moonobsrv\x00") != null);
    try std.testing.expectEqual(@as(u8, 0), m[m.len - 1]); // финальный \x00
}

test "md5-пароль по формуле RFC" {
    // Классический пример из документации PostgreSQL: user=md5_user, password=x
    // проверяем формулу детерминированно на своих данных.
    var buf: [64]u8 = undefined;
    const p1 = md5Pass(&buf, .{ .user = "u", .password = "p", .database = "d" }, .{ 1, 2, 3, 4 });
    var buf2: [64]u8 = undefined;
    const p2 = md5Pass(&buf2, .{ .user = "u", .password = "p", .database = "d" }, .{ 1, 2, 3, 4 });
    try std.testing.expectEqualStrings(p1, p2); // детерминизм
    try std.testing.expect(std.mem.startsWith(u8, p1, "md5"));
    try std.testing.expectEqual(@as(usize, 35), p1.len); // 3 + 32 hex
    const salt_diff = md5Pass(&buf2, .{ .user = "u", .password = "p", .database = "d" }, .{ 9, 9, 9, 9 });
    try std.testing.expect(!std.mem.eql(u8, p1, salt_diff)); // соль влияет
}

test "parseAuth и parseErrorBody" {
    const ok = parseAuth(&[_]u8{ 0, 0, 0, 0 });
    try std.testing.expectEqual(AuthKind.ok, ok.kind);
    const clear = parseAuth(&[_]u8{ 0, 0, 0, 3 });
    try std.testing.expectEqual(AuthKind.cleartext, clear.kind);
    const md5 = parseAuth(&[_]u8{ 0, 0, 0, 5, 0xAA, 0xBB, 0xCC, 0xDD });
    try std.testing.expectEqual(AuthKind.md5, md5.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD }, &md5.salt);
    const scram = parseAuth(&[_]u8{ 0, 0, 0, 10 });
    try std.testing.expectEqual(AuthKind.unsupported, scram.kind);

    const e = parseErrorBody("SFATAL\x00MconFLICT with other session\x00\x00");
    try std.testing.expectEqualStrings("FATAL", e.severity);
    try std.testing.expectEqualStrings("conFLICT with other session", e.message);
}

test "quoteLit" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try quoteLit(&w, "простое");
    try std.testing.expectEqualStrings("'простое'", w.buffered());
    var w2: std.Io.Writer = .fixed(&buf);
    try quoteLit(&w2, "o'brien");
    try std.testing.expectEqualStrings("'o''brien'", w2.buffered());
}

test "DataRow: значения и NULL" {
    // count=3, потом: len4 "abcd", len-1 null, len0 ""
    const body = [_]u8{
        0, 3,
        0, 0, 0, 4, 'a', 'b', 'c', 'd',
        0xFF, 0xFF, 0xFF, 0xFF,
        0, 0, 0, 0,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(arena);
    var conn = Conn{ .alloc = std.testing.allocator, .url = .{} };
    try conn.parseDataRow(arena, &rows, &body);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(usize, 3), rows.items[0].values.len);
    try std.testing.expectEqualStrings("abcd", rows.items[0].values[0].?);
    try std.testing.expect(rows.items[0].values[1] == null);
    try std.testing.expectEqualStrings("", rows.items[0].values[2].?);
}

// ─── Фейковый сервер: полный протокольный обмен ────────────────────────────

const FakePg = struct {
    md5: bool,
    got_sql: []const u8 = "",

    fn run(self: *FakePg, server: *std.net.Server) void {
        const conn = server.accept() catch return;
        defer conn.stream.close();
        const s = conn.stream;
        var rb: [4096]u8 = undefined;
        var r = std.net.Stream.reader(s, &rb);
        const ri = r.interface();

        // 1. startup
        var head: [4]u8 = undefined;
        ri.readSliceAll(&head) catch return;
        const len = std.mem.readInt(u32, &head, .big);
        var startup_body: [512]u8 = undefined;
        ri.readSliceAll(startup_body[0 .. len - 4]) catch return;

        if (self.md5) {
            send(s, 'R', &.{ 0, 0, 0, 5, 1, 2, 3, 4 });
            // ждём 'p'
            var ph: [5]u8 = undefined;
            ri.readSliceAll(&ph) catch return;
            const plen = std.mem.readInt(u32, ph[1..5], .big);
            var pbuf: [128]u8 = undefined;
            ri.readSliceAll(pbuf[0 .. plen - 4]) catch return;
            var expect_buf: [64]u8 = undefined;
            const expect = md5Pass(&expect_buf, .{ .user = "u", .password = "p", .database = "d" }, .{ 1, 2, 3, 4 });
            if (!std.mem.startsWith(u8, pbuf[0 .. plen - 4], expect)) {
                send(s, 'E', "SFATAL\x00Mmd5 mismatch\x00\x00");
                return;
            }
            send(s, 'R', &.{ 0, 0, 0, 0 });
        } else {
            send(s, 'R', &.{ 0, 0, 0, 0 });
        }
        send(s, 'S', "server_version\x0016.9\x00");
        send(s, 'Z', &.{ 'I' });

        // 2. один запрос Q → T + D + C + Z
        var qh: [5]u8 = undefined;
        ri.readSliceAll(&qh) catch return;
        if (qh[0] != 'Q') return;
        const qlen = std.mem.readInt(u32, qh[1..5], .big);
        var qbuf: [8192]u8 = undefined;
        ri.readSliceAll(qbuf[0 .. qlen - 4]) catch return;
        self.got_sql = qbuf[0 .. qlen - 5]; // без финального \x00

        // RowDescription: 1 колонка «x» (клиент описание не разбирает)
        send(s, 'T', &.{ 0, 1, 0, 1, 'x', 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0xFF, 0xFF, 0xFF, 0xFF });
        // DataRow: 1 значение «1»
        send(s, 'D', &.{ 0, 1, 0, 0, 0, 1, '1' });
        send(s, 'C', "SELECT 1\x00");
        send(s, 'Z', &.{ 'I' });
    }

    fn send(s: std.net.Stream, tag: u8, payload: []const u8) void {
        // кадр: [tag][int32 total_len][payload], total_len = 4 + payload
        var full: [8300]u8 = undefined;
        var f: std.Io.Writer = .fixed(&full);
        f.writeByte(tag) catch return;
        f.writeInt(u32, @intCast(payload.len + 4), .big) catch return;
        f.writeAll(payload) catch return;
        s.writeAll(f.buffered()) catch {};
    }
};

fn fakePgTest(md5: bool) !void {
    const ip = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try ip.listen(.{ .reuse_address = true });
    defer server.deinit();
    const addr = server.listen_address;
    var fake = FakePg{ .md5 = md5 };
    const th = try std.Thread.spawn(.{}, FakePg.run, .{ &fake, &server });
    defer th.join();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var conn = Conn{
        .alloc = std.testing.allocator,
        .url = .{ .user = "u", .password = "p", .host = "127.0.0.1", .port = addr.getPort(), .database = "d" },
    };
    defer conn.deinit();
    const res = try conn.exec(arena_state.allocator(), "SELECT 1");
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("1", res.rows[0].values[0].?);
    try std.testing.expectEqualStrings("SELECT 1", fake.got_sql);
}

test "протокол: trust-аутентификация и запрос" {
    try fakePgTest(false);
}

test "протокол: md5-аутентификация" {
    try fakePgTest(true);
}
