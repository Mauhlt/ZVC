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
const pin_file = "pinned-version.txt";
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
    install,
    update,
    version,
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
                "Unknown subcommand \"{s}\" (expected clean, reset, install, update, version, or no arg)",
                .{subcommand},
            );
            return error.UnknownSubcommand;
        };
        switch (command) {
            .clean => return error.Unimplemented,
            .reset => return doReset(gpa, io),
            .install => {
                const version = try installArgs(gpa, io, &args_it);
                defer gpa.free(version);
                return doInstall(gpa, io, init.environ_map, version);
            },
            .update => return run(io, gpa, init.environ_map, .update),
            .version => {
                std.debug.print("ZVC known-good zig: {s}\n", .{known_good_zig});
                return;
            },
            _ => return error.Unimplemented,
        }
    }

    try run(io, gpa, init.environ_map, .plain);
}

/// Both move to the newest release of `channel` and clear any pin. They differ
/// only on a device with no zig at all: a plain run then installs ZVC's
/// known-good zig and stops, while `update` goes straight to the newest build.
const RunMode = enum { plain, update };

fn run(io: Io, gpa: Allocator, environ_map: *const std.process.Environ.Map, mode: RunMode) !void {
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

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    if (mode == .plain and !try hasUsableZig(gpa, io, zvc_dir, environ_map)) {
        try bootstrapKnownGood(gpa, io, &client, zvc_dir, downloads_dir, environ_map);
        return;
    }

    const active_version = try readPointerFile(gpa, io, zvc_dir, active_file);
    defer if (active_version) |v| gpa.free(v);

    if (active_version) |curr_version| //
        std.debug.print("Current active version: {s}\n", .{curr_version})
    else //
        std.debug.print("No active version recorded yet.\n", .{});

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

    // Keep the other channel's newest release on disk too (stable beside the
    // nightly): it is the fallback when a nightly fails.
    refreshOtherSlot(gpa, io, &client, zvc_dir, downloads_dir, parsed.value, active_version);

    const live = channel == .nightly;
    const up_to_date = if (active_version) |cur| std.mem.eql(u8, cur, latest.name) //
        else false;

    if (up_to_date) {
        std.debug.print("Already up to date.\n", .{});
        const home = try resolveVersionHome(
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
                versionKind(latest.name),
                &latest,
            );
        };
        defer gpa.free(home);
        // Re-point the live zig in case it drifted, and drop any pin.
        activateVersion(gpa, io, zvc_dir, environ_map, .{
            .name = latest.name,
            .home = home,
            .pin = .unpin,
            .live = live,
        }) catch |err| switch (err) {
            error.LiveInstallFailed => return,
            else => return err,
        };
        return;
    }

    const candidate_home = try prepareVersion(
        gpa,
        io,
        &client,
        zvc_dir,
        downloads_dir,
        active_version,
        versionKind(latest.name),
        &latest,
    );
    defer gpa.free(candidate_home);

    const zig_bin_rel = try std.fs.path.join(gpa, &.{ candidate_home, target_info.exe_name });
    defer gpa.free(zig_bin_rel);

    const zig_bin = try cwd.realPathFileAlloc(io, zig_bin_rel, gpa);
    defer gpa.free(zig_bin);
    std.debug.print("Candidate Compiler: {s}\n", .{zig_bin});

    if (try validateAgainstTestProjects(io, zig_bin)) {
        activateVersion(gpa, io, zvc_dir, environ_map, .{
            .name = latest.name,
            .home = candidate_home,
            .pin = .unpin,
            .live = live,
        }) catch |err| switch (err) {
            error.LiveInstallFailed => return,
            else => return err,
        };
        recordKnownGood(gpa, io, zig_bin, latest.name);
        return;
    }

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
    if (!live) return;
    try syncLiveFallback(
        gpa,
        io,
        zvc_dir,
        downloads_dir,
        environ_map,
        &client,
        parsed.value,
        latest.name,
        active_version,
    );
}

/// Makes sure the newest release of the channel ZVC does not follow is on
/// disk, without promoting it. Best-effort: a failure only warns.
fn refreshOtherSlot(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    zvc_dir: Dir,
    downloads_dir: Dir,
    index_root: std.json.Value,
    active_version: ?[]const u8,
) void {
    const other = switch (channel) {
        .nightly => LatestRelease.findLatestStable(gpa, index_root),
        .stable => LatestRelease.findMaster(gpa, index_root),
    } catch |err| {
        std.log.warn("Could not find the other channel's newest release: {t}", .{err});
        return;
    };
    defer other.deinit(gpa);
    const home = prepareVersion(
        gpa,
        io,
        client,
        zvc_dir,
        downloads_dir,
        active_version,
        versionKind(other.name),
        &other,
    ) catch |err| {
        std.log.warn("Could not keep {s} on disk: {t}", .{ other.name, err });
        return;
    };
    gpa.free(home);
}

fn fetchIndexJson(gpa: Allocator, client: *std.http.Client) ![]u8 {
    return fetchBytes(gpa, client, index_url) catch |err| switch (err) {
        error.HttpNotFound, error.HttpStatus => return error.IndexFetchFailed,
        else => return err,
    };
}

/// GETs `url` into memory. A 404 is its own error so callers can say the
/// file is gone rather than that the request failed.
fn fetchBytes(gpa: Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    switch (result.status) {
        .ok => {},
        .not_found => return error.HttpNotFound,
        else => return error.HttpStatus,
    }

    return gpa.dupe(u8, aw.writer.buffered());
}

const LatestRelease = struct {
    /// Always a `parseVersion`-checked version: it becomes a folder name and
    /// the content of active-version.txt.
    name: []const u8,
    tarball: []const u8,
    /// The index's sha256 (lowercase hex), checked in addition to the
    /// minisign signature; null for a build found outside the index (an older
    /// dev build), which has only the signature.
    sha_sum: ?[]const u8,
    /// The archive size the index declares, if any; caps the download.
    size: ?u64 = null,

    pub fn initFromValue(gpa: Allocator, root: std.json.Value) !@This() {
        return switch (channel) {
            .stable => findLatestStable(gpa, root),
            .nightly => findMaster(gpa, root),
        };
    }

    pub fn deinit(self: *const @This(), gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.tarball);
        if (self.sha_sum) |sum| gpa.free(sum);
    }

    /// Reads one target's entry. Every field is type-checked, so an index of
    /// an unexpected shape is an error, never a panic.
    pub fn initFromObjectMap(
        gpa: Allocator,
        name: []const u8,
        target_obj: std.json.ObjectMap,
    ) !@This() {
        const version = try parseVersion(name);
        const tarball = target_obj.get("tarball") orelse return error.MissingTarballField;
        if (tarball != .string or !std.mem.startsWith(u8, tarball.string, "https://"))
            return error.BadIndex;
        const sha_sum = target_obj.get("shasum") orelse return error.MissingShasumField;
        if (sha_sum != .string or !isSha256Hex(sha_sum.string)) return error.BadIndex;
        const size: ?u64 = if (target_obj.get("size")) |value| switch (value) {
            .string => |text| std.fmt.parseUnsigned(u64, text, 10) catch return error.BadIndex,
            .integer => |n| std.math.cast(u64, n) orelse return error.BadIndex,
            else => return error.BadIndex,
        } else null;

        const name_copy = try gpa.dupe(u8, version);
        errdefer gpa.free(name_copy);
        const tarball_copy = try gpa.dupe(u8, tarball.string);
        errdefer gpa.free(tarball_copy);
        const sha_copy = try std.ascii.allocLowerString(gpa, sha_sum.string);
        return .{
            .name = name_copy,
            .tarball = tarball_copy,
            .sha_sum = sha_copy,
            .size = size,
        };
    }

    pub fn findLatestStable(gpa: Allocator, root: std.json.Value) !@This() {
        if (root != .object) return error.BadIndex;
        var best: ?std.SemanticVersion = null;
        var best_key: []const u8 = "";

        var it = root.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "master")) continue;
            const checked = parseVersion(key) catch continue;
            const ver = std.SemanticVersion.parse(checked) catch continue;
            if (best == null or ver.order(best.?) == .gt) {
                best = ver;
                best_key = key;
            }
        }
        if (best == null) return error.NoStableVersionFound;

        const release_obj = root.object.get(best_key).?;
        if (release_obj != .object) return error.BadIndex;
        const target_obj = release_obj.object.get(target_info.triple) orelse
            return error.NoBuildForThisTarget;
        if (target_obj != .object) return error.BadIndex;
        return initFromObjectMap(gpa, best_key, target_obj.object);
    }

    pub fn findMaster(gpa: Allocator, root: std.json.Value) !@This() {
        if (root != .object) return error.BadIndex;
        const master_obj = root.object.get("master") orelse return error.NoMasterEntry;
        if (master_obj != .object) return error.BadIndex;
        const name = master_obj.object.get("version") orelse return error.MissingVersionField;
        if (name != .string) return error.BadIndex;
        const target_obj = master_obj.object.get(target_info.triple) orelse
            return error.NoBuildForThisTarget;
        if (target_obj != .object) return error.BadIndex;
        return initFromObjectMap(gpa, name.string, target_obj.object);
    }
};

fn isSha256Hex(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

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
    const digest = try hashFile(std.crypto.hash.sha2.Sha256, io, dir, file_name);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashFile(
    comptime Hash: type,
    io: Io,
    dir: Dir,
    file_name: []const u8,
) ![Hash.digest_length]u8 {
    var file = try dir.openFile(io, file_name, .{});
    defer file.close(io);

    var read_buf: [1 << 16]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    var hasher = Hash.init(.{});
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = try file_reader.interface.readSliceShort(&chunk);
        hasher.update(chunk[0..n]);
        if (n < chunk.len) break;
    }

    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn ensureArchiveDownloaded(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    downloads_dir: Dir,
    release: *const LatestRelease,
    archive_name: []const u8,
) !void {
    // A build found outside the index has no published sha sum. Fetch its
    // minisign signature first, so a build that is gone fails before any
    // download starts.
    const signature: ?[]u8 = if (release.sha_sum == null)
        try fetchSignature(gpa, client, release.tarball)
    else
        null;
    defer if (signature) |sig| gpa.free(sig);
    const method = if (signature == null) "sha256" else "minisign";

    if (downloads_dir.access(io, archive_name, .{})) |_| {
        if (try archiveVerified(io, downloads_dir, archive_name, release, signature)) {
            std.log.info(
                "Using cached download {s} ({s} verified)",
                .{ archive_name, method },
            );
            return;
        }
        std.log.info(
            "Cached download {s} failed its {s} check; Discarding.",
            .{ archive_name, method },
        );
    } else |_| {}
    std.log.info("Downloading {s}", .{release.tarball});
    try downloadFile(io, client, release.tarball, downloads_dir, archive_name);

    if (!try archiveVerified(io, downloads_dir, archive_name, release, signature)) {
        downloads_dir.deleteFile(io, archive_name) catch {};
        return error.DownloadVerificationFailed;
    }
    std.log.info("Downloaded {s} ({s} verified)", .{ archive_name, method });
}

/// Checks a downloaded archive against the index's sha256 when there is one,
/// otherwise against ziglang.org's minisign signature for that file.
fn archiveVerified(
    io: Io,
    dir: Dir,
    archive_name: []const u8,
    release: *const LatestRelease,
    signature: ?[]const u8,
) !bool {
    if (release.sha_sum) |expected| {
        const actual = try sha256HexOfFile(io, dir, archive_name);
        if (std.mem.eql(u8, &actual, expected)) return true;
        std.log.info(
            "Hash mismatch for {s}:\nExpected {s}\nActual:   {s}",
            .{ archive_name, expected, actual },
        );
        return false;
    }
    const digest = try hashFile(std.crypto.hash.blake2.Blake2b512, io, dir, archive_name);
    verifyMinisign(signature.?, zig_minisign_key, &digest, archive_name) catch |err| {
        std.log.info("Signature check failed for {s}: {t}", .{ archive_name, err });
        return false;
    };
    return true;
}

fn fetchSignature(gpa: Allocator, client: *std.http.Client, tarball_url: []const u8) ![]u8 {
    const sig_url = try std.mem.concat(gpa, u8, &.{ tarball_url, ".minisig" });
    defer gpa.free(sig_url);
    return fetchBytes(gpa, client, sig_url) catch |err| switch (err) {
        error.HttpNotFound => return error.VersionNotOnServer,
        else => return err,
    };
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
    retain: Retain,
    live_real_path: ?[]const u8,
) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var it = versions_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }

    for (names.items) |name| {
        if (keepVersion(name, names.items, retain)) continue;
        // Never delete whatever directory currently backs the live zig
        // install, even if it isn't the recorded "active" version (the two
        // can drift, e.g. after a failed promotion). Deleting it out from
        // under a running/linked compiler is what corrupts installs.
        if (live_real_path) |live_real| protect: {
            const candidate_real = versions_dir.realPathFileAlloc(io, name, gpa) catch
                break :protect;
            defer gpa.free(candidate_real);
            if (pathIsWithin(candidate_real, live_real)) {
                std.log.info(
                    "Keeping {s}: currently backs the live zig install.",
                    .{name},
                );
                continue;
            }
        }
        std.log.info(
            "Pruning {s} (keep newest stable + newest nightly + pinned + active)",
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
    active: ?[]const u8,
    /// The slot this release takes (a newer stable or nightly), whose old
    /// occupant may then go; null for a pin, which takes no slot.
    replacing: ?Kind,
    release: *const LatestRelease,
) ![]u8 {
    if (try resolveVersionHome(gpa, io, zvc_dir, release.name)) |home| return home;

    const archive_name = std.fs.path.basenamePosix(release.tarball);
    try ensureArchiveDownloaded(gpa, io, client, downloads_dir, release, archive_name);

    const pinned = try readPointerFile(gpa, io, zvc_dir, pin_file);
    defer if (pinned) |p| gpa.free(p);
    try pruneVersionsIn(gpa, io, zvc_dir, .{
        .active = active,
        .pinned = pinned,
        .incoming = release.name,
        .replacing = replacing,
    });

    const version_rel = try std.fs.path.join(gpa, &.{ versions_subdir, release.name });
    defer gpa.free(version_rel);
    try zvc_dir.createDirPath(io, version_rel);
    var version_dir = try zvc_dir.openDir(io, version_rel, .{ .iterate = true });
    defer version_dir.close(io);

    std.log.info("Extract into {s}/{s}", .{ zvc_root, version_rel });
    try extractArchive(gpa, io, downloads_dir, archive_name, version_dir);

    const home_rel = try findZigHome(gpa, io, version_dir, version_rel);
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
        if (!try zigBuildTestPasses(io, zig_bin, project_path)) all_ok = false;
    }
    return all_ok;
}

/// Runs `<zig_bin> build test` in `project_path` and reports how it went.
fn zigBuildTestPasses(io: Io, zig_bin: []const u8, project_path: []const u8) !bool {
    const argv = [_][]const u8{ zig_bin, "build", "test" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = project_path },
    }) catch |err| {
        std.debug.print(" could not launch zig in {s}: {t}\n", .{ project_path, err });
        return false;
    };
    const term = try child.wait(io);
    if (switch (term) {
        .exited => |code| code == 0,
        else => false,
    }) {
        std.debug.print(" Ok\n", .{});
        return true;
    }
    std.debug.print(" Failed: {f}\n", .{term});
    return false;
}

fn pathVar(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    return environ_map.get("PATH") orelse //
        environ_map.get("Path") orelse //
        environ_map.get("path");
}

fn findLiveZigDir(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    const path_var = pathVar(environ_map) orelse return null;
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
            // No drive letter in the binary: release builds are checked for
            // `C:\` (see tools/check_dist.zig).
            const base = environ_map.get("LOCALAPPDATA") orelse //
                environ_map.get("USERPROFILE") orelse //
                return std.fs.path.join(gpa, &.{ environ_map.get("SystemDrive") orelse "C:", "zvc", "zig" });
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
        \\Dir will be created/reused; add it to PATH yourself.
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
    std.log.err("Zig {s}: {s}", .{ candidate_name, detail });
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "zig {s}: {s}",
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

/// After a nightly fails its tests: keep the live zig on a working version,
/// the previous nightly if it is on disk, else the latest stable.
fn syncLiveFallback(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    downloads_dir: Dir,
    environ_map: *const std.process.Environ.Map,
    client: *std.http.Client,
    index_root: std.json.Value,
    candidate_name: []const u8,
    previous_active: ?[]const u8,
) !void {
    const live_dir = try resolveLiveInstallPath(gpa, io, zvc_dir, environ_map);
    defer gpa.free(live_dir);

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
        .stable,
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
    clearPin(io, zvc_dir);

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
        .stable,
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
        null,
        .nightly,
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

// Pinned installs: `zvc install <version>` and `zvc install --from <project>`.
//
// A pin installs one exact version, makes it active and points the live zig
// at it. It stays until a plain `zvc` run or `zvc update` moves to the newest
// release, which clears the pin.
//
// Version folders kept: the newest stable and the newest nightly on disk (the
// two slots), plus the pinned version and the active one; see `keepVersion`.

/// The Zig Software Foundation's minisign key, as published on
/// ziglang.org/download. Every archive there has a `<archive>.minisig` beside it.
const zig_minisign_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
const zig_download_host = "https://ziglang.org";
const archive_ext = switch (builtin.os.tag) {
    .windows => "zip",
    else => "tar.xz",
};

/// Reads a one-line pointer file (`active-version.txt`, `pinned-version.txt`).
fn readPointerFile(gpa: Allocator, io: Io, zvc_dir: Dir, name: []const u8) !?[]u8 {
    const raw = zvc_dir.readFileAlloc(io, name, gpa, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

fn clearPin(io: Io, zvc_dir: Dir) void {
    zvc_dir.deleteFile(io, pin_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("Could not remove {s}/{s}: {t}", .{ zvc_root, pin_file, err }),
    };
}

const PinAction = enum { pin, unpin, keep };

const Activation = struct {
    name: []const u8,
    /// The version's zig home, relative to the cwd or absolute.
    home: []const u8,
    pin: PinAction,
    /// False only for a stable-channel update, whose live zig ZVC leaves alone.
    live: bool = true,
};

/// The one promotion step, used by updates, installs and the first-run setup.
/// It points the live zig at the new version first, so a failure leaves the old
/// version active and on disk; then records it as active and sets or clears
/// the pin; then prunes version folders and downloads nothing needs any more.
fn activateVersion(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    environ_map: *const std.process.Environ.Map,
    a: Activation,
) !void {
    if (a.live) {
        const live_dir = try resolveLiveInstallPath(gpa, io, zvc_dir, environ_map);
        defer gpa.free(live_dir);
        applyLiveInstall(gpa, io, live_dir, a.home) catch |err| {
            var buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &buf,
                "updating the live zig at {s} failed ({t}); the previous version stays active",
                .{ live_dir, err },
            ) catch "updating the live zig failed; the previous version stays active";
            try reportLiveInstallFailure(io, zvc_dir, a.name, detail);
            return error.LiveInstallFailed;
        };
        std.log.info("Live zig at {s} now points to {s}.", .{ live_dir, a.name });
        if (!dirIsOnPath(environ_map, live_dir)) std.log.warn(
            "{s} is not on PATH; add it so `zig` runs the live version.",
            .{live_dir},
        );
    }

    try zvc_dir.writeFile(io, .{ .sub_path = active_file, .data = a.name });
    switch (a.pin) {
        .pin => try zvc_dir.writeFile(io, .{ .sub_path = pin_file, .data = a.name }),
        .unpin => clearPin(io, zvc_dir),
        .keep => {},
    }

    const pinned = try readPointerFile(gpa, io, zvc_dir, pin_file);
    defer if (pinned) |p| gpa.free(p);
    try pruneVersionsIn(gpa, io, zvc_dir, .{ .active = a.name, .pinned = pinned });
    pruneDownloads(gpa, io, zvc_dir) catch |err| {
        std.log.warn("Could not prune {s}/{s}: {t}", .{ zvc_root, downloads_subdir, err });
    };
    std.log.info("Promoted zig version: {s} to active.\n", .{a.name});
}

fn pruneVersionsIn(gpa: Allocator, io: Io, zvc_dir: Dir, retain: Retain) !void {
    const live_real_path = currentLiveRealPath(gpa, io, zvc_dir);
    defer if (live_real_path) |p| gpa.free(p);
    var versions_dir = try zvc_dir.openDir(io, versions_subdir, .{ .iterate = true });
    defer versions_dir.close(io);
    try pruneVersions(gpa, io, versions_dir, retain, live_real_path);
}

const Kind = enum { stable, nightly };

fn versionKind(name: []const u8) Kind {
    return if (isNightlyVersionName(name)) .nightly else .stable;
}

const Retain = struct {
    active: ?[]const u8 = null,
    pinned: ?[]const u8 = null,
    /// The version being prepared.
    incoming: ?[]const u8 = null,
    /// Set while a newer stable or nightly is prepared: that slot's old
    /// occupant is then no longer protected (unless active or pinned).
    replacing: ?Kind = null,
};

/// Whether the version folder `name` stays. ZVC keeps two slots, the newest
/// stable and the newest nightly among `on_disk`, plus the pinned version, the
/// active one and the one being prepared. So at rest there are at most 2
/// folders, or 3 with a pin that is neither of the two.
fn keepVersion(name: []const u8, on_disk: []const []const u8, r: Retain) bool {
    for ([_]?[]const u8{ r.active, r.pinned, r.incoming }) |protected| {
        if (protected) |p| if (std.mem.eql(u8, p, name)) return true;
    }
    const version = std.SemanticVersion.parse(name) catch return false;
    const kind = versionKind(name);
    if (r.replacing) |slot| if (slot == kind) return false;
    for (on_disk) |other| {
        if (versionKind(other) != kind) continue;
        const other_version = std.SemanticVersion.parse(other) catch continue;
        if (other_version.order(version) == .gt) return false;
    }
    return true;
}

/// Deletes downloaded archives except those of a version folder still on
/// disk and of the pinned version.
fn pruneDownloads(gpa: Allocator, io: Io, zvc_dir: Dir) !void {
    var keep: std.ArrayList([]u8) = .empty;
    defer {
        for (keep.items) |name| gpa.free(name);
        keep.deinit(gpa);
    }
    {
        var versions_dir = try zvc_dir.openDir(io, versions_subdir, .{ .iterate = true });
        defer versions_dir.close(io);
        var it = versions_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try keep.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    if (try readPointerFile(gpa, io, zvc_dir, pin_file)) |pinned| {
        errdefer gpa.free(pinned);
        try keep.append(gpa, pinned);
    }

    var downloads_dir = zvc_dir.openDir(io, downloads_subdir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer downloads_dir.close(io);
    var doomed: std.ArrayList([]u8) = .empty;
    defer {
        for (doomed.items) |name| gpa.free(name);
        doomed.deinit(gpa);
    }
    var it = downloads_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (downloadIsKept(entry.name, keep.items)) continue;
        try doomed.append(gpa, try gpa.dupe(u8, entry.name));
    }
    for (doomed.items) |name| {
        std.log.info("Pruning old download {s}", .{name});
        downloads_dir.deleteFile(io, name) catch |err| {
            std.log.warn("Could not remove {s}: {t}", .{ name, err });
        };
    }
}

/// True if `file_name` is the archive of one of `versions`
/// (`zig-<target>-<version>.zip` or `.tar.xz`).
fn downloadIsKept(file_name: []const u8, versions: []const []const u8) bool {
    for (versions) |version| {
        for ([_][]const u8{ ".zip", ".tar.xz" }) |ext| {
            if (!std.mem.endsWith(u8, file_name, ext)) continue;
            const stem = file_name[0 .. file_name.len - ext.len];
            if (stem.len <= version.len or !std.mem.endsWith(u8, stem, version)) continue;
            if (stem[stem.len - version.len - 1] == '-') return true;
        }
    }
    return false;
}

fn dirIsOnPath(environ_map: *const std.process.Environ.Map, dir_path: []const u8) bool {
    const path_var = pathVar(environ_map) orelse return false;
    const want = std.mem.trimEnd(u8, dir_path, "/\\");
    var it = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (it.next()) |entry| {
        const have = std.mem.trimEnd(u8, entry, "/\\");
        const same = if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(have, want)
        else
            std.mem.eql(u8, have, want);
        if (same) return true;
    }
    return false;
}

/// The Zig version ZVC was last built and tested with. It is compiled in, so
/// a prebuilt ZVC can set up a machine with no Zig at all.
const known_good_zig = std.mem.trim(u8, @embedFile("known-good-zig.txt"), " \t\r\n");
/// The same record in the repo, relative to the ZVC repo root (the cwd).
const known_good_path = "src" ++ std.fs.path.sep_str ++ "known-good-zig.txt";

/// True if a live zig is set up or a zig is on PATH.
fn hasUsableZig(
    gpa: Allocator,
    io: Io,
    zvc_dir: Dir,
    environ_map: *const std.process.Environ.Map,
) !bool {
    if (try loadLiveDirConfig(gpa, io, zvc_dir)) |live| {
        defer gpa.free(live);
        if (Dir.cwd().openDir(io, live, .{})) |opened| {
            var dir = opened;
            defer dir.close(io);
            if (looksLikeZigInstallDir(io, dir)) return true;
        } else |_| {}
    }
    if (try findLiveZigDir(gpa, io, environ_map)) |found| {
        gpa.free(found);
        return true;
    }
    return false;
}

/// First run on a device with no zig: install exactly the known-good version
/// and make it live. If that build is gone from ziglang.org, say so and stop;
/// another version is only ever installed by an explicit command.
fn bootstrapKnownGood(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    zvc_dir: Dir,
    downloads_dir: Dir,
    environ_map: *const std.process.Environ.Map,
) !void {
    std.debug.print(
        "No zig found (no live install, none on PATH); installing ZVC's known-good zig {s}.\n",
        .{known_good_zig},
    );
    const active_version = try readPointerFile(gpa, io, zvc_dir, active_file);
    defer if (active_version) |v| gpa.free(v);

    const home = if (try resolveVersionHome(gpa, io, zvc_dir, known_good_zig)) |existing| existing else //
        fetchPinned(gpa, io, client, zvc_dir, downloads_dir, active_version, known_good_zig) catch |err| {
            if (err == error.VersionNotOnServer) std.log.err(
                \\ZVC's known-good zig {s} is no longer on ziglang.org, so nothing was installed.
                \\Choose a version explicitly: `ZVC update` installs the newest {t} build,
                \\`ZVC install <version>` a specific one (e.g. the latest stable listed in {s}).
            , .{ known_good_zig, channel, index_url });
            return err;
        };
    defer gpa.free(home);

    try activateVersion(gpa, io, zvc_dir, environ_map, .{
        .name = known_good_zig,
        .home = home,
        .pin = .keep,
    });
    std.debug.print(
        \\Zig {s} is live. Run `ZVC install --from <project>` to pin a project's version,
        \\or `ZVC update` to move to the newest {t} build.
        \\
    , .{ known_good_zig, channel });
}

/// After a promotion that passed its test projects: when ZVC runs from its
/// repo (the record file is in the cwd) and the new zig also builds and tests
/// ZVC, write it to the repo's known-good record for the owner to commit.
fn recordKnownGood(gpa: Allocator, io: Io, zig_bin: []const u8, name: []const u8) void {
    const cwd = Dir.cwd();
    const current = (readPointerFile(gpa, io, cwd, known_good_path) catch return) orelse return;
    defer gpa.free(current);
    if (std.mem.eql(u8, current, name)) return;

    std.debug.print("Checking that zig {s} builds and tests ZVC itself...\n", .{name});
    const ok = zigBuildTestPasses(io, zig_bin, ".") catch false;
    if (!ok) {
        std.log.warn("Zig {s} does not build/test ZVC; {s} stays at {s}.", .{ name, known_good_path, current });
        return;
    }
    var buf: [128]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "{s}\n", .{name}) catch return;
    cwd.writeFile(io, .{ .sub_path = known_good_path, .data = data }) catch |err| {
        std.log.warn("Could not update {s}: {t}", .{ known_good_path, err });
        return;
    };
    std.log.info("Recorded zig {s} as ZVC's known-good version in {s}; commit it.", .{ name, known_good_path });
}

/// Validates a Zig version such as `0.16.0` or `0.18.0-dev.1005+75d48dfff`.
/// It becomes a directory name and part of a URL, so only semver text passes.
fn parseVersion(text: []const u8) error{InvalidVersion}![]const u8 {
    const version = std.mem.trim(u8, text, " \t\r\n");
    if (version.len == 0 or version.len > 64) return error.InvalidVersion;
    for (version) |ch| switch (ch) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-', '+' => {},
        else => return error.InvalidVersion,
    };
    _ = std.SemanticVersion.parse(version) catch return error.InvalidVersion;
    return version;
}

fn archiveFileName(
    gpa: Allocator,
    triple: []const u8,
    version: []const u8,
    ext: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa, "zig-{s}-{s}.{s}", .{ triple, version, ext });
}

/// Where ziglang.org serves a build the index no longer lists: dev builds
/// under /builds/ (the same place the index's "master" entry points), tagged
/// releases under /download/<version>/. Releases are always in the index, so
/// in practice only dev builds take this path.
fn directTarballUrl(
    gpa: Allocator,
    triple: []const u8,
    version: []const u8,
    ext: []const u8,
) ![]u8 {
    const name = try archiveFileName(gpa, triple, version, ext);
    defer gpa.free(name);
    return if (isNightlyVersionName(version))
        std.fmt.allocPrint(gpa, "{s}/builds/{s}", .{ zig_download_host, name })
    else
        std.fmt.allocPrint(gpa, "{s}/download/{s}/{s}", .{ zig_download_host, version, name });
}

/// The index lists every tagged release by key, and only the newest dev
/// build (under "master"). Older dev builds return null.
fn findInIndex(
    gpa: Allocator,
    root: std.json.Value,
    triple: []const u8,
    version: []const u8,
) !?LatestRelease {
    if (root != .object) return error.BadIndex;
    const release_obj = root.object.get(version) orelse master: {
        const master = root.object.get("master") orelse return null;
        if (master != .object) return error.BadIndex;
        const name = master.object.get("version") orelse return null;
        if (name != .string or !std.mem.eql(u8, name.string, version)) return null;
        break :master master;
    };
    if (release_obj != .object) return error.BadIndex;
    const target = release_obj.object.get(triple) orelse return error.NoBuildForThisTarget;
    if (target != .object) return error.BadIndex;
    return try LatestRelease.initFromObjectMap(gpa, version, target.object);
}

fn resolvePinnedRelease(
    gpa: Allocator,
    client: *std.http.Client,
    version: []const u8,
) !LatestRelease {
    from_index: {
        std.debug.print("Looking for {s} in {s}...\n", .{ version, index_url });
        const bytes = fetchIndexJson(gpa, client) catch |err| {
            std.log.warn("Could not read the index ({t}); trying the direct URL.", .{err});
            break :from_index;
        };
        defer gpa.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| {
            std.log.warn("Could not parse the index ({t}); trying the direct URL.", .{err});
            break :from_index;
        };
        defer parsed.deinit();
        if (try findInIndex(gpa, parsed.value, target_info.triple, version)) |release| {
            std.debug.print("Found {s} in the index (sha256 check).\n", .{version});
            return release;
        }
        std.debug.print(
            "{s} is not in the index (it lists only the newest dev build); " ++
                "trying ziglang.org directly (minisign check).\n",
            .{version},
        );
    }
    const tarball = try directTarballUrl(gpa, target_info.triple, version, archive_ext);
    errdefer gpa.free(tarball);
    return .{
        .name = try gpa.dupe(u8, version),
        .tarball = tarball,
        .sha_sum = null,
    };
}

/// `zvc install <version>`, `zvc install --from <project dir | build.zig.zon>`,
/// or `zvc install --known-good <ZVC repo dir>` (the version in its
/// src/known-good-zig.txt, which may be newer than the one compiled in).
fn installArgs(gpa: Allocator, io: Io, args_it: *std.process.Args.Iterator) ![]u8 {
    const usage = "Usage: zvc install <version> | --from <project dir> | --known-good <ZVC repo dir>";
    const first = args_it.next() orelse {
        std.log.err("{s}", .{usage});
        return error.MissingVersion;
    };
    const version = if (std.mem.eql(u8, first, "--from")) from: {
        const project = args_it.next() orelse {
            std.log.err("{s}", .{usage});
            return error.MissingProjectPath;
        };
        break :from try readProjectZigVersion(gpa, io, project);
    } else if (std.mem.eql(u8, first, "--known-good")) known_good: {
        const repo = args_it.next() orelse {
            std.log.err("{s}", .{usage});
            return error.MissingProjectPath;
        };
        break :known_good try readRepoKnownGood(gpa, io, repo);
    } else try gpa.dupe(u8, parseVersion(first) catch |err| {
        std.log.err(
            "\"{s}\" is not a Zig version (e.g. 0.16.0 or 0.18.0-dev.1005+75d48dfff).",
            .{first},
        );
        return err;
    });
    errdefer gpa.free(version);
    if (args_it.next()) |extra| {
        std.log.err("Unexpected argument \"{s}\". {s}", .{ extra, usage });
        return error.UnexpectedArgument;
    }
    return version;
}

fn readProjectZigVersion(gpa: Allocator, io: Io, project_path: []const u8) ![]u8 {
    const zon_path = if (std.mem.endsWith(u8, project_path, ".zon"))
        try gpa.dupe(u8, project_path)
    else
        try std.fs.path.join(gpa, &.{ project_path, "build.zig.zon" });
    defer gpa.free(zon_path);

    const source = Dir.cwd().readFileAllocOptions(
        io,
        zon_path,
        gpa,
        .limited(1 << 20),
        .of(u8),
        0,
    ) catch |err| {
        std.log.err("Could not read {s}: {t}", .{ zon_path, err });
        return err;
    };
    defer gpa.free(source);

    const version = parseMinimumZigVersion(gpa, source) catch |err| {
        std.log.err("{s} has no usable minimum_zig_version ({t}).", .{ zon_path, err });
        return err;
    };
    std.debug.print("{s} asks for zig {s}\n", .{ zon_path, version });
    return version;
}

fn readRepoKnownGood(gpa: Allocator, io: Io, repo_path: []const u8) ![]u8 {
    var repo = Dir.cwd().openDir(io, repo_path, .{}) catch |err| {
        std.log.err("Could not open {s}: {t}", .{ repo_path, err });
        return err;
    };
    defer repo.close(io);
    const raw = (try readPointerFile(gpa, io, repo, known_good_path)) orelse {
        std.log.err("{s} has no {s}.", .{ repo_path, known_good_path });
        return error.NoKnownGoodRecord;
    };
    defer gpa.free(raw);
    const version = try gpa.dupe(u8, try parseVersion(raw));
    std.debug.print("{s} records known-good zig {s}\n", .{ repo_path, version });
    return version;
}

/// Reads `.minimum_zig_version` from build.zig.zon source; every other field
/// is ignored.
fn parseMinimumZigVersion(gpa: Allocator, source: [:0]const u8) ![]u8 {
    const Manifest = struct { minimum_zig_version: ?[]const u8 = null };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ParseZon => return error.InvalidBuildZon,
    };
    const raw = manifest.minimum_zig_version orelse return error.NoMinimumZigVersion;
    return gpa.dupe(u8, try parseVersion(raw));
}

fn doInstall(
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    version: []const u8,
) !void {
    const cwd = Dir.cwd();
    try cwd.createDirPath(io, zvc_root);
    var zvc_dir = try cwd.openDir(io, zvc_root, .{ .iterate = true });
    defer zvc_dir.close(io);
    try zvc_dir.createDirPath(io, downloads_subdir);
    try zvc_dir.createDirPath(io, versions_subdir);
    var downloads_dir = try zvc_dir.openDir(io, downloads_subdir, .{ .iterate = true });
    defer downloads_dir.close(io);

    const active_version = try readPointerFile(gpa, io, zvc_dir, active_file);
    defer if (active_version) |v| gpa.free(v);
    std.debug.print("Installing zig {s} for {s} (active now: {s})\n", .{
        version,
        target_info.triple,
        active_version orelse "none",
    });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // Already on disk (a re-pin, or the version an update left active):
    // no network needed.
    const home = if (try resolveVersionHome(gpa, io, zvc_dir, version)) |existing| existing else //
        fetchPinned(gpa, io, &client, zvc_dir, downloads_dir, active_version, version) catch |err| {
            if (err == error.VersionNotOnServer) std.log.err(
                \\Zig {s} for {s} is no longer on ziglang.org: dev builds are removed
                \\from /builds/ some time after they are superseded. Pick a version listed
                \\in {s}, or move the project's minimum_zig_version forward.
            , .{ version, target_info.triple, index_url });
            return err;
        };
    defer gpa.free(home);

    const zig_rel = try std.fs.path.join(gpa, &.{ home, target_info.exe_name });
    defer gpa.free(zig_rel);
    const zig_bin = try cwd.realPathFileAlloc(io, zig_rel, gpa);
    defer gpa.free(zig_bin);

    if (!try validateAgainstTestProjects(io, zig_bin)) {
        std.log.err(
            "Zig {s} failed the test projects; {s} stays active.",
            .{ version, active_version orelse "nothing" },
        );
        return error.CandidateFailedTests;
    }

    try activateVersion(gpa, io, zvc_dir, environ_map, .{
        .name = version,
        .home = home,
        .pin = .pin,
    });
    recordKnownGood(gpa, io, zig_bin, version);
    std.debug.print(
        \\Zig {s} is active and pinned.
        \\A plain `zvc` run or `zvc update` moves to the newest {t} release and drops the pin.
        \\
    , .{ version, channel });
}

fn fetchPinned(
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    zvc_dir: Dir,
    downloads_dir: Dir,
    active_version: ?[]const u8,
    version: []const u8,
) ![]u8 {
    const release = try resolvePinnedRelease(gpa, client, version);
    defer release.deinit(gpa);

    // A pin takes no slot: the newest stable and nightly stay beside it.
    return prepareVersion(
        gpa,
        io,
        client,
        zvc_dir,
        downloads_dir,
        active_version,
        null,
        &release,
    );
}

const MinisignError = error{
    BadSignatureFile,
    BadPublicKey,
    KeyIdMismatch,
    UnsupportedAlgorithm,
    SignatureMismatch,
    WrongFile,
};

fn decodeBase64Exact(comptime len: usize, text: []const u8) ?[len]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    if (size != len) return null;
    var out: [len]u8 = undefined;
    decoder.decode(&out, text) catch return null;
    return out;
}

/// Checks a minisign signature in the prehashed ("ED") form ziglang.org uses,
/// over a file whose BLAKE2b-512 digest is `file_digest`. Also requires the
/// signed trusted comment to name `file_name`, so a validly signed but
/// different build cannot stand in for the one asked for.
fn verifyMinisign(
    sig_file: []const u8,
    public_key: []const u8,
    file_digest: *const [64]u8,
    file_name: []const u8,
) MinisignError!void {
    const Ed25519 = std.crypto.sign.Ed25519;
    const untrusted_prefix = "untrusted comment: ";
    const trusted_prefix = "trusted comment: ";

    var lines = std.mem.splitScalar(u8, sig_file, '\n');
    var line: [4][]const u8 = undefined;
    for (&line) |*l| l.* = std.mem.trimEnd(u8, lines.next() orelse
        return error.BadSignatureFile, "\r");
    if (!std.mem.startsWith(u8, line[0], untrusted_prefix)) return error.BadSignatureFile;
    if (!std.mem.startsWith(u8, line[2], trusted_prefix)) return error.BadSignatureFile;
    const trusted = line[2][trusted_prefix.len..];

    const pk = decodeBase64Exact(42, public_key) orelse return error.BadPublicKey;
    if (!std.mem.eql(u8, pk[0..2], "Ed")) return error.BadPublicKey;
    const sig = decodeBase64Exact(74, line[1]) orelse return error.BadSignatureFile;
    if (!std.mem.eql(u8, sig[0..2], "ED")) return error.UnsupportedAlgorithm;
    if (!std.mem.eql(u8, sig[2..10], pk[2..10])) return error.KeyIdMismatch;
    const global = decodeBase64Exact(64, line[3]) orelse return error.BadSignatureFile;

    const key = Ed25519.PublicKey.fromBytes(pk[10..42].*) catch return error.BadPublicKey;
    Ed25519.Signature.fromBytes(sig[10..74].*).verify(file_digest, key) catch
        return error.SignatureMismatch;

    var verifier = Ed25519.Signature.fromBytes(global).verifier(key) catch
        return error.SignatureMismatch;
    verifier.update(sig[10..74]);
    verifier.update(trusted);
    verifier.verify() catch return error.SignatureMismatch;

    var fields = std.mem.splitScalar(u8, trusted, '\t');
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "file:") and
            std.mem.eql(u8, field["file:".len..], file_name)) return;
    }
    return error.WrongFile;
}

test "parseVersion accepts release and dev versions" {
    try std.testing.expectEqualStrings("0.16.0", try parseVersion("0.16.0"));
    try std.testing.expectEqualStrings(
        "0.18.0-dev.1005+75d48dfff",
        try parseVersion(" 0.18.0-dev.1005+75d48dfff\r\n"),
    );
}

test "parseVersion rejects non-versions and path tricks" {
    const bad = [_][]const u8{
        "",
        "master",
        "0.16",
        "latest",
        "../0.16.0",
        "0.16.0/../x",
        "0.16.0\\x",
        "0.16.0 x",
        "0.16.0-dev.1+abc:def",
        "0.16.0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    for (bad) |text| try std.testing.expectError(error.InvalidVersion, parseVersion(text));
}

test "direct URLs: dev builds under /builds, releases under /download" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { triple: []const u8, version: []const u8, ext: []const u8, url: []const u8 }{
        .{
            .triple = "x86_64-windows",
            .version = "0.18.0-dev.1005+75d48dfff",
            .ext = "zip",
            .url = "https://ziglang.org/builds/zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip",
        },
        .{
            .triple = "aarch64-windows",
            .version = "0.18.0-dev.1005+75d48dfff",
            .ext = "zip",
            .url = "https://ziglang.org/builds/zig-aarch64-windows-0.18.0-dev.1005+75d48dfff.zip",
        },
        .{
            .triple = "x86_64-linux",
            .version = "0.18.0-dev.1005+75d48dfff",
            .ext = "tar.xz",
            .url = "https://ziglang.org/builds/zig-x86_64-linux-0.18.0-dev.1005+75d48dfff.tar.xz",
        },
        .{
            .triple = "aarch64-macos",
            .version = "0.16.0",
            .ext = "tar.xz",
            .url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz",
        },
    };
    for (cases) |case| {
        const url = try directTarballUrl(gpa, case.triple, case.version, case.ext);
        defer gpa.free(url);
        try std.testing.expectEqualStrings(case.url, url);
    }
}

test "this build's target names its archive the way ziglang.org does" {
    const gpa = std.testing.allocator;
    const name = try archiveFileName(gpa, target_info.triple, "0.16.0", archive_ext);
    defer gpa.free(name);
    const expected = "zig-" ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++
        "-0.16.0." ++ (if (builtin.os.tag == .windows) "zip" else "tar.xz");
    try std.testing.expectEqualStrings(expected, name);
}

const test_sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const test_sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

test "findInIndex: releases by key, the newest dev build via master, older dev builds absent" {
    const gpa = std.testing.allocator;
    const index =
        \\{
        \\  "master": {
        \\    "version": "0.18.0-dev.1124+2ecf4b5e2",
        \\    "x86_64-windows": {
        \\      "tarball": "https://ziglang.org/builds/zig-x86_64-windows-0.18.0-dev.1124+2ecf4b5e2.zip",
        \\      "shasum": "
    ++ test_sha_a ++
        \\",
        \\      "size": "92937573"
        \\    }
        \\  },
        \\  "0.16.0": {
        \\    "x86_64-windows": {
        \\      "tarball": "https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip",
        \\      "shasum": "
    ++ test_sha_b ++
        \\"
        \\    }
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, index, .{});
    defer parsed.deinit();

    const release = (try findInIndex(gpa, parsed.value, "x86_64-windows", "0.16.0")).?;
    defer release.deinit(gpa);
    try std.testing.expectEqualStrings(test_sha_b, release.sha_sum.?);
    try std.testing.expectEqual(null, release.size);

    const master = (try findInIndex(gpa, parsed.value, "x86_64-windows", "0.18.0-dev.1124+2ecf4b5e2")).?;
    defer master.deinit(gpa);
    try std.testing.expectEqualStrings("0.18.0-dev.1124+2ecf4b5e2", master.name);
    try std.testing.expectEqualStrings(test_sha_a, master.sha_sum.?);
    try std.testing.expectEqual(92937573, master.size.?);

    try std.testing.expect(null == try findInIndex(gpa, parsed.value, "x86_64-windows", "0.18.0-dev.1005+75d48dfff"));
    try std.testing.expectError(
        error.NoBuildForThisTarget,
        findInIndex(gpa, parsed.value, "aarch64-windows", "0.16.0"),
    );
}

/// An index entry for this build's target, as ziglang.org lays it out.
fn testTargetEntry(comptime tarball: []const u8, comptime shasum: []const u8) []const u8 {
    return "\"" ++ target_info.triple ++ "\": { \"tarball\": " ++ tarball ++ ", \"shasum\": " ++ shasum ++ " }";
}

fn expectIndexError(comptime expected: anyerror, comptime find: anytype, json: []const u8) !void {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (find(gpa, parsed.value)) |release| {
        release.deinit(gpa);
        return error.TestExpectedError;
    } else |err| try std.testing.expectEqual(expected, err);
}

test "findMaster checks master.version with parseVersion and type-checks every field" {
    const gpa = std.testing.allocator;
    const good_target = comptime testTargetEntry("\"https://ziglang.org/builds/x.zip\"", "\"" ++ test_sha_a ++ "\"");
    const good = "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", " ++ good_target ++ " } }";
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, good, .{});
        defer parsed.deinit();
        const master = try LatestRelease.findMaster(gpa, parsed.value);
        defer master.deinit(gpa);
        try std.testing.expectEqualStrings("0.18.0-dev.1+abc", master.name);
    }
    const find = LatestRelease.findMaster;
    // A version that would be a path, or is not a version at all.
    try expectIndexError(error.InvalidVersion, find, "{ \"master\": { \"version\": \"../../evil\", " ++ good_target ++ " } }");
    try expectIndexError(error.InvalidVersion, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc/..\", " ++ good_target ++ " } }");
    try expectIndexError(error.InvalidVersion, find, "{ \"master\": { \"version\": \"master\", " ++ good_target ++ " } }");
    // Fields of the wrong type.
    try expectIndexError(error.BadIndex, find, "[]");
    try expectIndexError(error.BadIndex, find, "{ \"master\": [] }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": 5, " ++ good_target ++ " } }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", \"" ++ target_info.triple ++ "\": \"x\" } }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", " ++
        comptime testTargetEntry("7", "\"" ++ test_sha_a ++ "\"") ++ " } }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", " ++
        comptime testTargetEntry("\"http://ziglang.org/x.zip\"", "\"" ++ test_sha_a ++ "\"") ++ " } }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", " ++
        comptime testTargetEntry("\"https://ziglang.org/x.zip\"", "{}") ++ " } }");
    try expectIndexError(error.BadIndex, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", " ++
        comptime testTargetEntry("\"https://ziglang.org/x.zip\"", "\"abc\"") ++ " } }");
    // Missing fields.
    try expectIndexError(error.NoMasterEntry, find, "{}");
    try expectIndexError(error.MissingVersionField, find, "{ \"master\": {} }");
    try expectIndexError(error.NoBuildForThisTarget, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\" } }");
    try expectIndexError(error.MissingTarballField, find, "{ \"master\": { \"version\": \"0.18.0-dev.1+abc\", \"" ++
        target_info.triple ++ "\": { \"shasum\": \"" ++ test_sha_a ++ "\" } } }");
}

test "findLatestStable skips keys that are not versions and type-checks the release" {
    const gpa = std.testing.allocator;
    const target = comptime testTargetEntry("\"https://ziglang.org/download/0.16.0/x.zip\"", "\"" ++ test_sha_b ++ "\"");
    const index = "{ \"master\": {}, \"../9.9.9\": {}, \"0.15.2\": { " ++ target ++ " }, \"0.16.0\": { " ++ target ++ " } }";
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, index, .{});
    defer parsed.deinit();
    const stable = try LatestRelease.findLatestStable(gpa, parsed.value);
    defer stable.deinit(gpa);
    try std.testing.expectEqualStrings("0.16.0", stable.name);

    const find = LatestRelease.findLatestStable;
    try expectIndexError(error.BadIndex, find, "\"x\"");
    try expectIndexError(error.BadIndex, find, "{ \"0.16.0\": 1 }");
    try expectIndexError(error.BadIndex, find, "{ \"0.16.0\": { \"" ++ target_info.triple ++ "\": [] } }");
    try expectIndexError(error.NoStableVersionFound, find, "{ \"master\": {} }");
}

test "the index's declared size is read as a string or a number, anything else is an error" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { size: []const u8, want: anyerror!?u64 }{
        .{ .size = "\"47906164\"", .want = 47906164 },
        .{ .size = "47906164", .want = 47906164 },
        .{ .size = "\"-1\"", .want = error.BadIndex },
        .{ .size = "-1", .want = error.BadIndex },
        .{ .size = "[]", .want = error.BadIndex },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(gpa, "{{ \"tarball\": \"https://ziglang.org/x.zip\", \"shasum\": \"{s}\", \"size\": {s} }}", .{ test_sha_a, case.size });
        defer gpa.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        if (LatestRelease.initFromObjectMap(gpa, "0.16.0", parsed.value.object)) |release| {
            defer release.deinit(gpa);
            try std.testing.expectEqual(try case.want, release.size);
        } else |err| try std.testing.expectError(err, case.want);
    }
}

test "parseMinimumZigVersion reads a full build.zig.zon and ignores the rest" {
    const gpa = std.testing.allocator;
    const source =
        \\.{
        \\    .name = .app,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x9d5e988cabe0c3c0,
        \\    .minimum_zig_version = "0.18.0-dev.1005+75d48dfff",
        \\    .dependencies = .{
        \\        .sibling = .{ .path = "../sibling" },
        \\        .other = .{ .url = "https://example.invalid/x.tar.gz", .hash = "abc", .lazy = true },
        \\    },
        \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
        \\}
    ;
    const version = try parseMinimumZigVersion(gpa, source);
    defer gpa.free(version);
    try std.testing.expectEqualStrings("0.18.0-dev.1005+75d48dfff", version);
}

test "parseMinimumZigVersion errors" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.NoMinimumZigVersion,
        parseMinimumZigVersion(gpa, ".{ .name = .x, .version = \"0.0.0\" }"),
    );
    try std.testing.expectError(
        error.InvalidVersion,
        parseMinimumZigVersion(gpa, ".{ .minimum_zig_version = \"../../evil\" }"),
    );
    try std.testing.expectError(error.InvalidBuildZon, parseMinimumZigVersion(gpa, "not zon"));
}

/// Builds minisign files the way the minisign tool does, from a fixed test key.
const TestSigner = struct {
    const Ed25519 = std.crypto.sign.Ed25519;
    const encoder = std.base64.standard.Encoder;

    key_pair: Ed25519.KeyPair,
    key_id: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 },

    fn init() !TestSigner {
        return .{ .key_pair = try .generateDeterministic(@splat(7)) };
    }

    fn publicKey(self: TestSigner, buf: *[56]u8) []const u8 {
        var raw: [42]u8 = undefined;
        raw[0..2].* = "Ed".*;
        raw[2..10].* = self.key_id;
        raw[10..42].* = self.key_pair.public_key.toBytes();
        return encoder.encode(buf, &raw);
    }

    fn signatureFile(
        self: TestSigner,
        buf: []u8,
        alg: *const [2]u8,
        digest: []const u8,
        trusted: []const u8,
    ) ![]const u8 {
        const sig = (try self.key_pair.sign(digest, null)).toBytes();
        var raw: [74]u8 = undefined;
        raw[0..2].* = alg.*;
        raw[2..10].* = self.key_id;
        raw[10..74].* = sig;
        var global_msg: [64 + 256]u8 = undefined;
        global_msg[0..64].* = sig;
        @memcpy(global_msg[64..][0..trusted.len], trusted);
        const global = (try self.key_pair.sign(global_msg[0 .. 64 + trusted.len], null)).toBytes();
        var raw_b64: [100]u8 = undefined;
        var global_b64: [88]u8 = undefined;
        return std.fmt.bufPrint(buf, "untrusted comment: test key\n{s}\ntrusted comment: {s}\n{s}\n", .{
            encoder.encode(&raw_b64, &raw),
            trusted,
            encoder.encode(&global_b64, &global),
        });
    }
};

test "verifyMinisign accepts a good signature and rejects tampering" {
    const signer = try TestSigner.init();
    var pk_buf: [56]u8 = undefined;
    const pk = signer.publicKey(&pk_buf);

    var digest: [64]u8 = undefined;
    std.crypto.hash.blake2.Blake2b512.hash("archive bytes", &digest, .{});
    const name = "zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip";
    const trusted = "timestamp:1700000000\tfile:" ++ name ++ "\thashed";

    var buf: [512]u8 = undefined;
    const good = try signer.signatureFile(&buf, "ED", &digest, trusted);
    try verifyMinisign(good, pk, &digest, name);

    // A different file.
    var other: [64]u8 = digest;
    other[0] ^= 1;
    try std.testing.expectError(error.SignatureMismatch, verifyMinisign(good, pk, &other, name));

    // A validly signed archive for another version.
    try std.testing.expectError(
        error.WrongFile,
        verifyMinisign(good, pk, &digest, "zig-x86_64-windows-0.16.0.zip"),
    );

    // An edited trusted comment.
    var edited_buf: [512]u8 = undefined;
    const edited = edited_buf[0..good.len];
    @memcpy(edited, good);
    const at = std.mem.indexOf(u8, edited, "1700000000").?;
    edited[at] = '2';
    try std.testing.expectError(error.SignatureMismatch, verifyMinisign(edited, pk, &digest, name));

    // The legacy, non-prehashed form.
    var legacy_buf: [512]u8 = undefined;
    const legacy = try signer.signatureFile(&legacy_buf, "Ed", &digest, trusted);
    try std.testing.expectError(error.UnsupportedAlgorithm, verifyMinisign(legacy, pk, &digest, name));

    // Another key.
    var other_signer = try TestSigner.init();
    other_signer.key_id = .{ 9, 9, 9, 9, 9, 9, 9, 9 };
    var other_pk_buf: [56]u8 = undefined;
    const other_pk = other_signer.publicKey(&other_pk_buf);
    try std.testing.expectError(error.KeyIdMismatch, verifyMinisign(good, other_pk, &digest, name));

    try std.testing.expectError(error.BadSignatureFile, verifyMinisign("junk", pk, &digest, name));
}

test "verifyMinisign accepts a real ziglang.org signature with the built-in key" {
    // zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip.minisig as served by
    // ziglang.org, and the BLAKE2b-512 of that zip.
    const sig_file = "untrusted comment: signature from minisign secret key\n" ++
        "RUSGOq2NVecA2Q2FZXWo6dZh2r9ZtL5makiXyR21NBkhTnyf872sRb3doHMERNTb78M/ufvl+0ZWdY5xuG3XI2UYnspRjgXh4A8=\n" ++
        "trusted comment: timestamp:1794397335\tfile:zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip\thashed\n" ++
        "uUxLs9akVtHmb+3c4fsHPrWCSahNa+Vn/Cuy44um1NYMNDjPrNBcmGhcAGHWfGFjwlFbIG23DUQyQlE0umPVCQ==\n";
    var digest: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &digest,
        "96eaa95ea7fc6b39ae563374b81509d7d481c62ffb27aa379bea36c26f4e629e" ++
            "7d86279cc1c0fbb5e6990ad2b6b750bb1dab558a2e395c7cd9ac1e80b35e7e70",
    );
    const name = "zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip";
    try verifyMinisign(sig_file, zig_minisign_key, &digest, name);
    digest[63] ^= 1;
    try std.testing.expectError(
        error.SignatureMismatch,
        verifyMinisign(sig_file, zig_minisign_key, &digest, name),
    );
}

test "keepVersion: two slots, plus the pin and the active version" {
    const disk = [_][]const u8{
        "0.16.0",
        "0.17.1",
        "0.18.0-dev.900+aaaaaaaaa",
        "0.18.0-dev.1005+75d48dfff",
        "0.18.0-dev.1124+2ecf4b5e2",
        "junk",
    };
    const pin = "0.18.0-dev.1005+75d48dfff";

    // At rest with a pin: newest stable, newest nightly, the pin.
    const at_rest: Retain = .{ .active = pin, .pinned = pin };
    const expect_rest = [_]bool{ false, true, false, true, true, false };
    for (disk, expect_rest) |name, keep| try std.testing.expectEqual(keep, keepVersion(name, &disk, at_rest));

    // Without a pin, the nightly active: just the two slots.
    const plain: Retain = .{ .active = "0.18.0-dev.1124+2ecf4b5e2" };
    const expect_plain = [_]bool{ false, true, false, false, true, false };
    for (disk, expect_plain) |name, keep| try std.testing.expectEqual(keep, keepVersion(name, &disk, plain));

    // Preparing a newer nightly frees the nightly slot, but not the pin.
    const next_nightly: Retain = .{
        .active = pin,
        .pinned = pin,
        .incoming = "0.18.0-dev.1200+bbbbbbbbb",
        .replacing = .nightly,
    };
    const expect_next = [_]bool{ false, true, false, true, false, false };
    for (disk, expect_next) |name, keep| try std.testing.expectEqual(keep, keepVersion(name, &disk, next_nightly));

    // Installing a pin evicts neither slot.
    const new_pin: Retain = .{ .active = pin, .pinned = pin, .incoming = "0.15.2" };
    try std.testing.expect(keepVersion("0.17.1", &disk, new_pin));
    try std.testing.expect(keepVersion("0.18.0-dev.1124+2ecf4b5e2", &disk, new_pin));
}

test "downloadIsKept matches whole versions only" {
    const keep = [_][]const u8{ "0.18.0-dev.1005+75d48dfff", "1.0.0" };
    try std.testing.expect(downloadIsKept("zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip", &keep));
    try std.testing.expect(downloadIsKept("zig-aarch64-macos-1.0.0.tar.xz", &keep));
    try std.testing.expect(!downloadIsKept("zig-x86_64-linux-11.0.0.tar.xz", &keep));
    try std.testing.expect(!downloadIsKept("zig-x86_64-windows-0.18.0-dev.1124+2ecf4b5e2.zip", &keep));
    try std.testing.expect(!downloadIsKept("1.0.0.zip", &keep));
    try std.testing.expect(!downloadIsKept("zig-x86_64-windows-1.0.0.zip.minisig", &keep));
}

test "pruneVersions and pruneDownloads on a scratch zvc folder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const zvc_dir = tmp.dir;

    const versions = [_][]const u8{ "0.17.0", "0.17.1", "0.18.0-dev.1005+75d48dfff", "0.18.0-dev.1124+2ecf4b5e2" };
    for (versions) |v| {
        const rel = try std.fs.path.join(gpa, &.{ versions_subdir, v, "lib" });
        defer gpa.free(rel);
        try zvc_dir.createDirPath(io, rel);
        const zip = try std.fmt.allocPrint(gpa, "zig-x86_64-windows-{s}.zip", .{v});
        defer gpa.free(zip);
        const zip_rel = try std.fs.path.join(gpa, &.{ downloads_subdir, zip });
        defer gpa.free(zip_rel);
        try zvc_dir.createDirPath(io, downloads_subdir);
        try zvc_dir.writeFile(io, .{ .sub_path = zip_rel, .data = "x" });
    }
    try zvc_dir.writeFile(io, .{ .sub_path = downloads_subdir ++ "/zig-x86_64-windows-0.16.0.zip", .data = "x" });
    try zvc_dir.writeFile(io, .{ .sub_path = pin_file, .data = "0.18.0-dev.1005+75d48dfff\n" });

    try pruneVersionsIn(gpa, io, zvc_dir, .{ .active = "0.18.0-dev.1124+2ecf4b5e2", .pinned = "0.18.0-dev.1005+75d48dfff" });
    try pruneDownloads(gpa, io, zvc_dir);

    var versions_dir = try zvc_dir.openDir(io, versions_subdir, .{});
    defer versions_dir.close(io);
    var downloads_dir = try zvc_dir.openDir(io, downloads_subdir, .{});
    defer downloads_dir.close(io);
    for (versions, [_]bool{ false, true, true, true }) |v, kept| {
        const exists = if (versions_dir.access(io, v, .{})) |_| true else |_| false;
        try std.testing.expectEqual(kept, exists);
        const zip = try std.fmt.allocPrint(gpa, "zig-x86_64-windows-{s}.zip", .{v});
        defer gpa.free(zip);
        const zip_exists = if (downloads_dir.access(io, zip, .{})) |_| true else |_| false;
        try std.testing.expectEqual(kept, zip_exists);
    }
    try std.testing.expectError(error.FileNotFound, downloads_dir.access(io, "zig-x86_64-windows-0.16.0.zip", .{}));
}

test "the known-good record is a valid version" {
    _ = try parseVersion(known_good_zig);
}

test "the built-in Zig key decodes as a minisign Ed25519 key" {
    const pk = decodeBase64Exact(42, zig_minisign_key).?;
    try std.testing.expectEqualStrings("Ed", pk[0..2]);
    _ = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pk[10..42].*);
}
