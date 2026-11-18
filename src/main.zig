const std = @import("std");
const qt6 = @import("libqt6zig");

const app = @import("app.zig");
const QApplication = qt6.QApplication;

pub fn main(init: std.process.Init) !void {
    const argv = try qt6.init(init.gpa, init.minimal.args);
    defer qt6.deinit(init.gpa, argv);

    var argc: i32 = @intCast(argv.len);
    const qapp: QApplication = .new(init.arena.allocator(), &argc, argv);
    defer qapp.delete();

    try app.run(init, qapp);
}
