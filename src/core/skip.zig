const std = @import("std");

/// Directories that are rarely interesting in filename searches and are often
/// enormous. Keeping this list shared means the live scanner and the index
/// builder agree on what "the filesystem" means.
pub fn shouldSkipDir(name: []const u8, parent: []const u8) bool {
    const skipped = [_][]const u8{
        ".git",
        ".hg",
        ".svn",
        ".zig-cache",
        ".cache",
        ".npm",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        "zig-out",
        "zig-pkg",
        "target",
        "build",
    };
    for (skipped) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }

    // Trash is full of files the user deliberately removed.
    if (std.mem.eql(u8, name, "Trash") and std.mem.endsWith(u8, parent, "/.local/share")) {
        return true;
    }

    if (std.mem.eql(u8, parent, "/")) {
        const system_dirs = [_][]const u8{ "proc", "sys", "dev", "run", "lost+found" };
        for (system_dirs) |item| {
            if (std.mem.eql(u8, name, item)) return true;
        }
    }
    return false;
}

test "skips noisy directories" {
    try std.testing.expect(shouldSkipDir(".git", "/home/user/project"));
    try std.testing.expect(shouldSkipDir("node_modules", "/home/user/code"));
    try std.testing.expect(shouldSkipDir("Trash", "/home/user/.local/share"));
    try std.testing.expect(!shouldSkipDir("Documents", "/home/user"));
    try std.testing.expect(shouldSkipDir("proc", "/"));
    try std.testing.expect(!shouldSkipDir("proc", "/home/user"));
}
