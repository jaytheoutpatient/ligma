//! Mounted-volume discovery for the Places sidebar.
//!
//! Qt's QStorageInfo already understands the platform mount table and labels.
//! This module turns its snapshot into owned Zig strings and filters out
//! pseudo-filesystems and snap loop devices.

const std = @import("std");
const qt6 = @import("libqt6zig");
const text_sort = @import("../core/text_sort.zig");

const QProcess = qt6.QProcess;
const QStorageInfo = qt6.QStorageInfo;
const qiodevicebase_enums = qt6.qiodevicebase_enums;

pub const Volume = struct {
    label: []u8,
    /// Mount point for mounted volumes; empty for an unmounted device.
    path: []u8,
    device: []u8,
    fs_type: []u8,
    bytes_total: u64,
    bytes_free: u64,
    mounted: bool,
    removable: bool,
    read_only: bool,

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
            .mounted = true,
            .removable = false,
            .read_only = storage.isReadOnly(),
        });
    }

    listUnmountedUsb(gpa, &result) catch {};
    std.mem.sortUnstable(Volume, result.items, {}, volumeLessThan);
    return result;
}

fn listUnmountedUsb(gpa: std.mem.Allocator, result: *std.ArrayList(Volume)) !void {
    const process = QProcess.new();
    defer process.delete();
    process.start3(
        gpa,
        "lsblk",
        &.{ "-J", "-b", "-o", "NAME,PATH,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS,TRAN,RM,MODEL" },
        qiodevicebase_enums.OpenModeFlag.ReadOnly,
    );
    if (!process.waitForFinished()) return;
    if (process.exitCode() != 0) return;

    const output = process.readAllStandardOutput(gpa);
    defer gpa.free(output);
    if (output.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, output, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const devices_value = root.get("blockdevices") orelse return;
    const devices = switch (devices_value) {
        .array => |array| array,
        else => return,
    };

    for (devices.items) |device_value| {
        if (device_value != .object) continue;
        const device = device_value.object;
        if (!isUsbDevice(device)) continue;

        const model = jsonString(device.get("model")) orelse "";
        const children_value = device.get("children");
        if (children_value != null and children_value.? == .array and
            children_value.?.array.items.len > 0)
        {
            const children = children_value.?.array.items;
            for (children) |child_value| {
                if (child_value != .object) continue;
                const child = child_value.object;
                if (jsonString(child.get("path"))) |path| {
                    if (!isUnmounted(child)) {
                        const raw_label = jsonString(child.get("label")) orelse "";
                        markMountedRemovable(gpa, result.items, path, raw_label, model, children.len);
                    }
                }
                try appendUnmounted(gpa, result, child, model, children.len);
            }
        } else {
            if (jsonString(device.get("path"))) |path| {
                if (!isUnmounted(device)) {
                    const raw_label = jsonString(device.get("label")) orelse "";
                    markMountedRemovable(gpa, result.items, path, raw_label, model, 1);
                }
            }
            try appendUnmounted(gpa, result, device, model, 1);
        }
    }
}

fn isUsbDevice(device: std.json.ObjectMap) bool {
    if (jsonBool(device.get("rm"))) return true;
    if (jsonString(device.get("tran"))) |transport| {
        return std.mem.eql(u8, transport, "usb");
    }
    return false;
}

fn appendUnmounted(
    gpa: std.mem.Allocator,
    result: *std.ArrayList(Volume),
    device: std.json.ObjectMap,
    model: []const u8,
    child_count: usize,
) !void {
    const fs_type = jsonString(device.get("fstype")) orelse return;
    if (std.mem.eql(u8, fs_type, "swap")) return;
    const device_path = jsonString(device.get("path")) orelse return;
    if (hasDevice(result.items, device_path)) return;
    if (!isUnmounted(device)) return;

    const size = jsonU64(device.get("size")) orelse 0;
    const raw_label = jsonString(device.get("label")) orelse "";
    const name = jsonString(device.get("name")) orelse std.fs.path.basename(device_path);

    const label = if (raw_label.len > 0)
        try gpa.dupe(u8, raw_label)
    else if (model.len > 0 and child_count == 1)
        try gpa.dupe(u8, model)
    else if (model.len > 0)
        try std.fmt.allocPrint(gpa, "{s} ({s})", .{ model, name })
    else if (name.len > 0)
        try gpa.dupe(u8, name)
    else
        try gpa.dupe(u8, device_path);
    errdefer gpa.free(label);

    const path_copy = try gpa.dupe(u8, "");
    errdefer gpa.free(path_copy);
    const device_copy = try gpa.dupe(u8, device_path);
    errdefer gpa.free(device_copy);
    const fs_copy = try gpa.dupe(u8, fs_type);

    try result.append(gpa, .{
        .label = label,
        .path = path_copy,
        .device = device_copy,
        .fs_type = fs_copy,
        .bytes_total = size,
        .bytes_free = 0,
        .mounted = false,
        .removable = true,
        .read_only = false,
    });
}

fn markMountedRemovable(
    gpa: std.mem.Allocator,
    volumes: []Volume,
    device: []const u8,
    raw_label: []const u8,
    model: []const u8,
    child_count: usize,
) void {
    // A filesystem label is best; for a single-partition removable drive use
    // the drive model when the filesystem has no label. This avoids showing a
    // UUID where a human-readable name is available.
    const preferred = if (raw_label.len > 0)
        raw_label
    else if (model.len > 0 and child_count == 1)
        model
    else
        "";

    for (volumes) |*volume| {
        if (!volume.mounted or !std.mem.eql(u8, volume.device, device)) continue;
        volume.removable = true;
        if (preferred.len == 0 or std.mem.eql(u8, volume.label, preferred)) continue;
        const label = gpa.dupe(u8, preferred) catch continue;
        gpa.free(volume.label);
        volume.label = label;
    }
}

fn isUnmounted(device: std.json.ObjectMap) bool {
    const value = device.get("mountpoints") orelse return true;
    if (value != .array) return true;
    for (value.array.items) |item| {
        if (item == .string and item.string.len > 0) return false;
    }
    return true;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    if (item != .string or item.string.len == 0) return null;
    return item.string;
}

fn jsonBool(value: ?std.json.Value) bool {
    const item = value orelse return false;
    return item == .bool and item.bool;
}

fn jsonU64(value: ?std.json.Value) ?u64 {
    const item = value orelse return null;
    return switch (item) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn hasDevice(volumes: []const Volume, device: []const u8) bool {
    for (volumes) |volume| {
        if (std.mem.eql(u8, volume.device, device)) return true;
    }
    return false;
}

fn volumeLessThan(_: void, left: Volume, right: Volume) bool {
    // Mounted drives come first, then both groups sort naturally by label.
    if (left.mounted != right.mounted) return left.mounted;
    return text_sort.lessThanIgnoreCase(left.label, right.label);
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

test "mounted drives sort first and labels sort naturally" {
    const base = Volume{
        .label = @constCast(""),
        .path = @constCast(""),
        .device = @constCast(""),
        .fs_type = @constCast(""),
        .bytes_total = 0,
        .bytes_free = 0,
        .mounted = false,
        .removable = false,
        .read_only = false,
    };
    var usb = base;
    usb.label = @constCast("Game Drive Xbox");
    var internal = base;
    internal.label = @constCast("Balls");
    internal.mounted = true;
    try std.testing.expect(volumeLessThan({}, internal, usb));

    var track2 = base;
    track2.label = @constCast("Track 2");
    track2.mounted = true;
    var track10 = base;
    track10.label = @constCast("Track 10");
    track10.mounted = true;
    try std.testing.expect(volumeLessThan({}, track2, track10));
}
