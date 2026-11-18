# Ligma

A Linux file manager that combines the best of Nautilus, Nemo, and Dolphin — built in Zig with Qt 6.

Ligma is licensed under **GPL-3.0-or-later** (see [`LICENSE`](LICENSE)).

## Quick start

```bash
git clone https://github.com/jaytheoutpatient/ligma.git
cd ligma
./build.sh
```

The build script installs missing development packages, builds Ligma, then installs it system-wide after a successful build.

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
- Places and Drives sidebar, Details/Icons/Compact/Grid views, item count, and window title
- **Custom item model** — `src/ui/local_model.zig` lists folders and Trash on a worker thread, polls snapshots from the UI, and renders folder or trash-specific columns
- **Live folder refresh** — watches every open pane and the Trash directory, coalesces filesystem events, reloads the affected snapshots, and restores the selection
- **Drives** — the sidebar lists mounted volumes plus unmounted USB/removable partitions. Mounted rows show a free-space label and a used-capacity progress bar; unmounted rows show **not mounted** and mount when clicked. Mounted drives sort before unmounted ones, and both groups sort naturally by label (so `Game Drive 10` follows `Game Drive 9`). USB filesystems without a label use the drive model instead of a UUID. Mounted removable drives get an **⏏ eject button**; right-click offers **Safely Remove** (unmount, then power off via UDisks2) or **Unmount**. Tooltips include the mount path, device, filesystem, and free/total space, and the list updates automatically when devices appear, mount, unmount, or disappear
- **Compact sidebar** — the Places and Drives lists size themselves to their contents and scroll once they reach a height cap, instead of leaving a large empty box. List borders are removed; selected and hovered rows use solid-to-transparent theme-accent gradients, and drive usage bars fade to transparent at their fill edge
- **Appearance** — **View > Appearance** switches between **Matugen**, **Light**, **Dark**, and **System**. Matugen reads the active qt6ct color scheme, so the file manager follows the same Material You palette as Qt applications; Light/Dark are built-in palettes and System follows the desktop. The choice persists in `$XDG_CONFIG_HOME/ligma/appearance` (or `~/.config/ligma/appearance`), and switching updates the sidebar, file pane, music player, and drive bars immediately. The Matugen entry is disabled when no scheme is installed
- **Settings** — **Edit > Preferences…** (`Ctrl+,`) opens a Ligma-styled settings window with General, Appearance, Views, Thumbnails, and Preview categories. Changes apply live; behavior, view, sidebar, preview, thumbnail, and window preferences persist in `$XDG_CONFIG_HOME/ligma/settings.toml`, while the color theme stays in `ligma/appearance`. Controls cover click activation, typing behavior, delete confirmation, new-tab switching, session restore, terminal command, theme, background opacity, corner roundness, compact menus, tab/status bar visibility, sidebar and drives, sidebar width, preview visibility and hover length, view mode, density, elision, emblems, hidden/backup files, sorting, grid icon size, scroll sensitivity, list columns, thumbnail policy and size limit, and video thumbnail/hover toggles
- Back / forward / up / home / reload navigation with per-pane history
- Editable path bar with `~`, relative-path, and `file://` resolution
- In-memory current-folder filter and folder-first sorting by any column
- Hidden-file toggle
- Opens files with the desktop's default application, except audio files that play in the built-in music player
- **Tabs** — `Ctrl+T`, `Ctrl+W`, `Ctrl+Shift+W`
- **Split view** — `F3` toggles, `F6` focuses the other pane; panes keep independent history and filters
- **View modes** — **Details** (`Ctrl+1`), **Icons** (`Ctrl+2`), **Compact** (`Ctrl+3`), and **Grid** (`Ctrl+4`). The Details and grid-style views share one selection model, so switching modes preserves the selected paths. Grid uses larger adaptive tiles with wrapped names and image/video thumbnails; Icons is the denser icon grid. Details rows use a full-row gradient delegate for selection and hover (readable light-theme text and light-on-dark text), while the icon, grid, and compact views use the shared list gradient
- **File-type icons** — every file resolves through the system MIME icon theme with a generic MIME-family fallback, so documents, images, audio, video, archives, scripts, and launchers each get an appropriate icon. Home and the XDG folders use special themed icons (`folder-music`, `folder-pictures`, etc.), `.desktop` files use their declared `Icon=` entry, image files render a scaled thumbnail, and video files render a frame extracted in the background by ffmpeg. Symlinks keep the provider's link badge
- **Natural filename sorting** — names sort case-insensitively with numeric runs compared by value, so `Track 2` precedes `Track 10` and `Album 9` precedes `Album 10`. The same ordering applies to files, Trash original paths, drive labels, and recursively queued music
- **Global filename search** — `Ctrl+Shift+F`, streamed results in a search dock
- **SQLite FTS5 search index** — automatic background build, trigram substring matching, status-bar health, and `View > Rebuild Search Index`
- **Async file operations** — copy, cut, paste, rename, new folder, trash, restore, permanent delete, empty Trash, and undo, all on a worker thread with progress and cancellation
- **Context menu file actions** — right-click any row for *Open*, *Open in Terminal*, *Cut*, *Copy*, *Paste*, *New Folder…*, *Properties*, *Move to Trash*, and *Delete Permanently*. In Trash, the same menu offers *Restore*, *Properties*, *Delete Permanently*, and *Empty Trash…*. Right-clicking an unselected row targets it first, right-clicking a selected row keeps a multi-selection, and right-clicking empty space clears the selection while leaving folder-wide actions available. *Properties* reports name, kind, size, location, modified time, and permissions, or the count and total size of a multi-selection
- **Drag and drop** — drag selected rows to move them, or hold Ctrl to copy. Drop onto a folder row or into a pane's empty space. Drags from other applications always copy, same-folder drops are no-ops, and collisions use the same `name (1).ext` naming as paste
- **Freedesktop.org Trash** — a dedicated **Trash** place browses `Trash/files`, shows each item's original location and deletion date, and supports **Restore**, **Delete Permanently**, and **Empty Trash**. Trash contents use `Path=`/`DeletionDate=` `.trashinfo` files, collision-safe storage names, and restore conflicts use `name (1).ext`; restoring is also available through undo for a just-trashed batch
- **Undo journal** — the last completed batch can be reversed with `Ctrl+Z`, including copies, moves, renames, new folders, and trashed items
- **Custom Places bookmarks** — right-click a folder and choose *Add to Places* to pin it to the sidebar; right-click a user-added entry and choose *Remove from Places* to unbookmark it. Bookmarks persist in `$XDG_CONFIG_HOME/ligma/places` (or `~/.config/ligma/places`). Right-click the built-in **Trash** entry for *Empty Trash…*, or right-click **Music** for *Play All Music*, which recursively queues audio files from that folder
- **Embedded terminal** — `F12` toggles a terminal panel docked on the right; the first open starts the user's shell in the active folder, and the session survives hiding and reopening. Opening and closing the panel, and the music player, slide in from their dock edges; closing with the dock's title-bar button animates the same way
- **Smooth scrolling** — wheel events animate the Places, Drives, file views, search results, and player playlist instead of jumping by whole rows. Scroll sensitivity is adjustable from 50% to 250% under **Settings > Views**
- **Run executables** — activating an executable file asks for confirmation, then launches it detached with its folder as the working directory
- **Administrator mode** — **File > Enter Administrator Mode** (`Ctrl+.`) authenticates through **pkexec** and enables root-backed browsing and file operations in the current window. The polkit agent supplies the password dialog; Ligma never reads or stores it. A headless helper handles root-only directory listings plus delete, rename, create-folder, copy, and move operations over a private Unix socket, while the UI stays unprivileged. Administrator mode is shown by a badge and an **Administrator — Ligma** title; there is no second window. Moving files to Trash is unavailable while it is active, so deletion is permanent and undo is disabled. Toggle `Ctrl+.` again to leave administrator mode
- **Preview panel** — the whole sidebar area below Places and Drives is a persistent preview panel. It shows a scaled image, an ffmpeg video frame, or a file summary, and hovering a video plays a short muted snippet
- **Built-in music player** — GStreamer-powered playback with prev/play-pause/next/stop, repeat (off/all/one), shuffle, seek, volume, optional EQ/ReplayGain, and a playlist. A direct-ALSA/bit-perfect output mode is available for exclusive playback. Natural completion keeps the queue and advances to the next track; the context menu adds **Play** and **Add to Playlist**
- **MPRIS / playerctl** — exposes `org.mpris.MediaPlayer2.ligma` with root and Player interfaces, so desktop media keys, `playerctl`, panels, and other MPRIS clients can read metadata, seek, set volume, change loop/shuffle, and control playback
- **Discord Rich Presence** — shows the current song and artist in Discord through its local IPC socket, optionally enriched with canonical MusicBrainz title/artist/album data
- **Blue-and-purple floppy icon** — a custom scalable app icon, installed as `org.ligma.FileManager` in the hicolor theme and embedded in the binary for the window icon

Search falls back to a cancellable breadth-first filename scan while the index is building, when no index exists, or when the active folder is outside the indexed root.

Not implemented yet: metadata, remote locations, archives, and extensions. See the roadmap in the spec.

## Preview panel

The panel occupies all of the sidebar space below Places and Drives and stays visible with an idle placeholder when nothing is selected. It updates from the selection model, not the current index, so Shift+arrow extensions and model resets resolve correctly.

- Selecting one image shows a scaled preview via `QImageReader`; the full image is never allocated at its original size.
- Selecting one video extracts a frame with an asynchronous `ffmpeg -ss 1 -frames:v 1` job into a temporary PNG. Videos shorter than the one-second seek are retried from frame 0.
- Hovering a video row plays a muted, looping snippet in the panel through Qt Multimedia. Moving away restores the selected item's preview, and the snippet stops after the configured interval.
- Folders, multi-selections, and empty selections show the idle placeholder; other single files show their name and size. The panel stays visible throughout.
- Video files also use an extracted frame as their icon in Icons and Grid views. Extraction runs one job at a time in the background, with a bounded queue, so large clip folders keep scrolling smoothly.
- MIME classification uses fast extension checks for common image/video files and falls back to a shared `QMimeDatabase` for unusual types.

## Settings

Open Settings with `Ctrl+,` or **Edit > Preferences…**. The window uses the same accent gradients, rounded cards, and compact spacing as the rest of Ligma. Changes apply immediately; there is no Apply button, and **Reset All** restores the built-in defaults.

**Administrator mode** uses a headless root helper rather than elevating the UI process. Authentication is handled by pkexec/polkit; Ligma never reads or stores a password. The helper listens on a private, user-owned Unix socket (mode 0600) and accepts connections only from the Ligma process that started it; it also exits if that process disappears. The window itself never runs as root. While the mode is active, Ligma shows an **Administrator** badge and routes delete/rename/new-folder/copy/move through the helper, one operation at a time, with results and errors in the status bar. Moving files to Trash is deliberately unavailable so administrator deletion is explicit and permanent, and undo is disabled. New folders and files created through the helper are owned by root, as are files moved from root-only locations; adjust ownership afterwards if the normal user needs them. Toggle `Ctrl+.` again to stop the helper and return to normal user access. Previews and opening files still use the unprivileged process, so content that the user cannot read—such as a file inside `/root`—is browsable and manageable but has no preview and may not open in a desktop application; use a root-owned application for that content.

**Scroll sensitivity** is a 50–250% slider under **Views > View**. It scales wheel and touchpad distance for every smooth-scrolling surface and applies immediately; 100% is the tuned default.

**Background opacity** is a 20–100% slider under **Appearance > Window**. It tints the file manager's large surfaces — the sidebar, file views, menu/status bars, and pane background — while labels, icons, input fields, tabs, and the preview content stay opaque. At 100% the window is fully opaque and keeps the normal palette look; below 100% Ligma uses the compositor's window translucency and reveals the desktop behind the tint, so a compositing desktop is required. The slider updates the window live.

Settings are stored in `$XDG_CONFIG_HOME/ligma/settings.toml` (or `~/.config/ligma/settings.toml`) and survive restarts. The open tabs are saved in `$XDG_CONFIG_HOME/ligma/session` when **Restore tabs from last window** is enabled; absolute folder tabs are restored and the previous active tab is selected. When the option is off, the session file is removed.

The theme choice remains in `$XDG_CONFIG_HOME/ligma/appearance`, since it is also reachable from **View > Appearance** and from Matugen/qt6ct.

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
- The **Output** button switches between the default PipeWire sink and a direct ALSA device at runtime. Enter `hw:X,Y` for exclusive/bit-perfect output, or leave it empty for PipeWire.
- Activating another audio file appends it to the playlist (or reuses its existing entry) and starts it. **Add to Playlist** appends every selected audio file without interrupting the current track.
- **Play** in the context menu replaces the queue with the selected audio files and starts the first one. Recursively queued music is sorted naturally, so numbered tracks play in numeric order. The playlist widget also accepts clicks to jump to a track.
- Files are classified with `QMimeDatabase`, so content-detected audio formats work even when their extension is unusual.
- The player exposes MPRIS 2 on the session bus. Metadata includes a stable per-track object path, title, artist, album, and length; `Position` and `Seeked` are reported in microseconds. The **Raise** method shows Ligma and opens the player dock, and **Quit** exits cleanly.
- Closing the dock keeps the playlist and playback alive; reopening it shows the same state.
- Playback uses GStreamer (`src/ui/music_engine.cpp`) rather than QtMultimedia. The default output is PipeWire, so it cooperates with the desktop mixer.
- If no working audio backend is available, the player surfaces the decoder error in the now-playing label instead of crashing.

### Audio quality and bit-perfect output

The default PipeWire path is mixed and may resample to the graph's sample rate. For direct, exclusive playback set:

```bash
LIGMA_AUDIO_MODE=alsa LIGMA_ALSA_DEVICE=hw:0,0 ./zig-out/bin/ligma
```

- `LIGMA_AUDIO_MODE=alsa` selects a direct ALSA sink and clears software volume/DSP.
- `LIGMA_ALSA_DEVICE` must be a hardware device (`hw:X,Y`), not `default`, if you want to bypass PipeWire. Find devices with `aplay -L` and `cat /proc/asound/cards`.
- In this mode the in-app volume slider is disabled; use the hardware mixer. Notifications and other applications cannot play through the same device.
- EQ and ReplayGain are disabled in bit-perfect mode.

Optional DSP for normal output:

```bash
LIGMA_AUDIO_EQ=bass ./zig-out/bin/ligma       # bass, vocal, or rock preset
LIGMA_AUDIO_REPLAYGAIN=1 ./zig-out/bin/ligma  # use ReplayGain tags
```

### Queue behavior

- With repeat **off**, a track that reaches its natural end stays in the queue and the next track starts. When the last track ends, playback stops and the queue remains; **Play** starts again from the first track.
- **Repeat all** and **Repeat one** keep every queue entry. Repeat all advances/wraps, while repeat one replays the same row.
- **Shuffle** changes which row is chosen next. With repeat all it keeps picking random tracks; with repeat off it keeps picking a random other track, so previously played tracks can repeat.
- Manual **Next** and **Previous** never remove queue entries. **Stop** also leaves the queue intact.

### MPRIS and playerctl

Ligma registers `org.mpris.MediaPlayer2.ligma` on the session bus at startup. MPRIS clients can use the standard root object (`Raise`, `Quit`, `Identity`, `CanRaise`, `DesktopEntry`) and Player interface (`Play`, `Pause`, `PlayPause`, `Stop`, `Next`, `Previous`, `Seek`, `SetPosition`, `PlaybackStatus`, `Metadata`, `Position`, `Volume`, `LoopStatus`, `Shuffle`, and `Seeked`).

```bash
playerctl -p ligma status
playerctl -p ligma metadata
playerctl -p ligma play-pause
playerctl -p ligma next
playerctl -p ligma position 42.5
playerctl -p ligma volume 0.6
```

`OpenUri` is intentionally rejected: playback is local-file only, so a remote client cannot ask Ligma to fetch an arbitrary URI. The service is best-effort and silently disabled when no session bus is available (for example, in a bare TTY).

### Discord Rich Presence

While a track is playing, Ligma publishes the song title and artist/album to a running Discord client through the local `discord-ipc-*` socket. It uses the registered Ligma Discord application ID and needs no bot token, OAuth login, or outbound network request.

- The activity shows the tagged title, artist, and album when available. Missing tags fall back to the filename; an unknown artist is omitted from the displayed details.
- Discord's `status_display_type` is set to **Details**, so the compact member-list line shows **Song — Artist** instead of only the application name. The profile card also shows the album when tagged.
- MusicBrainz enrichment is **enabled by default**. Ligma queries the public MusicBrainz recording API for a canonical title/artist and release data, then updates the presence. Requests are rate-limited to one per 1.1 seconds and only run when a track has title and artist tags. Set `LIGMA_MUSICBRAINZ=0` to disable them; Discord IPC itself never leaves the machine, but MusicBrainz enrichment does make HTTPS requests.
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
- The index has no incremental watcher yet; rebuild after large filesystem changes.

The schema uses SQLite FTS5 external-content tables (`files`, `files_fts`, and a trigram table) in WAL mode. Queries of three or more characters use the trigram index; shorter queries use an escaped `LIKE` scan.

## File operations

- Copy, cut, paste, rename, new folder, move to trash, restore, permanent delete, and empty Trash run on a background worker thread. The UI stays responsive and shows progress in the status bar.
- `Escape` cancels the running operation. Partial output from the current item is removed; items that already finished remain and are still undoable.
- Copy and move never overwrite an existing name. Collisions become `name (1).ext`, `name (2).ext`, and so on.
- Moves use `rename(2)` when possible and fall back to copy-plus-delete across devices.
- Trash uses `$XDG_DATA_HOME/Trash`, falling back to `~/.local/share/Trash`, and writes freedesktop.org `.trashinfo` metadata. `Ctrl+Z` restores a just-trashed item and removes its metadata.
- The **Trash** place lists items from `Trash/files` with their original location and deletion date. Double-click or press Enter to restore the selection; right-click for *Restore*, *Delete Permanently*, or *Empty Trash…*. Restore recreates the original path, uses `name (1).ext` when something already exists there, and fails without deleting the item when the original parent folder is gone.
- *Delete Permanently* and *Empty Trash…* remove both the stored item and its `.trashinfo` metadata, and both require confirmation. These actions are not undoable.
- Undo covers the most recent completed batch. The journal is in memory, is not persisted across restarts, and undo jobs cannot themselves be undone.
- Only one file operation runs at a time. Starting another while one is active is rejected with a status message.

## Automatic refresh and drives

- `QFileSystemWatcher` watches every open pane's current folder plus `Trash/files` and `Trash/info`. Events are coalesced for 180 ms, then the relevant snapshots reload.
- Creates, deletes, renames, moves between folders, and Trash changes update counts and rows without a manual reload. Selected paths and the scroll position are captured before the snapshot reset and restored afterward when they still exist.
- Directory watches report directory-entry changes. An in-place save that only changes an existing file's contents may still need `F5`.
- Mounted volumes are refreshed every 2 seconds with `QStorageInfo`. The **Drives** list excludes pseudo-filesystems and snap loop devices, sorts by label, and shows a free-space label plus a used-capacity progress bar for each mounted volume. Read-only media is labelled **read-only** instead of showing a misleading zero free space.
- Unmounted USB and removable partitions are discovered with `lsblk` and shown as **not mounted**. Clicking one runs `udisksctl mount -b <device>`, then opens the resulting mount point. The context menu also offers **Mount**.
- Right-click a mounted drive and choose **Unmount**. Ligma tries `udisksctl unmount` first so user-mounted media can unmount without a password, then falls back to `pkexec umount` for authorization. Failures such as a busy device are reported without removing the drive from the list.
- The Places and Drives lists collapse to their content height. When they exceed a fraction of the window height they get scrollbars, leaving the remaining sidebar space outside the boxes.

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
- Zig **0.17.0+** (the build script downloads an official compiler into `.tools/` when needed)
- Qt **6.8+** development files (tested with 6.12.0; QtWidgets, QtNetwork, QtDBus, QtMultimedia, and QtMultimediaWidgets)
- GStreamer **1.x** development files and the base/good/bad/ugly plugin sets, plus a PipeWire or ALSA sink
- **ffmpeg** for video thumbnails and the static video preview frame
- QTermWidget **2.x** for Qt 6 development files (`qtermwidget6.pc`; Arch: `qtermwidget`; Debian: `libqtermwidget-dev`; newer Ubuntu: `libqtermwidget6-2-dev`)
- SQLite 3 development files with FTS5 and the trigram tokenizer (tested with 3.54.1)
- `util-linux` (`lsblk`, `umount`) and **UDisks2** (`udisksctl`) for USB/removable-drive detection and mounting
- A C/C++ toolchain (`g++`) and `pkg-config`
- Optional: `playerctl` (or another MPRIS client) to verify the media interface

On Debian/Ubuntu-style systems:

```bash
sudo apt install build-essential pkg-config qt6-base-dev qt6-multimedia-dev \
  libsqlite3-dev libutf8proc-dev libqtermwidget-dev ffmpeg \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  gstreamer1.0-pipewire gstreamer1.0-alsa udisks2 util-linux
# Debian names the Qt 6 widget development package libqtermwidget-dev.
# Newer Ubuntu releases use libqtermwidget6-2-dev instead.
# libutf8proc-dev is required by qtermwidget6.pc but is not pulled in by
# Debian's libqtermwidget-dev package.
```

On Arch Linux:

```bash
sudo pacman -S qt6-base qt6-multimedia sqlite qtermwidget utf8proc ffmpeg \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad \
  gst-plugins-ugly gst-plugin-pipewire udisks2 util-linux
```

The build fetches the pinned `libqt6zig` dependency automatically. The first build compiles only the Qt wrappers the app uses, so it is much faster than building the entire binding repository.

### Commands

The repository includes a build script that checks and installs the required
development packages, builds a ReleaseSafe binary, and stages the desktop
entry and icons:

```bash
./build.sh              # install packages, build, then install Ligma
./build.sh --test       # build, run tests, then install
./build.sh --no-install # build/test without installing system-wide
./build.sh --run        # build, install, and launch
./build.sh --help       # all options
```

On the first run, `./build.sh` checks for the required development packages
and automatically starts the installer when something is missing. It detects
`pacman`, `apt`, or `dnf`, shows the package list, and asks before changing the
system. It installs the Qt 6, GStreamer, QTermWidget, SQLite, C/C++, and
pkg-config development packages.

If Zig 0.17.0 or newer is not available, the script downloads the official
Zig 0.17.0 compiler from <https://ziglang.org>, verifies its SHA-256 checksum,
and extracts it into the ignored `.tools/` directory. No compiler binary is
committed to the repository. `--install-deps` remains available to force the
package installer.

After a successful build, the binary and desktop assets are installed
automatically. The script uses `pkexec` for a polkit prompt when it needs
root; if `pkexec` is unavailable or its prompt is cancelled, it falls back to
`sudo`. Use `--no-install` when you only want a local build.

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
`./build.sh` installs them automatically. To install a previously built tree
manually:

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
| `Ctrl+,` | Open Settings |
| `Ctrl+.` | Enter or leave administrator mode |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` / `Ctrl+4` | Details / Icons / Compact / Grid view |
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
| `Delete` | Move to Trash (disabled while browsing Trash) |
| `Shift+Delete` | Delete permanently, including from Trash |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | Copy / cut / paste |
| `Ctrl+Z` | Undo last completed file operation |
| `Escape` | Cancel the running file operation |
| `Ctrl+Q` | Quit |

In Trash, **Enter** or double-click restores the selected items; **Shift+Delete** deletes them permanently.

## Project layout

```
build.sh               dependency check, build, test, and install helper
build.zig              Zig build definition and the Qt wrapper link list
build.zig.zon          pinned libqt6zig dependency and package metadata
src/main.zig           Qt entrypoint
src/app.zig            window, tabs, panes, navigation, search and file-operation UI
src/ui/local_model.zig  async flat directory model with filter and sort
src/ui/mounts.zig       QStorageInfo/lsblk drive discovery and mount metadata
src/ui/qt_bridge.cpp    QVariant-from-QIcon bridge for view decorations
src/ui/terminal.zig     Zig wrapper for the embedded terminal panel
src/ui/terminal_widget.cpp  QTermWidget C ABI shim (compiled with g++)
src/ui/player.zig       music player UI, playlist, repeat/shuffle, Discord
src/ui/music_engine.cpp GStreamer C ABI engine (Output/DSP/ALSA)
src/ui/music_engine.zig Zig bridge for the GStreamer engine
src/core/musicbrainz.zig optional MusicBrainz metadata enrichment
assets/                 .desktop entry and hicolor icon set
src/core/file_ops.zig  async copy/move/trash/restore/purge/delete/rename/mkdir/undo engine
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

1. Add per-mount `.Trash-$uid` support and per-folder view state.
2. Add incremental search indexing with inotify and a query language.
3. Then move to metadata, previews, remote locations, and extensions.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
