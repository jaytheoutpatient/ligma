//! Persistent user settings inspired by Luciole's configuration surface.
//!
//! The file is intentionally simple `key = value` TOML-like text under
//! `$XDG_CONFIG_HOME/ligma/settings.toml`. Unknown keys are ignored so old
//! files keep working as Ligma grows.

const std = @import("std");

pub const ViewMode = enum { details, icons, compact, grid };
pub const Density = enum { compact, comfortable };
pub const FilenameTruncation = enum { middle, end };
pub const Activation = enum { double_click, single_click };
pub const TypingMode = enum { typeahead, filter, search };
pub const ThumbnailPolicy = enum { never, local, all };
pub const SortBy = enum { name, size, kind, modified };

pub const Settings = struct {
    // General
    activation: Activation = .double_click,
    typing_mode: TypingMode = .typeahead,
    confirm_delete: bool = true,
    switch_new_tab: bool = false,
    restore_last_window: bool = false,
    terminal_command: []u8 = &.{},

    // Appearance and sidebar
    always_show_tab_bar: bool = true,
    always_show_status_bar: bool = true,
    show_sidebar: bool = true,
    sidebar_width: i32 = 250,
    show_drives: bool = true,
    show_preview: bool = true,
    background_opacity: f64 = 1.0,
    corner_radius_scale: f64 = 1.0,
    compact_menus: bool = true,

    // Browser / views
    view_mode: ViewMode = .details,
    grid_icon_size: i32 = 96,
    density: Density = .compact,
    scroll_sensitivity: f64 = 1.0,
    filename_truncation: FilenameTruncation = .end,
    show_hidden: bool = false,
    show_backups: bool = true,
    show_emblems: bool = true,
    directories_first: bool = true,
    sort_by: SortBy = .name,
    sort_descending: bool = false,
    show_size_column: bool = true,
    show_kind_column: bool = true,
    show_modified_column: bool = true,

    // Preview
    video_hover_preview: bool = true,
    video_hover_seconds: i32 = 4,

    // Thumbnails
    thumbnail_policy: ThumbnailPolicy = .local,
    thumbnail_max_mib: i32 = 64,
    video_thumbnails: bool = true,

    pub fn deinit(self: *Settings, gpa: std.mem.Allocator) void {
        if (self.terminal_command.len > 0) gpa.free(self.terminal_command);
        self.terminal_command = &.{};
    }

    pub fn sortColumn(self: Settings) i32 {
        return switch (self.sort_by) {
            .name => 0,
            .size => 1,
            .kind => 2,
            .modified => 3,
        };
    }
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Settings {
    var settings = Settings{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64 * 1024)) catch
        return settings;
    defer gpa.free(data);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = std.mem.trim(u8, line[1..end], " \t");
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        applyValue(gpa, &settings, section, key, value);
    }
    settings.grid_icon_size = std.math.clamp(settings.grid_icon_size, 32, 256);
    settings.sidebar_width = std.math.clamp(settings.sidebar_width, 160, 620);
    settings.thumbnail_max_mib = std.math.clamp(settings.thumbnail_max_mib, 1, 1024);
    settings.video_hover_seconds = std.math.clamp(settings.video_hover_seconds, 1, 30);
    settings.scroll_sensitivity = std.math.clamp(settings.scroll_sensitivity, 0.5, 2.5);
    settings.background_opacity = std.math.clamp(settings.background_opacity, 0.20, 1.0);
    settings.corner_radius_scale = std.math.clamp(settings.corner_radius_scale, 0.0, 2.0);
    return settings;
}

pub fn save(settings: Settings, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    _ = gpa;
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print(
        "# Ligma settings\n\n[general]\nactivation = \"{s}\"\ntyping_mode = \"{s}\"\n" ++
            "confirm_delete = {s}\nswitch_new_tab = {s}\nrestore_last_window = {s}\n" ++
            "terminal_command = \"{s}\"\n\n",
        .{
            @tagName(settings.activation),
            @tagName(settings.typing_mode),
            boolText(settings.confirm_delete),
            boolText(settings.switch_new_tab),
            boolText(settings.restore_last_window),
            settings.terminal_command,
        },
    );
    try writer.print(
        "[appearance]\nalways_show_tab_bar = {s}\nalways_show_status_bar = {s}\n" ++
            "show_sidebar = {s}\nsidebar_width = {d}\nshow_drives = {s}\nshow_preview = {s}\n" ++
            "background_opacity = {d:.2}\ncorner_radius_scale = {d:.2}\ncompact_menus = {s}\n\n",
        .{
            boolText(settings.always_show_tab_bar),
            boolText(settings.always_show_status_bar),
            boolText(settings.show_sidebar),
            settings.sidebar_width,
            boolText(settings.show_drives),
            boolText(settings.show_preview),
            settings.background_opacity,
            settings.corner_radius_scale,
            boolText(settings.compact_menus),
        },
    );
    try writer.print(
        "[views]\nview_mode = \"{s}\"\ngrid_icon_size = {d}\ndensity = \"{s}\"\n" ++
            "scroll_sensitivity = {d:.2}\n" ++
            "filename_truncation = \"{s}\"\nshow_hidden = {s}\nshow_backups = {s}\n" ++
            "show_emblems = {s}\ndirectories_first = {s}\nsort_by = \"{s}\"\n" ++
            "sort_descending = {s}\nshow_size_column = {s}\nshow_kind_column = {s}\n" ++
            "show_modified_column = {s}\n\n",
        .{
            @tagName(settings.view_mode),
            settings.grid_icon_size,
            @tagName(settings.density),
            settings.scroll_sensitivity,
            @tagName(settings.filename_truncation),
            boolText(settings.show_hidden),
            boolText(settings.show_backups),
            boolText(settings.show_emblems),
            boolText(settings.directories_first),
            @tagName(settings.sort_by),
            boolText(settings.sort_descending),
            boolText(settings.show_size_column),
            boolText(settings.show_kind_column),
            boolText(settings.show_modified_column),
        },
    );
    try writer.print(
        "[preview]\nvideo_hover_preview = {s}\nvideo_hover_seconds = {d}\n\n",
        .{ boolText(settings.video_hover_preview), settings.video_hover_seconds },
    );
    try writer.print(
        "[thumbnails]\nthumbnail_policy = \"{s}\"\nthumbnail_max_mib = {d}\n" ++
            "video_thumbnails = {s}\n",
        .{
            @tagName(settings.thumbnail_policy),
            settings.thumbnail_max_mib,
            boolText(settings.video_thumbnails),
        },
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = writer.buffered(),
        .flags = .{ .truncate = true },
    });
}

fn applyValue(
    gpa: std.mem.Allocator,
    settings: *Settings,
    section: []const u8,
    key: []const u8,
    raw_value: []const u8,
) void {
    const value = unquote(raw_value);
    if (std.mem.eql(u8, section, "general")) {
        if (std.mem.eql(u8, key, "activation")) {
            settings.activation = enumValue(Activation, value) orelse settings.activation;
        } else if (std.mem.eql(u8, key, "typing_mode")) {
            settings.typing_mode = enumValue(TypingMode, value) orelse settings.typing_mode;
        } else if (std.mem.eql(u8, key, "confirm_delete")) {
            settings.confirm_delete = boolValue(value) orelse settings.confirm_delete;
        } else if (std.mem.eql(u8, key, "switch_new_tab")) {
            settings.switch_new_tab = boolValue(value) orelse settings.switch_new_tab;
        } else if (std.mem.eql(u8, key, "restore_last_window")) {
            settings.restore_last_window = boolValue(value) orelse settings.restore_last_window;
        } else if (std.mem.eql(u8, key, "terminal_command")) {
            const previous = settings.terminal_command;
            settings.terminal_command = gpa.dupe(u8, value) catch previous;
            if (settings.terminal_command.ptr != previous.ptr) gpa.free(previous);
        }
    } else if (std.mem.eql(u8, section, "appearance")) {
        if (std.mem.eql(u8, key, "always_show_tab_bar")) {
            settings.always_show_tab_bar = boolValue(value) orelse settings.always_show_tab_bar;
        } else if (std.mem.eql(u8, key, "always_show_status_bar")) {
            settings.always_show_status_bar = boolValue(value) orelse settings.always_show_status_bar;
        } else if (std.mem.eql(u8, key, "show_sidebar")) {
            settings.show_sidebar = boolValue(value) orelse settings.show_sidebar;
        } else if (std.mem.eql(u8, key, "sidebar_width")) {
            settings.sidebar_width = intValue(value) orelse settings.sidebar_width;
        } else if (std.mem.eql(u8, key, "show_drives")) {
            settings.show_drives = boolValue(value) orelse settings.show_drives;
        } else if (std.mem.eql(u8, key, "show_preview")) {
            settings.show_preview = boolValue(value) orelse settings.show_preview;
        } else if (std.mem.eql(u8, key, "background_opacity")) {
            settings.background_opacity = floatValue(value) orelse settings.background_opacity;
        } else if (std.mem.eql(u8, key, "corner_radius_scale")) {
            settings.corner_radius_scale = floatValue(value) orelse settings.corner_radius_scale;
        } else if (std.mem.eql(u8, key, "compact_menus")) {
            settings.compact_menus = boolValue(value) orelse settings.compact_menus;
        }
    } else if (std.mem.eql(u8, section, "views")) {
        if (std.mem.eql(u8, key, "view_mode")) {
            settings.view_mode = enumValue(ViewMode, value) orelse settings.view_mode;
        } else if (std.mem.eql(u8, key, "grid_icon_size")) {
            settings.grid_icon_size = intValue(value) orelse settings.grid_icon_size;
        } else if (std.mem.eql(u8, key, "density")) {
            settings.density = enumValue(Density, value) orelse settings.density;
        } else if (std.mem.eql(u8, key, "scroll_sensitivity")) {
            settings.scroll_sensitivity = floatValue(value) orelse settings.scroll_sensitivity;
        } else if (std.mem.eql(u8, key, "filename_truncation")) {
            settings.filename_truncation = enumValue(FilenameTruncation, value) orelse
                settings.filename_truncation;
        } else if (std.mem.eql(u8, key, "show_hidden")) {
            settings.show_hidden = boolValue(value) orelse settings.show_hidden;
        } else if (std.mem.eql(u8, key, "show_backups")) {
            settings.show_backups = boolValue(value) orelse settings.show_backups;
        } else if (std.mem.eql(u8, key, "show_emblems")) {
            settings.show_emblems = boolValue(value) orelse settings.show_emblems;
        } else if (std.mem.eql(u8, key, "directories_first")) {
            settings.directories_first = boolValue(value) orelse settings.directories_first;
        } else if (std.mem.eql(u8, key, "sort_by")) {
            settings.sort_by = enumValue(SortBy, value) orelse settings.sort_by;
        } else if (std.mem.eql(u8, key, "sort_descending")) {
            settings.sort_descending = boolValue(value) orelse settings.sort_descending;
        } else if (std.mem.eql(u8, key, "show_size_column")) {
            settings.show_size_column = boolValue(value) orelse settings.show_size_column;
        } else if (std.mem.eql(u8, key, "show_kind_column")) {
            settings.show_kind_column = boolValue(value) orelse settings.show_kind_column;
        } else if (std.mem.eql(u8, key, "show_modified_column")) {
            settings.show_modified_column = boolValue(value) orelse settings.show_modified_column;
        }
    } else if (std.mem.eql(u8, section, "preview")) {
        if (std.mem.eql(u8, key, "video_hover_preview")) {
            settings.video_hover_preview = boolValue(value) orelse settings.video_hover_preview;
        } else if (std.mem.eql(u8, key, "video_hover_seconds")) {
            settings.video_hover_seconds = intValue(value) orelse settings.video_hover_seconds;
        }
    } else if (std.mem.eql(u8, section, "thumbnails")) {
        if (std.mem.eql(u8, key, "thumbnail_policy")) {
            settings.thumbnail_policy = enumValue(ThumbnailPolicy, value) orelse
                settings.thumbnail_policy;
        } else if (std.mem.eql(u8, key, "thumbnail_max_mib")) {
            settings.thumbnail_max_mib = intValue(value) orelse settings.thumbnail_max_mib;
        } else if (std.mem.eql(u8, key, "video_thumbnails")) {
            settings.video_thumbnails = boolValue(value) orelse settings.video_thumbnails;
        }
    }
}

fn enumValue(comptime T: type, text: []const u8) ?T {
    const info = @typeInfo(T).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (std.mem.eql(u8, text, name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn boolValue(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) return false;
    return null;
}

fn intValue(text: []const u8) ?i32 {
    return std.fmt.parseInt(i32, text, 10) catch null;
}

fn floatValue(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch null;
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

test "settings parser reads values and ignores unknown keys" {
    const gpa = std.testing.allocator;
    var settings = Settings{};
    defer settings.deinit(gpa);

    applyValue(gpa, &settings, "general", "activation", "\"single_click\"");
    applyValue(gpa, &settings, "general", "unknown", "true");
    applyValue(gpa, &settings, "views", "view_mode", "\"grid\"");
    applyValue(gpa, &settings, "views", "grid_icon_size", "128");
    applyValue(gpa, &settings, "thumbnails", "thumbnail_policy", "\"never\"");

    try std.testing.expectEqual(Activation.single_click, settings.activation);
    try std.testing.expectEqual(ViewMode.grid, settings.view_mode);
    try std.testing.expectEqual(@as(i32, 128), settings.grid_icon_size);
    try std.testing.expectEqual(ThumbnailPolicy.never, settings.thumbnail_policy);
}
