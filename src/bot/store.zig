//! Персистентное состояние: подписчики, флаги ватчеров, whitelist, курсор.
//!
//! Два бэкенда, один API:
//!  • Postgres (задан MOONOBSRV_DB) — подписчики = app_user.notify, whitelist
//!    со статусами pending/active/denied, kv, сэмплы слоёв, дедуп апдейтов.
//!  • Без БД (режим разработки) — прежний state.json: подписчики в нём,
//!    whitelist открыт всем, /idle* отвечает «нет данных».
//!
//! Небесные флаги (VOC/ретро/лунный день) всегда живут в state.json —
//! это крошечное состояние, не заслуживающее БД. Запись атомарна
//! (tmp + rename). Все операции под мьютексом (два потока: цикл и ватчеры).

const std = @import("std");
const pg = @import("../db/pg.zig");
const wd = @import("wd.zig");
const log = @import("../log.zig").log;

/// Версия схемы state.json. При несовпадении в будущем — миграция здесь.
pub const schema_version: u32 = 2;

const Persist = struct {
    v: u32 = schema_version,
    subs: []const i64 = &.{},
    voc_active: ?bool = null,
    mercury_retro: ?bool = null,
    venus_retro: ?bool = null,
    mars_retro: ?bool = null,
    jupiter_retro: ?bool = null,
    saturn_retro: ?bool = null,
    lunar_day: ?u8 = null,
    last_update_id: i64 = 0,
};

/// Булевы флаги состояния, сравниваемые ватчерами.
pub const Flag = enum {
    voc_active,
    mercury_retro,
    venus_retro,
    mars_retro,
    jupiter_retro,
    saturn_retro,
};

/// Статус доступа пользователя (whitelist в Postgres).
pub const Status = enum { active, pending, denied };

pub const UserRow = struct { id: i64, name: []const u8 };

pub const Sample = wd.Sample;

pub const Store = struct {
    alloc: std.mem.Allocator,
    dir: []const u8,
    mutex: std.Thread.Mutex = .{},

    /// Postgres-бэкенд; null — режим без БД.
    db: ?*pg.Conn = null,
    /// Последняя операция с БД прошла (для /monitor и масок сэмплов).
    db_ok: bool = false,
    mark_count: usize = 0,

    // Доступ только под mutex.
    subs: std.ArrayList(i64),
    /// Кэш active-пользователей whitelist (обновляется при allow/revoke/load).
    active: std.ArrayList(i64),
    voc_active: ?bool = null,
    mercury_retro: ?bool = null,
    venus_retro: ?bool = null,
    mars_retro: ?bool = null,
    jupiter_retro: ?bool = null,
    saturn_retro: ?bool = null,
    lunar_day: ?u8 = null,
    last_update_id: i64 = 0,

    /// Вызывается один раз при старте, до запуска потоков.
    /// Отсутствие файла — не ошибка: начинаем с чистого состояния.
    pub fn load(alloc: std.mem.Allocator, dir: []const u8) Store {
        var st = Store{ .alloc = alloc, .dir = dir, .subs = .empty, .active = .empty };
        const path = std.fs.path.join(alloc, &.{ dir, "state.json" }) catch return st;
        defer alloc.free(path);
        const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return st;
        defer alloc.free(bytes);
        const parsed = std.json.parseFromSlice(Persist, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return st;
        defer parsed.deinit();
        st.voc_active = parsed.value.voc_active;
        st.mercury_retro = parsed.value.mercury_retro;
        st.venus_retro = parsed.value.venus_retro;
        st.mars_retro = parsed.value.mars_retro;
        st.jupiter_retro = parsed.value.jupiter_retro;
        st.saturn_retro = parsed.value.saturn_retro;
        st.lunar_day = parsed.value.lunar_day;
        st.last_update_id = parsed.value.last_update_id;
        st.subs.appendSlice(alloc, parsed.value.subs) catch {};
        return st;
    }

    /// Подключение к Postgres: схема, bootstrap админа, кэши. Ошибки не
    /// фатальны — бот продолжает в режиме JSON (без whitelist/idle).
    pub fn attachDb(self: *Store, url: []const u8, admin_id: i64) !void {
        const conn = try self.alloc.create(pg.Conn);
        errdefer self.alloc.destroy(conn);
        conn.* = try pg.Conn.init(self.alloc, url);
        conn.connect() catch |e| {
            log("pg connect: {s} — работаю без БД", .{@errorName(e)});
            return e;
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        _ = conn.exec(arena.allocator(), schema_sql) catch |e| {
            log("pg schema: {s}", .{@errorName(e)});
            conn.deinit();
            self.alloc.destroy(conn);
            return e;
        };
        if (admin_id != 0) {
            var b: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&b);
            w.print("INSERT INTO app_user (tg_id, status, created_at) VALUES ({d}, 'active', {d}) ON CONFLICT (tg_id) DO NOTHING", .{ admin_id, std.time.timestamp() }) catch {};
            _ = conn.exec(arena.allocator(), w.buffered()) catch |e| log("pg bootstrap admin: {s}", .{@errorName(e)});
        }
        self.db = conn;
        self.db_ok = true;
        self.reloadCaches();
    }

    fn reloadCaches(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.subs.clearRetainingCapacity();
        self.active.clearRetainingCapacity();
        const db = self.db orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const subs = db.exec(a, "SELECT tg_id FROM app_user WHERE notify") catch return;
        for (subs.rows) |row| {
            const id = std.fmt.parseInt(i64, row.values[0] orelse continue, 10) catch continue;
            self.subs.append(self.alloc, id) catch {};
        }
        const act = db.exec(a, "SELECT tg_id FROM app_user WHERE status = 'active'") catch return;
        for (act.rows) |row| {
            const id = std.fmt.parseInt(i64, row.values[0] orelse continue, 10) catch continue;
            self.active.append(self.alloc, id) catch {};
        }
    }

    pub fn dbMode(self: *Store) bool {
        return self.db != null;
    }

    // ─── Небесные флаги (state.json) ───────────────────────────────────────

    pub fn save(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.saveLocked();
    }

    fn saveLocked(self: *Store) !void {
        std.fs.cwd().makePath(self.dir) catch {};
        const path = try std.fs.path.join(self.alloc, &.{ self.dir, "state.json" });
        defer self.alloc.free(path);
        const tmp = try std.fs.path.join(self.alloc, &.{ self.dir, "state.json.tmp" });
        defer self.alloc.free(tmp);

        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        try std.json.Stringify.value(Persist{
            .v = schema_version,
            .subs = self.subs.items,
            .voc_active = self.voc_active,
            .mercury_retro = self.mercury_retro,
            .venus_retro = self.venus_retro,
            .mars_retro = self.mars_retro,
            .jupiter_retro = self.jupiter_retro,
            .saturn_retro = self.saturn_retro,
            .lunar_day = self.lunar_day,
            .last_update_id = self.last_update_id,
        }, .{}, &aw.writer);

        {
            var f = try std.fs.cwd().createFile(tmp, .{});
            defer f.close();
            try f.writeAll(aw.written());
        }
        try std.fs.cwd().rename(tmp, path);
    }

    fn flagPtr(self: *Store, f: Flag) *?bool {
        return switch (f) {
            .voc_active => &self.voc_active,
            .mercury_retro => &self.mercury_retro,
            .venus_retro => &self.venus_retro,
            .mars_retro => &self.mars_retro,
            .jupiter_retro => &self.jupiter_retro,
            .saturn_retro => &self.saturn_retro,
        };
    }

    pub fn getFlag(self: *Store, f: Flag) ?bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.flagPtr(f).*;
    }

    pub fn setFlag(self: *Store, f: Flag, v: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flagPtr(f).* = v;
        try self.saveLocked();
    }

    /// Установить флаг без записи на диск — для пакетной инициализации.
    pub fn setFlagQuiet(self: *Store, f: Flag, v: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flagPtr(f).* = v;
    }

    pub fn lunarDay(self: *Store) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.lunar_day;
    }

    pub fn setLunarDay(self: *Store, v: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lunar_day = v;
        try self.saveLocked();
    }

    // ─── Курсор Telegram ───────────────────────────────────────────────────

    pub fn updateCursor(self: *Store) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_update_id;
    }

    pub fn setUpdateCursor(self: *Store, v: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_update_id = v;
        try self.saveLocked();
        if (self.db) |db| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            var b: [96]u8 = undefined;
            var w: std.Io.Writer = .fixed(&b);
            w.print("INSERT INTO bot_kv (k, v) VALUES ('tg_offset', '{d}') ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v", .{v}) catch return;
            self.db_ok = if (db.exec(arena.allocator(), w.buffered())) |_| true else |_| false;
        }
    }

    /// Курсор, сохранённый в БД (0 — нет). Для старта: max(файл, БД).
    pub fn dbCursor(self: *Store) i64 {
        const db = self.db orelse return 0;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const res = db.exec(arena.allocator(), "SELECT v FROM bot_kv WHERE k = 'tg_offset'") catch return 0;
        if (res.rows.len == 0) return 0;
        return std.fmt.parseInt(i64, res.rows[0].values[0] orelse return 0, 10) catch 0;
    }

    /// Дедупликация апдейтов (tg_inbox). true — уже видели.
    pub fn updateSeen(self: *Store, id: i64) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("SELECT 1 FROM tg_inbox WHERE update_id = {d}", .{id}) catch return false;
        const res = db.exec(arena.allocator(), w.buffered()) catch return false;
        return res.rows.len > 0;
    }

    pub fn markUpdate(self: *Store, id: i64) void {
        const db = self.db orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("INSERT INTO tg_inbox (update_id, ts) VALUES ({d}, {d}) ON CONFLICT DO NOTHING", .{ id, std.time.timestamp() }) catch return;
        _ = db.exec(arena.allocator(), w.buffered()) catch return;
        self.mark_count += 1;
        if (self.mark_count % 50 == 0) {
            // чистка старых дедуп-записей без крона
            var p: [128]u8 = undefined;
            var pw: std.Io.Writer = .fixed(&p);
            pw.print("DELETE FROM tg_inbox WHERE ts < {d}", .{std.time.timestamp() - 90 * 86400}) catch return;
            _ = db.exec(arena.allocator(), pw.buffered()) catch return;
        }
    }

    // ─── Подписчики ────────────────────────────────────────────────────────

    pub fn hasSub(self: *Store, id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subs.items) |x| {
            if (x == id) return true;
        }
        return false;
    }

    pub fn addSub(self: *Store, id: i64) !void {
        self.mutex.lock();
        var found = false;
        for (self.subs.items) |x| {
            if (x == id) found = true;
        }
        if (!found) try self.subs.append(self.alloc, id);
        self.mutex.unlock();
        if (self.db) |db| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            var b: [160]u8 = undefined;
            var w: std.Io.Writer = .fixed(&b);
            w.print("INSERT INTO app_user (tg_id, status, notify, created_at) VALUES ({d}, 'active', TRUE, {d}) ON CONFLICT (tg_id) DO UPDATE SET notify = TRUE", .{ id, std.time.timestamp() }) catch return;
            self.db_ok = if (db.exec(arena.allocator(), w.buffered())) |_| true else |_| false;
        } else {
            try self.save();
        }
    }

    pub fn removeSub(self: *Store, id: i64) !void {
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.subs.items.len) : (i += 1) {
            if (self.subs.items[i] == id) {
                _ = self.subs.orderedRemove(i);
                break;
            }
        }
        self.mutex.unlock();
        if (self.db) |db| {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            var b: [96]u8 = undefined;
            var w: std.Io.Writer = .fixed(&b);
            w.print("UPDATE app_user SET notify = FALSE WHERE tg_id = {d}", .{id}) catch return;
            self.db_ok = if (db.exec(arena.allocator(), w.buffered())) |_| true else |_| false;
        } else {
            try self.save();
        }
    }

    /// Копия подписчиков для рассылки (читается под мьютексом).
    pub fn subsSnapshot(self: *Store, buf: []i64) []i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buf.len, self.subs.items.len);
        @memcpy(buf[0..n], self.subs.items[0..n]);
        return buf[0..n];
    }

    // ─── Whitelist ─────────────────────────────────────────────────────────

    /// Без БД бот открыт: все считаются active.
    pub fn statusOf(self: *Store, id: i64, buf: []u8) Status {
        const db = self.db orelse return .active;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var w: std.Io.Writer = .fixed(buf);
        w.print("SELECT status FROM app_user WHERE tg_id = {d}", .{id}) catch return .active;
        const res = db.exec(arena.allocator(), w.buffered()) catch return .active;
        if (res.rows.len == 0) return .pending; // неизвестный → заявка
        const s = res.rows[0].values[0] orelse return .pending;
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "denied")) return .denied;
        return .pending;
    }

    pub fn isActive(self: *Store, id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.active.items) |x| {
            if (x == id) return true;
        }
        return false;
    }

    /// Заявка на доступ. true — админа нужно уведомить (анти-спам:
    /// повторная заявка молчит, /start форсирует).
    pub fn requestAccess(self: *Store, id: i64, name: []const u8) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        {
            var b: [128]u8 = undefined;
            var w: std.Io.Writer = .fixed(&b);
            w.print("SELECT status FROM app_user WHERE tg_id = {d}", .{id}) catch return false;
            const res = db.exec(a, w.buffered()) catch return false;
            if (res.rows.len > 0) {
                const s = res.rows[0].values[0] orelse "";
                if (std.mem.eql(u8, s, "active")) return false;
                if (std.mem.eql(u8, s, "pending")) return false; // уже на рассмотрении
                // denied: молча обновляем заявку, без уведомления
            }
        }
        var nb: [512]u8 = undefined;
        var name_esc: std.Io.Writer = .fixed(nb[0..400]);
        pg.quoteLit(&name_esc, name) catch return false;
        var w2: std.Io.Writer = .fixed(&nb);
        w2.print("INSERT INTO app_user (tg_id, status, display_name, created_at) VALUES ({d}, 'pending', ", .{id}) catch return false;
        w2.writeAll(name_esc.buffered()) catch return false;
        w2.print(", {d}) ON CONFLICT (tg_id) DO UPDATE SET status = 'pending', display_name = EXCLUDED.display_name", .{std.time.timestamp()}) catch return false;
        self.db_ok = db.exec(a, w2.buffered());
        return self.db_ok;
    }

    pub fn allowUser(self: *Store, id: i64) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("INSERT INTO app_user (tg_id, status, created_at, decided_at) VALUES ({d}, 'active', {d}, {d}) ON CONFLICT (tg_id) DO UPDATE SET status = 'active', decided_at = {d}", .{ id, std.time.timestamp(), std.time.timestamp(), std.time.timestamp() }) catch return false;
        const ok = db.exec(arena.allocator(), w.buffered());
        self.db_ok = ok;
        if (ok) {
            self.mutex.lock();
            defer self.mutex.unlock();
            var found = false;
            for (self.active.items) |x| {
                if (x == id) found = true;
            }
            if (!found) self.active.append(self.alloc, id) catch {};
        }
        return ok;
    }

    pub fn denyUser(self: *Store, id: i64) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("UPDATE app_user SET status = 'denied', decided_at = {d} WHERE tg_id = {d} AND status != 'active'", .{ std.time.timestamp(), id }) catch return false;
        const res = db.exec(arena.allocator(), w.buffered()) catch return false;
        self.db_ok = true;
        return res.rows.len == 0 and std.mem.startsWith(u8, res.command_tag, "UPDATE");
    }

    /// Отзыв доступа: только active → denied. true — отозван.
    pub fn revokeUser(self: *Store, id: i64) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("UPDATE app_user SET status = 'denied', notify = FALSE, decided_at = {d} WHERE tg_id = {d} AND status = 'active'", .{ std.time.timestamp(), id }) catch return false;
        const res = db.exec(arena.allocator(), w.buffered()) catch return false;
        self.db_ok = true;
        if (std.mem.startsWith(u8, res.command_tag, "UPDATE")) {
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, res.command_tag["UPDATE ".len..], " "), 10) catch 0;
            if (n > 0) {
                self.mutex.lock();
                defer self.mutex.unlock();
                var i: usize = 0;
                while (i < self.active.items.len) : (i += 1) {
                    if (self.active.items[i] == id) {
                        _ = self.active.orderedRemove(i);
                        break;
                    }
                }
                i = 0;
                while (i < self.subs.items.len) : (i += 1) {
                    if (self.subs.items[i] == id) {
                        _ = self.subs.orderedRemove(i);
                        break;
                    }
                }
                return true;
            }
        }
        return false;
    }

    /// Список active-пользователей в арены вызывающего.
    pub fn listActive(self: *Store, arena: std.mem.Allocator) ![]UserRow {
        const db = self.db orelse return &.{};
        var b: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("SELECT tg_id, display_name FROM app_user WHERE status = 'active' ORDER BY tg_id", .{}) catch return &.{};
        const res = db.exec(arena, w.buffered()) catch return &.{};
        var list: std.ArrayList(UserRow) = .empty;
        for (res.rows) |row| {
            const id = std.fmt.parseInt(i64, row.values[0] orelse continue, 10) catch continue;
            try list.append(arena, .{ .id = id, .name = row.values[1] orelse "" });
        }
        return list.items;
    }

    // ─── Сэмплы слоёв (idle-статистика) ────────────────────────────────────

    pub fn putLayerSample(self: *Store, ts: i64, mask: i32, disk_pct: i16) void {
        const db = self.db orelse return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var b: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("INSERT INTO layer_sample (ts, mask, disk_pct) VALUES ({d}, {d}, {d}); DELETE FROM layer_sample WHERE ts < {d}", .{ ts, mask, disk_pct, ts - 400 * 86400 }) catch return;
        self.db_ok = if (db.exec(arena.allocator(), w.buffered())) |_| true else |_| false;
    }

    pub fn layerSamples(self: *Store, arena: std.mem.Allocator, from: i64, to: i64) []Sample {
        const db = self.db orelse return &.{};
        var b: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&b);
        w.print("SELECT ts, mask FROM layer_sample WHERE ts >= {d} AND ts <= {d} ORDER BY ts", .{ from, to }) catch return &.{};
        const res = db.exec(arena, w.buffered()) catch return &.{};
        var list: std.ArrayList(Sample) = .empty;
        for (res.rows) |row| {
            const ts = std.fmt.parseInt(i64, row.values[0] orelse continue, 10) catch continue;
            const mask = std.fmt.parseInt(i32, row.values[1] orelse continue, 10) catch continue;
            list.append(arena, .{ .ts = ts, .mask = mask }) catch return &.{};
        }
        return list.items;
    }

    pub fn pingDb(self: *Store) bool {
        const db = self.db orelse return false;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const ok = db.ping(arena.allocator());
        self.db_ok = ok;
        return ok;
    }

    pub fn deinit(self: *Store) void {
        if (self.db) |db| {
            db.deinit();
            self.alloc.destroy(db);
        }
        self.subs.deinit(self.alloc);
        self.active.deinit(self.alloc);
    }
};

const schema_sql =
    \\CREATE TABLE IF NOT EXISTS app_user (
    \\  tg_id BIGINT PRIMARY KEY,
    \\  status TEXT NOT NULL,
    \\  display_name TEXT NOT NULL DEFAULT '',
    \\  notify BOOLEAN NOT NULL DEFAULT FALSE,
    \\  created_at BIGINT NOT NULL DEFAULT 0,
    \\  decided_at BIGINT
    \\);
    \\CREATE TABLE IF NOT EXISTS layer_sample (
    \\  ts BIGINT NOT NULL,
    \\  mask INTEGER NOT NULL,
    \\  disk_pct SMALLINT NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_layer_sample_ts ON layer_sample (ts);
    \\CREATE TABLE IF NOT EXISTS bot_kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
    \\CREATE TABLE IF NOT EXISTS tg_inbox (update_id BIGINT PRIMARY KEY, ts BIGINT NOT NULL)
;

test "store roundtrip (JSON-режим)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var st = Store.load(alloc, dir);
    defer st.subs.deinit(alloc);
    defer st.active.deinit(alloc);
    try st.addSub(42);
    try st.addSub(42); // дубликат игнорируется
    try st.addSub(7);
    try st.setFlag(.voc_active, true);
    try st.setFlag(.venus_retro, false);
    try st.setLunarDay(23);
    try st.setUpdateCursor(1000);
    try st.save();

    var st2 = Store.load(alloc, dir);
    defer st2.subs.deinit(alloc);
    defer st2.active.deinit(alloc);
    try std.testing.expect(st2.hasSub(42));
    try std.testing.expect(st2.hasSub(7));
    var snap: [8]i64 = undefined;
    try std.testing.expectEqual(@as(usize, 2), st2.subsSnapshot(&snap).len);
    try std.testing.expectEqual(true, st2.getFlag(.voc_active));
    try std.testing.expectEqual(false, st2.getFlag(.venus_retro));
    try std.testing.expectEqual(@as(?u8, 23), st2.lunarDay());
    try std.testing.expectEqual(@as(i64, 1000), st2.updateCursor());

    // без БД бот открыт
    try std.testing.expectEqual(Status.active, st2.statusOf(999, undefined));
    try std.testing.expect(!st2.dbMode());
}

test "schema_sql: идемпотентные таблицы" {
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE TABLE IF NOT EXISTS app_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE TABLE IF NOT EXISTS layer_sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE TABLE IF NOT EXISTS bot_kv") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, "CREATE TABLE IF NOT EXISTS tg_inbox") != null);
    // несколько команд в одном batch — допустимо простым протоколом
    try std.testing.expect(std.mem.indexOf(u8, schema_sql, ";") != null);
}
