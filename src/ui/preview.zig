//! Bottom-left preview panel.
//!
//! The panel fills the sidebar space below Places and Drives. It shows a
//! placeholder when nothing is selected, a scaled image or video frame for
//! media, and a file summary for everything else. Hovering a video plays a
//! short muted snippet through Qt Multimedia.
//!
//! Static video frames are extracted with ffmpeg, asynchronously. When ffmpeg
//! cannot seek one second in, the job retries from the first frame so short
//! clips still get a thumbnail.

const std = @import("std");
const qt6 = @import("libqt6zig");

const local_model = @import("local_model.zig");

const QAudioOutput = qt6.QAudioOutput;
const QLabel = qt6.QLabel;
const QMediaPlayer = qt6.QMediaPlayer;
const QMimeDatabase = qt6.QMimeDatabase;
const QPixmap = qt6.QPixmap;
const QImageReader = qt6.QImageReader;
const QProcess = qt6.QProcess;
const QSize = qt6.QSize;
const QTimer = qt6.QTimer;
const QUrl = qt6.QUrl;
const QVBoxLayout = qt6.QVBoxLayout;
const QVideoWidget = qt6.QVideoWidget;
const QWidget = qt6.QWidget;

const qnamespace_enums = qt6.qnamespace_enums;
const qprocess_enums = qt6.qprocess_enums;
const qsizepolicy_enums = qt6.qsizepolicy_enums;

/// Initial box used before the sidebar has been laid out.
const INITIAL_W: i32 = 260;
const INITIAL_H: i32 = 200;

/// ffmpeg extracts frames at this width; the label scales to fit.
const VIDEO_W: i32 = 640;

const Kind = enum { image, video, other };

var active: ?*PreviewPanel = null;

const VideoJob = struct {
    panel: *PreviewPanel,
    proc: QProcess,
    seq: u64,
    path: []u8,
    tmp: []u8,
    attempt: u8,
};

/// Live QProcess pointers mapped to their job, so the finished/error
/// callbacks can find the Zig state (same pattern as local_model's registry).
var video_jobs: std.AutoHashMapUnmanaged(usize, *VideoJob) = .empty;

pub const PreviewPanel = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    container: QWidget = undefined,
    layout: QVBoxLayout = undefined,
    image_label: QLabel = undefined,
    caption: QLabel = undefined,
    seq: u64 = 0,

    selected_path: ?[]u8 = null,
    selected_name: ?[]u8 = null,
    selected_size: u64 = 0,

    hover_path: ?[]u8 = null,
    hover_timer: QTimer = undefined,
    hover_enabled: bool = true,
    hover_seconds: i32 = 4,

    video_widget: ?QVideoWidget = null,
    video_player: ?QMediaPlayer = null,
    video_audio: ?QAudioOutput = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) PreviewPanel {
        var self: PreviewPanel = .{ .gpa = gpa, .io = io };

        self.container = QWidget.new2();
        self.container.setSizePolicy2(qsizepolicy_enums.Policy.Expanding, qsizepolicy_enums.Policy.Expanding);

        self.image_label = QLabel.new3("Select a file to preview");
        self.image_label.setAlignment(qnamespace_enums.AlignmentFlag.AlignCenter);
        self.image_label.setWordWrap(true);
        self.image_label.setSizePolicy2(qsizepolicy_enums.Policy.Expanding, qsizepolicy_enums.Policy.Expanding);
        self.image_label.setMinimumHeight(120);
        self.image_label.setStyleSheet(
            "QLabel { background: rgba(127, 127, 127, 0.14); " ++
                "border: 1px solid rgba(127, 127, 127, 0.30); border-radius: 4px; " ++
                "padding: 8px; }",
        );

        self.caption = QLabel.new3("");
        self.caption.setWordWrap(true);
        self.caption.setAlignment(qnamespace_enums.AlignmentFlag.AlignCenter);
        self.caption.setMinimumHeight(36);

        self.layout = QVBoxLayout.new(self.container);
        self.layout.setContentsMargins(0, 8, 0, 0);
        self.layout.setSpacing(4);
        self.layout.addWidget2(self.image_label, 1);
        self.layout.addWidget(self.caption);

        self.hover_timer = QTimer.new2(self.container);
        self.hover_timer.setSingleShot(true);
        self.hover_timer.onTimeout(onHoverTimer);

        return self;
    }

    pub fn activate(self: *PreviewPanel) void {
        active = self;
    }

    pub fn setHoverEnabled(self: *PreviewPanel, enabled: bool) void {
        self.hover_enabled = enabled;
        if (!enabled) self.stopHover(true);
    }

    pub fn setHoverSeconds(self: *PreviewPanel, seconds: i32) void {
        self.hover_seconds = std.math.clamp(seconds, 1, 30);
    }

    /// Show the item under the panel. Callers pass one selected file.
    pub fn showItem(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        self.replaceSelected(path, name, size);
        self.stopHover(false);
        self.renderSelected();
    }

    /// Clear the selection and show the idle placeholder. The panel itself
    /// stays visible so it owns the full empty sidebar area.
    pub fn hide(self: *PreviewPanel) void {
        self.clearSelected();
        self.stopHover(false);
        self.cancelPending();
        self.clearImage();
        self.image_label.setText("Select a file to preview");
        self.caption.setText("Images, videos, and file details appear here");
        self.showImageLabel();
        self.container.show();
    }

    /// Play a muted snippet when a video row is hovered. Non-video paths
    /// restore the selected item's normal preview.
    pub fn hoverVideo(self: *PreviewPanel, path: []const u8) void {
        if (!self.hover_enabled) return;
        if (path.len == 0) {
            self.stopHover(true);
            return;
        }
        if (classify(self.gpa, path) != .video) {
            self.stopHover(true);
            return;
        }
        if (self.hover_path) |current| {
            if (std.mem.eql(u8, current, path) and self.video_widget != null and
                self.video_widget.?.isVisible()) return;
        }

        self.replaceHover(path);
        self.seq +%= 1;
        self.cancelPending();
        self.ensureVideo();
        self.showVideoWidget();

        const url = QUrl.fromLocalFile(path);
        defer url.delete();
        const player = self.video_player orelse return;
        player.setSource(url);
        player.setPosition(0);
        player.play();
        self.hover_timer.start(self.hover_seconds * 1000);

        self.caption.setText("Hover preview");
        self.container.show();
    }

    /// Kill in-flight ffmpeg jobs and release everything the panel owns.
    pub fn deinit(self: *PreviewPanel) void {
        self.hover_timer.stop();
        if (active == self) active = null;
        if (self.video_player) |player| {
            player.stop();
            player.delete();
            self.video_player = null;
        }
        if (self.video_audio) |audio| {
            audio.delete();
            self.video_audio = null;
        }
        if (self.video_widget) |widget| {
            widget.delete();
            self.video_widget = null;
        }
        self.clearSelected();
        self.clearHover();

        var keys: std.ArrayList(usize) = .empty;
        defer keys.deinit(self.gpa);
        var it = video_jobs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.panel == self)
                keys.append(self.gpa, entry.key_ptr.*) catch {};
        }
        for (keys.items) |key| {
            const job = video_jobs.get(key) orelse continue;
            _ = video_jobs.remove(key);
            job.proc.kill();
            freeJob(self.gpa, self.io, job);
            job.proc.delete();
        }
        video_jobs.deinit(self.gpa);
    }

    fn renderSelected(self: *PreviewPanel) void {
        const path = self.selected_path orelse {
            self.hide();
            return;
        };
        const name = self.selected_name orelse std.fs.path.basename(path);
        const size = self.selected_size;

        self.cancelPending();
        self.showImageLabel();
        self.clearImage();

        switch (classify(self.gpa, path)) {
            .image => self.showImage(path, name, size),
            .video => self.showVideoThumbnail(path, name, size),
            .other => self.showOther(name, size),
        }
        self.container.show();
    }

    fn showImageLabel(self: *PreviewPanel) void {
        if (self.video_widget) |widget| widget.hide();
        self.image_label.show();
    }

    fn showVideoWidget(self: *PreviewPanel) void {
        self.image_label.hide();
        if (self.video_widget) |widget| widget.show();
    }

    fn clearImage(self: *PreviewPanel) void {
        self.image_label.clear();
    }

    fn showImage(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        const reader = QImageReader.new3(path);
        defer reader.delete();
        reader.setAutoTransform(true);

        var full_w: i32 = 0;
        var full_h: i32 = 0;
        {
            const full = reader.size();
            defer full.delete();
            full_w = full.width();
            full_h = full.height();
        }

        const box = self.previewBox();
        if (full_w > 0 and full_h > 0) {
            const fit = fitWithin(full_w, full_h, box[0], box[1]);
            const scaled = QSize.new4(fit[0], fit[1]);
            defer scaled.delete();
            reader.setScaledSize(scaled);
        }

        const image = reader.read();
        defer image.delete();
        if (image.isNull()) {
            self.showOther(name, size);
            return;
        }

        const pixmap = QPixmap.fromImage(image);
        defer pixmap.delete();
        self.image_label.setPixmap(pixmap);
        self.showImageLabel();

        var cap_w: i32 = full_w;
        var cap_h: i32 = full_h;
        if (cap_w <= 0 or cap_h <= 0) {
            cap_w = image.width();
            cap_h = image.height();
        }
        const size_text = local_model.formatSize(size);
        const text = std.fmt.allocPrint(
            self.gpa,
            "{s} — {d}×{d} • {s}",
            .{ name, cap_w, cap_h, size_text },
        ) catch return;
        defer self.gpa.free(text);
        self.caption.setText(text);
    }

    fn showVideoThumbnail(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        const size_text = local_model.formatSize(size);
        const text = std.fmt.allocPrint(
            self.gpa,
            "{s} — Video • {s}",
            .{ name, size_text },
        ) catch return;
        defer self.gpa.free(text);
        self.caption.setText(text);
        self.image_label.setText("Loading video preview…");
        self.showImageLabel();

        const tmp = std.fmt.allocPrint(
            self.gpa,
            "/tmp/ligma-preview-{d}-{d}.png",
            .{ std.os.linux.getpid(), self.seq },
        ) catch return;
        const path_copy = self.gpa.dupe(u8, path) catch {
            self.gpa.free(tmp);
            return;
        };
        const job = self.gpa.create(VideoJob) catch {
            self.gpa.free(tmp);
            self.gpa.free(path_copy);
            return;
        };
        job.* = .{
            .panel = self,
            .proc = undefined,
            .seq = self.seq,
            .path = path_copy,
            .tmp = tmp,
            .attempt = 0,
        };

        const proc = QProcess.new();
        job.proc = proc;
        proc.setProgram("ffmpeg");
        video_jobs.put(self.gpa, @intFromPtr(proc.ptr), job) catch {
            freeJob(self.gpa, self.io, job);
            proc.delete();
            return;
        };
        proc.onFinished2(onVideoFinished);
        proc.onErrorOccurred(onVideoError);
        startFfmpeg(proc, job);
    }

    fn showOther(self: *PreviewPanel, name: []const u8, size: u64) void {
        self.image_label.clear();
        self.image_label.setText("No preview available");
        const size_text = local_model.formatSize(size);
        const text = std.fmt.allocPrint(self.gpa, "{s} • {s}", .{ name, size_text }) catch name;
        defer if (text.ptr != name.ptr) self.gpa.free(text);
        self.caption.setText(text);
        self.showImageLabel();
    }

    fn previewBox(self: *PreviewPanel) [2]i32 {
        const width = self.image_label.width();
        const height = self.image_label.height();
        return .{
            @max(width, INITIAL_W),
            @max(height, INITIAL_H),
        };
    }

    fn replaceSelected(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        self.clearSelected();
        self.selected_path = self.gpa.dupe(u8, path) catch null;
        if (self.selected_path == null) return;
        self.selected_name = self.gpa.dupe(u8, name) catch null;
        self.selected_size = size;
        self.seq +%= 1;
    }

    fn clearSelected(self: *PreviewPanel) void {
        if (self.selected_path) |path| self.gpa.free(path);
        if (self.selected_name) |name| self.gpa.free(name);
        self.selected_path = null;
        self.selected_name = null;
        self.selected_size = 0;
    }

    fn replaceHover(self: *PreviewPanel, path: []const u8) void {
        self.clearHover();
        self.hover_path = self.gpa.dupe(u8, path) catch null;
    }

    fn clearHover(self: *PreviewPanel) void {
        if (self.hover_path) |path| self.gpa.free(path);
        self.hover_path = null;
    }

    fn ensureVideo(self: *PreviewPanel) void {
        if (self.video_widget != null) return;

        const widget = QVideoWidget.new(self.container);
        widget.setAspectRatioMode(qnamespace_enums.AspectRatioMode.KeepAspectRatio);
        widget.setStyleSheet("background: black;");
        widget.hide();
        self.layout.insertWidget3(0, widget, 1);

        const audio = QAudioOutput.new3(self.container);
        audio.setMuted(true);

        const player = QMediaPlayer.new2(self.container);
        player.setAudioOutput(audio);
        player.setVideoOutput(widget);
        player.setLoops(-1);

        self.video_widget = widget;
        self.video_audio = audio;
        self.video_player = player;
    }

    fn stopHover(self: *PreviewPanel, restore: bool) void {
        const was_active = self.hover_path != null or
            (self.video_widget != null and self.video_widget.?.isVisible());
        if (!was_active) return;
        self.hover_timer.stop();
        self.seq +%= 1;
        self.cancelPending();
        if (self.video_player) |player| player.stop();
        if (self.video_widget) |widget| widget.hide();
        self.clearHover();
        if (restore) self.renderSelected();
    }

    fn cancelPending(self: *PreviewPanel) void {
        var keys: std.ArrayList(usize) = .empty;
        defer keys.deinit(self.gpa);
        var it = video_jobs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.panel == self)
                keys.append(self.gpa, entry.key_ptr.*) catch {};
        }
        for (keys.items) |key| {
            const job = video_jobs.get(key) orelse continue;
            // Killed jobs are cleaned up when their finished()/errorOccurred()
            // callbacks report the stale sequence number.
            job.proc.kill();
        }
    }

    fn loadVideoFrame(self: *PreviewPanel, tmp: []const u8) bool {
        const pixmap = QPixmap.new4(tmp);
        defer pixmap.delete();
        if (pixmap.isNull()) return false;

        const fit = fitWithin(pixmap.width(), pixmap.height(), self.previewBox()[0], self.previewBox()[1]);
        const scaled = pixmap.scaled4(
            fit[0],
            fit[1],
            qnamespace_enums.AspectRatioMode.KeepAspectRatio,
            qnamespace_enums.TransformationMode.SmoothTransformation,
        );
        defer scaled.delete();
        self.image_label.setPixmap(scaled);
        self.showImageLabel();
        return true;
    }
};

fn onHoverTimer(_: QTimer) callconv(.c) void {
    if (active) |panel| panel.stopHover(true);
}

fn freeJob(gpa: std.mem.Allocator, io: std.Io, job: *VideoJob) void {
    std.Io.Dir.deleteFileAbsolute(io, job.tmp) catch {};
    gpa.free(job.path);
    gpa.free(job.tmp);
    gpa.destroy(job);
}

/// Extracts one frame with ffmpeg. Attempt 0 seeks to 1 s so thumbnails show
/// real content instead of fading-in first frames; attempt 1 decodes from
/// frame 0, which also works for videos shorter than the seek offset.
fn startFfmpeg(proc: QProcess, job: *VideoJob) void {
    const scale_arg = std.fmt.allocPrint(job.panel.gpa, "scale={d}:-2", .{VIDEO_W}) catch {
        _ = video_jobs.remove(@intFromPtr(proc.ptr));
        freeJob(job.panel.gpa, job.panel.io, job);
        proc.deleteLater();
        return;
    };
    defer job.panel.gpa.free(scale_arg);

    var argv: [12][]const u8 = undefined;
    var n: usize = 0;
    argv[n] = "-y";
    n += 1;
    argv[n] = "-loglevel";
    n += 1;
    argv[n] = "error";
    n += 1;
    if (job.attempt == 0) {
        argv[n] = "-ss";
        n += 1;
        argv[n] = "1";
        n += 1;
    }
    argv[n] = "-i";
    n += 1;
    argv[n] = job.path;
    n += 1;
    argv[n] = "-frames:v";
    n += 1;
    argv[n] = "1";
    n += 1;
    argv[n] = "-vf";
    n += 1;
    argv[n] = scale_arg;
    n += 1;
    argv[n] = job.tmp;
    n += 1;

    proc.setArguments(job.panel.gpa, argv[0..n]);
    proc.start2();
}

fn onVideoFinished(proc: QProcess, exit_code: i32, exit_status: i32) callconv(.c) void {
    const key = @intFromPtr(proc.ptr);
    const job = video_jobs.get(key) orelse {
        proc.deleteLater();
        return;
    };
    const panel = job.panel;
    const ok = exit_status == 0 and exit_code == 0;

    if (panel.seq == job.seq) {
        if (ok and panel.loadVideoFrame(job.tmp)) {
            _ = video_jobs.remove(key);
            defer {
                freeJob(panel.gpa, panel.io, job);
                proc.deleteLater();
            }
            return;
        }
        if (job.attempt == 0) {
            // A seek only one second into a very short clip can succeed while
            // writing no frame. Retry from the beginning before giving up.
            job.attempt = 1;
            startFfmpeg(proc, job);
            return;
        }
        panel.showOther(panel.selected_name orelse "Video", panel.selected_size);
    }

    _ = video_jobs.remove(key);
    defer {
        freeJob(panel.gpa, panel.io, job);
        proc.deleteLater();
    }
}

fn onVideoError(proc: QProcess, code: i32) callconv(.c) void {
    if (code != qprocess_enums.ProcessError.FailedToStart) return;

    const key = @intFromPtr(proc.ptr);
    const job = video_jobs.get(key) orelse return;
    const panel = job.panel;

    if (panel.seq != job.seq) {
        _ = video_jobs.remove(key);
        defer proc.deleteLater();
        freeJob(panel.gpa, panel.io, job);
        return;
    }
    if (job.attempt == 0) {
        job.attempt = 1;
        startFfmpeg(proc, job);
        return;
    }
    _ = video_jobs.remove(key);
    defer proc.deleteLater();
    freeJob(panel.gpa, panel.io, job);
    panel.showOther(panel.selected_name orelse "Video", panel.selected_size);
}

/// A single MIME database is enough for the panel's lifetime. Creating one
/// per hover was measurable when the pointer moved quickly down a folder.
var mime_db: ?QMimeDatabase = null;

fn classify(allocator: std.mem.Allocator, path: []const u8) Kind {
    if (hasExtension(path, &.{
        ".mp4",  ".mkv", ".webm", ".avi",  ".mov", ".m4v", ".mpg",
        ".mpeg", ".ogv", ".ts",   ".m2ts", ".3gp", ".flv", ".wmv",
    })) return .video;
    if (hasExtension(path, &.{
        ".png",  ".jpg", ".jpeg", ".gif",  ".webp", ".bmp", ".tif",
        ".tiff", ".svg", ".avif", ".heic", ".jxl",  ".ico",
    })) return .image;

    if (mime_db == null) mime_db = QMimeDatabase.new();
    const db = mime_db.?;
    const mime = db.mimeTypeForFile(path);
    defer mime.delete();
    const name = mime.name(allocator);
    defer allocator.free(name);
    if (std.mem.startsWith(u8, name, "image/")) return .image;
    if (std.mem.startsWith(u8, name, "video/")) return .video;
    return .other;
}

fn hasExtension(path: []const u8, extensions: []const []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// Largest size that fits in the box, aspect ratio preserved, never upscaling.
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

test "fitWithin keeps aspect ratio and never upscales" {
    try std.testing.expectEqual([2]i32{ 232, 116 }, fitWithin(256, 128, 232, 176));
    try std.testing.expectEqual([2]i32{ 52, 176 }, fitWithin(300, 1000, 232, 176));
    try std.testing.expectEqual([2]i32{ 100, 50 }, fitWithin(100, 50, 232, 176));
    try std.testing.expectEqual([2]i32{ 22, 176 }, fitWithin(50, 400, 232, 176));
    try std.testing.expectEqual([2]i32{ 232, 175 }, fitWithin(232, 175, 232, 176));
    try std.testing.expectEqual([2]i32{ 0, 0 }, fitWithin(0, 0, 232, 176));
    const wide = fitWithin(1920, 1080, 224, 168);
    try std.testing.expect(wide[0] <= 224 and wide[1] <= 168);
    try std.testing.expectApproxEqAbs(@as(f64, 1920.0 / 1080.0), @as(f64, @floatFromInt(wide[0])) / @as(f64, @floatFromInt(wide[1])), 0.01);
}
