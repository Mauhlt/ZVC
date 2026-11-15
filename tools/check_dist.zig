//! `zig build check-dist`: fails if any release binary embeds a path from the
//! machine that built it.
const std = @import("std");

/// Byte strings that only show up in a binary through an absolute build path.
const forbidden = [_][]const u8{ "/home/runner", "Users\\", "C:\\", "/Users/" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();

    var checked: usize = 0;
    var clean = true;
    while (args.next()) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
        defer gpa.free(bytes);
        const name = std.fs.path.basename(path);
        if (findForbidden(bytes)) |hit| {
            std.log.err("{s}: contains \"{s}\" at offset {d}", .{ name, hit.needle, hit.offset });
            clean = false;
        }
        checked += 1;
    }
    if (checked == 0) return error.NoBinariesGiven;
    if (!clean) std.process.exit(1);
    std.debug.print("check-dist: {d} binaries contain no build-machine paths.\n", .{checked});
}

const Hit = struct { needle: []const u8, offset: usize };

/// Case-insensitive, so `users\` or `c:\` are caught too.
fn findForbidden(bytes: []const u8) ?Hit {
    for (forbidden) |needle| {
        if (std.ascii.findIgnoreCase(bytes, needle)) |offset| return .{ .needle = needle, .offset = offset };
    }
    return null;
}

test findForbidden {
    try std.testing.expect(findForbidden("ok https://ziglang.org /usr/local/bin") == null);
    try std.testing.expectEqual(@as(usize, 2), findForbidden("..c:\\x").?.offset);
    try std.testing.expect(findForbidden("/home/runner/work/x") != null);
    try std.testing.expect(findForbidden("\\USERS\\me") != null);
    try std.testing.expect(findForbidden("/Users/me") != null);
}
