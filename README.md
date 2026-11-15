# ZVC - Zig version control 
## How to run 
1. Clone repo to a directory
2. Ensure zig is installed: https://ziglang.org/download/
3. Run the following command inside your terminal
- inside main.zig, change the enum from stable to nightly to change default
```zig 
zig build run
```
4. Verify by opening a new terminal and typing the following: 
```terminal 
where.exe zig
zig version
```
- shows where zig is installed on windows + what version zig is installed

## Commands
Run these from the ZVC repo root: ZVC keeps its state in `.zvc/` under the
current directory (`zig-out/bin/ZVC.exe` on Windows, `zig-out/bin/ZVC` elsewhere).

| Command | What it does |
| --- | --- |
| `ZVC` (or `zig build run`) | Update to the newest release of the default channel, unless a version is pinned |
| `ZVC install <version>` | Download, verify, activate and pin that exact version, e.g. `ZVC install 0.18.0-dev.1005+75d48dfff` |
| `ZVC install --from <project>` | The same, for the `minimum_zig_version` in `<project>/build.zig.zon` (a path to a `.zon` file works too) |
| `ZVC update` | Update to the newest release even when pinned, and clear the pin once it is promoted |
| `ZVC reset` | Wipe versions and downloads, re-seed latest stable + master, promote nothing, clear the pin |

With `zig build run`, pass arguments after `--`: `zig build run -- install --from ../Portal`.

### Where `install` finds a version
1. `ziglang.org/download/index.json`: every tagged release, plus the newest dev
   build (`master`). Downloads found here are checked against the index's sha256.
2. Otherwise the build's direct URL: `https://ziglang.org/builds/zig-<arch>-<os>-<version>.<zip|tar.xz>`
   for dev builds, `https://ziglang.org/download/<version>/...` for releases. The
   index only lists the newest dev build, so older ones come from here. These are
   checked against the `.minisig` signature beside the archive, using the Zig
   Software Foundation's public key built into ZVC; the signed comment must name
   the requested file.
3. ziglang.org deletes superseded dev builds after a while. If the signature is
   gone, `install` stops with an error saying so, and nothing is changed.

A version already in `.zvc/versions/` is activated without any network access.

### Pinning and updates
- `install` writes `.zvc/active-version.txt` and `.zvc/pinned-version.txt`, points
  the live zig at the new version, then removes the previous active version's
  directory. If the download, check or live-dir update fails, the previous
  version stays active and on disk.
- The 2-directory cap still applies: while installing, ZVC keeps the active
  version (and whatever the live zig points at) and prunes any other directory.
  The pinned version is the active one, so the cap never removes it.
- A plain `ZVC` run with a pin set prints the pin and exits without touching the
  network or disk, so a scheduled or habitual run will not move a project off the
  version it needs.
- `ZVC update` is the normal update with the pin overridden: it fetches the newest
  release, promotes it as usual (removing the pinned directory) and clears the pin.
  If the new version fails its test projects, the pinned version stays active.
- Downloads in `.zvc/downloads/` are kept, so re-pinning after an update re-verifies
  the cached archive instead of downloading it again.

## New device
1. Clone ZVC, and next to it the project that needs a specific Zig (e.g. Portal).
2. Download any recent Zig from https://ziglang.org/download/ into a temporary
   folder and do not put it on PATH; ZVC replaces a zig it finds on PATH with a
   link to the version it manages. If the newest build no longer compiles ZVC,
   download the version the project pins instead, e.g.
   `https://ziglang.org/builds/zig-<arch>-<os>-0.18.0-dev.1005+75d48dfff.<zip|tar.xz>`.
3. Build ZVC with it, from the ZVC folder:
   ```terminal
   <temp folder>\zig.exe build
   ```
4. Install the project's Zig:
   ```terminal
   zig-out\bin\ZVC.exe install --from ..\Portal
   ```
   On first use ZVC asks where the live zig should go (Enter accepts the
   suggestion). Add that folder to PATH, then open a new terminal.
5. Check with `zig version` and delete the temporary Zig.

Supported targets: Windows, Linux and macOS on x86_64 and aarch64 (including
Windows on ARM laptops). The archive is `.zip` on Windows and `.tar.xz` elsewhere.

## Core (first pass)
1. Comptime platform detection:
- platforms
    - windows 
    - macos 
    - linux 
- arch
    - x86_64 
    - arm
2. Fetch `ziglang.ord/download/index.json`
- pick a release 
    - stable = highest semver key, skip `master` key
    - nightly = `master`, no order logic, just what's in index right now
3. Download tarball/zig for current platform target 
4. Extract
- .tar.xz on linux/macos 
- .zip on windows
- into .zvm/versions/<version>/
5. Run configuration 
- zig build test against list of projects using candidate compiler before trusting it 
6. Success = promote, Failure = Reject
- Promote: write active version pointer + delete old version directory 
- Reject: keep old active, leave candidate on disk, print clear breaking-change message

## Harden Pass (2nd pass - 1st pass = success)
7. sha256 verification
- check fresh download against `shasum`
- re-check cached download before trusting it = guard against corrupted partial download sitting in cache
8. Disk cap: nevel keep more than 2 version directories at once (active + newest candidate)
- prune everything else before extracting new candidate
9. `reset` subcommand 
- wipe `.zvm/versions` + `.zvm/downloads` 
- re-seed with fresh copy of latest master + latest nightly 
- promote nothing 
- start clean escape hatch

## Live-install sync pass (nightly only):
10. Find/track a dir meant to be on user's PATH, keep it pointing at whichever version is currently live 
11. Fallback chain on fail: 
revert to previous nightly if on disk -> fall to latest stable -> print an error + append to log file if also fails 
12. First-run config: 
- if no live dir known + none found on PATH, prompt user for one (with suggested default) 
- validate new dir choice 
- persist choice so future runs don't ask again
