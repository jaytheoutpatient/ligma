//! Built-in music player.
//!
//! Audio is decoded and rendered by GStreamer (`music_engine.cpp`), not
//! QtMultimedia. This gives the player a direct ALSA output mode, optional DSP
//! filters, and reliable tag events for Discord Rich Presence. The playlist,
//! repeat/shuffle policy, and Discord updates stay in this Zig module.
//!
//! Two output paths are available:
//! - The default PipeWire/GStreamer sink, which cooperates with the desktop.
//! - `LIGMA_AUDIO_MODE=alsa` plus `LIGMA_ALSA_DEVICE=hw:X,Y`, which uses a
//!   direct ALSA device, disables software volume, and bypasses DSP.

const std = @import("std");
const qt6 = @import("libqt6zig");

const discord = @import("../core/discord.zig");
const music_engine = @import("music_engine.zig");
const musicbrainz = @import("../core/musicbrainz.zig");
const theme = @import("theme.zig");

extern fn ligma_mpris_notify() void;
extern fn ligma_mpris_seeked() void;
extern fn ligma_player_control_icon(button: ?*anyopaque, kind: c_int, size_px: c_int) void;
extern fn ligma_smooth_scroll_attach(view: ?*anyopaque) void;

const QHBoxLayout = qt6.QHBoxLayout;
const QInputDialog = qt6.QInputDialog;
const QLabel = qt6.QLabel;
const QListWidget = qt6.QListWidget;
const QMimeDatabase = qt6.QMimeDatabase;
const QPushButton = qt6.QPushButton;
const QSlider = qt6.QSlider;
const QTimer = qt6.QTimer;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qlineedit_enums = qt6.qlineedit_enums;
const qnamespace_enums = qt6.qnamespace_enums;

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
    engine: ?music_engine.Engine = null,
    poll_timer: QTimer = undefined,

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
    tags: ?music_engine.Engine.Tags = null,
    tag_serial_seen: u32 = 0,
    track_loaded: bool = false,
    duration_ready: bool = false,
    transport_active: bool = false,
    playback_intent_playing: bool = false,
    output_device: ?[]u8 = null,
    discord: ?*discord.DiscordRpc = null,
    musicbrainz: ?*musicbrainz.MusicBrainz = null,
    mb_result: ?musicbrainz.Result = null,
    mb_serial: u64 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*PlayerPanel {
        const self = try gpa.create(PlayerPanel);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io };
        const seed: u64 = @bitCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
        self.rng = std.Random.DefaultPrng.init(seed);

        self.container = QWidget.new2();
        self.container.setObjectName("ligmaPlayerPanel");
        self.title_label = QLabel.new3("No track loaded");
        self.time_label = QLabel.new3("0:00 / 0:00");
        self.time_label.setMinimumWidth(118);
        self.time_label.setAlignment(qnamespace_enums.AlignmentFlag.AlignRight |
            qnamespace_enums.AlignmentFlag.AlignVCenter);

        self.seek_slider = QSlider.new3(qnamespace_enums.Orientation.Horizontal);
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);

        self.playlist_widget = QListWidget.new(self.container);
        self.playlist_widget.setAlternatingRowColors(false);
        self.playlist_widget.setUniformItemSizes(true);
        self.playlist_widget.setMinimumHeight(96);
        self.playlist_widget.setFixedHeight(120);
        ligma_smooth_scroll_attach(self.playlist_widget.ptr);

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
        const output_button = QPushButton.new3("Output");
        output_button.setFlat(true);
        output_button.setFixedWidth(64);
        output_button.setToolTip("Choose PipeWire or a direct ALSA device");
        output_button.onClicked(onOutputClicked);
        volume_row.addWidget(output_button);
        volume_row.addStretch();

        const layout = QVBoxLayout.new(self.container);
        layout.setContentsMargins(10, 6, 10, 6);
        layout.setSpacing(4);
        layout.addWidget(self.title_label);
        layout.addLayout(controls);
        layout.addLayout(volume_row);
        layout.addWidget(self.playlist_widget);

        // The environment selects the initial output/DSP setup. The Output
        // button can switch between PipeWire and direct ALSA at runtime.
        const output_mode = audioOutputMode();
        const alsa_device = if (std.c.getenv("LIGMA_ALSA_DEVICE")) |raw|
            std.mem.span(raw)
        else
            "default";
        const eq_preset = eqPresetGains();
        const replaygain = envFlag("LIGMA_AUDIO_REPLAYGAIN");
        self.engine = music_engine.Engine.create(
            output_mode,
            alsa_device,
            eq_preset != null,
            replaygain,
        );
        if (output_mode == .alsa) {
            self.output_device = gpa.dupe(u8, alsa_device) catch null;
        }
        if (self.engine) |engine| {
            if (eq_preset) |gains| _ = engine.setEq(true, gains[0..]);
            if (replaygain) _ = engine.setReplayGain(true);
            if (engine.isBitPerfect()) {
                self.volume_slider.setValue(100);
                self.volume_slider.setEnabled(false);
                self.volume_slider.setToolTip("Bit-perfect output: use the hardware volume control");
                self.title_label.setToolTip("Direct ALSA output; software volume and DSP are disabled");
            } else {
                engine.setVolume(0.7);
            }
        } else {
            self.title_label.setText("Audio engine unavailable");
            std.debug.print("player: could not create the GStreamer engine\n", .{});
        }

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

        self.poll_timer = QTimer.new2(self.container);
        self.poll_timer.setInterval(100);
        self.poll_timer.onTimeout(onPollTimer);
        self.poll_timer.start(100);

        self.applyThemeStyle();
        self.discord = discord.DiscordRpc.create(gpa, io, self.container) catch null;
        self.musicbrainz = musicbrainz.MusicBrainz.create(
            gpa,
            io,
            self.container,
            onMusicBrainzResult,
        ) catch null;
        self.refreshRepeatButton();
        self.refreshShuffleButton();

        active = self;
        return self;
    }

    pub fn applyThemeStyle(self: *PlayerPanel) void {
        var buffer: [4096]u8 = undefined;
        self.playlist_widget.setStyleSheet(theme.listStyle(&buffer));
    }

    pub fn mprisPlay(self: *PlayerPanel) void {
        if (self.playlist.items.len == 0) return;
        if (self.current == null) {
            self.playIndex(0);
            return;
        }
        const engine = self.engine orelse return;
        self.transport_active = true;
        self.playback_intent_playing = true;
        engine.play();
        self.refreshPlayButton();
        self.publishPresence(true);
        self.notifyMpris();
    }

    pub fn mprisPause(self: *PlayerPanel) void {
        const engine = self.engine orelse return;
        if (engine.state() != .playing) return;
        self.playback_intent_playing = false;
        engine.pause();
        self.refreshPlayButton();
        self.publishPresence(false);
        self.notifyMpris();
    }

    pub fn mprisPlayPause(self: *PlayerPanel) void {
        self.togglePlayPause();
    }

    pub fn mprisStop(self: *PlayerPanel) void {
        self.stop();
    }

    pub fn mprisNext(self: *PlayerPanel) void {
        self.playNext();
    }

    pub fn mprisPrevious(self: *PlayerPanel) void {
        self.playPrevious();
    }

    pub fn mprisSeekRelative(self: *PlayerPanel, microseconds: i64) void {
        const engine = self.engine orelse return;
        const delta_ms = @divTrunc(microseconds, 1000);
        var target: i64 = engine.position() + delta_ms;
        const duration = engine.duration();
        if (target < 0) target = 0;
        if (duration > 0 and target > duration) target = duration;
        engine.setPosition(target);
        self.seek_slider.setValue(@intCast(@max(target, 0)));
        self.updateTime();
        ligma_mpris_seeked();
    }

    pub fn mprisSetPosition(self: *PlayerPanel, microseconds: i64) void {
        const engine = self.engine orelse return;
        var target: i64 = @divTrunc(@max(microseconds, 0), 1000);
        const duration = engine.duration();
        if (duration > 0 and target > duration) target = duration;
        engine.setPosition(target);
        self.seek_slider.setValue(@intCast(@max(target, 0)));
        self.updateTime();
        ligma_mpris_seeked();
    }

    pub fn mprisSetVolume(self: *PlayerPanel, volume: f64) void {
        const clamped = std.math.clamp(volume, 0.0, 1.0);
        const percent: i32 = @intFromFloat(@round(clamped * 100.0));
        self.volume_slider.setValue(percent);
        if (self.engine) |engine| engine.setVolume(volumeFraction(percent));
        self.notifyMpris();
    }

    pub fn mprisSetLoop(self: *PlayerPanel, mode: i32) void {
        self.repeat_mode = switch (mode) {
            1 => .one,
            2 => .all,
            else => .off,
        };
        self.refreshRepeatButton();
        self.notifyMpris();
    }

    pub fn mprisSetShuffle(self: *PlayerPanel, enabled: bool) void {
        self.shuffle = enabled;
        self.refreshShuffleButton();
        self.notifyMpris();
    }

    pub fn mprisState(self: *PlayerPanel) i32 {
        const engine = self.engine orelse return 0;
        return switch (engine.state()) {
            .playing => 1,
            .paused => 2,
            .stopped => 0,
        };
    }

    pub fn mprisPositionUs(self: *PlayerPanel) i64 {
        const engine = self.engine orelse return 0;
        return engine.position() * 1000;
    }

    pub fn mprisDurationUs(self: *PlayerPanel) i64 {
        const engine = self.engine orelse return 0;
        return engine.duration() * 1000;
    }

    pub fn mprisVolume(self: *PlayerPanel) f64 {
        return @floatCast(volumeFraction(self.volume_slider.value()));
    }

    pub fn mprisLoop(self: *PlayerPanel) i32 {
        return switch (self.repeat_mode) {
            .off => 0,
            .one => 1,
            .all => 2,
        };
    }

    pub fn mprisShuffle(self: *PlayerPanel) bool {
        return self.shuffle;
    }

    pub fn mprisMetadata(self: *PlayerPanel, title_out: []u8, artist_out: []u8, album_out: []u8) void {
        @memset(title_out, 0);
        @memset(artist_out, 0);
        @memset(album_out, 0);
        const index = self.current orelse return;
        if (index >= self.playlist.items.len) return;

        var title: []const u8 = std.fs.path.basename(self.playlist.items[index]);
        var artist: []const u8 = "";
        var album: []const u8 = "";
        if (self.tags) |*tags| {
            if (nonEmpty(tags.titleSlice())) |value| title = value;
            if (nonEmpty(tags.artistSlice())) |value| artist = value;
            if (nonEmpty(tags.albumSlice())) |value| album = value;
        }
        copyMetadataField(title_out, title);
        copyMetadataField(artist_out, artist);
        copyMetadataField(album_out, album);
    }

    pub fn mprisTrackId(self: *PlayerPanel, out: []u8) void {
        @memset(out, 0);
        const index = self.current orelse return;
        if (index >= self.playlist.items.len) return;
        var buffer: [64]u8 = undefined;
        const hash = std.hash.Wyhash.hash(0, self.playlist.items[index]);
        const id = std.fmt.bufPrint(&buffer, "/org/ligma/track/{x}", .{hash}) catch return;
        copyMetadataField(out, id);
    }

    pub fn notifyMpris(self: *PlayerPanel) void {
        _ = self;
        ligma_mpris_notify();
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

        self.tags = null;
        self.mb_result = null;
        self.mb_serial +%= 1;
        self.tag_serial_seen = 0;
        self.track_loaded = false;
        self.duration_ready = false;
        self.updateTitle();
        self.seek_slider.setEnabled(true);
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setValue(0);
        self.time_label.setText("0:00 / 0:00");

        const engine = self.engine orelse {
            self.title_label.setText("Audio engine unavailable");
            return;
        };
        self.transport_active = true;
        self.playback_intent_playing = true;
        if (!engine.load(self.gpa, self.playlist.items[row])) {
            self.handleEngineError();
            return;
        }
        self.track_loaded = true;
        engine.play();
        engine.setVolume(volumeFraction(self.volume_slider.value()));
        self.refreshPlayButton();
        self.publishPresence(true);
        self.notifyMpris();
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
        const engine = self.engine orelse return;
        // Restart the current track unless it has just started.
        if (engine.position() > 3000) {
            engine.setPosition(0);
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
        engine.setPosition(0);
    }

    /// Called when GStreamer reports EndOfMedia.
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
                if (self.shuffle and self.playlist.items.len > 1) {
                    self.playIndex(self.randomOther(finished));
                } else if (finished + 1 < self.playlist.items.len) {
                    self.playIndex(finished + 1);
                } else {
                    self.finishQueue();
                }
            },
        }
    }

    fn finishQueue(self: *PlayerPanel) void {
        self.current = null;
        self.tags = null;
        self.mb_result = null;
        self.mb_serial +%= 1;
        self.track_loaded = false;
        self.duration_ready = false;
        self.transport_active = false;
        self.playback_intent_playing = false;
        if (self.engine) |engine| engine.stop();
        self.seek_slider.setValue(0);
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);
        self.time_label.setText("0:00 / 0:00");
        self.playlist_updating = true;
        self.playlist_widget.setCurrentRow(-1);
        self.playlist_updating = false;
        self.updateTitle();
        self.refreshPlayButton();
        if (self.discord) |client| client.clearActivity();
        self.notifyMpris();
    }

    fn randomOther(self: *PlayerPanel, current: usize) usize {
        const length = self.playlist.items.len;
        if (length <= 1) return current;
        const candidate = self.rng.random().uintLessThan(usize, length - 1);
        return if (candidate >= current) candidate + 1 else candidate;
    }

    fn togglePlayPause(self: *PlayerPanel) void {
        if (self.playlist.items.len == 0) return;
        const engine = self.engine orelse return;
        if (engine.state() == .playing) {
            self.playback_intent_playing = false;
            engine.pause();
            self.refreshPlayButton();
            self.publishPresence(false);
            self.notifyMpris();
            return;
        }
        if (self.current == null) {
            self.playIndex(0);
            return;
        }
        self.transport_active = true;
        self.playback_intent_playing = true;
        engine.play();
        self.refreshPlayButton();
        self.publishPresence(true);
        self.notifyMpris();
    }

    fn stop(self: *PlayerPanel) void {
        self.transport_active = false;
        self.playback_intent_playing = false;
        if (self.discord) |client| client.clearActivity();
        if (self.engine) |engine| engine.stop();
        self.seek_slider.setValue(0);
        self.time_label.setText("0:00 / 0:00");
        self.refreshPlayButton();
        self.notifyMpris();
    }

    fn cycleRepeat(self: *PlayerPanel) void {
        self.repeat_mode = switch (self.repeat_mode) {
            .off => .all,
            .all => .one,
            .one => .off,
        };
        self.refreshRepeatButton();
        self.notifyMpris();
    }

    fn refreshRepeatButton(self: *PlayerPanel) void {
        self.repeat_button.setChecked(self.repeat_mode != .off);
        self.repeat_button.setAccessibleName("Repeat");
        const repeat_one = self.repeat_mode == .one;
        self.repeat_button.setText("");
        self.repeat_button.setFixedWidth(36);
        ligma_player_control_icon(self.repeat_button.ptr, if (repeat_one) 1 else 0, 20);
        self.repeat_button.setToolTip(switch (self.repeat_mode) {
            .off => "Repeat: off",
            .all => "Repeat: all",
            .one => "Repeat: one",
        });
    }

    fn toggleShuffle(self: *PlayerPanel) void {
        self.shuffle = !self.shuffle;
        self.refreshShuffleButton();
        self.notifyMpris();
    }

    fn refreshShuffleButton(self: *PlayerPanel) void {
        self.shuffle_button.setChecked(self.shuffle);
        self.shuffle_button.setAccessibleName("Shuffle");
        self.shuffle_button.setText("");
        self.shuffle_button.setFixedWidth(36);
        ligma_player_control_icon(self.shuffle_button.ptr, 2, 20);
        self.shuffle_button.setToolTip(if (self.shuffle) "Shuffle: on" else "Shuffle: off");
    }

    pub fn clearPlaylist(self: *PlayerPanel) void {
        if (self.discord) |client| client.clearActivity();
        self.transport_active = false;
        self.playback_intent_playing = false;
        if (self.engine) |engine| engine.stop();
        self.current = null;
        self.tags = null;
        self.mb_result = null;
        self.mb_serial +%= 1;
        self.track_loaded = false;
        self.duration_ready = false;
        self.playlist_widget.clear();
        for (self.playlist.items) |path| self.gpa.free(path);
        self.playlist.clearRetainingCapacity();
        self.title_label.setText("No track loaded");
        self.time_label.setText("0:00 / 0:00");
        self.seek_slider.setRange(0, 0);
        self.seek_slider.setEnabled(false);
        self.refreshPlayButton();
        self.notifyMpris();
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
        const position_ms = if (self.engine) |engine| engine.position() else 0;
        const duration_ms = if (self.engine) |engine| engine.duration() else 0;
        const position = formatTime(&position_buffer, position_ms);
        const duration = formatTime(&duration_buffer, duration_ms);
        const text = std.fmt.bufPrint(&buffer, "{s} / {s}", .{ position, duration }) catch "0:00 / 0:00";
        self.time_label.setText(text);
    }

    fn refreshPlayButton(self: *PlayerPanel) void {
        const playing = if (self.engine) |engine| engine.state() == .playing else false;
        self.play_button.setText(if (playing) "⏸" else "▶");
    }

    fn pollEngine(self: *PlayerPanel) void {
        const engine = self.engine orelse return;
        const events = engine.poll();
        if ((events & music_engine.Failed) != 0) {
            self.handleEngineError();
            return;
        }

        const serial = engine.tagSerial();
        if (serial != self.tag_serial_seen) {
            self.tag_serial_seen = serial;
            if (engine.readTags()) |tags| {
                self.tags = tags;
                self.mb_result = null;
                self.mb_serial +%= 1;
                if (self.musicbrainz) |brainz| {
                    brainz.lookup(
                        tags.titleSlice(),
                        tags.artistSlice(),
                        tags.albumSlice(),
                        self.mb_serial,
                    );
                }
                self.publishPresence(self.playback_intent_playing);
                self.notifyMpris();
            }
        }

        const duration = engine.duration();
        if (duration > 0 and !self.duration_ready) {
            self.duration_ready = true;
            self.publishPresence(self.playback_intent_playing);
            self.notifyMpris();
        }
        if (duration > 0) {
            const clamped: i32 = @intCast(@min(duration, std.math.maxInt(i32)));
            if (self.seek_slider.maximum() != clamped)
                self.seek_slider.setRange(0, clamped);
        }

        const position: i32 = @intCast(@min(engine.position(), std.math.maxInt(i32)));
        if (!self.seek_slider.isSliderDown())
            self.seek_slider.setValue(position);
        self.updateTime();

        if (self.transport_active and (events & music_engine.Eos) != 0) {
            self.finishTrack();
        }
    }

    fn handleEngineError(self: *PlayerPanel) void {
        const detail = if (self.engine) |engine|
            if (engine.readError()) |error_text| error_text.slice() else "unknown audio error"
        else
            "audio engine unavailable";
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "Cannot play “{s}”: {s}",
            .{ self.currentName(), detail },
        ) catch "Cannot play this file";
        self.title_label.setText(text);
        self.transport_active = false;
        self.playback_intent_playing = false;
        self.track_loaded = false;
        self.duration_ready = false;
        self.seek_slider.setEnabled(false);
        if (self.discord) |client| client.clearActivity();
        self.refreshPlayButton();
    }

    fn applyOutputDevice(self: *PlayerPanel, device: []const u8) void {
        const engine = self.engine orelse return;
        const trimmed = std.mem.trim(u8, device, " \t\r\n");
        const bitperfect = trimmed.len > 0;
        if (bitperfect) {
            if (!engine.setOutput(.alsa, trimmed)) return;
        } else {
            if (!engine.setOutput(.automatic, "")) return;
        }

        if (self.output_device) |old| self.gpa.free(old);
        self.output_device = if (trimmed.len > 0) self.gpa.dupe(u8, trimmed) catch null else null;

        if (bitperfect) {
            self.volume_slider.setValue(100);
            self.volume_slider.setEnabled(false);
            self.volume_slider.setToolTip("Bit-perfect output: use the hardware volume control");
            self.title_label.setToolTip("Direct ALSA output; software volume and DSP are disabled");
            engine.setVolume(1.0);
        } else {
            self.volume_slider.setEnabled(true);
            self.volume_slider.setToolTip("");
            self.title_label.setToolTip("PipeWire audio output");
            engine.setVolume(volumeFraction(self.volume_slider.value()));
        }
    }

    /// Publish title/artist (and progress while playing) to Discord.
    fn publishPresence(self: *PlayerPanel, playing: bool) void {
        const client = self.discord orelse return;
        const index = self.current orelse {
            client.clearActivity();
            return;
        };
        if (index >= self.playlist.items.len or !self.track_loaded) return;
        if (!self.transport_active) return;

        var title: []const u8 = std.fs.path.basename(self.playlist.items[index]);
        var artist: []const u8 = "Unknown artist";
        var album_name: []const u8 = "";
        var year: []const u8 = "";
        if (self.tags) |*tags| {
            if (nonEmpty(tags.titleSlice())) |value| title = value;
            if (nonEmpty(tags.artistSlice())) |value| artist = value;
            if (nonEmpty(tags.albumSlice())) |value| album_name = value;
        }
        if (self.mb_result) |*result| {
            if (nonEmpty(result.titleSlice())) |value| title = value;
            if (nonEmpty(result.artistSlice())) |value| artist = value;
            if (album_name.len == 0) {
                if (nonEmpty(result.albumSlice())) |value| album_name = value;
            }
            if (nonEmpty(result.yearSlice())) |value| year = value;
        }

        var details_owned: ?[]u8 = null;
        defer if (details_owned) |value| self.gpa.free(value);

        // The member-list line can show only one activity field. Put the song
        // and artist together in `details`, and ask Discord to display that
        // field rather than the application name.
        var details: []const u8 = title;
        if (!std.mem.eql(u8, artist, "Unknown artist")) {
            details_owned = std.fmt.allocPrint(self.gpa, "{s} — {s}", .{ title, artist }) catch null;
            if (details_owned) |value| details = value;
        }

        var state_buffer: [320]u8 = undefined;
        var state: []const u8 = album_name;
        if (album_name.len > 0 and year.len > 0) {
            state = std.fmt.bufPrint(
                &state_buffer,
                "{s} • {s}",
                .{ album_name, year },
            ) catch album_name;
        } else if (album_name.len == 0 and year.len > 0) {
            state = year;
        }

        const position = if (self.engine) |engine| engine.position() else 0;
        const duration = if (self.engine) |engine| engine.duration() else 0;
        client.setActivity(details, state, playing, position, duration);
    }

    /// Stop playback and release everything the panel owns. The widget tree
    /// itself is owned by the dock's window and is deleted with it.
    pub fn deinit(self: *PlayerPanel) void {
        if (active == self) active = null;
        self.poll_timer.stop();
        if (self.musicbrainz) |brainz| {
            brainz.deinit();
            self.musicbrainz = null;
        }
        if (self.output_device) |device| {
            self.gpa.free(device);
            self.output_device = null;
        }
        if (self.discord) |client| {
            client.deinit();
            self.discord = null;
        }
        if (self.engine) |*engine| {
            engine.destroy();
            self.engine = null;
        }
        for (self.playlist.items) |path| self.gpa.free(path);
        self.playlist.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

fn nonEmpty(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn copyMetadataField(destination: []u8, source: []const u8) void {
    if (destination.len == 0) return;
    const length = @min(source.len, destination.len - 1);
    @memcpy(destination[0..length], source[0..length]);
    destination[length] = 0;
}

fn envFlag(name: [*:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    return !(value.len == 0 or
        std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "off"));
}

fn audioOutputMode() music_engine.OutputMode {
    const raw = std.c.getenv("LIGMA_AUDIO_MODE") orelse return .automatic;
    const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (std.ascii.eqlIgnoreCase(value, "alsa") or
        std.ascii.eqlIgnoreCase(value, "bitperfect") or
        std.ascii.eqlIgnoreCase(value, "bit-perfect"))
    {
        return .alsa;
    }
    return .automatic;
}

fn eqPresetGains() ?[10]f64 {
    const raw = std.c.getenv("LIGMA_AUDIO_EQ") orelse return null;
    const name = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    if (std.ascii.eqlIgnoreCase(name, "bass")) {
        return .{ 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 };
    }
    if (std.ascii.eqlIgnoreCase(name, "vocal")) {
        return .{ -2, -1, 0, 2, 4, 4, 3, 1, 0, -1 };
    }
    if (std.ascii.eqlIgnoreCase(name, "rock")) {
        return .{ 4, 3, 2, 0, -1, -1, 0, 2, 3, 4 };
    }
    return null;
}

fn volumeFraction(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 100.0;
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
    if (active) |panel| {
        if (panel.engine) |engine| engine.setPosition(value);
    }
}

fn onSeekReleased(_: QSlider) callconv(.c) void {
    if (active) |panel| {
        panel.publishPresence(panel.playback_intent_playing);
        ligma_mpris_seeked();
    }
}

fn onRepeatClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.cycleRepeat();
}

fn onShuffleClicked(_: QPushButton) callconv(.c) void {
    if (active) |panel| panel.toggleShuffle();
}

fn onOutputClicked(_: QPushButton) callconv(.c) void {
    const panel = active orelse return;
    var ok = false;
    const current = panel.output_device orelse "";
    const raw = QInputDialog.getText6(
        panel.gpa,
        panel.container,
        "Audio Output",
        "Empty = PipeWire. Enter an ALSA device such as hw:1,0 for direct/bit-perfect output:",
        qlineedit_enums.EchoMode.Normal,
        current,
        &ok,
    );
    defer panel.gpa.free(raw);
    if (!ok) return;
    panel.applyOutputDevice(raw);
}

fn onVolumeChanged(_: QSlider, value: i32) callconv(.c) void {
    if (active) |panel| {
        if (panel.engine) |engine| engine.setVolume(volumeFraction(value));
        ligma_mpris_notify();
    }
}

fn onPlaylistRowChanged(_: QListWidget, row: i32) callconv(.c) void {
    const panel = active orelse return;
    if (panel.playlist_updating or row < 0) return;
    panel.playIndex(@intCast(row));
}

fn onPollTimer(_: QTimer) callconv(.c) void {
    if (active) |panel| panel.pollEngine();
}

fn onMusicBrainzResult(result: musicbrainz.Result) void {
    const panel = active orelse return;
    if (panel.current == null) return;
    if (result.serial != panel.mb_serial) return;
    panel.mb_result = result;
    panel.publishPresence(panel.playback_intent_playing);
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
