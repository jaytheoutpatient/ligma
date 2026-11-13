# Ligma — Product and Technical Specification

**Status:** v0.4 prototype implemented  
**Date:** 2026-11-09  
**Target platform:** Linux (Wayland first, X11 supported)  
**Implementation:** Zig 0.17 + Qt 6 Widgets via `libqt6zig`  
**Audience:** users who have outgrown a casual file manager but do not want Dolphin's full configuration surface

---

## 1. Product thesis

Ligma is a Linux-only file manager that combines the best ideas from Nautilus, Nemo, and Dolphin without inheriting their desktop-specific baggage.

The three reference applications optimize for different things:

- **Nautilus** wins on clarity, search, Quick Look, cloud integration, and polish.
- **Nemo** wins on classic power features, configurability, desktop integration, and user-defined actions.
- **Dolphin** wins on split view, the embedded terminal, metadata, network transparency, and bulk-operation tools.

Ligma's job is to make those strengths coexist in one coherent app. The product is not a clone of any of them; it is a careful synthesis with three hard differentiators:

1. **Speed** — instant startup, instant folder loading, never-blocking file operations.
2. **Search** — a current-folder filter that feels instantaneous and a global index that is actually useful.
3. **Extensions** — a low-friction action system, a modern script API, and native plugins for the things scripts cannot do.

### Design principles

- **Keyboard first, mouse optional.** Every important action has a shortcut and is reachable from a command palette.
- **No blocking I/O on the UI thread.** Ever.
- **Sensible defaults, discoverable depth.** A casual user can ignore the power features; a power user can reach them without editing five config files.
- **Local first, remote-aware.** Local files are the fast path. Remote and archive locations use the same UI through a VFS layer.
- **Extensions are a product surface, not an afterthought.** They get a documented API, permissions, and versioning from the start.
- **Linux-native.** No Windows/macOS compatibility layer. Use Linux facilities directly: inotify/fanotify, xattrs, UDisks2, polkit, PipeWire, XDG directories.

### Non-goals for v1

- Windows or macOS builds.
- Reimplementing every cloud provider.
- A full desktop shell.
- Feature parity with every plugin ever written for Nemo or Dolphin.
- Running the whole application as root.

---

## 2. Target user

The primary user is comfortable with files, archives, terminal commands, and keyboard shortcuts, but does not want to configure a file manager for an hour before it is useful.

Typical tasks:

- Move and rename batches of files without waiting on modal progress dialogs.
- Find a file by name or content across a project or home directory.
- Work with a local folder, an archive, and a remote server side by side.
- Add a custom action ("optimize this image", "open in my editor", "upload here") without writing a C++ plugin.
- Tag and rate reference material, then find it later.
- Preview a PDF, image, or video without opening a heavy application.

Secondary users:

- Developers who want Git status in the file list, a terminal synced to the current folder, and fast keyboard navigation.
- Creatives who want thumbnails, tags, ratings, and batch operations.
- Linux users coming from Nemo or Dolphin who want their familiar workflows without the rest of Cinnamon or Plasma.

---

## 3. Feature synthesis

Legend: **MVP** = phase 1, **P2**–**P6** = later phases, **opt** = optional/feature-gated.

### 3.1 Nautilus-derived features

| Feature | Ligma treatment | Phase |
|---|---|---|
| Search Everywhere (Tracker/TinySPARQL) | Native SQLite FTS5 index with filename + optional content search, query language, fast results | P3 |
| Starred files | Virtual `Starred` place backed by metadata DB/xattr | P3 |
| Sushi Quick Look (Space) | Built-in Quick Look overlay with image/PDF/video/audio/text/HTML providers | P2 |
| Tabs and tab overview | Tabs from P1; tab overview and session restore later | P1, P6 |
| Tree List view | Details view plus an expandable tree mode; Miller columns as a differentiator | P2 |
| Native archive handling | Archive VFS via libarchive; extract/create with progress and undo | P2 |
| GVfs/GOA remote and cloud | Optional GVfs bridge (`gio` mount points) in addition to native backends | P4 |
| `admin:///` and properties | Polkit-backed privileged operations, not a root file manager | P2 |
| Python extensions and scripts | Modern action/JS/native extension tiers, plus importers for Nemo actions | P5 |
| Recent files | XDG recent-documents integration and internal frecency | P3 |

### 3.2 Nemo-derived features

| Feature | Ligma treatment | Phase |
|---|---|---|
| Desktop icons | Optional separate desktop layer; deferred because Wayland support varies by compositor | P6/opt |
| Extra Pane (F3) | First-class split view with independent panes and "focus other view" | P1 |
| Open as Root | Polkit helper for explicit privileged operations; no root UI process | P2 |
| Open in Terminal | Embedded terminal panel (`F12`) implemented; external terminal action planned | P1, P2 |
| Configurable toolbar/UI | Customizable toolbar and sidebar; command palette exposes the same actions | P2 |
| Per-folder view/zoom | Remembered per-folder view mode, sort, zoom, and columns | P2 |
| Compact view | Compact/list mode alongside icons and details | P1 |
| Actions/scripts | `.desktop`-style declarative actions; import Nemo action files | P5 |
| Templates manager | "Create New Document" templates from XDG templates, with a manager | P2 |
| Rich context actions | Move To, Copy To, Duplicate, Make Link, Compress, image resize/rotate, set wallpaper | P1–P2 |
| Status bar count/free space | Item count, selection size, free space, operation speed/ETA | P1 |
| Pause/resume operations | Operation queue supports pause, resume, cancel, retry, undo | P1 |
| Media preview pane (F7) | Information/preview panel with EXIF and media metadata | P2 |
| Extension ecosystem | Native action/JS/native plugin APIs plus Nemo action import | P5 |

### 3.3 Dolphin-derived features

| Feature | Ligma treatment | Phase |
|---|---|---|
| Split view (F3) | Same pane system as Nemo's Extra Pane, with focus-other-view | P1 |
| Embedded terminal (F12) | Right-side QTermWidget panel; starts in the active folder and keeps its shell session across toggles | P2 (implemented) |
| KIO network transparency | VFS with `sftp://`, `smb://`, `webdav://`, `mtp://`, `archive://`; optional KIO-FUSE/GVfs bridge | P4 |
| Baloo metadata (tags/ratings/comments) | Portable xattr + SQLite metadata; optional Baloo import/export | P3 |
| Filter bar (text/glob/regex) | Current-folder filter with text, glob, and regex modes; instant in-memory filtering | P1 text, P2 glob/regex |
| Grouping independent of sorting | Group by type/date/tag while sorting by another key | P3 |
| Service menus | Declarative actions with submenus, icons, conditions; import Dolphin service menus | P5 |
| Per-folder view modes | Shared with Nemo feature above | P2 |
| Selection mode (Space) | Touch-friendly selection mode, with configurable Space behavior | P2 |
| Power actions | Batch rename, compare, compress/extract, share, duplicate, copy/move | P2 |
| Undo/redo for file operations | First-class operation journal with undo/redo | P1 |
| Git plugin | Optional native/JS plugin showing status and actions | P5 |
| KDE Connect / phone | Optional DBus integration | P4/opt |

### 3.4 Shared baseline (must exist)

- Tabs and multiple windows
- Back/forward/up, breadcrumbs, editable location bar
- Bookmarks/places, recent files, trash
- Search and filter; hidden-file toggle
- Icon, compact, details, and tree views; thumbnails
- Copy/cut/paste, drag and drop, duplicate, move to/copy to
- Built-in audio playback with a persistent playlist and standard transport controls
- Rename, batch rename, new folder/file, delete/trash, undo
- Archive compress/extract
- Remote mounts: SMB, SFTP, FTP, MTP, WebDAV
- Properties, permissions, owner/group
- Sorting/grouping, zoom, status bar
- Extensions/scripts/actions
- Mount/unmount, removable media, network discovery
- Keyboard shortcuts, accessibility, i18n

---

## 4. Product design

### 4.1 Main window

```
┌─────────────────────────────────────────────────────────────────────┐
│ Menu bar: File  Edit  View  Go  Tools  Help                         │
├─────────────────────────────────────────────────────────────────────┤
│ Toolbar: Back Forward Up Home Reload | Path breadcrumb / edit       │
│          Search / Filter | View mode | Split | Terminal | More      │
├──────────────┬──────────────────────────────────────────────────────┤
│ Places       │ Tab 1 | Tab 2 | +                                    │
│              ├───────────────────────┬──────────────────────────────┤
│ Home         │ Pane A                │ Pane B (optional, F3)        │
│ Desktop      │                       │                              │
│ Documents    │  icon/list/details    │  icon/list/details           │
│ Downloads    │                       │                              │
│ Starred      │                       │                              │
│ Recent       │                       │                              │
│ Trash        │                       │                              │
│ Filesystem   │                       │                              │
│ Devices      │                       │                              │
│ Network      │                       │                              │
├──────────────┴───────────────────────┴──────────────────────────────┤
│ Information / Preview panel (F7, optional)                          │
├─────────────────────────────────────────────────────────────────────┤
│ Terminal panel (F12, right side)                                    │
├─────────────────────────────────────────────────────────────────────┤
│ Status: 14 items · 2 selected · 1.2 GB free · Copying 34% 12 MB/s   │
└─────────────────────────────────────────────────────────────────────┘
```

The default is a single pane with a sidebar and details view. Split view, information panel, and terminal are toggles, not separate modes.

### 4.2 View modes

- **Icons** — grid, adjustable zoom, thumbnails, labels.
- **Compact** — dense multi-column list.
- **Details** — sortable columns: name, size, type, modified, permissions, owner, tags, rating, custom extension columns.
- **Tree** — expandable folders inline in the details view.
- **Miller columns** — optional three-column browser for deep hierarchies (a differentiator none of the three has).

Per-folder state remembers view mode, sort column/order, grouping, zoom, hidden-file state, and column layout. Global defaults live in config; per-folder overrides live in the state DB.

### 4.3 Navigation

- Back/forward history per tab/pane.
- Breadcrumb path bar; click a segment to navigate; Ctrl+L or click empty space to edit the full path.
- `~`, relative paths, and `file://` URIs accepted in the location bar.
- Places sidebar with Home, XDG directories, Starred, Recent, Trash, Filesystem, devices, network.
- **Implemented (v0.4):** right-click a folder → *Add to Places* pins it to the sidebar; right-click a user-added entry → *Remove from Places*. Custom entries persist in `$XDG_CONFIG_HOME/ligma/places`, one absolute path per line, and load at startup after the built-ins. Built-in entries cannot be removed. The file-list menu also offers *Open in Terminal*.
- **Implemented (v0.4):** the file-list context menu exposes *Open*, *Open in Terminal*, *Cut*, *Copy*, *Paste*, *New Folder…*, *Properties*, *Move to Trash*, *Delete Permanently*, and *Add to Places* (shown only when the selection contains a folder). Right-clicking an unselected row selects it first, right-clicking a row that is already selected preserves a multi-selection, and right-clicking empty space clears the selection so only folder-wide actions (*Paste*, *New Folder…*) remain enabled. *Paste* is enabled only while the clipboard holds items and no file operation is running. *Properties* shows name, kind, size, location, modified time, permissions, and the symlink target for one item, and the item count, folder/file breakdown, total size, and location for a multi-selection.
- Drag a folder to the sidebar to bookmark it.
- Middle-click a folder to open it in a new tab.
- Enter opens; Ctrl+Enter opens in the other pane; Shift+Enter opens in a new tab.
- Backspace goes up (configurable).

### 4.4 Tabs and panes

- Tabs are per window; each tab has one or two panes.
- F3 toggles split view; Tab switches focus; Shift+Tab reverses.
- Each pane has independent history, filter, view mode, and selection.
- Drag between panes with copy/move modifiers.
- "Focus other view" command, matching Dolphin 26.08.
- Session restore reopens windows, tabs, panes, and scroll positions.

### 4.5 Quick Look and preview

**Implemented (v0.4):** selecting exactly one image or video file shows a larger thumbnail panel at the bottom of the Places sidebar (window's bottom-left corner). It hides for folders, non-media files, multi-selections, and empty selections. Images are decoded at display size via `QImageReader`; video frames are extracted by an asynchronous ffmpeg job (1 s seek, retried from frame 0 for shorter clips). MIME classification is content-aware.

Planned on top of this:

- Space opens a borderless preview overlay for the focused item.
- Esc or Space closes it.
- Supported providers: images (QImageReader), PDF (Qt6Pdf), video/audio (Qt6Multimedia + ffmpeg thumbnails), text/code (syntax highlighted read-only view), HTML (safe subset), archives (listing), directories (folder summary).
- Preview providers are extensions: a provider declares MIME types and returns a QWidget or texture.
- Thumbnails are generated asynchronously in a worker pool, cached under `$XDG_CACHE_HOME/ligma/thumbnails`, and keyed by path + mtime + size.
- F7 opens the persistent Information/Preview panel with metadata, EXIF, tags, rating, comments, and permissions.

### 4.6 Selection mode

- Ctrl+Space toggles a touch-friendly selection mode with a contextual action bar.
- In selection mode, a single click toggles selection instead of replacing it; Space remains Quick Look outside selection mode.
- This resolves the Dolphin/Nautilus conflict without giving up either behavior.

### 4.7 Embedded terminal

- **Implemented (v0.4):** `F12` toggles a terminal panel docked on the right side of the window. The dock can also be hidden with its title-bar button or through **View > Terminal Panel**; the menu item's check state follows visibility.
- **Implemented (v0.4):** right-clicking the file list offers **Open in Terminal**. The action follows the row under the pointer — a folder opens the terminal there, a file opens it in the containing folder, and empty space falls back to the pane's current folder. If a shell is already running it receives a `cd` only while it is at a prompt, so a foreground job (editor, build) is not disturbed.

- The shell is started lazily on the first open, using `$SHELL` and the active pane's current folder.
- Hiding and reopening the panel keeps the same shell session and working directory, including anything the user ran in it.
- `F12` is handled both as a window shortcut and inside the terminal widget, so the panel can be closed while the shell has keyboard focus.
- The terminal is QTermWidget (`qtermwidget6.pc`). Because the widget is C++, `src/ui/terminal_widget.cpp` exposes a small C ABI shim compiled with the system `g++`; Zig code lives in `src/ui/terminal.zig`.
- QTermWidget is LGPL-2.0-or-later (some files BSD-3-Clause), which is compatible with Ligma's GPL-3.0-or-later license.
- The terminal widget is deleted during shutdown, which closes the PTY and ends the shell.

Still planned:

- Two-way directory synchronization: navigating in Ligma updates the shell when it is at a prompt, and `cd` in the shell navigates the pane.
- Per-tab terminals and an external-terminal fallback when qtermwidget is unavailable.
- Configurable shell, profile, font size, and color scheme.

### 4.8 Desktop icons

Desktop icons are a Nemo signature feature, but a correct implementation is desktop-environment-specific:

- Wayland: requires a layer-shell surface; works on wlroots/KDE, not GNOME without an extension.
- X11: a desktop-level window is possible but interacts poorly with compositors and other desktop managers.

Decision: ship desktop icons as an optional component in P6, with a clear warning when the compositor does not support the required protocol. The core file manager must not depend on it.

### 4.9 Keyboard model (initial)

| Shortcut | Action |
|---|---|
| Ctrl+L | Edit location |
| Ctrl+F | Filter current folder |
| Ctrl+Shift+F | Global search |
| Ctrl+Shift+P | Command palette |
| F3 | Toggle split view |
| Tab / Shift+Tab | Focus next/previous pane |
| F12 | Toggle terminal panel |
| F9 | Toggle music player |
| F7 | Toggle information/preview panel |
| Space | Quick Look |
| Ctrl+Space | Selection mode |
| Enter | Open (runs executable files after confirmation) |
| Shift+Enter | Open in new tab |
| Ctrl+Return | Run selected executable |
| Ctrl+Shift+Enter | Open in other pane |
| Backspace / Alt+Up | Parent folder |
| Alt+Left / Alt+Right | Back / forward |
| F2 | Rename |
| Ctrl+Shift+N | New folder |
| Ctrl+H | Show/hide hidden files |
| Ctrl+Shift+V | Paste into current folder |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo file operation |
| Delete / Shift+Delete | Move to trash / delete permanently |
| Ctrl+Shift+T | Restore last closed tab |
| Esc | Close overlay / clear selection |

Shortcuts are configurable and exposed in the command palette.

### 4.10 Drag and drop

The details view supports dragging selected rows and dropping them onto folders or empty pane space.

- Internal drags move by default; holding Ctrl at gesture start copies. The drag payload carries a `text/uri-list` plus an internal marker, and the copy intent is recorded from the mouse-press modifiers because Qt's drag loop does not receive modifier state reliably on every platform.
- A drop onto a folder row targets that folder. A drop over empty space targets the pane's current folder.
- Same-folder drops are rejected as no-ops. Folder sources that would contain the destination are rejected before any job starts.
- Internal drops start the existing asynchronous move/copy engine, so progress, cancellation, collision naming, and the undo journal behave exactly like paste.
- Drags from other applications are accepted as `text/uri-list` and always copy; external sources are never moved.
- Folder rows advertise `ItemIsDropEnabled`; the model implements `mimeTypes`, `mimeData`, `canDropMimeData`, `dropMimeData`, and the supported drag/drop actions.

### 4.11 Music player

- **Implemented (v0.5):** activating a local file whose `QMimeDatabase` type starts with `audio/` plays it in an in-app player instead of handing it to the desktop opener. The same rule applies to files activated from the global search results.
- The player is a bottom `QDockWidget` toggled with `F9` or **View > Music Player**. It shows the current track and playlist position, elapsed/total time, a seek slider, volume, previous/play-pause/next/stop, repeat, and shuffle.
- Repeat cycles **off → all → one**. Repeat all wraps at the end of the queue; repeat one reloads the current row. Shuffle chooses a random other row for Next and for automatic advancement.
- The playlist is in memory and parallel to the list widget. Activating another audio file appends it if missing and starts it; **Add to Playlist** appends the selected audio files without interrupting the current track; **Play** replaces the queue and starts the first selected track.
- Clicking a playlist row jumps to that track. The media-status callback handles `EndOfMedia`: with repeat off it removes the finished entry before selecting the next one; repeat all/one preserve the queue. Manual Next/Previous and Stop do not remove entries.
- Seeking is slider-driven (`sliderMoved`), so playback position updates do not fight a drag. Volume is applied to `QAudioOutput` in the 0–1 range.
- Closing the dock keeps playback and queue state. Shutdown stops the player and deletes the `QMediaPlayer`/`QAudioOutput` objects explicitly before the window is torn down.
- QtMultimedia is linked as `Qt6Multimedia`; at runtime the FFmpeg multimedia backend supplies codecs for common formats such as MP3, Opus, FLAC, and WAV.
- **Implemented (v0.5):** Discord Rich Presence uses the local `discord-ipc-*` socket and the registered Ligma application ID. `QMediaMetaData` supplies title, contributing artist/album artist/author, and album title; untagged files fall back to the filename and omit an unknown artist. `details` combines song and artist and `status_display_type` is set to Details, so the member-list status text shows the track rather than only the application name. Presence includes playback timestamps while playing, drops them while paused, and is cleared on stop/exit. `LIGMA_DISCORD=0` disables it and `LIGMA_DISCORD_APP_ID` overrides the app ID.
- Rich Presence is best-effort and reconnects in the background. It never blocks playback when Discord is absent, and it only talks to the local Discord client — no bot token or remote service is involved.

### 4.12 Application identity

- The application icon is a blue-and-purple floppy disk drawn as SVG and rasterized at 16, 22, 24, 32, 48, 64, 128, 256, and 512 px.
- Installed assets use the name `org.ligma.FileManager` under the hicolor theme, alongside `org.ligma.FileManager.desktop`.
- The 256 px PNG is embedded in the binary and installed as the window icon, so the icon also works when running directly from a build directory.

---

## 5. Architecture

### 5.1 Layers

```
┌───────────────────────────────────────────────────────────────┐
│ Qt 6 Widgets UI                                               │
│ main window · tabs · panes · views · dialogs · command palette│
├───────────────────────────────────────────────────────────────┤
│ Qt item models and delegates (Zig subclasses)                 │
│ LigmaModel · PlacesModel · SearchModel · column providers    │
├───────────────────────────────────────────────────────────────┤
│ Application services (Zig)                                    │
│ navigation · selection · settings · sessions · undo journal   │
├───────────────────────────────────────────────────────────────┤
│ Core engines (Zig, worker threads)                            │
│ VFS · file operations · search/index · metadata · previews    │
├───────────────────────────────────────────────────────────────┤
│ Platform layer (Linux)                                        │
│ inotify/fanotify · xattr · UDisks2 · polkit · XDG · MIME      │
└───────────────────────────────────────────────────────────────┘
```

Qt objects live on the main thread. All blocking work happens on Zig worker threads. Worker results are delivered to the UI through a thread-safe event queue drained by a QTimer or a Qt queued invocation; workers never touch Qt objects.

### 5.2 Planned source layout

```
src/
  main.zig                 application entry point and composition
  app/
    app.zig                state, command registry, event loop glue
    commands.zig           command definitions and keybindings
    settings.zig           config load/save and migrations
    session.zig            windows, tabs, panes, scroll positions
  core/
    vfs/
      vfs.zig              VFS interface, URI parsing, capabilities
      local.zig            local filesystem backend
      trash.zig            freedesktop.org trash backend
      archive.zig          libarchive backend
      search.zig           virtual search result backend
      remote/              sftp, smb, webdav, mtp
      gvfs.zig             optional bridge to GVfs mounts
      kio.zig              optional bridge to KIO-FUSE mounts
    ops/
      engine.zig           queue, workers, pause/resume/cancel
      copy.zig             copy/move with metadata preservation
      delete.zig           trash and permanent delete
      rename.zig           single and batch rename
      archive_ops.zig      compress/extract
      undo.zig             operation journal
    search/
      index.zig            SQLite FTS5 schema and queries
      crawler.zig          incremental indexing and inotify
      query.zig            query parser
      extract.zig          text/metadata extraction
    integration/
      discord.zig          local Discord Rich Presence IPC
    meta/
      metadata.zig         tags, ratings, comments, emblems
      xattr.zig            portable xattr encoding
      baloo.zig            optional Baloo import/export
    preview/
      registry.zig         provider registry
      providers/           image, pdf, video, text, archive, ...
      thumbnails.zig       cache and async generation
    extensions/
      actions.zig          declarative .desktop actions
      js/                  QuickJS host and API
      native.zig           versioned native plugin ABI
      importers/           Nemo actions, Dolphin service menus
  ui/
    main_window.zig
    tab_bar.zig
    pane.zig
    views/                 icon, compact, details, tree, miller
    models/                LigmaModel, PlacesModel, SearchModel
    delegates/
    dialogs/               properties, conflicts, batch rename, settings
    command_palette.zig
    quick_look.zig
    terminal.zig           right-side QTermWidget panel
    terminal_widget.cpp    C ABI shim for QTermWidget (g++)
    player.zig             QtMultimedia player, transport controls, repeat/shuffle, playlist
    status_bar.zig
  platform/
    linux/
      inotify.zig
      xattr.zig
      trash.zig
      udisks.zig
      polkit.zig
      xdg.zig
  qt/
    facade.zig             thin wrappers around libqt6zig quirks
```

The prototype is split into `src/main.zig` (Qt entrypoint), `src/app.zig` (window, tabs, panes, navigation, search UI), and `src/core/` (path resolution, scanners, and the SQLite index). It should continue moving toward the layout above as features land rather than growing `app.zig` indefinitely.

### 5.3 VFS interface

Everything the UI browses is a VFS location, including local folders. This keeps split view, search results, archives, and remote servers on the same code path.

```zig
pub const Vfs = struct {
    vtable: *const VTable,
    context: *anyopaque,

    pub const VTable = struct {
        scheme: *const fn () []const u8,
        list: *const fn (*Vfs, path: []const u8, opts: ListOptions, ctx: *OpContext) Error!Listing,
        stat: *const fn (*Vfs, path: []const u8, ctx: *OpContext) Error!Stat,
        openRead: *const fn (*Vfs, path: []const u8, ctx: *OpContext) Error!Reader,
        openWrite: *const fn (*Vfs, path: []const u8, opts: WriteOptions, ctx: *OpContext) Error!Writer,
        createDir: *const fn (*Vfs, path: []const u8, ctx: *OpContext) Error!void,
        remove: *const fn (*Vfs, path: []const u8, ctx: *OpContext) Error!void,
        rename: *const fn (*Vfs, from: []const u8, to: []const u8, ctx: *OpContext) Error!void,
        watch: ?*const fn (*Vfs, path: []const u8, cb: WatchCallback) Error!WatchHandle,
        capabilities: *const fn () Capabilities,
    };
};
```

URI examples:

- `file:///home/user`
- `trash:///`
- `search://tag:work%20type:pdf`
- `archive:///home/user/backup.zip!/folder`
- `sftp://host/home/user`
- `smb://server/share`
- `mtp://device/Internal storage/DCIM`

Capabilities tell the UI what is possible: rename, delete, trash, watch, random write, thumbnails, permissions, case sensitivity, and whether operations can be paused.

### 5.4 Custom item model

`QFileSystemModel` is fine for a prototype but not for Ligma:

- It cannot represent remote, archive, and search results uniformly.
- It has limited column and metadata support.
- Filtering and sorting behavior is not under our control.
- It does not expose operation progress or custom roles.

**Implemented in the v0.5 prototype:** `src/ui/local_model.zig` provides `LocalModel`, a `QAbstractItemModel` subclass backed by a flat, immutable snapshot of one folder. A worker thread enumerates the directory with `std.Io.Dir` and records name, path, kind, size, and mtime; the completed snapshot is published through an atomic flag, and the UI applies it with a model reset from a 50 ms timer. Filtering (case-insensitive substring over file names; directories stay visible) and sorting (name, size, kind, modified; folders always first) run in memory on the UI thread. Qt's `index`, `parent`, `rowCount`, `columnCount`, `hasChildren`, `data`, `headerData`, `flags`, and `sort` virtuals are bridged through `libqt6zig` callbacks, with a pointer registry mapping each C++ model to its Zig state. Navigation, reload, hidden-file toggling, selection status, and post-operation refresh all go through this model.

The planned `LigmaModel` extends this snapshot API into the VFS layer. Each snapshot will contain mode, owner, group, MIME type, icon key, tags, rating, and extension columns, and the model will support:

- Lazy, cancellable directory and subtree loads.
- Stable sort and group orders independent of each other.
- In-place updates from the file watcher without resetting the whole view.
- A flat "current folder" mode and a tree mode over the same snapshot API.
- Trash, archive, search, and remote-location snapshots behind one interface.

A `QSortFilterProxyModel` is not used for the primary filter; matching happens in Zig against the snapshot so the filter is O(visible) and can support glob, regex, and metadata predicates.

### 5.5 File operation engine

Requirements:

- Queue multiple operations; run N workers based on device and operation type.
- Per-operation and per-file progress, speed, ETA, and error list.
- Pause, resume, cancel, retry, skip, overwrite, rename, and "apply to all".
- Undo/redo journal persisted across sessions.
- Copy preserves mode, timestamps, xattrs, ACLs where possible, sparse regions, and hard links within a batch.
- Move is rename when possible, copy+delete across devices.
- Use `copy_file_range`/`sendfile` with a read/write fallback; handle `EXDEV`, `ENOSPC`, `EINTR`, and partial writes.
- Trash follows the freedesktop.org Trash specification and works across mount points.
- Operations never run on the UI thread.

Conflict resolution is a first-class dialog with per-file and bulk choices. A "dry run" preview is available for batch rename and complex moves.

**Implemented in the v0.3 prototype:** `src/core/file_ops.zig` provides an asynchronous `Job` with copy, move, trash, permanent delete, rename, mkdir, and undo workers. Each job owns its inputs, reports progress through atomics, supports cooperative cancellation, and returns owned undo records. Copy is recursive over files, directories, and symlinks; moves use `rename` with a copy-plus-delete fallback across devices; collisions produce `name (n).ext` rather than overwriting. Trash follows the freedesktop.org layout under `$XDG_DATA_HOME/Trash` with percent-encoded `Path=` metadata, UTC deletion dates, and restore support. The UI runs one job at a time, prompts for names with `QInputDialog`, confirms permanent deletion, and keeps an in-memory undo stack. Not yet implemented: the operation queue, pause/resume, conflict dialogs, batch rename preview, metadata/ACL preservation, persistent history, and redo.

### 5.6 Search and index

Two distinct experiences:

1. **Current-folder filter** — instant, in-memory, no index. Typing filters the current snapshot. Modes: substring (default), glob, regex. Directories can be included or excluded with a toggle.
2. **Global search** — SQLite FTS5 index over indexed roots, opt-in per root. Filename and path are always indexed; content indexing is opt-in.

Schema (sketch):

```sql
CREATE TABLE roots (
  id INTEGER PRIMARY KEY,
  path BLOB NOT NULL UNIQUE,
  content_indexed INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
  path BLOB NOT NULL UNIQUE,
  parent BLOB NOT NULL,
  name TEXT NOT NULL,
  kind INTEGER NOT NULL,
  size INTEGER NOT NULL,
  mtime_ns INTEGER NOT NULL,
  mode INTEGER NOT NULL,
  dev INTEGER NOT NULL,
  ino INTEGER NOT NULL
);

CREATE VIRTUAL TABLE files_fts USING fts5(
  name, path, content,
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TABLE tags (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  PRIMARY KEY (file_id, tag)
);

CREATE TABLE ratings (
  file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
  stars INTEGER NOT NULL CHECK (stars BETWEEN 0 AND 5),
  comment TEXT
);
```

Additional trigram index for substring matching:

```sql
CREATE VIRTUAL TABLE name_trigram USING fts5(name, tokenize='trigram');
```

**Implemented in the v0.2 prototype:** `src/core/search_index.zig` builds `files`, `files_fts` (unicode61), and `files_fts_trigram` external-content tables in `$XDG_DATA_HOME/ligma/search.db`. The initial build walks the home directory breadth-first on a worker thread in WAL mode, skips the shared ignore list, and marks completion in a `meta` table. The UI uses the trigram index for queries of three or more characters, an escaped `LIKE` scan for shorter queries, and falls back to the live scanner while building or outside the indexed root. Incremental crawls, inotify updates, multiple roots, content extraction, and the query language below are still planned.

Indexing behavior:

- Initial crawl is incremental, resumable, and throttled when the user is active.
- inotify watches are installed per directory; overflow triggers a targeted rescan.
- Ignore rules: `.git`, `node_modules`, trash, cache dirs, and user-defined exclusions.
- Content extraction is delegated to small helpers: plain text/code, PDF (`pdftotext` or Qt6Pdf), office documents via optional tools, media metadata via ffmpeg.
- Index lives in `$XDG_DATA_HOME/ligma/search.db` with WAL, `busy_timeout`, and periodic `PRAGMA optimize`.
- Query cancellation token checks between result batches.
- Search results show path, match context, and actions ("open", "open containing folder", "reveal in list").

Query language examples:

```
report type:pdf modified:<7d
size:>1M tag:work path:projects
*.rs content:"async fn" modified:today
rating:>=4 tag:reference
```

Search ranking blends match quality, recency, and frecency. The first 100 results are returned before the full query finishes.

### 5.7 Metadata

Source of truth:

- Tags, rating, comment, color label, and emblems are stored in SQLite for speed.
- The same values are mirrored to xattrs (`user.ligma.meta` as compact JSON) when the filesystem supports them, so metadata survives a reinstall and moves with the file.
- If xattrs are unavailable, SQLite remains the fallback; a sidecar `.ligma-meta.json` export is available for sync services.
- Optional Baloo import/export maps tags, ratings, and comments to/from Baloo.

Metadata is visible in the details columns, information panel, search, and grouping.

### 5.8 Previews and thumbnails

**Implemented (v0.4):** the single-selection preview panel (`src/ui/preview.zig`) rides on the selection model — not the current index — because Qt moves the current index before extending a Shift+arrow selection, and a model reset clears the selection without emitting a signal. In-flight ffmpeg jobs are keyed by `QProcess` pointer and cleaned up through stale-sequence checks in their `finished`/`errorOccurred` callbacks; `FailedToStart` is handled in the error path because Qt emits no `finished()` in that case.

Planned generalization:

- Provider API: MIME patterns, priority, `createWidget(path)`, `createThumbnail(path, size)`, and optional metadata extraction.
- Built-in providers: image, PDF, video, audio, text/code, HTML, archive listing, directory summary, font, and SVG.
- Thumbnails are generated off the UI thread and cached by content identity (path + mtime + size + provider version).
- Failed previews are cached briefly to avoid retry storms.
- Large files and network locations have size/time limits and a cancel path.
- Quick Look never blocks the file list; it shows a loading state and can be dismissed immediately.

### 5.9 Extension system

Three tiers, from easiest to most powerful.

#### Tier 1 — declarative actions

`.desktop`-style files in:

- `~/.local/share/ligma/actions/`
- `/usr/share/ligma/actions/`

Example:

```ini
[Desktop Entry]
Type=Action
Name=Optimize PNG
Icon=image-x-generic
Profiles=image/png;
Exec=ligma-optimize-png %F
MimeType=image/png;
X-Ligma-Submenu=Image Tools
X-Ligma-Multiple=true
```

Supported placeholders: `%f`, `%F`, `%u`, `%U`, `%d`, `%D`, `%n`, `%N`, `%b`, `%B`. Commands are executed without a shell; arguments are passed as an argv array. A shell mode is available but requires explicit opt-in.

Importers:

- Nemo action files from `~/.local/share/nemo/actions/`.
- Dolphin service menus from `~/.local/share/kio/servicemenus/` and `/usr/share/kio/servicemenus/`.

This gives Ligma a large existing action ecosystem on day one.

#### Tier 2 — JavaScript extensions

- Embedded QuickJS runtime (MIT) with no ambient I/O.
- Manifest `manifest.json` declares name, version, permissions, activation events, and contributions.
- Host API:

```js
ligma.commands.register("com.example.optimize", async (ctx) => {
  const files = await ctx.selection.paths();
  await ctx.fs.run("oxipng", ["-o", "4", ...files]);
  ctx.ui.notify("Optimized " + files.length + " files");
});

ligma.menu.addItem({
  menu: "context",
  title: "Optimize PNG",
  when: "selection.mime:image/png",
  command: "com.example.optimize"
});

ligma.columns.register({
  id: "image.dimensions",
  title: "Dimensions",
  value: async (file) => file.meta("image.width") + "×" + file.meta("image.height")
});
```

Permissions: `filesystem.read`, `filesystem.write`, `process.spawn`, `network`, `clipboard`, `notifications`, `metadata.write`. Permissions are shown at install time and can be revoked.

#### Tier 3 — native plugins

- Versioned C ABI (`ligma_plugin_v1`) loadable from `.so` files.
- Can provide VFS backends, preview providers, column providers, commands, and background services.
- Written in Zig (preferred) or C. No Qt ABI dependency; the plugin uses host services for UI.
- Native plugins are trusted code and are not sandboxed by default; distribution packages should be signed.

Extension lifecycle: install → validate manifest → permission prompt → enable → load lazily on activation event → update with migration → disable/uninstall. API versioning follows semver with a documented deprecation window.

### 5.10 Settings and state

- User config: `$XDG_CONFIG_HOME/ligma/config.toml` (human-editable, commented).
- State DB: `$XDG_DATA_HOME/ligma/state.db` (per-folder views, sessions, bookmarks, metadata, operation journal).
- Cache: `$XDG_CACHE_HOME/ligma/` (thumbnails, search cache, preview failures).
- Runtime: `$XDG_RUNTIME_DIR/ligma/` (single-instance socket, IPC).
- Settings search and import/export; schema migrations with backups.
- Defaults are casual-friendly. Advanced options are grouped under "Advanced" and exposed in the command palette.

### 5.11 Security model

- No shell interpolation for actions; use argv arrays.
- Destructive operations require confirmation by default; permanent delete is never the default.
- Privileged operations go through polkit and a small helper, not a root UI process.
- Extension permissions are explicit and revocable.
- Remote credentials go to the system keyring (Secret Service) or an encrypted credential store, never plain text config.
- Path traversal, symlink attacks, and TOCTOU are handled in the VFS/operation layer with `openat`-style APIs where possible.
- Untrusted archives are extracted with path sanitization and optional size limits.

---

## 6. Performance budgets

| Scenario | Target |
|---|---|
| Cold start to first window | < 200 ms |
| Warm start to first window | < 80 ms |
| 10k-entry folder, first paint | < 100 ms |
| 100k-entry folder, first paint | < 500 ms |
| Keystroke-to-filter update | < 16 ms |
| Global search, first results, 1M files | < 150 ms |
| Memory, 1M indexed files, idle | < 200 MB |
| Copy throughput | within 10% of `cp -a` |
| Thumbnail generation | never blocks UI; cancelable |

Rules:

- No synchronous `stat` storms on the UI thread.
- Batch and cache MIME/icon lookups.
- Avoid full model resets for watcher updates.
- Profile startup with `perf` and Qt's `QT_LOGGING_RULES`; keep a benchmark corpus in `bench/`.
- Use release-safe builds for benchmarks; test debug builds for assertions and leaks.

---

## 7. Roadmap

### Phase 0 — Stack validation (done)

- Zig 0.17 + Qt 6.12 + `libqt6zig` build.
- Main window with places, navigation, path bar, filter, hidden files, status bar.
- Verified on Wayland (screenshot) and offscreen; X11 smoke test.

### Phase 1 — Core file manager (MVP)

Acceptance criteria:

- Custom `LigmaModel` replaces `QFileSystemModel` (flat local snapshot done in v0.4).
- Tabs, split view, icon/compact/details/tree views.
- Local VFS, trash VFS, bookmarks, recent, breadcrumbs, editable path.
- Copy/move/rename/delete/trash/duplicate, drag and drop, operation queue with pause/resume/cancel and undo.
- Properties/permissions, new folder, batch rename (basic), hidden files.
- Current-folder filter (substring + glob), sort/group, zoom.
- Session restore and per-folder view settings.
- Keyboard map and command palette skeleton.
- No blocking I/O on the UI thread; 10k-entry folder under 100 ms.

### Phase 2 — Power features

- Embedded terminal and external terminal integration.
- Archive VFS, compress/extract, archive preview.
- Quick Look and information panel; thumbnail cache.
- Batch rename with preview, move/copy to, make link, image resize/rotate, set wallpaper.
- Per-folder view/zoom, configurable toolbar, templates manager.
- Selection mode, focus-other-view, Miller columns.
- Root/polkit operations; properties editing.
- Free-space and selection-size status; operation history UI.

### Phase 3 — Search and metadata

- SQLite FTS5 index, incremental crawler, inotify.
- Global search UI, query language, filters by type/date/size/tag.
- Starred, recent, frecency.
- Tags/ratings/comments/emblems; details columns; grouping by metadata.
- Optional Baloo import/export; duplicate finder.
- Search benchmarks and index health tools.

### Phase 4 — Remote, devices, and cloud

- SFTP, SMB, WebDAV, FTP, MTP backends.
- Mount/unmount and removable media via UDisks2.
- GVfs bridge for cloud/GOA locations; optional KIO-FUSE bridge.
- Network discovery and "Connect to Server".
- Credential storage via Secret Service.
- KDE Connect optional integration.

### Phase 5 — Extensions

- Declarative actions and context menu integration.
- Nemo action and Dolphin service-menu importers.
- QuickJS extension host with permissions and API docs.
- Native plugin ABI and SDK examples.
- Extension manager UI; install/enable/disable/update.
- Git integration plugin as a reference.

### Phase 6 — Polish and desktop integration

- Optional desktop icons with compositor capability detection.
- Tab overview, window/tab restoration polish.
- Accessibility audit, screen-reader support, high contrast.
- Translations and RTL.
- Flatpak, AppImage, and distro packaging.
- AppStream metadata, `.desktop` file, icons, MIME associations.
- Performance hardening and long-running soak tests.

---

## 8. Testing and quality

- **Unit tests:** path/URI parsing, query parser, conflict resolution, trash spec, rename templates, settings migrations, metadata encoding.
- **Integration tests:** operations against temporary directories; fault injection for `ENOSPC`, `EACCES`, `EIO`, interrupted copies; archive extraction safety; symlink/TOCTOU cases.
- **UI tests:** Qt offscreen platform, QTest-style key/mouse simulation, screenshot diffs for critical dialogs.
- **Search tests:** corpus with unicode, case folding, diacritics, long paths, 1M synthetic files; measure latency and index size.
- **Fuzzing:** query parser, manifest parser, archive path sanitizer, `.desktop` action parser.
- **Leak/UB checks:** debug allocator, ASAN/Valgrind on core tests; Qt object lifetime audit around model/view boundaries.
- **Benchmarks:** startup, folder load, filter, search, copy, thumbnail; tracked per release.
- **CI:** `zig fmt --check`, `zig build`, `zig build test`, offscreen smoke test, packaging checks.

---

## 9. Packaging and distribution

- Build system: `zig build`; no CMake requirement.
- Qt 6.8+ runtime, dynamically linked; document distro packages.
- `libqt6zig` pinned by commit and hash; keep a patch set if upstream fixes are needed.
- Optional features via build options: `-Dgvfs=true`, `-Dkio=true`.
- Desktop entry: `org.ligma.FileManager.desktop`; AppStream metadata; hicolor icons.
- Flatpak: bundle Qt and required libraries; avoid optional GPL components unless the app license is compatible.
- Release channels: nightly, beta, stable; settings migration tested across channels.

---

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `libqt6zig` is a generated binding and may lag Qt or have gaps | Build/API breakage | Pin commit; wrap in `src/qt/facade.zig`; upstream patches; keep a C++ escape hatch for missing APIs |
| Qt object ownership and callback lifetimes are subtle | Crashes/leaks | Confine Qt calls to the main thread; explicit ownership rules; ASAN and stress tests |
| Custom model complexity | Performance and correctness bugs | Start with immutable snapshots; incremental update tests; benchmark 100k entries |
| File operation correctness across filesystems | Data loss | Small, well-tested primitives; dry-run mode; fault injection; never delete source until destination is durable |
| Wayland desktop icons | Feature cannot work uniformly | Optional layer-shell component; detect compositor support; do not block core |
| qtermwidget6 is LGPL-2.0-or-later and may be absent on some distributions | Build and runtime dependency | Document the development package; isolate the API behind `terminal_widget.cpp`; keep the panel small and replaceable |
| Search index privacy and size | User trust, disk usage | Opt-in roots, ignore rules, clear index UI, size limits, local-only by default |
| Remote protocol scope is huge | Schedule risk | Native SFTP/SMB first; GVfs/KIO bridge instead of reimplementing cloud providers |
| Extension security | Malicious actions/plugins | Permissions, no shell by default, sandbox JS, trust native plugins, signed packages |
| Root operations | Privilege escalation | Polkit helper with narrow operations; no root UI; audit |

---

## 11. Open decisions

These need a product decision before the relevant phase:

1. **Project name.** Selected: "Ligma"; trademark and package-name checks still pending.
2. **License.** Decided: GPL-3.0-or-later.
3. **Terminal strategy.** Decided: QTermWidget panel on `F12`, docked on the right, with a C++ C-ABI shim; two-way directory synchronization is deferred.
4. **Remote strategy.** Start with native SFTP/SMB, or start with a GVfs bridge because it delivers cloud providers faster.
5. **Desktop icons.** Confirm whether this is a v1 priority or a later optional component.
6. **Extension language.** QuickJS is the current proposal; Lua or WASM would change the sandboxing and dependency story.
7. **Minimum distribution targets.** Qt 6.8 vs 6.12, glibc baseline, Flatpak-only vs distro packages.

---

## 12. Current implementation status

Implemented in the v0.5 prototype:

- Zig 0.17 + Qt 6.12 window using `libqt6zig`, split into `main.zig`, `app.zig`, `ui/`, and `core/`.
- Places sidebar (Home, XDG folders, Filesystem).
- Back/forward/up/home/reload navigation with independent per-pane history.
- Editable path bar with `~`, relative-path, and `file://` resolution.
- Custom `LocalModel` (`src/ui/local_model.zig`) replacing `QFileSystemModel`: worker-thread folder enumeration, UI-timer polling, and a flat details snapshot.
- Details view with Name, Size, Kind, and Modified columns; folder-first sorting by any column.
- In-memory case-insensitive substring filter (directories remain visible) that never touches the filesystem.
- Hidden-file toggle that applies to every pane.
- File opening through the desktop's default application, with audio routed to the built-in player.
- Built-in music player (`src/ui/player.zig`): MIME-based audio activation, bottom dock (`F9`), playlist, previous/play-pause/next/stop, repeat (off/all/one), shuffle, seek, volume, and auto-advance at end of media. Audio selections also expose **Play** and **Add to Playlist** in the context menu.
- Queue clearing on natural completion when repeat is off; manual Next/Previous and Stop leave the queue intact. Repeat all/one preserve entries.
- Discord Rich Presence (`src/core/discord.zig`): title/artist/album from `QMediaMetaData`, timestamps while playing, pause/stop handling, local socket discovery for native and Flatpak clients, and configurable app ID.
- Executable files (ELF binaries, scripts, AppImages) can be launched after a confirmation prompt by pressing Enter, double-clicking, or choosing `File > Run Selected` (`Ctrl+Return`); the process starts detached with the file's folder as its working directory.
- Tabs (`Ctrl+T`, `Ctrl+W`) and split view (`F3`, `F6`); panes keep independent state.
- Global filename search with streamed results in a dock.
- SQLite FTS5 index (`files`, `files_fts`, `files_fts_trigram`) with WAL, background home-directory crawler, status-bar health, and a rebuild action.
- Live breadth-first scanner fallback while indexing, outside the indexed root, or when indexing is disabled.
- Asynchronous file operations (`src/core/file_ops.zig`): copy, cut, paste, rename, new folder, trash, permanent delete, and undo.
- Drag and drop between panes/folders via `text/uri-list`: internal move by default, Ctrl-copy, folder-row targeting, external copy-only drops, and collision-safe naming.
- Freedesktop.org trash with percent-encoded `Path=` metadata, UTC `DeletionDate=`, collision-safe names, and restore through undo.
- In-memory undo journal for the last completed batch; progress and cancellation in the status bar; `Escape` cancels.
- Blue-and-purple floppy application icon (`assets/`): scalable SVG, nine PNG sizes in the hicolor theme, a desktop entry, and an embedded window icon.
- Menus, keyboard shortcuts, item count, window title, and clean shutdown.
- Builds and runs on Wayland; smoke-tested offscreen and via X11, including end-to-end file-operation UI automation.

Known prototype limitations (addressed in later phases):

- The model is a flat single-folder snapshot: no tree expansion, icons, thumbnails, or per-folder view state yet.
- No filesystem watcher yet; external changes appear after a manual reload (`F5`) or the next file operation.
- No trash browsing or VFS abstraction yet.
- Executables run detached without a terminal, allow-list, or remembered confirmation, so command-line tools with no GUI produce no visible output.
- One file operation at a time; no queue, pause/resume, conflict dialog, or redo.
- Undo history is in memory, holds only the last completed batch, and is not persisted across restarts.
- Copy does not preserve xattrs, ACLs, sparse regions, hard links, or timestamps yet.
- No metadata editing, remote locations, archives, or extensions yet.
- The music playlist is in memory only and is not persisted across restarts; album art is not shown in the player.
- Discord Rich Presence requires a running Discord desktop client; metadata depends on tags supplied by the FFmpeg backend, and the app falls back to filenames for untagged files.
- Search index has no incremental watcher or multiple roots; rebuild manually after large changes. File operations do not update the index.
- Status bar selection message can be stale after some navigation transitions.
- Place selection does not follow path-bar navigation.
- Filter is a case-insensitive substring over file names; wildcards and regex are not supported yet, and directories remain visible.

The next engineering step is adding a local/trash VFS behind `LocalModel`, followed by per-folder view state and incremental file watching. After that come incremental file watching and search indexing. New features should continue moving into `src/core/` and `src/ui/` rather than accumulating in `app.zig`.
