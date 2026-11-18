//! File/folder properties with Dolphin-style permission editing.
//!
//! The dialog is created once and reused. The caller supplies a snapshot of
//! the selected items; this module copies the owned strings it needs so the
//! selection can change while the window stays open.

const std = @import("std");
const qt6 = @import("libqt6zig");

const theme = @import("theme.zig");

const QCheckBox = qt6.QCheckBox;
const QDialog = qt6.QDialog;
const QGridLayout = qt6.QGridLayout;
const QHBoxLayout = qt6.QHBoxLayout;
const QLabel = qt6.QLabel;
const QMessageBox = qt6.QMessageBox;
const QPushButton = qt6.QPushButton;
const QScrollArea = qt6.QScrollArea;
const QTabWidget = qt6.QTabWidget;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qframe_enums = qt6.qframe_enums;
const qnamespace_enums = qt6.qnamespace_enums;

pub const Item = struct {
    path: []const u8,
    name: []const u8,
    kind: []const u8,
    is_dir: bool,
    mode: u32,
};

pub const Callbacks = struct {
    /// Called after an apply, including partial failures.
    changed: *const fn (ok: bool) callconv(.c) void,
};

const OwnedItem = struct {
    path: []u8,
    name: []u8,
    kind: []u8,
    is_dir: bool,
    mode: u32,

    fn deinit(self: *OwnedItem, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.name);
        gpa.free(self.kind);
        self.* = undefined;
    }
};

const PermissionBoxes = struct {
    read: QCheckBox = undefined,
    write: QCheckBox = undefined,
    execute: QCheckBox = undefined,
};

const Ui = struct {
    dialog: QDialog = undefined,
    tabs: QTabWidget = undefined,
    general_label: QLabel = undefined,
    permissions: QWidget = undefined,
    perm_title: QLabel = undefined,
    perm_hint: QLabel = undefined,
    owner: PermissionBoxes = .{},
    group: PermissionBoxes = .{},
    other: PermissionBoxes = .{},
    set_uid: QCheckBox = undefined,
    set_gid: QCheckBox = undefined,
    sticky: QCheckBox = undefined,
    recursive: QCheckBox = undefined,
    status: QLabel = undefined,
    apply: QPushButton = undefined,
};

var ui: Ui = undefined;
var created = false;
var items: std.ArrayList(OwnedItem) = .empty;
var gpa_global: std.mem.Allocator = undefined;
var io_global: std.Io = undefined;
var callbacks: Callbacks = undefined;
var editable = true;
var has_directory = false;

/// Open (or refresh) the Properties window for the selected items.
pub fn open(
    parent: anytype,
    gpa: std.mem.Allocator,
    io: std.Io,
    snapshot: []const Item,
    general_text: []const u8,
    can_edit_permissions: bool,
    cb: Callbacks,
) void {
    gpa_global = gpa;
    io_global = io;
    callbacks = cb;
    editable = can_edit_permissions;

    clearItems();
    for (snapshot) |item| {
        appendItem(item) catch break;
    }

    if (!created) createDialog(parent);
    refreshDialog(general_text);
    ui.dialog.show();
    ui.dialog.raise();
    ui.dialog.activateWindow();
}

fn appendItem(item: Item) !void {
    const path = try gpa_global.dupe(u8, item.path);
    errdefer gpa_global.free(path);
    const name = try gpa_global.dupe(u8, item.name);
    errdefer gpa_global.free(name);
    const kind = try gpa_global.dupe(u8, item.kind);
    errdefer gpa_global.free(kind);
    try items.append(gpa_global, .{
        .path = path,
        .name = name,
        .kind = kind,
        .is_dir = item.is_dir,
        .mode = item.mode,
    });
}

fn clearItems() void {
    for (items.items) |*item| item.deinit(gpa_global);
    items.clearRetainingCapacity();
}

fn refreshDialog(general_text: []const u8) void {
    ui.general_label.setText(general_text);

    if (items.items.len == 1) {
        const item = items.items[0];
        var title_buffer: [512]u8 = undefined;
        const title = std.fmt.bufPrint(
            &title_buffer,
            "Properties — {s}",
            .{item.name},
        ) catch "Properties";
        ui.dialog.setWindowTitle(title);
        ui.perm_title.setText(item.name);
        ui.perm_hint.setText(if (editable)
            "Choose the permissions to apply. Folders usually need Execute to be opened."
        else
            "Permissions for Trash items cannot be changed here.");
    } else {
        var buffer: [128]u8 = undefined;
        const title = std.fmt.bufPrint(
            &buffer,
            "Properties — {d} items",
            .{items.items.len},
        ) catch "Properties";
        ui.dialog.setWindowTitle(title);
        ui.perm_title.setText(title);
        ui.perm_hint.setText(if (editable)
            "Choose the permissions to apply to every selected item."
        else
            "Permissions for Trash items cannot be changed here.");
    }

    var mixed = false;
    const first_mode = if (items.items.len > 0) items.items[0].mode else 0;
    for (items.items) |item| {
        if (item.mode != first_mode) {
            mixed = true;
            break;
        }
    }
    if (mixed and items.items.len > 0) {
        ui.perm_hint.setText(
            "The selection has mixed permissions. Applying will set the chosen values on every item.",
        );
    }

    syncCheckboxes(first_mode);
    has_directory = blk: {
        for (items.items) |item| {
            if (item.is_dir) break :blk true;
        }
        break :blk false;
    };
    ui.recursive.setChecked(false);
    ui.recursive.setEnabled(editable and has_directory);
    ui.status.hide();
    setEditable(editable);

    ui.apply.setDefault(true);
    ui.tabs.setCurrentIndex(0);
}

fn createDialog(parent: anytype) void {
    ui.dialog = QDialog.new(parent);
    ui.dialog.setWindowTitle("Properties");
    ui.dialog.setMinimumSize2(560, 480);
    ui.dialog.resize(680, 580);
    ui.dialog.setStyleSheet(dialogStyle());

    const root = QVBoxLayout.new(ui.dialog);
    root.setContentsMargins(12, 12, 12, 12);
    root.setSpacing(8);

    ui.tabs = QTabWidget.new(ui.dialog);
    root.addWidget2(ui.tabs, 1);

    // ---- General ---------------------------------------------------------
    const general_page = QWidget.new2();
    const general_layout = QVBoxLayout.new(general_page);
    general_layout.setContentsMargins(10, 10, 10, 10);

    const scroll = QScrollArea.new2();
    scroll.setWidgetResizable(true);
    scroll.setFrameShape(qframe_enums.Shape.NoFrame);
    ui.general_label = QLabel.new3("");
    ui.general_label.setTextFormat(qnamespace_enums.TextFormat.PlainText);
    ui.general_label.setWordWrap(true);
    ui.general_label.setTextInteractionFlags(
        qnamespace_enums.TextInteractionFlag.TextSelectableByMouse |
            qnamespace_enums.TextInteractionFlag.TextSelectableByKeyboard,
    );
    ui.general_label.setAlignment(qnamespace_enums.AlignmentFlag.AlignTop |
        qnamespace_enums.AlignmentFlag.AlignLeft);
    scroll.setWidget(ui.general_label);
    general_layout.addWidget(scroll);
    _ = ui.tabs.addTab(general_page, "General");

    // ---- Permissions -----------------------------------------------------
    ui.permissions = QWidget.new2();
    const permissions_layout = QVBoxLayout.new(ui.permissions);
    permissions_layout.setContentsMargins(12, 12, 12, 12);
    permissions_layout.setSpacing(8);

    ui.perm_title = QLabel.new3("");
    ui.perm_title.setStyleSheet("font-weight: 600;");
    permissions_layout.addWidget(ui.perm_title);
    ui.perm_hint = QLabel.new3("");
    ui.perm_hint.setObjectName("ligmaHint");
    ui.perm_hint.setWordWrap(true);
    permissions_layout.addWidget(ui.perm_hint);

    const grid = QGridLayout.new2();
    grid.setHorizontalSpacing(10);
    grid.setVerticalSpacing(6);

    const read_header = QLabel.new3("Read");
    const write_header = QLabel.new3("Write");
    const execute_header = QLabel.new3("Execute");
    grid.addWidget2(read_header, 0, 1);
    grid.addWidget2(write_header, 0, 2);
    grid.addWidget2(execute_header, 0, 3);

    ui.owner = makePermissionRow("Owner", 1, grid);
    ui.group = makePermissionRow("Group", 2, grid);
    ui.other = makePermissionRow("Others", 3, grid);

    permissions_layout.addLayout(grid);

    const special_row = QHBoxLayout.new2();
    special_row.setSpacing(12);
    ui.set_uid = QCheckBox.new3("Set UID");
    ui.set_gid = QCheckBox.new3("Set GID");
    ui.sticky = QCheckBox.new3("Sticky");
    special_row.addWidget(ui.set_uid);
    special_row.addWidget(ui.set_gid);
    special_row.addWidget(ui.sticky);
    special_row.addStretch();
    permissions_layout.addLayout(special_row);

    const quick_row = QHBoxLayout.new2();
    quick_row.setSpacing(8);
    const make_executable = QPushButton.new3("Make Executable");
    const remove_executable = QPushButton.new3("Remove Execute");
    make_executable.onClicked(onMakeExecutable);
    remove_executable.onClicked(onRemoveExecutable);
    quick_row.addWidget(make_executable);
    quick_row.addWidget(remove_executable);
    quick_row.addStretch();
    permissions_layout.addLayout(quick_row);

    ui.recursive = QCheckBox.new3("Apply to all subfolders and their contents");
    permissions_layout.addWidget(ui.recursive);

    ui.status = QLabel.new3("");
    ui.status.setObjectName("ligmaHint");
    ui.status.setWordWrap(true);
    ui.status.hide();
    permissions_layout.addWidget(ui.status);
    permissions_layout.addStretch();

    _ = ui.tabs.addTab(ui.permissions, "Permissions");

    const footer = QHBoxLayout.new2();
    footer.setSpacing(8);
    footer.addStretch();
    const close = QPushButton.new3("Close");
    close.onClicked(onCloseClicked);
    footer.addWidget(close);
    ui.apply = QPushButton.new3("Apply");
    ui.apply.onClicked(onApplyClicked);
    footer.addWidget(ui.apply);
    root.addLayout(footer);

    created = true;
}

fn makePermissionRow(label: []const u8, row: i32, grid: QGridLayout) PermissionBoxes {
    const heading = QLabel.new3(label);
    heading.setStyleSheet("font-weight: 600;");
    grid.addWidget2(heading, row, 0);

    var boxes: PermissionBoxes = .{};
    boxes.read = QCheckBox.new3("");
    boxes.write = QCheckBox.new3("");
    boxes.execute = QCheckBox.new3("");
    grid.addWidget2(boxes.read, row, 1);
    grid.addWidget2(boxes.write, row, 2);
    grid.addWidget2(boxes.execute, row, 3);
    return boxes;
}

fn syncCheckboxes(mode: u32) void {
    setPermissionBoxes(&ui.owner, 0o400, 0o200, 0o100, mode);
    setPermissionBoxes(&ui.group, 0o040, 0o020, 0o010, mode);
    setPermissionBoxes(&ui.other, 0o004, 0o002, 0o001, mode);
    ui.set_uid.setChecked((mode & 0o4000) != 0);
    ui.set_gid.setChecked((mode & 0o2000) != 0);
    ui.sticky.setChecked((mode & 0o1000) != 0);
}

fn setPermissionBoxes(
    boxes: *PermissionBoxes,
    read_bit: u32,
    write_bit: u32,
    execute_bit: u32,
    mode: u32,
) void {
    boxes.read.setChecked((mode & read_bit) != 0);
    boxes.write.setChecked((mode & write_bit) != 0);
    boxes.execute.setChecked((mode & execute_bit) != 0);
}

fn setEditable(can_edit: bool) void {
    setPermissionBoxesEnabled(&ui.owner, can_edit);
    setPermissionBoxesEnabled(&ui.group, can_edit);
    setPermissionBoxesEnabled(&ui.other, can_edit);
    ui.set_uid.setEnabled(can_edit);
    ui.set_gid.setEnabled(can_edit);
    ui.sticky.setEnabled(can_edit);
    ui.recursive.setEnabled(can_edit and has_directory);
    ui.apply.setEnabled(can_edit and items.items.len > 0);
}

fn setPermissionBoxesEnabled(boxes: *PermissionBoxes, enabled: bool) void {
    boxes.read.setEnabled(enabled);
    boxes.write.setEnabled(enabled);
    boxes.execute.setEnabled(enabled);
}

fn selectedMode() u32 {
    var mode: u32 = 0;
    if (ui.owner.read.isChecked()) mode |= 0o400;
    if (ui.owner.write.isChecked()) mode |= 0o200;
    if (ui.owner.execute.isChecked()) mode |= 0o100;
    if (ui.group.read.isChecked()) mode |= 0o040;
    if (ui.group.write.isChecked()) mode |= 0o020;
    if (ui.group.execute.isChecked()) mode |= 0o010;
    if (ui.other.read.isChecked()) mode |= 0o004;
    if (ui.other.write.isChecked()) mode |= 0o002;
    if (ui.other.execute.isChecked()) mode |= 0o001;
    if (ui.set_uid.isChecked()) mode |= 0o4000;
    if (ui.set_gid.isChecked()) mode |= 0o2000;
    if (ui.sticky.isChecked()) mode |= 0o1000;
    return mode;
}

fn onMakeExecutable(_: QPushButton) callconv(.c) void {
    ui.owner.execute.setChecked(true);
    ui.group.execute.setChecked(true);
    ui.other.execute.setChecked(true);
}

fn onRemoveExecutable(_: QPushButton) callconv(.c) void {
    ui.owner.execute.setChecked(false);
    ui.group.execute.setChecked(false);
    ui.other.execute.setChecked(false);
}

fn onCloseClicked(_: QPushButton) callconv(.c) void {
    ui.dialog.hide();
}

fn onApplyClicked(_: QPushButton) callconv(.c) void {
    if (!editable or items.items.len == 0) return;

    const mode = selectedMode();
    var attempts: usize = 0;
    var failures: usize = 0;
    for (items.items) |item| {
        attempts += 1;
        if (!chmodPath(item.path, mode)) failures += 1;
        if (ui.recursive.isChecked() and item.is_dir) {
            const tree = applyToTree(item.path, mode);
            attempts += tree.attempts;
            failures += tree.failures;
        }
    }

    const ok = failures == 0;
    callbacks.changed(ok);

    var buffer: [256]u8 = undefined;
    const message = if (ok)
        std.fmt.bufPrint(
            &buffer,
            "Permissions updated for {d} item{s}.",
            .{ attempts, if (attempts == 1) "" else "s" },
        ) catch "Permissions updated."
    else
        std.fmt.bufPrint(
            &buffer,
            "Updated {d} of {d} items; {d} could not be changed. You may not own them.",
            .{ attempts - failures, attempts, failures },
        ) catch "Some permissions could not be changed.";
    ui.status.setText(message);
    ui.status.show();

    if (!ok) {
        _ = QMessageBox.warning(
            ui.dialog,
            "Permissions",
            message,
        );
    }
}

fn chmodPath(path: []const u8, mode: u32) bool {
    const path_z = gpa_global.dupeSentinel(u8, path, 0) catch return false;
    defer gpa_global.free(path_z);
    return std.c.chmod(path_z.ptr, @intCast(mode)) == 0;
}

const TreeResult = struct { attempts: usize = 0, failures: usize = 0 };

fn applyToTree(root: []const u8, mode: u32) TreeResult {
    var result = TreeResult{};
    var dir = std.Io.Dir.openDirAbsolute(io_global, root, .{ .iterate = true }) catch {
        result.attempts = 1;
        result.failures = 1;
        return result;
    };
    defer dir.close(io_global);

    var walker = dir.walk(gpa_global) catch {
        result.attempts = 1;
        result.failures = 1;
        return result;
    };
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io_global) catch break;
        const current = entry orelse break;
        // Do not chmod through symlinks into unrelated locations.
        if (current.kind == .sym_link) continue;
        result.attempts += 1;
        if (std.c.fchmodat(current.dir.handle, current.basename.ptr, @intCast(mode), 0) != 0)
            result.failures += 1;
    }
    return result;
}

fn dialogStyle() []const u8 {
    const buffer = struct {
        var data: [4096]u8 = undefined;
    };
    return std.fmt.bufPrint(
        &buffer.data,
        "QDialog {{ background: palette(window); }}" ++
            "QTabWidget::pane {{ border: 1px solid rgba(127, 127, 127, 0.25); " ++
            "border-radius: {d}px; top: -1px; }}" ++
            "QTabBar::tab {{ padding: 6px 16px; }}" ++
            "QLabel#ligmaHint {{ color: rgba(127, 127, 127, 0.95); font-size: 11px; }}" ++
            "QCheckBox::indicator {{ width: 16px; height: 16px; border-radius: {d}px; " ++
            "border: 1px solid rgba(127, 127, 127, 0.45); background: rgba(127, 127, 127, 0.12); }}" ++
            "QCheckBox::indicator:checked {{ border: none; background: qlineargradient(" ++
            "x1:0, y1:0, x2:1, y2:1, stop:0 rgb({d}, {d}, {d}), " ++
            "stop:1 rgb({d}, {d}, {d})); }}" ++
            "QPushButton {{ background: rgba(127, 127, 127, 0.12); border: none; " ++
            "border-radius: {d}px; padding: 6px 16px; }}" ++
            "QPushButton:hover {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.35), stop:1 rgba({d}, {d}, {d}, 0.10)); }}" ++
            "QPushButton:default {{ color: white; background: qlineargradient(" ++
            "x1:0, y1:0, x2:1, y2:0, stop:0 rgba({d}, {d}, {d}, 0.90), " ++
            "stop:1 rgba({d}, {d}, {d}, 0.55)); }}",
        .{
            theme.radius(8),
            theme.radius(4),
            theme.accent_start.r,
            theme.accent_start.g,
            theme.accent_start.b,
            theme.accent_end.r,
            theme.accent_end.g,
            theme.accent_end.b,
            theme.radius(7),
            theme.accent_start.r,
            theme.accent_start.g,
            theme.accent_start.b,
            theme.accent_end.r,
            theme.accent_end.g,
            theme.accent_end.b,
            theme.accent_start.r,
            theme.accent_start.g,
            theme.accent_start.b,
            theme.accent_end.r,
            theme.accent_end.g,
            theme.accent_end.b,
        },
    ) catch "QDialog { background: palette(window); }";
}
