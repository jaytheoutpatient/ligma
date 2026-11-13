# Ligma

A Linux file manager that combines the best of Nautilus, Nemo, and Dolphin — built in Zig with Qt 6.

Ligma is licensed under **GPL-3.0-or-later** (see [`LICENSE`](LICENSE)).

## Why

Nautilus is polished, Nemo keeps the classic power features, and Dolphin has the best power-user workflow. Ligma aims to combine them with three hard differentiators:

- **Speed** — instant navigation and never-blocking file operations.
- **Search** — instant current-folder filtering and a useful global index.
- **Extensions** — actions, a modern script API, and native plugins.

Target user: between casual and power user. Linux only. Wayland first, X11 supported.

Read the full product and technical specification in [`docs/spec.md`](docs/spec.md).

## Status

This repository contains a working **v0.5 prototype**:

- Zig 0.17 + Qt 6.12 via [`libqt6zig`](https://github.com/rcalixte/libqt6zig)
- Places sidebar, details view, item count, and window title
- **Custom item model** — `src/ui/local_model.zig` lists folders on a worker thread, polls snapshots from the UI, and renders Name/Size/Kind/Modified columns
- Back / forward / up / home / reload navigation with per-pane history
- Editable path bar with `~`, relative-path, and `file://` resolution
- In-memory current-folder filter and folder-first sorting by any column
- Hidden-file toggle
- Opens files with the desktop's default application, except audio files that play in the built-in music player
- **Tabs** — `Ctrl+T`, `Ctrl+W`, `Ctrl+Shift+W`
- **Split view** — `F3` toggles, `F6` focuses the other pane; panes keep independent history and filters
- **Global filename search** — `Ctrl+Shift+F`, streamed results in a search dock
- **SQLite FTS5 search index** — automatic background build, trigram substring matching, status-bar health, and `View > Rebuild Search Index`
- **Async file operations** — copy, cut, paste, rename, new folder, trash, permanent delete, and undo, all on a worker thread with progress and cancellation
- **Context menu file actions** — right-click any row for *Open*, *Open in Terminal*, *Cut*, *Copy*, *Paste*, *New Folder…*, *Properties*, *Move to Trash*, and *Delete Permanently*. Right-clicking an unselected row targets it first, right-clicking a selected row keeps a multi-selection, and right-clicking empty space clears the selection while leaving *Paste* and *New Folder* available. *Properties* reports name, kind, size, location, modified time, and permissions, or the count and total size of a multi-selection
- **Drag and drop** — drag selected rows to move them, or hold Ctrl to copy. Drop onto a folder row or into a pane's empty space. Drags from other applications always copy, same-folder drops are no-ops, and collisions use the same `name (1).ext` naming as paste
- **Freedesktop.org trash** — `Path=`/`DeletionDate=` `.trashinfo` files, collision-safe names, and restore via undo
- **Undo journal** — the last completed batch can be reversed with `Ctrl+Z`, including copies, moves, renames, new folders, and trashed items
- **Custom Places bookmarks** — right-click a folder and choose *Add to Places* to pin it to the sidebar; right-click a user-added entry to remove it. Bookmarks persist in `$XDG_CONFIG_HOME/ligma/places` (or `~/.config/ligma/places`)
- **Embedded terminal** — `F12` toggles a terminal panel docked on the right; the first open starts the user's shell in the active folder, and the session survives hiding and reopening
- **Run executables** — activating an executable file asks for confirmation, then launches it detached with its folder as the working directory
- **Preview panel** — selecting exactly one image or video file shows a larger thumbnail in the window's bottom-left corner
- **Built-in music player** — activating an audio file opens a bottom panel with prev/play-pause/next/stop, repeat (off/all/one), shuffle, a seek bar, volume, and a playlist. Finished tracks leave the queue unless repeat is active, and the context menu adds **Play** and **Add to Playlist** for audio selections
- **Discord Rich Presence** — shows the current song title and artist/album in Discord through its local IPC socket, with no bot token, network service, or account linking
- **Blue-and-purple floppy icon** — a custom scalable app icon, installed as `org.ligma.FileManager` in the hicolor theme and embedded in the binary for the window icon

Search falls back to a cancellable breadth-first filename scan while the index is building, when no index exists, or when the active folder is outside the indexed root.

Not implemented yet: trash browsing, file watching, metadata, remote locations, archives, and extensions. See the roadmap in the spec.

## Preview panel

Selecting exactly one file whose MIME type is `image/` or `video/*` shows a thumbnail in a small panel at the bottom of the Places sidebar. The panel hides for folders, text files, multi-selections, and empty selections.

- Images are decoded with `QImageReader` straight into the display size, so opening a large photo never allocates the full image.
- Video thumbnails are extracted by an asynchronous `ffmpeg -ss 1 -frames:v 1` job into a temporary PNG; videos shorter than the one-second seek are retried from frame 0.
- MIME classification is content-aware (`QMimeDatabase.mimeTypeForFile`), not extension-based.
- Selection semantics follow the selection model, not the current index: the panel tracks `selectionChanged`, so Shift+arrow extensions (where Qt moves the current index before extending the selection) and model resets (which clear the selection without a signal) both resolve correctly.

Current limitations: no thumbnail cache, one ffmpeg process per selection change, no debouncing, and a fixed 212×168 thumbnail box that does not adapt to the sidebar width. These are tracked for the thumbnail/cache milestone in the spec.

## Terminal panel

Press `F12` to show or hide a terminal docked on the right side of the window. The first time it opens, it starts `$SHELL` in the active pane's folder; hiding and reopening keeps the same shell session and working directory. The View menu has a matching **Terminal Panel** item, and the dock's title-bar button hides it. F12 works both from the file list and from inside the terminal.

The terminal is [QTermWidget](https://github.com/lxqt/qtermwidget) (the widget used by QTerminal). Because it is a C++ Qt class, `src/ui/terminal_widget.cpp` provides a small C ABI shim that is compiled with the system C++ compiler and linked against the qtermwidget development package.

Right-clicking an item offers **Open in Terminal**, which shows the panel and points the shell at the row under the pointer: a folder opens there, a file opens in its containing folder, and right-clicking empty space uses the pane's current folder. If the shell is already running, it receives a `cd` only when it is sitting at a prompt, so a foreground job (an editor, a long build) is not interrupted.

The panel is intentionally not synchronized in both directions yet: navigating in Ligma after the shell starts does not `cd` the shell, and `cd` in the shell does not navigate the pane.

## Music player

Activating a file whose MIME type is `audio/*` plays it in the built-in player instead of launching a separate application. The player is a dock at the bottom of the window; `F9` or **View > Music Player** toggles it.

- **Play / Pause**, **Previous**, **Next**, and **Stop** control the current track.
- **Repeat** cycles **off → all → one**. Repeat all wraps at the end; repeat one restarts the current track.
- **Shuffle** picks a random other track for Next and for automatic advancement.
- The seek slider follows playback and can be dragged to jump. The volume slider sets output volume for this player.
- Activating another audio file appends it to the playlist (or reuses its existing entry) and starts it. **Add to Playlist** appends every selected audio file without interrupting the current track.
- **Play** in the context menu replaces the queue with the selected audio files and starts the first one. The playlist widget also accepts clicks to jump to a track.
- Files are classified with `QMimeDatabase`, so content-detected audio formats work even when their extension is unusual.
- Closing the dock keeps the playlist and playback alive; reopening it shows the same state.
- QtMultimedia uses the FFmpeg backend when available. If the system has no working audio backend, the player surfaces the decoder error in the now-playing label instead of crashing.

### Queue behavior

- With repeat **off**, a track that reaches its natural end is removed from the queue and the next track starts. When the queue has no more tracks to play, playback stops.
- **Repeat all** and **Repeat one** keep every queue entry. Repeat all advances/wraps, while repeat one replays the same row.
- **Shuffle** changes which row is chosen next but does not remove anything by itself. With repeat off, shuffle plus natural advancement eventually drains the queue.
- Manual **Next** and **Previous** never remove queue entries, even when repeat is off. Only natural completion clears. **Stop** also leaves the queue intact.

### Discord Rich Presence

While a track is playing, Ligma publishes the song title and artist/album to a running Discord client through the local `discord-ipc-*` socket. It uses the registered Ligma Discord application ID and needs no bot token, OAuth login, or outbound network request.

- The activity shows the tagged title, artist, and album when available. Missing tags fall back to the filename; an unknown artist is omitted from the displayed details.
- Discord's `status_display_type` is set to **Details**, so the compact member-list line shows **Song — Artist** instead of only the application name. The profile card also shows the album when tagged.
- Discord shows elapsed/remaining progress while playing. Pausing keeps the title/artist but removes progress; stopping or quitting clears the activity.
- The connection is best-effort: if Discord/Vesktop is not running or restarts, playback continues normally and the client reconnects in the background.
- Set `LIGMA_DISCORD=0` to disable Rich Presence. `LIGMA_DISCORD_APP_ID` overrides the built-in application ID for development builds.
- The Discord desktop client must be running (native Discord, Vesktop, or a Flatpak build); Ligma checks the standard XDG and temporary runtime locations for its IPC socket.

## Search index

- Database: `$XDG_DATA_HOME/ligma/search.db`, or `~/.local/share/ligma/search.db`.
- The index is built in the background under the current home directory on first start.
- `.git`, caches, `node_modules`, build output, virtual environments, Trash, and Ligma's own data directory are skipped.
- The search dock and status bar show whether a query was served by the index or the live scanner.
- Rebuild at any time with `View > Rebuild Search Index`.
- Set `LIGMA_SKIP_INDEX=1` to disable automatic index builds. An existing completed index is still used.
- There is no incremental watcher yet; rebuild after large filesystem changes.

The schema uses SQLite FTS5 external-content tables (`files`, `files_fts`, and a trigram table) in WAL mode. Queries of three or more characters use the trigram index; shorter queries use an escaped `LIKE` scan.

## File operations

- Copy, cut, paste, rename, new folder, move to trash, and permanent delete run on a background worker thread. The UI stays responsive and shows progress in the status bar.
- `Escape` cancels the running operation. Partial output from the current item is removed; items that already finished remain and are still undoable.
- Copy and move never overwrite an existing name. Collisions become `name (1).ext`, `name (2).ext`, and so on.
- Moves use `rename(2)` when possible and fall back to copy-plus-delete across devices.
- Trash uses `$XDG_DATA_HOME/Trash`, falling back to `~/.local/share/Trash`, and writes freedesktop.org `.trashinfo` metadata. `Ctrl+Z` restores a trashed item and removes its metadata.
- Undo covers the most recent completed batch. The journal is in memory, is not persisted across restarts, and undo jobs cannot themselves be undone.
- Only one file operation runs at a time. Starting another while one is active is rejected with a status message.

## Drag and drop

Drag one or more selected rows onto a folder row or into a pane's empty space. The default action is **move**; hold **Ctrl** when starting the drag to **copy** instead. Internal drags show a drop indicator, and a completed drop is one normal undoable file operation (`Ctrl+Z`).

- Dropping on a folder row targets that folder; dropping over empty space targets the pane's current folder.
- Dropping an item back into its own folder is ignored instead of creating a duplicate.
- Folders cannot be dropped inside themselves, and the single-operation limit applies while another file job is running.
- Drags that originate in another application are always copied into Ligma, never moved.
- Name collisions use the same collision-safe `name (1).ext` scheme as paste.

## Build

### Requirements

- Linux
- Zig **0.17.0**
- Qt **6.8+** development files (tested with 6.12.0), including QtMultimedia and a multimedia backend
- QTermWidget **2.x** for Qt 6 development files (`qtermwidget6.pc`; Arch: `qtermwidget`)
- SQLite 3 development files with FTS5 and the trigram tokenizer (tested with 3.54.1)
- A C/C++ toolchain (`g++`) and `pkg-config`

On Debian/Ubuntu-style systems:

```bash
sudo apt install build-essential pkg-config qt6-base-dev qt6-multimedia-dev libsqlite3-dev
# plus the Qt 6 qtermwidget development package for your release
# and QtMultimedia with its FFmpeg backend
```

On Arch Linux: `sudo pacman -S qt6-base qt6-multimedia qt6-multimedia-ffmpeg sqlite qtermwidget`.

The build fetches the pinned `libqt6zig` dependency automatically. The first build compiles only the Qt wrappers the app uses, so it is much faster than building the entire binding repository.

### Commands

The repository includes a build script that checks the required development
packages, builds a ReleaseSafe binary, and stages the desktop entry and icons:

```bash
./build.sh          # ReleaseSafe build
./build.sh --test   # build and run tests
./build.sh --run    # build and launch
./build.sh --help   # all options
```

The raw Zig commands remain available:

```bash
zig build          # build to zig-out/bin/ligma
zig build run      # build and run
zig build check    # compile without installing
zig build test     # run tests
```

Run with an explicit Qt platform when testing without a display:

```bash
QT_QPA_PLATFORM=offscreen zig build run
```

`zig build` also stages the desktop entry and icons under `zig-out/share`.
Install the binary and desktop integration system-wide with `./build.sh
--install`, or manually:

```bash
sudo install -Dm755 zig-out/bin/ligma /usr/bin/ligma
sudo cp -a zig-out/share/. /usr/share/
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
sudo update-desktop-database /usr/share/applications
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+T` / `Ctrl+W` | New tab / close tab |
| `Ctrl+Shift+W` | Close window |
| `F3` / `F6` | Toggle split view / focus other pane |
| `F12` | Toggle the terminal panel |
| `F9` | Toggle the music player |
| `Ctrl+L` | Edit location |
| `Ctrl+F` | Filter current folder |
| `Ctrl+Shift+F` | Global filename search |
| `Ctrl+H` | Show hidden files |
| `Alt+Left` / `Alt+Right` | Back / forward |
| `Alt+Up` / `Alt+Home` | Up / home |
| `F5` | Reload |
| `Ctrl+Shift+N` | New folder |
| `F2` | Rename |
| `Ctrl+Return` | Run the selected executable (with confirmation) |
| `Delete` | Move to Trash |
| `Shift+Delete` | Delete permanently |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste |
| `Ctrl+Z` | Undo last completed file operation |
| `Escape` | Cancel the running file operation |
| `Ctrl+Q` | Quit |

## Project layout

```
build.sh               dependency check, build, test, and install helper
build.zig              Zig build definition and the Qt wrapper link list
build.zig.zon          pinned libqt6zig dependency and package metadata
src/main.zig           Qt entrypoint
src/app.zig            window, tabs, panes, navigation, search and file-operation UI
src/ui/local_model.zig  async flat directory model with filter and sort
src/ui/terminal.zig     Zig wrapper for the embedded terminal panel
src/ui/terminal_widget.cpp  QTermWidget C ABI shim (compiled with g++)
src/ui/player.zig       QtMultimedia music player and playlist
assets/                 .desktop entry and hicolor icon set
src/core/file_ops.zig  async copy/move/trash/delete/rename/mkdir/undo engine
src/core/paths.zig     path and file:// resolution
src/core/search_scan.zig  cancellable live filename scanner
src/core/search_index.zig SQLite FTS5 index, reader, background builder
src/core/discord.zig    local Discord Rich Presence IPC client
src/core/skip.zig      shared ignore rules for scanners
docs/spec.md           product, architecture, feature matrix, roadmap
```

## Dependency pin

`libqt6zig` is pinned to commit `76fbd35d3b4d67721e5ca5cd323c06cd83afeaad` with a package hash in `build.zig.zon`. This keeps builds reproducible and avoids relying on a local clone.

The binding is MIT-licensed. Qt itself is LGPL-licensed; distribution must meet Qt's LGPL obligations. Optional components such as qtermwidget6 have their own licenses.

## Near-term plan

1. Add trash browsing through the model's VFS layer and per-folder view state.
2. Add file watching so views refresh without a manual reload.
3. Add incremental search indexing with inotify and a query language.
4. Then move to metadata, previews, remote locations, and extensions.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
