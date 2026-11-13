//! Bottom-left preview panel.
//!
//! Selecting exactly one image or video file shows a larger thumbnail in a
//! small panel under the Places sidebar (the window's bottom-left corner).
//! The panel hides for anything else: folders, multiple selections, and
//! non-media files.
//!
//! Images are decoded with `QImageReader` at display size, so even large
//! photos only allocate the thumbnail. Videos are handed to `ffmpeg`, which
//! extracts one frame into a temporary PNG; extraction is asynchronous, and
//! when a video is shorter than the 1 s seek the job falls back to decoding
//! from the very first frame.

const std = @import("std");
const qt6 = @import("libqt6zig");

const local_model = @import("local_model.zig");

const QLabel = qt6.QLabel;
const QPixmap = qt6.QPixmap;
const QImageReader = qt6.QImageReader;
const QMimeDatabase = qt6.QMimeDatabase;
const QProcess = qt6.QProcess;
const QSize = qt6.QSize;
const QVBoxLayout = qt6.QVBoxLayout;
const QWidget = qt6.QWidget;

const qnamespace_enums = qt6.qnamespace_enums;
const qprocess_enums = qt6.qprocess_enums;

/// Box the thumbnails are fitted into. Small enough to fit the sidebar's
/// inner width in both the normal and the split-view layout.
pub const IMAGE_W: i32 = 212;
pub const IMAGE_H: i32 = 168;

/// ffmpeg extracts frames at this width; the label scales down again.
const VIDEO_W: i32 = 480;

const Kind = enum { image, video, other };

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
    image_label: QLabel = undefined,
    caption: QLabel = undefined,
    seq: u64 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) PreviewPanel {
        var self: PreviewPanel = .{ .gpa = gpa, .io = io };

        self.container = QWidget.new2();
        self.image_label = QLabel.new3("");
        self.caption = QLabel.new3("");

        self.image_label.setAlignment(qnamespace_enums.AlignmentFlag.AlignCenter);
        self.image_label.setFixedHeight(IMAGE_H);
        self.image_label.setStyleSheet(
            "QLabel { background: rgba(127, 127, 127, 0.14); " ++
                "border: 1px solid rgba(127, 127, 127, 0.30); border-radius: 4px; }",
        );
        self.caption.setWordWrap(true);
        self.caption.setFixedHeight(36);

        const layout = QVBoxLayout.new(self.container);
        layout.setContentsMargins(0, 8, 0, 0);
        layout.setSpacing(2);
        layout.addWidget(self.image_label);
        layout.addWidget(self.caption);

        self.container.setVisible(false);
        return self;
    }

    /// Show the item under the panel. Callers pass one selected file; the
    /// panel hides itself for anything it cannot preview.
    pub fn showItem(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        self.seq += 1;
        self.cancelPending();
        self.clearImage();

        switch (classify(self.gpa, path)) {
            .image => self.showImage(path, name, size),
            .video => self.showVideo(path, name, size),
            .other => self.hide(),
        }
    }

    pub fn hide(self: *PreviewPanel) void {
        self.cancelPending();
        self.clearImage();
        self.container.hide();
    }

    /// Kill in-flight ffmpeg jobs and release everything the panel owns.
    pub fn deinit(self: *PreviewPanel) void {
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

    fn clearImage(self: *PreviewPanel) void {
        self.image_label.clear();
    }

    fn show(self: *PreviewPanel) void {
        self.container.show();
    }

    fn showImage(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        const reader = QImageReader.new3(path);
        defer reader.delete();

        // Decode straight into the display size; size() reads only the header.
        var full_w: i32 = 0;
        var full_h: i32 = 0;
        {
            const full = reader.size();
            defer full.delete();
            full_w = full.width();
            full_h = full.height();
        }
        if (full_w > 0 and full_h > 0) {
            const fit = fitWithin(full_w, full_h, IMAGE_W, IMAGE_H);
            const scaled = QSize.new4(fit[0], fit[1]);
            defer scaled.delete();
            reader.setScaledSize(scaled);
        }

        const image = reader.read();
        defer image.delete();
        if (image.isNull()) {
            self.hide();
            return;
        }

        const pixmap = QPixmap.fromImage(image);
        defer pixmap.delete();
        self.image_label.setPixmap(pixmap);
        self.show();

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

    fn showVideo(self: *PreviewPanel, path: []const u8, name: []const u8, size: u64) void {
        const size_text = local_model.formatSize(size);
        const text = std.fmt.allocPrint(
            self.gpa,
            "{s} — Video • {s}",
            .{ name, size_text },
        ) catch return;
        defer self.gpa.free(text);
        self.caption.setText(text);
        self.show();

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

    fn loadVideoFrame(self: *PreviewPanel, tmp: []const u8) void {
        const pixmap = QPixmap.new4(tmp);
        defer pixmap.delete();
        if (pixmap.isNull()) {
            self.hide();
            return;
        }

        const w = pixmap.width();
        const h = pixmap.height();
        if (w > IMAGE_W or h > IMAGE_H) {
            const fit = fitWithin(w, h, IMAGE_W, IMAGE_H);
            const scaled = pixmap.scaledToWidth(fit[0]);
            defer scaled.delete();
            self.image_label.setPixmap(scaled);
        } else {
            self.image_label.setPixmap(pixmap);
        }
        self.show();
    }
};

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

    // ffmpeg failed with the 1 s seek — likely a very short video. Retry by
    // decoding from the first frame.
    if (!ok and panel.seq == job.seq and job.attempt == 0) {
        job.attempt = 1;
        startFfmpeg(proc, job);
        return;
    }

    _ = video_jobs.remove(key);
    defer {
        freeJob(panel.gpa, panel.io, job);
        proc.deleteLater();
    }
    if (panel.seq != job.seq) return;
    if (!ok) {
        panel.hide();
        return;
    }
    panel.loadVideoFrame(job.tmp);
}

fn onVideoError(proc: QProcess, code: i32) callconv(.c) void {
    // Only FailedToStart needs handling here: Qt never emits finished() when a
    // program could not start. Other errors (e.g. Crashed) are followed by
    // finished() and are handled by onVideoFinished.
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
    panel.hide();
}

fn classify(allocator: std.mem.Allocator, path: []const u8) Kind {
    const db = QMimeDatabase.new();
    defer db.delete();
    const mime = db.mimeTypeForFile(path);
    defer mime.delete();
    const name = mime.name(allocator);
    defer allocator.free(name);
    if (std.mem.startsWith(u8, name, "image/")) return .image;
    if (std.mem.startsWith(u8, name, "video/")) return .video;
    return .other;
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
    // Landscape 16:9 lands inside the box.
    const wide = fitWithin(1920, 1080, 224, 168);
    try std.testing.expect(wide[0] <= 224 and wide[1] <= 168);
    try std.testing.expectApproxEqAbs(@as(f64, 1920.0 / 1080.0), @as(f64, @floatFromInt(wide[0])) / @as(f64, @floatFromInt(wide[1])), 0.01);
}
