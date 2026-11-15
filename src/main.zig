const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const zvc_root = ".zvc";
const versions_subdir = "versions";
const downloads_subdir = "downloads";
const active_file = "active-version.txt";
const log_file = "log.txt";
const live_path_file = "live-path.txt";
const index_url = "https://ziglang.org/download/index.json";

const Channel = enum { stable, nightly };
const channel: Channel = .nightly; // default

// paths to projects to auto-test
const test_projects = [_][]const u8{};

const TargetInfo = struct {
    os_name: []const u8,
    arch_name: []const u8,
    triple: []const u8,
    exe_name: []const u8,
};

const target_info: TargetInfo = detect: {
    const os_name = switch (builtin.os.tag) {
        .windows, .linux, .macos => @tagName(builtin.os.tag),
        else => @compileError("zvc only supports windows/linux/macos"),
    };
    const arch_name = switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => @tagName(builtin.cpu.arch),
        else => @compileError("zvc only supports x86_64 or aarch64."),
    };
    const exe_name = switch (builtin.os.tag) {
        .windows => "zig.exe",
        .linux, .macos => "zig",
        else => unreachable,
    };
    break :detect .{
        .arch_name = arch_name,
        .os_name = os_name,
        .triple = arch_name ++ "-" ++ os_name,
        .exe_name = exe_name,
    };
};

const Subcommands = enum(u64) {
    clean,
    reset,
    _,
};

const String = struct {
    buf: []u8,
    len: usize,

    fn init(buf: []u8, len: usize) @This() {
        return .{
            .buf = buf,
            .len = len,
        };
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.free(self.buf);
    }

    pub fn toStr(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }
};

fn getCwdPath(io: Io, gpa: Allocator) !String {
    const buf = try gpa.alloc(u8, Dir.max_path_bytes);
    const len = try Dir.cwd().realPath(io, buf);
    return .init(buf, len);
}

fn getExePath(io: Io, gpa: Allocator) !String {
    const buf = try std.process.executableDirPathAlloc(io, gpa);
    const index = std.mem.indexOf(u8, buf, "zig-out").?;
    return .init(buf, index - 1);
}

// fn getZVCPath(io: Io, gpa: Allocator) !String {
//     const exe_path = try getExePath(io, gpa);
//     std.debug.print("Exe Path: {s}\n", .{exe_path});
//     // const index = std.mem.indexOf(u8, exe_path, "zig-out").?;
//     // return exe_path[0 .. index - 1];
//     return exe_path;
// }

test "Path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // The cwd helper agrees with the process's real working directory.
    var cwd_path = try getCwdPath(io, gpa);
    defer cwd_path.deinit(gpa);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const cwd_real = try Dir.realPathFileAbsoluteAlloc(io, cwd, gpa);
    defer gpa.free(cwd_real);
    try std.testing.expectEqualStrings(cwd_real, cwd_path.toStr());

    // The exe helper returns the folder that holds zig-out. Test binaries run
    // from the build cache, so check it only when the exe is under zig-out.
    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(exe_dir);
    const zig_out = std.mem.indexOf(u8, exe_dir, "zig-out") orelse return;
    var exe_path = try getExePath(io, gpa);
    defer exe_path.deinit(gpa);
    try std.testing.expectEqualStrings(exe_dir[0 .. zig_out - 1], exe_path.toStr());

    // const zvc_path = try getZVCPath(io, gpa);
    // defer gpa.free(zvc_path);
    // std.debug.print("{s}\n", .{zvc_path});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next(); // argv[0] = ZVC.exe
    if (args_it.next()) |subcommand| {
        const command = std.meta.stringToEnum(Subcommands, subcommand) orelse { //
            std.log.err(
                "Unknown subcommand \"{s}\" (expected clean, reset, or no arg)",
                .{subcommand},
            );
            return error.UnknownSubcommand;
        };
        switch (command) {
            .clean => return error.Unimplemented,
            .reset => return doReset(gpa, io),
            _ => return error.Unimplemented,
        }
    }

    try run(io, gpa, init.environ_map);
}

fn run(io: Io, gpa: Allocator, environ_map: *const std.process.Environ.Map) !void {
    std.debug.print(
        \\Detected: {s}-{s}
        \\Found:    {s}
    , .{
        target_info.arch_name,
        target_info.os_name,
        target_info.triple,
    });

    const cwd = Dir.cwd();
    try cwd.createDirPath(io, zvc_root);
    var zvc_dir = try cwd.openDir(io, zvc_root, .{ .iterate = true });
    defer zvc_dir.close(io);

    try zvc_dir.createDirPath(io, downloads_subdir);
    try zvc_dir.createDirPath(io, versions_subdir);

    var downloads_dir = try zvc_dir.openDir(io, downloads_subdir, .{ .iterate = true });
    defer downloads_dir.close(io);

    const active_raw: ?[]u8 = zvc_dir.readFileAlloc(
        io,
        active_file,
        gpa,
        .limited(1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (active_raw) |raw| gpa.free(raw);
    const active_version = if (active_raw) |raw| std.mem.trim(u8, raw, "\r\n") //
        else null;

    if (active_version) |curr_version| //
        std.debug.print("Current active version: {s}\n", .{curr_version})
    else //
        std.debug.print("No active version recorded yet.\n", .{});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    std.debug.print(
        "Checking {s} for latest {t} release...\n",
        .{ index_url, channel },
    );
    const index_bytes = try fetchIndexJson(gpa, &client);
    defer gpa.free(index_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, index_bytes, .{});
    defer parsed.deinit();

    const latest: LatestRelease = try .initFromValue(gpa, parsed.value);
    defer latest.deinit(gpa);

    std.debug.print("Latest {t} release: {s}\n", .{ channel, latest.name });

    const up_to_date = if (active_version) |cur| std.mem.eql(u8, cur, latest.name) //
        else false;

    var candidate_ok: bool = undefined;
    var candidate_home: []u8 = undefined;

    if (up_to_date) {
        std.debug.print("Already up to date.\n", .{});
        candidate_home = try resolveVersionHome(
            gpa,
            io,
            zvc_dir,
            latest.name,
        ) orelse home: {
            std.debug.print(
                "Warning: {s}'s dir is missing on disk; re-prep it.\n",
                .{latest.name},
            );
            break :home try prepareVersion(
                gpa,
                io,
                &client,
                zvc_dir,
                downloads_dir,
                active_version,
                &latest,
            );
        };
        defer gpa.free(candidate_home);
        candidate_ok = true;
        try finishRun(
            gpa,
            io,
            environ_map,
            &client,
            zvc_dir,
            downloads_dir,
            parsed.value,
            &latest,
            active_version,
            candidate_ok,
            candidate_home,
        );
        return;
    }

    candidate_home = try prepareVersion(
        gpa,
        io,
        &client,
        zvc_dir,
        downloads_dir,
        active_version,
        &latest,
    );
    defer gpa.free(candidate_home);

    const zig_bin_rel = try std.fs.path.join(gpa, &.{ candidate_home, target_info.exe_name });
    defer gpa.free(zig_bin_rel);

    const zig_bin = try cwd.realPathFileAlloc(io, zig_bin_rel, gpa);
    defer gpa.free(zig_bin);
    std.debug.print("Candidate Compiler: {s}\n", .{zig_bin});

    candidate_ok = try validateAgainstTestProjects(io, zig_bin);

    if (candidate_ok) {
        try zvc_dir.writeFile(io, .{ .sub_path = active_file, .data = latest.name });
        if (active_version) |old| {
            const old_rel = try std.fs.path.join(gpa, &.{ versions_subdir, old });
            defer gpa.free(old_rel);
            zvc_dir.deleteTree(io, old_rel) catch |err| {
                std.log.warn("Failed to remove old version. {s}: {t}\n", .{ old, err });
            };
        }
        std.log.info("Promoted zig version: {s} to active.\n", .{latest.name});
    } else {
        std.log.info(
            \\Breaking Change Detected 
            \\Zig {s} failed testing.
            \\Previous active version, {s}, left in place.
            \\New version remains on disk at {s}/{s}/{s} for inspection.
            \\Manual review required for promotion.
        , .{
            latest.name,
            if (active_version) |version| version else "none",
            zvc_root,
            versions_subdir,
            latest.name,
        });
    }

    try finishRun(
        gpa,
        io,
        environ_map,
        &client,
        zvc_dir,
        downloads_dir,
        parsed.value,
        &latest,
        active_version,
        candidate_ok,
        candidate_home,
    );
}

fn finishRun(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    client: *std.http.Client,
    zvc_dir: Dir,
    downloads_dir: Dir,
    index_root: std.json.Value,
    latest: *const LatestRelease,
    previous_active: ?[]const u8,
    candidate_ok: bool,
    candidate_home: []const u8,
) !void {
    if (channel != .nightly) return;
    try syncLiveInstall(
        gpa,
        io,
        zvc_dir,
        downloads_dir,
        environ_map,
        client,
        index_root,
        candidate_ok,
        latest.name,
        candidate_home,
        previous_active,
    );
}

fn fetchIndexJson(gpa: Allocator, client: *std.http.Client) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{
            .url = index_url,
        },
        .response_writer = &aw.writer,
    });
    if (result.status != .ok) return error.IndexFetchFailed;

    return gpa.dupe(u8, aw.writer.buffered());
}

const LatestRelease = struct {
    name: []const u8,
    tarball: []const u8,
    sha_sum: []const u8,

    pub fn initFromValue(gpa: Allocator, root: std.json.Value) !@This() {
        return switch (channel) {
            .stable => findLatestStable(gpa, root),
            .nightly => findMaster(gpa, root),
        };
    }

    pub fn deinit(self: *const @This(), gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.tarball);
        gpa.free(self.sha_sum);
    }

    pub fn initFromObjectMap(
        gpa: Allocator,
        name: []const u8,
        target_obj: std.json.ObjectMap,
    ) !@This() {
        const tarball = (target_obj.get("tarball") orelse //
            return error.MissingTarballField).string;
        const sha_sum = (target_obj.get("shasum") orelse //
            return error.MissingShasumField).string;
        return .{
            .name = try gpa.dupe(u8, name),
            .tarball = try gpa.dupe(u8, tarball),
            .sha_sum = try gpa.dupe(u8, sha_sum),
        };
    }

    pub fn findLatestStable(gpa: Allocator, root: std.json.Value) !@This() {
        var best: ?std.SemanticVersion = null;
        var best_key: []const u8 = "";

        var it = root.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "master")) continue;
            const ver = std.SemanticVersion.parse(key) catch continue;
            if (best == null or ver.order(best.?) == .gt) {
                best = ver;
                best_key = key;
            }
        }
        if (best == null) return error.NoStableVersionFound;

        const release_obj = root.object.get(best_key).?.object;
        const target_obj = (release_obj.get(target_info.triple) orelse
            return error.NoBuildForThisTarget).object;
        return initFromObjectMap(gpa, best_key, target_obj);
    }

    pub fn findMaster(gpa: Allocator, root: std.json.Value) !@This() {
        const master_obj = (root.object.get("master") orelse //
            return error.NoMasterEntry).object;
        const name = (master_obj.get("version") orelse //
            return error.MissingVersionField).string;
        const target_obj = (master_obj.get(target_info.triple) orelse
            return error.NoBuildForThisTarget).object;
        return initFromObjectMap(gpa, name, target_obj);
    }
};

fn isNightlyVersionName(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "-dev") != null;
}

fn downloadFile(
    io: Io,
    client: *std.http.Client,
    url: []const u8,
    dest_dir: Dir,
    dest_name: []const u8,
) !void {
    var out_file = try dest_dir.createFile(io, dest_name, .{});
    defer out_file.close(io);

    var buf: [1 << 16]u8 = undefined;
    var file_writer = out_file.writer(io, &buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });
    try file_writer.flush();

    if (result.status != .ok) return error.DownloadFailed;
}

fn sha256HexOfFile(
    io: Io,
    dir: Dir,
    file_name: []const u8,
) ![64]u8 {
    var file = try dir.openFile(io, file_name, .{});
    defer file.close(io);

    var read_buf: [1 << 16]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = try file_reader.interface.readSliceShort(&chunk);
        hasher.update(chunk[0..n]);
        if (n < chunk.len) break;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn ensureArchiveDownloaded(
    io: Io,
    client: *std.http.Client,
    downloads_dir: Dir,
    release: *const LatestRelease,
    archive_name: []const u8,
) !void {
    if (downloads_dir.access(io, archive_name, .{})) |_| {
        const cached_hex = try sha256HexOfFile(io, downloads_dir, archive_name);
        if (std.mem.eql(u8, &cached_hex, release.sha_sum)) {
            std.log.info(
                "Using cached download {s} (sha256 verified)",
                .{archive_name},
            );
            return;
        }
        std.log.info(
            "Cached download {s} does not match the published sha sum; Discarding.",
            .{archive_name},
        );
    } else |_| {}
    std.log.info("Downloading {s}", .{release.tarball});
    try downloadFile(io, client, release.tarball, downloads_dir, archive_name);

    const fresh_hex = try sha256HexOfFile(io, downloads_dir, archive_name);
    if (!std.mem.eql(u8, &fresh_hex, release.sha_sum)) {
        downloads_dir.deleteFile(io, archive_name) catch {};
        std.log.info(
            "Download hash mismatch for {s}:\nExpected {s}\nActual:   {s}",
            .{ archive_name, release.sha_sum, fresh_hex },
        );
        return error.DownloadHashMismatch;
    }
    std.log.info("Downloaded {s} (sha256 verified)", .{archive_name});
}

/// True if `path_or_child` is `ancestor` itself, or a path underneath it.
/// Used to check whether a resolved "live" directory lives inside a
/// candidate version directory, regardless of how deeply nested (e.g. a
/// version dir `versions/0.16.0` whose actual zig home is the nested
/// `versions/0.16.0/zig-x86_64-windows-0.16.0`).
fn pathIsWithin(ancestor: []const u8, path_or_child: []const u8) bool {
    if (!std.mem.startsWith(u8, path_or_child, ancestor)) return false;
    if (path_or_child.len == ancestor.len) return true;
    const sep = path_or_child[ancestor.len];
    return sep == '/' or sep == '\\';
}

/// Resolves the real, canonical directory that the configured "live" zig
/// (see `live-path.txt`) currently points at, if any. Best-effort: any
/// failure (nothing configured yet, dangling junction, etc.) just yields
/// `null` rather than an error, since this is only used to decide what
/// pruning must not touch.
fn currentLiveRealPath(gpa: Allocator, io: Io, zvc_dir: Dir) ?[:0]u8 {
    const live_dir_path = (loadLiveDirConfig(gpa, io, zvc_dir) catch null) orelse return null;
    defer gpa.free(live_dir_path);
    return Dir.cwd().realPathFileAlloc(io, live_dir_path, gpa) catch null;
}

fn pruneVersions(
    gpa: Allocator,
    io: Io,
    versions_dir: Dir,
    keep_name: ?[]const u8,
    live_real_path: ?[]const u8,
) !void {
    var to_delete: std.ArrayList([]u8) = .empty;
    defer {
        for (to_delete.items) |name| gpa.free(name);
        to_delete.deinit(gpa);
    }

    var it = versions_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (keep_name) |keep| {
            if (std.mem.eql(u8, entry.name, keep)) continue;
        }
        // Never delete whatever directory currently backs the live zig
        // install, even if it isn't the recorded "active" version (the two
        // can drift, e.g. after a failed promotion). Deleting it out from
        // under a running/linked compiler is what corrupts installs.
        if (live_real_path) |live_real| protect: {
            const candidate_real = versions_dir.realPathFileAlloc(io, entry.name, gpa) catch
                break :protect;
            defer gpa.free(candidate_real);
            if (pathIsWithin(candidate_real, live_real)) {
                std.log.info(
                    "Keeping {s}: currently backs the live zig install.",
                    .{entry.name},
                );
                continue;
            }
        }
        try to_delete.append(gpa, try gpa.dupe(u8, entry.name));
    }

    for (to_delete.items) |name| {
        std.log.info(
            "Pruning old candidate {s} (keep active + newest candidates)",
            .{name},
        );
        versions_dir.deleteTree(io, name) catch |err| {
            std.log.info(" warning: failed to remove {s}: {t}", .{ name, err });
        };
    }
}

fn prepareVersion(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    zvc_dir: Dir,
    downloads_dir: Dir,
    keep_alongside: ?[]const u8,
    release: *const LatestRelease,
) ![]u8 {
    if (try resolveVersionHome(gpa, io, zvc_dir, release.name)) |home| return home;

    const archive_name = std.fs.path.basenamePosix(release.tarball);
    try ensureArchiveDownloaded(io, client, downloads_dir, release, archive_name);

    const live_real_path = currentLiveRealPath(gpa, io, zvc_dir);
    defer if (live_real_path) |p| gpa.free(p);

    var versions_dir = try zvc_dir.openDir(io, versions_subdir, .{ .iterate = true });
    try pruneVersions(gpa, io, versions_dir, keep_alongside, live_real_path);
    versions_dir.close(io);

    const version_rel = try std.fs.path.join(gpa, &.{ versions_subdir, release.name });
    defer gpa.free(version_rel);
    try zvc_dir.createDirPath(io, version_rel);
    var version_dir = try zvc_dir.openDir(io, version_rel, .{ .iterate = true });
    defer version_dir.close(io);

    std.log.info("Extract into {s}/{s}", .{ zvc_root, version_rel });
    try extractArchive(gpa, io, downloads_dir, archive_name, version_dir);

    const home_rel = try findZigHome(gpa, io, versions_dir, version_rel);
    defer gpa.free(home_rel);
    return std.fs.path.join(gpa, &.{ zvc_root, home_rel });
}

fn resolveVersionHome(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    name: []const u8,
) !?[]u8 {
    const version_rel = try std.fs.path.join(
        gpa,
        &.{ versions_subdir, name },
    );
    defer gpa.free(version_rel);

    var version_dir = zvc_dir.openDir(
        io,
        version_rel,
        .{ .iterate = true },
    ) catch return null;
    defer version_dir.close(io);

    const home_rel = try findZigHome(gpa, io, version_dir, version_rel);
    defer gpa.free(home_rel);
    return try std.fs.path.join(gpa, &.{ zvc_root, home_rel });
}

fn extractArchive(
    gpa: Allocator,
    io: Io,
    archive_dir: Dir,
    archive_name: []const u8,
    dest_dir: Dir,
) !void {
    var archive_file = try archive_dir.openFile(io, archive_name, .{});
    defer archive_file.close(io);

    var read_buf: [1 << 16]u8 = undefined;
    var file_reader = archive_file.reader(io, &read_buf);

    if (std.mem.endsWith(u8, archive_name, ".zip")) {
        try std.zip.extract(dest_dir, &file_reader, .{});
    } else {
        const xz_buf = try gpa.alloc(u8, 1 << 16);
        defer gpa.free(xz_buf);
        var decompress = try std.compress.xz.Decompress.init(
            &file_reader.interface,
            gpa,
            xz_buf,
        );
        defer decompress.deinit();
        try std.tar.extract(io, dest_dir, &decompress.reader, .{
            .mode_mode = .executable_bit_only,
        });
    }
}

fn findZigHome(
    gpa: Allocator,
    io: Io,
    version_dir: Dir,
    version_rel: []const u8,
) ![]const u8 {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var nested_len: usize = 0;
    var entry_count: usize = 0;
    var only_entry_is_dir: bool = false;

    var it = version_dir.iterate();
    while (try it.next(io)) |entry| {
        entry_count += 1;
        if (entry_count == 1 and entry.kind == .directory) {
            @memcpy(name_buf[0..entry.name.len], entry.name);
            nested_len = entry.name.len;
            only_entry_is_dir = true;
        } else {
            only_entry_is_dir = false;
        }
    }
    if (entry_count == 1 and only_entry_is_dir) {
        return std.fs.path.join(gpa, &.{ version_rel, name_buf[0..nested_len] });
    }
    return gpa.dupe(u8, version_rel);
}

fn validateAgainstTestProjects(io: Io, zig_bin: []const u8) !bool {
    if (test_projects.len == 0) {
        std.debug.print("No test projects configured; Skipping compatibility checks.\n", .{});
        return true;
    }
    var all_ok = true;
    for (test_projects) |project_path| {
        std.debug.print("Testing candidate against {s}\n", .{project_path});
        const argv = [_][]const u8{ zig_bin, "build", "test" };
        var child = std.process.spawn(io, .{
            .argv = &argv,
            .cwd = .{ .path = project_path },
        }) catch |err| {
            std.debug.print(" could not launch zig in {s}: {t}\n", .{ project_path, err });
            all_ok = false;
            continue;
        };
        const term = try child.wait(io);
        if (term.success()) {
            std.debug.print(" Ok\n", .{});
        } else {
            std.debug.print(" Failed: {f}\n", .{term});
            all_ok = false;
        }
    }
    return all_ok;
}

fn findLiveZigDir(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    const path_var = environ_map.get("PATH") orelse //
        environ_map.get("Path") orelse //
        environ_map.get("path") orelse //
        return null;
    var it = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |dir_path| {
        const candidate = try std.fs.path.join(gpa, &.{ dir_path, target_info.exe_name });
        defer gpa.free(candidate);
        if (Dir.cwd().access(io, candidate, .{})) |_| {
            return try gpa.dupe(u8, dir_path);
        } else |_| {}
    }
    return null;
}

fn looksLikeZigInstallDir(io: Io, dir: Dir) bool {
    dir.access(io, target_info.exe_name, .{}) catch return false;
    dir.access(io, "lib", .{}) catch return false;
    return true;
}

fn validateLiveDirPath(path_str: []const u8) !void {
    if (path_str.len == 0) return error.EmptyPath;
    if (std.mem.indexOfScalar(u8, path_str, 0) != null) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(path_str)) return error.PathMustBeAbsolute;
    if (builtin.os.tag == .windows) {
        for (path_str) |ch| {
            if (std.mem.indexOfScalar(u8, "<>\"|?*)", ch) != null) //
                return error.InvalidPathCharacter;
        }
    }
}

fn defaultLiveDirSuggestion(
    gpa: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const base = environ_map.get("LOCALAPPDATA") orelse //
                environ_map.get("USERPROFILE") orelse //
                return gpa.dupe(u8, "C:\\zvc\\zig");
            return std.fs.path.join(gpa, &.{ base, "zvc", "zig" });
        },
        else => {
            const home = environ_map.get("HOME") orelse //
                return gpa.dupe(u8, "/usr/local/zvc/zig");
            return std.fs.path.join(gpa, &.{ home, ".local", "share", "zvc", "zig" });
        },
    }
}

fn loadLiveDirConfig(gpa: Allocator, io: Io, zvc_dir: Dir) !?[]u8 {
    const raw = zvc_dir.readFileAlloc(
        io,
        live_path_file,
        gpa,
        .limited(4096),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(raw);

    const trimmed = std.mem.trim(u8, raw, "\t\r\n");
    if (trimmed.len == 0) return null;
    validateLiveDirPath(trimmed) catch {
        std.log.warn(
            "{s}/{s} contains invalid path {s}; Ignoring path.",
            .{ zvc_root, live_path_file, trimmed },
        );
        return null;
    };
    return try gpa.dupe(u8, trimmed);
}

fn saveLiveDirConfig(io: Io, zvc_dir: Dir, path_str: []const u8) !void {
    try zvc_dir.writeFile(io, .{ .sub_path = live_path_file, .data = path_str });
}

fn promptForLiveDir(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    const suggested = try defaultLiveDirSuggestion(gpa, environ_map);
    defer gpa.free(suggested);

    std.log.info(
        \\No existing `zig` found on PATH.
        \\No managed install location configured.
        \\Dir will be created/reused + added to PATH. 
        \\Contents will point to currently active version.
        \\Press <ENTER> to accept default suggestion or type an abs path.
        \\[{s}]
        \\
    , .{suggested});

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const line = stdin_reader.interface.takeDelimiterExclusive('\n') //
        catch |err| switch (err) {
            error.EndOfStream => "",
            else => return err,
        };
    const trimmed = std.mem.trim(u8, line, "\t\r\n");
    const chosen = if (trimmed.len == 0) suggested else trimmed;

    try validateLiveDirPath(chosen);
    return gpa.dupe(u8, chosen);
}

fn resolveLiveInstallPath(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    if (try loadLiveDirConfig(gpa, io, zvc_dir)) |configured| return configured;
    if (try findLiveZigDir(gpa, io, environ_map)) |detected| {
        std.log.info(
            "Detected existing zig on PATH at {s}; remember it at {s}/{s}.",
            .{ detected, zvc_root, live_path_file },
        );
        saveLiveDirConfig(io, zvc_dir, detected) catch |err| {
            std.log.warn(
                "Could not save {s}/{s}: {t}",
                .{ zvc_root, live_path_file, err },
            );
        };
        return detected;
    }
    const chosen = try promptForLiveDir(gpa, io, environ_map);
    try saveLiveDirConfig(io, zvc_dir, chosen);
    return chosen;
}

fn createLink(io: Io, link_path: []const u8, target_path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            const argv = [_][]const u8{
                "cmd",
                "/c",
                "mklink",
                "/J",
                link_path,
                target_path,
            };
            var child = try std.process.spawn(io, .{
                .argv = &argv,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            const term = try child.wait(io);
            switch (term) {
                .exited => |code| if (code != 0) return error.JunctionCreateFailed,
                else => return error.JunctionCreateFailed,
            }
        },
        else => try Dir.cwd().symLink(
            io,
            target_path,
            link_path,
            .{ .is_directory = true },
        ),
    }
}

fn pointLiveInstall(
    io: Io,
    live_dir_path: []const u8,
    target_home_abs: []const u8,
) !void {
    const cwd = Dir.cwd();
    if (std.fs.path.dirname(live_dir_path)) |parent| try cwd.createDirPath(io, parent);
    const exists = if (cwd.access(io, live_dir_path, .{})) |_| true else |_| false;
    if (exists) {
        cwd.deleteDir(io, live_dir_path) catch |err| switch (err) {
            error.DirNotEmpty => {
                var existing = try cwd.openDir(io, live_dir_path, .{ .iterate = true });
                const looks_like_zig = looksLikeZigInstallDir(io, existing);
                existing.close(io);
                if (!looks_like_zig) return error.LiveDirDoesNotLookLikeZig;
                try cwd.deleteTree(io, live_dir_path);
            },
            else => return err,
        };
    }
    try createLink(io, live_dir_path, target_home_abs);
}

fn applyLiveInstall(
    gpa: Allocator,
    io: Io,
    live_dir_path: []const u8,
    source_home_path: []const u8,
) !void {
    const abs_path = try Dir.cwd().realPathFileAlloc(io, source_home_path, gpa);
    defer gpa.free(abs_path);
    try pointLiveInstall(io, live_dir_path, abs_path);
}

fn logError(io: Io, zvc_dir: Dir, msg: []const u8) !void {
    var file = try zvc_dir.createFile(
        io,
        log_file,
        .{ .truncate = false, .read = true },
    );
    defer file.close(io);

    const size = (try file.stat(io)).size;
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.seekTo(size);

    const now = Io.Timestamp.now(io, .real).nanoseconds;
    const epoch_seconds = @divTrunc(
        now,
        std.time.ns_per_s,
    );
    try writer.interface.print("[{d}] {s}\n", .{ epoch_seconds, msg });
    try writer.flush();
}

fn reportLiveInstallFailure(
    io: Io,
    zvc_dir: Dir,
    candidate_name: []const u8,
    detail: []const u8,
) !void {
    std.log.err("Nightly {s} failed and {s}", .{ candidate_name, detail });
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "nightly {s} failed and {s}",
        .{ candidate_name, detail },
    ) catch
        "nightly failed and the failure detail was too long to log";
    logError(io, zvc_dir, msg) catch |err| {
        std.log.err(
            "Additionally, failed to write {s}/{s}: {t}\n",
            .{ zvc_root, log_file, err },
        );
    };
}

fn syncLiveInstall(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    downloads_dir: Dir,
    environ_map: *const std.process.Environ.Map,
    client: *std.http.Client,
    index_root: std.json.Value,
    candidate_ok: bool,
    candidate_name: []const u8,
    candidate_home: []const u8,
    previous_active: ?[]const u8,
) !void {
    const live_dir = try resolveLiveInstallPath(gpa, io, zvc_dir, environ_map);
    defer gpa.free(live_dir);

    if (candidate_ok) {
        applyLiveInstall(gpa, io, live_dir, candidate_home) catch |err| {
            var buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &buf,
                "passed its tests but updating {s} failed ({t})",
                .{ live_dir, err },
            ) catch
                "passed its tests but updating live install failed";
            try reportLiveInstallFailure(io, zvc_dir, candidate_name, detail);
            return;
        };
        std.log.info("Live zig at {s} now points to {s}.", .{ live_dir, candidate_name });
        return;
    }
    std.log.info(
        "Nightly {s} failed its tests; looking for a fallback for {s}...\n",
        .{ candidate_name, live_dir },
    );

    if (previous_active) |prev| {
        if (isNightlyVersionName(prev)) {
            if (try resolveVersionHome(gpa, io, zvc_dir, prev)) |prev_home| {
                defer gpa.free(prev_home);
                if (applyLiveInstall(gpa, io, live_dir, prev_home)) |_| {
                    std.debug.print(
                        "Live zig reverted to last known good nightly: {s}\n",
                        .{prev},
                    );
                    return;
                } else |_| {
                    // Fall through to stable fallback
                }
            }
        }
    }

    const stable = LatestRelease.findLatestStable(gpa, index_root) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &buf,
            \\no known-good nightly was available and latest stable release could not be 
            \\determined ({t})."
        ,
            .{err},
        ) catch
            "no known good nightly available and latest stable release could not be determined";
        try reportLiveInstallFailure(io, zvc_dir, candidate_name, detail);
        return;
    };
    defer stable.deinit(gpa);

    const stable_home = prepareVersion(
        gpa,
        io,
        client,
        zvc_dir,
        downloads_dir,
        previous_active,
        &stable,
    ) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &buf,
            \\no known good nightly available and proparing fallback stable release 
            \\{s} failed ({t}).
        ,
            .{ stable.name, err },
        ) catch
            "no known good nightly available and preparing fallback stable release failed";
        try reportLiveInstallFailure(io, zvc_dir, candidate_name, detail);
        return;
    };
    defer gpa.free(stable_home);

    applyLiveInstall(gpa, io, live_dir, stable_home) catch |err| {
        var buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf,
            \\no known good nightly available and applying fallback stable release 
            \\{s} failed ({t})"
        , .{ stable.name, err }) catch
            "no known good nightly available and applying fallback stable release failed";
        try reportLiveInstallFailure(io, zvc_dir, candidate_name, detail);
        return;
    };
    std.log.err(
        \\No known good nightly available.
        \\Live zig backed up to latest stable release {s}."
    ,
        .{stable.name},
    );
}

fn doReset(gpa: Allocator, io: Io) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, zvc_root);
    var zvc_dir = try cwd.openDir(io, zvc_root, .{ .iterate = true });
    defer zvc_dir.close(io);

    std.log.info(
        "Reset {s}: clearing all downloaded/extracted zig versions...",
        .{zvc_root},
    );
    zvc_dir.deleteTree(io, versions_subdir) catch {};
    zvc_dir.deleteTree(io, downloads_subdir) catch {};
    zvc_dir.deleteFile(io, active_file) catch {};

    try zvc_dir.createDirPath(io, versions_subdir);
    try zvc_dir.createDirPath(io, downloads_subdir);
    var downloads_dir = try zvc_dir.openDir(io, downloads_subdir, .{ .iterate = true });
    defer downloads_dir.close(io);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const index_bytes = try fetchIndexJson(gpa, &client);
    defer gpa.free(index_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, index_bytes, .{});
    defer parsed.deinit();

    const stable: LatestRelease = try .findLatestStable(gpa, parsed.value);
    defer stable.deinit(gpa);

    const master: LatestRelease = try .findMaster(gpa, parsed.value);
    defer master.deinit(gpa);

    std.log.info("Fetching latest stable: ({s})...", .{stable.name});
    const stable_home = try prepareVersion(
        gpa,
        io,
        &client,
        zvc_dir,
        downloads_dir,
        null,
        &stable,
    );
    gpa.free(stable_home);

    std.log.info("Fetching latest master: ({s})...", .{master.name});
    const master_home = try prepareVersion(
        gpa,
        io,
        &client,
        zvc_dir,
        downloads_dir,
        stable.name,
        &master,
    );
    defer gpa.free(master_home);

    std.log.info(
        \\Reset Complete: {s} (stable) and {s} (master) are on disk.
        \\Nothing was promoted or synced to live install.
    ,
        .{ stable.name, master.name },
    );
}
