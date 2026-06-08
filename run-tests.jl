#!/usr/bin/env julia
# Driver to boot the Shen 41.1 kernel and run basic verification.

using Pkg
Pkg.activate(@__DIR__)

using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims

println("Loading Shen 41.1 kernel...")
t0 = time()
boot!(get(ENV, "SHEN_VERBOSE", "") == "1")
t1 = time()
println("  boot: $(round(t1 - t0, digits=3))s")
println("Kernel initialised. Version: ", F["version"]())

# Basic smoke tests
println("\n=== Smoke tests ===")

@assert F["+"](3, 4) == 7
@assert equal(cons(intern("a"), NIL), cons(intern("a"), NIL))
println("  primitives: ok")

form = read_all("(define smoke-test X -> (* X X))")[1]
Base.invokelatest(F["eval"], form)
@assert Base.invokelatest(F["smoke-test"], 5) == 25
println("  eval define: ok")

# Seed *macros* if initialise missed it (known issue across ports)
macros_fn = get(F, "shen.macros", nothing)
if macros_fn !== nothing && !haskey(GLOBALS, "*macros*")
    entry = cons(cons(intern("shen.macros"), macros_fn), NIL)
    GLOBALS["*macros*"] = cons(entry, NIL)
    println("  note: manually seeded *macros*")
end

if haskey(GLOBALS, "shen.*tc*") && !haskey(GLOBALS, "*tc*")
    GLOBALS["*tc*"] = GLOBALS["shen.*tc*"]
end

# Try loading official test harness if available
tests_dirs = [
    "tests",
    "../cl-source/ShenOSKernel-41.1/tests",
    joinpath(@__DIR__, "tests"),
]
local tests_dir = nothing
for d in tests_dirs
    if isfile(joinpath(d, "harness.shen"))
        global tests_dir = d
        break
    end
end

if tests_dir !== nothing
    println("\n=== Test suite (from $tests_dir) ===")
    try
        cd(tests_dir) do
            try
                run_kl_string("(define y-or-n? _ -> true)")
            catch
            end
            println("Loading harness.shen ...")
            try
                F["load"]("harness.shen")
                println("  harness: ok")
                println("Loading kerneltests.shen ...")
                F["load"]("kerneltests.shen")
                passed = get(GLOBALS, "*passed*", "?")
                failed = get(GLOBALS, "*failed*", "?")
                println("Counters: passed=$passed failed=$failed")
            catch e
                if e isa ShenExcn
                    println("  FAILED: ", e.msg)
                else
                    println("  FAILED: ", e)
                    for (exc, bt) in Base.catch_stack()
                        showerror(stdout, exc, bt)
                        println()
                    end
                end
            end
        end
    catch e
        println("Could not run test suite: ", e)
    end
else
    println("\nNo tests/ directory with harness.shen found — smoke tests only.")
end

println("\nDone.")