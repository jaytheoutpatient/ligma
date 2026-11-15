//! Accent colors and shared stylesheet fragments.
//!
//! Appearance selection lives in app.zig. This module only owns the current
//! accent pair and renders the gradients used by the sidebar, file views,
//! player playlist, and drive progress bars.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub var accent_start: Rgb = .{ .r = 59, .g = 130, .b = 246 };
pub var accent_end: Rgb = .{ .r = 99, .g = 102, .b = 241 };

pub fn parseHexColor(text: []const u8) ?Rgb {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len != 7 or value[0] != '#') return null;
    const r = hexByte(value[1..3]) orelse return null;
    const g = hexByte(value[3..5]) orelse return null;
    const b = hexByte(value[5..7]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

pub fn setAccentFromHex(start: []const u8, end: []const u8) void {
    if (parseHexColor(start)) |color| accent_start = color;
    if (parseHexColor(end)) |color| accent_end = color;
}

pub fn setDefaultAccent() void {
    accent_start = .{ .r = 59, .g = 130, .b = 246 };
    accent_end = .{ .r = 99, .g = 102, .b = 241 };
}

pub fn listStyle(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "QListWidget {{ background: transparent; border: none; outline: none; padding: 2px; }}" ++
            "QListWidget::item {{ border: none; border-radius: 6px; padding: 4px 6px; margin: 1px 0; }}" ++
            "QListWidget::item:hover {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.34), stop:1 rgba({d}, {d}, {d}, 0.0)); }}" ++
            "QListWidget::item:selected {{ color: white; background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.88), stop:0.6 rgba({d}, {d}, {d}, 0.50), " ++
            "stop:1 rgba({d}, {d}, {d}, 0.0)); }}" ++
            "QListWidget QScrollBar:vertical {{ background: transparent; width: 8px; margin: 0; }}" ++
            "QListWidget QScrollBar::handle:vertical {{ background: rgba(148, 163, 184, 0.5); " ++
            "border-radius: 4px; min-height: 18px; }}" ++
            "QListWidget QScrollBar::add-line:vertical, QListWidget QScrollBar::sub-line:vertical " ++
            "{{ height: 0; background: none; }}" ++
            "QListWidget QScrollBar::add-page:vertical, QListWidget QScrollBar::sub-page:vertical " ++
            "{{ background: transparent; }}",
        .{
            accent_start.r, accent_start.g, accent_start.b,
            accent_end.r,   accent_end.g,   accent_end.b,
            accent_start.r, accent_start.g, accent_start.b,
            accent_end.r,   accent_end.g,   accent_end.b,
            accent_end.r,   accent_end.g,   accent_end.b,
        },
    ) catch "QListWidget { background: transparent; border: none; }";
}

pub fn viewStyle(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "QTreeView, QListView {{ outline: 0; }}" ++
            "QTreeView::item:selected {{ color: white; background: transparent; }}" ++
            "QListView::item:hover {{ background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.30), stop:1 rgba({d}, {d}, {d}, 0.0)); }}" ++
            "QListView::item:selected {{ color: white; " ++
            "background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 0.85), stop:0.6 rgba({d}, {d}, {d}, 0.45), " ++
            "stop:1 rgba({d}, {d}, {d}, 0.0)); }}",
        .{
            accent_start.r, accent_start.g, accent_start.b,
            accent_end.r,   accent_end.g,   accent_end.b,
            accent_start.r, accent_start.g, accent_start.b,
            accent_end.r,   accent_end.g,   accent_end.b,
            accent_end.r,   accent_end.g,   accent_end.b,
        },
    ) catch "QTreeView, QListView { outline: 0; }";
}

pub fn progressStyle(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "QProgressBar {{ border: 0; border-radius: 3px; background: rgba(128, 128, 128, 0.22); }}" ++
            "QProgressBar::chunk {{ border-radius: 3px; background: qlineargradient(x1:0, y1:0, x2:1, y2:0, " ++
            "stop:0 rgba({d}, {d}, {d}, 1.0), stop:0.58 rgba({d}, {d}, {d}, 0.72), " ++
            "stop:1 rgba({d}, {d}, {d}, 0.0)); }}",
        .{
            accent_start.r, accent_start.g, accent_start.b,
            accent_end.r,   accent_end.g,   accent_end.b,
            accent_end.r,   accent_end.g,   accent_end.b,
        },
    ) catch "QProgressBar { border: 0; }";
}

fn hexByte(text: []const u8) ?u8 {
    if (text.len != 2) return null;
    const high = hexDigit(text[0]) orelse return null;
    const low = hexDigit(text[1]) orelse return null;
    return (high << 4) | low;
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

test "hex colors parse" {
    const color = parseHexColor("#00ded3") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), color.r);
    try std.testing.expectEqual(@as(u8, 222), color.g);
    try std.testing.expectEqual(@as(u8, 211), color.b);
    try std.testing.expect(parseHexColor("#xyz") == null);
}
