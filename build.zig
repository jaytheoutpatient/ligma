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
    exe.root_module.linkSystemLibrary("Qt6Multimedia", .{});
    exe.root_module.linkSystemLibrary("Qt6Network", .{});

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
    "qabstractslider",
    "qaction",
    "qapplication",
    "qaudiooutput",
    "qboxlayout",
    "qcoreapplication",
    "qdesktopservices",
    "qdir",
    "qdockwidget",
    "qevent",
    "qfileinfo",
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
    "qmediaplayer",
    "qmediametadata",
    "qmenu",
    "qmenubar",
    "qmessagebox",
    "qmimedata",
    "qmimedatabase",
    "qmimetype",
    "qobject",
    "qpoint",
    "qpixmap",
    "qprocess",
    "qpushbutton",
    "qsize",
    "qslider",
    "qsplitter",
    "qstatusbar",
    "qtabwidget",
    "qtimer",
    "qtreeview",
    "qurl",
    "qvariant",
    "qwidget",
};
