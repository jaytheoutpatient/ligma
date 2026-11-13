const std = @import("std");
const skip = @import("skip.zig");

/// Zig 0.17 removed `@cImport`, so the small SQLite surface this app uses is
/// declared directly. Keeping it narrow also documents exactly what we depend
/// on and avoids translating the whole sqlite3.h on every build.
const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;

    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;

    pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
    pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;

    pub extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        ppDb: *?*sqlite3,
        flags: c_int,
        zVfs: ?[*:0]const u8,
    ) c_int;
    pub extern fn sqlite3_close(db: ?*sqlite3) c_int;
    pub extern fn sqlite3_busy_timeout(db: ?*sqlite3, milliseconds: c_int) c_int;
    pub extern fn sqlite3_exec(
        db: ?*sqlite3,
        sql: [*:0]const u8,
        callback: ?*const anyopaque,
        arg: ?*anyopaque,
        error_message: ?*?[*:0]u8,
    ) c_int;
    pub extern fn sqlite3_free(pointer: ?*anyopaque) void;
    pub extern fn sqlite3_prepare_v2(
        db: ?*sqlite3,
        sql: [*]const u8,
        byte_count: c_int,
        stmt: *?*sqlite3_stmt,
        tail: ?*anyopaque,
    ) c_int;
    pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_bind_text(
        stmt: ?*sqlite3_stmt,
        index: c_int,
        text: [*]const u8,
        byte_count: c_int,
        destructor: sqlite3_destructor_type,
    ) c_int;
    pub extern fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, index: c_int, value: c_int) c_int;
    pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
    pub extern fn sqlite3_interrupt(db: ?*sqlite3) void;
    pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, index: c_int) ?[*:0]const u8;
    pub extern fn sqlite3_column_int(stmt: ?*sqlite3_stmt, index: c_int) c_int;
};

/// SQLite wants a sentinel pointer instead of a length with SQLITE_TRANSIENT.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const schema_version: u32 = 1;
pub const result_limit: usize = 500;

const schema_sql: [:0]const u8 =
    \\DROP TABLE IF EXISTS files_fts;
    \\DROP TABLE IF EXISTS files_fts_trigram;
    \\DROP TABLE IF EXISTS files;
    \\DROP TABLE IF EXISTS meta;
    \\CREATE TABLE files (
    \\    id INTEGER PRIMARY KEY,
    \\    path TEXT NOT NULL UNIQUE,
    \\    name TEXT NOT NULL,
    \\    is_dir INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE VIRTUAL TABLE files_fts USING fts5(
    \\    name,
    \\    content='files',
    \\    content_rowid='id',
    \\    tokenize='unicode61'
    \\);
    \\CREATE VIRTUAL TABLE files_fts_trigram USING fts5(
    \\    name,
    \\    content='files',
    \\    content_rowid='id',
    \\    tokenize='trigram'
    \\);
    \\CREATE TABLE meta (
    \\    key TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
    \\PRAGMA user_version = 1;
;

const pragmas_sql: [:0]const u8 =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\PRAGMA temp_store = MEMORY;
    \\PRAGMA foreign_keys = OFF;
;

const fts_rebuild_sql: [:0]const u8 =
    \\BEGIN;
    \\INSERT INTO files_fts(files_fts) VALUES('rebuild');
    \\INSERT INTO files_fts_trigram(files_fts_trigram) VALUES('rebuild');
    \\COMMIT;
;

const open_flags_read: c_int = c.SQLITE_OPEN_READONLY;
const open_flags_write: c_int = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;

/// The database lives beside other per-user Ligma state.
pub fn dbPath(allocator: std.mem.Allocator) ![]u8 {
    return dirPath(allocator, "search.db");
}

pub fn dataDir(allocator: std.mem.Allocator) ![]u8 {
    return dirPath(allocator, null);
}

fn dirPath(allocator: std.mem.Allocator, file: ?[]const u8) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |raw| {
        const xdg = std.mem.span(raw);
        if (xdg.len > 0 and xdg[0] == '/') {
            return if (file) |name|
                std.fs.path.join(allocator, &.{ xdg, "ligma", name })
            else
                std.fs.path.join(allocator, &.{ xdg, "ligma" });
        }
    }

    const home = if (std.c.getenv("HOME")) |raw| std.mem.span(raw) else "/";
    return if (file) |name|
        std.fs.path.join(allocator, &.{ home, ".local", "share", "ligma", name })
    else
        std.fs.path.join(allocator, &.{ home, ".local", "share", "ligma" });
}

/// Tests and privacy-conscious users can opt out of the automatic background
/// build. An existing index is still used when present.
pub fn autoIndexEnabled() bool {
    if (std.c.getenv("LIGMA_SKIP_INDEX")) |raw| {
        const value = std.mem.span(raw);
        return value.len == 0 or std.mem.eql(u8, value, "0");
    }
    return true;
}

pub const Hit = struct {
    /// Owned by the caller once returned.
    path: []u8,
    is_dir: bool,
};

/// A read connection to a completed index. SQLite is used in serialized mode
/// by default; this connection is normally only touched from the UI thread
/// while `BuildJob` uses its own connection.
pub const Reader = struct {
    gpa: std.mem.Allocator,
    db: *c.sqlite3,
    root: []u8,
    file_count: usize,

    pub fn open(gpa: std.mem.Allocator, path: []const u8) !Reader {
        const db = try openDatabase(gpa, path, open_flags_read);
        errdefer _ = c.sqlite3_close(db);
        _ = c.sqlite3_busy_timeout(db, 5000);

        const status = (try readMeta(gpa, db, "status")) orelse return error.NotReady;
        defer gpa.free(status);
        if (!std.mem.eql(u8, status, "complete")) return error.NotReady;

        const version_text = (try readMeta(gpa, db, "schema_version")) orelse return error.NotReady;
        defer gpa.free(version_text);
        const version = std.fmt.parseInt(u32, version_text, 10) catch return error.NotReady;
        if (version != schema_version) return error.NotReady;

        const root = (try readMeta(gpa, db, "root")) orelse return error.NotReady;
        errdefer gpa.free(root);

        const count_text = (try readMeta(gpa, db, "file_count")) orelse try gpa.dupe(u8, "0");
        defer gpa.free(count_text);
        const file_count = std.fmt.parseInt(usize, count_text, 10) catch 0;

        return .{
            .gpa = gpa,
            .db = db,
            .root = root,
            .file_count = file_count,
        };
    }

    pub fn deinit(self: *Reader) void {
        _ = c.sqlite3_close(self.db);
        self.gpa.free(self.root);
        self.* = undefined;
    }

    pub fn coversRoot(self: *const Reader, path: []const u8) bool {
        if (std.mem.eql(u8, self.root, "/")) return true;
        if (std.mem.eql(u8, path, self.root)) return true;
        return path.len > self.root.len and
            std.mem.startsWith(u8, path, self.root) and
            path[self.root.len] == '/';
    }

    /// Search names below `under`, newest index snapshot. Hits are owned by
    /// `results`; on an error any appended hits are freed before returning.
    pub fn search(
        self: *Reader,
        query: []const u8,
        under: []const u8,
        limit: usize,
        results: *std.ArrayList(Hit),
    ) !void {
        if (query.len == 0) return;

        const prefix = if (std.mem.eql(u8, under, "/"))
            try self.gpa.dupe(u8, "/")
        else
            try std.fmt.allocPrint(self.gpa, "{s}/", .{under});
        defer self.gpa.free(prefix);

        const c_limit: c_int = @intCast(@min(limit, std.math.maxInt(c_int)));
        const c_prefix_len: c_int = @intCast(prefix.len);
        const start_len = results.items.len;

        errdefer {
            while (results.items.len > start_len) {
                const hit = results.pop().?;
                self.gpa.free(hit.path);
            }
        }

        if (query.len >= 3) {
            const phrase = try quoteFts(self.gpa, query);
            defer self.gpa.free(phrase);

            const stmt = try prepare(
                self.db,
                "SELECT f.path, f.is_dir FROM files_fts_trigram " ++
                    "JOIN files AS f ON f.id = files_fts_trigram.rowid " ++
                    "WHERE files_fts_trigram MATCH ?1 " ++
                    "AND substr(f.path, 1, ?2) = ?3 " ++
                    "ORDER BY f.is_dir DESC, f.name COLLATE NOCASE LIMIT ?4",
            );
            defer _ = c.sqlite3_finalize(stmt);

            try bindText(stmt, 1, phrase);
            try bindInt(stmt, 2, c_prefix_len);
            try bindText(stmt, 3, prefix);
            try bindInt(stmt, 4, c_limit);
            try collectHits(self.gpa, stmt, results);
        } else {
            const pattern = try likePattern(self.gpa, query);
            defer self.gpa.free(pattern);

            const stmt = try prepare(
                self.db,
                "SELECT path, is_dir FROM files " ++
                    "WHERE name LIKE ?1 ESCAPE '\\' " ++
                    "AND substr(path, 1, ?2) = ?3 " ++
                    "ORDER BY is_dir DESC, name COLLATE NOCASE LIMIT ?4",
            );
            defer _ = c.sqlite3_finalize(stmt);

            try bindText(stmt, 1, pattern);
            try bindInt(stmt, 2, c_prefix_len);
            try bindText(stmt, 3, prefix);
            try bindInt(stmt, 4, c_limit);
            try collectHits(self.gpa, stmt, results);
        }
    }
};

/// Convenience for startup: does a completed, schema-compatible index exist?
pub fn isReady(gpa: std.mem.Allocator, path: []const u8) bool {
    var reader = Reader.open(gpa, path) catch return false;
    reader.deinit();
    return true;
}

/// Owns a background connection and the walk that fills it. Progress is
/// atomic so the UI timer can poll without sharing a mutex with SQLite.
pub const BuildJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db_path: []u8,
    root: []u8,
    skip_prefix: ?[]u8,

    files_indexed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_db: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    thread: ?std.Thread = null,

    const max_files: usize = 2_000_000;
    const batch_size: usize = 2048;

    pub const Progress = struct {
        files: usize,
        done: bool,
        failed: bool,
    };

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        db_path: []const u8,
        root: []const u8,
        skip_prefix: ?[]const u8,
    ) !*BuildJob {
        const self = try gpa.create(BuildJob);
        errdefer gpa.destroy(self);

        const db_copy = try gpa.dupe(u8, db_path);
        errdefer gpa.free(db_copy);
        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const skip_copy = if (skip_prefix) |prefix| try gpa.dupe(u8, prefix) else null;

        self.* = .{
            .gpa = gpa,
            .io = io,
            .db_path = db_copy,
            .root = root_copy,
            .skip_prefix = skip_copy,
        };
        return self;
    }

    pub fn start(self: *BuildJob) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn requestCancel(self: *BuildJob) void {
        self.cancel.store(true, .release);
        const address = self.active_db.load(.acquire);
        if (address != 0) c.sqlite3_interrupt(@ptrFromInt(address));
    }

    pub fn join(self: *BuildJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *BuildJob) void {
        self.requestCancel();
        self.join();

        self.gpa.free(self.db_path);
        self.gpa.free(self.root);
        if (self.skip_prefix) |prefix| self.gpa.free(prefix);
        self.gpa.destroy(self);
    }

    pub fn progress(self: *BuildJob) Progress {
        return .{
            .files = self.files_indexed.load(.acquire),
            .done = self.done.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }

    fn worker(self: *BuildJob) void {
        self.build() catch {
            self.failed.store(true, .release);
        };
        self.done.store(true, .release);
    }

    fn build(self: *BuildJob) !void {
        const db = try openDatabase(self.gpa, self.db_path, open_flags_write);
        self.active_db.store(@intFromPtr(db), .release);
        defer {
            self.active_db.store(0, .release);
            _ = c.sqlite3_close(db);
        }
        _ = c.sqlite3_busy_timeout(db, 5000);

        try execSql(db, pragmas_sql);
        try execSql(db, schema_sql);
        try self.markBuilding(db);

        try execSql(db, "BEGIN IMMEDIATE");
        var in_transaction = true;
        errdefer {
            if (in_transaction) execSql(db, "ROLLBACK") catch {};
        }

        const stmt = try prepare(
            db,
            "INSERT INTO files(path, name, is_dir) VALUES(?1, ?2, ?3)",
        );
        defer _ = c.sqlite3_finalize(stmt);

        var pending: usize = 0;
        try self.walk(db, stmt, &pending);
        if (in_transaction) {
            try execSql(db, "COMMIT");
            in_transaction = false;
        }
        if (self.cancel.load(.acquire)) return error.Cancelled;

        try execSql(db, fts_rebuild_sql);
        try self.markComplete(db);
        execSql(db, "PRAGMA optimize") catch {};
        execSql(db, "PRAGMA wal_checkpoint(TRUNCATE)") catch {};
    }

    fn walk(self: *BuildJob, db: *c.sqlite3, stmt: *c.sqlite3_stmt, pending: *usize) !void {
        var queue: std.ArrayList([]u8) = .empty;
        var head: usize = 0;
        defer {
            for (queue.items[head..]) |path| self.gpa.free(path);
            queue.deinit(self.gpa);
        }

        const root_copy = try self.gpa.dupe(u8, self.root);
        {
            errdefer self.gpa.free(root_copy);
            try queue.append(self.gpa, root_copy);
        }

        while (head < queue.items.len) {
            const path = queue.items[head];
            head += 1;
            defer self.gpa.free(path);

            if (self.cancel.load(.acquire)) return error.Cancelled;
            if (self.files_indexed.load(.monotonic) >= max_files) return;

            var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);

            var iterator = dir.iterate();
            while (true) {
                if (self.cancel.load(.acquire)) return error.Cancelled;
                if (self.files_indexed.load(.monotonic) >= max_files) return;

                const maybe_entry = iterator.next(self.io) catch break;
                const entry = maybe_entry orelse break;
                const is_dir = entry.kind == .directory;

                if (is_dir and skip.shouldSkipDir(entry.name, path)) continue;

                const full_path = std.fs.path.join(self.gpa, &.{ path, entry.name }) catch continue;
                if (is_dir) {
                    if (self.isUnderSkipPrefix(full_path)) {
                        self.gpa.free(full_path);
                        continue;
                    }
                }

                insertFile(stmt, full_path, entry.name, is_dir) catch {
                    self.gpa.free(full_path);
                    return error.SqliteInsert;
                };
                _ = self.files_indexed.fetchAdd(1, .monotonic);
                pending.* += 1;

                if (is_dir) {
                    queue.append(self.gpa, full_path) catch self.gpa.free(full_path);
                } else {
                    self.gpa.free(full_path);
                }

                if (pending.* >= batch_size) {
                    try execSql(db, "COMMIT");
                    try execSql(db, "BEGIN IMMEDIATE");
                    pending.* = 0;
                }
            }
        }
    }

    fn isUnderSkipPrefix(self: *BuildJob, path: []const u8) bool {
        const prefix = self.skip_prefix orelse return false;
        if (std.mem.eql(u8, path, prefix)) return true;
        return path.len > prefix.len and
            std.mem.startsWith(u8, path, prefix) and
            path[prefix.len] == '/';
    }

    fn markBuilding(self: *BuildJob, db: *c.sqlite3) !void {
        var version_buffer: [16]u8 = undefined;
        const version = std.fmt.bufPrint(&version_buffer, "{d}", .{schema_version}) catch "1";
        var time_buffer: [32]u8 = undefined;
        const started_at = std.fmt.bufPrint(&time_buffer, "{d}", .{
            std.Io.Timestamp.now(self.io, .real).toSeconds(),
        }) catch "0";

        try execSql(db, "BEGIN");
        errdefer {
            execSql(db, "ROLLBACK") catch {};
        }
        try setMeta(db, "status", "building");
        try setMeta(db, "schema_version", version);
        try setMeta(db, "root", self.root);
        try setMeta(db, "file_count", "0");
        try setMeta(db, "started_at", started_at);
        try execSql(db, "DELETE FROM files");
        try execSql(db, "COMMIT");
    }

    fn markComplete(self: *BuildJob, db: *c.sqlite3) !void {
        var count_buffer: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d}", .{
            self.files_indexed.load(.acquire),
        }) catch "0";
        var time_buffer: [32]u8 = undefined;
        const built_at = std.fmt.bufPrint(&time_buffer, "{d}", .{
            std.Io.Timestamp.now(self.io, .real).toSeconds(),
        }) catch "0";

        try execSql(db, "BEGIN");
        errdefer {
            execSql(db, "ROLLBACK") catch {};
        }
        try setMeta(db, "file_count", count);
        try setMeta(db, "built_at", built_at);
        try setMeta(db, "status", "complete");
        try execSql(db, "COMMIT");
    }
};

fn openDatabase(gpa: std.mem.Allocator, path: []const u8, flags: c_int) !*c.sqlite3 {
    const path_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(path_z);

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path_z.ptr, &db, flags, null);
    if (rc != c.SQLITE_OK) {
        if (db) |handle| _ = c.sqlite3_close(handle);
        return error.SqliteOpen;
    }
    return db orelse error.SqliteOpen;
}

fn execSql(db: *c.sqlite3, sql: [:0]const u8) !void {
    var error_message: ?[*:0]u8 = null;
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, &error_message);
    if (error_message) |message| c.sqlite3_free(@ptrCast(message));
    if (rc != c.SQLITE_OK) return error.SqliteExec;
}

fn prepare(db: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    // SQL strings used here are all comptime literals with a sentinel.
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != c.SQLITE_OK) return error.SqlitePrepare;
    return stmt orelse error.SqlitePrepare;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), SQLITE_TRANSIENT) != c.SQLITE_OK) {
        return error.SqliteBind;
    }
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: c_int) !void {
    if (c.sqlite3_bind_int(stmt, index, value) != c.SQLITE_OK) return error.SqliteBind;
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStep;
}

fn insertFile(
    stmt: *c.sqlite3_stmt,
    path: []const u8,
    name: []const u8,
    is_dir: bool,
) !void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
    try bindText(stmt, 1, path);
    try bindText(stmt, 2, name);
    try bindInt(stmt, 3, if (is_dir) 1 else 0);
    try stepDone(stmt);
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const raw = c.sqlite3_column_text(stmt, index) orelse return "";
    return std.mem.span(raw);
}

fn collectHits(
    gpa: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    results: *std.ArrayList(Hit),
) !void {
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;

        const path = try gpa.dupe(u8, columnText(stmt, 0));
        errdefer gpa.free(path);
        try results.append(gpa, .{
            .path = path,
            .is_dir = c.sqlite3_column_int(stmt, 1) != 0,
        });
    }
}

fn setMeta(db: *c.sqlite3, key: []const u8, value: []const u8) !void {
    const stmt = try prepare(
        db,
        "INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, key);
    try bindText(stmt, 2, value);
    try stepDone(stmt);
}

fn readMeta(gpa: std.mem.Allocator, db: *c.sqlite3, key: []const u8) !?[]u8 {
    const stmt = try prepare(db, "SELECT value FROM meta WHERE key = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, key);

    const rc = c.sqlite3_step(stmt);
    if (rc == c.SQLITE_DONE) return null;
    if (rc != c.SQLITE_ROW) return error.SqliteStep;
    return try gpa.dupe(u8, columnText(stmt, 0));
}

/// Wrap a user query as a single FTS5 phrase so punctuation cannot be parsed
/// as FTS syntax. Embedded double quotes are doubled.
fn quoteFts(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '"');
    for (query) |ch| {
        if (ch == '"') try out.append(gpa, '"');
        try out.append(gpa, ch);
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn likePattern(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '%');
    for (query) |ch| {
        switch (ch) {
            '\\', '%', '_' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, ch);
    }
    try out.append(gpa, '%');
    return out.toOwnedSlice(gpa);
}

test "fts phrase quoting" {
    const gpa = std.testing.allocator;
    const phrase = try quoteFts(gpa, "read \"me\"");
    defer gpa.free(phrase);
    try std.testing.expectEqualStrings("\"read \"\"me\"\"\"", phrase);
}

test "like pattern escaping" {
    const gpa = std.testing.allocator;
    const pattern = try likePattern(gpa, "100%_done");
    defer gpa.free(pattern);
    try std.testing.expectEqualStrings("%100\\%\\_done%", pattern);
}
