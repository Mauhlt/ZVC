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
current directory. A prebuilt binary is `zvc-<arch>-<os>[.exe]`; one built from
source is `zig-out/bin/ZVC[.exe]`.

| Command | What it does |
| --- | --- |
| `zvc` (or `zig build run`) | Update to the newest nightly, keep the newest stable beside it, and drop any pin. On a machine with no Zig, install the known-good Zig instead and stop |
| `zvc update` | The same update, but on a machine with no Zig it goes straight to the newest nightly |
| `zvc install <version>` | Download, verify, activate and pin that exact version, e.g. `zvc install 0.18.0-dev.1005+75d48dfff` |
| `zvc install --from <project>` | The same, for the `minimum_zig_version` in `<project>/build.zig.zon` (a path to a `.zon` file works too) |
| `zvc install --known-good <ZVC repo>` | The same, for the version in that repo's `src/known-good-zig.txt` |
| `zvc version` | Print the known-good Zig compiled into this ZVC |
| `zvc reset` | Wipe versions and downloads, re-seed latest stable + master, promote nothing, clear the pin |

With `zig build run`, pass arguments after `--`: `zig build run -- install --from ../Portal`.

**A plain `zvc` run moves off a pin.** Don't run plain `zvc` (or `zvc update`)
on a device that must stay on a pinned version; re-pin with `zvc install --from`
if you do.

### Known-good Zig
`src/known-good-zig.txt` holds the Zig version ZVC was last built and tested
with, and every ZVC binary embeds it. When ZVC promotes a version (an update or an
install) whose test projects pass, and it is running from its repo, it runs
`zig build test` on ZVC with the new compiler; if that passes, it writes the
version to `src/known-good-zig.txt`. Commit that change: pushing it to main is
what triggers a release.

On a machine with no live Zig and no `zig` on PATH, a plain `zvc` run installs
exactly that version and makes it live. If ziglang.org no longer has it, ZVC says
so and installs nothing; then choose explicitly with `zvc update` or
`zvc install <version>`.

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

### Which versions stay on disk
ZVC keeps two slots, the **newest stable** and the **newest nightly** in
`.zvc/versions/`, plus the **pinned** version and the **active** one. Usually
the active version is the nightly or the pin, so at rest that is 2 folders, or 3
while a pin is set that is neither the newest stable nor the newest nightly. A
pin never evicts the stable or the nightly.

- An update downloads a newer nightly into the nightly slot (and a newer stable
  into the stable slot); the slot's old version goes once it is no longer active.
- While a new version is prepared, the outgoing active version stays until the new
  one is live, so there can briefly be one folder more.
- The folder the live zig points at is never deleted.
- `.zvc/downloads/` keeps only the archives of the versions on disk and of the pin.

### Promotion
Updates and installs promote the same way: point the live zig at the new
version first, then write `.zvc/active-version.txt` (and set or clear
`.zvc/pinned-version.txt`), then prune folders and downloads. If pointing the
live zig fails, the previous version stays active and on disk.

## New device
Download the prebuilt ZVC for the machine from the latest release
(`<repo>` is this repository's GitHub URL):

| Machine | Download |
| --- | --- |
| Windows x86_64 | `<repo>/releases/latest/download/zvc-x86_64-windows.exe` |
| Windows on ARM (aarch64) | `<repo>/releases/latest/download/zvc-aarch64-windows.exe` |
| Linux x86_64 | `<repo>/releases/latest/download/zvc-x86_64-linux` |
| Linux aarch64 | `<repo>/releases/latest/download/zvc-aarch64-linux` |
| macOS Intel | `<repo>/releases/latest/download/zvc-x86_64-macos` |
| macOS Apple silicon | `<repo>/releases/latest/download/zvc-aarch64-macos` |

1. Clone ZVC and, next to it, the project that needs a specific Zig (e.g. Portal).
   Put the downloaded binary in the ZVC folder (on Linux and macOS, `chmod +x` it).
2. From the ZVC folder, either:
   - `zvc-x86_64-windows.exe` installs the known-good Zig and makes it live, or
   - `zvc-x86_64-windows.exe install --from ..\Portal` installs and pins the
     project's Zig directly.

   On first use ZVC asks where the live zig should go (Enter accepts the
   suggestion). Add that folder to PATH, then open a new terminal.
3. Check with `zig version`. Now ZVC can also be built from source: `zig build`.

Without a release, build ZVC from source with its known-good Zig (from
`https://ziglang.org/builds/` or `/download/`, run by full path, not on PATH,
because ZVC replaces a zig it finds on PATH with a link to the version it manages).

## Release builds
- `zig build dist` cross-builds stripped ReleaseSafe binaries for the six targets
  into `zig-out/dist/zvc-<arch>-<os>[.exe]`.
- `zig build check-dist` builds them and fails if any contains `/home/runner`,
  `Users\`, `C:\` or `/Users/` (an absolute build path).
- `zig build check-zig` fails unless the running zig is the known-good version.
- `zig build release-info` writes the release tag (`v<UTC date>-zig<version>`) and
  notes to `zig-out/release/`.

`.github/workflows/release.yml` runs these on ubuntu-latest when a push to main
changes `src/known-good-zig.txt` (or on a manual run). It installs the
known-good Zig with the previous release's `zvc-x86_64-linux`, runs `check-zig`,
`test`, `check-dist` and `release-info`, then creates a release marked latest
with the six binaries. Any failing step means no release.

Because the workflow uses the previous release's ZVC, the first release has to
be made by hand, once, with the known-good Zig on PATH:
```terminal
zig build check-zig test check-dist release-info
gh release create <tag from zig-out/release/tag.txt> zig-out/dist/* --notes-file zig-out/release/notes.md --latest
```

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
