# Kernel provenance

shen-julia vendors the 23 community ShenOSKernel 43.1 files, as built at upstream
`Shen-Language/shen-sources` master `ec16a9f` (the 43.1 release plus the type checker's
deref-once change, shen-sources#117), byte-for-byte in
the kernel directories (`klambda/`, `sources/`, `tests/`, `lib/`, `doc/`,
`extensions/`, and `assets/`). This file is the sole local addition in that
tree.

- Repo: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
- Upstream commit: `ec16a9f` (merge of shen-sources#117), on top of tag `shen-43.1`
  (`715824a52b55e9c81a9501df8548ff3edd8411f5`)
- Archive: `ShenOSKernel-43.1-ec16a9f.tar.gz`, unmodified upstream sources built with the
  repo's `make klambda`/`make release`, from
  https://github.com/pyrex41/shen-sources/releases/tag/upstream-ec16a9f
- Archive SHA-256: `060066a8f84d9a2f7d41cb3b37b986a8d4653279752b739b5063cd648d9baacd`
- Previous import: the `shen-43.1` release archive, SHA-256
  `900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`
- `(version)` is `"43.1"`.

The 43.1 port interface is public: ports provide `char-stream?` (arity 1),
`read-unit-string` (arity 1), and `write-string` (arity 2). Shen/Julia uses
byte-oriented streams, so `char-stream?` returns false and the character
operations report unsupported stream errors.
