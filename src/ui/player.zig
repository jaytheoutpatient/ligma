//! Built-in music player.
//!
//! A bottom dock that plays local audio files through QtMultimedia. The
//! playlist is in memory and belongs to this panel: activating an audio file
//! appends it (unless it is already present) and starts playback, while the
//! context-menu action adds files without interrupting the current track.
//!
//! QtMultimedia is a separate Qt module; on Linux it is a regular shared
//! library and the FFmpeg backend package provides the codecs. Files are
//! classified with `QMimeDatabase`, so any format the desktop recognizes as
//! `audio/*` is routed here instead of the desktop opener.

const std = @import("std");
const qt6 = @import("libqt6zig");

const discord = @import("../core/discord.zig");

const QAudioOutput = qt6.QAudioOutput;
const QHBoxLayout = qt6.QHBoxLayout;
const QLabel = qt6.QLabel;
const QListWidget = qt6.QListWidget;
const QMediaMetaData = qt6.QMediaMetaData;
const QMediaPlayer = qt6.QMediaPlayer;
const QMimeDatabase = qt6.QMimeDatabase;
const QPushButton = qt6.QPushButton;
const QSlider = qt6.QSlider;
const QUrl = qt6.QUrl;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qnamespace_enums = qt6.qnamespace_enums;
const qmediaplayer_enums = qt6.qmediaplayer_enums;
const qmediametadata_enums = qt6.qmediametadata_enums;

const RepeatMode = enum { off, all, one };

const toggle_style = "QPushButton:checked { background-color: rgba(59, 130, 246, 0.25); border-radius: 4px; }";

/// True when the desktop's MIME database classifies `path` as audio.
pub fn isAudioFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const db = QMimeDatabase.new();
    defer db.delete();
    const mime = db.mimeTypeForFile(path);
    defer mime.delete();
    const name = mime.name(allocator);
    defer allocator.free(name);
    return std.mem.startsWith(u8, name, "audio/");
}

/// The single live panel. Qt callbacks are plain C functions without user
/// data, so they reach the panel through this pointer.
var active: ?*PlayerPanel = null;

pub const PlayerPanel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    container: QWidget = undefined,
    media: QMediaPlayer = undefined,
    audio: QAudioOutput = undefined,

    title_label: QLabel = undefined,
    time_label: QLabel = undefined,
    seek_slider: QSlider = undefined,
    volume_slider: QSlider = undefined,
    playlist_widget: QListWidget = undefined,
    play_button: QPushButton = undefined,
    repeat_button: QPushButton = undefined,
    shuffle_button: QPushButton = undefined,

    /// Owned absolute paths, parallel to the list-widget rows.
    playlist: std.ArrayList([]u8) = .empty,
    /// Index into `playlist` of the loaded track.
    current: ?usize = null,
    /// Set while rows are changed programmatically so the row-changed
    /// callback does not mistake it for a click.
    playlist_updating: bool = false,

    repeat_mode: RepeatMode = .off,
    shuffle: bool = false,
    rng: std.Random.DefaultPrng = undefined,
    metadata_ready: bool = false,
    track_loaded: bool = false,
    duration_ready: bool = false,
    transport_active: bool = false,
    playback_intent_playing: bool = false,
    discord: ?*discord.DiscordRpc = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*PlayerPanel {
        const self = try gpa.create(PlayerPanel);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io };
        const seed: u64 = @bitCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
        self.rng = std.Random.DefaultPrng.init(seed);

        self.container = QWidget.new2();
        self.title_label = QLabel.new3("No track loaded");
        self.time_label = QLabel.new3("0:00 / 0:00");
        self.time_label.setMinimumWidth(118);
        self.time_label.setAlignment(qnamespace_enums.AlignmentFlag.AlignRight |
            qnamespace_enums.AlignmentFlag.AlignVCenter);

        self.seek_slider = QSlider.new3(qnamespace_enums.Orientation.Horizontal);
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);

        self.playlist_widget = QListWidget.new(self.container);
        self.playlist_widget.setAlternatingRowColors(true);
        self.playlist_widget.setUniformItemSizes(true);
        self.playlist_widget.setMinimumHeight(96);
        self.playlist_widget.setFixedHeight(120);

        const previous_button = QPushButton.new3("⏮");
        self.play_button = QPushButton.new3("▶");
        const next_button = QPushButton.new3("⏭");
        const stop_button = QPushButton.new3("⏹");
        self.repeat_button = QPushButton.new3("Repeat");
        self.repeat_button.setCheckable(true);
        self.shuffle_button = QPushButton.new3("Shuffle");
        self.shuffle_button.setCheckable(true);
        self.configureControl(previous_button, "Previous track");
        self.configureControl(self.play_button, "Play or pause");
        self.configureControl(next_button, "Next track");
        self.configureControl(stop_button, "Stop");
        self.configureControl(self.repeat_button, "Repeat: off");
        self.configureControl(self.shuffle_button, "Shuffle: off");
        self.repeat_button.setStyleSheet(toggle_style);
        self.shuffle_button.setStyleSheet(toggle_style);
        self.repeat_button.setFixedWidth(72);
        self.shuffle_button.setFixedWidth(64);

        const controls = QHBoxLayout.new2();
        controls.setSpacing(4);
        controls.addWidget(previous_button);
        controls.addWidget(self.play_button);
        controls.addWidget(next_button);
        controls.addWidget(stop_button);
        controls.addWidget(self.repeat_button);
        controls.addWidget(self.shuffle_button);
        controls.addWidget(self.seek_slider);
        controls.addWidget(self.time_label);
        controls.setStretch(6, 1);

        self.volume_slider = QSlider.new3(qnamespace_enums.Orientation.Horizontal);
        self.volume_slider.setRange(0, 100);
        self.volume_slider.setValue(70);
        self.volume_slider.setFixedWidth(120);
        const volume_label = QLabel.new3("Volume");
        const volume_row = QHBoxLayout.new2();
        volume_row.setSpacing(6);
        volume_row.addWidget(volume_label);
        volume_row.addWidget(self.volume_slider);
        volume_row.addStretch();

        const layout = QVBoxLayout.new(self.container);
        layout.setContentsMargins(10, 6, 10, 6);
        layout.setSpacing(4);
        layout.addWidget(self.title_label);
        layout.addLayout(controls);
        layout.addLayout(volume_row);
        layout.addWidget(self.playlist_widget);

        self.audio = QAudioOutput.new();
        self.audio.setVolume(0.7);
        self.media = QMediaPlayer.new2(self.container);
        self.media.setAudioOutput(self.audio);

        self.media.onPlaybackStateChanged(onPlaybackStateChanged);
        self.media.onMediaStatusChanged(onMediaStatusChanged);
        self.media.onPositionChanged(onPositionChanged);
        self.media.onDurationChanged(onDurationChanged);
        self.media.onMetaDataChanged(onMetaDataChanged);
        self.media.onErrorOccurred(onErrorOccurred);

        self.seek_slider.onSliderMoved(onSeekMoved);
        self.seek_slider.onSliderReleased(onSeekReleased);
        self.volume_slider.onValueChanged(onVolumeChanged);
        self.playlist_widget.onCurrentRowChanged(onPlaylistRowChanged);
        self.play_button.onClicked(onPlayPauseClicked);
        previous_button.onClicked(onPreviousClicked);
        next_button.onClicked(onNextClicked);
        stop_button.onClicked(onStopClicked);
        self.repeat_button.onClicked(onRepeatClicked);
        self.shuffle_button.onClicked(onShuffleClicked);

        self.discord = discord.DiscordRpc.create(gpa, io, self.container) catch null;
        self.refreshRepeatButton();
        self.refreshShuffleButton();

        active = self;
        return self;
    }

    fn configureControl(self: *PlayerPanel, button: QPushButton, tooltip: []const u8) void {
        _ = self;
        button.setFixedWidth(36);
        button.setFlat(true);
        button.setToolTip(tooltip);
    }

    /// Append `path` if needed and start it.
    pub fn playPath(self: *PlayerPanel, path: []const u8) void {
        const index = self.ensurePath(path) orelse return;
        self.playIndex(index);
    }

    /// Replace the queue with `paths` and start the first track.
    pub fn playAll(self: *PlayerPanel, paths: []const []const u8) void {
        if (paths.len == 0) return;
        self.clearPlaylist();
        for (paths) |path| _ = self.ensurePath(path);
        if (self.playlist.items.len > 0) self.playIndex(0);
    }

    /// Append any tracks not already in the queue. Returns how many were new.
    pub fn addPaths(self: *PlayerPanel, paths: []const []const u8) usize {
        var added: usize = 0;
        for (paths) |path| {
            const before = self.playlist.items.len;
            _ = self.ensurePath(path);
            if (self.playlist.items.len > before) added += 1;
        }
        return added;
    }

    fn ensurePath(self: *PlayerPanel, path: []const u8) ?usize {
        if (self.indexOf(path)) |index| return index;

        const copy = self.gpa.dupe(u8, path) catch return null;
        self.playlist.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return null;
        };
        self.playlist_widget.addItem(std.fs.path.basename(copy));
        self.updateTitle();
        return self.playlist.items.len - 1;
    }

    fn indexOf(self: *PlayerPanel, path: []const u8) ?usize {
        return findPath(self.playlist.items, path);
    }

    fn currentName(self: *PlayerPanel) []const u8 {
        const index = self.current orelse return "track";
        if (index >= self.playlist.items.len) return "track";
        return std.fs.path.basename(self.playlist.items[index]);
    }

    fn playIndex(self: *PlayerPanel, row: usize) void {
        if (row >= self.playlist.items.len) return;

        self.current = row;
        self.playlist_updating = true;
        self.playlist_widget.setCurrentRow(@intCast(row));
        self.playlist_updating = false;

        self.metadata_ready = false;
        self.track_loaded = false;
        self.duration_ready = false;
        self.updateTitle();
        self.seek_slider.setEnabled(true);
        self.seek_slider.setValue(0);

        self.transport_active = true;
        self.playback_intent_playing = true;
        const url = QUrl.fromLocalFile(self.playlist.items[row]);
        defer url.delete();
        self.media.setSource(url);
        self.media.play();
    }

    fn playNext(self: *PlayerPanel) void {
        const current = self.current orelse {
            if (self.playlist.items.len > 0) self.playIndex(0);
            return;
        };

        if (self.shuffle and self.playlist.items.len > 1) {
            self.playIndex(self.randomOther(current));
            return;
        }
        if (current + 1 < self.playlist.items.len) {
            self.playIndex(current + 1);
            return;
        }
        if (self.repeat_mode == .all) {
            self.playIndex(0);
            return;
        }
        self.stop();
    }

    fn playPrevious(self: *PlayerPanel) void {
        const current = self.current orelse {
            if (self.playlist.items.len > 0) self.playIndex(0);
            return;
        };
        // Restart the current track unless it has just started.
        if (self.media.position() > 3000) {
            self.media.setPosition(0);
            return;
        }
        if (current > 0) {
            self.playIndex(current - 1);
            return;
        }
        if (self.repeat_mode == .all and self.playlist.items.len > 1) {
            self.playIndex(self.playlist.items.len - 1);
            return;
        }
        self.media.setPosition(0);
    }

    /// Called when the media backend reports EndOfMedia.
    fn finishTrack(self: *PlayerPanel) void {
        const finished = self.current orelse return;
        if (finished >= self.playlist.items.len) return;

        switch (self.repeat_mode) {
            .one => self.playIndex(finished),
            .all => {
                if (self.shuffle and self.playlist.items.len > 1) {
                    self.playIndex(self.randomOther(finished));
                } else if (finished + 1 < self.playlist.items.len) {
                    self.playIndex(finished + 1);
                } else {
                    self.playIndex(0);
                }
            },
            .off => {
                const had_next = finished + 1 < self.playlist.items.len;
                const shuffled = self.shuffle;
                self.removeTrack(finished);

                if (shuffled and self.playlist.items.len > 0) {
                    self.playIndex(self.randomAny());
                } else if (had_next and finished < self.playlist.items.len) {
                    self.playIndex(finished);
                } else {
                    self.finishQueue();
                }
            },
        }
    }

    fn removeTrack(self: *PlayerPanel, index: usize) void {
        if (index >= self.playlist.items.len) return;
        const path = self.playlist.orderedRemove(index);
        self.gpa.free(path);

        const item = self.playlist_widget.takeItem(@intCast(index));
        if (item.ptr != null) item.delete();

        if (self.current) |current| {
            if (current > index) {
                self.current = current - 1;
            } else if (current == index) {
                self.current = null;
            }
        }
    }

    fn finishQueue(self: *PlayerPanel) void {
        self.current = null;
        self.track_loaded = false;
        self.duration_ready = false;
        self.transport_active = false;
        self.playback_intent_playing = false;
        self.media.stop();
        self.seek_slider.setValue(0);
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);
        self.time_label.setText("0:00 / 0:00");
        self.updateTitle();
        if (self.discord) |client| client.clearActivity();
    }

    fn randomOther(self: *PlayerPanel, current: usize) usize {
        const length = self.playlist.items.len;
        if (length <= 1) return current;
        const candidate = self.rng.random().uintLessThan(usize, length - 1);
        return if (candidate >= current) candidate + 1 else candidate;
    }

    fn randomAny(self: *PlayerPanel) usize {
        return self.rng.random().uintLessThan(usize, self.playlist.items.len);
    }

    fn togglePlayPause(self: *PlayerPanel) void {
        if (self.playlist.items.len == 0) return;
        if (self.media.playbackState() == qmediaplayer_enums.PlaybackState.PlayingState) {
            self.playback_intent_playing = false;
            self.media.pause();
            self.publishPresence(false);
            return;
        }
        // Tracks added with "Add to Playlist" before anything has played have
        // no loaded source yet; start the first one instead of calling play()
        // with an empty media player.
        if (self.current == null) {
            self.playIndex(0);
            return;
        }
        self.transport_active = true;
        self.playback_intent_playing = true;
        self.media.play();
        self.publishPresence(true);
    }

    fn stop(self: *PlayerPanel) void {
        self.transport_active = false;
        self.playback_intent_playing = false;
        if (self.discord) |client| client.clearActivity();
        self.media.stop();
        self.seek_slider.setValue(0);
        self.time_label.setText("0:00 / 0:00");
    }

    fn cycleRepeat(self: *PlayerPanel) void {
        self.repeat_mode = switch (self.repeat_mode) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
        self.refreshRepeatButton();
    }

    fn refreshRepeatButton(self: *PlayerPanel) void {
        self.repeat_button.setChecked(self.repeat_mode != .off);
        self.repeat_button.setText(if (self.repeat_mode == .one) "Repeat 1" else "Repeat");
        self.repeat_button.setToolTip(switch (self.repeat_mode) {
            .off => "Repeat: off",
            .all => "Repeat: all",
            .one => "Repeat: one",
        });
    }

    fn toggleShuffle(self: *PlayerPanel) void {
        self.shuffle = !self.shuffle;
        self.refreshShuffleButton();
    }

    fn refreshShuffleButton(self: *PlayerPanel) void {
        self.shuffle_button.setChecked(self.shuffle);
        self.shuffle_button.setText("Shuffle");
        self.shuffle_button.setToolTip(if (self.shuffle) "Shuffle: on" else "Shuffle: off");
    }

    pub fn clearPlaylist(self: *PlayerPanel) void {
        if (self.discord) |client| client.clearActivity();
        self.transport_active = false;
        self.playback_intent_playing = false;
        self.media.stop();
        self.current = null;
        self.metadata_ready = false;
        self.track_loaded = false;
        self.duration_ready = false;
        self.playlist_widget.clear();
        for (self.playlist.items) |path| self.gpa.free(path);
        self.playlist.clearRetainingCapacity();
        self.title_label.setText("No track loaded");
        self.time_label.setText("0:00 / 0:00");
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);
    }

    fn updateTitle(self: *PlayerPanel) void {
        const index = self.current orelse {
            if (self.playlist.items.len == 0) {
                self.title_label.setText("No track loaded");
            } else {
                var queue_buffer: [96]u8 = undefined;
                const queue = std.fmt.bufPrint(
                    &queue_buffer,
                    "{d} track{s} in playlist",
                    .{ self.playlist.items.len, if (self.playlist.items.len == 1) "" else "s" },
                ) catch "Playlist";
                self.title_label.setText(queue);
            }
            return;
        };
        if (index >= self.playlist.items.len) return;

        var buffer: [1024]u8 = undefined;
        const name = std.fs.path.basename(self.playlist.items[index]);
        const text = std.fmt.bufPrint(
            &buffer,
            "{s} — track {d}/{d}",
            .{ name, index + 1, self.playlist.items.len },
        ) catch name;
        self.title_label.setText(text);
    }

    fn updateTime(self: *PlayerPanel) void {
        var position_buffer: [32]u8 = undefined;
        var duration_buffer: [32]u8 = undefined;
        var buffer: [96]u8 = undefined;
        const position = formatTime(&position_buffer, self.media.position());
        const duration = formatTime(&duration_buffer, self.media.duration());
        const text = std.fmt.bufPrint(&buffer, "{s} / {s}", .{ position, duration }) catch "0:00 / 0:00";
        self.time_label.setText(text);
    }

    fn refreshPlayButton(self: *PlayerPanel) void {
        const playing = self.media.playbackState() ==
            qmediaplayer_enums.PlaybackState.PlayingState;
        self.play_button.setText(if (playing) "⏸" else "▶");
    }

    /// Publish title/artist (and progress while playing) to Discord. Audio
    /// metadata can arrive after playback starts, so callers pass through
    /// again from `metaDataChanged` and media-status callbacks.
    fn publishPresence(self: *PlayerPanel, playing: bool) void {
        const client = self.discord orelse return;
        const index = self.current orelse {
            client.clearActivity();
            return;
        };
        if (index >= self.playlist.items.len or !self.track_loaded) return;
        if (!self.transport_active) return;

        var title_meta: ?[]const u8 = null;
        var contributing: ?[]const u8 = null;
        var album_artist: ?[]const u8 = null;
        var author: ?[]const u8 = null;
        var album: ?[]const u8 = null;
        var details_owned: ?[]const u8 = null;
        defer {
            if (title_meta) |value| self.gpa.free(value);
            if (contributing) |value| self.gpa.free(value);
            if (album_artist) |value| self.gpa.free(value);
            if (author) |value| self.gpa.free(value);
            if (album) |value| self.gpa.free(value);
            if (details_owned) |value| self.gpa.free(value);
        }

        var title: []const u8 = std.fs.path.basename(self.playlist.items[index]);
        var artist: []const u8 = "Unknown artist";
        var album_name: []const u8 = "";

        if (self.metadata_ready) {
            const metadata = self.media.metaData();
            defer metadata.delete();

            title_meta = metadata.stringValue(self.gpa, qmediametadata_enums.Key.Title);
            if (nonEmpty(title_meta.?)) |value| title = value;

            contributing = metadata.stringValue(self.gpa, qmediametadata_enums.Key.ContributingArtist);
            album_artist = metadata.stringValue(self.gpa, qmediametadata_enums.Key.AlbumArtist);
            author = metadata.stringValue(self.gpa, qmediametadata_enums.Key.Author);
            album = metadata.stringValue(self.gpa, qmediametadata_enums.Key.AlbumTitle);

            if (nonEmpty(contributing.?)) |value| {
                artist = value;
            } else if (nonEmpty(album_artist.?)) |value| {
                artist = value;
            } else if (nonEmpty(author.?)) |value| {
                artist = value;
            }
            if (nonEmpty(album.?)) |value| album_name = value;
        }

        // The member-list line can show only one activity field. Put the song
        // and artist together in `details`, and ask Discord to display that
        // field rather than the application name.
        var details: []const u8 = title;
        if (!std.mem.eql(u8, artist, "Unknown artist")) {
            details_owned = std.fmt.allocPrint(self.gpa, "{s} — {s}", .{ title, artist }) catch null;
            if (details_owned) |value| details = value;
        }

        const state: []const u8 = album_name;
        const ready = self.track_loaded and self.duration_ready;
        const position = if (ready) self.media.position() else 0;
        const duration = if (ready) self.media.duration() else 0;
        client.setActivity(details, state, playing, position, duration);
    }

    /// Stop playback and release everything the panel owns. The widget tree
    /// itself is owned by the dock's window and is deleted with it.
    pub fn deinit(self: *PlayerPanel) void {
        if (active == self) active = null;
        if (self.discord) |client| {
            client.deinit();
            self.discord = null;
        }
        self.media.stop();
        self.media.delete();
        self.audio.delete();
        for (self.playlist.items) |path| self.gpa.free(path);
        self.playlist.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

fn nonEmpty(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn formatTime(buffer: []u8, milliseconds: i64) []const u8 {
    const ms = @max(milliseconds, 0);
    const total_seconds = @divTrunc(ms, 1000);
    const hours = @divTrunc(total_seconds, 3600);
    const minutes = @divTrunc(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);
    if (hours > 0) {
        return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "0:00";
    }
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ minutes, seconds }) catch "0:00";
}

// ---- Qt callbacks --------------------------------------------------------

fn onPlayPauseClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.togglePlayPause();
}

fn onPreviousClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.playPrevious();
}

fn onNextClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.playNext();
}

fn onStopClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.stop();
}

fn onSeekMoved(_: QSlider, value: i32) callconv(.c) void {
    if (active) |panel| panel.media.setPosition(value);
}

fn onSeekReleased(_: QSlider) callconv(.c) void {
    if (active) |panel| panel.publishPresence(panel.playback_intent_playing);
}

fn onRepeatClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.cycleRepeat();
}

fn onShuffleClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.toggleShuffle();
}

fn onVolumeChanged(_: QSlider, value: i32) callconv(.c) void {
    if (active) |panel| {
        const volume: f32 = @as(f32, @floatFromInt(value)) / 100.0;
        panel.audio.setVolume(volume);
    }
}

fn onPlaylistRowChanged(_: QListWidget, row: i32) callconv(.c) void {
    const panel = active orelse return;
    if (panel.playlist_updating or row < 0) return;
    panel.playIndex(@intCast(row));
}

fn onPlaybackStateChanged(_: QMediaPlayer, state: i32) callconv(.c) void {
    const panel = active orelse return;
    panel.refreshPlayButton();
    if (state == qmediaplayer_enums.PlaybackState.PlayingState) {
        panel.playback_intent_playing = true;
        panel.publishPresence(true);
    } else if (state == qmediaplayer_enums.PlaybackState.PausedState) {
        panel.playback_intent_playing = false;
        panel.publishPresence(false);
    }
}

fn onMediaStatusChanged(_: QMediaPlayer, status: i32) callconv(.c) void {
    const panel = active orelse return;
    if (status == qmediaplayer_enums.MediaStatus.EndOfMedia) {
        panel.finishTrack();
        return;
    }
    if (status == qmediaplayer_enums.MediaStatus.LoadedMedia or
        status == qmediaplayer_enums.MediaStatus.BufferedMedia)
    {
        panel.track_loaded = true;
        panel.metadata_ready = true;
        panel.publishPresence(panel.playback_intent_playing);
    }
}

fn onMetaDataChanged(_: QMediaPlayer) callconv(.c) void {
    const panel = active orelse return;
    if (!panel.track_loaded) return;
    panel.metadata_ready = true;
    panel.publishPresence(panel.playback_intent_playing);
}

fn onPositionChanged(_: QMediaPlayer, position: i64) callconv(.c) void {
    const panel = active orelse return;
    if (!panel.seek_slider.isSliderDown()) {
        const clamped: i32 = @intCast(@min(position, std.math.maxInt(i32)));
        panel.seek_slider.setValue(clamped);
    }
    panel.updateTime();
}

fn onDurationChanged(_: QMediaPlayer, duration: i64) callconv(.c) void {
    const panel = active orelse return;
    const clamped: i32 = @intCast(@min(duration, std.math.maxInt(i32)));
    panel.seek_slider.setRange(0, clamped);
    panel.duration_ready = true;
    panel.updateTime();
    if (panel.track_loaded) panel.publishPresence(panel.playback_intent_playing);
}

fn onErrorOccurred(_: QMediaPlayer, _: i32, description: [*:0]const u8) callconv(.c) void {
    const panel = active orelse return;
    var buffer: [768]u8 = undefined;
    const detail = std.mem.span(description);
    const text = std.fmt.bufPrint(
        &buffer,
        "Cannot play “{s}”: {s}",
        .{ panel.currentName(), detail },
    ) catch "Cannot play this file";
    panel.title_label.setText(text);
    panel.transport_active = false;
    panel.playback_intent_playing = false;
    panel.duration_ready = false;
    if (panel.discord) |client| client.clearActivity();
}

fn findPath(paths: []const []u8, path: []const u8) ?usize {
    for (paths, 0..) |existing, index| {
        if (std.mem.eql(u8, existing, path)) return index;
    }
    return null;
}

test "formatTime renders minutes and padded seconds" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0:00", formatTime(&buffer, 0));
    try std.testing.expectEqualStrings("0:07", formatTime(&buffer, 7000));
    try std.testing.expectEqualStrings("1:02", formatTime(&buffer, 62000));
    try std.testing.expectEqualStrings("0:00", formatTime(&buffer, -5));
    try std.testing.expectEqualStrings("1:01:01", formatTime(&buffer, 3_661_000));
}

test "findPath de-duplicates by full path" {
    const paths = [_][]u8{ @constCast("/tmp/one.ogg"), @constCast("/tmp/two.flac") };
    try std.testing.expectEqual(@as(?usize, 0), findPath(&paths, "/tmp/one.ogg"));
    try std.testing.expectEqual(@as(?usize, 1), findPath(&paths, "/tmp/two.flac"));
    try std.testing.expectEqual(@as(?usize, null), findPath(&paths, "/tmp/three.ogg"));
}
