const std = @import("std");
const qt6 = @import("libqt6zig");

const file_ops = @import("../core/file_ops.zig");
const text_sort = @import("../core/text_sort.zig");

const QAbstractItemModel = qt6.QAbstractItemModel;
const QFileIconProvider = qt6.QFileIconProvider;
const QFileInfo = qt6.QFileInfo;
const QIcon = qt6.QIcon;
const QImageReader = qt6.QImageReader;
const QMimeData = qt6.QMimeData;
const QMimeDatabase = qt6.QMimeDatabase;
const QModelIndex = qt6.QModelIndex;
const QPixmap = qt6.QPixmap;
const QSize = qt6.QSize;
const QUrl = qt6.QUrl;
const QVariant = qt6.QVariant;

extern fn ligma_qvariant_from_icon(icon: ?*anyopaque) ?*anyopaque;

const qnamespace_enums = qt6.qnamespace_enums;

pub const Location = enum { directory, trash };

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
    icon_provider: QFileIconProvider = undefined,
    mime_db: QMimeDatabase = .{ .ptr = null },

    root_path: ?[]u8 = null,
    location: Location = .directory,
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
        /// Real path on disk. In Trash this is the file inside `Trash/files`.
        path: []u8,
        is_dir: bool,
        is_symlink: bool,
        size: u64,
        mtime: i64,
        /// Set only for Trash entries.
        original_path: ?[]u8 = null,
        info_path: ?[]u8 = null,
        deletion_text: [19]u8 = std.mem.zeroes([19]u8),
        deletion_len: usize = 0,
        icon: ?QIcon = null,
        icon_loaded: bool = false,

        fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
            gpa.free(self.name);
            gpa.free(self.path);
            if (self.original_path) |path| gpa.free(path);
            if (self.info_path) |path| gpa.free(path);
            if (self.icon) |icon| icon.delete();
            self.* = undefined;
        }

        pub fn deletedLabel(self: *const Entry, buffer: []u8) []const u8 {
            if (self.deletion_len == 0) return "—";
            const text = self.deletion_text[0..self.deletion_len];
            const length = @min(text.len, buffer.len);
            @memcpy(buffer[0..length], text[0..length]);
            if (length > 10 and buffer[10] == 'T') buffer[10] = ' ';
            if (length > 16) return buffer[0..16];
            return buffer[0..length];
        }
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, parent: anytype) !*LocalModel {
        const qt_model = QAbstractItemModel.new2(parent);
        errdefer qt_model.delete();

        const self = try gpa.create(LocalModel);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .qt = qt_model,
            .icon_provider = QFileIconProvider.new(),
        };
        errdefer self.icon_provider.delete();
        self.mime_db = QMimeDatabase.new();
        errdefer self.mime_db.delete();

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
        self.icon_provider.delete();

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
        if (self.mime_db.ptr != null) self.mime_db.delete();
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

    pub fn isTrash(self: *const LocalModel) bool {
        return self.location == .trash;
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
        self.location = if (file_ops.isTrashLocation(new_root)) .trash else .directory;
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

    /// Find the model index for a path after a snapshot refresh. Used to
    /// restore selection when a directory changes underneath the view.
    pub fn indexForPath(self: *LocalModel, path: []const u8) ?QModelIndex {
        for (self.visible.items, 0..) |entry_index, row| {
            if (std.mem.eql(u8, self.entries.items[entry_index].path, path)) {
                return self.qt.createIndex(@intCast(row), 0);
            }
        }
        return null;
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

    fn iconFor(self: *LocalModel, entry: *Entry) QIcon {
        if (entry.icon_loaded) {
            return entry.icon orelse QIcon{ .ptr = null };
        }

        const icon = self.resolveIcon(entry) orelse self.fallbackIcon(entry);
        entry.icon = icon;
        entry.icon_loaded = true;
        return icon;
    }

    fn resolveIcon(self: *LocalModel, entry: *Entry) ?QIcon {
        // QFileIconProvider adds the link badge for symlinks; themed MIME icons
        // do not, so let the provider handle those rows.
        if (entry.is_symlink) return null;

        if (entry.is_dir) {
            const folder = self.themedIcon("folder") orelse return null;
            if (specialFolderIcon(entry.path)) |name| {
                if (self.themedIcon(name)) |icon| {
                    folder.delete();
                    return icon;
                }
            }
            return folder;
        }

        if (std.mem.endsWith(u8, entry.name, ".desktop")) {
            if (self.desktopIconName(entry.path)) |name| {
                defer self.gpa.free(name);
                if (self.iconFromName(name)) |icon| return icon;
            }
        }

        const mime = self.mime_db.mimeTypeForFile(entry.path);
        defer mime.delete();
        const mime_name = mime.name(self.gpa);
        defer self.gpa.free(mime_name);

        if (std.mem.startsWith(u8, mime_name, "image/")) {
            if (self.imageIcon(entry)) |icon| return icon;
        }

        const icon_name = mime.iconName(self.gpa);
        defer self.gpa.free(icon_name);
        if (self.iconFromName(icon_name)) |icon| return icon;
        if (self.themedIcon(genericMimeIcon(mime_name))) |icon| return icon;
        return null;
    }

    fn fallbackIcon(self: *LocalModel, entry: *Entry) QIcon {
        const info = QFileInfo.new2(entry.path);
        defer info.delete();
        return self.icon_provider.icon2(info);
    }

    fn themedIcon(self: *LocalModel, name: []const u8) ?QIcon {
        _ = self;
        if (name.len == 0) return null;
        const icon = QIcon.fromTheme(name);
        if (icon.isNull()) {
            icon.delete();
            return null;
        }
        return icon;
    }

    fn iconFromName(self: *LocalModel, name: []const u8) ?QIcon {
        if (name.len == 0) return null;
        if (name[0] == '/') {
            const icon = QIcon.new4(name);
            if (icon.isNull()) {
                icon.delete();
                return null;
            }
            return icon;
        }
        return self.themedIcon(name);
    }

    fn imageIcon(self: *LocalModel, entry: *Entry) ?QIcon {
        _ = self;
        if (entry.size > 64 * 1024 * 1024) return null;

        const reader = QImageReader.new3(entry.path);
        defer reader.delete();
        reader.setAutoTransform(true);

        const size = reader.size();
        defer size.delete();
        const width = size.width();
        const height = size.height();
        if (width <= 0 or height <= 0) return null;

        const fit = fitWithin(width, height, 128, 128);
        const scaled = QSize.new4(fit[0], fit[1]);
        defer scaled.delete();
        reader.setScaledSize(scaled);

        const image = reader.read();
        defer image.delete();
        if (image.isNull()) return null;

        const pixmap = QPixmap.fromImage(image);
        defer pixmap.delete();
        if (pixmap.isNull()) return null;

        const icon = QIcon.new2(pixmap);
        if (icon.isNull()) {
            icon.delete();
            return null;
        }
        return icon;
    }

    fn desktopIconName(self: *LocalModel, path: []const u8) ?[]u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            std.Io.Limit.limited(64 * 1024),
        ) catch return null;
        defer self.gpa.free(data);

        var in_desktop_entry = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                in_desktop_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                continue;
            }
            if (!in_desktop_entry) continue;
            if (!std.mem.startsWith(u8, line, "Icon=")) continue;
            const value = std.mem.trim(u8, line["Icon=".len..], " \t\r");
            if (value.len == 0) return null;
            return self.gpa.dupe(u8, value) catch null;
        }
        return null;
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
        const trash = self.location == .trash;

        for (self.entries.items, 0..) |entry, index| {
            if (!trash and !self.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (filter.len > 0) {
                if (trash) {
                    const original = entry.original_path orelse "";
                    if (!containsIgnoreCase(entry.name, filter) and
                        !containsIgnoreCase(original, filter)) continue;
                } else if (!entry.is_dir and !containsIgnoreCase(entry.name, filter)) {
                    continue;
                }
            }
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

        const order = if (self.location == .trash)
            switch (self.sort_column) {
                0 => text_sort.orderIgnoreCase(a.name, b.name),
                1 => text_sort.orderIgnoreCase(
                    a.original_path orelse "",
                    b.original_path orelse "",
                ),
                2 => std.mem.order(
                    u8,
                    a.deletion_text[0..a.deletion_len],
                    b.deletion_text[0..b.deletion_len],
                ),
                3 => std.math.order(a.size, b.size),
                else => text_sort.orderIgnoreCase(a.name, b.name),
            }
        else switch (self.sort_column) {
            0 => text_sort.orderIgnoreCase(a.name, b.name),
            1 => std.math.order(a.size, b.size),
            2 => std.math.order(kindRank(a), kindRank(b)),
            3 => std.math.order(a.mtime, b.mtime),
            else => text_sort.orderIgnoreCase(a.name, b.name),
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
        if (file_ops.isTrashLocation(self.path)) return self.scanTrash();

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

    fn scanTrash(self: *LoadJob) !void {
        var trash_entries = try file_ops.listTrash(self.gpa, self.io);
        defer {
            for (trash_entries.items) |*entry| entry.deinit(self.gpa);
            trash_entries.deinit(self.gpa);
        }

        for (trash_entries.items) |entry| {
            if (self.cancel.load(.acquire)) return error.Cancelled;

            const copy = try copyTrashEntry(self.gpa, entry);
            self.entries.append(self.gpa, copy) catch |err| {
                var discard = copy;
                discard.deinit(self.gpa);
                return err;
            };
        }
    }
};

fn copyTrashEntry(gpa: std.mem.Allocator, entry: file_ops.TrashEntry) !LocalModel.Entry {
    const name = try gpa.dupe(u8, entry.name);
    errdefer gpa.free(name);
    const path = try gpa.dupe(u8, entry.trash_path);
    errdefer gpa.free(path);
    const original_path = if (entry.original_path.len > 0)
        try gpa.dupe(u8, entry.original_path)
    else
        null;
    errdefer if (original_path) |value| gpa.free(value);
    const info_path = try gpa.dupe(u8, entry.info_path);
    errdefer gpa.free(info_path);

    return .{
        .name = name,
        .path = path,
        .is_dir = entry.is_dir,
        .is_symlink = entry.is_symlink,
        .size = entry.size,
        .mtime = entry.mtime,
        .original_path = original_path,
        .info_path = info_path,
        .deletion_text = entry.deletion_text,
        .deletion_len = entry.deletion_len,
    };
}

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

    if (role == qnamespace_enums.ItemDataRole.DecorationRole and index.column() == 0) {
        const icon = self.iconFor(entry);
        const variant_ptr = ligma_qvariant_from_icon(icon.ptr) orelse return emptyVariant();
        return QVariant{ .ptr = @ptrCast(variant_ptr) };
    }

    if (role == qnamespace_enums.ItemDataRole.DisplayRole) {
        if (self.location == .trash) {
            var deleted_buffer: [32]u8 = undefined;
            return switch (index.column()) {
                0 => stringVariant(entry.name),
                1 => stringVariant(entry.original_path orelse "—"),
                2 => stringVariant(entry.deletedLabel(&deleted_buffer)),
                3 => if (entry.is_dir) emptyVariant() else stringVariant(formatSize(entry.size)),
                else => emptyVariant(),
            };
        }
        return switch (index.column()) {
            0 => stringVariant(entry.name),
            1 => if (entry.is_dir) emptyVariant() else stringVariant(formatSize(entry.size)),
            2 => stringVariant(kindLabel(entry)),
            3 => stringVariant(formatModified(entry.mtime)),
            else => emptyVariant(),
        };
    }

    if (role == qnamespace_enums.ItemDataRole.ToolTipRole) {
        if (self.location == .trash) {
            var deleted_buffer: [32]u8 = undefined;
            var buffer: [4096]u8 = undefined;
            const original = entry.original_path orelse "Unknown original location";
            const text = std.fmt.bufPrint(
                &buffer,
                "Original location: {s}\nDeleted: {s}\nTrash file: {s}",
                .{ original, entry.deletedLabel(&deleted_buffer), entry.path },
            ) catch entry.path;
            return stringVariant(text);
        }
        return stringVariant(entry.path);
    }

    const size_column: i32 = if (self.location == .trash) 3 else 1;
    if (role == qnamespace_enums.ItemDataRole.TextAlignmentRole and index.column() == size_column) {
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
    const self = findModel(model) orelse return emptyVariant();
    if (orientation != qnamespace_enums.Orientation.Horizontal) return emptyVariant();
    if (role != qnamespace_enums.ItemDataRole.DisplayRole) return emptyVariant();

    if (self.location == .trash) {
        return switch (section) {
            0 => stringVariant("Name"),
            1 => stringVariant("Original Location"),
            2 => stringVariant("Deleted"),
            3 => stringVariant("Size"),
            else => emptyVariant(),
        };
    }

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
    if (!index.isValid()) {
        return if (self.location == .trash) 0 else qnamespace_enums.ItemFlag.ItemIsDropEnabled;
    }

    var flags = qnamespace_enums.ItemFlag.ItemIsEnabled |
        qnamespace_enums.ItemFlag.ItemIsSelectable |
        qnamespace_enums.ItemFlag.ItemIsDragEnabled;
    if (self.location == .trash) return flags & ~qnamespace_enums.ItemFlag.ItemIsDragEnabled;
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
    if (self.location == .trash) return mime;
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
    if (self.location == .trash) return false;
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
    if (self.location == .trash) return false;
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
    if (self.location == .trash) return null;
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

fn specialFolderIcon(path: []const u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const home_path = withoutTrailingSlashes(std.mem.span(home));
    if (samePath(path, home_path)) return "user-home";

    const specials = [_]struct { name: []const u8, icon: []const u8 }{
        .{ .name = "Desktop", .icon = "user-desktop" },
        .{ .name = "Documents", .icon = "folder-documents" },
        .{ .name = "Downloads", .icon = "folder-download" },
        .{ .name = "Music", .icon = "folder-music" },
        .{ .name = "Pictures", .icon = "folder-pictures" },
        .{ .name = "Public", .icon = "folder-publicshare" },
        .{ .name = "Templates", .icon = "folder-templates" },
        .{ .name = "Videos", .icon = "folder-videos" },
    };
    var buffer: [4096]u8 = undefined;
    for (specials) |special| {
        const joined = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ home_path, special.name }) catch continue;
        if (samePath(path, joined)) return special.icon;
    }

    // XDG user directories can be relocated or localized. Fall back to the
    // conventional folder name so a custom Music/Pictures location still gets
    // its themed icon.
    const base = std.fs.path.basename(path);
    for (specials) |special| {
        if (std.ascii.eqlIgnoreCase(base, special.name)) return special.icon;
    }
    return null;
}

fn genericMimeIcon(mime: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mime, "image/")) return "image-x-generic";
    if (std.mem.startsWith(u8, mime, "audio/")) return "audio-x-generic";
    if (std.mem.startsWith(u8, mime, "video/")) return "video-x-generic";
    if (std.mem.startsWith(u8, mime, "text/")) return "text-x-generic";
    if (std.mem.startsWith(u8, mime, "font/")) return "font-x-generic";
    if (std.mem.startsWith(u8, mime, "model/")) return "model-x-generic";
    if (std.mem.eql(u8, mime, "application/pdf")) return "application-pdf";
    if (std.mem.startsWith(u8, mime, "application/zip") or
        std.mem.startsWith(u8, mime, "application/x-tar") or
        std.mem.startsWith(u8, mime, "application/x-7z") or
        std.mem.startsWith(u8, mime, "application/x-rar"))
    {
        return "package-x-generic";
    }
    return "application-x-generic";
}

fn samePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, withoutTrailingSlashes(a), withoutTrailingSlashes(b));
}

fn withoutTrailingSlashes(path: []const u8) []const u8 {
    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return trimmed;
}

fn fitWithin(width: i32, height: i32, box_w: i32, box_h: i32) [2]i32 {
    if (width <= 0 or height <= 0) return .{ 0, 0 };
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const scale = @min(
        @as(f64, @floatFromInt(box_w)) / w,
        @as(f64, @floatFromInt(box_h)) / h,
        1.0,
    );
    const fw: i32 = @intFromFloat(@max(1.0, @floor(w * scale)));
    const fh: i32 = @intFromFloat(@max(1.0, @floor(h * scale)));
    return .{ fw, fh };
}

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
