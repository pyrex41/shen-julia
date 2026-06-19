#!/usr/bin/env julia
# Bake one Shen program into a fast-start sysimage.
#
#   julia --project=. bin/build_app_sysimage.jl <prog.shen> [out.sys] [-- ENTRYEXPR ...]
#
# Produces a PackageCompiler sysimage that contains the native-compiled kernel
# PLUS the native code for every kernel path your program exercises while loading
# and running. Start your program against it in ~1s:
#
#   SHEN_JULIA_SYSIMAGE=<out.sys> ./bin/shen script <prog.shen>
#   SHEN_JULIA_SYSIMAGE=<out.sys> ./bin/shen eval -l <prog.shen> -e "(main)"
#
# What this does / does not do:
#   * It traces a real run — boot, `(load "<prog>")`, then any ENTRYEXPR forms you
#     pass after `--` (e.g. `(main)`, `(run-tests)`) — so the reader, evaluator,
#     printer and the kernel functions your program calls are all baked native.
#     This removes the first-call JIT cliff; startup drops to process-spin-up.
#   * Your program is still (re)loaded at startup, but that load is fast because
#     everything it compiles down to is already native. For most programs this is
#     well under a second.
#   * For a fully self-contained artifact where your program's OWN functions are
#     also baked (and the kernel is tree-shaken to just what you use), use the
#     Ratatoskr pipeline + bin/ratatoskr-build.jl instead.
#
# The sysimage is tied to this machine's OS/CPU and Julia version (see README).

using Pkg
Pkg.activate(dirname(@__DIR__))
using PackageCompiler

length(ARGS) >= 1 || error("usage: build_app_sysimage.jl <prog.shen> [out.sys] [-- ENTRYEXPR ...]")

# Split ARGS at `--`: before it are positional (prog, out); after are entry exprs.
sep = findfirst(==("--"), ARGS)
pos = sep === nothing ? ARGS : ARGS[1:sep-1]
entries = sep === nothing ? String[] : ARGS[sep+1:end]

prog = abspath(pos[1])
isfile(prog) || error("program not found: $prog")
out  = length(pos) >= 2 ? abspath(pos[2]) : abspath(splitext(prog)[1] * ".sys")
proj = dirname(@__DIR__)

# Render the entry exprs as a Julia vector literal of strings for the exec file.
entry_lits = "[" * join((repr(e) for e in entries), ", ") * "]"

precomp = tempname() * ".jl"
open(precomp, "w") do io
    write(io, """
    using ShenJulia
    using ShenJulia: Prims, Runtime
    const F = Prims.F
    boot!(false)
    Prims.with_shen_stack() do
        try
            Prims.force(Base.invokelatest(F["load"], $(repr(prog))))
            println("app-sysimage: loaded $(basename(prog))")
        catch e
            @warn "load failed during trace (sysimage still built)" exception=e
        end
        for ex in $entry_lits
            try
                println("app-sysimage: running ", ex)
                ShenJulia.run_kl_string(ex)
            catch e
                @warn "entry expr failed during trace" expr=ex exception=e
            end
        end
    end
    # Also warm the standard launcher / printer path the CLI drives.
    let argv = Runtime.NIL
        for a in Iterators.reverse(["shen", "eval", "-e", "(+ 1 2)"]); argv = Runtime.cons(a, argv); end
        try Prims.with_shen_stack() do; Base.invokelatest(F["shen.x.launcher.main"], argv) end catch end
    end
    """)
end

ct = get(ENV, "SHEN_SYSIMAGE_CPU_TARGET", "")
kw = (; sysimage_path = out, precompile_execution_file = precomp)
isempty(ct) || (kw = (; kw..., cpu_target = ct))

println("Baking app sysimage for ", basename(prog), " -> ", out)
println("  entry exprs traced: ", isempty(entries) ? "(none — load only)" : join(entries, "  "))
println("  (this takes a few minutes and significant RAM)")
create_sysimage(["ShenJulia"]; kw...)
rm(precomp; force=true)

println("Done: ", out, "  (", round(filesize(out)/1024/1024, digits=1), " MiB)")
println("Run:  SHEN_JULIA_SYSIMAGE=", out, " ", joinpath(proj, "bin", "shen"), " script ", prog)
