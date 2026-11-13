const std = @import("std");

/// Resolve a user-entered location to an absolute path.
///
/// Supports:
///   - absolute paths
///   - paths relative to `cwd`
///   - `~` and `~/...`
///   - `file://` URIs (no percent-decoding yet)
///
/// Caller owns the returned slice.
pub fn resolve(allocator: std.mem.Allocator, cwd: []const u8, raw: []const u8) ![]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return error.EmptyPath;

    if (std.mem.startsWith(u8, text, "file://")) {
        text = text["file://".len..];
    }
    if (text.len == 0) return error.EmptyPath;

    if (text[0] == '~') {
        const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/";
        if (text.len == 1) return allocator.dupe(u8, home);
        if (text[1] == '/') {
            return std.fs.path.resolveAlloc(allocator, &.{ home, text[2..] });
        }
    }

    if (std.fs.path.isAbsolute(text)) {
        return std.fs.path.resolveAlloc(allocator, &.{text});
    }
    return std.fs.path.resolveAlloc(allocator, &.{ cwd, text });
}

test "resolve absolute path" {
    const result = try resolve(std.testing.allocator, "/tmp", "/home/user");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user", result);
}

test "resolve relative path" {
    const result = try resolve(std.testing.allocator, "/home/user", "Documents");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/Documents", result);
}

test "resolve parent traversal" {
    const result = try resolve(std.testing.allocator, "/home/user/Documents", "../Pictures");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/Pictures", result);
}

test "resolve file uri" {
    const result = try resolve(std.testing.allocator, "/tmp", "file:///var/log");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/var/log", result);
}
