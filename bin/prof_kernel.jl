#!/usr/bin/env julia
# Profile representative kerneltests-style workloads: Prolog search (einstein)
# and the typechecker. Prints @time (allocations) and a flat profile summary.

using Pkg
Pkg.activate(dirname(@__DIR__))

using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
using Profile

const G = Prims.GLOBALS

t0 = time()
boot!(false)
println("boot: $(round(time() - t0, digits=2))s")

G["shen.*tc*"] = false
G["*tc*"] = false
fn = isdefined(Prims, :setfn!) ? Prims.setfn! : (n, f) -> (Prims.F[n] = f)
fn("y-or-n?", Prims.MKFUN(1, _ -> true))

fc(x) = Prims.force(x)
sheval(s) = begin
    forms = Base.invokelatest(F["read-from-string"], s)
    fc(Base.invokelatest(F["eval"], forms isa Cons ? forms.h : forms))
end

cd(joinpath(dirname(@__DIR__), "tests")) do
    # --- workload 1: Prolog backtracking (einstein) ---
    fc(Base.invokelatest(F["load"], "einsteins-riddle.shen"))
    println("\n--- einstein riddle (Prolog search) ---")
    @time r = sheval("(prolog? (riddle))")
    println("result: ", Runtime.to_str(r))

    # --- workload 2: typechecker on a small function ---
    println("\n--- typecheck small fn (tc +) ---")
    G["shen.*tc*"] = true
    G["*tc*"] = true
    @time r2 = sheval("(define my-rev {(list A) --> (list A)} [] -> [] [X | Xs] -> (append (my-rev Xs) [X]))")
    println("result: ", Runtime.to_str(r2))
    @time r3 = sheval("(my-rev [1 2 3 4 5])")
    println("result: ", Runtime.to_str(r3))
    G["shen.*tc*"] = false
    G["*tc*"] = false

    # --- profile einstein ---
    println("\n--- profile (einstein) ---")
    Profile.clear()
    Profile.@profile sheval("(prolog? (riddle))")
    Profile.print(format=:flat, sortedby=:count, mincount=50, noisefloor=2)
end
