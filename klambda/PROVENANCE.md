# Kernel provenance

shen-julia vendors the community **ShenOSKernel 42.2** release byte-for-byte.
The following directories are copies of the release tree with nothing added
or removed (this file is the only exception):

`klambda/`, `sources/`, `tests/`, `lib/`, `doc/`, `extensions/`, `assets/`.

- Repo: [`Shen-Language/shen-sources`](https://github.com/Shen-Language/shen-sources)
- Tag: `shen-42.2`
- Commit: `73507e069fe147aefb728d632c4ce40bc6a7b314` (2026-10-01, "Prepare Shen kernel 42.2 release")
- Release asset: `ShenOSKernel-42.2.tar.gz`
- Archive SHA-256: `1d02273003654d34ec020ae67cb214ecec410dee3350419ff807d82b652678d8`
  (the checksum pinned in shen-scheme 0.50's Makefile)
- `(version)` is `"42.2"` (set by `shen.initialise-environment` in `init.kl`).
  shen-julia reports it unchanged; human-facing docs say "ShenOSKernel 42.2".

This is the kernel that upstream [shen-scheme 0.50](https://github.com/tizoc/shen-scheme/tree/v0.50)
ships, so shen-julia and shen-scheme run the same KLambda.

To check the tree, unpack the tarball and run, for each directory `D` above,
`diff -r ShenOSKernel-42.2/D D`; the only difference is this file.

## Lineage choice: community kernel, adopted wholesale

Tracking issue pyrex41/shen-julia#10 (umbrella pyrex41/bifrost#26,
pyrex41/yggdrasil#32) offered two options:

- **(a) adopt ShenOSKernel-42.2 wholesale** -- chosen (the same choice as
  shen-go and shen-cl);
- (b) port the 42.1/42.2 changes onto Tarver's S42.0 base as a derived kernel.

Option (a) replaces the Tarver lineage shen-julia vendored from 2026-07-14
(S41.2 refresh) to 2026-10 (S42.0); see "History" below. Consequences:

- **`shen.initialise` is back.** Every 42.2 `.kl` file is a plain list of
  `(defun …)` forms, so load order no longer matters. All state (globals,
  `*property-vector*`, arities, lambda forms, signatures, `*macros*`) is built
  by `Boot.initialise!`, which calls `shen.initialise`, then
  `shen.x.features.initialise` with `[shen/julia]` (as shen-cl registers
  `shen/cl`), then `stlib.initialise`.
- **`*property-vector*` is a `shen.dict`** (`dict.kl`). `get`/`put`/`unput`,
  `arity`, `fn` and `update-lambda-table` stay the kernel's own KL
  definitions; shen-julia has no native that reads the property store, so
  nothing was written against Tarver's plain-vector layout. Lambda forms live
  in the dict under `shen.lambda-form`; redefining a function with zero or
  unknown arity drops the stale form (42.0 requirement) and `(fn F)`, partial
  and dynamic application see the new definition.
- **Standard library = `klambda/stlib.kl`.** The precompiled StLib is baked
  with the kernel by `bin/gen_kernel.jl` and initialised by `stlib.initialise`
  (doc/port-upgrades.md, 41.1). `lib/stlib/` holds the matching 42.2 sources;
  the old `bin/gen_stlib.jl` (compile Tarver's Lib/StLib from source) is
  retired.
- Loaded extensions: `features`, `expand-dynamic`, `launcher` (as in shen-cl).
  `namespaces`, `type-annotations` and `programmable-pattern-matching` are
  vendored but not loaded.

## Native overrides and the 42.1 reader / macroexpand audit

shen-julia replaces only these kernel functions (`Compiler.NATIVE_OVERRIDES`,
`Prims.NATIVE_IMPLS`): `reverse`, `length`, `append` (iterative, same results
and errors) and `pr` (`*hush*` silences only `*stoutput*`, never a file
stream; otherwise the 42.2 `writer.kl` definition). It does not override
`read`, `lineread`, `read-file`, `shen.read-loop`, `shen.try-parse`,
`shen.my-read-byte`, `macroexpand` or `shen.macroexpand-h`, so the 42.1
source-form expansion order and the 4-argument `shen.macroexpand-h` are the
kernel's own. The `read-byte` primitive returns `-1` at end of stream, so
input at EOF with no trailing newline is read (checked for `script`, `load`,
`read-file` and `(read (stinput))`).

## History

- 2026-10: ShenOSKernel 42.2 (this file).
- 2026-08-27 to 2026-10: Mark Tarver's Shen 42.0 (S42, 2026-08-25).
  Archive `https://www.shenlanguage.org/Download/S42.zip`, SHA-256
  `30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23`,
  canonical mirror tag `s42-pristine-20260825`. `(version)` was `"42"`.
  The StLib came from the same archive (`Lib/StLib`), compiled from source by
  `bin/gen_stlib.jl`. `extension-launcher.kl` was retained from the community
  kernel because Tarver's distribution has none.
- 2026-07-14 to 2026-08: Tarver's S41.2 (2026-07-11 refresh), mirror tag
  `s41.2-pristine-20260711`.
- Before 2026-07-14: community ShenOSKernel 41.2.
