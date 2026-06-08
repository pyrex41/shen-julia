# Boot: load the Shen 41.1 KLambda kernel and run shen.initialise.

module Boot

using ..Runtime
using ..Compiler
using ..Prims

export load_kernel!, initialise!, run_kl_string, find_kldir

const KERNEL_FILES = [
    "toplevel", "core", "sys", "dict", "sequent", "yacc", "reader", "prolog",
    "track", "load", "writer", "macros", "declarations", "types", "t-star", "init",
    "extension-features", "extension-expand-dynamic", "extension-launcher",
    "compiler", "stlib",
]

function find_kldir()
    env = get(ENV, "SHEN_KL_DIR", "")
    !isempty(env) && return env

    if isfile("klambda/toplevel.kl")
        return "klambda"
    end

    candidates = [
        "../cl-source/ShenOSKernel-41.1/klambda",
        "../ShenOSKernel-41.1/klambda",
        joinpath(@__DIR__, "..", "klambda"),
    ]
    for c in candidates
        isfile(joinpath(c, "toplevel.kl")) && return c
    end
    return "klambda"
end

function setup_streams!()
    out_stream = Prims.mk_out_stream(
        s -> print(stdout, s),
        () -> flush(stdout),
        "stdout",
    )
    err_stream = Prims.mk_out_stream(
        s -> print(stderr, s),
        () -> flush(stderr),
        "stderr",
    )
    in_stream = Prims.mk_in_stream(
        () -> begin
            c = read(stdin, Char)
            return eof(stdin) ? nothing : Int(c)
        end,
        () -> nothing,
        "stdin",
    )
    Prims.GLOBALS["*stoutput*"] = out_stream
    Prims.GLOBALS["*sterror*"] = err_stream
    Prims.GLOBALS["*stinput*"] = in_stream
    Prims.GLOBALS["*home-directory*"] = ""

    Prims.GLOBALS["*language*"] = "Julia"
    Prims.GLOBALS["*implementation*"] = string(VERSION)
    Prims.GLOBALS["*port*"] = "shen-julia"
    Prims.GLOBALS["*porters*"] = "shen-julia contributors"
    Prims.GLOBALS["*os*"] = Sys.iswindows() ? "Windows" : "Unix"
    Prims.GLOBALS["*release*"] = "0.1"
end

function load_kernel!(verbose::Bool=false)
    kldir = find_kldir()
    all = Dict{String, Vector{Any}}()

    for nm in KERNEL_FILES
        path = joinpath(kldir, nm * ".kl")
        src = read(path, String)
        forms = read_all(src)
        all[nm] = forms
        Compiler.prescan(forms)
    end

    for nm in KERNEL_FILES
        for f in all[nm]
            julia_src = Compiler.compile_top(f)
            try
                Prims.compile_and_load!(julia_src, nm)
            catch e
                rethrow()
            end
        end
        verbose && println(stderr, "  loaded $nm")
    end
end

function initialise!()
    fn = get(Prims.F, "shen.initialise", nothing)
    fn === nothing && error("shen.initialise not defined after kernel load")
    # Kernel functions are eval'd at runtime; invokelatest avoids world-age errors.
    return Base.invokelatest(fn)
end

function run_kl_string(src::String)
    forms = read_all(src)
    last = nothing
    eval_fn = get(Prims.F, "eval", nothing)
    for f in forms
        last = if eval_fn !== nothing && f isa Cons
            Base.invokelatest(eval_fn, f)
        else
            Prims.eval_kl(f)
        end
    end
    return last
end

end # module Boot