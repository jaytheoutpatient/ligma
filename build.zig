const std = @import("std");

const configureQtExeRootModule = @import("libqt6zig").configureQtExeRootModule;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const qt6zig = b.dependency("libqt6zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ligma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("libqt6zig", qt6zig.module("libqt6zig"));
    exe.root_module.linkSystemLibrary("sqlite3", .{});

    // QTermWidget is a C++ Qt widget, so it cannot be reached through the
    // generated Zig bindings. A tiny C ABI shim (src/ui/terminal_widget.cpp)
    // bridges it. Compile the shim with the system g++ and link it against
    // the qtermwidget development package (qtermwidget6.pc).
    const qtermwidget_cflags = switch (b.runFallible(
        &.{ "pkg-config", "--cflags", "qtermwidget6" },
        .{},
    )) {
        .success => |stdout| stdout,
        else => @panic("qtermwidget6 development files not found (qtermwidget6.pc). Install the Qt 6 qtermwidget package before building Ligma."),
    };
    const terminal_shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    terminal_shim.addFileArg(b.path("src/ui/terminal_widget.cpp"));
    terminal_shim.addArg("-o");
    const terminal_object = terminal_shim.addOutputFileArg("terminal_widget.o");
    var cflags = std.mem.tokenizeAny(u8, qtermwidget_cflags, " \t\r\n");
    while (cflags.next()) |flag| terminal_shim.addArg(flag);

    exe.root_module.addObjectFile(terminal_object);
    exe.root_module.linkSystemLibrary("qtermwidget6", .{});
    exe.root_module.linkSystemLibrary("stdc++", .{});
    exe.root_module.linkSystemLibrary("Qt6Network", .{});

    // libqt6zig does not expose a QVariant constructor for QIcon, so the item
    // model uses this tiny helper for DecorationRole.
    const qt_bridge_cflags = switch (b.runFallible(
        &.{ "pkg-config", "--cflags", "Qt6Widgets", "Qt6Gui", "Qt6Core" },
        .{},
    )) {
        .success => |stdout| stdout,
        else => @panic("Qt 6 Core/Gui development files not found."),
    };
    const qt_bridge_shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    qt_bridge_shim.addFileArg(b.path("src/ui/qt_bridge.cpp"));
    qt_bridge_shim.addArg("-o");
    const qt_bridge_object = qt_bridge_shim.addOutputFileArg("qt_bridge.o");
    var qt_bridge_flags = std.mem.tokenizeAny(u8, qt_bridge_cflags, " \t\r\n");
    while (qt_bridge_flags.next()) |flag| qt_bridge_shim.addArg(flag);
    exe.root_module.addObjectFile(qt_bridge_object);

    const palette_cflags = switch (b.runFallible(
        &.{ "pkg-config", "--cflags", "Qt6Widgets", "Qt6Gui", "Qt6Core" },
        .{},
    )) {
        .success => |stdout| stdout,
        else => @panic("Qt 6 Widgets development files not found."),
    };
    const palette_shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    palette_shim.addFileArg(b.path("src/ui/palette.cpp"));
    palette_shim.addArg("-o");
    const palette_object = palette_shim.addOutputFileArg("palette.o");
    var palette_flags = std.mem.tokenizeAny(u8, palette_cflags, " \t\r\n");
    while (palette_flags.next()) |flag| palette_shim.addArg(flag);
    exe.root_module.addObjectFile(palette_object);

    const mpris_cflags = switch (b.runFallible(
        &.{ "pkg-config", "--cflags", "Qt6DBus", "Qt6Core" },
        .{},
    )) {
        .success => |stdout| stdout,
        else => @panic("Qt 6 D-Bus development files not found (Qt6DBus.pc)."),
    };
    const mpris_shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    mpris_shim.addFileArg(b.path("src/ui/mpris.cpp"));
    mpris_shim.addArg("-o");
    const mpris_object = mpris_shim.addOutputFileArg("mpris.o");
    var mpris_flags = std.mem.tokenizeAny(u8, mpris_cflags, " \t\r\n");
    while (mpris_flags.next()) |flag| mpris_shim.addArg(flag);
    exe.root_module.addObjectFile(mpris_object);
    exe.root_module.linkSystemLibrary("Qt6DBus", .{});

    // GStreamer owns the audio pipeline so the music player can use direct
    // ALSA output and optional DSP filters. Like QTermWidget, the engine is a
    // C++ translation unit with a plain C ABI.
    const gstreamer_cflags = switch (b.runFallible(
        &.{ "pkg-config", "--cflags", "gstreamer-1.0" },
        .{},
    )) {
        .success => |stdout| stdout,
        else => @panic("GStreamer development files not found (gstreamer-1.0.pc). Install the GStreamer development package before building Ligma."),
    };
    const music_shim = b.addSystemCommand(&.{ "g++", "-std=c++17", "-O2", "-fPIC", "-c" });
    music_shim.addFileArg(b.path("src/ui/music_engine.cpp"));
    music_shim.addArg("-o");
    const music_object = music_shim.addOutputFileArg("music_engine.o");
    var music_cflags = std.mem.tokenizeAny(u8, gstreamer_cflags, " \t\r\n");
    while (music_cflags.next()) |flag| music_shim.addArg(flag);
    exe.root_module.addObjectFile(music_object);
    exe.root_module.linkSystemLibrary("gstreamer-1.0", .{});
    exe.root_module.linkSystemLibrary("gobject-2.0", .{});
    exe.root_module.linkSystemLibrary("glib-2.0", .{});

    // Only the Qt wrappers this application actually calls need to be linked.
    // Keeping this list tight is the difference between a fast build and a
    // multi-minute one.
    for (qt_libraries) |lib|
        exe.root_module.linkLibrary(qt6zig.artifact(lib));

    try configureQtExeRootModule(b, exe, .{});

    const check_step = b.step("check", "Compile without producing an executable");
    check_step.dependOn(&exe.step);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // Desktop entry and the blue/purple floppy icon. Installing into
    // `zig-out/share` lets a package or `sudo cp -r` place them under /usr.
    const desktop_file = b.addInstallFileWithDir(
        b.path("assets/org.ligma.FileManager.desktop"),
        .{ .custom = "share/applications" },
        "org.ligma.FileManager.desktop",
    );
    b.getInstallStep().dependOn(&desktop_file.step);

    const icon_sizes = [_][]const u8{ "16", "22", "24", "32", "48", "64", "128", "256", "512" };
    inline for (icon_sizes) |size| {
        const source = b.fmt("assets/org.ligma.FileManager-{s}.png", .{size});
        const destination = b.fmt("share/icons/hicolor/{s}x{s}/apps", .{ size, size });
        const icon = b.addInstallFileWithDir(
            b.path(source),
            .{ .custom = destination },
            "org.ligma.FileManager.png",
        );
        b.getInstallStep().dependOn(&icon.step);
    }
    const scalable_icon = b.addInstallFileWithDir(
        b.path("assets/org.ligma.FileManager.svg"),
        .{ .custom = "share/icons/hicolor/scalable/apps" },
        "org.ligma.FileManager.svg",
    );
    b.getInstallStep().dependOn(&scalable_icon.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run Ligma");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

const qt_libraries = [_][]const u8{
    "qabstractbutton",
    "qabstractitemmodel",
    "qabstractitemview",
    "qabstractscrollarea",
    "qabstractslider",
    "qaction",
    "qactiongroup",
    "qapplication",
    "qboxlayout",
    "qcoreapplication",
    "qcursor",
    "qdesktopservices",
    "qdir",
    "qdockwidget",
    "qevent",
    "qfileiconprovider",
    "qfileinfo",
    "qframe",
    "qfilesystemwatcher",
    "qguiapplication",
    "qicon",
    "qimage",
    "qimagereader",
    "qinputdialog",
    "qiodevice",
    "qitemselectionmodel",
    "qkeysequence",
    "qlabel",
    "qlayout",
    "qlocalsocket",
    "qlineedit",
    "qlistview",
    "qlistwidget",
    "qmainwindow",
    "qmenu",
    "qmenubar",
    "qmessagebox",
    "qnetworkaccessmanager",
    "qnetworkreply",
    "qnetworkrequest",
    "qmimedata",
    "qmimedatabase",
    "qmimetype",
    "qobject",
    "qpoint",
    "qpixmap",
    "qprocess",
    "qprogressbar",
    "qpushbutton",
    "qrect",
    "qscrollbar",
    "qsize",
    "qslider",
    "qsplitter",
    "qstackedwidget",
    "qstatusbar",
    "qstorageinfo",
    "qtabwidget",
    "qtimer",
    "qtreeview",
    "qurl",
    "qvariant",
    "qwidget",
};
