//! GStreamer audio engine bridge.
//!
//! `music_engine.cpp` owns the GStreamer pipeline. This module keeps the Zig
//! side small: calls are synchronous, while playback events and tags are
//! polled from a QTimer owned by the player panel.

const std = @import("std");

pub const Eos: i32 = 1;
pub const Failed: i32 = 2;

pub const OutputMode = enum(i32) {
    automatic = 0,
    alsa = 1,
};

pub const State = enum(i32) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

extern fn ligma_music_new(output_mode: i32, alsa_device: ?[*:0]const u8, eq_enabled: i32, rg_enabled: i32) ?*anyopaque;
extern fn ligma_music_free(handle: ?*anyopaque) void;
extern fn ligma_music_load(handle: ?*anyopaque, path: [*:0]const u8) i32;
extern fn ligma_music_play(handle: ?*anyopaque) void;
extern fn ligma_music_pause(handle: ?*anyopaque) void;
extern fn ligma_music_stop(handle: ?*anyopaque) void;
extern fn ligma_music_set_volume(handle: ?*anyopaque, volume: f64) void;
extern fn ligma_music_set_position(handle: ?*anyopaque, milliseconds: i64) void;
extern fn ligma_music_position(handle: ?*anyopaque) i64;
extern fn ligma_music_duration(handle: ?*anyopaque) i64;
extern fn ligma_music_state(handle: ?*anyopaque) i32;
extern fn ligma_music_is_bitperfect(handle: ?*anyopaque) i32;
extern fn ligma_music_poll(handle: ?*anyopaque) i32;
extern fn ligma_music_tag_serial(handle: ?*anyopaque) u32;
extern fn ligma_music_tags(
    handle: ?*anyopaque,
    title: [*]u8,
    title_len: usize,
    artist: [*]u8,
    artist_len: usize,
    album: [*]u8,
    album_len: usize,
) i32;
extern fn ligma_music_error(handle: ?*anyopaque, buffer: [*]u8, length: usize) i32;
extern fn ligma_music_set_eq(handle: ?*anyopaque, enabled: i32, gains: ?[*]const f64, count: i32) i32;
extern fn ligma_music_set_replaygain(handle: ?*anyopaque, enabled: i32) i32;
extern fn ligma_music_set_output(handle: ?*anyopaque, mode: i32, device: ?[*:0]const u8) i32;

pub const Engine = struct {
    handle: *anyopaque,

    pub fn create(
        mode: OutputMode,
        alsa_device: []const u8,
        eq_enabled: bool,
        rg_enabled: bool,
    ) ?Engine {
        var device_buffer: [256]u8 = undefined;
        const device = deviceZ(&device_buffer, alsa_device);
        const handle = ligma_music_new(
            @backingInt(mode),
            device,
            @intFromBool(eq_enabled),
            @intFromBool(rg_enabled),
        ) orelse return null;
        return .{ .handle = handle };
    }

    pub fn destroy(self: *Engine) void {
        ligma_music_free(self.handle);
        self.handle = undefined;
    }

    pub fn load(self: Engine, allocator: std.mem.Allocator, path: []const u8) bool {
        const path_z = allocator.dupeSentinel(u8, path, 0) catch return false;
        defer allocator.free(path_z);
        return ligma_music_load(self.handle, path_z) != 0;
    }

    pub fn play(self: Engine) void {
        ligma_music_play(self.handle);
    }

    pub fn pause(self: Engine) void {
        ligma_music_pause(self.handle);
    }

    pub fn stop(self: Engine) void {
        ligma_music_stop(self.handle);
    }

    pub fn setVolume(self: Engine, volume: f32) void {
        ligma_music_set_volume(self.handle, volume);
    }

    pub fn setPosition(self: Engine, milliseconds: i64) void {
        ligma_music_set_position(self.handle, milliseconds);
    }

    pub fn position(self: Engine) i64 {
        return ligma_music_position(self.handle);
    }

    pub fn duration(self: Engine) i64 {
        return ligma_music_duration(self.handle);
    }

    pub fn state(self: Engine) State {
        return @fromBackingInt(@intCast(ligma_music_state(self.handle)));
    }

    pub fn isBitPerfect(self: Engine) bool {
        return ligma_music_is_bitperfect(self.handle) != 0;
    }

    pub fn poll(self: Engine) i32 {
        return ligma_music_poll(self.handle);
    }

    pub fn tagSerial(self: Engine) u32 {
        return ligma_music_tag_serial(self.handle);
    }

    pub const Tags = struct {
        title: [512]u8 = undefined,
        artist: [512]u8 = undefined,
        album: [512]u8 = undefined,

        pub fn titleSlice(self: *const Tags) []const u8 {
            return std.mem.sliceTo(&self.title, 0);
        }

        pub fn artistSlice(self: *const Tags) []const u8 {
            return std.mem.sliceTo(&self.artist, 0);
        }

        pub fn albumSlice(self: *const Tags) []const u8 {
            return std.mem.sliceTo(&self.album, 0);
        }
    };

    pub fn readTags(self: Engine) ?Tags {
        var tags: Tags = .{};
        if (ligma_music_tags(
            self.handle,
            &tags.title,
            tags.title.len,
            &tags.artist,
            tags.artist.len,
            &tags.album,
            tags.album.len,
        ) == 0) return null;
        return tags;
    }

    pub const ErrorText = struct {
        buffer: [768]u8 = undefined,

        pub fn slice(self: *const ErrorText) []const u8 {
            return std.mem.sliceTo(&self.buffer, 0);
        }
    };

    pub fn readError(self: Engine) ?ErrorText {
        var error_text: ErrorText = .{};
        if (ligma_music_error(self.handle, &error_text.buffer, error_text.buffer.len) == 0)
            return null;
        return error_text;
    }

    pub fn setEq(self: Engine, enabled: bool, gains: []const f64) bool {
        return ligma_music_set_eq(
            self.handle,
            @intFromBool(enabled),
            gains.ptr,
            @intCast(gains.len),
        ) != 0;
    }

    pub fn setReplayGain(self: Engine, enabled: bool) bool {
        return ligma_music_set_replaygain(self.handle, @intFromBool(enabled)) != 0;
    }

    pub fn setOutput(self: Engine, mode: OutputMode, alsa_device: []const u8) bool {
        var device_buffer: [256]u8 = undefined;
        const device = deviceZ(&device_buffer, alsa_device);
        return ligma_music_set_output(self.handle, @backingInt(mode), device) != 0;
    }
};

fn deviceZ(buffer: []u8, device: []const u8) ?[*:0]const u8 {
    if (device.len == 0) return null;
    const length = @min(device.len, buffer.len - 1);
    @memcpy(buffer[0..length], device[0..length]);
    buffer[length] = 0;
    return @ptrCast(buffer.ptr);
}
