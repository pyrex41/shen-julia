#!/usr/bin/env julia
# Shen/Julia interactive REPL entry point.

using Pkg
Pkg.activate(dirname(@__DIR__))

using ShenJulia

if length(ARGS) >= 1 && ARGS[1] == "--boot-only"
    t0 = time()
    boot!(get(ENV, "SHEN_VERBOSE", "") == "1")
    t1 = time()
    println("Kernel loaded in $(round(t1 - t0, digits=3))s")
    println("version: ", ShenJulia.Prims.force(Base.invokelatest(ShenJulia.F["version"])))
    exit(0)
end

repl()