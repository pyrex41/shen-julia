# Shen/Julia — handoff (2026-06-08)

Julia port of the **Shen 41.1** kernel. Architecture mirrors [shen-lua](https://github.com/pyrex41/shen-lua): KLambda sources compile to Julia, `Core.eval` loads them at boot, ~35 KL primitives live in the host runtime.

## Quick start

```bash
# Boot kernel only (~60s first run; includes precompile)
julia --project=. bin/shen.jl --boot-only

# Smoke tests (primitives + define via eval)
julia --project=. run-tests.jl

# REPL (boots then prompts)
julia --project=. bin/shen.jl
```

```julia
using ShenJulia
boot!(false)
using ShenJulia.Runtime
Base.invokelatest(F["eval"], read_all("(define square X -> (* X X))")[1])
Base.invokelatest(F["square"], 12)  # => 144
```

## Repository layout

| Path | Role |
|------|------|
| `src/ShenJulia.jl` | Main module, `boot!`, REPL |
| `src/Runtime.jl` | Symbols, `NIL`, `Cons`, `AbsVector`, streams, KL reader |
| `src/Compiler.jl` | KL → Julia codegen (`ctail`/`cexpr`, `if`/`and`/`or`) |
| `src/Prims.jl` | ~35 primitives, `APP`/`PARTIAL`/`MKFUN`, `eval_kl`, `F`/`FA` tables |
| `src/Boot.jl` | Load 21 `klambda/*.kl` files, streams, `shen.initialise` |
| `bin/shen.jl` | CLI entry (`--boot-only`, REPL) |
| `klambda/` | Vendored Shen 41.1 kernel (21 `.kl` files) |
| `tests/` | Official Shen test suite (`harness.shen`, `kerneltests.shen`, …) |
| `run-tests.jl` | Smoke tests + optional harness load |
| `doc/porting.md` | Upstream porting guide |

Remote: `git@github.com:pyrex41/shen-julia.git`

## What works

- **Full kernel boot** — all 21 `klambda/*.kl` files compile and load; `shen.initialise` completes.
- **Version** — reports `"41.1"`.
- **KL primitives** — arithmetic, lists, vectors, streams, globals, errors, etc.
- **Compiler** — statement-based codegen for `defun`, `if`, `cond`, `let`, `do`, `and`, `or`, currying via `APP`/`PARTIAL`.
- **Smoke tests** — `+`, `cons`/`equal`, `(define …)` through `F["eval"]`.
- **Simple Shen reads** — `(+ 1 2)`, `(define foo X -> X)`, small `package` forms via `read-file`.

## What does not work yet

### 1. Loading `.shen` files (certification blocker)

`(load "harness.shen")` / `read-file` on the full official harness fails:

```
reader error near here: (package test-harnes
```

Underlying yacc partial-parse residue starts at `(package test-harness …)`. Simple forms and truncated harness prefixes parse OK; the complete `tests/harness.shen` does not. This blocks `kerneltests.shen` (134 official reports).

### 2. Julia world age (partially addressed)

Runtime-generated functions (yacc `compile`, `eval`, `define`) need `Base.invokelatest`. Applied in:

- `APP` (function calls)
- `Boot.initialise!`
- `eval_kl` result eval
- `run_kl_string` → `F["eval"]`

May still need `invokelatest` in `PARTIAL`/`MKFUN` closures and `thaw` paths.

### 3. Missing port primitives

Not yet defined (shen-lua provides these; required by `reader.kl` / `writer.kl`):

- `shen.char-stinput?` → should return `false` (byte streams)
- `shen.char-stoutput?` → should return `false`

File `read-byte` works without them; interactive `lineread` and `pr` string paths may not.

### 4. Test harness wiring

Before running the suite (once `load` works):

- Seed `*macros*` if `shen.initialise-environment` missed it
- Alias `*tc*` ← `shen.*tc*`
- Stub `y-or-n?` to always return `true` (non-interactive)
- `cd` into `tests/` so relative `(load "foo.shen")` resolves

See `run-tests.jl` and shen-lua `run-41.1-tests.lua` for reference.

### 5. 41.1 compiler hardening (future)

shen-lua needed extra codegen for 41.1 certification. Not ported yet:

- Strict literal hoisting (don’t hoist side-effecting forms)
- `MKTREE` for deep cons trees (~7k cells in stlib)
- Freeze/`BIND` hoisting (Prolog CPS chains)
- Let-floating, right-spine call-chain flattening

Boot succeeds without these; heavy `kerneltests` workloads may not.

### 6. Tail recursion

Julia has no native TCO. Deep recursion needs backend loop transforms (SBCL/shen-go style). Not implemented.

## Major bugs fixed in this session

1. **`ccall` reserved** — compiler helper renamed to `kl_call`.
2. **`if`/`or`/`and` codegen** — nested `if`/`else` with `begin`/`end` wrappers; `and`/`or` use nested trees (not broken `elseif` flattening).
3. **Unique `kl_fnN` names** — reused `function impl` overwrote `FA` arity table.
4. **`AbsVector` constructor** — `make_absvector(n, fill)` instead of recursive constructor.
5. **`is_lit` hoisting** — exclude symbols in `ARITY` / specials from `KDATA` hoisting.
6. **`eval_kl` atoms** — self-evaluate symbols, vectors, streams (like shen-lua).
7. **`APP` world age** — `Base.invokelatest` on calls.

## Performance

- **Boot**: ~55–65s (dominated by compiling 21 KL files + Julia precompile on cold start).
- **Primitives only** (no kernel): ~1s module load.

## Suggested next steps (priority order)

1. Add `shen.char-stinput?` / `shen.char-stoutput?` to `Prims.jl`.
2. Finish world-age audit (`PARTIAL`, `MKFUN`, `thaw`).
3. Debug full `harness.shen` yacc parse (bisect forms after line 24; check `shen.*residue*` / parser state).
4. Wire test driver; run `kerneltests.shen`; fix failures iteratively.
5. Port shen-lua 41.1 compiler optimizations as failures demand.
6. Optional: sysimage for faster boot, TCO transforms, shen-julia-specific README.

## References

- Porting guide: `doc/porting.md`, [GitHub](https://github.com/Shen-Language/shen-sources/blob/master/doc/porting.md)
- Reference port: `/Users/reuben/projects/shen/shen-lua` (certified 134/134 on 41.1)
- Go port: `pyrex41/shen-go` (AOT compiled)