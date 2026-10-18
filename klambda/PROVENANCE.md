# Kernel provenance

shen-julia vendors the 23 official community ShenOSKernel 43.1 release files byte-for-byte in
the kernel directories (`klambda/`, `sources/`, `tests/`, `lib/`, `doc/`,
`extensions/`, and `assets/`). This file is the sole local addition in that
tree.

- Repo: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
- Tag: `shen-43.1`
- Commit: `715824a52b55e9c81a9501df8548ff3edd8411f5`
- Release archive SHA-256: `900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`
- `(version)` is `"43.1"`.

The 43.1 port interface is public: ports provide `char-stream?` (arity 1),
`read-unit-string` (arity 1), and `write-string` (arity 2). Shen/Julia uses
byte-oriented streams, so `char-stream?` returns false and the character
operations report unsupported stream errors.
