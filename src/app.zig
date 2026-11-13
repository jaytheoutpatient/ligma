const std = @import("std");
const qt6 = @import("libqt6zig");

const file_ops = @import("core/file_ops.zig");
const paths = @import("core/paths.zig");
const search_index = @import("core/search_index.zig");
const search_scan = @import("core/search_scan.zig");
const local_model = @import("ui/local_model.zig");
const player_mod = @import("ui/player.zig");
const preview_mod = @import("ui/preview.zig");
const terminal_mod = @import("ui/terminal.zig");

const QAction = qt6.QAction;
const QApplication = qt6.QApplication;
const QDesktopServices = qt6.QDesktopServices;
const QDir = qt6.QDir;
const QDockWidget = qt6.QDockWidget;
const QFileInfo = qt6.QFileInfo;
const QHBoxLayout = qt6.QHBoxLayout;
const QIcon = qt6.QIcon;
const QInputDialog = qt6.QInputDialog;
const QItemSelection = qt6.QItemSelection;
const QItemSelectionModel = qt6.QItemSelectionModel;
const QKeySequence = qt6.QKeySequence;
const QLabel = qt6.QLabel;
const QLineEdit = qt6.QLineEdit;
const QListWidget = qt6.QListWidget;
const QListWidgetItem = qt6.QListWidgetItem;
const QMainWindow = qt6.QMainWindow;
const QMenu = qt6.QMenu;
const QMessageBox = qt6.QMessageBox;
const QModelIndex = qt6.QModelIndex;
const QMouseEvent = qt6.QMouseEvent;
const QPixmap = qt6.QPixmap;
const QPoint = qt6.QPoint;
const QProcess = qt6.QProcess;
const QPushButton = qt6.QPushButton;
const QSize = qt6.QSize;
const QSplitter = qt6.QSplitter;
const QStatusBar = qt6.QStatusBar;
const QTabWidget = qt6.QTabWidget;
const QTimer = qt6.QTimer;
const QTreeView = qt6.QTreeView;
const QUrl = qt6.QUrl;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qabstractitemview_enums = qt6.qabstractitemview_enums;
const qnamespace_enums = qt6.qnamespace_enums;
const qdockwidget_enums = qt6.qdockwidget_enums;
const qfiledevice_enums = qt6.qfiledevice_enums;
const qitemselectionmodel_enums = qt6.qitemselectionmodel_enums;
const qlineedit_enums = qt6.qlineedit_enums;
const qmessagebox_enums = qt6.qmessagebox_enums;

pub const Pane = struct {
    tab: *Tab,
    container: QWidget,
    tree: QTreeView,
    model: *local_model.LocalModel,
    path_edit: QLineEdit,
    search_edit: QLineEdit,
    selection: QItemSelectionModel,

    history: std.ArrayList([]u8) = .empty,
    history_index: usize = 0,
    current_path: ?[]u8 = null,
};

pub const Tab = struct {
    splitter: QSplitter,
    panes: [2]?*Pane = .{ null, null },
    pane_count: u8 = 0,
    split_visible: bool = false,
    active: u8 = 0,
};

const UndoBatch = std.ArrayList(file_ops.UndoItem);

const ClipMode = enum { none, copy, cut };

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    qapp: QApplication,

    window: QMainWindow,
    tabs: QTabWidget,
    main_splitter: QSplitter,
    places: QListWidget,
    status: QStatusBar,
    count_label: QLabel,

    preview: preview_mod.PreviewPanel = undefined,

    terminal_dock: QDockWidget,
    terminal_widget: QWidget,
    terminal_action: QAction,
    terminal_started: bool = false,

    player_dock: QDockWidget,
    player: *player_mod.PlayerPanel,
    player_action: QAction,

    tree_menu: QMenu,
    places_menu: QMenu,
    ctx_open_action: QAction,
    ctx_play_action: QAction,
    ctx_playlist_action: QAction,
    ctx_cut_action: QAction,
    ctx_copy_action: QAction,
    ctx_paste_action: QAction,
    ctx_new_folder_action: QAction,
    ctx_properties_action: QAction,
    ctx_trash_action: QAction,
    ctx_delete_action: QAction,
    ctx_add_places_action: QAction,
    ctx_remove_place_action: QAction,
    context_pane: ?*Pane = null,
    context_place_row: i32 = -1,
    // Folder for the "Open in Terminal" action, captured when the context
    // menu opens so it follows the clicked row rather than the selection.
    context_terminal_dir: [8192]u8 = undefined,
    context_terminal_dir_len: usize = 0,

    global_search: QLineEdit,
    search_dock: QDockWidget,
    search_list: QListWidget,
    search_timer: QTimer,

    index_label: QLabel,
    index_timer: QTimer,
    index_path: ?[]u8 = null,
    index_reader: ?search_index.Reader = null,
    index_job: ?*search_index.BuildJob = null,

    file_timer: QTimer,
    file_job: ?*file_ops.Job = null,
    file_job_clears_clipboard: bool = false,

    model_timer: QTimer,

    back_action: ?QAction = null,
    forward_action: ?QAction = null,
    split_action: ?QAction = null,
    hidden_action: ?QAction = null,
    undo_action: ?QAction = null,

    undo_stack: std.ArrayList(UndoBatch) = .empty,
    clip_paths: std.ArrayList([]const u8) = .empty,
    clip_mode: ClipMode = .none,

    show_hidden: bool = false,
    suppress_filter: bool = false,
    tabs_updating: bool = false,

    tabs_list: std.ArrayList(*Tab) = .empty,
    panes_list: std.ArrayList(*Pane) = .empty,
    place_paths: std.ArrayList([]u8) = .empty,
    place_builtin_count: usize = 0,
    places_updating: bool = false,

    search_job: ?*search_scan.Scan = null,
    search_paths: std.ArrayList([]u8) = .empty,
    search_hits: usize = 0,
    search_query: ?[]u8 = null,
};

var app: App = undefined;

/// The 256 px rendition is embedded so the window icon works when Ligma runs
/// from a build directory, while the installed hicolor theme provides the
/// other sizes for launchers and panels.
const window_icon_png = @embedFile("assets/org.ligma.FileManager-256.png");

fn loadApplicationIcon() QIcon {
    const pixmap = QPixmap.new();
    defer pixmap.delete();
    if (pixmap.loadFromData(&window_icon_png[0], @intCast(window_icon_png.len))) {
        return QIcon.new2(pixmap);
    }
    return QIcon.fromTheme("org.ligma.FileManager");
}

pub fn run(init: std.process.Init, qapp: QApplication) !void {
    QApplication.setApplicationName("Ligma");
    QApplication.setApplicationDisplayName("Ligma");
    QApplication.setDesktopFileName("org.ligma.FileManager");

    const window_icon = loadApplicationIcon();
    defer window_icon.delete();
    QApplication.setWindowIcon(window_icon);

    const home = QDir.homePath(init.gpa);
    defer init.gpa.free(home);

    const window = QMainWindow.new2();
    defer window.delete();
    window.setWindowTitle("Ligma");
    window.resize(1240, 800);
    const minimum_size = QSize.new4(800, 520);
    defer minimum_size.delete();
    window.setMinimumSize(minimum_size);

    // ---- Main layout: shared Places sidebar + tabbed content -------------
    const main_splitter = QSplitter.new2();
    main_splitter.setChildrenCollapsible(false);
    main_splitter.setHandleWidth(1);
    window.setCentralWidget(main_splitter);

    const sidebar = QWidget.new2();
    const sidebar_layout = QVBoxLayout.new(sidebar);
    sidebar_layout.setContentsMargins(10, 10, 10, 10);
    sidebar_layout.setSpacing(8);

    const places_label = QLabel.new3("Places");
    sidebar_layout.addWidget(places_label);

    const places = QListWidget.new(sidebar);
    places.setUniformItemSizes(true);
    places.setSpacing(1);
    sidebar_layout.addWidget(places);
    sidebar_layout.addStretch();

    // Bottom-left preview: selecting a single image or video shows a larger
    // thumbnail here, under the Places sidebar.
    const preview_panel = preview_mod.PreviewPanel.create(init.gpa, init.io);
    sidebar_layout.addWidget(preview_panel.container);
    // The Places list keeps the spare vertical space; the preview panel sits
    // at the bottom with its natural height.
    sidebar_layout.setStretch(1, 1);

    main_splitter.addWidget(sidebar);

    const right_panel = QWidget.new2();
    const right_layout = QVBoxLayout.new(right_panel);
    right_layout.setContentsMargins(10, 10, 10, 10);
    right_layout.setSpacing(6);

    const nav_row = QHBoxLayout.new2();
    nav_row.setSpacing(2);
    right_layout.addLayout(nav_row);
    nav_row.addWidget(makeNavButton("←", "Back (Alt+Left)", onPaneBack));
    nav_row.addWidget(makeNavButton("→", "Forward (Alt+Right)", onPaneForward));
    nav_row.addWidget(makeNavButton("↑", "Up (Alt+Up)", onPaneUp));
    nav_row.addWidget(makeNavButton("⌂", "Home (Alt+Home)", onPaneHome));
    nav_row.addWidget(makeNavButton("⟳", "Reload (F5)", onPaneReload));
    nav_row.addStretch();

    const search_row = QHBoxLayout.new2();
    search_row.setSpacing(4);
    right_layout.addLayout(search_row);

    const global_search = QLineEdit.new2();
    global_search.setClearButtonEnabled(true);
    global_search.setPlaceholderText("Search files by name in this folder (Ctrl+Shift+F)");
    search_row.addWidget(global_search);

    const tabs = QTabWidget.new2();
    tabs.setTabsClosable(true);
    tabs.setMovable(true);
    tabs.setDocumentMode(true);
    tabs.setElideMode(qnamespace_enums.TextElideMode.ElideRight);
    right_layout.addWidget(tabs);
    right_layout.setStretch(1, 1);
    main_splitter.addWidget(right_panel);
    var main_sizes = [_]i32{ 250, 990 };
    main_splitter.setSizes(&main_sizes);

    // ---- Search results dock --------------------------------------------
    const search_dock = QDockWidget.new4("Search Results", window);
    search_dock.setAllowedAreas(qnamespace_enums.DockWidgetArea.BottomDockWidgetArea |
        qnamespace_enums.DockWidgetArea.RightDockWidgetArea);
    search_dock.setFeatures(qdockwidget_enums.DockWidgetFeature.DockWidgetClosable |
        qdockwidget_enums.DockWidgetFeature.DockWidgetMovable);
    const search_list = QListWidget.new(search_dock);
    search_list.setUniformItemSizes(true);
    search_list.setAlternatingRowColors(true);
    search_list.setWordWrap(false);
    search_dock.setWidget(search_list);
    window.addDockWidget(qnamespace_enums.DockWidgetArea.BottomDockWidgetArea, search_dock);
    search_dock.hide();

    // ---- Terminal dock ---------------------------------------------------
    // F12 toggles this panel. The shell itself is started lazily the first
    // time the panel is shown, in the active pane's folder.
    const terminal_dock = QDockWidget.new4("Terminal", window);
    terminal_dock.setAllowedAreas(qnamespace_enums.DockWidgetArea.RightDockWidgetArea);
    terminal_dock.setFeatures(qdockwidget_enums.DockWidgetFeature.DockWidgetClosable |
        qdockwidget_enums.DockWidgetFeature.DockWidgetMovable);
    terminal_dock.setMinimumWidth(400);
    const terminal_widget = terminal_mod.create(terminal_dock, onTerminalKeyToggle);
    terminal_dock.setWidget(terminal_widget);
    window.addDockWidget(qnamespace_enums.DockWidgetArea.RightDockWidgetArea, terminal_dock);
    terminal_dock.hide();

    // ---- Music player dock ----------------------------------------------
    // Hidden until an audio file is activated or the user adds tracks to the
    // playlist. The panel owns the QtMultimedia objects; the dock owns the
    // widget tree.
    const player_dock = QDockWidget.new4("Music Player", window);
    player_dock.setAllowedAreas(qnamespace_enums.DockWidgetArea.BottomDockWidgetArea);
    player_dock.setFeatures(qdockwidget_enums.DockWidgetFeature.DockWidgetClosable |
        qdockwidget_enums.DockWidgetFeature.DockWidgetMovable);
    const player_panel = player_mod.PlayerPanel.create(init.gpa, init.io) catch
        @panic("Out of memory creating music player");
    player_dock.setWidget(player_panel.container);
    window.addDockWidget(qnamespace_enums.DockWidgetArea.BottomDockWidgetArea, player_dock);
    player_dock.hide();

    const search_timer = QTimer.new2(window);
    search_timer.setInterval(100);

    const index_timer = QTimer.new2(window);
    index_timer.setInterval(500);

    const file_timer = QTimer.new2(window);
    file_timer.setInterval(150);

    const model_timer = QTimer.new2(window);
    model_timer.setInterval(50);

    const status = window.statusBar();
    const count_label = QLabel.new3("");
    status.addPermanentWidget(count_label);
    const index_label = QLabel.new3("Index: …");
    status.addPermanentWidget(index_label);

    // ---- Menus -----------------------------------------------------------
    const menubar = window.menuBar();

    const file_menu = QMenu.new4("&File", window);
    _ = menubar.addMenu(file_menu);
    const new_folder_action = makeAction(file_menu, "New Folder…", "Ctrl+Shift+N", onNewFolder);
    file_menu.addAction(new_folder_action);
    const rename_action = makeAction(file_menu, "Rename…", "F2", onRename);
    file_menu.addAction(rename_action);
    const run_action = makeAction(file_menu, "Run Selected", "Ctrl+Return", onRunSelected);
    file_menu.addAction(run_action);
    _ = file_menu.addSeparator();
    const trash_action = makeAction(file_menu, "Move to Trash", "Delete", onTrashSelected);
    file_menu.addAction(trash_action);
    const delete_action = makeAction(file_menu, "Delete Permanently", "Shift+Delete", onDeleteSelected);
    file_menu.addAction(delete_action);
    _ = file_menu.addSeparator();
    const new_tab_action = makeAction(file_menu, "New Tab", "Ctrl+T", onNewTab);
    file_menu.addAction(new_tab_action);
    _ = file_menu.addSeparator();
    const close_tab_action = makeAction(file_menu, "Close Tab", "Ctrl+W", onCloseTab);
    file_menu.addAction(close_tab_action);
    const close_window_action = makeAction(file_menu, "Close Window", "Ctrl+Shift+W", onCloseWindow);
    file_menu.addAction(close_window_action);
    _ = file_menu.addSeparator();
    const quit_action = makeAction(file_menu, "Quit", "Ctrl+Q", onQuit);
    file_menu.addAction(quit_action);

    const edit_menu = QMenu.new4("&Edit", window);
    _ = menubar.addMenu(edit_menu);
    const undo_action = makeAction(edit_menu, "Undo", "Ctrl+Z", onUndo);
    undo_action.setEnabled(false);
    edit_menu.addAction(undo_action);
    _ = edit_menu.addSeparator();
    const cut_action = makeAction(edit_menu, "Cut", "Ctrl+X", onCut);
    edit_menu.addAction(cut_action);
    const copy_action = makeAction(edit_menu, "Copy", "Ctrl+C", onCopy);
    edit_menu.addAction(copy_action);
    const paste_action = makeAction(edit_menu, "Paste", "Ctrl+V", onPaste);
    edit_menu.addAction(paste_action);
    _ = edit_menu.addSeparator();
    const select_all_action = makeAction(edit_menu, "Select All", "Ctrl+A", onSelectAll);
    edit_menu.addAction(select_all_action);
    const location_action = makeAction(edit_menu, "Edit Location", "Ctrl+L", onEditLocation);
    edit_menu.addAction(location_action);
    _ = edit_menu.addSeparator();
    const filter_action = makeAction(edit_menu, "Filter Current Folder", "Ctrl+F", onFocusFilter);
    edit_menu.addAction(filter_action);
    const find_action = makeAction(edit_menu, "Find Files", "Ctrl+Shift+F", onFocusGlobalSearch);
    edit_menu.addAction(find_action);
    _ = edit_menu.addSeparator();
    const cancel_op_action = makeAction(edit_menu, "Cancel Operation", "Escape", onCancelOperation);
    edit_menu.addAction(cancel_op_action);

    const view_menu = QMenu.new4("&View", window);
    _ = menubar.addMenu(view_menu);
    const reload_action = makeAction(view_menu, "Reload", "F5", onReloadAction);
    view_menu.addAction(reload_action);
    const hidden_action = makeAction(view_menu, "Show Hidden Files", "Ctrl+H", onToggleHidden);
    hidden_action.setCheckable(true);
    view_menu.addAction(hidden_action);
    _ = view_menu.addSeparator();
    const split_action = makeAction(view_menu, "Split View", "F3", onToggleSplit);
    split_action.setCheckable(true);
    view_menu.addAction(split_action);
    const focus_other_action = makeAction(view_menu, "Focus Other Pane", "F6", onFocusOtherPane);
    view_menu.addAction(focus_other_action);
    _ = view_menu.addSeparator();
    const terminal_action = makeAction(view_menu, "Terminal Panel", "F12", onToggleTerminal);
    terminal_action.setCheckable(true);
    view_menu.addAction(terminal_action);
    const player_action = makeAction(view_menu, "Music Player", "F9", onTogglePlayer);
    player_action.setCheckable(true);
    view_menu.addAction(player_action);
    search_dock.toggleViewAction().setText("Search Results");
    view_menu.addAction(search_dock.toggleViewAction());
    const rebuild_index_action = makeAction(view_menu, "Rebuild Search Index", null, onRebuildIndex);
    view_menu.addAction(rebuild_index_action);

    const go_menu = QMenu.new4("&Go", window);
    _ = menubar.addMenu(go_menu);
    const back_action = makeAction(go_menu, "Back", "Alt+Left", onBackAction);
    const forward_action = makeAction(go_menu, "Forward", "Alt+Right", onForwardAction);
    const up_action = makeAction(go_menu, "Up", "Alt+Up", onUpAction);
    const home_action = makeAction(go_menu, "Home", "Alt+Home", onHomeAction);
    go_menu.addAction(back_action);
    go_menu.addAction(forward_action);
    go_menu.addAction(up_action);
    _ = go_menu.addSeparator();
    go_menu.addAction(home_action);

    const help_menu = QMenu.new4("&Help", window);
    _ = menubar.addMenu(help_menu);
    const about_action = makeAction(help_menu, "About Ligma", null, onAbout);
    help_menu.addAction(about_action);

    // Context menus for the file list and the Places panel. They are created
    // once and popped up on demand; their actions read the active pane and
    // the right-clicked place row.
    const tree_menu = QMenu.new(window);
    const ctx_open_action = tree_menu.addAction2("&Open");
    ctx_open_action.onTriggered(onCtxOpen);
    const ctx_play_action = tree_menu.addAction2("&Play");
    ctx_play_action.onTriggered(onCtxPlay);
    const ctx_playlist_action = tree_menu.addAction2("Add to &Playlist");
    ctx_playlist_action.onTriggered(onCtxAddToPlaylist);
    _ = tree_menu.addSeparator();
    const ctx_terminal_action = tree_menu.addAction2("Open in &Terminal");
    ctx_terminal_action.onTriggered(onCtxOpenInTerminal);
    _ = tree_menu.addSeparator();
    const ctx_cut_action = tree_menu.addAction2("C&ut");
    ctx_cut_action.onTriggered(onCut);
    const ctx_copy_action = tree_menu.addAction2("&Copy");
    ctx_copy_action.onTriggered(onCopy);
    const ctx_paste_action = tree_menu.addAction2("&Paste");
    ctx_paste_action.onTriggered(onPaste);
    _ = tree_menu.addSeparator();
    const ctx_new_folder_action = tree_menu.addAction2("New &Folder…");
    ctx_new_folder_action.onTriggered(onNewFolder);
    _ = tree_menu.addSeparator();
    const ctx_properties_action = tree_menu.addAction2("P&roperties");
    ctx_properties_action.onTriggered(onProperties);
    _ = tree_menu.addSeparator();
    const ctx_trash_action = tree_menu.addAction2("Move to Tra&sh");
    ctx_trash_action.onTriggered(onTrashSelected);
    const ctx_delete_action = tree_menu.addAction2("&Delete Permanently");
    ctx_delete_action.onTriggered(onDeleteSelected);
    _ = tree_menu.addSeparator();
    const ctx_add_places_action = tree_menu.addAction2("&Add to Places");
    ctx_add_places_action.onTriggered(onCtxAddToPlaces);
    const places_menu = QMenu.new(window);
    const ctx_remove_place_action = places_menu.addAction2("Remove from Places");
    ctx_remove_place_action.onTriggered(onCtxRemovePlace);

    // ---- Shared state ----------------------------------------------------
    app = .{
        .gpa = init.gpa,
        .io = init.io,
        .qapp = qapp,
        .window = window,
        .tabs = tabs,
        .main_splitter = main_splitter,
        .places = places,
        .status = status,
        .count_label = count_label,
        .preview = preview_panel,
        .terminal_dock = terminal_dock,
        .terminal_widget = terminal_widget,
        .terminal_action = terminal_action,
        .player_dock = player_dock,
        .player = player_panel,
        .player_action = player_action,
        .tree_menu = tree_menu,
        .places_menu = places_menu,
        .ctx_open_action = ctx_open_action,
        .ctx_play_action = ctx_play_action,
        .ctx_playlist_action = ctx_playlist_action,
        .ctx_cut_action = ctx_cut_action,
        .ctx_copy_action = ctx_copy_action,
        .ctx_paste_action = ctx_paste_action,
        .ctx_new_folder_action = ctx_new_folder_action,
        .ctx_properties_action = ctx_properties_action,
        .ctx_trash_action = ctx_trash_action,
        .ctx_delete_action = ctx_delete_action,
        .ctx_add_places_action = ctx_add_places_action,
        .ctx_remove_place_action = ctx_remove_place_action,
        .global_search = global_search,
        .search_dock = search_dock,
        .search_list = search_list,
        .search_timer = search_timer,
        .index_label = index_label,
        .index_timer = index_timer,
        .file_timer = file_timer,
        .model_timer = model_timer,
        .back_action = back_action,
        .forward_action = forward_action,
        .split_action = split_action,
        .hidden_action = hidden_action,
        .undo_action = undo_action,
    };

    addPlace("Home", home);
    addChildPlace(home, "Desktop");
    addChildPlace(home, "Documents");
    addChildPlace(home, "Downloads");
    addChildPlace(home, "Music");
    addChildPlace(home, "Pictures");
    addChildPlace(home, "Videos");
    addPlace("Filesystem", "/");
    app.place_builtin_count = app.place_paths.items.len;
    loadCustomPlaces();

    places.setContextMenuPolicy(qnamespace_enums.ContextMenuPolicy.CustomContextMenu);
    places.onCustomContextMenuRequested(onPlacesContextMenu);
    places.onCurrentRowChanged(onPlaceSelected);
    terminal_dock.onVisibilityChanged(onTerminalVisibilityChanged);
    player_dock.onVisibilityChanged(onPlayerVisibilityChanged);
    tabs.onCurrentChanged(onTabChanged);
    tabs.onTabCloseRequested(onTabCloseRequested);
    qapp.onFocusChanged(onFocusChanged);
    search_list.onItemActivated(onSearchActivated);
    global_search.onReturnPressed(onSearchReturn);
    search_timer.onTimeout(onSearchTimer);
    index_timer.onTimeout(onIndexTimer);
    file_timer.onTimeout(onFileTimer);
    model_timer.onTimeout(onModelTimer);

    const first_tab = createTab(home);
    window.show();
    model_timer.start(50);
    initSearchIndex(home);
    if (first_tab.panes[0]) |pane| pane.tree.setFocus();

    _ = QApplication.exec();

    shutdown();
}

fn shutdown() void {
    // Stop playback and release QtMultimedia before the window disappears.
    app.player.deinit();

    // Stop any in-flight thumbnail extraction before other teardown.
    app.preview.deinit();

    // Deleting the terminal widget closes its PTY and ends the shell before
    // the QApplication and window are torn down.
    terminal_mod.shutdown(app.terminal_widget);

    cancelIndexBuild();

    app.model_timer.stop();
    app.file_timer.stop();
    if (app.file_job) |job| {
        job.requestCancel();
        job.deinit();
        app.file_job = null;
    }
    for (app.undo_stack.items) |*batch| freeUndoBatch(batch);
    app.undo_stack.deinit(app.gpa);
    clearClipboard();
    app.clip_paths.deinit(app.gpa);
    if (app.index_reader) |*reader| {
        reader.deinit();
        app.index_reader = null;
    }
    if (app.index_path) |path| {
        app.gpa.free(path);
        app.index_path = null;
    }

    if (app.search_job) |job| {
        job.requestCancel();
        job.deinit();
        app.search_job = null;
    }
    app.search_timer.stop();

    if (app.search_query) |query| app.gpa.free(query);
    for (app.search_paths.items) |path| app.gpa.free(path);
    app.search_paths.deinit(app.gpa);

    for (app.panes_list.items) |pane| {
        pane.model.destroy();
        for (pane.history.items) |path| app.gpa.free(path);
        pane.history.deinit(app.gpa);
        if (pane.current_path) |path| app.gpa.free(path);
        app.gpa.destroy(pane);
    }
    app.panes_list.deinit(app.gpa);

    for (app.tabs_list.items) |tab| app.gpa.destroy(tab);
    app.tabs_list.deinit(app.gpa);

    for (app.place_paths.items) |path| app.gpa.free(path);
    app.place_paths.deinit(app.gpa);
}

// ---- Tabs and panes ------------------------------------------------------

fn createTab(initial_path: []const u8) *Tab {
    const tab = app.gpa.create(Tab) catch @panic("Out of memory creating tab");
    const splitter = QSplitter.new2();
    splitter.setChildrenCollapsible(false);
    splitter.setHandleWidth(1);

    tab.* = .{ .splitter = splitter };
    app.tabs_list.append(app.gpa, tab) catch @panic("Out of memory creating tab");

    const pane = createPane(tab, initial_path);
    tab.panes[0] = pane;
    tab.pane_count = 1;

    const index = app.tabs.addTab(splitter, "Home");
    app.tabs.setCurrentIndex(index);
    updateTabTitle(tab);
    setActivePane(pane);
    return tab;
}

fn createPane(tab: *Tab, initial_path: []const u8) *Pane {
    const container = QWidget.new2();
    const layout = QVBoxLayout.new(container);
    layout.setContentsMargins(6, 6, 6, 6);
    layout.setSpacing(6);

    const nav = QHBoxLayout.new2();
    nav.setSpacing(4);
    layout.addLayout(nav);

    const path_edit = QLineEdit.new2();
    path_edit.setClearButtonEnabled(true);
    path_edit.setPlaceholderText("Path — type a location and press Enter");
    path_edit.onReturnPressed(onPathEntered);
    nav.addWidget(path_edit);
    nav.setStretch(0, 3);

    const search_edit = QLineEdit.new2();
    search_edit.setClearButtonEnabled(true);
    search_edit.setPlaceholderText("Filter this folder");
    search_edit.onTextChanged(onFilterChanged);
    nav.addWidget(search_edit);
    nav.setStretch(1, 2);

    const tree = QTreeView.new(container);
    tree.setAlternatingRowColors(true);
    tree.setUniformRowHeights(true);
    tree.setSortingEnabled(true);
    tree.setRootIsDecorated(false);
    tree.setItemsExpandable(false);
    tree.setExpandsOnDoubleClick(false);
    tree.setSelectionBehavior(qabstractitemview_enums.SelectionBehavior.SelectRows);
    tree.setSelectionMode(qabstractitemview_enums.SelectionMode.ExtendedSelection);
    tree.setDragEnabled(true);
    tree.setAcceptDrops(true);
    tree.setDropIndicatorShown(true);
    tree.setDragDropMode(qabstractitemview_enums.DragDropMode.DragDrop);
    tree.setDefaultDropAction(qnamespace_enums.DropAction.MoveAction);
    tree.setDragDropOverwriteMode(false);
    tree.setColumnWidth(0, 460);
    tree.setColumnWidth(1, 110);
    tree.setColumnWidth(2, 170);
    tree.setColumnWidth(3, 190);

    const model = local_model.LocalModel.create(app.gpa, app.io, container) catch
        @panic("Out of memory creating model");
    model.setShowHidden(app.show_hidden);
    model.setDropHandler(onModelDrop);
    tree.setModel(model.qt);
    tree.sortByColumn(0, qnamespace_enums.SortOrder.AscendingOrder);

    const selection = tree.selectionModel();

    const pane = app.gpa.create(Pane) catch @panic("Out of memory creating pane");
    pane.* = .{
        .tab = tab,
        .container = container,
        .tree = tree,
        .model = model,
        .path_edit = path_edit,
        .search_edit = search_edit,
        .selection = selection,
    };
    app.panes_list.append(app.gpa, pane) catch @panic("Out of memory creating pane");

    tree.onClicked(onTreeClicked);
    tree.onActivated(onItemActivated);
    tree.onMousePressEvent(onTreeMousePress);
    tree.setContextMenuPolicy(qnamespace_enums.ContextMenuPolicy.CustomContextMenu);
    tree.onCustomContextMenuRequested(onTreeContextMenu);
    selection.onCurrentChanged(onSelectionChanged);
    selection.onSelectionChanged(onSelectionModelChanged);

    layout.addWidget(tree);
    layout.setStretch(1, 1);
    tab.splitter.addWidget(container);

    navigateTo(pane, initial_path, true);
    return pane;
}

fn destroyPaneData(pane: *Pane) void {
    pane.model.destroy();
    for (pane.history.items) |path| app.gpa.free(path);
    pane.history.deinit(app.gpa);
    if (pane.current_path) |path| app.gpa.free(path);

    for (app.panes_list.items, 0..) |item, index| {
        if (item == pane) {
            _ = app.panes_list.orderedRemove(index);
            break;
        }
    }
    app.gpa.destroy(pane);
}

fn closeTab(index: i32) void {
    if (index < 0) return;
    const pos: usize = @intCast(index);
    if (pos >= app.tabs_list.items.len) return;

    const tab = app.tabs_list.items[pos];

    app.tabs_updating = true;
    app.tabs.removeTab(index);
    _ = app.tabs_list.orderedRemove(pos);
    app.tabs_updating = false;

    for (tab.panes) |maybe_pane| {
        if (maybe_pane) |pane| destroyPaneData(pane);
    }
    tab.splitter.delete();
    app.gpa.destroy(tab);

    if (app.tabs_list.items.len == 0) {
        _ = app.window.close();
        return;
    }

    const current = activeTab() orelse return;
    const pane = current.panes[current.active] orelse current.panes[0] orelse return;
    setActivePane(pane);
    pane.tree.setFocus();
}

fn newTab() void {
    const current = activePane();
    const path = if (current) |pane| (pane.current_path orelse "/") else "/";
    const tab = createTab(path);
    if (tab.panes[tab.active]) |pane| pane.tree.setFocus();
}

fn toggleSplit() void {
    const tab = activeTab() orelse return;

    if (!tab.split_visible) {
        if (tab.panes[1] == null) {
            const active = tab.panes[tab.active] orelse tab.panes[0] orelse return;
            const path = active.current_path orelse "/";
            tab.panes[1] = createPane(tab, path);
            tab.pane_count = 2;
        }
        if (tab.panes[1]) |pane| pane.container.show();
        tab.split_visible = true;
        var sizes = [_]i32{ 1, 1 };
        tab.splitter.setSizes(&sizes);
    } else {
        if (tab.active == 1) {
            tab.active = 0;
            if (tab.panes[0]) |pane| {
                setActivePane(pane);
                pane.tree.setFocus();
            }
        }
        if (tab.panes[1]) |pane| pane.container.hide();
        tab.split_visible = false;
    }

    if (app.split_action) |action| action.setChecked(tab.split_visible);
    updateTabTitle(tab);
}

fn focusOtherPane() void {
    const tab = activeTab() orelse return;
    if (!tab.split_visible) return;
    const other: u8 = if (tab.active == 0) 1 else 0;
    if (tab.panes[other]) |pane| {
        setActivePane(pane);
        pane.tree.setFocus();
    }
}

fn activeTab() ?*Tab {
    const index = app.tabs.currentIndex();
    if (index < 0) return null;
    const pos: usize = @intCast(index);
    if (pos >= app.tabs_list.items.len) return null;
    return app.tabs_list.items[pos];
}

fn activePane() ?*Pane {
    const tab = activeTab() orelse return null;
    return tab.panes[tab.active] orelse tab.panes[0];
}

fn tabIndex(tab: *Tab) i32 {
    for (app.tabs_list.items, 0..) |item, index| {
        if (item == tab) return @intCast(index);
    }
    return -1;
}

fn isActivePane(pane: *Pane) bool {
    return activePane() == pane;
}

fn setActivePane(pane: *Pane) void {
    const index = tabIndex(pane.tab);
    if (index >= 0 and app.tabs.currentIndex() != index and index < app.tabs.count()) {
        app.tabs.setCurrentIndex(index);
    }

    pane.tab.active = if (pane.tab.panes[1] == pane) 1 else 0;
    updateHistoryActions();
    refreshCount(pane);
    refreshPreview(pane);
    updateWindowTitle();
    updateTabTitle(pane.tab);
}

/// Feeds the bottom-left preview panel with the pane's current selection.
/// The panel itself hides when the selection is not exactly one image or
/// video file. The item is the selected row — not currentIndex(), which Qt
/// may move ahead of the selection (Shift+arrow extension).
fn refreshPreview(pane: *Pane) void {
    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);
    if (rows.len == 1 and rows[0].isValid()) {
        const index = rows[0];
        if (!pane.model.isDir(index)) {
            const path = pane.model.pathAt(app.gpa, index);
            defer app.gpa.free(path);
            if (path.len > 0) {
                const name = pane.model.nameAt(app.gpa, index);
                defer app.gpa.free(name);
                const size = pane.model.sizeAt(index);
                app.preview.showItem(path, name, size);
                return;
            }
        }
    }
    app.preview.hide();
}

fn updateTabTitle(tab: *Tab) void {
    const index = tabIndex(tab);
    if (index < 0 or index >= app.tabs.count()) return;

    const pane = tab.panes[tab.active] orelse tab.panes[0] orelse return;
    const path = pane.current_path orelse return;
    const name = if (std.mem.eql(u8, path, "/")) "/" else std.fs.path.basename(path);

    if (tab.split_visible) {
        const title = std.fmt.allocPrint(app.gpa, "◧ {s}", .{name}) catch name;
        defer if (title.ptr != name.ptr) app.gpa.free(title);
        app.tabs.setTabText(index, title);
    } else {
        app.tabs.setTabText(index, name);
    }
    app.tabs.setTabToolTip(index, path);
}

// ---- Navigation ----------------------------------------------------------

fn navigateTo(pane: *Pane, raw: []const u8, record_history: bool) void {
    const cwd = pane.current_path orelse "/";
    const resolved = paths.resolve(app.gpa, cwd, raw) catch {
        showStatus("Cannot resolve that location", 2500);
        return;
    };
    defer app.gpa.free(resolved);

    const dir = QDir.new4(resolved);
    defer dir.delete();
    if (!dir.exists()) {
        showStatus("No such folder — check the path and try again", 3000);
        return;
    }

    setRoot(pane, resolved);
    if (record_history) pushHistory(pane, resolved);
}

fn setRoot(pane: *Pane, path: []const u8) void {
    // Every navigation starts unfiltered. The flag prevents the textChanged
    // signal from re-entering through onFilterChanged.
    app.suppress_filter = true;
    pane.search_edit.clear();
    app.suppress_filter = false;
    pane.model.setFilter("");

    pane.tree.clearSelection();
    pane.model.load(path);

    if (pane.current_path) |old| app.gpa.free(old);
    pane.current_path = app.gpa.dupe(u8, path) catch null;

    pane.path_edit.setText(path);
    if (isActivePane(pane)) {
        app.status.clearMessage();
        refreshCount(pane);
        updateWindowTitle();
    }
    updateTabTitle(pane.tab);
    updateHistoryActions();
}

fn refreshRoot(pane: *Pane) void {
    if (pane.current_path == null) return;
    pane.model.reload();
    if (isActivePane(pane)) refreshCount(pane);
}

fn onModelTimer(_: QTimer) callconv(.c) void {
    for (app.panes_list.items) |pane| {
        switch (pane.model.poll()) {
            .none => {},
            .updated => {
                // Applying a snapshot resets the model, and a model reset
                // clears the selection model without emitting any signal.
                if (isActivePane(pane)) refreshPreview(pane);
                if (isActivePane(pane)) refreshCount(pane);
            },
            .failed => {
                if (isActivePane(pane)) {
                    var buffer: [1024]u8 = undefined;
                    const message = std.fmt.bufPrint(
                        &buffer,
                        "Cannot open this folder: {s}",
                        .{pane.model.lastError()},
                    ) catch "Cannot open this folder";
                    showStatus(message, 4000);
                    refreshCount(pane);
                }
            },
        }
    }
}

fn pushHistory(pane: *Pane, path: []const u8) void {
    while (pane.history.items.len > pane.history_index + 1) {
        if (pane.history.pop()) |old| app.gpa.free(old);
    }

    const copy = app.gpa.dupe(u8, path) catch return;
    pane.history.append(app.gpa, copy) catch {
        app.gpa.free(copy);
        return;
    };
    pane.history_index = pane.history.items.len - 1;
    updateHistoryActions();
}

fn updateHistoryActions() void {
    const pane = activePane();
    if (app.back_action) |action| {
        action.setEnabled(if (pane) |p| p.history_index > 0 else false);
    }
    if (app.forward_action) |action| {
        action.setEnabled(if (pane) |p| p.history_index + 1 < p.history.items.len else false);
    }
}

fn goBack(pane: *Pane) void {
    if (pane.history_index == 0) return;
    pane.history_index -= 1;
    setRoot(pane, pane.history.items[pane.history_index]);
    updateHistoryActions();
}

fn goForward(pane: *Pane) void {
    if (pane.history_index + 1 >= pane.history.items.len) return;
    pane.history_index += 1;
    setRoot(pane, pane.history.items[pane.history_index]);
    updateHistoryActions();
}

fn goUp(pane: *Pane) void {
    const current = pane.current_path orelse return;
    if (std.mem.eql(u8, current, "/")) return;
    const parent = std.fs.path.dirname(current) orelse "/";
    navigateTo(pane, parent, true);
}

fn goHome(pane: *Pane) void {
    const home = QDir.homePath(app.gpa);
    defer app.gpa.free(home);
    navigateTo(pane, home, true);
}

fn reloadPane(pane: *Pane) void {
    if (pane.current_path == null) return;
    pane.model.reload();
    if (isActivePane(pane)) refreshCount(pane);
}

fn applyFilter(pane: *Pane, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    pane.model.setFilter(trimmed);
    if (isActivePane(pane)) refreshCount(pane);
}

fn refreshCount(pane: *Pane) void {
    const count = pane.model.count();
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{d} item{s}",
        .{ count, if (count == 1) "" else "s" },
    ) catch "Items";
    app.count_label.setText(message);
}

fn updateWindowTitle() void {
    const pane = activePane() orelse {
        app.window.setWindowTitle("Ligma");
        return;
    };
    const path = pane.current_path orelse {
        app.window.setWindowTitle("Ligma");
        return;
    };

    var buffer: [8192]u8 = undefined;
    const title = std.fmt.bufPrint(&buffer, "{s} — Ligma", .{path}) catch "Ligma";
    app.window.setWindowTitle(title);
}

fn showStatus(message: []const u8, timeout_ms: i32) void {
    app.status.showMessage2(message, timeout_ms);
}

fn showPlayer() void {
    app.player_dock.show();
    app.player_dock.raise();
}

fn showStatusForPath(verb: []const u8, path: []const u8) void {
    var buffer: [512]u8 = undefined;
    const name = std.fs.path.basename(path);
    const message = std.fmt.bufPrint(&buffer, "{s} “{s}”", .{ verb, name }) catch verb;
    showStatus(message, 3000);
}

fn selectedPath(pane: *Pane, index: QModelIndex) ?[]const u8 {
    if (!index.isValid()) return null;
    return pane.model.pathAt(app.gpa, index);
}

fn openSelected(pane: *Pane, index: QModelIndex) void {
    const path = selectedPath(pane, index) orelse return;
    defer app.gpa.free(path);

    if (pane.model.isDir(index)) {
        navigateTo(pane, path, true);
        return;
    }

    // Audio is played in the built-in player rather than handed to the
    // desktop opener, which may start a separate application.
    if (player_mod.isAudioFile(app.gpa, path)) {
        app.player.playPath(path);
        showPlayer();
        showStatusForPath("Playing", path);
        return;
    }

    // Executables are launched directly instead of being handed to the
    // desktop opener, which usually forces an editor or archive tool.
    if (isExecutableFile(path)) {
        runExecutable(path);
        return;
    }

    const url = QUrl.fromLocalFile(path);
    defer url.delete();
    if (!QDesktopServices.openUrl(url))
        showStatus("No application is registered to open this file", 3500);
}

fn isExecutableFile(path: []const u8) bool {
    const info = QFileInfo.new2(path);
    defer info.delete();
    return info.isFile() and info.isExecutable();
}

fn runExecutable(path: []const u8) void {
    const info = QFileInfo.new2(path);
    defer info.delete();
    if (!info.isFile() or !info.isExecutable()) {
        showStatus("That item is not an executable file", 3000);
        return;
    }

    const name = std.fs.path.basename(path);
    const message = std.fmt.allocPrint(
        app.gpa,
        "Run “{s}”?\n\nOnly run files you trust.",
        .{name},
    ) catch "Run this executable? Only run files you trust.";
    defer app.gpa.free(message);

    const answer = QMessageBox.question2(
        app.window,
        "Run Executable",
        message,
        qmessagebox_enums.StandardButton.Yes,
        qmessagebox_enums.StandardButton.No,
    );
    if (answer != qmessagebox_enums.StandardButton.Yes) return;

    const working_dir = std.fs.path.dirname(path) orelse "/";
    const arguments: []const []const u8 = &.{};
    if (!QProcess.startDetached3(app.gpa, path, arguments, working_dir)) {
        showStatus("Could not start the executable", 3500);
        return;
    }

    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "Started {s}", .{name}) catch "Started executable";
    showStatus(text, 3000);
}

fn onRunSelected(_: QAction) callconv(.c) void {
    const pane = activePane() orelse return;
    const index = pane.selection.currentIndex();
    if (!index.isValid()) {
        showStatus("Select an executable file first", 2500);
        return;
    }

    const path = pane.model.pathAt(app.gpa, index);
    defer app.gpa.free(path);
    if (!isExecutableFile(path)) {
        showStatus("The selected item is not an executable file", 3000);
        return;
    }
    runExecutable(path);
}

// ---- File operations -----------------------------------------------------

fn collectSelectedPaths(pane: *Pane) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| app.gpa.free(path);
        result.deinit(app.gpa);
    }

    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);

    for (rows) |index| {
        if (!index.isValid()) continue;
        const path = pane.model.pathAt(app.gpa, index);
        errdefer app.gpa.free(path);
        if (path.len == 0) {
            app.gpa.free(path);
            continue;
        }
        try result.append(app.gpa, path);
    }

    // Some Qt views move the current row with Home/End without marking it as
    // selected. Treat a valid current row in this folder as the target so
    // keyboard-only users are not told the selection is empty.
    if (result.items.len == 0) {
        const current = pane.selection.currentIndex();
        if (current.isValid()) {
            const path = pane.model.pathAt(app.gpa, current);
            errdefer app.gpa.free(path);
            const root = pane.current_path orelse "";
            const parent = std.fs.path.dirname(path) orelse "/";
            if (path.len > 0 and std.mem.eql(u8, parent, root)) {
                try result.append(app.gpa, path);
            } else {
                app.gpa.free(path);
            }
        }
    }
    return result;
}

fn freePathList(list: *std.ArrayList([]const u8)) void {
    for (list.items) |path| app.gpa.free(path);
    list.deinit(app.gpa);
}

fn freeUndoBatch(batch: *UndoBatch) void {
    for (batch.items) |*item| item.deinit(app.gpa);
    batch.deinit(app.gpa);
}

fn clearClipboard() void {
    for (app.clip_paths.items) |path| app.gpa.free(path);
    app.clip_paths.clearRetainingCapacity();
    app.clip_mode = .none;
}

fn updateUndoAction() void {
    if (app.undo_action) |action| {
        action.setEnabled(app.undo_stack.items.len > 0 and app.file_job == null);
    }
}

fn startFileJob(job: *file_ops.Job, clear_cut_clipboard: bool) bool {
    if (app.file_job != null) {
        job.deinit();
        showStatus("Finish or cancel the current operation first", 3500);
        return false;
    }

    job.start() catch {
        job.deinit();
        showStatus("Could not start the file operation", 3500);
        return false;
    };

    app.file_job = job;
    app.file_job_clears_clipboard = clear_cut_clipboard;
    app.file_timer.start(150);
    updateUndoAction();
    showStatus(job.kind.verb(), 0);
    return true;
}

fn cancelCurrentFileJob() void {
    const job = app.file_job orelse {
        showStatus("No file operation is running", 2500);
        return;
    };
    job.requestCancel();
    showStatus("Cancelling the operation…", 0);
}

fn refreshAllPanes() void {
    for (app.panes_list.items) |pane| refreshRoot(pane);
}

fn onFileTimer(_: QTimer) callconv(.c) void {
    const job = app.file_job orelse {
        app.file_timer.stop();
        updateUndoAction();
        return;
    };
    const progress = job.progress();

    if (progress.state == .pending or progress.state == .running) {
        var buffer: [256]u8 = undefined;
        var size_buffer: [32]u8 = undefined;
        const text = if (progress.entries > 0)
            std.fmt.bufPrint(
                &buffer,
                "{s}… {d} entries, {s}",
                .{ job.kind.verb(), progress.entries, formatBytes(&size_buffer, progress.bytes) },
            ) catch job.kind.verb()
        else if (progress.items > 0)
            std.fmt.bufPrint(
                &buffer,
                "{s}… {d} item{s}",
                .{ job.kind.verb(), progress.items, if (progress.items == 1) "" else "s" },
            ) catch job.kind.verb()
        else
            job.kind.verb();
        app.status.showMessage(text);
        return;
    }

    app.file_timer.stop();
    job.join();

    const kind = job.kind;
    const clear_cut_clipboard = app.file_job_clears_clipboard;
    var undo = job.takeUndo();

    var status_buffer: [1200]u8 = undefined;
    var message: []const u8 = undefined;
    switch (progress.state) {
        .failed => {
            const detail = if (progress.error_message.len > 0)
                progress.error_message
            else
                "unknown error";
            message = std.fmt.bufPrint(
                &status_buffer,
                "{s} failed: {s}",
                .{ kind.verb(), detail },
            ) catch "File operation failed";
        },
        .cancelled => {
            message = if (progress.items > 0)
                std.fmt.bufPrint(
                    &status_buffer,
                    "{s} cancelled after {d} item{s}",
                    .{ kind.verb(), progress.items, if (progress.items == 1) "" else "s" },
                ) catch "Operation cancelled"
            else
                "Operation cancelled";
        },
        else => {
            if (progress.failures > 0) {
                const detail = if (progress.error_message.len > 0)
                    progress.error_message
                else
                    "unknown error";
                message = std.fmt.bufPrint(
                    &status_buffer,
                    "{s} {d} item{s} — {d} error{s}: {s}",
                    .{
                        kind.doneVerb(),
                        progress.items,
                        if (progress.items == 1) "" else "s",
                        progress.failures,
                        if (progress.failures == 1) "" else "s",
                        detail,
                    },
                ) catch "File operation finished with errors";
            } else {
                const undoable = undo.items.len > 0 and kind != .undo;
                message = std.fmt.bufPrint(
                    &status_buffer,
                    "{s} {d} item{s}{s}",
                    .{
                        kind.doneVerb(),
                        progress.items,
                        if (progress.items == 1) "" else "s",
                        if (undoable) " — Ctrl+Z to undo" else "",
                    },
                ) catch "File operation finished";
            }
        },
    }

    if (undo.items.len > 0) {
        app.undo_stack.append(app.gpa, undo) catch freeUndoBatch(&undo);
    } else {
        freeUndoBatch(&undo);
    }

    job.deinit();
    app.file_job = null;
    app.file_job_clears_clipboard = false;

    if (clear_cut_clipboard) clearClipboard();
    refreshAllPanes();
    updateUndoAction();
    showStatus(message, 6000);
}

fn formatBytes(buffer: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "0 B";

    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit < units.len) : (unit += 1) {
        value /= 1024.0;
    }
    // The loop overshoots by one on exit because it divides before advancing.
    if (unit > 0) unit -= 1;
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "0 B";
}

fn onNewFolder(_: QAction) callconv(.c) void {
    const pane = activePane() orelse return;
    const parent = pane.current_path orelse return;

    var ok = false;
    const raw = QInputDialog.getText6(
        app.gpa,
        app.window,
        "New Folder",
        "Folder name:",
        qlineedit_enums.EchoMode.Normal,
        "New Folder",
        &ok,
    );
    defer app.gpa.free(raw);
    if (!ok) {
        pane.tree.setFocus();
        return;
    }

    const name = std.mem.trim(u8, raw, " \t\r\n");
    if (!file_ops.isValidName(name)) {
        showStatus("That folder name is not valid", 3500);
        return;
    }

    const job = file_ops.Job.createMkdir(app.gpa, app.io, parent, name) catch {
        showStatus("Could not create the folder", 3500);
        return;
    };
    _ = startFileJob(job, false);
}

fn onRename(_: QAction) callconv(.c) void {
    const pane = activePane() orelse return;
    const index = pane.selection.currentIndex();
    if (!index.isValid()) {
        showStatus("Select an item to rename", 2500);
        return;
    }

    const path = pane.model.pathAt(app.gpa, index);
    defer app.gpa.free(path);
    const old_name = std.fs.path.basename(path);

    var ok = false;
    const raw = QInputDialog.getText6(
        app.gpa,
        app.window,
        "Rename",
        "New name:",
        qlineedit_enums.EchoMode.Normal,
        old_name,
        &ok,
    );
    defer app.gpa.free(raw);
    if (!ok) {
        pane.tree.setFocus();
        return;
    }

    const new_name = std.mem.trim(u8, raw, " \t\r\n");
    if (!file_ops.isValidName(new_name)) {
        showStatus("That name is not valid", 3500);
        return;
    }
    if (std.mem.eql(u8, new_name, old_name)) return;

    const job = file_ops.Job.createRename(app.gpa, app.io, path, new_name) catch {
        showStatus("Could not rename the item", 3500);
        return;
    };
    _ = startFileJob(job, false);
}

fn onTrashSelected(_: QAction) callconv(.c) void {
    const pane = activePane() orelse return;
    var selected = collectSelectedPaths(pane) catch {
        showStatus("Could not read the selection", 3500);
        return;
    };
    if (selected.items.len == 0) {
        freePathList(&selected);
        showStatus("Select items to move to Trash", 2500);
        return;
    }
    defer freePathList(&selected);

    const job = file_ops.Job.createTrash(app.gpa, app.io, selected.items) catch {
        showStatus("Could not start the Trash operation", 3500);
        return;
    };
    _ = startFileJob(job, false);
}

fn onDeleteSelected(_: QAction) callconv(.c) void {
    const pane = activePane() orelse return;
    var selected = collectSelectedPaths(pane) catch {
        showStatus("Could not read the selection", 3500);
        return;
    };
    if (selected.items.len == 0) {
        freePathList(&selected);
        showStatus("Select items to delete", 2500);
        return;
    }
    defer freePathList(&selected);

    const message = if (selected.items.len == 1)
        std.fmt.allocPrint(
            app.gpa,
            "Permanently delete “{s}”? This cannot be undone.",
            .{std.fs.path.basename(selected.items[0])},
        ) catch "Permanently delete the selected item? This cannot be undone."
    else
        std.fmt.allocPrint(
            app.gpa,
            "Permanently delete {d} items? This cannot be undone.",
            .{selected.items.len},
        ) catch "Permanently delete the selected items? This cannot be undone.";
    defer app.gpa.free(message);

    const answer = QMessageBox.question2(
        app.window,
        "Delete Permanently",
        message,
        qmessagebox_enums.StandardButton.Yes,
        qmessagebox_enums.StandardButton.No,
    );
    if (answer != qmessagebox_enums.StandardButton.Yes) return;

    const job = file_ops.Job.createDelete(app.gpa, app.io, selected.items) catch {
        showStatus("Could not start the delete operation", 3500);
        return;
    };
    _ = startFileJob(job, false);
}

fn onProperties(_: QAction) callconv(.c) void {
    const pane = app.context_pane orelse activePane() orelse return;

    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);

    var single: [1]QModelIndex = undefined;
    const targets: []const QModelIndex = if (rows.len > 0) rows else blk: {
        // Keep keyboard-only use working: a valid current row that is not
        // marked selected still describes a single item.
        const current = pane.selection.currentIndex();
        if (!current.isValid()) break :blk &.{};
        single[0] = current;
        break :blk single[0..1];
    };
    if (targets.len == 0) {
        showStatus("Select an item to show its properties", 2500);
        return;
    }
    if (targets.len == 1 and pane.model.entryAt(targets[0]) == null) {
        showStatus("That item is no longer available", 2500);
        return;
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(app.gpa);

    if (targets.len == 1) {
        appendSingleProperties(&text, pane, targets[0]) catch return;
    } else {
        appendMultiProperties(&text, pane, targets) catch return;
    }

    _ = QMessageBox.information(app.window, "Properties", text.items);
}

fn appendProperties(list: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(app.gpa, format, args);
    defer app.gpa.free(line);
    try list.appendSlice(app.gpa, line);
}

fn appendSingleProperties(list: *std.ArrayList(u8), pane: *Pane, index: QModelIndex) !void {
    const entry = pane.model.entryAt(index) orelse return;
    const name = pane.model.nameAt(app.gpa, index);
    defer app.gpa.free(name);
    const path = pane.model.pathAt(app.gpa, index);
    defer app.gpa.free(path);

    const info = QFileInfo.new2(path);
    defer info.delete();

    const kind = if (entry.is_symlink)
        (if (entry.is_dir) "Folder link" else "Symbolic link")
    else if (entry.is_dir)
        "Folder"
    else
        "File";

    var size_buffer: [64]u8 = undefined;
    var amount_buffer: [64]u8 = undefined;
    const size_text = if (entry.is_dir)
        "—"
    else
        std.fmt.bufPrint(
            &size_buffer,
            "{s} ({d} bytes)",
            .{ formatBytes(&amount_buffer, entry.size), entry.size },
        ) catch "—";

    const location = std.fs.path.dirname(path) orelse "/";
    const permissions = permissionsString(info.permissions());

    try appendProperties(list, "Name: {s}\n", .{name});
    try appendProperties(list, "Kind: {s}\n", .{kind});
    try appendProperties(list, "Size: {s}\n", .{size_text});
    try appendProperties(list, "Location: {s}\n", .{location});
    try appendProperties(list, "Modified: {s}\n", .{local_model.formatModified(entry.mtime)});
    try appendProperties(list, "Permissions: {s}\n", .{permissions[0..]});

    if (info.isSymLink()) {
        const target = info.symLinkTarget(app.gpa);
        defer app.gpa.free(target);
        try appendProperties(list, "Link target: {s}\n", .{target});
    }

    // QMessageBox adds its own padding; drop the trailing newline.
    if (list.items.len > 0 and list.items[list.items.len - 1] == '\n') {
        _ = list.pop();
    }
}

fn appendMultiProperties(list: *std.ArrayList(u8), pane: *Pane, targets: []const QModelIndex) !void {
    var file_count: usize = 0;
    var folder_count: usize = 0;
    var total_size: u64 = 0;

    for (targets) |index| {
        const entry = pane.model.entryAt(index) orelse continue;
        if (entry.is_dir) {
            folder_count += 1;
        } else {
            file_count += 1;
            total_size += entry.size;
        }
    }

    try appendProperties(list, "{d} items selected\n", .{targets.len});
    if (folder_count > 0) try appendProperties(list, "Folders: {d}\n", .{folder_count});
    if (file_count > 0) try appendProperties(list, "Files: {d}\n", .{file_count});

    var amount_buffer: [64]u8 = undefined;
    const size_text = if (file_count > 0) formatBytes(&amount_buffer, total_size) else "—";
    try appendProperties(list, "Total size: {s}\n", .{size_text});
    if (pane.current_path) |location| {
        try appendProperties(list, "Location: {s}\n", .{location});
    }

    if (list.items.len > 0 and list.items[list.items.len - 1] == '\n') {
        _ = list.pop();
    }
}

/// Formats QFileDevice permission flags as a classic nine-character mode
/// string, for example "rw-r--r--".
fn permissionsString(permissions: i32) [9]u8 {
    var text = [_]u8{ '-', '-', '-', '-', '-', '-', '-', '-', '-' };
    const flags = [_]struct { bit: i32, position: usize, character: u8 }{
        .{ .bit = qfiledevice_enums.Permission.ReadUser, .position = 0, .character = 'r' },
        .{ .bit = qfiledevice_enums.Permission.WriteUser, .position = 1, .character = 'w' },
        .{ .bit = qfiledevice_enums.Permission.ExeUser, .position = 2, .character = 'x' },
        .{ .bit = qfiledevice_enums.Permission.ReadGroup, .position = 3, .character = 'r' },
        .{ .bit = qfiledevice_enums.Permission.WriteGroup, .position = 4, .character = 'w' },
        .{ .bit = qfiledevice_enums.Permission.ExeGroup, .position = 5, .character = 'x' },
        .{ .bit = qfiledevice_enums.Permission.ReadOther, .position = 6, .character = 'r' },
        .{ .bit = qfiledevice_enums.Permission.WriteOther, .position = 7, .character = 'w' },
        .{ .bit = qfiledevice_enums.Permission.ExeOther, .position = 8, .character = 'x' },
    };
    for (flags) |flag| {
        if (permissions & flag.bit != 0) text[flag.position] = flag.character;
    }
    return text;
}

fn copyOrCut(mode: ClipMode) void {
    const pane = activePane() orelse return;
    var selected = collectSelectedPaths(pane) catch {
        showStatus("Could not read the selection", 3500);
        return;
    };
    if (selected.items.len == 0) {
        freePathList(&selected);
        showStatus("Select items first", 2500);
        return;
    }

    clearClipboard();
    // clearClipboard() only releases the paths and keeps the buffer for
    // reuse; assigning a new list here would orphan that allocation.
    app.clip_paths.deinit(app.gpa);
    app.clip_paths = selected;
    app.clip_mode = mode;

    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "{s} {d} item{s}",
        .{
            if (mode == .cut) "Cut" else "Copied",
            selected.items.len,
            if (selected.items.len == 1) "" else "s",
        },
    ) catch "Selection copied";
    showStatus(text, 3000);
}

fn onCopy(_: QAction) callconv(.c) void {
    copyOrCut(.copy);
}

fn onCut(_: QAction) callconv(.c) void {
    copyOrCut(.cut);
}

fn onPaste(_: QAction) callconv(.c) void {
    if (app.clip_mode == .none or app.clip_paths.items.len == 0) {
        showStatus("The clipboard is empty", 2500);
        return;
    }
    if (app.file_job != null) {
        showStatus("Finish or cancel the current operation first", 3500);
        return;
    }

    const pane = activePane() orelse return;
    const dest = pane.current_path orelse return;
    const cutting = app.clip_mode == .cut;

    const job = if (cutting)
        file_ops.Job.createMove(app.gpa, app.io, app.clip_paths.items, dest)
    else
        file_ops.Job.createCopy(app.gpa, app.io, app.clip_paths.items, dest);
    const created = job catch {
        showStatus("Could not start the paste operation", 3500);
        return;
    };
    _ = startFileJob(created, cutting);
}

/// Called by the model after it has validated and resolved a drop. This runs
/// synchronously on the UI thread, so the job can copy the path list.
fn onModelDrop(
    model: *local_model.LocalModel,
    sources: []const []const u8,
    dest_dir: []const u8,
    move: bool,
) bool {
    var target: ?*Pane = null;
    for (app.panes_list.items) |pane| {
        if (pane.model == model) {
            target = pane;
            break;
        }
    }
    const pane = target orelse return false;
    if (!isActivePane(pane)) setActivePane(pane);

    if (app.file_job != null) {
        showStatus("Finish or cancel the current operation first", 3500);
        return false;
    }

    const job = if (move)
        file_ops.Job.createMove(app.gpa, app.io, sources, dest_dir)
    else
        file_ops.Job.createCopy(app.gpa, app.io, sources, dest_dir);
    const created = job catch {
        showStatus("Could not start the drop operation", 3500);
        return false;
    };
    return startFileJob(created, false);
}

fn onUndo(_: QAction) callconv(.c) void {
    if (app.file_job != null) {
        showStatus("Wait for the current operation to finish", 3000);
        return;
    }
    var batch = app.undo_stack.pop() orelse {
        showStatus("Nothing to undo", 2500);
        return;
    };

    const job = file_ops.Job.createUndo(app.gpa, app.io, batch.items) catch {
        app.undo_stack.append(app.gpa, batch) catch freeUndoBatch(&batch);
        updateUndoAction();
        showStatus("Could not start the undo operation", 3500);
        return;
    };

    if (!startFileJob(job, false)) {
        app.undo_stack.append(app.gpa, batch) catch freeUndoBatch(&batch);
        updateUndoAction();
        return;
    }
    freeUndoBatch(&batch);
    updateUndoAction();
}

fn onCancelOperation(_: QAction) callconv(.c) void {
    cancelCurrentFileJob();
}

// ---- Search --------------------------------------------------------------

fn startSearch() void {
    const raw = app.global_search.text(app.gpa);
    defer app.gpa.free(raw);
    const query = std.mem.trim(u8, raw, " \t\r\n");
    if (query.len == 0) return;

    const pane = activePane() orelse return;
    const root = pane.current_path orelse return;

    cancelSearch();
    clearSearchResults();

    if (app.search_query) |old| app.gpa.free(old);
    app.search_query = app.gpa.dupe(u8, query) catch null;

    if (tryIndexedSearch(query, root)) return;

    const job = search_scan.Scan.create(app.gpa, app.io, root, query) catch {
        showStatus("Could not start the search", 3000);
        return;
    };
    job.start() catch {
        job.deinit();
        showStatus("Could not start the search", 3000);
        return;
    };

    app.search_job = job;
    app.search_timer.start(100);
    app.search_dock.show();

    var buffer: [8192]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Searching {s} in {s}…", .{ query, root }) catch "Searching…";
    app.status.showMessage(message);
}

/// Returns true when the index served the search (including an empty result).
/// Falls back to the live scanner while the index is building, absent, or
/// does not cover the active folder.
fn tryIndexedSearch(query: []const u8, root: []const u8) bool {
    if (app.index_reader) |*reader| {
        if (!reader.coversRoot(root)) return false;

        var hits: std.ArrayList(search_index.Hit) = .empty;
        defer hits.deinit(app.gpa);
        reader.search(query, root, search_index.result_limit, &hits) catch return false;

        for (hits.items) |hit| {
            app.search_paths.append(app.gpa, hit.path) catch {
                app.gpa.free(hit.path);
                continue;
            };
            addSearchResultItem(hit.path);
            app.search_hits += 1;
        }

        app.search_dock.show();
        showIndexedSearchFinished();
        return true;
    }
    return false;
}

fn cancelSearch() void {
    if (app.search_job) |job| {
        job.requestCancel();
        job.deinit();
        app.search_job = null;
    }
    app.search_timer.stop();
}

fn clearSearchResults() void {
    app.search_list.clear();
    for (app.search_paths.items) |path| app.gpa.free(path);
    app.search_paths.clearRetainingCapacity();
    app.search_hits = 0;
}

fn onSearchTimer(_: QTimer) callconv(.c) void {
    const job = app.search_job orelse {
        app.search_timer.stop();
        return;
    };

    var batch = job.takeResults();
    defer batch.deinit(app.gpa);
    appendSearchResults(batch.items);

    if (job.isDone()) {
        app.search_timer.stop();
        job.join();
        job.deinit();
        app.search_job = null;
        showSearchFinished();
        return;
    }

    var buffer: [8192]u8 = undefined;
    const query = app.search_query orelse "";
    const message = std.fmt.bufPrint(
        &buffer,
        "Searching {s}… {d} result{s} so far",
        .{ query, app.search_hits, if (app.search_hits == 1) "" else "s" },
    ) catch "Searching…";
    app.status.showMessage(message);
}

fn appendSearchResults(items: []const []u8) void {
    for (items) |path| {
        app.search_paths.append(app.gpa, path) catch {
            app.gpa.free(path);
            continue;
        };
        addSearchResultItem(path);
        app.search_hits += 1;
    }
}

fn addSearchResultItem(path: []const u8) void {
    const name = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse "";
    const label = std.fmt.allocPrint(app.gpa, "{s}    —    {s}", .{ name, parent }) catch name;
    const label_owned = label.ptr != name.ptr;

    const item = QListWidgetItem.new2(label);
    item.setToolTip(path);
    app.search_list.addItem2(item);

    if (label_owned) app.gpa.free(label);
}

fn showSearchFinished() void {
    if (app.search_hits == 0) {
        showStatus("No files matched", 4000);
        return;
    }

    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "Search finished — {d} result{s}",
        .{ app.search_hits, if (app.search_hits == 1) "" else "s" },
    ) catch "Search finished";
    app.status.showMessage(message);
}

fn showIndexedSearchFinished() void {
    if (app.search_hits == 0) {
        showStatus("No files matched in the search index", 4000);
        return;
    }

    var buffer: [512]u8 = undefined;
    if (app.search_hits >= search_index.result_limit) {
        const message = std.fmt.bufPrint(
            &buffer,
            "Search finished — first {d} results (indexed)",
            .{search_index.result_limit},
        ) catch "Search finished (indexed)";
        app.status.showMessage(message);
        return;
    }

    const message = std.fmt.bufPrint(
        &buffer,
        "Search finished — {d} result{s} (indexed)",
        .{ app.search_hits, if (app.search_hits == 1) "" else "s" },
    ) catch "Search finished (indexed)";
    app.status.showMessage(message);
}

// ---- Search index --------------------------------------------------------

fn initSearchIndex(home: []const u8) void {
    const db_path = search_index.dbPath(app.gpa) catch {
        app.index_label.setText("Index: unavailable");
        return;
    };
    app.index_path = db_path;

    if (std.fs.path.dirname(db_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    }

    if (search_index.Reader.open(app.gpa, db_path)) |reader| {
        app.index_reader = reader;
        updateIndexReadyLabel();
    } else |_| {
        if (search_index.autoIndexEnabled()) {
            startIndexBuild(home);
        } else {
            app.index_label.setText("Index: off (scan only)");
        }
    }
}

fn startIndexBuild(root: []const u8) void {
    cancelIndexBuild();

    if (app.index_reader) |*reader| {
        reader.deinit();
        app.index_reader = null;
    }

    const db_path = app.index_path orelse return;
    const data_dir = search_index.dataDir(app.gpa) catch null;
    defer if (data_dir) |dir| app.gpa.free(dir);

    const job = search_index.BuildJob.create(app.gpa, app.io, db_path, root, data_dir) catch {
        app.index_label.setText("Index: unavailable");
        showStatus("Could not start the search index", 4000);
        return;
    };
    job.start() catch {
        job.deinit();
        app.index_label.setText("Index: unavailable");
        showStatus("Could not start the search index", 4000);
        return;
    };

    app.index_job = job;
    app.index_timer.start(500);
    app.index_label.setText("Index: building…");
    showStatus("Building the search index in the background", 4000);
}

fn cancelIndexBuild() void {
    if (app.index_job) |job| {
        job.requestCancel();
        job.deinit();
        app.index_job = null;
    }
    app.index_timer.stop();
}

fn onIndexTimer(_: QTimer) callconv(.c) void {
    const job = app.index_job orelse {
        app.index_timer.stop();
        return;
    };
    const progress = job.progress();

    if (!progress.done) {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "Index: building {d} files…",
            .{progress.files},
        ) catch "Index: building…";
        app.index_label.setText(text);
        return;
    }

    app.index_timer.stop();
    job.join();
    job.deinit();
    app.index_job = null;

    if (progress.failed) {
        app.index_label.setText("Index: unavailable");
        showStatus("Search index build failed — using the live scanner", 5000);
        return;
    }

    const db_path = app.index_path orelse return;
    if (search_index.Reader.open(app.gpa, db_path)) |reader| {
        app.index_reader = reader;
        updateIndexReadyLabel();
        showStatus("Search index ready — searches now use SQLite FTS5", 5000);
    } else |_| {
        app.index_label.setText("Index: unavailable");
        showStatus("Search index was built but could not be opened", 5000);
    }
}

fn updateIndexReadyLabel() void {
    const reader = if (app.index_reader) |*value| value else return;
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "Index: {d} files",
        .{reader.file_count},
    ) catch "Index: ready";
    app.index_label.setText(text);
}

// ---- Qt helpers and callbacks -------------------------------------------

fn makeNavButton(label: []const u8, tooltip: []const u8, callback: *const fn (QPushButton) callconv(.c) void) QPushButton {
    const button = QPushButton.new3(label);
    button.setFixedWidth(34);
    button.setFlat(true);
    button.setToolTip(tooltip);
    button.onClicked(callback);
    return button;
}

fn makeAction(parent: anytype, label: []const u8, shortcut: ?[]const u8, callback: *const fn (QAction) callconv(.c) void) QAction {
    const action = QAction.new4(parent);
    action.setText(label);
    if (shortcut) |text| {
        const sequence = QKeySequence.new2(text);
        defer sequence.delete();
        action.setShortcut(sequence);
    }
    action.onTriggered(callback);
    return action;
}

fn addPlace(label: []const u8, path: []const u8) void {
    const dir = QDir.new4(path);
    defer dir.delete();
    if (!dir.exists()) return;

    const copy = app.gpa.dupe(u8, path) catch return;
    app.place_paths.append(app.gpa, copy) catch {
        app.gpa.free(copy);
        return;
    };
    app.places.addItem(label);
}

fn addChildPlace(home: []const u8, name: []const u8) void {
    const path = std.fs.path.join(app.gpa, &.{ home, name }) catch return;
    defer app.gpa.free(path);
    addPlace(name, path);
}

fn findPaneContaining(widget: anytype) ?*Pane {
    const widget_address = @intFromPtr(widget.ptr orelse return null);
    for (app.panes_list.items) |pane| {
        if (@intFromPtr(pane.container.ptr orelse continue) == widget_address) return pane;
        if (pane.container.isAncestorOf(widget)) return pane;
    }
    return null;
}

fn findPaneBySelection(selection: QItemSelectionModel) ?*Pane {
    for (app.panes_list.items) |pane| {
        if (pane.selection.ptr == selection.ptr) return pane;
    }
    return null;
}

fn activateFromWidget(widget: anytype) ?*Pane {
    const pane = findPaneContaining(widget) orelse return null;
    if (!isActivePane(pane)) setActivePane(pane);
    return pane;
}

fn navigationPane(button: QPushButton) ?*Pane {
    return activateFromWidget(button) orelse activePane();
}

fn onPaneBack(button: QPushButton) callconv(.c) void {
    if (navigationPane(button)) |pane| goBack(pane);
}

fn onPaneForward(button: QPushButton) callconv(.c) void {
    if (navigationPane(button)) |pane| goForward(pane);
}

fn onPaneUp(button: QPushButton) callconv(.c) void {
    if (navigationPane(button)) |pane| goUp(pane);
}

fn onPaneHome(button: QPushButton) callconv(.c) void {
    if (navigationPane(button)) |pane| goHome(pane);
}

fn onPaneReload(button: QPushButton) callconv(.c) void {
    if (navigationPane(button)) |pane| reloadPane(pane);
}

fn onPathEntered(edit: QLineEdit) callconv(.c) void {
    const pane = activateFromWidget(edit) orelse return;
    const text = edit.text(app.gpa);
    defer app.gpa.free(text);
    navigateTo(pane, text, true);
    pane.tree.setFocus();
}

fn onFilterChanged(edit: QLineEdit, text: [*:0]const u8) callconv(.c) void {
    if (app.suppress_filter) return;
    const pane = activateFromWidget(edit) orelse return;
    applyFilter(pane, std.mem.span(text));
}

fn onPlaceSelected(_: QListWidget, row: i32) callconv(.c) void {
    if (app.places_updating) return;
    if (row < 0) return;
    const index: usize = @intCast(row);
    if (index >= app.place_paths.items.len) return;

    const pane = activePane() orelse return;
    navigateTo(pane, app.place_paths.items[index], true);
    pane.tree.setFocus();
}

// ---- Context menus -------------------------------------------------------

fn onTreeContextMenu(tree: QTreeView, pos: QPoint) callconv(.c) void {
    const pane = activateFromWidget(tree) orelse return;
    app.context_pane = pane;

    const index = tree.indexAt(pos);

    // File actions operate on the clicked row, like every mainstream file
    // manager: right-clicking an unselected row selects it, while clicking a
    // row that is already part of a multi-selection keeps that selection.
    // Right-clicking empty space clears the selection so item actions are
    // disabled and Paste/New Folder still target the current folder.
    setContextSelection(pane, index);

    // "Open in Terminal" follows the row under the pointer: a folder opens
    // the terminal there, a file opens it in the containing folder, and empty
    // space falls back to the pane's current folder.
    setContextTerminalDir(pane, index);

    updateContextMenuState(pane, index);

    const global = tree.mapToGlobal2(pos);
    defer global.delete();
    app.tree_menu.popup(global);
}

fn setContextSelection(pane: *Pane, index: QModelIndex) void {
    if (index.isValid()) {
        if (!pane.selection.isSelected(index)) {
            pane.selection.select(
                index,
                qitemselectionmodel_enums.SelectionFlag.ClearAndSelect |
                    qitemselectionmodel_enums.SelectionFlag.Rows,
            );
        }
        pane.selection.setCurrentIndex(index, qitemselectionmodel_enums.SelectionFlag.NoUpdate);
        return;
    }

    pane.selection.clear();
    // collectSelectedPaths() falls back to the current row when nothing is
    // selected, so empty-space clicks must also invalidate the current index.
    const invalid = QModelIndex.new3();
    defer invalid.delete();
    pane.selection.setCurrentIndex(invalid, qitemselectionmodel_enums.SelectionFlag.NoUpdate);
}

fn updateContextMenuState(pane: *Pane, index: QModelIndex) void {
    const has_item = index.isValid();
    const has_audio = has_item and selectionHasAudio(pane);
    app.ctx_open_action.setEnabled(has_item);
    app.ctx_play_action.setVisible(has_audio);
    app.ctx_play_action.setEnabled(has_audio);
    app.ctx_playlist_action.setVisible(has_audio);
    app.ctx_playlist_action.setEnabled(has_audio);
    app.ctx_cut_action.setEnabled(has_item);
    app.ctx_copy_action.setEnabled(has_item);
    app.ctx_properties_action.setEnabled(has_item);
    app.ctx_trash_action.setEnabled(has_item);
    app.ctx_delete_action.setEnabled(has_item);
    app.ctx_new_folder_action.setEnabled(pane.current_path != null);
    app.ctx_paste_action.setEnabled(
        app.file_job == null and app.clip_mode != .none and app.clip_paths.items.len > 0,
    );

    // "Add to Places" only makes sense when the selection has a folder.
    app.ctx_add_places_action.setVisible(selectionHasFolder(pane));
}

fn setContextTerminalDir(pane: *Pane, index: QModelIndex) void {
    app.context_terminal_dir_len = 0;

    var folder: ?[]const u8 = null;
    var owned: ?[]u8 = null;
    defer if (owned) |path| app.gpa.free(path);

    if (index.isValid() and pane.model.isDir(index)) {
        const path = pane.model.pathAt(app.gpa, index);
        owned = path;
        if (path.len > 0) folder = path;
    }
    const resolved = folder orelse pane.current_path orelse return;

    const len = @min(resolved.len, app.context_terminal_dir.len);
    @memcpy(app.context_terminal_dir[0..len], resolved[0..len]);
    app.context_terminal_dir_len = len;
}

fn onCtxOpenInTerminal(_: QAction) callconv(.c) void {
    if (app.context_terminal_dir_len == 0) return;
    openTerminalAt(app.context_terminal_dir[0..app.context_terminal_dir_len]);
}

fn onCtxOpen(_: QAction) callconv(.c) void {
    const pane = app.context_pane orelse return;
    const current = pane.selection.currentIndex();
    if (current.isValid()) openSelected(pane, current);
}

fn onCtxPlay(_: QAction) callconv(.c) void {
    const pane = app.context_pane orelse return;
    var audio_paths = collectSelectedAudioPaths(pane) catch return;
    defer freePathList(&audio_paths);

    if (audio_paths.items.len == 0) {
        showStatus("Select an audio file first", 2500);
        return;
    }

    app.player.playAll(audio_paths.items);
    showPlayer();
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "Playing {d} track{s}",
        .{ audio_paths.items.len, if (audio_paths.items.len == 1) "" else "s" },
    ) catch "Playing";
    showStatus(message, 3000);
}

fn onCtxAddToPlaylist(_: QAction) callconv(.c) void {
    const pane = app.context_pane orelse return;
    var audio_paths = collectSelectedAudioPaths(pane) catch return;
    defer freePathList(&audio_paths);

    if (audio_paths.items.len == 0) {
        showStatus("Select an audio file first", 2500);
        return;
    }

    const added = app.player.addPaths(audio_paths.items);
    showPlayer();
    if (added == 0) {
        showStatus("Already in the playlist", 3000);
        return;
    }
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "Added {d} track{s} to the playlist",
        .{ added, if (added == 1) "" else "s" },
    ) catch "Added to the playlist";
    showStatus(message, 3000);
}

fn onCtxAddToPlaces(_: QAction) callconv(.c) void {
    const pane = app.context_pane orelse return;

    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);
    var single: [1]QModelIndex = undefined;
    const targets: []const QModelIndex = if (rows.len > 0) rows else blk: {
        // The current row can be valid without being selected (Home/End).
        const current = pane.selection.currentIndex();
        if (!current.isValid()) break :blk &.{};
        single[0] = current;
        break :blk single[0..1];
    };

    var added: usize = 0;
    var duplicates: usize = 0;
    var last_name: [256]u8 = undefined;
    var last_len: usize = 0;

    for (targets) |index| {
        if (!index.isValid() or !pane.model.isDir(index)) continue;
        const path = pane.model.pathAt(app.gpa, index);
        defer app.gpa.free(path);
        if (path.len == 0) continue;
        switch (addCustomPlace(path)) {
            .added => {
                added += 1;
                const name = std.fs.path.basename(path);
                last_len = @min(name.len, last_name.len);
                @memcpy(last_name[0..last_len], name[0..last_len]);
            },
            .duplicate => duplicates += 1,
            .failed => {},
        }
    }

    var buffer: [1024]u8 = undefined;
    const message = if (added == 1)
        std.fmt.bufPrint(&buffer, "Added “{s}” to Places", .{last_name[0..last_len]}) catch "Added to Places"
    else if (added > 1)
        std.fmt.bufPrint(&buffer, "Added {d} folders to Places", .{added}) catch "Added to Places"
    else if (duplicates > 0)
        "Already in Places"
    else
        "No folders to add";
    showStatus(message, 4000);
}

fn onPlacesContextMenu(list: QListWidget, pos: QPoint) callconv(.c) void {
    const item = list.itemAt(pos);
    if (item.ptr == null) return;
    const row = list.row(item);
    if (row < 0) return;
    // Built-in places are fixed; only user-added entries can be removed.
    if (@as(usize, @intCast(row)) < app.place_builtin_count) return;
    app.context_place_row = row;

    const global = list.mapToGlobal2(pos);
    defer global.delete();
    app.places_menu.popup(global);
}

fn onCtxRemovePlace(_: QAction) callconv(.c) void {
    const row = app.context_place_row;
    app.context_place_row = -1;
    if (row < 0) return;
    const index: usize = @intCast(row);
    if (index < app.place_builtin_count or index >= app.place_paths.items.len) return;

    const removed_path = app.place_paths.items[index];
    const name = std.fs.path.basename(removed_path);

    // Removing the listed item updates the current row; do not navigate to a
    // neighbouring place because of it.
    app.places_updating = true;
    defer app.places_updating = false;
    const item = app.places.takeItem(row);
    if (item.ptr != null) item.delete();
    app.gpa.free(removed_path);
    _ = app.place_paths.orderedRemove(index);

    savePlaces();

    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "Removed “{s}” from Places", .{name}) catch "Removed from Places";
    showStatus(message, 4000);
}

fn selectionHasFolder(pane: *Pane) bool {
    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);
    if (rows.len == 0) {
        const current = pane.selection.currentIndex();
        return current.isValid() and pane.model.isDir(current);
    }
    for (rows) |index| {
        if (index.isValid() and pane.model.isDir(index)) return true;
    }
    return false;
}

fn selectionHasAudio(pane: *Pane) bool {
    const rows = pane.selection.selectedRows(app.gpa);
    defer app.gpa.free(rows);

    var single: [1]QModelIndex = undefined;
    const targets: []const QModelIndex = if (rows.len > 0) rows else blk: {
        single[0] = pane.selection.currentIndex();
        break :blk single[0..1];
    };

    for (targets) |index| {
        if (!index.isValid() or pane.model.isDir(index)) continue;
        const path = pane.model.pathAt(app.gpa, index);
        const audio = player_mod.isAudioFile(app.gpa, path);
        app.gpa.free(path);
        if (audio) return true;
    }
    return false;
}

/// Selection paths reduced to audio files, transferring ownership of the
/// matching strings to the returned list.
fn collectSelectedAudioPaths(pane: *Pane) !std.ArrayList([]const u8) {
    var all = try collectSelectedPaths(pane);
    defer all.deinit(app.gpa);

    var result: std.ArrayList([]const u8) = .empty;
    errdefer freePathList(&result);
    for (all.items) |path| {
        if (player_mod.isAudioFile(app.gpa, path)) {
            result.append(app.gpa, path) catch {
                app.gpa.free(path);
                continue;
            };
        } else {
            app.gpa.free(path);
        }
    }
    return result;
}

// ---- Places persistence --------------------------------------------------
//
// User-added places live in $XDG_CONFIG_HOME/ligma/places (or
// ~/.config/ligma/places), one absolute path per line. Built-in entries are
// always present and never stored.

fn placesConfigPath() ?[]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |raw| {
        const xdg = std.mem.span(raw);
        if (xdg.len > 0 and xdg[0] == '/') {
            return std.fs.path.join(app.gpa, &.{ xdg, "ligma", "places" }) catch null;
        }
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fs.path.join(app.gpa, &.{ std.mem.span(home), ".config", "ligma", "places" }) catch null;
}

fn loadCustomPlaces() void {
    const path = placesConfigPath() orelse return;
    defer app.gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, std.Io.Limit.limited(64 * 1024)) catch return;
    defer app.gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed)) continue;
        var seen = false;
        for (app.place_paths.items) |existing| {
            if (samePlacePath(existing, trimmed)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        addPlace(placeLabel(trimmed), trimmed);
    }
}

fn savePlaces() void {
    const path = placesConfigPath() orelse return;
    defer app.gpa.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    }

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(app.gpa);
    const start = @min(app.place_builtin_count, app.place_paths.items.len);
    for (app.place_paths.items[start..]) |place| {
        content.appendSlice(app.gpa, place) catch return;
        content.append(app.gpa, '\n') catch return;
    }

    std.Io.Dir.cwd().writeFile(app.io, .{
        .sub_path = path,
        .data = content.items,
        .flags = .{ .truncate = true },
    }) catch {};
}

fn addCustomPlace(path: []const u8) AddPlaceResult {
    for (app.place_paths.items) |existing| {
        if (samePlacePath(existing, path)) return .duplicate;
    }
    const before = app.place_paths.items.len;
    addPlace(placeLabel(path), path);
    if (app.place_paths.items.len == before) return .failed;
    savePlaces();
    return .added;
}

fn placeLabel(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

fn samePlacePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, withoutTrailingSlash(a), withoutTrailingSlash(b));
}

fn withoutTrailingSlash(path: []const u8) []const u8 {
    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

const AddPlaceResult = enum { added, duplicate, failed };

fn onTreeClicked(tree: QTreeView, _: QModelIndex) callconv(.c) void {
    _ = activateFromWidget(tree);
}

/// Modifier state is not reliably available inside Qt's drag loop on every
/// platform, so remember whether Ctrl was held when the gesture started and
/// let the model put that intent in the MIME payload.
fn onTreeMousePress(tree: QTreeView, event: QMouseEvent) callconv(.c) void {
    if (findPaneContaining(tree)) |pane| {
        const ctrl = qnamespace_enums.KeyboardModifier.ControlModifier;
        pane.model.setDragCopyHint((event.modifiers() & ctrl) != 0);
    }
    tree.superMousePressEvent(event);
}

fn onItemActivated(tree: QTreeView, index: QModelIndex) callconv(.c) void {
    const pane = activateFromWidget(tree) orelse return;
    openSelected(pane, index);
}

fn onSelectionChanged(selection: QItemSelectionModel, current: QModelIndex, _: QModelIndex) callconv(.c) void {
    const pane = findPaneBySelection(selection) orelse return;
    if (!isActivePane(pane)) return;

    if (!current.isValid()) {
        app.status.clearMessage();
        refreshCount(pane);
        return;
    }

    const name = pane.model.nameAt(app.gpa, current);
    defer app.gpa.free(name);

    var buffer: [8192]u8 = undefined;
    if (pane.model.isDir(current)) {
        const message = std.fmt.bufPrint(&buffer, "{s} — Folder", .{name}) catch name;
        app.status.showMessage(message);
    } else {
        const size = pane.model.sizeAt(current);
        const message = std.fmt.bufPrint(&buffer, "{s} — {d} bytes", .{ name, size }) catch name;
        app.status.showMessage(message);
    }
}

/// The selection ranges changed (select, shift-extend, Ctrl+A, clear).
/// The preview panel follows the selected rows, so this — not currentChanged —
/// is the right signal for it: Qt moves the current index before extending a
/// Shift+arrow selection, and a model reset clears the selection without any
/// signal at all.
fn onSelectionModelChanged(selection: QItemSelectionModel, _: QItemSelection, _: QItemSelection) callconv(.c) void {
    const pane = findPaneBySelection(selection) orelse return;
    if (!isActivePane(pane)) return;
    refreshPreview(pane);
}

fn onFocusChanged(_: QApplication, _: QWidget, now: QWidget) callconv(.c) void {
    if (now.ptr == null) return;

    for (app.panes_list.items) |pane| {
        if (pane.container.ptr == now.ptr or pane.container.isAncestorOf(now)) {
            if (!isActivePane(pane)) setActivePane(pane);
            return;
        }
    }
}

fn onTabChanged(_: QTabWidget, index: i32) callconv(.c) void {
    if (app.tabs_updating) return;
    if (index < 0) return;
    const pos: usize = @intCast(index);
    if (pos >= app.tabs_list.items.len) return;

    const tab = app.tabs_list.items[pos];
    const pane = tab.panes[tab.active] orelse tab.panes[0] orelse return;
    setActivePane(pane);
}

fn onTabCloseRequested(_: QTabWidget, index: i32) callconv(.c) void {
    closeTab(index);
}

fn onSearchReturn(_: QLineEdit) callconv(.c) void {
    startSearch();
}

fn onSearchActivated(list: QListWidget, item: QListWidgetItem) callconv(.c) void {
    const row = list.row(item);
    if (row < 0) return;
    const index: usize = @intCast(row);
    if (index >= app.search_paths.items.len) return;

    const path = app.search_paths.items[index];
    const info = QFileInfo.new2(path);
    defer info.delete();

    if (info.isDir()) {
        const pane = activePane() orelse return;
        navigateTo(pane, path, true);
        return;
    }

    if (player_mod.isAudioFile(app.gpa, path)) {
        app.player.playPath(path);
        showPlayer();
        showStatusForPath("Playing", path);
        return;
    }

    const url = QUrl.fromLocalFile(path);
    defer url.delete();
    if (!QDesktopServices.openUrl(url))
        showStatus("No application is registered to open this file", 3500);
}

// ---- Menu actions --------------------------------------------------------

fn onNewTab(_: QAction) callconv(.c) void {
    newTab();
}

fn onCloseTab(_: QAction) callconv(.c) void {
    closeTab(app.tabs.currentIndex());
}

fn onCloseWindow(_: QAction) callconv(.c) void {
    _ = app.window.close();
}

fn onQuit(_: QAction) callconv(.c) void {
    QApplication.quit();
}

fn onSelectAll(_: QAction) callconv(.c) void {
    if (activePane()) |pane| {
        pane.tree.selectAll();
        pane.tree.setFocus();
    }
}

fn onEditLocation(_: QAction) callconv(.c) void {
    if (activePane()) |pane| {
        pane.path_edit.setFocus();
        pane.path_edit.selectAll();
    }
}

fn onFocusFilter(_: QAction) callconv(.c) void {
    if (activePane()) |pane| {
        pane.search_edit.setFocus();
        pane.search_edit.selectAll();
    }
}

fn onFocusGlobalSearch(_: QAction) callconv(.c) void {
    app.global_search.setFocus();
    app.global_search.selectAll();
}

fn onRebuildIndex(_: QAction) callconv(.c) void {
    const home = QDir.homePath(app.gpa);
    defer app.gpa.free(home);
    startIndexBuild(home);
}

fn onToggleHidden(_: QAction) callconv(.c) void {
    app.show_hidden = !app.show_hidden;
    if (app.hidden_action) |action| action.setChecked(app.show_hidden);

    for (app.panes_list.items) |pane| {
        pane.model.setShowHidden(app.show_hidden);
        if (isActivePane(pane)) refreshCount(pane);
    }
}

fn onToggleSplit(_: QAction) callconv(.c) void {
    toggleSplit();
}

fn onFocusOtherPane(_: QAction) callconv(.c) void {
    focusOtherPane();
}

/// F12 pressed while the terminal widget has keyboard focus.
fn onTerminalKeyToggle(_: ?*anyopaque) callconv(.c) void {
    toggleTerminal();
}

fn onToggleTerminal(_: QAction) callconv(.c) void {
    toggleTerminal();
}

fn onTerminalVisibilityChanged(_: QDockWidget, visible: bool) callconv(.c) void {
    app.terminal_action.setChecked(visible);
}

fn onTogglePlayer(_: QAction) callconv(.c) void {
    if (app.player_dock.isVisible()) {
        app.player_dock.hide();
        if (activePane()) |pane| pane.tree.setFocus();
        return;
    }
    showPlayer();
}

fn onPlayerVisibilityChanged(_: QDockWidget, visible: bool) callconv(.c) void {
    app.player_action.setChecked(visible);
}

fn toggleTerminal() void {
    if (app.terminal_dock.isVisible()) {
        app.terminal_dock.hide();
        if (activePane()) |pane| pane.tree.setFocus();
        return;
    }
    openTerminalAt(terminalWorkingDirectory());
}

/// Show the terminal panel and point the shell at `directory`. A shell that
/// is already running is asked to change directory; QTermWidget only forwards
/// the `cd` while the shell is at a prompt, so foreground jobs are safe.
fn openTerminalAt(directory: []const u8) void {
    app.terminal_dock.show();
    app.terminal_dock.raise();
    if (!app.terminal_started) {
        app.terminal_started = terminal_mod.start(app.terminal_widget, app.gpa, userShell(), directory);
    } else {
        _ = terminal_mod.changeDirectory(app.terminal_widget, app.gpa, directory);
    }
    terminal_mod.setFocus(app.terminal_widget);
}

fn userShell() []const u8 {
    if (std.c.getenv("SHELL")) |raw| {
        const shell = std.mem.span(raw);
        if (shell.len > 0) return shell;
    }
    return "/bin/bash";
}

fn terminalWorkingDirectory() []const u8 {
    if (activePane()) |pane| {
        if (pane.current_path) |path| return path;
    }
    if (std.c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        if (home.len > 0) return home;
    }
    return "/";
}

fn onBackAction(_: QAction) callconv(.c) void {
    if (activePane()) |pane| goBack(pane);
}

fn onForwardAction(_: QAction) callconv(.c) void {
    if (activePane()) |pane| goForward(pane);
}

fn onUpAction(_: QAction) callconv(.c) void {
    if (activePane()) |pane| goUp(pane);
}

fn onHomeAction(_: QAction) callconv(.c) void {
    if (activePane()) |pane| goHome(pane);
}

fn onReloadAction(_: QAction) callconv(.c) void {
    if (activePane()) |pane| reloadPane(pane);
}

fn onAbout(_: QAction) callconv(.c) void {
    QMessageBox.about(
        app.window,
        "About Ligma",
        "Ligma 0.4 — a fast, keyboard-friendly file manager for Linux.\n\n" ++
            "Built with Zig and Qt 6. This build adds a custom asynchronous " ++
            "item model, tabs, split view, recursive filename search, and " ++
            "undoable file operations including freedesktop.org trash.\n\n" ++
            "The roadmap adds trash browsing, drag and drop, file watching, " ++
            "metadata, previews, remote locations, and an extension API.",
    );
}
