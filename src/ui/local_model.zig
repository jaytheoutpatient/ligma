const std = @import("std");
const qt6 = @import("libqt6zig");

const QAbstractItemModel = qt6.QAbstractItemModel;
const QMimeData = qt6.QMimeData;
const QModelIndex = qt6.QModelIndex;
const QUrl = qt6.QUrl;
const QVariant = qt6.QVariant;

const qnamespace_enums = qt6.qnamespace_enums;

/// A flat, single-folder item model backed by a directory snapshot.
///
/// `QFileSystemModel` owns its own watcher, lazy loading, and sorting policy,
/// none of which can be reused for trash, archives, or remote locations. This
/// model keeps the same details-view shape but owns the snapshot, which makes
/// the VFS migration possible without changing the UI.
///
/// Directory enumeration runs on a worker thread. The UI thread polls `poll()`
/// from a timer; completed snapshots are applied with a model reset. Filtering
/// and sorting happen against the in-memory snapshot, so typing in the filter
/// box never touches the filesystem.
pub const LocalModel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    qt: QAbstractItemModel,

    root_path: ?[]u8 = null,
    entries: std.ArrayList(Entry) = .empty,
    visible: std.ArrayList(usize) = .empty,

    filter: ?[]u8 = null,
    show_hidden: bool = false,
    sort_column: i32 = 0,
    sort_order: i32 = qnamespace_enums.SortOrder.AscendingOrder,

    job: ?*LoadJob = null,
    retired: std.ArrayList(*LoadJob) = .empty,
    generation: u64 = 0,

    drop_handler: ?DropHandler = null,
    drag_copy_hint: bool = false,

    error_buffer: [512]u8 = undefined,
    error_len: usize = 0,

    pub const DropHandler = *const fn (
        self: *LocalModel,
        sources: []const []const u8,
        dest_dir: []const u8,
        move: bool,
    ) bool;

    pub const Poll = enum { none, updated, failed };

    pub const Entry = struct {
        name: []u8,
        path: []u8,
        is_dir: bool,
        is_symlink: bool,
        size: u64,
        mtime: i64,

        fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.path);
            self.* = undefined;
        }
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, parent: anytype) !*LocalModel {
        const qt_model = QAbstractItemModel.new2(parent);
        errdefer qt_model.delete();

        const self = try gpa.create(LocalModel);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .qt = qt_model };

        try registry.put(registry_allocator, @intFromPtr(qt_model.ptr.?), self);
        errdefer _ = registry.remove(@intFromPtr(qt_model.ptr.?));

        qt_model.onIndex(onIndex);
        qt_model.onParent(onParent);
        qt_model.onRowCount(onRowCount);
        qt_model.onColumnCount(onColumnCount);
        qt_model.onHasChildren(onHasChildren);
        qt_model.onData(onData);
        qt_model.onHeaderData(onHeaderData);
        qt_model.onFlags(onFlags);
        qt_model.onSort(onSort);
        qt_model.onMimeTypes(onMimeTypes);
        qt_model.onMimeData(onMimeData);
        qt_model.onCanDropMimeData(onCanDropMimeData);
        qt_model.onDropMimeData(onDropMimeData);
        qt_model.onSupportedDropActions(onSupportedDropActions);
        qt_model.onSupportedDragActions(onSupportedDragActions);

        return self;
    }

    pub fn setDropHandler(self: *LocalModel, handler: DropHandler) void {
        self.drop_handler = handler;
    }

    /// Record whether Ctrl was held when the drag gesture started. Modifier
    /// state is not reliably delivered to the drag loop on every platform, so
    /// the source model carries the intent in the MIME payload instead.
    pub fn setDragCopyHint(self: *LocalModel, copy: bool) void {
        self.drag_copy_hint = copy;
    }

    /// Unregister before the parent widget deletes the C++ object.
    pub fn destroy(self: *LocalModel) void {
        _ = registry.remove(@intFromPtr(self.qt.ptr.?));

        if (self.job) |job| {
            job.requestCancel();
            job.deinit();
            self.job = null;
        }
        for (self.retired.items) |job| {
            job.requestCancel();
            job.deinit();
        }
        self.retired.deinit(self.gpa);

        self.clearEntries();
        self.visible.deinit(self.gpa);
        self.freeRoot();
        self.freeFilter();
        self.gpa.destroy(self);
    }

    pub fn isLoading(self: *LocalModel) bool {
        return self.job != null;
    }

    pub fn count(self: *LocalModel) usize {
        return self.visible.items.len;
    }

    pub fn lastError(self: *LocalModel) []const u8 {
        return self.error_buffer[0..self.error_len];
    }

    pub fn currentPath(self: *LocalModel) ?[]const u8 {
        return self.root_path;
    }

    /// Start loading `path`, cancelling any previous snapshot request.
    pub fn load(self: *LocalModel, path: []const u8) void {
        const new_root = self.gpa.dupe(u8, path) catch {
            self.setError("Out of memory");
            return;
        };

        self.cancelActive();
        self.freeRoot();
        self.root_path = new_root;
        self.clearError();
        self.generation +%= 1;

        self.clearEntries();
        self.resetModel();

        const job = LoadJob.create(self, self.generation, new_root) catch |err| {
            self.setError(@errorName(err));
            return;
        };
        job.start() catch |err| {
            self.setError(@errorName(err));
            job.deinit();
            return;
        };
        self.job = job;
    }

    pub fn reload(self: *LocalModel) void {
        const path = self.root_path orelse return;
        self.load(path);
    }

    pub fn setFilter(self: *LocalModel, text: []const u8) void {
        const same = if (self.filter) |old|
            std.mem.eql(u8, old, text)
        else
            text.len == 0;
        if (same) return;

        self.freeFilter();
        if (text.len > 0) {
            self.filter = self.gpa.dupe(u8, text) catch null;
        }
        self.rebuildVisible();
        self.resetModel();
    }

    pub fn filterText(self: *LocalModel) []const u8 {
        return self.filter orelse "";
    }

    pub fn setShowHidden(self: *LocalModel, show: bool) void {
        if (self.show_hidden == show) return;
        self.show_hidden = show;
        self.rebuildVisible();
        self.resetModel();
    }

    /// Apply a completed background snapshot. Returns `updated` or `failed`
    /// once so the UI can refresh its item count and status line.
    pub fn poll(self: *LocalModel) Poll {
        var result: Poll = .none;

        if (self.job) |job| {
            if (job.done.load(.acquire)) {
                job.join();
                const generation = job.generation;
                const failed = job.failed;
                if (generation == self.generation) {
                    if (failed) {
                        self.setError(job.errorMessage());
                        result = .failed;
                    } else {
                        self.clearEntries();
                        self.entries = job.takeEntries();
                        self.rebuildVisible();
                        self.resetModel();
                        result = .updated;
                    }
                } else {
                    // A newer load superseded this one.
                    job.dropEntries();
                }
                job.deinit();
                self.job = null;
            }
        }

        var index: usize = 0;
        while (index < self.retired.items.len) {
            const job = self.retired.items[index];
            if (job.done.load(.acquire)) {
                job.join();
                job.deinit();
                _ = self.retired.orderedRemove(index);
            } else {
                index += 1;
            }
        }

        return result;
    }

    pub fn pathAt(self: *LocalModel, allocator: std.mem.Allocator, index: QModelIndex) []u8 {
        const entry = self.entryAt(index) orelse return allocator.dupe(u8, "") catch @panic("OOM");
        return allocator.dupe(u8, entry.path) catch @panic("OOM");
    }

    pub fn nameAt(self: *LocalModel, allocator: std.mem.Allocator, index: QModelIndex) []u8 {
        const entry = self.entryAt(index) orelse return allocator.dupe(u8, "") catch @panic("OOM");
        return allocator.dupe(u8, entry.name) catch @panic("OOM");
    }

    pub fn isDir(self: *LocalModel, index: QModelIndex) bool {
        const entry = self.entryAt(index) orelse return false;
        return entry.is_dir;
    }

    pub fn sizeAt(self: *LocalModel, index: QModelIndex) u64 {
        const entry = self.entryAt(index) orelse return 0;
        return entry.size;
    }

    pub fn mtimeAt(self: *LocalModel, index: QModelIndex) i64 {
        const entry = self.entryAt(index) orelse return 0;
        return entry.mtime;
    }

    pub fn entryAt(self: *LocalModel, index: QModelIndex) ?*Entry {
        if (!index.isValid()) return null;
        const row = index.row();
        if (row < 0) return null;
        const position: usize = @intCast(row);
        if (position >= self.visible.items.len) return null;
        return &self.entries.items[self.visible.items[position]];
    }

    fn cancelActive(self: *LocalModel) void {
        const job = self.job orelse return;
        self.job = null;
        job.requestCancel();
        self.retired.append(self.gpa, job) catch {
            job.deinit();
        };
    }

    fn clearEntries(self: *LocalModel) void {
        for (self.entries.items) |*entry| entry.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.entries = .empty;
        self.visible.clearRetainingCapacity();
    }

    fn freeRoot(self: *LocalModel) void {
        if (self.root_path) |path| self.gpa.free(path);
        self.root_path = null;
    }

    fn freeFilter(self: *LocalModel) void {
        if (self.filter) |text| self.gpa.free(text);
        self.filter = null;
    }

    fn rebuildVisible(self: *LocalModel) void {
        self.visible.clearRetainingCapacity();
        const filter = self.filter orelse "";

        for (self.entries.items, 0..) |entry, index| {
            if (!self.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (filter.len > 0 and !entry.is_dir and !containsIgnoreCase(entry.name, filter)) continue;
            self.visible.append(self.gpa, index) catch return;
        }

        std.mem.sortUnstable(usize, self.visible.items, self, lessThanEntry);
    }

    fn lessThanEntry(self: *LocalModel, left: usize, right: usize) bool {
        const a = &self.entries.items[left];
        const b = &self.entries.items[right];

        // Folders stay above files in both sort directions, which is what
        // users expect from a file manager even when sorting by size or date.
        if (a.is_dir != b.is_dir) return a.is_dir;

        const order = switch (self.sort_column) {
            0 => std.ascii.orderIgnoreCase(a.name, b.name),
            1 => std.math.order(a.size, b.size),
            2 => std.math.order(kindRank(a), kindRank(b)),
            3 => std.math.order(a.mtime, b.mtime),
            else => std.ascii.orderIgnoreCase(a.name, b.name),
        };

        const ascending = self.sort_order != qnamespace_enums.SortOrder.DescendingOrder;
        return switch (order) {
            .lt => ascending,
            .gt => !ascending,
            .eq => std.mem.lessThan(u8, a.name, b.name),
        };
    }

    fn kindRank(entry: *const Entry) u8 {
        if (entry.is_symlink) return 3;
        if (entry.is_dir) return 0;
        return 1;
    }

    fn resetModel(self: *LocalModel) void {
        self.qt.beginResetModel();
        self.qt.endResetModel();
    }

    fn setError(self: *LocalModel, message: []const u8) void {
        const len = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..len], message[0..len]);
        self.error_len = len;
    }

    fn clearError(self: *LocalModel) void {
        self.error_len = 0;
    }
};

// ---- Background directory listing -----------------------------------------

const LoadJob = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    model: *LocalModel,
    generation: u64,
    path: []u8,
    entries: std.ArrayList(LocalModel.Entry) = .empty,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: bool = false,
    error_buffer: [512]u8 = undefined,
    error_len: usize = 0,
    thread: ?std.Thread = null,

    fn create(
        model: *LocalModel,
        generation: u64,
        path: []const u8,
    ) !*LoadJob {
        const self = try model.gpa.create(LoadJob);
        errdefer model.gpa.destroy(self);

        const copy = try model.gpa.dupe(u8, path);
        self.* = .{
            .gpa = model.gpa,
            .io = model.io,
            .model = model,
            .generation = generation,
            .path = copy,
        };
        return self;
    }

    fn start(self: *LoadJob) !void {
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn requestCancel(self: *LoadJob) void {
        self.cancel.store(true, .release);
    }

    fn join(self: *LoadJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn errorMessage(self: *LoadJob) []const u8 {
        if (self.error_len == 0) return "could not read the folder";
        return self.error_buffer[0..self.error_len];
    }

    fn setError(self: *LoadJob, err: anyerror) void {
        const text = if (err == error.AccessDenied)
            "permission denied"
        else if (err == error.FileNotFound)
            "folder not found"
        else if (err == error.NotDir)
            "not a folder"
        else
            @errorName(err);
        const len = @min(text.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..len], text[0..len]);
        self.error_len = len;
        self.failed = true;
    }

    fn takeEntries(self: *LoadJob) std.ArrayList(LocalModel.Entry) {
        const entries = self.entries;
        self.entries = .empty;
        return entries;
    }

    fn dropEntries(self: *LoadJob) void {
        for (self.entries.items) |*entry| entry.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.entries = .empty;
    }

    fn deinit(self: *LoadJob) void {
        self.requestCancel();
        self.join();
        self.dropEntries();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    fn worker(self: *LoadJob) void {
        self.scan() catch |err| {
            if (err != error.Cancelled) self.setError(err);
        };
        self.done.store(true, .release);
    }

    fn scan(self: *LoadJob) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.path, .{ .iterate = true });
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (true) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            const maybe_entry = try iterator.next(self.io);
            const item = maybe_entry orelse break;

            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;

            const name = try self.gpa.dupe(u8, item.name);
            errdefer self.gpa.free(name);
            const path = try std.fs.path.join(self.gpa, &.{ self.path, name });
            errdefer self.gpa.free(path);

            var size: u64 = 0;
            var mtime: i64 = 0;
            var is_dir = item.kind == .directory;

            // Following symlinks gives the view the target's kind and size,
            // which matches the navigation behavior: activating a link to a
            // folder enters the folder.
            if (dir.statFile(self.io, name, .{ .follow_symlinks = true })) |stat| {
                size = stat.size;
                mtime = stat.mtime.toSeconds();
                is_dir = stat.kind == .directory;
            } else |_| {
                // Broken links and races still deserve a row rather than a
                // silently truncated folder listing.
            }

            try self.entries.append(self.gpa, .{
                .name = name,
                .path = path,
                .is_dir = is_dir,
                .is_symlink = item.kind == .sym_link,
                .size = size,
                .mtime = mtime,
            });
        }
    }
};

// ---- Qt virtual callbacks -------------------------------------------------

var registry: std.AutoHashMapUnmanaged(usize, *LocalModel) = .empty;
const registry_allocator = std.heap.page_allocator;

fn findModel(model: QAbstractItemModel) ?*LocalModel {
    const ptr = model.ptr orelse return null;
    return registry.get(@intFromPtr(ptr));
}

fn emptyIndex() QModelIndex {
    return QModelIndex.new3();
}

fn emptyVariant() QVariant {
    return QVariant.new();
}

fn stringVariant(text: []const u8) QVariant {
    return QVariant.new24(text);
}

fn onIndex(
    model: QAbstractItemModel,
    row: i32,
    column: i32,
    parent: QModelIndex,
) callconv(.c) QModelIndex {
    if (parent.isValid()) return emptyIndex();
    const self = findModel(model) orelse return emptyIndex();

    if (row < 0 or column < 0 or column >= column_count) return emptyIndex();
    const position: usize = @intCast(row);
    if (position >= self.visible.items.len) return emptyIndex();

    return model.createIndex(row, column);
}

fn onParent(_: QAbstractItemModel, _: QModelIndex) callconv(.c) QModelIndex {
    return emptyIndex();
}

fn onRowCount(model: QAbstractItemModel, parent: QModelIndex) callconv(.c) i32 {
    if (parent.isValid()) return 0;
    const self = findModel(model) orelse return 0;
    return @intCast(@min(self.visible.items.len, @as(usize, std.math.maxInt(i32))));
}

fn onColumnCount(model: QAbstractItemModel, parent: QModelIndex) callconv(.c) i32 {
    if (parent.isValid()) return 0;
    if (findModel(model) == null) return 0;
    return column_count;
}

fn onHasChildren(model: QAbstractItemModel, parent: QModelIndex) callconv(.c) bool {
    if (parent.isValid()) return false;
    const self = findModel(model) orelse return false;
    return self.visible.items.len > 0;
}

fn onData(
    model: QAbstractItemModel,
    index: QModelIndex,
    role: i32,
) callconv(.c) QVariant {
    const self = findModel(model) orelse return emptyVariant();
    const entry = self.entryAt(index) orelse return emptyVariant();

    if (role == qnamespace_enums.ItemDataRole.DisplayRole) {
        return switch (index.column()) {
            0 => stringVariant(entry.name),
            1 => if (entry.is_dir) emptyVariant() else stringVariant(formatSize(entry.size)),
            2 => stringVariant(kindLabel(entry)),
            3 => stringVariant(formatModified(entry.mtime)),
            else => emptyVariant(),
        };
    }

    if (role == qnamespace_enums.ItemDataRole.ToolTipRole) {
        return stringVariant(entry.path);
    }

    if (role == qnamespace_enums.ItemDataRole.TextAlignmentRole and index.column() == 1) {
        return QVariant.new4(text_align_right | text_align_vcenter);
    }

    return emptyVariant();
}

fn onHeaderData(
    model: QAbstractItemModel,
    section: i32,
    orientation: i32,
    role: i32,
) callconv(.c) QVariant {
    if (findModel(model) == null) return emptyVariant();
    if (orientation != qnamespace_enums.Orientation.Horizontal) return emptyVariant();
    if (role != qnamespace_enums.ItemDataRole.DisplayRole) return emptyVariant();

    return switch (section) {
        0 => stringVariant("Name"),
        1 => stringVariant("Size"),
        2 => stringVariant("Kind"),
        3 => stringVariant("Modified"),
        else => emptyVariant(),
    };
}

fn onFlags(model: QAbstractItemModel, index: QModelIndex) callconv(.c) i32 {
    const self = findModel(model) orelse return 0;
    if (!index.isValid()) return qnamespace_enums.ItemFlag.ItemIsDropEnabled;

    var flags = qnamespace_enums.ItemFlag.ItemIsEnabled |
        qnamespace_enums.ItemFlag.ItemIsSelectable |
        qnamespace_enums.ItemFlag.ItemIsDragEnabled;
    if (self.entryAt(index)) |entry| {
        if (entry.is_dir) flags |= qnamespace_enums.ItemFlag.ItemIsDropEnabled;
    }
    return flags;
}

fn onSort(
    model: QAbstractItemModel,
    column: i32,
    order: i32,
) callconv(.c) void {
    const self = findModel(model) orelse return;
    if (column < 0 or column >= column_count) return;
    self.sort_column = column;
    self.sort_order = order;
    self.rebuildVisible();
    self.resetModel();
}

// ---- Drag and drop --------------------------------------------------------

/// Marker attached to drags that started in this app. External drags do not
/// carry it, so they always copy even if the file manager's default drop
/// action is move.
const internal_mime = "application/x-ligma-paths";
const copy_mime = "application/x-ligma-copy";

fn onMimeTypes(_: QAbstractItemModel) callconv(.c) ?[*:null]?[*:0]const u8 {
    // Qt takes ownership of the returned array and calls free() on it. The
    // strings themselves are copied before that, so they can stay static.
    const types = std.heap.c_allocator.alloc(?[*:0]const u8, 2) catch return null;
    types[0] = "text/uri-list";
    types[1] = null;
    return @ptrCast(types.ptr);
}

fn onMimeData(model: QAbstractItemModel, indexes: qt6.C.libqt_list) callconv(.c) QMimeData {
    const mime = QMimeData.new();
    const self = findModel(model) orelse return mime;
    if (indexes.len == 0 or indexes.data == null) return mime;

    var urls: std.ArrayList(QUrl) = .empty;
    defer {
        for (urls.items) |url| url.delete();
        urls.deinit(self.gpa);
    }

    const rows: [*]*QModelIndex = @ptrCast(@alignCast(indexes.data));
    for (0..indexes.len) |i| {
        // The callback list stores pointers to C++ QModelIndex values, not
        // pointers to the Zig wrapper struct. Rebuild the wrapper around the
        // C++ address instead of dereferencing it as a wrapper.
        const index = QModelIndex{ .ptr = @ptrCast(rows[i]) };
        // QTreeView reports every selected column; one URL per row is enough.
        if (index.column() != 0) continue;
        const entry = self.entryAt(index) orelse continue;
        const url = QUrl.fromLocalFile(entry.path);
        urls.append(self.gpa, url) catch {
            url.delete();
            continue;
        };
    }

    if (urls.items.len > 0) {
        mime.setUrls(urls.items);
        mime.setData(internal_mime, "1");
        if (self.drag_copy_hint) mime.setData(copy_mime, "1");
    }
    return mime;
}

fn onSupportedDropActions(_: QAbstractItemModel) callconv(.c) i32 {
    return qnamespace_enums.DropAction.CopyAction |
        qnamespace_enums.DropAction.MoveAction;
}

fn onSupportedDragActions(_: QAbstractItemModel) callconv(.c) i32 {
    return qnamespace_enums.DropAction.CopyAction |
        qnamespace_enums.DropAction.MoveAction;
}

fn onCanDropMimeData(
    model: QAbstractItemModel,
    data: QMimeData,
    action: i32,
    _: i32,
    _: i32,
    parent: QModelIndex,
) callconv(.c) bool {
    const self = findModel(model) orelse return false;
    if (action != qnamespace_enums.DropAction.CopyAction and
        action != qnamespace_enums.DropAction.MoveAction) return false;
    const dest = dropDestination(self, parent) orelse return false;

    var sources: std.ArrayList([]const u8) = .empty;
    defer freeSourceList(self.gpa, &sources);
    if (!collectDropSources(self, data, dest, &sources)) return false;
    return true;
}

fn onDropMimeData(
    model: QAbstractItemModel,
    data: QMimeData,
    action: i32,
    _: i32,
    _: i32,
    parent: QModelIndex,
) callconv(.c) bool {
    const self = findModel(model) orelse return false;
    if (action != qnamespace_enums.DropAction.CopyAction and
        action != qnamespace_enums.DropAction.MoveAction) return false;
    const dest = dropDestination(self, parent) orelse return false;

    var sources: std.ArrayList([]const u8) = .empty;
    defer freeSourceList(self.gpa, &sources);
    if (!collectDropSources(self, data, dest, &sources)) return false;

    // Internal drags move by default; Ctrl at gesture start (or a Copy action
    // chosen by Qt) copies. Anything from another application is copied.
    const internal = data.hasFormat(internal_mime);
    const copy_requested = data.hasFormat(copy_mime) or
        action == qnamespace_enums.DropAction.CopyAction;
    const move = internal and !copy_requested;

    const handler = self.drop_handler orelse return false;
    return handler(self, sources.items, dest, move);
}

fn freeSourceList(gpa: std.mem.Allocator, sources: *std.ArrayList([]const u8)) void {
    for (sources.items) |path| gpa.free(path);
    sources.deinit(gpa);
}

/// Resolve the folder that receives a drop. Qt passes the folder row as the
/// parent when dropping onto it, and an invalid index over empty space.
fn dropDestination(self: *LocalModel, parent: QModelIndex) ?[]const u8 {
    if (parent.isValid()) {
        if (self.entryAt(parent)) |entry| {
            if (entry.is_dir) return entry.path;
        }
    }
    return self.root_path;
}

fn collectDropSources(
    self: *LocalModel,
    data: QMimeData,
    dest: []const u8,
    out: *std.ArrayList([]const u8),
) bool {
    if (!data.hasUrls()) return false;

    const urls = data.urls(self.gpa);
    defer {
        for (urls) |url| url.delete();
        self.gpa.free(urls);
    }

    for (urls) |url| {
        if (!url.isLocalFile()) continue;
        const path = url.toLocalFile(self.gpa);
        if (path.len == 0) {
            self.gpa.free(path);
            continue;
        }

        // A drop back into the item's own folder is a no-op, not a duplicate
        // copy. Folders may also not be dropped inside themselves.
        const parent = std.fs.path.dirname(path) orelse "/";
        if (std.mem.eql(u8, parent, dest) or isInside(self, path, dest)) {
            self.gpa.free(path);
            continue;
        }

        var duplicate = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            self.gpa.free(path);
            continue;
        }

        out.append(self.gpa, path) catch {
            self.gpa.free(path);
            return false;
        };
    }
    return out.items.len > 0;
}

fn isInside(self: *LocalModel, path: []const u8, dest: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return false;
    if (stat.kind != .directory) return false;
    if (std.mem.eql(u8, path, dest)) return true;

    if (path.len == 1 and path[0] == '/') return true; // The root contains everything.
    if (dest.len <= path.len) return false;
    if (!std.mem.startsWith(u8, dest, path)) return false;
    return dest[path.len] == '/';
}

// ---- Formatting helpers ---------------------------------------------------

pub const column_count: i32 = 4;

const text_align_right: i32 = 0x0002;
const text_align_vcenter: i32 = 0x0080;

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

pub fn formatSize(bytes: u64) []const u8 {
    const buffer = &size_buffer;
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) {
        value /= 1024.0;
    }
    if (unit == 0) {
        return std.fmt.bufPrint(buffer, "{d} {s}", .{ bytes, units[0] }) catch "0 B";
    }
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "0 B";
}

var size_buffer: [32]u8 = undefined;

pub fn formatModified(seconds: i64) []const u8 {
    if (seconds <= 0) return "—";
    const secs: u64 = @intCast(seconds);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.bufPrint(
        &modified_buffer,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
        },
    ) catch "—";
}

var modified_buffer: [32]u8 = undefined;

fn kindLabel(entry: *const LocalModel.Entry) []const u8 {
    if (entry.is_symlink) {
        return if (entry.is_dir) "Folder link" else "Link";
    }
    if (entry.is_dir) return "Folder";
    return "File";
}

// ---- Tests ----------------------------------------------------------------

test "visible rows sort folders first and filter in memory" {
    const gpa = std.testing.allocator;

    var entries: std.ArrayList(LocalModel.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }

    const fixture = struct {
        fn add(
            list: *std.ArrayList(LocalModel.Entry),
            allocator: std.mem.Allocator,
            name: []const u8,
            is_dir: bool,
            size: u64,
            mtime: i64,
        ) !void {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .path = try allocator.dupe(u8, name),
                .is_dir = is_dir,
                .is_symlink = false,
                .size = size,
                .mtime = mtime,
            });
        }
    };

    try fixture.add(&entries, gpa, "zeta.txt", false, 300, 30);
    try fixture.add(&entries, gpa, "alpha.txt", false, 100, 10);
    try fixture.add(&entries, gpa, "beta", true, 0, 20);
    try fixture.add(&entries, gpa, ".hidden", false, 5, 5);

    var model = LocalModel{
        .gpa = gpa,
        .io = undefined,
        .qt = undefined,
        .entries = entries,
    };
    defer model.visible.deinit(gpa);

    model.rebuildVisible();
    try std.testing.expectEqual(@as(usize, 3), model.visible.items.len);
    try std.testing.expectEqualStrings("beta", model.entries.items[model.visible.items[0]].name);
    try std.testing.expectEqualStrings("alpha.txt", model.entries.items[model.visible.items[1]].name);
    try std.testing.expectEqualStrings("zeta.txt", model.entries.items[model.visible.items[2]].name);

    model.show_hidden = true;
    model.rebuildVisible();
    try std.testing.expectEqual(@as(usize, 4), model.visible.items.len);

    model.show_hidden = false;
    model.sort_column = 1;
    model.rebuildVisible();
    try std.testing.expectEqualStrings("alpha.txt", model.entries.items[model.visible.items[1]].name);
    try std.testing.expectEqualStrings("zeta.txt", model.entries.items[model.visible.items[2]].name);

    model.sort_order = qnamespace_enums.SortOrder.DescendingOrder;
    model.rebuildVisible();
    try std.testing.expectEqualStrings("zeta.txt", model.entries.items[model.visible.items[1]].name);
    try std.testing.expectEqualStrings("alpha.txt", model.entries.items[model.visible.items[2]].name);

    model.sort_column = 0;
    model.sort_order = qnamespace_enums.SortOrder.AscendingOrder;
    model.filter = try gpa.dupe(u8, "eta");
    defer gpa.free(model.filter.?);
    model.rebuildVisible();
    try std.testing.expectEqual(@as(usize, 2), model.visible.items.len);
    try std.testing.expectEqualStrings("beta", model.entries.items[model.visible.items[0]].name);
    try std.testing.expectEqualStrings("zeta.txt", model.entries.items[model.visible.items[1]].name);
}

test "case-insensitive substring matching" {
    try std.testing.expect(containsIgnoreCase("Report Final.PDF", "final"));
    try std.testing.expect(containsIgnoreCase("Report Final.PDF", "REPORT"));
    try std.testing.expect(!containsIgnoreCase("Report Final.PDF", "draft"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "size formatting uses binary units" {
    try std.testing.expectEqualStrings("512 B", formatSize(512));
    try std.testing.expectEqualStrings("0 B", formatSize(0));
    try std.testing.expectEqualStrings("1.0 KB", formatSize(1024));
    try std.testing.expectEqualStrings("42.9 KB", formatSize(43972));
    try std.testing.expectEqualStrings("1.5 MB", formatSize(1024 * 1024 + 512 * 1024));
    try std.testing.expectEqualStrings("3.0 MB", formatSize(3 * 1024 * 1024));
    try std.testing.expectEqualStrings("2.0 GB", formatSize(2 * 1024 * 1024 * 1024));
}

test "modified dates render in UTC" {
    try std.testing.expectEqualStrings("1970-01-01 00:00", formatModified(0 + 1));
    try std.testing.expectEqualStrings("2021-06-05 20:28", formatModified(1622924906));
    try std.testing.expectEqualStrings("—", formatModified(-1));
}
