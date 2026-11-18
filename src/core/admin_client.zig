//! Client for the pkexec-launched administrator helper.
//!
//! Every call opens a short-lived Unix-socket connection and sends one framed
//! request. Most calls wait for a framed response; shutdown is fire-and-forget
//! so a busy helper cannot freeze the UI. That makes the client safe to use
//! from the UI thread and from the directory-loading worker threads without
//! sharing mutable state.

const std = @import("std");

const protocol = @import("admin_protocol.zig");

pub const RemoteEntry = struct {
    name: []u8,
    is_dir: bool,
    is_symlink: bool,
    size: u64,
    mtime: i64,

    pub fn deinit(self: *RemoteEntry, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.* = undefined;
    }
};

pub const Operation = union(enum) {
    delete: []const []const u8,
    rename: struct {
        source: []const u8,
        new_name: []const u8,
    },
    mkdir: []const u8,
    copy: struct {
        sources: []const []const u8,
        dest_dir: []const u8,
    },
    move: struct {
        sources: []const []const u8,
        dest_dir: []const u8,
    },
};

fn frameRequest(
    gpa: std.mem.Allocator,
    request: *std.ArrayList(u8),
) ![]u8 {
    if (request.items.len > protocol.max_message) return error.MessageTooLarge;
    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(gpa);
    try protocol.appendU32(&frame, gpa, @intCast(request.items.len));
    try frame.appendSlice(gpa, request.items);
    return frame.toOwnedSlice(gpa);
}

fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    request: []const u8,
) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var length_buffer: [4]u8 = undefined;
    try reader.interface.readSliceAll(&length_buffer);
    const response_length = std.mem.readInt(u32, &length_buffer, .little);
    if (response_length == 0 or response_length > protocol.max_message)
        return error.MalformedMessage;

    const response = try gpa.alloc(u8, response_length);
    errdefer gpa.free(response);
    try reader.interface.readSliceAll(response);
    return response;
}

pub fn ping(io: std.Io, socket_path: []const u8) bool {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(std.heap.page_allocator);
    request.append(std.heap.page_allocator, @backingInt(protocol.Command.ping)) catch return false;
    const frame = frameRequest(std.heap.page_allocator, &request) catch return false;
    defer std.heap.page_allocator.free(frame);
    const response = exchange(std.heap.page_allocator, io, socket_path, frame) catch return false;
    defer std.heap.page_allocator.free(response);
    return response.len > 0 and response[0] == protocol.status_ok;
}

/// Ask the helper to stop without waiting for its reply. The helper may be
/// finishing a slow directory listing; the UI should not freeze while it gets
/// around to accepting the shutdown connection.
pub fn shutdown(io: std.Io, socket_path: []const u8) void {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(std.heap.page_allocator);
    request.append(
        std.heap.page_allocator,
        @backingInt(protocol.Command.shutdown),
    ) catch return;
    const frame = frameRequest(std.heap.page_allocator, &request) catch return;
    defer std.heap.page_allocator.free(frame);

    const address = std.Io.net.UnixAddress.init(socket_path) catch return;
    var stream = address.connect(io) catch return;
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(frame) catch return;
    writer.interface.flush() catch {};
}

pub fn list(
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    path: []const u8,
    error_out: *?[]u8,
) !std.ArrayList(RemoteEntry) {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(gpa);
    try request.append(gpa, @backingInt(protocol.Command.list));
    try protocol.appendString(&request, gpa, path);
    const frame = try frameRequest(gpa, &request);
    defer gpa.free(frame);

    const response = try exchange(gpa, io, socket_path, frame);
    defer gpa.free(response);
    if (response.len == 0) return error.MalformedMessage;
    if (response[0] != protocol.status_ok) {
        error_out.* = if (response.len > 1)
            gpa.dupe(u8, response[1..]) catch null
        else
            null;
        return error.RemoteError;
    }

    var cursor = protocol.Cursor{ .data = response[1..] };
    const count = try cursor.readU32();
    if (count > protocol.max_entries) return error.MalformedMessage;

    var entries: std.ArrayList(RemoteEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(gpa);
        entries.deinit(gpa);
    }
    try entries.ensureTotalCapacity(gpa, count);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const name = try cursor.readString();
        const flags = try cursor.readByte();
        const size = try cursor.readU64();
        const mtime = try cursor.readI64();
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try entries.append(gpa, .{
            .name = copy,
            .is_dir = (flags & protocol.flag_dir) != 0,
            .is_symlink = (flags & protocol.flag_symlink) != 0,
            .size = size,
            .mtime = mtime,
        });
    }
    return entries;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    operation: Operation,
    error_out: *?[]u8,
) !void {
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(gpa);

    switch (operation) {
        .delete => |paths| {
            try request.append(gpa, @backingInt(protocol.Command.delete));
            try protocol.appendU32(&request, gpa, @intCast(paths.len));
            for (paths) |path| try protocol.appendString(&request, gpa, path);
        },
        .rename => |rename| {
            try request.append(gpa, @backingInt(protocol.Command.rename));
            try protocol.appendString(&request, gpa, rename.source);
            try protocol.appendString(&request, gpa, rename.new_name);
        },
        .mkdir => |path| {
            try request.append(gpa, @backingInt(protocol.Command.mkdir));
            try protocol.appendString(&request, gpa, path);
        },
        .copy => |copy| {
            try request.append(gpa, @backingInt(protocol.Command.copy));
            try protocol.appendString(&request, gpa, copy.dest_dir);
            try protocol.appendU32(&request, gpa, @intCast(copy.sources.len));
            for (copy.sources) |source| try protocol.appendString(&request, gpa, source);
        },
        .move => |move| {
            try request.append(gpa, @backingInt(protocol.Command.move));
            try protocol.appendString(&request, gpa, move.dest_dir);
            try protocol.appendU32(&request, gpa, @intCast(move.sources.len));
            for (move.sources) |source| try protocol.appendString(&request, gpa, source);
        },
    }

    const frame = try frameRequest(gpa, &request);
    defer gpa.free(frame);
    const response = try exchange(gpa, io, socket_path, frame);
    defer gpa.free(response);
    if (response.len == 0) return error.MalformedMessage;
    if (response[0] != protocol.status_ok) {
        error_out.* = if (response.len > 1)
            gpa.dupe(u8, response[1..]) catch null
        else
            null;
        return error.RemoteError;
    }
}
