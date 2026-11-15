//! `zig build release-info`: writes the release tag and notes for the
//! known-good Zig version into zig-out/release/.
//! Usage: release_info <zig version> <tag file> <notes file>
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const version = args.next() orelse return error.MissingVersion;
    const tag_path = args.next() orelse return error.MissingTagPath;
    const notes_path = args.next() orelse return error.MissingNotesPath;

    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const secs: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

    var tag_buf: [128]u8 = undefined;
    const tag = try releaseTag(&tag_buf, secs, version);
    var notes_buf: [2048]u8 = undefined;
    const notes = try releaseNotes(&notes_buf, version);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tag_path, .data = tag });
    try cwd.writeFile(io, .{ .sub_path = notes_path, .data = notes });
}

/// `v<YYYY-MM-DD>-zig<version>`, dated in UTC.
fn releaseTag(buf: []u8, epoch_secs: u64, version: []const u8) ![]const u8 {
    const day = (std.time.epoch.EpochSeconds{ .secs = epoch_secs }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "v{d:0>4}-{d:0>2}-{d:0>2}-zig{s}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
        version,
    });
}

fn releaseNotes(buf: []u8, version: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\ZVC built and tested with Zig {s}, its known-good version.
        \\
        \\Each binary embeds that version: on a machine with no Zig, a plain run
        \\installs exactly Zig {s} from ziglang.org (checked against the index's
        \\sha256, or the archive's minisign signature) and makes it live.
        \\
        \\Binaries: zvc-x86_64-windows.exe, zvc-aarch64-windows.exe,
        \\zvc-x86_64-linux, zvc-aarch64-linux, zvc-x86_64-macos, zvc-aarch64-macos.
        \\
    , .{ version, version });
}

test releaseTag {
    var buf: [128]u8 = undefined;
    // 2026-11-14T12:00:00Z
    try std.testing.expectEqualStrings(
        "v2026-11-14-zig0.18.0-dev.1005+75d48dfff",
        try releaseTag(&buf, 1794657600, "0.18.0-dev.1005+75d48dfff"),
    );
    // 1970-01-01
    try std.testing.expectEqualStrings("v1970-01-01-zig0.17.1", try releaseTag(&buf, 0, "0.17.1"));
}
