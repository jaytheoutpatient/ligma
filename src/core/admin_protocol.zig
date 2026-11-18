//! Framing shared by Ligma's administrator helper and its in-process client.
//!
//! Messages are a 4-byte little-endian length followed by a payload. The
//! payload starts with a command byte (requests) or a status byte (responses).
//! Strings are a 4-byte length followed by raw bytes, which keeps arbitrary
//! Linux filenames intact.

const std = @import("std");

pub const max_message: usize = 64 * 1024 * 1024;
pub const max_string: usize = 1024 * 1024;
pub const max_entries: u32 = 1_000_000;

pub const Command = enum(u8) {
    list = 1,
    delete = 2,
    rename = 3,
    mkdir = 4,
    copy = 5,
    move = 6,
    shutdown = 7,
    ping = 8,
};

pub const status_ok: u8 = 0;
pub const status_error: u8 = 1;

pub fn commandFromByte(value: u8) ?Command {
    return switch (value) {
        1 => .list,
        2 => .delete,
        3 => .rename,
        4 => .mkdir,
        5 => .copy,
        6 => .move,
        7 => .shutdown,
        8 => .ping,
        else => null,
    };
}

pub const flag_dir: u8 = 1;
pub const flag_symlink: u8 = 2;

pub fn appendU32(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    try list.appendSlice(gpa, &buffer);
}

pub fn appendU64(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u64) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value, .little);
    try list.appendSlice(gpa, &buffer);
}

pub fn appendI64(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: i64) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(i64, &buffer, value, .little);
    try list.appendSlice(gpa, &buffer);
}

pub fn appendString(list: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    if (text.len > max_string) return error.StringTooLarge;
    try appendU32(list, gpa, @intCast(text.len));
    try list.appendSlice(gpa, text);
}

pub const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readByte(self: *Cursor) !u8 {
        if (self.pos >= self.data.len) return error.MalformedMessage;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    pub fn readU32(self: *Cursor) !u32 {
        if (self.pos + 4 > self.data.len) return error.MalformedMessage;
        const value = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    pub fn readU64(self: *Cursor) !u64 {
        if (self.pos + 8 > self.data.len) return error.MalformedMessage;
        const value = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    pub fn readI64(self: *Cursor) !i64 {
        if (self.pos + 8 > self.data.len) return error.MalformedMessage;
        const value = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    pub fn readString(self: *Cursor) ![]const u8 {
        const length = try self.readU32();
        if (length > max_string or self.pos + length > self.data.len)
            return error.MalformedMessage;
        const text = self.data[self.pos .. self.pos + length];
        self.pos += length;
        return text;
    }

    pub fn done(self: *const Cursor) bool {
        return self.pos == self.data.len;
    }
};

test "framing round-trips strings and numbers" {
    const gpa = std.testing.allocator;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);

    try message.append(gpa, protocolCommandForTest);
    try appendU32(&message, gpa, 42);
    try appendU64(&message, gpa, 9_000_000_000);
    try appendI64(&message, gpa, -1_700_000_000);
    try appendString(&message, gpa, "a name with spaces and \xff bytes");

    var cursor = Cursor{ .data = message.items };
    try std.testing.expectEqual(protocolCommandForTest, try cursor.readByte());
    try std.testing.expectEqual(@as(u32, 42), try cursor.readU32());
    try std.testing.expectEqual(@as(u64, 9_000_000_000), try cursor.readU64());
    try std.testing.expectEqual(@as(i64, -1_700_000_000), try cursor.readI64());
    try std.testing.expectEqualStrings(
        "a name with spaces and \xff bytes",
        try cursor.readString(),
    );
    try std.testing.expect(cursor.done());
}

test "cursor rejects truncated fields" {
    var cursor = Cursor{ .data = &.{ 1, 2 } };
    try std.testing.expectError(error.MalformedMessage, cursor.readU32());

    var length_cursor = Cursor{ .data = &.{ 8, 0, 0, 0, 'a' } };
    try std.testing.expectError(error.MalformedMessage, length_cursor.readString());
}

test "appendString rejects oversized names" {
    const gpa = std.testing.allocator;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);

    const huge = try gpa.alloc(u8, max_string + 1);
    defer gpa.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.StringTooLarge, appendString(&message, gpa, huge));
}

const protocolCommandForTest: u8 = 0xab;

test "command bytes map to protocol commands" {
    try std.testing.expectEqual(Command.list, commandFromByte(1).?);
    try std.testing.expectEqual(Command.shutdown, commandFromByte(7).?);
    try std.testing.expect(commandFromByte(0) == null);
    try std.testing.expect(commandFromByte(9) == null);
}
