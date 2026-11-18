const std = @import("std");
const qt6 = @import("libqt6zig");

const app = @import("app.zig");
const QApplication = qt6.QApplication;

pub fn main(init: std.process.Init) !void {
    // Administrator helper mode is headless and deliberately avoids creating
    // a QApplication or connecting to the display.
    if (std.c.getenv("LIGMA_ADMIN_HELPER") != null) {
        try @import("core/admin_helper.zig").run(init);
        return;
    }

    const argv = try qt6.init(init.gpa, init.minimal.args);
    defer qt6.deinit(init.gpa, argv);

    var argc: i32 = @intCast(argv.len);
    const qapp: QApplication = .new(init.arena.allocator(), &argc, argv);
    defer qapp.delete();

    try app.run(init, qapp);
}
