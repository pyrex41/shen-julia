#!/usr/bin/env julia
# Sysimage builder for ShenJulia (PackageCompiler) with aggressive kernel precompilation.
# Run: julia --project=. bin/build_sysimage.jl
# Produces ShenJulia.sys + precompiled_kernel.jls in the project root.
# Then use: julia --sysimage ShenJulia.sys --project=. -e '
#   using ShenJulia, ShenJulia.Prims, ShenJulia.Runtime: from_vec, cons, NIL;
#   using ShenJulia: F;
#   t0=time(); boot!(false); println("warm boot: ", time()-t0);
#   println("version: ", Prims.force(Base.invokelatest(F["version"])))
# '
#
# This captures as much of kernel load as possible:
# - First, precompile_kernel_to_file!() runs full prescan + bc_compile_top/compile_top (the codegen)
#   for all 21 klambda/*.kl , snapshots pre-gen Julia srcs + bc BytecodeFunc (with Instr arrays + consts)
#   + ARITY/KDATA/PRIMS/BC_F state. Writes precompiled_kernel.jls .
# - The precomp_execution then does boot!(false) which (because .jls present) takes the fast replay path:
#   restore state + register_bc / compile_and_load only (no re-read_all, no re-codegen of cexpr etc).
# - Exercises after boot cover hot paths (APP, lists, prolog CPS via freezes/BIND, MKTREE deep trees,
#   reader, equal, stlib, self-tail, wrappers, etc) so PackageCompiler traces the generated funcs + VM.
# Result: warm boots (and even boots after build without --sysimage if .jls kept) target <5-10s.
# Cold boots unchanged (full path, unless .jls left from prior build).
# Compatible with MKTREE, BIND, _safe_caller, parallel prescan (used at pre-gen), hybrid bc+source, etc.
# Prioritizes precomp wins; bc VM integration is coordinated (pre-gen captures bc forms too).

using Pkg
Pkg.activate(dirname(@__DIR__))

using PackageCompiler

proj = dirname(@__DIR__)
sysout = joinpath(proj, "ShenJulia.sys")

# Generate the fast-load form for klambda (pre-gen Julia source + bytecode arrays).
# This runs the expensive Compiler work (once) as part of the build.
println("Pre-generating fast kernel load form (codegen of 21 KL files + state snapshot; one-time per build)...")
using ShenJulia.Boot
Boot.precompile_kernel_to_file!()

# Precompile execution: boot (now via fast path) + extensive list/prolog/stlib/metaprog loads
# + direct calls + run_kl to cover as much post-kernel as possible for the sysimage trace.
# (The more exercised, the better the warm boot perf after.)
precomp_script = joinpath(proj, "sysimage_precompile.jl")
open(precomp_script, "w") do io
    write(io, """
    using ShenJulia
    using ShenJulia: F
    using ShenJulia.Prims
    using ShenJulia.Runtime: from_vec, cons, NIL
    boot!(false)
    println("sysimage precomp: kernel booted (fast path), version=", Prims.GLOBALS["*version*"])
    v = Prims.force(Base.invokelatest(F["version"]))
    println("  verified version=", v)

    # Heavy representative workloads to trace lists, prolog (CPS freezes/BIND), deep trees (MKTREE),
    # reader, equal, stlib init side effects, self-tail, APP/PARTIAL, wrappers, load etc.
    cd(joinpath(@__DIR__, "tests")) do
        for testf in ("powerset.shen", "cartprod.shen", "prolog.shen", "einsteins-riddle.shen",
                      "n queens.shen", "prime.shen", "search.shen")
            try; Prims.force(F["load"](testf)); println("  precomp loaded ", testf); catch e; end
        end
        # Exercise loaded fns (cover map-like, powerset, prolog queries, nqueens etc)
        xs = from_vec(collect(1:6))
        try; res=Prims.force(Base.invokelatest(F["powerset*"], xs)); println("  powerset* len=", length(collect(res))); catch; end
        try; Prims.force(Base.invokelatest(F["cartprod*"], from_vec([1,2]), from_vec([:a,:b]))); catch; end
        try; res=Prims.force(Base.invokelatest(F["prime*"], 30)); println("  primes to 30: ", res); catch; end
        # Some direct prim + run_kl to cover more paths
        try; println("  2+3=", Prims.force(Base.invokelatest(F["+"],2,3))); catch; end
        try; run_kl_string("(define sysimg-square X -> (* X X))"); println("  define via run_kl: ok"); catch; end
        try; println("  square 9=", Prims.force(Base.invokelatest(F["sysimg-square"], 9))); catch; end
        println("sysimage precomp: list/prolog/stlib exercises done")
    end
    """)
end

println("Building ShenJulia sysimage (this will take minutes and significant RAM; one-time cost)...")
create_sysimage(["ShenJulia"];
    sysimage_path = sysout,
    precompile_execution_file = precomp_script,
    # cpu_target="native" for max perf on this machine; omit or set "generic" for portable.
)

println("Sysimage written: ", sysout)
println("Size: ", filesize(sysout) / 1024 / 1024, " MiB")
println("Also produced: precompiled_kernel.jls (for fast boots even without sysimage)")
println("To measure warm: julia --sysimage ", sysout, " --project=. -e 'using ShenJulia, ShenJulia.Prims, ShenJulia: F; using ShenJulia.Runtime: from_vec, cons, NIL; t0=time(); boot!(false); println(\"warm boot: \", time()-t0, \"s\"); println(\"ver: \", Prims.force(Base.invokelatest(F[\"version\"])))' ")
println("To measure run-tests micro (SKIP): SKIP_TESTS=1 julia --sysimage ", sysout, " --project=. run-tests.jl")
rm(precomp_script; force=true)
