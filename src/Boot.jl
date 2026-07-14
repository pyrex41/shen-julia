# Boot: load Mark Tarver's S41.2 (2026-07-11 refresh) KLambda kernel.
#
# This kernel has NO shen.initialise: initialisation is performed by the kernel's
# own top-level forms (declarations.kl builds the property/arity/lambda tables;
# types.kl runs 161 declares), which the baked registrar / source loader run at
# load time. See klambda/PROVENANCE.md.

module Boot

using ..Runtime
using ..Compiler
using ..Prims

# Stdlib for serializing pre-generated kernel Julia sources + snapshots (ARITY/KDATA/PRIMS)
# for dramatically faster warm boots (and even non-sysimage boots once artifact exists).
# This gives the quick precompile win without requiring full switch to bytecode VM path.
using Serialization

export load_kernel!, initialise!, run_kl_string, find_kldir, precompile_kernel_to_file!

# Upstream boot order (sources/make.shen) is:
#   yacc core load prolog reader sequent sys t-star toplevel track types
#   writer backend declarations   then   macros
# We move `declarations` BEFORE `types` because the baked/source loader runs all
# defuns first and only then the top-level forms in file order: `declarations`
# creates *property-vector* + the arity table, which the 161 top-level (declare)
# forms in `types` require. `extension-launcher` (community add-on, not in
# Tarver's distribution) is appended last for the eval/script/--version CLI.
const KERNEL_FILES = [
    "yacc", "core", "load", "prolog", "reader", "sequent", "sys", "t-star",
    "toplevel", "track", "writer", "backend", "declarations", "types", "macros",
    "extension-launcher",
]

function find_kldir()
    env = get(ENV, "SHEN_KL_DIR", "")
    !isempty(env) && return env

    if isfile("klambda/toplevel.kl")
        return "klambda"
    end

    candidates = [
        "../cl-source/ShenOSKernel-41.2/klambda",
        "../ShenOSKernel-41.2/klambda",
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
            eof(stdin) && return nothing
            c = read(stdin, Char)
            return Int(c)
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
    # Fastest path: the kernel was baked into the module image by bin/gen_kernel.jl,
    # so the ~1138 methods are already compiled — we only restore ARITY/KDATA and run
    # the cheap setfn! registrations. No per-boot Core.eval / JIT of kernel source.
    if isdefined(Prims, :HAS_BAKED_KERNEL) && getfield(Prims, :HAS_BAKED_KERNEL)
        load_kernel_baked!(verbose)
        return
    end
    if should_use_precompiled_kernel()
        load_precompiled_kernel!(verbose)
        return
    end

    kldir = find_kldir()
    all = Dict{String, Vector{Any}}()

    # Parallel prescan (and read) of the KERNEL_FILES using @async (Base, no extra using/threads flag needed).
    # (Originally used @spawn which requires Threads and explicit using; @async suffices for the IO/prescan.)
    # This path (cold / no precomp artifact / SHEN_FORCE_SLOW_BOOT=1) is unchanged and remains
    # fully compatible with bc hybrid, MKTREE, BIND, _safe_caller, parallel prescan, self-tail etc.
    l = ReentrantLock()
    @sync for nm in KERNEL_FILES
        @async begin
            path = joinpath(kldir, nm * ".kl")
            src = read(path, String)
            forms = read_all(src)
            lock(l) do
                all[nm] = forms
            end
            Compiler.prescan(forms)
        end
    end

    for nm in KERNEL_FILES
        for f in all[nm]
            # Keep source path for kernel (bc prototype supports core; complex with trap/reader use source for now)
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
    # Tarver's S41.2 refresh has no shen.initialise — the kernel's top-level forms
    # (declarations.kl / types.kl) already ran during load_kernel! and populated
    # *property-vector*, the arity/lambda tables, *macros*, the globals, etc. This
    # step is kept only for backward compatibility with community kernels that DO
    # define shen.initialise; on the refresh it is a no-op.
    fn = get(Prims.F, "shen.initialise", nothing)
    if fn !== nothing
        Prims.reset_max_frame_depth!()
        try
            Base.invokelatest(fn)
        catch e
            println(stderr, "  [init] shen.initialise threw (", typeof(e), ")")
        end
    end
    return nothing
end

function run_kl_string(src::String)
    # Shen-level input uses Shen reader syntax ([...] lists, vectors, etc.) which the raw KL
    # reader (read_all) does NOT understand — it would mis-read `[1 2 3]`. Once the kernel is
    # up, parse via the kernel's own reader `read-from-string` (bytes -> shen.<s-exprs> ->
    # process-sexprs), which yields a proper list of forms, then eval each via `eval`.
    rfs = get(Prims.F, "read-from-string", nothing)
    eval_fn = get(Prims.F, "eval", nothing)
    if rfs !== nothing && eval_fn !== nothing
        forms = Prims.force(Base.invokelatest(rfs, src))   # a Shen list (Cons chain) of forms
        last = nothing
        cur = forms
        while cur isa Cons
            last = Prims.force(Base.invokelatest(eval_fn, cur.h))
            cur = cur.t
        end
        return last
    end
    # Fallback (pre-boot / kernel not ready): low-level KL reader.
    forms = read_all(src)
    last = nothing
    for f in forms
        val = (eval_fn !== nothing && f isa Cons) ? Base.invokelatest(eval_fn, f) : Prims.eval_kl(f)
        last = Prims.force(val)
    end
    return last
end

# --- Baked-kernel fast boot (bin/gen_kernel.jl) ---

const KERNEL_ARITY_PATH = joinpath(dirname(@__DIR__), "kernel_arity.jls")
const KERNEL_KDATA_PATH = joinpath(dirname(@__DIR__), "kernel_kdata.jls")
const STLIB_ARITY_PATH  = joinpath(dirname(@__DIR__), "kernel_stlib_arity.jls")

function load_kernel_baked!(verbose::Bool=false)
    # Restore the literal table the baked methods index (KDATA) and the defun arity
    # table the post-boot eval/define codegen needs (ARITY). Then register the
    # already-compiled K_ methods into F + run the kernel's top-level forms.
    if isfile(KERNEL_KDATA_PATH)
        kd = Serialization.deserialize(KERNEL_KDATA_PATH)
        empty!(Compiler.KDATA); append!(Compiler.KDATA, kd)
    end
    if isfile(KERNEL_ARITY_PATH)
        merge!(Compiler.ARITY, Serialization.deserialize(KERNEL_ARITY_PATH))
    end
    Base.invokelatest(getfield(Prims, :_register_baked_kernel!))
    # Register the baked StLib on top of the kernel (methods already baked by the
    # stlib_generated.jl include; here we wire them into F and extend ARITY). The
    # stdlib arity table is a superset of the kernel's, so merging it is idempotent.
    # SHEN_SKIP_BAKED_STLIB=1 lets bin/gen_stlib.jl boot kernel-only and (re)load
    # StLib from source cleanly, instead of stacking a source load on top of an
    # already-baked stdlib.
    if isdefined(Prims, :HAS_BAKED_STLIB) && getfield(Prims, :HAS_BAKED_STLIB) &&
       get(ENV, "SHEN_SKIP_BAKED_STLIB", "") != "1"
        isfile(STLIB_ARITY_PATH) && merge!(Compiler.ARITY, Serialization.deserialize(STLIB_ARITY_PATH))
        Base.invokelatest(getfield(Prims, :_register_baked_stlib!))
    end
    verbose && println(stderr, "  loaded(baked) $(length(Prims.F)) functions")
end

# --- Fast precompile / sysimage support ---

const PRECOMPILED_KERNEL_PATH = joinpath(dirname(@__DIR__), "precompiled_kernel.jls")

function should_use_precompiled_kernel()
    get(ENV, "SHEN_FORCE_SLOW_BOOT", "") == "1" && return false
    isfile(PRECOMPILED_KERNEL_PATH)
end

function load_precompiled_kernel!(verbose::Bool=false)
    # Fast path for warm boots (with/without --sysimage): use pre-generated compile results.
    # Deserializes per-nm Vector of pre-generated Julia source strings (from compile_top during
    # the pre-gen pass) + snapshots of ARITY/KDATA/PRIMS state produced by prescan+compile_top.
    # (We use the source form for the fast-load artifact for reliability/compat with current
    # hybrid bc prototype; "simple bytecode arrays" captured in BytecodeFunc during cold bc path.)
    # Replay: restore state (for KDATA refs in hoisted lits/MKTREE, ARITY for post-boot codegen)
    # then only compile_and_load! the pre-gen srcs. Skips full reader + Compiler cexpr/ctail etc.
    # Executes identical side effects for F/FA/GLOBALS etc. Pre-gen does the codegen cost once.
    # Fully compatible with MKTREE/BIND (baked in), _safe_caller, parallel prescan (at pre-gen),
    # wrappers, self-tail logic (hardened), explicit frames, existing KDATA etc. bc register integrates for runtime defs.
    data = Serialization.deserialize(PRECOMPILED_KERNEL_PATH)
    sources = data[:sources]
    arity_snap = data[:arity]
    kdata_snap = data[:kdata]
    prims_snap = get(data, :prims, Set{String}())

    empty!(Compiler.ARITY); merge!(Compiler.ARITY, arity_snap)
    empty!(Compiler.KDATA); append!(Compiler.KDATA, kdata_snap)
    empty!(Compiler.PRIMS); union!(Compiler.PRIMS, prims_snap)
    # The pre-generated sources call kernel functions by their mangled name (K_<name>),
    # which the cdefun replay defines as methods — no slot map to restore.

    for nm in KERNEL_FILES
        srcs = get(sources, nm, String[])
        for julia_src in srcs
            Prims.compile_and_load!(julia_src, nm)
        end
        verbose && println(stderr, "  loaded(pre) $nm")
    end
end

# Capture pre-generated form by running prescan + compile_top for *every* form (source path).
# This ensures side effects (ARITY sets, KDATA pushes for MKTREE/KDATA lits) happen.
# Collects the julia source strings (pre-gen Julia source fast-load form). No bc collection here
# (to keep artifact simple/reliable; bc path still active for cold boots and can be targeted by
# future precomp/bytecode agent). Snapshot after codegen phase. No loads executed in this pass.
# Called from build_sysimage.jl ; also manual. Fulfills task item for precompiling klambda to fast form.
# Captures the completed self-tail (while/continue for all defuns in cdefun) and explicit frames so
# fast .jls boots + init use the SO fixes; bc vm (register + frames in exec) integrated for user defs.
function precompile_kernel_to_file!(outpath::String = PRECOMPILED_KERNEL_PATH)
    kldir = find_kldir()
    all_forms = Dict{String, Vector{Any}}()
    sources = Dict{String, Vector{String}}()

    l = ReentrantLock()
    @sync for nm in KERNEL_FILES
        @async begin
            path = joinpath(kldir, nm * ".kl")
            src = read(path, String)
            forms = read_all(src)
            lock(l) do
                all_forms[nm] = forms
            end
            Compiler.prescan(forms)
        end
    end

    for nm in KERNEL_FILES
        form_srcs = String[]
        for f in all_forms[nm]
            jsrc = Compiler.compile_top(f)  # always source for the artifact (reliable); side effects AR/KD
            push!(form_srcs, jsrc)
        end
        sources[nm] = form_srcs
    end

    snap = (
        sources = sources,
        arity = copy(Compiler.ARITY),
        kdata = copy(Compiler.KDATA),
        prims = copy(Compiler.PRIMS),
        # Integrate post-init snapshot: if frames wiring + self-tail while ensure shen.initialise-environment
        # and full init (incl prolog/stlib deep paths) completes w/o SO, pre-gen can snapshot here
        # (by temp loading srcs + Boot.setup + initialise + capture GLOBALS scalars/*macros* etc).
        # For now marker + note; runtime boot! always does load+initialise! for clean full state.
        # When init clean, higher cert counters, no printF undef, *macros* ready early.
        post_init_state = (initialised_marker = false, note = "set true + data when init completes in pre-gen path"),
    )
    Serialization.serialize(outpath, snap)
    @info "Precompiled kernel fast-load form (julia srcs + state snaps) written: $outpath ($(filesize(outpath)) bytes)"
    return outpath
end

end # module Boot