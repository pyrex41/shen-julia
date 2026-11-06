# Kernel provenance

shen-julia vendors the 23 community ShenOSKernel 43.2 files, as released by
`Shen-Language/shen-sources` tag `shen-43.2`, byte-for-byte in
the kernel directories (`klambda/`, `sources/`, `tests/`, `lib/`, `doc/`,
`extensions/`, and `assets/`). This file is the sole local addition in that
tree (`doc/evidence/` is also local).

- Repo: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
- Release: `shen-43.2` (tag object `7b7563e5`, commit `e6947f507ebc`)
- Archive: `ShenOSKernel-43.2.tar.gz`, from
  https://github.com/Shen-Language/shen-sources/releases/download/shen-43.2/ShenOSKernel-43.2.tar.gz
- Archive SHA-256: `23c71508f0de24785e1f127ea4fab440081904d81c463090bc642ee840417f32`
- Previous import: `ShenOSKernel-43.1-ec16a9f.tar.gz`, SHA-256
  `060066a8f84d9a2f7d41cb3b37b986a8d4653279752b739b5063cd648d9baacd`
- `(version)` is `"43.2"`.

The port interface is public: ports provide `char-stream?` (arity 1),
`read-unit-string` (arity 1), and `write-string` (arity 2). Shen/Julia uses
byte-oriented streams, so `char-stream?` returns false and the character
operations report unsupported stream errors.
