# Kernel provenance

These `klambda/*.kl` files are the vendored Shen language kernel that shen-julia
bakes ahead of time (see `bin/gen_kernel.jl`, `src/kernel_generated.jl`).

## Current source: Mark Tarver's "S41.2" refresh (2026-07-11)

Canonical source (what these files were vendored from):

- Repo: `pyrex41/shen-s41.1` — the canonical mirror of Tarver's shenlanguage.org
  uploads (one tag per import).
- Tag: `s41.2-pristine-20260711`
- Commit: `11fc51bdf53a4dcb505adeec6ec8352754cbe50f`
- The `KLambda/*.kl` there are byte-identical to the archive below; `.shen`
  originals under `sources/` are from the archive's `Sources/`.

Upstream origin (secondary detail):

- URL: https://www.shenlanguage.org/Download/S41.2.zip
- Last-Modified: 2026-07-11
- sha256 (zip): `51becbfd60fa8c93c3f8ae5b20b948eaa84c4b1d14ad2f5d2a056002a53ee836`

### Caveat: reused version number, different lineage

Upstream **reused the version string "41.2"** for a *restructured* kernel. This
is NOT the community `ShenOSKernel-41.2` (github.com/Shen-Language/shen-sources,
tag `shen-41.2`) that earlier shen-julia releases vendored. It is a distinct
lineage — refer to it as **"S41.2 (2026-07-11 refresh)"**. `(version)` still
reports `"41.2"` (upstream keeps the string), so cross-port goldens are
unaffected.

### What changed vs the community 41.2 kernel

Boot order (from `sources/make.shen`):

    yacc core load prolog reader sequent sys t-star toplevel track types
    writer backend declarations   (then)   macros

- **NEW**: `backend.kl` — a `cl.*` KLambda→Common-Lisp backend. Irrelevant to
  the Julia runtime; baked for completeness/parity only.
- **REMOVED** `init.kl` — there is no longer a `shen.initialise` function.
  Initialisation is done by *top-level forms* that run at load time:
  `declarations.kl` creates `*property-vector*`, `*macros*`, the arity table,
  the external-symbol table and the lambda table; `types.kl` runs 161 top-level
  `(declare ...)` forms. (`shen.initialise_environment`, note the underscore,
  now only resets the `shen.*call*`/`shen.*infs*` counters.)
- **REMOVED** `dict.kl` — `*property-vector*` is now a plain `(vector 20000)`.
  `put`/`get` live in `sys.kl` and use `shen.change-pointer-value` /
  `shen.remove-pointer` over hash-bucketed association lists.
- **REMOVED** `compiler.kl` — the community `shen-cl.*` CL backend; superseded by
  `backend.kl`.
- **REMOVED** `stlib.kl` — the standard library is externalised to lazy Shen
  sources under the archive's `Lib/StLib` and is NOT part of the kernel.

### Local additions kept on top of upstream

- `extension-launcher.kl` — community launcher extension providing
  `shen.x.launcher.main` (the `eval` / `script` / `--version` CLI). NOT part of
  Tarver's distribution, but shen-julia's `bin/shen` and the Ratatoskr stage-1
  driver depend on it, so it is retained. Self-contained; verified to reference
  no removed kernel function except `shen.repl` on the interactive `launch-repl`
  path (which shen-julia handles host-side in `bin/shen.jl`, so it is not hit by
  `eval`/`script`).

Dropped community extensions: `extension-expand-dynamic.kl` (called the renamed
`shen.initialise-lambda-forms` → incompatible), `extension-features.kl` and
`extension-programmable-pattern-matching.kl` (orphaned; not loaded).
