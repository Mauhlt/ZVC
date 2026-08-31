# ZVC - Zig version control 
Goals: 
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

Live-install sync pass (nightly only):
10. Find/track a dir meant to be on user's PATH, keep it pointing at whichever version is currently live 
11. Fallback chain on fail: 
revert to previous nightly if on disk -> fall to latest stable -> print an error + append to log file if also fails 
12. First-run config: 
- if no live dir known + none found on PATH, prompt user for one (with suggested default) 
- validate new dir choice 
- persist choice so future runs don't ask again

## Gotchas: 
1. Archives don't extract flat 
- wrapper dir name =/= stable 
- don't hardcode `zig-<version>-<target>`
- extract into dir -> look at inside - needs 1 entry + dir or its flat 
2. std.fs.path.basename uses *native* separator - urls don't 
- download URL = `/`-delimited
- taking its basename on windows with platform-aware basename() = wrong 
- use posix variant for anything that isn't a real filesystem 
3. Spawn child `argv[0]` resolved before `cwd` is applied
- silently causes `FileNotFound` error 
- resolve compiler binary to abs path first 
4. Hash-check both branches, not just download 
- verify archive you fetched 
- re-verify the cache hit before trusting it 
5. Windows symlinks need priviledge to process but doesn't have it - a dir junction doesn't 
- `Dir.symlink` call for a dir failed with `PermissionDenied` in a normal non-elevated non-dev-mode session 
6. Delete a link =/= same op as deleting what it points at 
- 

