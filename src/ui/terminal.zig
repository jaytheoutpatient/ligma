//! Right-side terminal panel.
//!
//! The actual terminal emulation comes from QTermWidget (the widget used by
//! QTerminal), which is a C++ class. `terminal_widget.cpp` wraps it in a tiny
//! C ABI; this module declares that ABI and owns the Zig-side convenience
//! functions.

const std = @import("std");
const qt6 = @import("libqt6zig");

const QWidget = qt6.QWidget;

/// Called when F12 is pressed while the terminal widget itself has focus.
pub const ToggleCallback = *const fn (user: ?*anyopaque) callconv(.c) void;

extern fn ligma_terminal_new(
    parent: ?*anyopaque,
    user: ?*anyopaque,
    toggle: ToggleCallback,
) ?*anyopaque;
extern fn ligma_terminal_start(handle: ?*anyopaque, shell: [*:0]const u8, working_directory: [*:0]const u8) void;
extern fn ligma_terminal_set_focus(handle: ?*anyopaque) void;
extern fn ligma_terminal_change_dir(handle: ?*anyopaque, working_directory: [*:0]const u8) void;
extern fn ligma_terminal_shutdown(handle: ?*anyopaque) void;

/// Create the terminal widget under `parent`. The shell is not started until
/// `start` is called.
pub fn create(parent: anytype, on_toggle: ToggleCallback) QWidget {
    const ptr = ligma_terminal_new(parent.ptr, null, on_toggle) orelse return .{ .ptr = null };
    return .{ .ptr = @ptrCast(ptr) };
}

/// Start the user's shell in `working_directory`. Returns false if the
/// arguments could not be prepared.
pub fn start(widget: QWidget, gpa: std.mem.Allocator, shell: []const u8, working_directory: []const u8) bool {
    const shell_z = gpa.dupeSentinel(u8, shell, 0) catch return false;
    defer gpa.free(shell_z);
    const cwd_z = gpa.dupeSentinel(u8, working_directory, 0) catch return false;
    defer gpa.free(cwd_z);
    ligma_terminal_start(widget.ptr, shell_z, cwd_z);
    return true;
}

pub fn setFocus(widget: QWidget) void {
    ligma_terminal_set_focus(widget.ptr);
}

/// Ask a running shell to change directory. Does nothing when the shell is
/// busy with a foreground job.
pub fn changeDirectory(widget: QWidget, gpa: std.mem.Allocator, working_directory: []const u8) bool {
    const cwd_z = gpa.dupeSentinel(u8, working_directory, 0) catch return false;
    defer gpa.free(cwd_z);
    ligma_terminal_change_dir(widget.ptr, cwd_z);
    return true;
}

/// Destroy the terminal and close its PTY. Safe to call once during shutdown.
pub fn shutdown(widget: QWidget) void {
    if (widget.ptr) |ptr| ligma_terminal_shutdown(ptr);
}
