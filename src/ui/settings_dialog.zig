//! Ligma's Settings window.
//!
//! The categories and controls follow Luciole's configuration surface, but
//! the presentation is Ligma's: a borderless navigation column with the same
//! gradient selection used by Places, rounded cards, and accent-tinted
//! switches. Changes apply immediately and are saved by the caller.

const std = @import("std");
const qt6 = @import("libqt6zig");

const settings_mod = @import("../core/settings.zig");
const theme = @import("theme.zig");

const QCheckBox = qt6.QCheckBox;
const QComboBox = qt6.QComboBox;
const QDialog = qt6.QDialog;
const QDoubleSpinBox = qt6.QDoubleSpinBox;
const QFrame = qt6.QFrame;
const QHBoxLayout = qt6.QHBoxLayout;
const QLabel = qt6.QLabel;
const QLineEdit = qt6.QLineEdit;
const QListWidget = qt6.QListWidget;
const QPushButton = qt6.QPushButton;
const QScrollArea = qt6.QScrollArea;
const QSlider = qt6.QSlider;
const QSpinBox = qt6.QSpinBox;
const QStackedWidget = qt6.QStackedWidget;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qframe_enums = qt6.qframe_enums;
const qnamespace_enums = qt6.qnamespace_enums;

extern fn ligma_checkbox_row_click(text: ?*anyopaque, checkbox: ?*anyopaque) void;

pub const Callbacks = struct {
    /// Re-apply settings to the whole window. The callee also persists them.
    apply: *const fn () callconv(.c) void,
    /// Switch the color theme. 0 = Matugen, 1 = Light, 2 = Dark, 3 = System.
    set_theme: *const fn (mode: i32) callconv(.c) void,
    /// Resize the sidebar without touching any other window state.
    sidebar_width: *const fn (width: i32) callconv(.c) void,
    /// Update only the window background tint while the slider is moving.
    background_opacity: *const fn (opacity: f64) callconv(.c) void,
    /// Update wheel and touchpad scroll distance immediately.
    scroll_sensitivity: *const fn (sensitivity: f64) callconv(.c) void,
};

const Ui = struct {
    gpa: std.mem.Allocator,
    dialog: QDialog = undefined,
    nav: QListWidget = undefined,
    pages: QStackedWidget = undefined,

    activation: QComboBox = undefined,
    typing: QComboBox = undefined,
    confirm_delete: QCheckBox = undefined,
    switch_new_tab: QCheckBox = undefined,
    restore_last_window: QCheckBox = undefined,
    terminal: QLineEdit = undefined,

    theme: QComboBox = undefined,
    opacity: QSlider = undefined,
    opacity_value: QLabel = undefined,
    corner: QDoubleSpinBox = undefined,
    compact_menus: QCheckBox = undefined,
    always_tabs: QCheckBox = undefined,
    always_status: QCheckBox = undefined,
    show_sidebar: QCheckBox = undefined,
    show_drives: QCheckBox = undefined,
    sidebar_width: QSpinBox = undefined,
    show_preview: QCheckBox = undefined,

    view_mode: QComboBox = undefined,
    density: QComboBox = undefined,
    scroll_sensitivity: QSlider = undefined,
    scroll_value: QLabel = undefined,
    truncation: QComboBox = undefined,
    show_emblems: QCheckBox = undefined,
    show_hidden: QCheckBox = undefined,
    show_backups: QCheckBox = undefined,
    sort_by: QComboBox = undefined,
    sort_desc: QCheckBox = undefined,
    dirs_first: QCheckBox = undefined,
    grid_size: QSpinBox = undefined,
    size_col: QCheckBox = undefined,
    kind_col: QCheckBox = undefined,
    modified_col: QCheckBox = undefined,

    thumbnail_policy: QComboBox = undefined,
    thumbnail_limit: QSpinBox = undefined,
    video_thumbs: QCheckBox = undefined,

    hover_preview: QCheckBox = undefined,
    hover_seconds: QSpinBox = undefined,
};

var ui: Ui = undefined;
var created = false;
var suppress = false;
var settings_ptr: *settings_mod.Settings = undefined;
var callbacks: Callbacks = undefined;

/// Open Settings, or focus the existing window. Controls always show the
/// caller's current values, so the menu path and Ctrl+, stay in sync.
pub fn open(
    parent: anytype,
    gpa: std.mem.Allocator,
    settings: *settings_mod.Settings,
    initial_theme: i32,
    matugen_available: bool,
    cb: Callbacks,
) void {
    if (created) {
        syncControls(settings);
        setThemeIndex(initial_theme);
        ui.dialog.show();
        ui.dialog.raise();
        ui.dialog.activateWindow();
        return;
    }

    settings_ptr = settings;
    callbacks = cb;
    ui = .{ .gpa = gpa };

    ui.dialog = QDialog.new(parent);
    ui.dialog.setWindowTitle("Settings");
    ui.dialog.setMinimumSize2(680, 500);
    ui.dialog.resize(900, 660);
    ui.dialog.setStyleSheet(dialogStyle());

    const root = QHBoxLayout.new(ui.dialog);
    root.setContentsMargins(12, 12, 12, 12);
    root.setSpacing(14);

    ui.nav = QListWidget.new(ui.dialog);
    ui.nav.setFixedWidth(172);
    ui.nav.setUniformItemSizes(true);
    ui.nav.setSpacing(1);
    var nav_style: [4096]u8 = undefined;
    ui.nav.setStyleSheet(theme.listStyle(&nav_style));
    ui.nav.addItem("General");
    ui.nav.addItem("Appearance");
    ui.nav.addItem("Views");
    ui.nav.addItem("Thumbnails");
    ui.nav.addItem("Preview");
    ui.nav.onCurrentRowChanged(onNavChanged);
    root.addWidget(ui.nav);

    const right = QVBoxLayout.new2();
    right.setSpacing(8);
    ui.pages = QStackedWidget.new2();
    right.addWidget2(ui.pages, 1);

    buildGeneralPage();
    buildAppearancePage(matugen_available);
    buildViewsPage();
    buildThumbnailsPage();
    buildPreviewPage();

    const footer = QHBoxLayout.new2();
    footer.setSpacing(8);
    const reset = QPushButton.new3("Reset All");
    reset.onClicked(onResetClicked);
    footer.addWidget(reset);
    footer.addStretch();
    const close = QPushButton.new3("Close");
    close.onClicked(onCloseClicked);
    footer.addWidget(close);
    right.addLayout(footer);
    root.addLayout2(right, 1);

    // Lay out every page once before showing the window. QStackedWidget
    // otherwise leaves hidden pages unlaid-out, which makes the first
    // switch to a category briefly use stale row geometry.
    var page_index: i32 = 0;
    while (page_index < ui.pages.count()) : (page_index += 1) {
        ui.pages.setCurrentIndex(page_index);
        ui.pages.currentWidget().adjustSize();
        ui.pages.currentWidget().updateGeometry();
    }
    ui.pages.setCurrentIndex(0);

    syncControls(settings);
    setThemeIndex(initial_theme);
    ui.nav.setCurrentRow(0);
    created = true;
    ui.dialog.show();
    ui.dialog.raise();
    ui.dialog.activateWindow();
    ui.nav.setFocus();
}

/// Keep the theme choice in sync when the View > Appearance menu changes it.
pub fn setThemeIndex(index: i32) void {
    if (!created) return;
    if (index < 0 or index > 3) return;
    suppress = true;
    ui.theme.setCurrentIndex(index);
    suppress = false;
}

/// Re-apply accent-dependent styles after a palette change.
pub fn refreshTheme() void {
    if (!created) return;
    var nav_style: [4096]u8 = undefined;
    ui.nav.setStyleSheet(theme.listStyle(&nav_style));
    ui.dialog.setStyleSheet(dialogStyle());
}

fn onNavChanged(_: QListWidget, row: i32) callconv(.c) void {
    if (row < 0) return;
    ui.pages.setCurrentIndex(row);
    ui.pages.currentWidget().updateGeometry();
    ui.pages.currentWidget().update();
    ui.pages.update();
}

fn onCloseClicked(_: QPushButton) callconv(.c) void {
    ui.dialog.hide();
}

fn onResetClicked(_: QPushButton) callconv(.c) void {
    settings_ptr.deinit(ui.gpa);
    settings_ptr.* = settings_mod.Settings{};
    syncControls(settings_ptr);
    callbacks.apply();
}

fn onAnyCheck(_: QCheckBox, _: bool) callconv(.c) void {
    commit();
}

fn onAnyCombo(_: QComboBox, _: i32) callconv(.c) void {
    commit();
}

fn onAnySpin(_: QSpinBox, _: i32) callconv(.c) void {
    commit();
}

fn onAnyDoubleSpin(_: QDoubleSpinBox, _: f64) callconv(.c) void {
    commit();
}

fn onOpacityChanged(_: QSlider, value: i32) callconv(.c) void {
    updatePercentLabel(ui.opacity_value, value);
    if (suppress) return;
    settings_ptr.background_opacity = @as(f64, @floatFromInt(value)) / 100.0;
    // Re-applying every pane setting on each drag step would be needless
    // work, so the slider only rebuilds the window chrome.
    callbacks.background_opacity(settings_ptr.background_opacity);
}

fn onScrollSensitivityChanged(_: QSlider, value: i32) callconv(.c) void {
    updatePercentLabel(ui.scroll_value, value);
    if (suppress) return;
    settings_ptr.scroll_sensitivity = @as(f64, @floatFromInt(value)) / 100.0;
    callbacks.scroll_sensitivity(settings_ptr.scroll_sensitivity);
}

fn updatePercentLabel(label: QLabel, value: i32) void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}%", .{value}) catch "";
    label.setText(text);
}

fn onAnyText(_: QLineEdit) callconv(.c) void {
    commit();
}

fn onThemeCombo(_: QComboBox, index: i32) callconv(.c) void {
    if (suppress) return;
    callbacks.set_theme(index);
    refreshTheme();
}

/// Copy every control into the settings struct. Running once per edit keeps
/// the callbacks simple and makes Reset All a single assignment.
fn commit() void {
    if (suppress) return;
    const s = settings_ptr;

    s.activation = switch (ui.activation.currentIndex()) {
        1 => .single_click,
        else => .double_click,
    };
    s.typing_mode = switch (ui.typing.currentIndex()) {
        1 => .filter,
        2 => .search,
        else => .typeahead,
    };
    s.confirm_delete = ui.confirm_delete.isChecked();
    s.switch_new_tab = ui.switch_new_tab.isChecked();
    s.restore_last_window = ui.restore_last_window.isChecked();
    const terminal_text = ui.terminal.text(ui.gpa);
    defer ui.gpa.free(terminal_text);
    if (!std.mem.eql(u8, terminal_text, s.terminal_command)) {
        if (s.terminal_command.len > 0) ui.gpa.free(s.terminal_command);
        s.terminal_command = if (terminal_text.len == 0)
            &.{}
        else
            ui.gpa.dupe(u8, terminal_text) catch &.{};
    }

    s.background_opacity = @as(f64, @floatFromInt(ui.opacity.value())) / 100.0;
    s.corner_radius_scale = ui.corner.value();
    s.compact_menus = ui.compact_menus.isChecked();
    s.always_show_tab_bar = ui.always_tabs.isChecked();
    s.always_show_status_bar = ui.always_status.isChecked();
    s.show_sidebar = ui.show_sidebar.isChecked();
    s.show_drives = ui.show_drives.isChecked();
    const previous_width = s.sidebar_width;
    s.sidebar_width = ui.sidebar_width.value();
    s.show_preview = ui.show_preview.isChecked();

    s.view_mode = switch (ui.view_mode.currentIndex()) {
        1 => .icons,
        2 => .compact,
        3 => .grid,
        else => .details,
    };
    s.density = switch (ui.density.currentIndex()) {
        1 => .comfortable,
        else => .compact,
    };
    s.scroll_sensitivity = @as(f64, @floatFromInt(ui.scroll_sensitivity.value())) / 100.0;
    s.filename_truncation = switch (ui.truncation.currentIndex()) {
        1 => .middle,
        else => .end,
    };
    s.show_emblems = ui.show_emblems.isChecked();
    s.show_hidden = ui.show_hidden.isChecked();
    s.show_backups = ui.show_backups.isChecked();
    s.sort_by = switch (ui.sort_by.currentIndex()) {
        1 => .size,
        2 => .kind,
        3 => .modified,
        else => .name,
    };
    s.sort_descending = ui.sort_desc.isChecked();
    s.directories_first = ui.dirs_first.isChecked();
    s.grid_icon_size = ui.grid_size.value();
    s.show_size_column = ui.size_col.isChecked();
    s.show_kind_column = ui.kind_col.isChecked();
    s.show_modified_column = ui.modified_col.isChecked();

    s.thumbnail_policy = switch (ui.thumbnail_policy.currentIndex()) {
        1 => .local,
        2 => .all,
        else => .never,
    };
    s.thumbnail_max_mib = ui.thumbnail_limit.value();
    s.video_thumbnails = ui.video_thumbs.isChecked();

    s.video_hover_preview = ui.hover_preview.isChecked();
    s.video_hover_seconds = ui.hover_seconds.value();

    if (s.sidebar_width != previous_width)
        callbacks.sidebar_width(s.sidebar_width);
    callbacks.apply();
}

/// Push the current settings into every control without triggering commits.
fn syncControls(settings: *const settings_mod.Settings) void {
    suppress = true;
    defer suppress = false;

    ui.activation.setCurrentIndex(if (settings.activation == .single_click) 1 else 0);
    ui.typing.setCurrentIndex(switch (settings.typing_mode) {
        .filter => 1,
        .search => 2,
        .typeahead => 0,
    });
    ui.confirm_delete.setChecked(settings.confirm_delete);
    ui.switch_new_tab.setChecked(settings.switch_new_tab);
    ui.restore_last_window.setChecked(settings.restore_last_window);
    ui.terminal.setText(settings.terminal_command);

    ui.opacity.setValue(@intFromFloat(@round(settings.background_opacity * 100.0)));
    updatePercentLabel(ui.opacity_value, ui.opacity.value());
    ui.corner.setValue(settings.corner_radius_scale);
    ui.compact_menus.setChecked(settings.compact_menus);
    ui.always_tabs.setChecked(settings.always_show_tab_bar);
    ui.always_status.setChecked(settings.always_show_status_bar);
    ui.show_sidebar.setChecked(settings.show_sidebar);
    ui.show_drives.setChecked(settings.show_drives);
    ui.sidebar_width.setValue(settings.sidebar_width);
    ui.show_preview.setChecked(settings.show_preview);

    ui.view_mode.setCurrentIndex(switch (settings.view_mode) {
        .details => 0,
        .icons => 1,
        .compact => 2,
        .grid => 3,
    });
    ui.density.setCurrentIndex(if (settings.density == .comfortable) 1 else 0);
    ui.scroll_sensitivity.setValue(@intFromFloat(@round(settings.scroll_sensitivity * 100.0)));
    updatePercentLabel(ui.scroll_value, ui.scroll_sensitivity.value());
    ui.truncation.setCurrentIndex(if (settings.filename_truncation == .middle) 1 else 0);
    ui.show_emblems.setChecked(settings.show_emblems);
    ui.show_hidden.setChecked(settings.show_hidden);
    ui.show_backups.setChecked(settings.show_backups);
    ui.sort_by.setCurrentIndex(switch (settings.sort_by) {
        .name => 0,
        .size => 1,
        .kind => 2,
        .modified => 3,
    });
    ui.sort_desc.setChecked(settings.sort_descending);
    ui.dirs_first.setChecked(settings.directories_first);
    ui.grid_size.setValue(settings.grid_icon_size);
    ui.size_col.setChecked(settings.show_size_column);
    ui.kind_col.setChecked(settings.show_kind_column);
    ui.modified_col.setChecked(settings.show_modified_column);

    ui.thumbnail_policy.setCurrentIndex(switch (settings.thumbnail_policy) {
        .never => 0,
        .local => 1,
        .all => 2,
    });
    ui.thumbnail_limit.setValue(settings.thumbnail_max_mib);
    ui.video_thumbs.setChecked(settings.video_thumbnails);

    ui.hover_preview.setChecked(settings.video_hover_preview);
    ui.hover_seconds.setValue(settings.video_hover_seconds);
}

fn buildGeneralPage() void {
    const page = newPage();

    const behavior = addCard(page, "Behavior");
    ui.activation = addCombo(behavior, "Open items", "How a file or folder is activated", &.{
        "Double click", "Single click",
    });
    ui.typing = addCombo(behavior, "When typing", "What plain letters do in a file view", &.{
        "Select names", "Filter current folder", "Search subfolders",
    });
    ui.confirm_delete = addCheck(behavior, "Confirm permanent deletion", "Ask before deleting files for good");
    ui.switch_new_tab = addCheck(behavior, "Switch to new folder tabs", "Open folders in a tab and focus it");
    ui.restore_last_window = addCheck(behavior, "Restore tabs from last window", "Reopen the tabs that were open when Ligma closed");

    const terminal = addCard(page, "Terminal");
    ui.terminal = QLineEdit.new2();
    ui.terminal.setPlaceholderText("Automatic");
    ui.terminal.setMinimumWidth(220);
    ui.terminal.onEditingFinished(onAnyText);
    _ = addRow(terminal, "Terminal command", "For example: foot or kitty. Empty uses $TERMINAL.", ui.terminal);

    page.addStretch();
}

fn buildAppearancePage(matugen_available: bool) void {
    const page = newPage();

    const window_card = addCard(page, "Theme");
    ui.theme = addCombo(window_card, "Color theme", "Matugen follows the desktop color scheme", &.{
        "Matugen", "Light", "Dark", "System",
    });
    ui.theme.onCurrentIndexChanged(onThemeCombo);
    if (!matugen_available) ui.theme.setToolTip("Matugen is not installed or has not generated a scheme yet.");

    const window_look = addCard(page, "Window");
    const opacity_row = QWidget.new2();
    opacity_row.setMinimumWidth(240);
    const opacity_layout = QHBoxLayout.new(opacity_row);
    opacity_layout.setContentsMargins(0, 0, 0, 0);
    opacity_layout.setSpacing(8);
    ui.opacity = QSlider.new3(qnamespace_enums.Orientation.Horizontal);
    ui.opacity.setRange(20, 100);
    ui.opacity.setPageStep(10);
    ui.opacity.setMinimumWidth(180);
    ui.opacity_value = QLabel.new3("100%");
    ui.opacity_value.setObjectName("ligmaValue");
    ui.opacity_value.setFixedWidth(40);
    ui.opacity_value.setAlignment(qnamespace_enums.AlignmentFlag.AlignRight |
        qnamespace_enums.AlignmentFlag.AlignVCenter);
    opacity_layout.addWidget2(ui.opacity, 1);
    opacity_layout.addWidget(ui.opacity_value);
    ui.opacity.onValueChanged(onOpacityChanged);
    _ = addRow(
        window_look,
        "Background opacity",
        "How much of the desktop shows through the window background",
        opacity_row,
    );
    ui.corner = addDoubleSpin(window_look, "Corner roundness", "Scales row, card, and progress radius", 0.0, 2.0, 0.1);
    ui.compact_menus = addCheck(window_look, "Compact context menus", "Tighter padding in menus");
    ui.always_tabs = addCheck(window_look, "Always show tab bar", "Keep the tab strip visible with one tab");
    ui.always_status = addCheck(window_look, "Always show status bar", "Show file counts and messages");

    const sidebar = addCard(page, "Sidebar");
    ui.show_sidebar = addCheck(sidebar, "Show sidebar", "Places, drives, and the preview panel");
    ui.show_drives = addCheck(sidebar, "Show drives", "Mounted and removable volumes");
    ui.sidebar_width = addSpin(sidebar, "Sidebar width", "Pixels", "px", 160, 620, 10);

    page.addStretch();
}

fn buildViewsPage() void {
    const page = newPage();

    const view = addCard(page, "View");
    ui.view_mode = addCombo(view, "View", "Default for new tabs", &.{
        "Details", "Icons", "Compact", "Grid",
    });
    ui.density = addCombo(view, "Density", "Spacing inside file views", &.{
        "Compact", "Comfortable",
    });
    ui.truncation = addCombo(view, "Long filenames", "Details view elision", &.{
        "Shorten at the end", "Shorten in the middle",
    });
    const scroll_row = QWidget.new2();
    scroll_row.setMinimumWidth(240);
    const scroll_layout = QHBoxLayout.new(scroll_row);
    scroll_layout.setContentsMargins(0, 0, 0, 0);
    scroll_layout.setSpacing(8);
    ui.scroll_sensitivity = QSlider.new3(qnamespace_enums.Orientation.Horizontal);
    ui.scroll_sensitivity.setRange(50, 250);
    ui.scroll_sensitivity.setPageStep(25);
    ui.scroll_sensitivity.setMinimumWidth(180);
    ui.scroll_value = QLabel.new3("100%");
    ui.scroll_value.setObjectName("ligmaValue");
    ui.scroll_value.setFixedWidth(40);
    ui.scroll_value.setAlignment(qnamespace_enums.AlignmentFlag.AlignRight |
        qnamespace_enums.AlignmentFlag.AlignVCenter);
    scroll_layout.addWidget2(ui.scroll_sensitivity, 1);
    scroll_layout.addWidget(ui.scroll_value);
    ui.scroll_sensitivity.onValueChanged(onScrollSensitivityChanged);
    _ = addRow(
        view,
        "Scroll sensitivity",
        "Wheel and touchpad distance",
        scroll_row,
    );

    ui.show_emblems = addCheck(view, "Link and read-only emblems", "Keep the symlink badge on icons");

    const files = addCard(page, "Files");
    ui.show_hidden = addCheck(files, "Show hidden files", "Names beginning with a dot");
    ui.show_backups = addCheck(files, "Show backup files (*~)", "Editor backup copies");

    const sorting = addCard(page, "Sorting");
    ui.sort_by = addCombo(sorting, "Sort by", "Natural order is used for names", &.{
        "Name", "Size", "Type", "Modified",
    });
    ui.sort_desc = addCheck(sorting, "Reverse order", "Largest or newest first");
    ui.dirs_first = addCheck(sorting, "Folders first", "Keep directories above files");

    const grid = addCard(page, "Grid");
    ui.grid_size = addSpin(grid, "Icon size", "Pixels in Grid view", "px", 48, 192, 8);

    const columns = addCard(page, "List columns");
    ui.size_col = addCheck(columns, "Size", "Show the size column in Details");
    ui.kind_col = addCheck(columns, "Type", "Show the type column in Details");
    ui.modified_col = addCheck(columns, "Modified", "Show the modification time");

    page.addStretch();
}

fn buildThumbnailsPage() void {
    const page = newPage();

    const generation = addCard(page, "Generation");
    ui.thumbnail_policy = addCombo(generation, "Show thumbnails", "Thumbnail source policy", &.{
        "Never", "Local files", "All locations",
    });
    ui.thumbnail_limit = addSpin(generation, "Image/PDF size limit", "Applies to image and PDF thumbnails", "MiB", 1, 1024, 8);

    const video = addCard(page, "Video");
    ui.video_thumbs = addCheck(video, "Video thumbnails", "Extract a frame with ffmpeg for file icons");
    const note = QLabel.new3("Video frames are extracted in the background, one at a time, so scrolling stays responsive.");
    note.setWordWrap(true);
    note.setObjectName("ligmaHint");
    video.addWidget(note);

    page.addStretch();
}

fn buildPreviewPage() void {
    const page = newPage();

    const panel = addCard(page, "Panel");
    ui.show_preview = addCheck(panel, "Show preview", "Use the empty sidebar space below Places");
    const note = QLabel.new3("The preview fills the bottom-left corner. Selecting one image or video shows a larger preview; other files show their details.");
    note.setWordWrap(true);
    note.setObjectName("ligmaHint");
    panel.addWidget(note);

    const hover = addCard(page, "Video hover");
    ui.hover_preview = addCheck(hover, "Play a video snippet on hover", "Muted preview while the pointer rests on a video");
    ui.hover_seconds = addSpin(hover, "Snippet length", "Seconds before the preview stops", "s", 1, 30, 1);

    page.addStretch();
}

fn newPage() QVBoxLayout {
    const scroll = QScrollArea.new2();
    scroll.setWidgetResizable(true);
    scroll.setFrameShape(qframe_enums.Shape.NoFrame);
    scroll.setHorizontalScrollBarPolicy(qnamespace_enums.ScrollBarPolicy.ScrollBarAlwaysOff);

    const content = QWidget.new2();
    const layout = QVBoxLayout.new(content);
    layout.setContentsMargins(2, 2, 10, 2);
    layout.setSpacing(12);
    scroll.setWidget(content);
    _ = ui.pages.addWidget(scroll);
    return layout;
}

fn addCard(page: QVBoxLayout, title: []const u8) QVBoxLayout {
    const frame = QFrame.new2();
    frame.setObjectName("ligmaCard");
    const layout = QVBoxLayout.new(frame);
    layout.setContentsMargins(14, 10, 14, 12);
    layout.setSpacing(3);
    const label = QLabel.new3(title);
    label.setObjectName("ligmaCardTitle");
    layout.addWidget(label);
    page.addWidget(frame);
    return layout;
}

fn addRow(card: QVBoxLayout, title: []const u8, subtitle: []const u8, control: anytype) QWidget {
    const row = QHBoxLayout.new2();
    row.setContentsMargins(0, 4, 0, 4);
    row.setSpacing(12);

    const text = QWidget.new2();
    const text_layout = QVBoxLayout.new(text);
    text_layout.setContentsMargins(0, 0, 0, 0);
    text_layout.setSpacing(1);
    const title_label = QLabel.new3(title);
    title_label.setWordWrap(true);
    title_label.setAttribute2(qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
    text_layout.addWidget(title_label);
    if (subtitle.len > 0) {
        const hint = QLabel.new3(subtitle);
        hint.setWordWrap(true);
        hint.setObjectName("ligmaHint");
        hint.setAttribute2(qnamespace_enums.WidgetAttribute.WA_TransparentForMouseEvents, true);
        text_layout.addWidget(hint);
    }

    row.addWidget2(text, 1);
    row.addWidget(control);
    card.addLayout(row);
    return text;
}

fn addCheck(card: QVBoxLayout, title: []const u8, subtitle: []const u8) QCheckBox {
    const box = QCheckBox.new2();
    // A fixed, right-aligned hit area is easier to click than the bare
    // indicator and keeps the indicator visually aligned with the other rows.
    box.setFixedSize2(52, 28);
    box.setLayoutDirection(qnamespace_enums.LayoutDirection.RightToLeft);
    box.onToggled(onAnyCheck);
    const text = addRow(card, title, subtitle, box);
    // The title and description are part of the switch: clicking anywhere on
    // the row toggles it, just like the indicator itself.
    ligma_checkbox_row_click(text.ptr, box.ptr);
    return box;
}

fn addCombo(
    card: QVBoxLayout,
    title: []const u8,
    subtitle: []const u8,
    options: []const []const u8,
) QComboBox {
    const box = QComboBox.new2();
    box.setMinimumWidth(200);
    for (options) |option| box.addItem(option);
    box.onCurrentIndexChanged(onAnyCombo);
    _ = addRow(card, title, subtitle, box);
    return box;
}

fn addSpin(
    card: QVBoxLayout,
    title: []const u8,
    subtitle: []const u8,
    suffix: []const u8,
    min: i32,
    max: i32,
    step: i32,
) QSpinBox {
    const spin = QSpinBox.new2();
    spin.setRange(min, max);
    spin.setSingleStep(step);
    spin.setKeyboardTracking(false);
    if (suffix.len > 0) {
        var suffixed: [32]u8 = undefined;
        spin.setSuffix(std.fmt.bufPrint(&suffixed, " {s}", .{suffix}) catch suffix);
    }
    spin.setMinimumWidth(160);
    spin.onValueChanged(onAnySpin);
    _ = addRow(card, title, subtitle, spin);
    return spin;
}

fn addDoubleSpin(
    card: QVBoxLayout,
    title: []const u8,
    subtitle: []const u8,
    min: f64,
    max: f64,
    step: f64,
) QDoubleSpinBox {
    const spin = QDoubleSpinBox.new2();
    spin.setRange(min, max);
    spin.setSingleStep(step);
    spin.setDecimals(2);
    spin.setKeyboardTracking(false);
    spin.setMinimumWidth(160);
    spin.onValueChanged(onAnyDoubleSpin);
    _ = addRow(card, title, subtitle, spin);
    return spin;
}

/// Ligma-styled settings chrome. The card and switch rules carry the accent
/// gradient; text stays on the active theme's palette colors.
fn dialogStyle() []const u8 {
    const buffer = struct {
        var data: [8192]u8 = undefined;
    };
    const radius = theme.radius(10);
    const button_radius = theme.radius(7);
    return std.fmt.bufPrint(
        &buffer.data,
        "QDialog {{ background: palette(window); }}" ++
            "QFrame#ligmaCard {{ background: rgba(127, 127, 127, 0.10); border: none; border-radius: {d}px; }}" ++
            "QLabel#ligmaCardTitle {{ font-weight: 600; padding-bottom: 2px; }}" ++
            "QLabel#ligmaHint {{ color: rgba(127, 127, 127, 0.95); font-size: 11px; }}" ++
            "QComboBox, QSpinBox, QDoubleSpinBox, QLineEdit {{ background: rgba(127, 127, 127, 0.12); " ++
            "border: 1px solid rgba(127, 127, 127, 0.28); border-radius: {d}px; padding: 4px 8px; " ++
            "min-height: 22px; }}" ++
            "QComboBox::drop-down {{ border: none; width: 18px; }}" ++
            "QComboBox QAbstractItemView {{ border: 1px solid rgba(127, 127, 127, 0.28); }}" ++
            "QCheckBox::indicator {{ width: 16px; height: 16px; border-radius: {d}px; " ++
            "border: 1px solid rgba(127, 127, 127, 0.45); background: rgba(127, 127, 127, 0.12); }}" ++
            "QCheckBox::indicator:checked {{ border: none; background: qlineargradient(x1:0, y1:0, x2:1, y2:1, " ++
            "stop:0 rgb({d}, {d}, {d}), stop:1 rgb({d}, {d}, {d})); }}" ++
            "QLabel#ligmaValue {{ font-weight: 600; }}" ++
            "QSlider::groove:horizontal {{ height: 4px; background: rgba(127, 127, 127, 0.25); " ++
            "border-radius: 2px; }}" ++
            "QSlider::sub-page:horizontal {{ border-radius: 2px; " ++
            "background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgb({d}, {d}, {d}), stop:1 rgb({d}, {d}, {d})); }}" ++
            "QSlider::handle:horizontal {{ width: 14px; height: 14px; margin: -6px 0; " ++
            "border-radius: 7px; background: rgb({d}, {d}, {d}); }}" ++
            "QPushButton {{ background: rgba(127, 127, 127, 0.12); border: none; border-radius: {d}px; " ++
            "padding: 6px 16px; }}" ++
            "QPushButton:hover {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.35), stop:1 rgba({d}, {d}, {d}, 0.10)); }}" ++
            "QPushButton:default {{ color: white; background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.90), stop:1 rgba({d}, {d}, {d}, 0.55)); }}" ++
            "QScrollArea {{ background: transparent; border: none; }}" ++
            "QScrollBar:vertical {{ background: transparent; width: 8px; }}" ++
            "QScrollBar::handle:vertical {{ background: rgba(148, 163, 184, 0.5); border-radius: 4px; min-height: 20px; }}" ++
            "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}" ++
            "QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}",
        .{
            radius,
            button_radius,
            theme.radius(4),
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
            theme.accent_start.r,
            theme.accent_start.g,
            theme.accent_start.b,
            button_radius,
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
    ) catch "";
}
