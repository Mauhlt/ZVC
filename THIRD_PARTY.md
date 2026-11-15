# Third-party material

ZVC's own code is under the MIT license in `LICENSE`. It contains or relies on
the following material from others.

## Zig standard library
ZVC is written against, and its binaries contain parts of, the Zig standard
library (HTTP client, TLS, zip/tar/xz extraction, SHA-256, BLAKE2b, Ed25519).
- Source: https://ziglang.org
- License: MIT, Copyright (c) Zig contributors

## Zig Software Foundation signing key
`zig_minisign_key` in `src/main.zig` is the Zig Software Foundation's public
minisign key, as published on https://ziglang.org/download/. ZVC uses it to
verify every archive it downloads from ziglang.org.

## ziglang.org signature test fixture
The test "verifyMinisign accepts a real ziglang.org signature with the built-in
key" in `src/main.zig` embeds the signature file
`zig-x86_64-windows-0.18.0-dev.1005+75d48dfff.zip.minisig` as served by
ziglang.org, and the BLAKE2b-512 digest of that archive. Both were published by
the Zig Software Foundation.

## minisign signature format
ZVC verifies signatures in the minisign format (prehashed Ed25519, "ED"),
designed by Frank Denis (https://jedisct1.github.io/minisign/, ISC license).
ZVC implements the check itself in Zig; no minisign code is included.
