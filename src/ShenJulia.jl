# ShenJulia: a Julia port of the Shen 41.1 language kernel.
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
export boot!, eval_kl, run_kl_string, to_str, intern, cons, NIL, equal
export F, GLOBALS

const F = Prims.F
const GLOBALS = Prims.GLOBALS
eval_kl(form) = Prims.eval_kl(form)

function boot!(verbose::Bool=false)
    Boot.setup_streams!()
    Boot.load_kernel!(verbose)
    Boot.initialise!()
    # Swap in fast host implementations of hot list builtins, overriding the KL defs.
    Prims.install_fast_builtins!()
end

run_kl_string(src) = Boot.run_kl_string(src)

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

end # module ShenJulia