const std = @import("std");

/// Asynchronous file operations with freedesktop.org trash support and undo.
///
/// The UI creates a `Job`, starts it, and polls `progress()` from a timer.
/// Strings are owned by the job; a completed job hands back undo items that
/// the caller owns and can feed into `createUndo` later.
///
/// Only one job should run at a time. Each job owns its own worker thread.
pub const Kind = enum {
    copy,
    move,
    trash,
    delete,
    rename,
    mkdir,
    undo,

    pub fn verb(self: Kind) []const u8 {
        return switch (self) {
            .copy => "Copying",
            .move => "Moving",
            .trash => "Moving to Trash",
            .delete => "Deleting",
            .rename => "Renaming",
            .mkdir => "Creating folder",
            .undo => "Undoing",
        };
    }

    pub fn doneVerb(self: Kind) []const u8 {
        return switch (self) {
            .copy => "Copied",
            .move => "Moved",
            .trash => "Moved to Trash",
            .delete => "Deleted",
            .rename => "Renamed",
            .mkdir => "Created folder",
            .undo => "Undid",
        };
    }
};

pub const State = enum(u8) {
    pending,
    running,
    done,
    failed,
    cancelled,
};

/// One reversible action. `move` means "the item at `to` came from `from`",
/// so undoing it moves `to` back to `from`. `remove` means "this path was
/// created by the operation", so undoing it deletes the path.
pub const UndoItem = union(enum) {
    remove: []u8,
    move: Move,

    pub const Move = struct {
        from: []u8,
        to: []u8,
        /// Set for trashed items; removed after a successful restore.
        trash_info: ?[]u8 = null,
    };

    pub fn deinit(self: *UndoItem, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .remove => |path| gpa.free(path),
            .move => |item| {
                gpa.free(item.from);
                gpa.free(item.to);
                if (item.trash_info) |path| gpa.free(path);
            },
        }
        self.* = undefined;
    }

    pub fn clone(self: UndoItem, gpa: std.mem.Allocator) !UndoItem {
        switch (self) {
            .remove => |path| return .{ .remove = try gpa.dupe(u8, path) },
            .move => |item| {
                const from = try gpa.dupe(u8, item.from);
                errdefer gpa.free(from);
                const to = try gpa.dupe(u8, item.to);
                errdefer gpa.free(to);
                const trash_info = if (item.trash_info) |path|
                    try gpa.dupe(u8, path)
                else
                    null;
                return .{ .move = .{
                    .from = from,
                    .to = to,
                    .trash_info = trash_info,
                } };
            },
        }
    }
};

pub const Progress = struct {
    state: State,
    items: usize,
    entries: usize,
    bytes: u64,
    failures: usize,
    error_message: []const u8,
};

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kind: Kind,

    sources: std.ArrayList([]u8) = .empty,
    /// Destination directory for copy/move, full path for rename/mkdir.
    dest: ?[]u8 = null,
    /// Owned input actions for an undo job.
    undo_input: std.ArrayList(UndoItem) = .empty,
    /// Produced by copy/move/trash/rename/mkdir, taken by the UI.
    undo_output: std.ArrayList(UndoItem) = .empty,

    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(State.pending)),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    items_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    entries_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bytes_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failures: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    error_buffer: [1024]u8 = undefined,
    error_len: usize = 0,

    thread: ?std.Thread = null,

    pub fn createCopy(
        gpa: std.mem.Allocator,
        io: std.Io,
        sources: []const []const u8,
        dest_dir: []const u8,
    ) !*Job {
        const self = try initJob(gpa, io, .copy);
        errdefer self.deinit();
        try self.addSources(sources);
        self.dest = try gpa.dupe(u8, dest_dir);
        return self;
    }

    pub fn createMove(
        gpa: std.mem.Allocator,
        io: std.Io,
        sources: []const []const u8,
        dest_dir: []const u8,
    ) !*Job {
        const self = try initJob(gpa, io, .move);
        errdefer self.deinit();
        try self.addSources(sources);
        self.dest = try gpa.dupe(u8, dest_dir);
        return self;
    }

    pub fn createTrash(
        gpa: std.mem.Allocator,
        io: std.Io,
        sources: []const []const u8,
    ) !*Job {
        const self = try initJob(gpa, io, .trash);
        errdefer self.deinit();
        try self.addSources(sources);
        return self;
    }

    pub fn createDelete(
        gpa: std.mem.Allocator,
        io: std.Io,
        sources: []const []const u8,
    ) !*Job {
        const self = try initJob(gpa, io, .delete);
        errdefer self.deinit();
        try self.addSources(sources);
        return self;
    }

    pub fn createRename(
        gpa: std.mem.Allocator,
        io: std.Io,
        source: []const u8,
        new_name: []const u8,
    ) !*Job {
        if (!isValidName(new_name)) return error.InvalidName;
        const parent = std.fs.path.dirname(source) orelse "/";
        const dest = try std.fs.path.join(gpa, &.{ parent, new_name });
        errdefer gpa.free(dest);

        const self = try initJob(gpa, io, .rename);
        errdefer self.deinit();
        try self.addSources(&.{source});
        self.dest = dest;
        return self;
    }

    pub fn createMkdir(
        gpa: std.mem.Allocator,
        io: std.Io,
        parent: []const u8,
        name: []const u8,
    ) !*Job {
        if (!isValidName(name)) return error.InvalidName;
        const dest = try std.fs.path.join(gpa, &.{ parent, name });
        errdefer gpa.free(dest);

        const self = try initJob(gpa, io, .mkdir);
        errdefer self.deinit();
        self.dest = dest;
        return self;
    }

    /// Duplicate undo actions into a job that reverses them in reverse order.
    /// The caller keeps ownership of `items`.
    pub fn createUndo(
        gpa: std.mem.Allocator,
        io: std.Io,
        items: []const UndoItem,
    ) !*Job {
        const self = try initJob(gpa, io, .undo);
        errdefer self.deinit();
        for (items) |item| {
            const copy = try item.clone(gpa);
            errdefer {
                var owned = copy;
                owned.deinit(gpa);
            }
            try self.undo_input.append(gpa, copy);
        }
        return self;
    }

    fn initJob(gpa: std.mem.Allocator, io: std.Io, kind: Kind) !*Job {
        const self = try gpa.create(Job);
        self.* = .{ .gpa = gpa, .io = io, .kind = kind };
        return self;
    }

    fn addSources(self: *Job, sources: []const []const u8) !void {
        for (sources) |source| {
            const copy = try self.gpa.dupe(u8, source);
            errdefer self.gpa.free(copy);
            try self.sources.append(self.gpa, copy);
        }
    }

    pub fn start(self: *Job) !void {
        self.state.store(@backingInt(State.running), .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.setErrorMessage("Could not start the operation");
            self.state.store(@backingInt(State.failed), .release);
            return err;
        };
    }

    pub fn requestCancel(self: *Job) void {
        self.cancel.store(true, .release);
    }

    pub fn join(self: *Job) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Job) void {
        self.requestCancel();
        self.join();

        for (self.sources.items) |source| self.gpa.free(source);
        self.sources.deinit(self.gpa);
        if (self.dest) |dest| self.gpa.free(dest);
        for (self.undo_input.items) |*item| item.deinit(self.gpa);
        self.undo_input.deinit(self.gpa);
        for (self.undo_output.items) |*item| item.deinit(self.gpa);
        self.undo_output.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Transfer the undo actions produced by a completed job to the caller.
    /// Only call after the worker is done and joined.
    pub fn takeUndo(self: *Job) std.ArrayList(UndoItem) {
        const taken = self.undo_output;
        self.undo_output = .empty;
        return taken;
    }

    pub fn progress(self: *Job) Progress {
        return .{
            .state = @fromBackingInt(@intCast(self.state.load(.acquire))),
            .items = self.items_done.load(.acquire),
            .entries = self.entries_done.load(.acquire),
            .bytes = self.bytes_done.load(.acquire),
            .failures = self.failures.load(.acquire),
            .error_message = self.error_buffer[0..self.error_len],
        };
    }

    pub fn errorMessage(self: *Job) []const u8 {
        return self.error_buffer[0..self.error_len];
    }

    fn worker(self: *Job) void {
        self.run() catch |err| {
            if (err == error.Cancelled) {
                self.state.store(@backingInt(State.cancelled), .release);
                return;
            }
            self.setErrorMessage(describeError(err));
            self.state.store(@backingInt(State.failed), .release);
            return;
        };
        self.state.store(@backingInt(State.done), .release);
    }

    fn run(self: *Job) !void {
        switch (self.kind) {
            .copy => try self.runCopy(),
            .move => try self.runMove(),
            .trash => try self.runTrash(),
            .delete => try self.runDelete(),
            .rename => try self.runRename(),
            .mkdir => try self.runMkdir(),
            .undo => try self.runUndo(),
        }
    }

    fn runCopy(self: *Job) !void {
        const dest_dir = self.dest orelse return error.MissingDestination;
        for (self.sources.items) |source| {
            try self.checkCancel();
            self.copyOne(source, dest_dir) catch |err| {
                if (err == error.Cancelled) return err;
                self.recordError(source, err);
            };
        }
    }

    fn copyOne(self: *Job, source: []const u8, dest_dir: []const u8) !void {
        try self.checkCancel();
        const st = try statPath(self.io, source);
        if (st.kind == .directory and isSameOrDescendant(dest_dir, source)) {
            return error.DestinationInsideSource;
        }

        const base = std.fs.path.basename(source);
        const dest = try uniqueNameInDir(
            self.gpa,
            self.io,
            dest_dir,
            base,
            st.kind == .directory,
        );
        defer self.gpa.free(dest);

        self.copyEntry(source, dest) catch |err| {
            cleanupPath(self.io, dest);
            return err;
        };
        try self.addUndo(.{ .remove = try self.gpa.dupe(u8, dest) });
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn runMove(self: *Job) !void {
        const dest_dir = self.dest orelse return error.MissingDestination;
        for (self.sources.items) |source| {
            try self.checkCancel();
            self.moveOne(source, dest_dir) catch |err| {
                if (err == error.Cancelled) return err;
                self.recordError(source, err);
            };
        }
    }

    fn moveOne(self: *Job, source: []const u8, dest_dir: []const u8) !void {
        try self.checkCancel();
        const st = try statPath(self.io, source);
        if (st.kind == .directory and isSameOrDescendant(dest_dir, source)) {
            return error.DestinationInsideSource;
        }

        const parent = std.fs.path.dirname(source) orelse "/";
        if (std.mem.eql(u8, parent, dest_dir)) {
            // Dropping an item back into its own folder is a no-op, not a
            // duplicate copy.
            _ = self.items_done.fetchAdd(1, .monotonic);
            return;
        }

        const base = std.fs.path.basename(source);
        const dest = try uniqueNameInDir(
            self.gpa,
            self.io,
            dest_dir,
            base,
            st.kind == .directory,
        );
        defer self.gpa.free(dest);

        try self.movePath(source, dest);
        try self.addUndo(.{ .move = .{
            .from = try self.gpa.dupe(u8, source),
            .to = try self.gpa.dupe(u8, dest),
        } });
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn runTrash(self: *Job) !void {
        const root = try trashDir(self.gpa);
        defer self.gpa.free(root);
        const files_dir = try std.fs.path.join(self.gpa, &.{ root, "files" });
        defer self.gpa.free(files_dir);
        const info_dir = try std.fs.path.join(self.gpa, &.{ root, "info" });
        defer self.gpa.free(info_dir);

        try std.Io.Dir.cwd().createDirPath(self.io, files_dir);
        try std.Io.Dir.cwd().createDirPath(self.io, info_dir);

        for (self.sources.items) |source| {
            try self.checkCancel();
            self.trashOne(source, files_dir, info_dir) catch |err| {
                if (err == error.Cancelled) return err;
                self.recordError(source, err);
            };
        }
    }

    fn trashOne(
        self: *Job,
        source: []const u8,
        files_dir: []const u8,
        info_dir: []const u8,
    ) !void {
        try self.checkCancel();
        const st = try statPath(self.io, source);
        const is_dir = st.kind == .directory;
        const base = std.fs.path.basename(source);

        // Pick a name free in both files/ and info/.
        var number: usize = 0;
        var trash_path: []u8 = undefined;
        var info_path: []u8 = undefined;
        while (true) : (number += 1) {
            if (number > 10_000) return error.TooManyCollisions;
            const candidate_name = try numberedName(self.gpa, base, number, is_dir);
            defer self.gpa.free(candidate_name);

            const candidate_file = try std.fs.path.join(self.gpa, &.{ files_dir, candidate_name });
            const info_name = try std.fmt.allocPrint(self.gpa, "{s}.trashinfo", .{candidate_name});
            const candidate_info = try std.fs.path.join(self.gpa, &.{ info_dir, info_name });
            self.gpa.free(info_name);

            if (!pathExists(self.io, candidate_file) and !pathExists(self.io, candidate_info)) {
                trash_path = candidate_file;
                info_path = candidate_info;
                break;
            }
            self.gpa.free(candidate_file);
            self.gpa.free(candidate_info);
        }
        defer self.gpa.free(trash_path);
        defer self.gpa.free(info_path);

        try self.writeTrashInfo(info_path, source);
        self.movePath(source, trash_path) catch |err| {
            std.Io.Dir.deleteFileAbsolute(self.io, info_path) catch {};
            cleanupPath(self.io, trash_path);
            return err;
        };

        try self.addUndo(.{ .move = .{
            .from = try self.gpa.dupe(u8, source),
            .to = try self.gpa.dupe(u8, trash_path),
            .trash_info = try self.gpa.dupe(u8, info_path),
        } });
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn writeTrashInfo(self: *Job, info_path: []const u8, original: []const u8) !void {
        const encoded = try percentEncodePath(self.gpa, original);
        defer self.gpa.free(encoded);
        const date = formatDeletionDate(@intCast(@max(
            std.Io.Timestamp.now(self.io, .real).toSeconds(),
            0,
        )));

        const content = try std.fmt.allocPrint(
            self.gpa,
            "[Trash Info]\nPath={s}\nDeletionDate={s}\n",
            .{ encoded, date },
        );
        defer self.gpa.free(content);

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = info_path,
            .data = content,
            .flags = .{ .truncate = true },
        });
    }

    fn runDelete(self: *Job) !void {
        for (self.sources.items) |source| {
            try self.checkCancel();
            deletePath(self.io, source) catch |err| {
                self.recordError(source, err);
                continue;
            };
            _ = self.items_done.fetchAdd(1, .monotonic);
        }
    }

    fn runRename(self: *Job) !void {
        if (self.sources.items.len == 0) return error.MissingSource;
        const source = self.sources.items[0];
        const dest = self.dest orelse return error.MissingDestination;

        if (std.mem.eql(u8, source, dest)) {
            _ = self.items_done.fetchAdd(1, .monotonic);
            return;
        }

        const st = try statPath(self.io, source);
        if (st.kind == .directory and isSameOrDescendant(dest, source)) {
            return error.DestinationInsideSource;
        }

        try self.movePath(source, dest);
        try self.addUndo(.{ .move = .{
            .from = try self.gpa.dupe(u8, source),
            .to = try self.gpa.dupe(u8, dest),
        } });
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn runMkdir(self: *Job) !void {
        const dest = self.dest orelse return error.MissingDestination;
        try std.Io.Dir.createDirAbsolute(self.io, dest, .default_dir);
        try self.addUndo(.{ .remove = try self.gpa.dupe(u8, dest) });
        _ = self.items_done.fetchAdd(1, .monotonic);
    }

    fn runUndo(self: *Job) !void {
        var index = self.undo_input.items.len;
        while (index > 0) {
            index -= 1;
            try self.checkCancel();
            self.undoAction(self.undo_input.items[index]) catch |err| {
                if (err == error.Cancelled) return err;
                self.recordError(undoSubject(self.undo_input.items[index]), err);
                continue;
            };
            _ = self.items_done.fetchAdd(1, .monotonic);
        }
    }

    fn undoAction(self: *Job, item: UndoItem) !void {
        switch (item) {
            .remove => |path| {
                try deletePath(self.io, path);
            },
            .move => |move| {
                const st = try statPath(self.io, move.to);
                var target: []u8 = undefined;
                if (pathExists(self.io, move.from)) {
                    const parent = std.fs.path.dirname(move.from) orelse "/";
                    target = try uniqueNameInDir(
                        self.gpa,
                        self.io,
                        parent,
                        std.fs.path.basename(move.from),
                        st.kind == .directory,
                    );
                } else {
                    target = try self.gpa.dupe(u8, move.from);
                }
                defer self.gpa.free(target);

                try self.movePath(move.to, target);
                if (move.trash_info) |info_path| {
                    std.Io.Dir.deleteFileAbsolute(self.io, info_path) catch {};
                }
            },
        }
    }

    fn movePath(self: *Job, source: []const u8, dest: []const u8) !void {
        std.Io.Dir.renameAbsolute(source, dest, self.io) catch |err| switch (err) {
            error.CrossDevice => {
                self.copyEntry(source, dest) catch |copy_err| {
                    cleanupPath(self.io, dest);
                    return copy_err;
                };
                try deletePath(self.io, source);
            },
            else => return err,
        };
    }

    fn copyEntry(self: *Job, source: []const u8, dest: []const u8) !void {
        try self.checkCancel();
        const st = try statPath(self.io, source);
        switch (st.kind) {
            .directory => {
                try std.Io.Dir.createDirAbsolute(self.io, dest, .default_dir);
                var dir = try std.Io.Dir.openDirAbsolute(self.io, source, .{ .iterate = true });
                defer dir.close(self.io);

                var iterator = dir.iterate();
                while (true) {
                    try self.checkCancel();
                    const maybe_entry = try iterator.next(self.io);
                    const entry = maybe_entry orelse break;

                    const child_source = try std.fs.path.join(
                        self.gpa,
                        &.{ source, entry.name },
                    );
                    defer self.gpa.free(child_source);
                    const child_dest = try std.fs.path.join(
                        self.gpa,
                        &.{ dest, entry.name },
                    );
                    defer self.gpa.free(child_dest);

                    try self.copyEntry(child_source, child_dest);
                }
            },
            .sym_link => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = try std.Io.Dir.readLinkAbsolute(self.io, source, &buffer);
                // The link target itself may be relative; only the new link
                // path has to be absolute.
                try std.Io.Dir.symLink(.cwd(), self.io, buffer[0..len], dest, .{});
            },
            .file => {
                try std.Io.Dir.copyFileAbsolute(source, dest, self.io, .{
                    .replace = false,
                });
                _ = self.bytes_done.fetchAdd(st.size, .monotonic);
            },
            else => return error.UnsupportedFileType,
        }
        _ = self.entries_done.fetchAdd(1, .monotonic);
    }

    fn checkCancel(self: *Job) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
    }

    fn addUndo(self: *Job, item: UndoItem) !void {
        errdefer {
            var owned = item;
            owned.deinit(self.gpa);
        }
        try self.undo_output.append(self.gpa, item);
    }

    fn recordError(self: *Job, subject: []const u8, err: anyerror) void {
        _ = self.failures.fetchAdd(1, .monotonic);
        if (self.error_len != 0) return;
        self.setErrorMessageFormat("{s}: {s}", .{ subject, describeError(err) });
    }

    fn setErrorMessage(self: *Job, message: []const u8) void {
        const len = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..len], message[0..len]);
        self.error_len = len;
    }

    fn setErrorMessageFormat(self: *Job, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.error_buffer, format, args) catch {
            self.setErrorMessage("Operation failed");
            return;
        };
        self.error_len = text.len;
    }
};

// ---- Pure helpers ---------------------------------------------------------

/// Reject empty names, dot entries, path separators, and NUL bytes.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > std.fs.max_name_bytes) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (byte == '/' or byte == 0) return false;
    }
    return true;
}

/// `name` for n == 0, otherwise `base (n).ext` (or `name (n)` for folders).
pub fn numberedName(
    gpa: std.mem.Allocator,
    name: []const u8,
    n: usize,
    is_dir: bool,
) ![]u8 {
    if (n == 0) return gpa.dupe(u8, name);
    if (is_dir) {
        return std.fmt.allocPrint(gpa, "{s} ({d})", .{ name, n });
    }

    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    if (dot) |index| {
        if (index != 0 and index + 1 < name.len) {
            return std.fmt.allocPrint(
                gpa,
                "{s} ({d}){s}",
                .{ name[0..index], n, name[index..] },
            );
        }
    }
    return std.fmt.allocPrint(gpa, "{s} ({d})", .{ name, n });
}

/// True when `child` is `parent` itself or lives underneath it. Paths are
/// compared lexically after dropping trailing separators; callers pass
/// absolute, normalized paths.
pub fn isSameOrDescendant(child: []const u8, parent: []const u8) bool {
    const normalized_child = trimTrailingSeparators(child);
    const normalized_parent = trimTrailingSeparators(parent);
    if (std.mem.eql(u8, normalized_child, normalized_parent)) return true;
    if (std.mem.eql(u8, normalized_parent, "/")) {
        return normalized_child.len > 1 and normalized_child[0] == '/';
    }
    return normalized_child.len > normalized_parent.len and
        std.mem.startsWith(u8, normalized_child, normalized_parent) and
        normalized_child[normalized_parent.len] == '/';
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// URI-encode an absolute path for a `.trashinfo` file. Unreserved characters
/// and `/` stay readable; everything else becomes uppercase `%XX`.
pub fn percentEncodePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);

    for (path) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~' or
            byte == '/';
        if (unreserved) {
            try result.append(gpa, byte);
        } else {
            try result.append(gpa, '%');
            try result.append(gpa, hex[byte >> 4]);
            try result.append(gpa, hex[byte & 0x0f]);
        }
    }
    return result.toOwnedSlice(gpa);
}

/// UTC timestamp in the freedesktop.org `DeletionDate` format.
pub fn formatDeletionDate(seconds: u64) [19]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    var buffer: [19]u8 = undefined;
    _ = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    ) catch unreachable;
    return buffer;
}

/// Find a free name in `dir_path`, adding ` (n)` before the extension.
pub fn uniqueNameInDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
    is_dir: bool,
) ![]u8 {
    const direct = try std.fs.path.join(gpa, &.{ dir_path, name });
    if (!pathExists(io, direct)) return direct;
    gpa.free(direct);

    var number: usize = 1;
    while (number <= 10_000) : (number += 1) {
        const candidate_name = try numberedName(gpa, name, number, is_dir);
        defer gpa.free(candidate_name);
        const candidate = try std.fs.path.join(gpa, &.{ dir_path, candidate_name });
        if (!pathExists(io, candidate)) return candidate;
        gpa.free(candidate);
    }
    return error.TooManyCollisions;
}

pub fn dataHome(gpa: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |raw| {
        const xdg = std.mem.span(raw);
        if (xdg.len > 0 and xdg[0] == '/') return gpa.dupe(u8, xdg);
    }

    const home = std.c.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ std.mem.span(home), ".local", "share" });
}

/// `$XDG_DATA_HOME/Trash`, falling back to `~/.local/share/Trash`.
pub fn trashDir(gpa: std.mem.Allocator) ![]u8 {
    const base = try dataHome(gpa);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "Trash" });
}

// ---- Filesystem helpers ---------------------------------------------------

fn statPath(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = statPath(io, path) catch return false;
    return true;
}

fn deletePath(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.deleteTree(.cwd(), io, path);
}

fn cleanupPath(io: std.Io, path: []const u8) void {
    deletePath(io, path) catch {};
}

pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.FileNotFound => "not found",
        error.PathAlreadyExists => "already exists",
        error.NotDir => "not a folder",
        error.IsDir => "is a folder",
        error.DirNotEmpty => "folder is not empty",
        error.NoSpaceLeft, error.DiskQuota => "no space left",
        error.ReadOnlyFileSystem => "read-only filesystem",
        error.NameTooLong => "name is too long",
        error.SymLinkLoop => "too many symbolic links",
        error.CrossDevice => "cross-device move failed",
        error.DestinationInsideSource => "cannot copy or move a folder into itself",
        error.UnsupportedFileType => "unsupported file type",
        error.InvalidName => "invalid name",
        error.TooManyCollisions => "too many files with that name",
        error.NoHomeDirectory => "cannot determine the home folder",
        error.MissingSource => "missing source",
        error.MissingDestination => "missing destination",
        else => @errorName(err),
    };
}

fn undoSubject(item: UndoItem) []const u8 {
    return switch (item) {
        .remove => |path| path,
        .move => |move| move.to,
    };
}

// ---- Tests ----------------------------------------------------------------

test "name validation" {
    try std.testing.expect(isValidName("report.txt"));
    try std.testing.expect(isValidName(".config"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("."));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a\x00b"));
}

test "numbered names preserve extensions" {
    const gpa = std.testing.allocator;
    const file = try numberedName(gpa, "archive.tar.gz", 2, false);
    defer gpa.free(file);
    try std.testing.expectEqualStrings("archive.tar (2).gz", file);

    const directory = try numberedName(gpa, "Photos", 3, true);
    defer gpa.free(directory);
    try std.testing.expectEqualStrings("Photos (3)", directory);

    const dotfile = try numberedName(gpa, ".bashrc", 1, false);
    defer gpa.free(dotfile);
    try std.testing.expectEqualStrings(".bashrc (1)", dotfile);

    const same = try numberedName(gpa, "README", 0, false);
    defer gpa.free(same);
    try std.testing.expectEqualStrings("README", same);
}

test "descendant checks stop at path boundaries" {
    try std.testing.expect(isSameOrDescendant("/home/user", "/home/user"));
    try std.testing.expect(isSameOrDescendant("/home/user/docs", "/home/user"));
    try std.testing.expect(isSameOrDescendant("/home/user/docs/", "/home/user/"));
    try std.testing.expect(!isSameOrDescendant("/home/username", "/home/user"));
    try std.testing.expect(!isSameOrDescendant("/home", "/home/user"));
    try std.testing.expect(isSameOrDescendant("/etc", "/"));
    try std.testing.expect(isSameOrDescendant("/", "/"));
}

test "trash info paths are percent encoded" {
    const gpa = std.testing.allocator;
    const encoded = try percentEncodePath(gpa, "/home/user/My Files/100% done.txt");
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings(
        "/home/user/My%20Files/100%25%20done.txt",
        encoded,
    );
}

test "trash info deletion date is UTC" {
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00",
        &formatDeletionDate(0),
    );
    try std.testing.expectEqualStrings(
        "2021-06-05T20:28:26",
        &formatDeletionDate(1622924906),
    );
}
