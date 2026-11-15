//! Optional MusicBrainz metadata enrichment for the music player.
//!
//! The player already has tags for most files. MusicBrainz is used to fill in
//! missing or inconsistent artist/album data and to add a release year to the
//! Discord Rich Presence. Requests are serialized at one per 1.1 seconds to
//! respect the public API's rate limit and only happen while a track is
//! playing with known title+artist tags.

const std = @import("std");
const qt6 = @import("libqt6zig");

const QNetworkAccessManager = qt6.QNetworkAccessManager;
const QNetworkReply = qt6.QNetworkReply;
const QNetworkRequest = qt6.QNetworkRequest;
const QTimer = qt6.QTimer;
const QUrl = qt6.QUrl;

const max_field = 256;
const min_interval_ms = 1100;

pub const Result = struct {
    serial: u64 = 0,
    title: [max_field]u8 = std.mem.zeroes([max_field]u8),
    artist: [max_field]u8 = std.mem.zeroes([max_field]u8),
    album: [max_field]u8 = std.mem.zeroes([max_field]u8),
    year: [8]u8 = std.mem.zeroes([8]u8),

    pub fn titleSlice(self: *const Result) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }

    pub fn artistSlice(self: *const Result) []const u8 {
        return std.mem.sliceTo(&self.artist, 0);
    }

    pub fn albumSlice(self: *const Result) []const u8 {
        return std.mem.sliceTo(&self.album, 0);
    }

    pub fn yearSlice(self: *const Result) []const u8 {
        return std.mem.sliceTo(&self.year, 0);
    }
};

pub const Callback = *const fn (result: Result) void;

const Query = struct {
    title: [max_field]u8 = std.mem.zeroes([max_field]u8),
    artist: [max_field]u8 = std.mem.zeroes([max_field]u8),
    album: [max_field]u8 = std.mem.zeroes([max_field]u8),
    serial: u64 = 0,

    fn titleSlice(self: *const Query) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }

    fn artistSlice(self: *const Query) []const u8 {
        return std.mem.sliceTo(&self.artist, 0);
    }

    fn albumSlice(self: *const Query) []const u8 {
        return std.mem.sliceTo(&self.album, 0);
    }
};

var active: ?*MusicBrainz = null;

pub const MusicBrainz = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    manager: QNetworkAccessManager,
    timer: QTimer,
    callback: Callback,
    enabled: bool = true,
    pending: ?Query = null,
    in_flight: ?Query = null,
    reply: ?QNetworkReply = null,
    last_request_ms: i64 = 0,

    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        parent: anytype,
        callback: Callback,
    ) !*MusicBrainz {
        const self = try gpa.create(MusicBrainz);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .manager = QNetworkAccessManager.new2(parent),
            .timer = undefined,
            .callback = callback,
        };
        self.enabled = musicbrainzEnabled();
        self.timer = QTimer.new2(self.manager);
        self.timer.setSingleShot(true);
        self.timer.setInterval(@intCast(min_interval_ms));
        self.timer.onTimeout(onTimer);
        self.manager.onFinished(onManagerFinished);
        active = self;
        return self;
    }

    pub fn lookup(self: *MusicBrainz, title: []const u8, artist: []const u8, album: []const u8, serial: u64) void {
        if (!self.enabled) return;
        const clean_title = std.mem.trim(u8, title, " \t\r\n");
        const clean_artist = std.mem.trim(u8, artist, " \t\r\n");
        if (clean_title.len == 0 or clean_artist.len == 0) return;
        if (std.ascii.eqlIgnoreCase(clean_artist, "unknown artist")) return;

        var query: Query = .{ .serial = serial };
        copyField(&query.title, clean_title);
        copyField(&query.artist, clean_artist);
        copyField(&query.album, std.mem.trim(u8, album, " \t\r\n"));
        self.pending = query;

        if (self.reply == null)
            self.scheduleNext();
    }

    fn scheduleNext(self: *MusicBrainz) void {
        if (self.pending == null) return;
        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const elapsed = now - self.last_request_ms;
        if (elapsed >= min_interval_ms) {
            self.startPending();
            return;
        }
        self.timer.start(@intCast(min_interval_ms - elapsed));
    }

    fn startPending(self: *MusicBrainz) void {
        const query = self.pending orelse return;
        self.pending = null;
        self.in_flight = query;

        const encoded_title = QUrl.toPercentEncoding(self.gpa, query.titleSlice());
        defer self.gpa.free(encoded_title);
        const encoded_artist = QUrl.toPercentEncoding(self.gpa, query.artistSlice());
        defer self.gpa.free(encoded_artist);

        var url: std.ArrayList(u8) = .empty;
        defer url.deinit(self.gpa);
        url.appendSlice(self.gpa, "https://musicbrainz.org/ws/2/recording/?query=recording:%22") catch return;
        url.appendSlice(self.gpa, encoded_title) catch return;
        url.appendSlice(self.gpa, "%22%20AND%20artist:%22") catch return;
        url.appendSlice(self.gpa, encoded_artist) catch return;
        url.appendSlice(self.gpa, "%22&fmt=json&limit=1") catch return;

        const qurl = QUrl.fromEncoded(url.items);
        defer qurl.delete();
        const request = QNetworkRequest.new2(qurl);
        defer request.delete();
        request.setRawHeader("User-Agent", "Ligma/0.5 (https://github.com/jaytheoutpatient/ligma)");
        request.setRawHeader("Accept", "application/json");

        const reply = self.manager.get(request);
        if (reply.ptr == null) {
            self.in_flight = null;
            return;
        }
        self.reply = reply;
        self.last_request_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        reply.onFinished(onReplyFinished);
    }

    pub fn deinit(self: *MusicBrainz) void {
        if (active == self) active = null;
        self.timer.stop();
        if (self.reply) |reply| {
            reply.abort();
            reply.deleteLater();
            self.reply = null;
        }
        self.manager.delete();
        self.gpa.destroy(self);
    }
};

fn musicbrainzEnabled() bool {
    const raw = std.c.getenv("LIGMA_MUSICBRAINZ") orelse return true;
    const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    return !(value.len == 0 or
        std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "off"));
}

fn copyField(destination: []u8, source: []const u8) void {
    @memset(destination, 0);
    const length = @min(source.len, destination.len - 1);
    @memcpy(destination[0..length], source[0..length]);
}

fn onManagerFinished(_: QNetworkAccessManager, _: QNetworkReply) callconv(.c) void {
    // Replies are handled by their individual finished callback. Keeping this
    // signal connected gives us a place for future shared error handling.
}

fn onReplyFinished(reply: QNetworkReply) callconv(.c) void {
    const self = active orelse return;
    const current = self.reply orelse return;
    if (current.ptr != reply.ptr) return;
    self.reply = null;

    const body = reply.readAll(self.gpa);
    defer self.gpa.free(body);
    reply.deleteLater();

    const query = self.in_flight orelse {
        self.scheduleNext();
        return;
    };
    self.in_flight = null;

    parseResult(self.gpa, body, query) catch {};
    self.scheduleNext();
}

fn parseResult(gpa: std.mem.Allocator, body: []const u8, query: Query) !void {
    const self = active orelse return;
    if (body.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const recordings_value = root.get("recordings") orelse return;
    const recordings = switch (recordings_value) {
        .array => |array| array,
        else => return,
    };
    if (recordings.items.len == 0) return;
    const recording_value = recordings.items[0];
    const recording = switch (recording_value) {
        .object => |object| object,
        else => return,
    };

    var result: Result = .{ .serial = query.serial };

    if (recording.get("score")) |score_value| {
        const score: i64 = switch (score_value) {
            .integer => |value| value,
            .float => |value| @intFromFloat(value),
            else => 0,
        };
        if (score < 80) return;
    }

    if (recording.get("title")) |title_value| {
        if (title_value == .string) copyField(&result.title, title_value.string);
    }
    if (result.title[0] == 0) copyField(&result.title, query.titleSlice());

    if (recording.get("artist-credit")) |credit_value| {
        if (credit_value == .array and credit_value.array.items.len > 0) {
            if (credit_value.array.items[0] == .object) {
                const credit = credit_value.array.items[0].object;
                if (credit.get("name")) |name_value| {
                    if (name_value == .string) copyField(&result.artist, name_value.string);
                }
            }
        }
    }
    if (result.artist[0] == 0) copyField(&result.artist, query.artistSlice());

    if (recording.get("releases")) |releases_value| {
        if (releases_value == .array) {
            var chosen_title: []const u8 = "";
            var chosen_date: []const u8 = "";
            var fallback_title: []const u8 = "";
            var fallback_date: []const u8 = "";
            for (releases_value.array.items) |release_value| {
                if (release_value != .object) continue;
                const release = release_value.object;
                const release_title = if (release.get("title")) |title_value|
                    if (title_value == .string) title_value.string else ""
                else
                    "";
                const release_date = if (release.get("date")) |date_value|
                    if (date_value == .string) date_value.string else ""
                else
                    "";
                if (fallback_title.len == 0 and release_title.len > 0) {
                    fallback_title = release_title;
                    fallback_date = release_date;
                }
                if (query.albumSlice().len > 0 and release_title.len > 0 and
                    std.ascii.eqlIgnoreCase(release_title, query.albumSlice()))
                {
                    chosen_title = release_title;
                    chosen_date = release_date;
                    break;
                }
                if (chosen_title.len == 0 and release_title.len > 0 and release_date.len >= 4) {
                    chosen_title = release_title;
                    chosen_date = release_date;
                }
            }
            if (chosen_title.len == 0) {
                chosen_title = fallback_title;
                chosen_date = fallback_date;
            }
            if (chosen_title.len > 0) copyField(&result.album, chosen_title);
            if (chosen_date.len >= 4) copyField(&result.year, chosen_date[0..4]);
        }
    }
    if (result.album[0] == 0) copyField(&result.album, query.albumSlice());

    if (result.title[0] == 0 and result.artist[0] == 0 and result.album[0] == 0)
        return;
    self.callback(result);
}

fn onTimer(_: QTimer) callconv(.c) void {
    const self = active orelse return;
    self.startPending();
}

test "copyField truncates and null terminates" {
    var destination: [8]u8 = std.mem.zeroes([8]u8);
    copyField(&destination, "abcdefghij");
    try std.testing.expectEqualStrings("abcdefg", std.mem.sliceTo(&destination, 0));
}
