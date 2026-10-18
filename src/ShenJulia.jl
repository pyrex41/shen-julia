# ShenJulia: a Julia port of the Shen language (ShenOSKernel 43.1).
#
# Architecture mirrors shen-lua: KLambda compiles to host source (Julia) which
# is eval'd at boot. Primitives implement the ~35 KL operations; the kernel
# .kl files provide the full Shen runtime.

module ShenJulia

include("Runtime.jl")
include("Compiler.jl")
include("Prims.jl")
include("Boot.jl")

using .Runtime
using .Compiler
using .Prims
using .Boot

# Re-export convenience API
export boot!, eval_kl, run_kl_string, to_str, intern, cons, NIL, equal, repl
export F, GLOBALS

const F = Prims.F
const GLOBALS = Prims.GLOBALS
eval_kl(form) = Prims.eval_kl(form)

function boot!(verbose::Bool=false)
    # Run boot on the big reserved stack: with no trampoline, deep kernel recursion
    # (init / prolog CPS / stlib / the typechecker) consumes real Julia stack frames.
    Prims.with_shen_stack() do
        Boot.setup_streams!()
        Boot.load_kernel!(verbose)
        Boot.initialise!()
        # Swap in fast host implementations of hot list builtins, overriding the KL defs.
        Prims.install_fast_builtins!()
    end
end

# User/REPL evaluation can recurse arbitrarily deep too — keep it on the big stack.
run_kl_string(src) = Prims.with_shen_stack(() -> Boot.run_kl_string(src))

function repl()
    boot!(false)
    println("Shen/Julia $(Prims.GLOBALS["*port*"]) — kernel $(Base.invokelatest(Prims.F["version"]))")
    println("Type Shen forms at the prompt (empty line to quit).")
    while true
        print("shen> ")
        flush(stdout)
        line = readline()
        isempty(strip(line)) && break
        try
            result = run_kl_string(line)
            result !== nothing && println(to_str(result))
        catch e
            if e isa ShenExcn
                println("error: ", e.msg)
            else
                println("error: ", e)
            end
        end
    end
end

# --- Precompile workload ------------------------------------------------------
# The kernel is baked into this package (src/kernel_generated.jl), but Julia only
# caches NATIVE code in the package image for methods that actually run while the
# package is being precompiled. Without this, every start pays the JIT for
# shen.initialise / stlib.initialise (~40 s on ShenOSKernel 43.1: init.kl and the
# StLib's initialise-* functions are huge). So boot the kernel once at precompile
# time and exercise the common paths, then restore every mutable table to its
# pre-boot contents so no runtime state leaks into the image (boot! rebuilds it at
# every start). Set SHEN_JULIA_NO_WORKLOAD=1 *before* the package is (re)compiled
# to skip it (the setting is baked into the cache; force a recompile to change it).
function _snapshot_state()
    return (F = copy(Prims.F), G = copy(Prims.GLOBALS), A = copy(Compiler.ARITY),
            K = copy(Compiler.KDATA), P = copy(Compiler.PRIMS))
end

function _restore_state!(s)
    empty!(Prims.F); merge!(Prims.F, s.F)
    empty!(Prims.GLOBALS); merge!(Prims.GLOBALS, s.G)
    empty!(Compiler.ARITY); merge!(Compiler.ARITY, s.A)
    empty!(Compiler.KDATA); append!(Compiler.KDATA, s.K)
    empty!(Compiler.PRIMS); union!(Compiler.PRIMS, s.P)
    return nothing
end

function _precompile_workload()
    snap = _snapshot_state()
    try
        redirect_stdout(devnull) do
            boot!(false)
            for src in ("(+ 1 2)", "(map (/. X (* X X)) [1 2 3])", "(fn filter)",
                        "(trap-error (head []) (/. E (error-to-string E)))",
                        "(read-from-string \"(a b) [c]\")", "(version)",
                        "(tc +)", "(define shen-julia.precompile-probe {number --> number} X -> (+ X 1))",
                        "(shen-julia.precompile-probe 1)", "(tc -)")
                run_kl_string(src)
            end
            Prims.with_shen_stack() do
                argv = Runtime.NIL
                for a in reverse(["shen", "eval", "-e", "(cons 1 [2 \"x\"])"])
                    argv = Runtime.cons(a, argv)
                end
                Base.invokelatest(Prims.F["shen.x.launcher.main"], argv)
            end
        end
    catch e
        @warn "ShenJulia precompile workload failed (startup will JIT instead)" exception = e
    finally
        _restore_state!(snap)
    end
    return nothing
end

if ccall(:jl_generating_output, Cint, ()) == 1 && Prims.HAS_BAKED_KERNEL &&
   get(ENV, "SHEN_JULIA_NO_WORKLOAD", "") != "1"
    _precompile_workload()
end

end # module ShenJulia
