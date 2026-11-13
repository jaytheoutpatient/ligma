//! Minimal Discord Rich Presence client.
//!
//! Discord exposes a local JSON-RPC endpoint over a Unix socket. There is no
//! public Zig SDK and no bot token is involved: the desktop client performs
//! the authentication, and this module only writes `SET_ACTIVITY` frames to
//! the local socket. Every frame starts with two little-endian u32 values
//! (opcode and payload length).
//!
//! Presence is best-effort. Discord may not be running, may restart, or may
//! reject a frame; none of those conditions are allowed to affect playback.

const std = @import("std");
const qt6 = @import("libqt6zig");

const QLocalSocket = qt6.QLocalSocket;
const QTimer = qt6.QTimer;

const qlocalsocket_enums = qt6.qlocalsocket_enums;

/// Public application ID for Ligma's Discord application. It is not a secret;
/// `LIGMA_DISCORD_APP_ID` can override it for development builds.
pub const default_app_id = "1570592024560672878";

const retry_interval_ms = 15_000;
const activity_debounce_ms = 450;
const max_activity_field = 127;

const op_handshake: u32 = 0;
const op_frame: u32 = 1;
const op_close: u32 = 2;
const op_ping: u32 = 3;
const op_pong: u32 = 4;

/// The single live connection. Qt callbacks are C functions without user data.
var active: ?*DiscordRpc = null;

pub const DiscordRpc = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: QLocalSocket,
    retry_timer: QTimer,
    send_timer: QTimer,
    buffer: std.ArrayList(u8) = .empty,
    app_id: []const u8 = default_app_id,
    pid: i32,
    enabled: bool = true,
    ready: bool = false,
    sent_activity: bool = false,
    nonce: u64 = 0,
    activity: ?Activity = null,

    const Activity = struct {
        details: []u8,
        state: []u8,
        playing: bool,
        position_ms: i64,
        duration_ms: i64,
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, parent: anytype) !*DiscordRpc {
        const self = try gpa.create(DiscordRpc);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .socket = QLocalSocket.new2(parent),
            .retry_timer = undefined,
            .send_timer = undefined,
            .pid = @intCast(std.os.linux.getpid()),
        };

        self.enabled = discordEnabled();
        if (std.c.getenv("LIGMA_DISCORD_APP_ID")) |raw| {
            const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
            if (value.len > 0) self.app_id = value;
        }

        self.retry_timer = QTimer.new2(self.socket);
        self.retry_timer.setInterval(retry_interval_ms);
        self.send_timer = QTimer.new2(self.socket);
        self.send_timer.setSingleShot(true);
        self.send_timer.setInterval(activity_debounce_ms);
        self.send_timer.onTimeout(onSendTimeout);

        self.socket.onConnected(onConnected);
        self.socket.onReadyRead(onReadyRead);
        self.socket.onDisconnected(onDisconnected);
        self.socket.onErrorOccurred(onSocketError);
        self.retry_timer.onTimeout(onRetryTimeout);

        active = self;
        return self;
    }

    /// Replace the displayed activity. `state` is typically the artist.
    pub fn setActivity(
        self: *DiscordRpc,
        details_raw: []const u8,
        state_raw: []const u8,
        playing: bool,
        position_ms: i64,
        duration_ms: i64,
    ) void {
        if (!self.enabled) return;

        const details = truncateUtf8(std.mem.trim(u8, details_raw, " \t\r\n"), max_activity_field);
        const state = truncateUtf8(std.mem.trim(u8, state_raw, " \t\r\n"), max_activity_field);
        if (details.len == 0) return;

        if (self.activity) |old| {
            const close_position = @abs(old.position_ms - position_ms) < 1000;
            if (old.playing == playing and
                old.duration_ms == duration_ms and
                close_position and
                std.mem.eql(u8, old.details, details) and
                std.mem.eql(u8, old.state, state))
            {
                return;
            }
        }

        const details_copy = self.gpa.dupe(u8, details) catch return;
        errdefer self.gpa.free(details_copy);
        const state_copy = self.gpa.dupe(u8, state) catch {
            self.gpa.free(details_copy);
            return;
        };

        self.freeActivity();
        self.activity = .{
            .details = details_copy,
            .state = state_copy,
            .playing = playing,
            .position_ms = position_ms,
            .duration_ms = duration_ms,
        };

        if (self.ready) {
            self.scheduleSend();
        } else {
            self.ensureConnection();
        }
    }

    pub fn clearActivity(self: *DiscordRpc) void {
        const had_activity = self.activity != null or self.sent_activity;
        self.send_timer.stop();
        self.freeActivity();
        self.retry_timer.stop();
        if (had_activity and self.ready) {
            self.sendClear();
            self.sent_activity = false;
        }
    }

    pub fn deinit(self: *DiscordRpc) void {
        if (active == self) active = null;
        self.clearActivity();
        if (self.ready) {
            _ = self.socket.flush();
            _ = self.socket.waitForBytesWritten(250);
        }
        self.socket.abort();
        self.socket.delete();
        self.buffer.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freeActivity(self: *DiscordRpc) void {
        if (self.activity) |*activity| {
            self.gpa.free(activity.details);
            self.gpa.free(activity.state);
            self.activity = null;
        }
    }

    fn scheduleSend(self: *DiscordRpc) void {
        if (!self.ready or self.activity == null) return;
        self.send_timer.start(activity_debounce_ms);
    }

    fn ensureConnection(self: *DiscordRpc) void {
        if (!self.enabled or self.ready or self.activity == null) return;
        self.attemptConnect();
        if (!self.ready) self.retry_timer.start(retry_interval_ms);
    }

    fn attemptConnect(self: *DiscordRpc) void {
        if (!self.enabled or self.ready) return;
        if (self.socket.state() != qlocalsocket_enums.LocalSocketState.UnconnectedState) return;

        const path = findSocketPath(self.gpa, self.io) orelse return;
        defer self.gpa.free(path);
        self.socket.connectToServer2(path);
    }

    fn sendHandshake(self: *DiscordRpc) void {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        json.appendSlice(self.gpa, "{\"v\":1,\"client_id\":") catch return;
        appendJsonString(self.gpa, &json, self.app_id) catch return;
        json.append(self.gpa, '}') catch return;
        self.sendFrame(op_handshake, json.items);
    }

    fn sendActivity(self: *DiscordRpc) void {
        const activity = self.activity orelse return;

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);

        json.appendSlice(self.gpa, "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":") catch return;
        appendInt(self.gpa, &json, self.pid) catch return;
        json.appendSlice(self.gpa, ",\"activity\":{\"details\":") catch return;
        appendJsonString(self.gpa, &json, activity.details) catch return;
        if (activity.state.len > 0) {
            json.appendSlice(self.gpa, ",\"state\":") catch return;
            appendJsonString(self.gpa, &json, activity.state) catch return;
        }
        // Show the details line (song plus artist) in the member-list status
        // instead of only the application name. Discord defaults this to 0
        // (Name), which is why the compact status previously read "Ligma".
        json.appendSlice(self.gpa, ",\"type\":2,\"status_display_type\":2") catch return;

        // Discord anchors progress to absolute epoch milliseconds. Recompute
        // the anchor from the current media position on every state change so
        // pausing, resuming, and seeking stay accurate.
        if (activity.playing and activity.duration_ms > 0) {
            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            const position = @max(activity.position_ms, 0);
            const start = now - @min(position, activity.duration_ms);
            const end = start + activity.duration_ms;
            json.appendSlice(self.gpa, ",\"timestamps\":{\"start\":") catch return;
            appendInt(self.gpa, &json, start) catch return;
            json.appendSlice(self.gpa, ",\"end\":") catch return;
            appendInt(self.gpa, &json, end) catch return;
            json.append(self.gpa, '}') catch return;
        }

        json.appendSlice(self.gpa, "}},\"nonce\":") catch return;
        self.nonce +%= 1;
        var nonce_buffer: [48]u8 = undefined;
        const nonce = std.fmt.bufPrint(&nonce_buffer, "ligma-{d}", .{self.nonce}) catch "ligma";
        appendJsonString(self.gpa, &json, nonce) catch return;
        json.append(self.gpa, '}') catch return;

        self.sendFrame(op_frame, json.items);
    }

    fn sendClear(self: *DiscordRpc) void {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.gpa);
        json.appendSlice(self.gpa, "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":") catch return;
        appendInt(self.gpa, &json, self.pid) catch return;
        json.appendSlice(self.gpa, ",\"activity\":null},\"nonce\":") catch return;
        self.nonce +%= 1;
        var nonce_buffer: [48]u8 = undefined;
        const nonce = std.fmt.bufPrint(&nonce_buffer, "ligma-{d}", .{self.nonce}) catch "ligma";
        appendJsonString(self.gpa, &json, nonce) catch return;
        json.append(self.gpa, '}') catch return;
        self.sendFrame(op_frame, json.items);
    }

    fn sendFrame(self: *DiscordRpc, opcode: u32, payload: []const u8) void {
        if (self.socket.state() != qlocalsocket_enums.LocalSocketState.ConnectedState) return;

        const buffer = self.gpa.allocSentinel(u8, payload.len + 8, 0) catch return;
        defer self.gpa.free(buffer);
        std.mem.writeInt(u32, buffer[0..4], opcode, .little);
        std.mem.writeInt(u32, buffer[4..8], @intCast(payload.len), .little);
        @memcpy(buffer[8 .. 8 + payload.len], payload);
        _ = self.socket.write(buffer, @intCast(buffer.len));
        _ = self.socket.flush();
    }

    fn handleFrames(self: *DiscordRpc) void {
        while (self.buffer.items.len >= 8) {
            const opcode = std.mem.readInt(u32, self.buffer.items[0..4], .little);
            const length = std.mem.readInt(u32, self.buffer.items[4..8], .little);
            if (length > 1024 * 1024) {
                self.buffer.clearRetainingCapacity();
                return;
            }
            const frame_len = 8 + @as(usize, length);
            if (self.buffer.items.len < frame_len) return;

            const payload = self.buffer.items[8..frame_len];
            if (opcode == op_frame and !self.ready and
                std.mem.indexOf(u8, payload, "\"evt\":\"READY\"") != null)
            {
                self.ready = true;
                self.retry_timer.stop();
                self.scheduleSend();
            } else if (opcode == op_ping) {
                self.sendFrame(op_pong, payload);
            } else if (opcode == op_close) {
                self.ready = false;
                self.socket.abort();
                if (self.activity != null) self.retry_timer.start(retry_interval_ms);
            }

            const remaining = self.buffer.items.len - frame_len;
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[frame_len..]);
            self.buffer.shrinkRetainingCapacity(remaining);
        }
    }
};

fn discordEnabled() bool {
    const raw = std.c.getenv("LIGMA_DISCORD") orelse return true;
    const value = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
    return !(std.mem.eql(u8, value, "0") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "off"));
}

fn findSocketPath(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    var bases: [4][]const u8 = undefined;
    var count: usize = 0;

    if (std.c.getenv("XDG_RUNTIME_DIR")) |raw| {
        const value = std.mem.span(raw);
        if (value.len > 0) {
            bases[count] = value;
            count += 1;
            // Flatpak Discord keeps its socket inside the per-app runtime dir.
            const flatpak = std.fmt.allocPrint(
                gpa,
                "{s}/app/com.discordapp.Discord",
                .{value},
            ) catch null;
            if (flatpak) |path| {
                const found = findInBase(gpa, io, path);
                gpa.free(path);
                if (found) |socket| return socket;
            }
        }
    }

    if (std.c.getenv("TMPDIR")) |raw| {
        const value = std.mem.span(raw);
        if (value.len > 0) {
            bases[count] = value;
            count += 1;
        }
    }
    bases[count] = "/tmp";
    count += 1;

    for (bases[0..count]) |base| {
        if (findInBase(gpa, io, base)) |path| return path;
    }
    return null;
}

fn findInBase(gpa: std.mem.Allocator, io: std.Io, base: []const u8) ?[]u8 {
    var index: u8 = 0;
    while (index < 10) : (index += 1) {
        const path = std.fmt.allocPrint(gpa, "{s}/discord-ipc-{d}", .{ base, index }) catch return null;
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            gpa.free(path);
            continue;
        };
        return path;
    }
    return null;
}

fn truncateUtf8(text: []const u8, maximum: usize) []const u8 {
    if (text.len <= maximum) return text;
    var end = maximum;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn appendInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try out.appendSlice(gpa, text);
}

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(gpa, '"');
    for (text) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            else => {
                if (byte < 0x20) {
                    var escaped: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try out.appendSlice(gpa, &escaped);
                } else {
                    try out.append(gpa, byte);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

// ---- Qt callbacks --------------------------------------------------------

fn onConnected(socket: QLocalSocket) callconv(.c) void {
    const self = active orelse return;
    if (self.socket.ptr != socket.ptr) return;
    self.buffer.clearRetainingCapacity();
    self.sendHandshake();
}

fn onReadyRead(socket: QLocalSocket) callconv(.c) void {
    const self = active orelse return;
    if (self.socket.ptr != socket.ptr) return;

    const chunk = socket.readAll(self.gpa);
    defer self.gpa.free(chunk);
    self.buffer.appendSlice(self.gpa, chunk) catch return;
    self.handleFrames();
}

fn onDisconnected(socket: QLocalSocket) callconv(.c) void {
    const self = active orelse return;
    if (self.socket.ptr != socket.ptr) return;
    self.ready = false;
    self.sent_activity = false;
    self.send_timer.stop();
    if (self.activity != null) self.retry_timer.start(retry_interval_ms);
}

fn onSocketError(socket: QLocalSocket, _: i32) callconv(.c) void {
    const self = active orelse return;
    if (self.socket.ptr != socket.ptr) return;
    self.ready = false;
    self.sent_activity = false;
    self.send_timer.stop();
    if (self.activity != null) self.retry_timer.start(retry_interval_ms);
}

fn onSendTimeout(_: QTimer) callconv(.c) void {
    const self = active orelse return;
    if (!self.ready or self.activity == null) return;
    self.sendActivity();
    self.sent_activity = true;
}

fn onRetryTimeout(_: QTimer) callconv(.c) void {
    const self = active orelse return;
    if (!self.enabled or self.ready or self.activity == null) {
        self.retry_timer.stop();
        return;
    }
    if (self.socket.state() != qlocalsocket_enums.LocalSocketState.UnconnectedState) {
        // A connected socket that never completed its handshake is replaced
        // rather than reused, so a restarting Discord client cannot wedge us.
        self.socket.abort();
    }
    self.attemptConnect();
    self.retry_timer.start(retry_interval_ms);
}

test "truncateUtf8 keeps codepoints intact" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 8));
    try std.testing.expectEqualStrings("a", truncateUtf8("aé", 2));
    try std.testing.expectEqualStrings("", truncateUtf8("é", 1));
}

test "JSON escaping handles quotes and controls" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendJsonString(gpa, &out, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items);
}
