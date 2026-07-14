# StLib provenance

These are Mark Tarver's Shen **standard library** sources, vendored so shen-julia
can bake them ahead of time (see `bin/gen_stlib.jl`, `src/stlib_generated.jl`).

## Source

- Canonical mirror: `pyrex41/shen-upstream` (formerly `pyrex41/shen-s41.1`; old
  URLs redirect), tag **`s41.2-pristine-20260711`**, from the archive's
  `Lib/StLib/`.
- Upstream origin: https://www.shenlanguage.org/Download/S41.2.zip
  (Last-Modified 2026-07-11).
- Same lineage as the vendored kernel — Tarver's S41.2 (2026-07-11 refresh); see
  `klambda/PROVENANCE.md`.

## Layout

The library is organised by package (`package-stlib.shen`): `list string maths
vector symbol tuple file print`, loaded by `install.shen` (which type-checks it,
toggling `(tc +/-)`). Subdirectories: `Lists/`, `Strings/`, `Maths/` (incl. the
`rationals`/`complex`/`numerals` datatypes), `Vectors/`, `Symbols/`, `Tuples/`,
`IO/`, `Calendar/`, `Data/`.

## How shen-julia uses it

Unlike the community `ShenOSKernel-41.2` (which shipped a pre-compiled
`stlib.kl`), Tarver's refresh ships the stdlib as **Shen source**. A from-source
`(load "install.shen")` costs ~50 s, so `bin/gen_stlib.jl` compiles it once —
recording every KL `(defun …)` the load produces and re-emitting them through the
same `cdefun_parts` path the kernel uses — into `src/stlib_generated.jl`
(precompiled/baked, ~no boot cost). `_register_baked_stlib!()` wires the methods
into `F`/`ARITY` at boot and registers their arities in the kernel
`*property-vector*` so function-reference use (`(fn filter)`, higher-order calls)
resolves.

No StLib source required patching to load on shen-julia.
