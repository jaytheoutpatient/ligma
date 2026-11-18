//! Headless administrator helper.
//!
//! The normal Ligma process starts this mode through pkexec:
//!
//!     pkexec env LIGMA_ADMIN_HELPER=1 ... /path/to/ligma
//!
//! It listens on a user-owned Unix socket and executes narrowly framed
//! directory-listing and file-operation requests. The UI never becomes root;
//! the helper is the only privileged process.

const std = @import("std");

const file_ops = @import("file_ops.zig");
const protocol = @import("admin_protocol.zig");

const max_request_paths: u32 = 100_000;

/// Linux `struct ucred`, as returned by `SO_PEERCRED`.
const PeerCredentials = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const socket_raw = std.c.getenv("LIGMA_ADMIN_SOCKET") orelse return error.MissingSocket;
    const socket_path = std.mem.span(socket_raw);
    if (socket_path.len == 0 or socket_path[0] != '/') return error.BadSocket;
    const uid = parseEnvInt("LIGMA_ADMIN_UID", u32) orelse return error.BadUid;
    const gid = parseEnvInt("LIGMA_ADMIN_GID", u32) orelse return error.BadGid;
    const parent_pid = parseEnvInt("LIGMA_ADMIN_PID", i32) orelse return error.BadPid;

    // Remove a stale socket from a previous aborted helper, then bind.
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer {
        server.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    }

    if (std.c.chmod(socket_raw, 0o600) != 0) return error.SocketPermissions;
    if (std.c.geteuid() == 0) {
        if (std.os.linux.chown(socket_raw, uid, gid) != 0)
            return error.SocketOwnership;
    }

    const watchdog = std.Thread.spawn(.{}, watchParent, .{ io, parent_pid, socket_path }) catch null;
    if (watchdog) |thread| thread.detach();

    var stop = false;
    while (!stop) {
        var stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            else => continue,
        };
        // The socket is already mode 0600 and user-owned. Checking peer
        // credentials as well keeps every other process running as that user
        // from borrowing the helper's privileges while it is active.
        if (peerIsAllowed(stream, uid, parent_pid)) {
            handleConnection(gpa, io, stream, &stop) catch {};
        }
        stream.close(io);
    }
}

fn peerIsAllowed(stream: std.Io.net.Stream, uid: u32, pid: i32) bool {
    var credentials: PeerCredentials = undefined;
    var length: std.os.linux.socklen_t = @sizeOf(PeerCredentials);
    const rc = std.os.linux.getsockopt(
        stream.socket.handle,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.PEERCRED,
        @ptrCast(&credentials),
        &length,
    );
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    if (length != @sizeOf(PeerCredentials)) return false;
    return credentials.uid == uid and credentials.pid == pid;
}

fn parseEnvInt(comptime key: [*:0]const u8, comptime T: type) ?T {
    const raw = std.c.getenv(key) orelse return null;
    const text = std.mem.span(raw);
    return std.fmt.parseInt(T, text, 10) catch null;
}

fn watchParent(io: std.Io, pid: i32, socket_path: []const u8) void {
    var buffer: [64]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&buffer, "/proc/{d}", .{pid}) catch return;
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        _ = std.Io.Dir.cwd().statFile(io, proc_path, .{}) catch {
            // The UI disappeared without asking for a shutdown. Remove the
            // socket before exiting so no stale path is left behind.
            std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
            std.process.exit(0);
        };
    }
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    stop: *bool,
) !void {
    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var length_buffer: [4]u8 = undefined;
    reader.interface.readSliceAll(&length_buffer) catch return error.MalformedMessage;
    const length = std.mem.readInt(u32, &length_buffer, .little);
    if (length == 0 or length > protocol.max_message) return error.MalformedMessage;
    const request = try gpa.alloc(u8, length);
    defer gpa.free(request);
    try reader.interface.readSliceAll(request);

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(gpa);
    processRequest(gpa, io, request, &response, stop) catch |err| {
        response.clearRetainingCapacity();
        response.append(gpa, protocol.status_error) catch {};
        response.appendSlice(gpa, file_ops.describeError(err)) catch {};
    };

    if (response.items.len > protocol.max_message) return error.MessageTooLarge;
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var response_length: [4]u8 = undefined;
    std.mem.writeInt(u32, &response_length, @intCast(response.items.len), .little);
    // A client that only sent a shutdown request may close before reading the
    // reply. That must not undo the shutdown flag already stored in `stop`.
    writer.interface.writeAll(&response_length) catch return;
    writer.interface.writeAll(response.items) catch return;
    writer.interface.flush() catch {};
}

fn processRequest(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: []const u8,
    response: *std.ArrayList(u8),
    stop: *bool,
) !void {
    var cursor = protocol.Cursor{ .data = request };
    const command = protocol.commandFromByte(try cursor.readByte()) orelse
        return error.UnknownCommand;

    switch (command) {
        .ping => try response.append(gpa, protocol.status_ok),
        .shutdown => {
            try response.append(gpa, protocol.status_ok);
            stop.* = true;
        },
        .list => {
            const path = try cursor.readString();
            if (!cursor.done()) return error.MalformedMessage;
            try response.append(gpa, protocol.status_ok);
            var count: u32 = 0;
            try protocol.appendU32(response, gpa, 0);
            try listDirectory(gpa, io, path, response, &count);
            std.mem.writeInt(u32, response.items[1..5], count, .little);
        },
        .delete => {
            const count = try cursor.readU32();
            if (count > max_request_paths) return error.TooManyPaths;
            const paths = try gpa.alloc([]const u8, count);
            defer gpa.free(paths);
            for (paths) |*path| path.* = try cursor.readString();
            if (!cursor.done()) return error.MalformedMessage;
            const job = try file_ops.Job.createDelete(gpa, io, paths);
            try completeJob(gpa, io, job, response);
        },
        .rename => {
            const source = try cursor.readString();
            const new_name = try cursor.readString();
            if (!cursor.done()) return error.MalformedMessage;
            if (!file_ops.isValidName(new_name)) return error.InvalidName;
            const job = try file_ops.Job.createRename(gpa, io, source, new_name);
            try completeJob(gpa, io, job, response);
        },
        .mkdir => {
            const path = try cursor.readString();
            if (!cursor.done()) return error.MalformedMessage;
            try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
            try response.append(gpa, protocol.status_ok);
        },
        .copy, .move => {
            const dest_dir = try cursor.readString();
            const count = try cursor.readU32();
            if (count > max_request_paths) return error.TooManyPaths;
            const paths = try gpa.alloc([]const u8, count);
            defer gpa.free(paths);
            for (paths) |*path| path.* = try cursor.readString();
            if (!cursor.done()) return error.MalformedMessage;
            const job = if (command == .copy)
                try file_ops.Job.createCopy(gpa, io, paths, dest_dir)
            else
                try file_ops.Job.createMove(gpa, io, paths, dest_dir);
            try completeJob(gpa, io, job, response);
        },
    }
}

fn listDirectory(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    response: *std.ArrayList(u8),
    count: *u32,
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = try iterator.next(io);
        const item = maybe_entry orelse break;
        if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, ".."))
            continue;
        if (count.* >= protocol.max_entries) return error.TooManyEntries;

        var size: u64 = 0;
        var mtime: i64 = 0;
        var is_dir = item.kind == .directory;
        if (dir.statFile(io, item.name, .{ .follow_symlinks = true })) |stat| {
            size = stat.size;
            mtime = stat.mtime.toSeconds();
            is_dir = stat.kind == .directory;
        } else |_| {}

        var flags: u8 = 0;
        if (is_dir) flags |= protocol.flag_dir;
        if (item.kind == .sym_link) flags |= protocol.flag_symlink;

        try protocol.appendString(response, gpa, item.name);
        try response.append(gpa, flags);
        try protocol.appendU64(response, gpa, size);
        try protocol.appendI64(response, gpa, mtime);
        count.* += 1;
    }
}

/// Run a file job to completion and append the terminal status to `response`.
/// The job's own error message is copied before the job is destroyed so the UI
/// can show why an operation failed.
fn completeJob(
    gpa: std.mem.Allocator,
    io: std.Io,
    job: *file_ops.Job,
    response: *std.ArrayList(u8),
) !void {
    try job.start();
    defer {
        job.requestCancel();
        job.join();
        job.deinit();
    }

    while (true) {
        const progress = job.progress();
        switch (progress.state) {
            .pending, .running => {},
            .done => {
                // Delete and copy-style jobs record per-item failures and
                // still finish. Report those as an error so the UI does not
                // claim success when nothing was changed.
                if (progress.failures > 0) {
                    try response.append(gpa, protocol.status_error);
                    if (progress.error_message.len > 0) {
                        try response.appendSlice(gpa, progress.error_message);
                    } else {
                        try response.appendSlice(gpa, "operation failed");
                    }
                } else {
                    try response.append(gpa, protocol.status_ok);
                }
                return;
            },
            .failed => {
                try response.append(gpa, protocol.status_error);
                const message = job.errorMessage();
                if (message.len > 0) {
                    try response.appendSlice(gpa, message);
                } else {
                    try response.appendSlice(gpa, "operation failed");
                }
                return;
            },
            .cancelled => {
                try response.append(gpa, protocol.status_error);
                try response.appendSlice(gpa, "operation cancelled");
                return;
            },
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
}
