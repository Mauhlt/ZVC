# ZVC - Zig version control 
## How to run 
1. Clone repo to a directory
2. Ensure zig is installed: https://ziglang.org/download/
3. Run the following command inside your terminal
- inside main.zig, change the enum from stable to nightly to change default
```zig 
zig build run
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
