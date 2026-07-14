# Shen/Julia

A [Julia](https://julialang.org) port of the **Shen 41.2** language kernel.

> **Kernel lineage:** as of the `kernel/tarver-s41-refresh` work this vendors Mark
> Tarver's **S41.2 (2026-07-11 refresh)** — a restructured kernel that reuses the
> "41.2" version string but is a different lineage from the community
> `ShenOSKernel-41.2`. `(version)` still reports `"41.2"`. Details, provenance and
> the delta are in [`klambda/PROVENANCE.md`](klambda/PROVENANCE.md).

Shen programs compile to native Julia methods (one `K_<name>` method per Shen
function), so once warmed up this port runs compute-bound code **6–16× faster
than the reference SBCL port** (`shen-cl`) and passes the full official kernel
test suite **134/134**.

> **Heads-up about startup:** Julia compiles to native code *on first use*, so a
> from-source start spends ~10 s booting the kernel and the *first* call into the
> reader/evaluator pays a one-time JIT cost. The fix is a **sysimage** (a
> prebuilt, fully-native snapshot) — see [Startup time & sysimages](#startup-time--sysimages).
> With a sysimage, startup is ~0.5–1.5 s.

---

## Requirements

- **Julia 1.12** (the prebuilt release sysimages are pinned to this version — a
  sysimage built for one Julia minor version will not load on another; CI and
  the from-source path are only tested on 1.12).
- No other dependencies; `Project.toml`/`Manifest.toml` pin everything.

## Install

```bash
git clone git@github.com:pyrex41/shen-julia.git
cd shen-julia
julia --project=. -e 'import Pkg; Pkg.instantiate()'   # one-time dep install
```

The launcher is `bin/shen` (a thin shell wrapper around `julia`). Put `bin/` on
your `PATH` or call it directly.

## Quick start

```bash
# Evaluate an expression (prints the value)
./bin/shen eval -e "(+ 40 2)"                 # => 42

# Load a file, then evaluate against it
./bin/shen eval -l myprog.shen -e "(main)"

# Run a program quietly (no defun echo)
./bin/shen script myprog.shen

# Interactive REPL (Ctrl-D / EOF exits cleanly)
./bin/shen

# Version banner (contains 41.2)
./bin/shen --version
```

The CLI mirrors the *standard* Shen launcher (`shen.x.launcher.main`), so the
`eval` / `script` / `--version` flags behave the same as on `shen-go`,
`shen-rust`, and `ShenScript`.

From Julia directly:

```julia
using ShenJulia
boot!(false)
run_kl_string("(define square X -> (* X X))")
run_kl_string("(square 12)")   # => 144
```

---

## Startup time & sysimages

This is the one thing to understand about a Julia-hosted language.

| Path | Boot | First `eval`/`script` | When it's used |
|------|-----:|----------------------:|----------------|
| **From source** (no sysimage) | ~10 s | + one-time JIT of reader/evaluator | `SHEN_JULIA_NO_SYSIMAGE=1`, or no `.sys` present |
| **With sysimage** | ~0.5–1.5 s | negligible | default when `ShenJulia.sys` exists |

Why: the kernel’s ~1130 functions are **baked ahead of time** into the package
(`src/kernel_generated.jl`) so Julia’s precompilation turns them into real native
methods — there is no per-startup `Core.eval` of the kernel. What a plain start
*can’t* avoid is Julia loading the package image and JIT-compiling the
reader/printer/evaluator on their first call. A **sysimage** captures all of that
as a native snapshot, so startup is dominated by process spin-up.

`bin/shen` automatically uses `./ShenJulia.sys` if it is present. Controls:

```bash
SHEN_JULIA_SYSIMAGE=/path/to/ShenJulia.sys ./bin/shen ...   # explicit image
SHEN_JULIA_NO_SYSIMAGE=1 ./bin/shen ...                      # force the slow source path
```

### Get a sysimage

**Option A — download a prebuilt one** (recommended). Release assets are named
`ShenJulia-<os>-<arch>-julia<ver>.sys`. Download the one matching your platform
**and Julia version**, then drop it in the repo root as `ShenJulia.sys`:

```bash
# example for macOS arm64 on Julia 1.12
curl -L -o ShenJulia.sys \
  https://github.com/pyrex41/shen-julia/releases/latest/download/ShenJulia-macos-aarch64-julia1.12.sys
./bin/shen --version    # now boots in ~1s
```

> A sysimage is tied to the **OS, CPU architecture, and Julia minor version** it
> was built for. If the download doesn’t match yours, build locally (Option B).
> A mismatched image fails to load (or, for a too-aggressive CPU target, can
> crash with an illegal-instruction error) — that’s the cue to rebuild.

**Option B — build locally** (a few minutes, significant RAM, one-time):

```bash
julia --project=. bin/build_sysimage.jl
# writes ./ShenJulia.sys, tuned natively for THIS machine
```

---

## Baking *your* program into a fast-start sysimage

If you have a Shen program you run often and want it to start in ~1 s with its
own functions already native-compiled, bake a program-specific sysimage:

```bash
julia --project=. bin/build_app_sysimage.jl myprog.shen myprog.sys
```

This loads `myprog.shen` at build time, exercises it, and snapshots the result.
Run your program against it:

```bash
SHEN_JULIA_SYSIMAGE=myprog.sys ./bin/shen script myprog.shen
# or call a specific entry point:
SHEN_JULIA_SYSIMAGE=myprog.sys ./bin/shen eval -l myprog.shen -e "(main)"
```

For most programs the **base** `ShenJulia.sys` is already enough: boot is ~1 s and
loading your `.shen` on top is fast. Reach for a program-specific image only when
you want the program’s *own* functions precompiled too (tightest startup, e.g. a
CLI tool invoked repeatedly).

For an even more self-contained artifact (a tree-shaken kernel slice + your
program, optionally as its own sysimage), see the Ratatoskr builder
`bin/ratatoskr-build.jl`.

---

## Status

- **Kernel:** Shen **41.2** (`(version)` reports `"41.2"`).
- **Tests:** official `tests/kerneltests.shen` passes **134/134** via
  `julia --project=. bin/run_canonical.jl` (loads `harness.shen` +
  `kerneltests.shen` exactly as upstream does).
- **Performance** (vs `shen-cl`/SBCL, the reference; per-trial median):

  | benchmark | shen-julia | shen-cl |
  |-----------|-----------:|--------:|
  | tak / fib / ack (compute) | 2.2 / 2.4 / 8.2 ms | 33 / 39 / 53 ms |
  | iota 100k | ~16 ms | 16.5 ms |
  | map / sum (allocation-heavy) | 1.25–1.78× cl | — |

  Compute-bound code is several times faster than SBCL; the only place SBCL still
  wins is allocation-heavy list code, because SBCL tags fixnums as immediates
  while Julia heap-boxes integers stored in `Any`.

## Building from source / for developers

The kernel is **baked ahead of time** — after changing any `klambda/*.kl` file or
the compiler’s codegen you must regenerate it:

```bash
julia --project=. bin/gen_kernel.jl    # regenerate src/kernel_generated.jl + kernel_*.jls
# then bump the "[baked-kernel guard vN]" marker in src/Prims.jl (Julia does not
# track the generated file as a precompile dependency), then rebuild the sysimage:
julia --project=. bin/build_sysimage.jl
```

The **standard library** (Tarver's `Lib/StLib`, vendored under `lib/stlib/`) is
baked the same way — it ships as Shen *source*, so a from-source load costs ~50 s;
`bin/gen_stlib.jl` compiles it once into `src/stlib_generated.jl` (loaded at boot at
~no cost). After changing `lib/stlib/**` regenerate it and bump the
`[baked-stlib guard vN]` marker in `src/Prims.jl`:

```bash
julia --project=. bin/gen_stlib.jl     # regenerate src/stlib_generated.jl + kernel_stlib_arity.jls
```

Repository layout:

| Path | Role |
|------|------|
| `src/ShenJulia.jl` | Main module, `boot!`, `run_kl_string`, REPL |
| `src/Runtime.jl` | Symbols, `NIL`/`Cons`/`AbsVector`, streams, KL reader |
| `src/Compiler.jl` | KL → Julia codegen; `INLINE_PRIM` hot-path inlines |
| `src/Prims.jl` | Host primitives, `APP`/`PARTIAL`, `eval_kl`, baked-kernel include |
| `src/Boot.jl` | Kernel load (baked fast path + source fallback), `shen.initialise` |
| `src/kernel_generated.jl` | **auto-generated** baked 41.2 kernel (do not edit) |
| `src/stlib_generated.jl` | **auto-generated** baked standard library (do not edit) |
| `bin/shen`, `bin/shen.jl` | CLI launcher |
| `bin/gen_kernel.jl` | Ahead-of-time kernel generator |
| `bin/gen_stlib.jl` | Ahead-of-time standard-library generator (from `lib/stlib/`) |
| `lib/stlib/` | Vendored Shen standard library (Tarver `Lib/StLib`; see `lib/stlib/PROVENANCE.md`) |
| `bin/build_sysimage.jl` | Base sysimage builder (honours `SHEN_SYSIMAGE_CPU_TARGET`) |
| `bin/build_app_sysimage.jl` | Bake a user `.shen` into its own sysimage |
| `bin/ratatoskr-build.jl` | Ratatoskr stage-2 standalone-artifact builder |
| `bin/run_canonical.jl` | Run the official kerneltests harness (134/134) |
| `klambda/` | Vendored Shen kernel sources (Tarver S41.2 2026-07-11 refresh; see `klambda/PROVENANCE.md`) |
| `tests/` | Official Shen test suite + sample programs |

---

## About Shen

Shen is [Mark Tarver’s](http://www.marktarver.com/) functional programming
language. This repository is a **port of its kernel**, intended for developers
working on Shen itself and for running Shen programs on the Julia runtime. For a
general-purpose environment, beginners should start at the
[main website](https://shenlanguage.org) and the
[mailing list](https://groups.google.com/forum/#!forum/qilang); other complete
implementations include the SBCL port and
[Shen/Scheme](https://github.com/tizoc/shen-scheme).

Language documentation: [shendoc](http://shenlanguage.org/shendoc.htm).

神
