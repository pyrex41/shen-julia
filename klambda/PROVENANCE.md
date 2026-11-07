# Kernel provenance

shen-julia vendors the 23 community ShenOSKernel 43.4 files, as released by
`Shen-Language/shen-sources` tag `shen-43.4`, byte-for-byte in
the kernel directories (`klambda/`, `sources/`, `tests/`, `lib/`, `doc/`,
`extensions/`, and `assets/`). This file is the sole local addition in that
tree (`doc/evidence/` is also local).

- Repo: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
- Release: `shen-43.4` (tag object `40fd335893cf`, commit `f34b307b490880eedcfe1f5e5d3cc24ca3d2602e`)
- Archive: `ShenOSKernel-43.4.tar.gz`, from
  https://github.com/Shen-Language/shen-sources/releases/download/shen-43.4/ShenOSKernel-43.4.tar.gz
- Archive SHA-256: `15e7972e6bf0cd65d37c2eba85750b8839d2dbadda41027eae0c88e5017a2756`
- Previous import: the `shen-43.2` release archive, SHA-256
  `23c71508f0de24785e1f127ea4fab440081904d81c463090bc642ee840417f32`
- `(version)` is `"43.4"`.

The port interface is public: ports provide `char-stream?` (arity 1),
`read-unit-string` (arity 1), and `write-string` (arity 2). Shen/Julia uses
byte-oriented streams, so `char-stream?` returns false and the character
operations report unsupported stream errors.
