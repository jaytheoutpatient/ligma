const std = @import("std");
const skip = @import("skip.zig");

/// A cancellable, recursive filename search running on a worker thread.
///
/// This is the first search implementation: no index, no content extraction,
/// just an efficient name walk. Results are drained from the UI thread by a
/// QTimer. The SQLite FTS5 index will replace the walk for global searches
/// while keeping this scanner for "search inside this folder now" requests.
pub const Scan = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    needle: []u8,

    mutex: std.Io.Mutex = .init,
    results: std.ArrayList([]u8) = .empty,
    scanned_dirs: usize = 0,
    done: bool = false,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    const max_results = 2000;

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        needle: []const u8,
    ) !*Scan {
        const self = try gpa.create(Scan);
        errdefer gpa.destroy(self);

        const root_copy = try gpa.dupe(u8, root);
        errdefer gpa.free(root_copy);
        const needle_copy = try gpa.dupe(u8, needle);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .root = root_copy,
            .needle = needle_copy,
        };
        return self;
    }

    pub fn start(self: *Scan) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn requestCancel(self: *Scan) void {
        self.cancel.store(true, .release);
    }

    pub fn join(self: *Scan) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Scan) void {
        self.requestCancel();
        self.join();

        for (self.results.items) |path| self.gpa.free(path);
        self.results.deinit(self.gpa);
        self.gpa.free(self.root);
        self.gpa.free(self.needle);
        self.gpa.destroy(self);
    }

    /// Move all currently known results out of the worker-owned list.
    pub fn takeResults(self: *Scan) std.ArrayList([]u8) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const taken = self.results;
        self.results = .empty;
        return taken;
    }

    pub fn isDone(self: *Scan) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.done;
    }

    pub fn scannedDirs(self: *Scan) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scanned_dirs;
    }

    fn worker(self: *Scan) void {
        self.walk();
        self.mutex.lockUncancelable(self.io);
        self.done = true;
        self.mutex.unlock(self.io);
    }

    fn walk(self: *Scan) void {
        var queue: std.ArrayList([]u8) = .empty;
        var head: usize = 0;
        defer {
            for (queue.items[head..]) |path| self.gpa.free(path);
            queue.deinit(self.gpa);
        }

        const root_copy = self.gpa.dupe(u8, self.root) catch return;
        queue.append(self.gpa, root_copy) catch {
            self.gpa.free(root_copy);
            return;
        };

        // Breadth-first traversal: nearby matches show up immediately instead
        // of diving into the first deep subtree.
        while (head < queue.items.len) {
            const path = queue.items[head];
            head += 1;
            defer self.gpa.free(path);

            if (self.cancel.load(.acquire)) return;
            if (self.reachedLimit()) return;
            if (head > 200_000) return;

            self.mutex.lockUncancelable(self.io);
            self.scanned_dirs += 1;
            self.mutex.unlock(self.io);

            var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);

            var iterator = dir.iterate();
            while (true) {
                if (self.cancel.load(.acquire)) return;
                if (self.reachedLimit()) return;

                const maybe_entry = iterator.next(self.io) catch break;
                const entry = maybe_entry orelse break;

                const full_path = std.fs.path.join(self.gpa, &.{ path, entry.name }) catch continue;
                const matched = containsIgnoreCase(entry.name, self.needle);

                if (entry.kind == .directory) {
                    if (skip.shouldSkipDir(entry.name, path)) {
                        self.gpa.free(full_path);
                        continue;
                    }
                    if (matched) {
                        if (self.gpa.dupe(u8, full_path)) |copy| {
                            self.addResult(copy);
                        } else |_| {}
                    }
                    queue.append(self.gpa, full_path) catch self.gpa.free(full_path);
                } else {
                    if (matched) {
                        self.addResult(full_path);
                    } else {
                        self.gpa.free(full_path);
                    }
                }
            }
        }
    }

    fn reachedLimit(self: *Scan) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.results.items.len >= max_results;
    }

    fn addResult(self: *Scan, path: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.results.items.len >= max_results) {
            self.gpa.free(path);
            return;
        }
        self.results.append(self.gpa, path) catch self.gpa.free(path);
    }
};

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "case-insensitive substring" {
    try std.testing.expect(containsIgnoreCase("README.md", "readme"));
    try std.testing.expect(containsIgnoreCase("Photo.JPG", "jpg"));
    try std.testing.expect(!containsIgnoreCase("photo.jpg", "png"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}
