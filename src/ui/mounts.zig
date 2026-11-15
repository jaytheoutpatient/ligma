//! Mounted-volume discovery for the Places sidebar.
//!
//! Qt's QStorageInfo already understands the platform mount table and labels.
//! This module turns its snapshot into owned Zig strings and filters out
//! pseudo-filesystems and snap loop devices.

const std = @import("std");
const qt6 = @import("libqt6zig");

const QStorageInfo = qt6.QStorageInfo;

pub const Volume = struct {
    label: []u8,
    path: []u8,
    device: []u8,
    fs_type: []u8,
    bytes_total: u64,
    bytes_free: u64,

    pub fn deinit(self: *Volume, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
        gpa.free(self.path);
        gpa.free(self.device);
        gpa.free(self.fs_type);
        self.* = undefined;
    }
};

pub fn list(gpa: std.mem.Allocator) !std.ArrayList(Volume) {
    var result: std.ArrayList(Volume) = .empty;
    errdefer {
        for (result.items) |*volume| volume.deinit(gpa);
        result.deinit(gpa);
    }

    const mounted = QStorageInfo.mountedVolumes(gpa);
    defer {
        for (mounted) |volume| volume.delete();
        gpa.free(mounted);
    }

    for (mounted) |storage| {
        if (!storage.isValid() or !storage.isReady()) continue;

        const path = storage.rootPath(gpa);
        defer gpa.free(path);
        if (path.len == 0 or std.mem.eql(u8, path, "/")) continue;

        const device = storage.device(gpa);
        defer gpa.free(device);
        if (isNoiseFs(device, path)) continue;

        const fs_type = storage.fileSystemType(gpa);
        defer gpa.free(fs_type);
        if (isPseudoFs(fs_type)) continue;

        const display = storage.displayName(gpa);
        defer gpa.free(display);
        const base = std.fs.path.basename(path);
        const label_source = if (display.len > 0 and !std.mem.eql(u8, display, path))
            display
        else if (base.len > 0)
            base
        else
            path;

        if (hasPath(result.items, path)) continue;

        const label = try gpa.dupe(u8, label_source);
        errdefer gpa.free(label);
        const path_copy = try gpa.dupe(u8, path);
        errdefer gpa.free(path_copy);
        const device_copy = try gpa.dupe(u8, device);
        errdefer gpa.free(device_copy);
        const fs_copy = try gpa.dupe(u8, fs_type);

        try result.append(gpa, .{
            .label = label,
            .path = path_copy,
            .device = device_copy,
            .fs_type = fs_copy,
            .bytes_total = @intCast(@max(storage.bytesTotal(), 0)),
            .bytes_free = @intCast(@max(storage.bytesAvailable(), 0)),
        });
    }
    std.mem.sortUnstable(Volume, result.items, {}, volumeLessThan);
    return result;
}

fn volumeLessThan(_: void, left: Volume, right: Volume) bool {
    return std.ascii.orderIgnoreCase(left.label, right.label) == .lt;
}

fn isNoiseFs(device: []const u8, path: []const u8) bool {
    // Real block devices are the norm, but mounts under the standard media
    // locations are useful even when they come from a network or FUSE.
    if (std.mem.startsWith(u8, device, "/dev/")) {
        if (std.mem.startsWith(u8, device, "/dev/loop")) return true;
        return false;
    }
    return !(std.mem.startsWith(u8, path, "/media/") or
        std.mem.startsWith(u8, path, "/run/media/") or
        std.mem.startsWith(u8, path, "/mnt/"));
}

fn isPseudoFs(fs_type: []const u8) bool {
    const pseudo = [_][]const u8{
        "tmpfs",
        "devtmpfs",
        "devpts",
        "proc",
        "sysfs",
        "cgroup",
        "cgroup2",
        "overlay",
        "aufs",
        "ramfs",
        "squashfs",
        "debugfs",
        "tracefs",
        "securityfs",
        "pstore",
        "bpf",
        "mqueue",
        "hugetlbfs",
        "configfs",
        "autofs",
        "nsfs",
        "fuse.portal",
        "fuse.gvfsd-fuse",
    };
    for (pseudo) |item| {
        if (std.mem.eql(u8, fs_type, item)) return true;
    }
    return false;
}

fn hasPath(volumes: []const Volume, path: []const u8) bool {
    for (volumes) |volume| {
        if (std.mem.eql(u8, volume.path, path)) return true;
    }
    return false;
}

test "pseudo filesystems are filtered" {
    try std.testing.expect(isPseudoFs("tmpfs"));
    try std.testing.expect(isPseudoFs("squashfs"));
    try std.testing.expect(!isPseudoFs("ext4"));
    try std.testing.expect(!isPseudoFs("xfs"));
}

test "loop devices and unrelated pseudo mounts are ignored" {
    try std.testing.expect(isNoiseFs("/dev/loop0", "/mnt/snap"));
    try std.testing.expect(!isNoiseFs("/dev/nvme0n1p1", "/boot"));
    try std.testing.expect(!isNoiseFs("server:/share", "/mnt/share"));
    try std.testing.expect(isNoiseFs("proc", "/proc"));
}
