# Prims: KL primitives, apply/curry machinery, and eval loader.

module Prims

using ..Runtime
import ..Runtime: make_absvector, NIL, Cons, is_cons, is_symbol, intern
using ..Compiler

export F, FA, GLOBALS, ERR, APP, MKFUN, PARTIAL, equal, BIND, MKTREE
export defprim, eval_kl, compile_and_load!, force, is_bounce, bounce, Bounce, mk_in_stream, mk_out_stream
export force, bounce, is_bounce, Bounce, BIND, MKTREE, FRAME_STACK, ActivationRecord, push_frame!, pop_frame!, max_frame_depth, reset_max_frame_depth!, ensure_port_prims!  # trampoline + explicit frames (SO fix, precomp/VM coord, depth measure)

const F = Dict{String, Function}()
const FA = Dict{Function, Int}()
const GLOBALS = Dict{String, Any}()

# Trampoline support for tail calls (Julia has no TCO).
# Tail-position calls in compiled code (via kl_call_tail / APP in tail ctx) return a Bounce
# instead of invoking directly. force() drives the loop at the "boundary" (top-level eval,
# APP entry for value calls, thaw, run_kl_string, etc.). This keeps Julia stack shallow
# for deep/mutual recursion in the kernel (Prolog CPS, Y, numeric self-rec, list fns, etc.).
mutable struct Bounce
    f::Function
    args::Vector{Any}
end

# Simple bounce constructor (the trampoline agent experimented with reuse for alloc reduction;
# for baseline we keep it simple and correct; reuse can be re-added safely later).
# Small-arity specializations reduce the Any[] allocation on the common tail-call paths.
@inline bounce(f) = Bounce(f, Any[])
@inline bounce(f, a1) = Bounce(f, Any[a1])
@inline bounce(f, a1, a2) = Bounce(f, Any[a1, a2])
@inline bounce(f, a1, a2, a3) = Bounce(f, Any[a1, a2, a3])
@inline bounce(f, args...) = Bounce(f, Any[args...])
is_bounce(x) = x isa Bounce

@inline function force(x)
    # Fast path (agent improvement): most returns from prims / value-pos calls / after driving a tail
    # are already concrete values. Avoid while + is_bounce check overhead on the common case.
    is_bounce(x) || return x
    while true
        b = x
        x = Base.invokelatest(b.f, b.args...)
        is_bounce(x) || return x
    end
end

# MKTREE: flat blueprint executor for deep cons trees (ported from shen-lua 41.1 technique).
# Blueprint is a flat Vector of alternating tags + values: 'v', <leaf>, 'v', <leaf>, 'c', ...
# 'v' pushes a value (atom, symbol, hoisted KDATA ref, or subexpr result).
# 'c' pops two and pushes (cons left right). This keeps both generated source size
# and runtime stack shallow for trees with thousands of cells (stlib record-kl etc.).
# Combined with BIND hoisting, reduces deep nesting that caused parser/runtime SO in init/prolog/stlib.
function MKTREE(ops::Vector)
    # Pre-allocate stack with a reasonable capacity. MKTREE blueprints for deep literals
    # (stlib etc.) can be hundreds of cells; starting small and growing is fine, but
    # a modest hint reduces reallocs.
    stack = Vector{Any}()
    sizehint!(stack, min(64, length(ops) ÷ 2))
    i = 1
    n = length(ops)
    @inbounds while i <= n
        tag = ops[i]
        if tag == "v"
            push!(stack, ops[i+1])
            i += 2
        elseif tag == "c"
            if length(stack) < 2
                ERR("MKTREE: stack underflow on c")
            end
            r = pop!(stack)
            l = pop!(stack)
            push!(stack, cons(l, r))
            i += 1
        else
            ERR("MKTREE: bad op $(tag)")
        end
    end
    if length(stack) != 1
        ERR("MKTREE: stack left with $(length(stack)) items")
    end
    return stack[1]
end

# Visible to eval'd kernel chunks (same module as other helpers like MKLIST).
# MKTREE (and MKLIST) are defined at module scope so bare names in
# Core.eval'd compiler output (from emit_mktree / MKLIST in cexpr) resolve.
const _MKTREE = MKTREE

# Explicit frame stack (inspired by shen-c LoopFrameStack) for the executor.
# Activation records hold locals (for lets/params), continuation or pc, and
# trap-error handler. The main driver loop (force + public boundaries) plus
# self-while in codegen keeps Julia stack bounded; this vec reifies the KL
# control state for measurement, VM handoff (precomp snapshot), and future
# full stepper (avoid deep Julia calls for non-tail cross fn).
mutable struct ActivationRecord
    fn::String
    locals::Dict{String,Any}
    cont::Any
    handler::Any
end
const FRAME_STACK = ActivationRecord[]
const _MAX_FRAME_DEPTH = Ref(0)
function push_frame!(fn::String, locals=Dict{String,Any}(), cont=nothing, handler=nothing)
    push!(FRAME_STACK, ActivationRecord(fn, locals, cont, handler))
    d = length(FRAME_STACK)
    if d > _MAX_FRAME_DEPTH[]; _MAX_FRAME_DEPTH[] = d; end
    return d
end
function pop_frame!()
    isempty(FRAME_STACK) && return nothing
    return pop!(FRAME_STACK)
end
function max_frame_depth()
    return _MAX_FRAME_DEPTH[]
end
function reset_max_frame_depth!()
    empty!(FRAME_STACK)
    _MAX_FRAME_DEPTH[] = 0
end

# Early-world wrapper for all user-defined and prim fns (world-age mitigation from
# dedicated subagent). Every entry in F and every key in FA is one of these.
# The wrapper itself is created in the initial module world; it does the invokelatest
# on the (possibly late) raw impl and *always forces the result* so that all "public"
# calls to KL fns (via F table, from init, smoke, tests, REPL, user Julia code) return
# concrete values, never a pending Bounce. Internal self-tail bounces (if the while
# opt is active inside the raw) are driven here at the boundary.
function _safe_caller(rawfn::Function, klname::String="")
    nm = isempty(klname) ? string(rawfn) : klname
    return function(args...)
        # Track on explicit frame stack at public boundary (helps measure max depth for init/prolog/self-rec; VM can own/snapshot).
        # Use KL name when provided (from defun) for better reified frames / depth measure.
        push_frame!(nm, Dict{String,Any}())
        try
            res = Base.invokelatest(rawfn, args...)
            return force(res)
        finally
            pop_frame!()
        end
    end
end

# ===================================================================
# Bytecode VM implementation (tight loop, explicit frames for SO safety + self-tail fastpath)
# Integrates with existing Bounce/force trampoline for cross-boundary tails (bc <-> non-bc).
# World-age: zero issue -- VM is fixed host code; new KL fns are *data* (BytecodeFunc).
# Precompile friendly: BytecodeFunc trees are plain data (can be built in precomp script
# and live in sysimage with no per-boot string/parse/JIT).
# ===================================================================

# Frame for explicit control stack inside vm_exec (no Julia recursion for KL calls).
# Kept as concrete as possible for the interpreter loop: BytecodeFunc is a fixed struct,
# but operand/locals/upvals are Vector{Any} because KL is dynamically typed (heterogeneous
# values, cons lists, closures, etc.). We mitigate via:
# - @inbounds + @inline on hot paths
# - in-place mutation for SELF_TAIL (no new vectors)
# - small-arity fast paths where practical
# - pre-sizing where we know narg/nlocals
# Per Julia performance tips: avoid abstract containers in *very* hot loops when you can;
# here the dynamic language semantics force Any for user values, but the *VM machinery*
# (pc, op dispatch, frame switching) is kept concrete (UInt8 op, Int pc, struct fields).
mutable struct _VMFrame
    bcf::BytecodeFunc
    locals::Vector{Any}
    upvals::Vector{Any}
    pc::Int
    vals::Vector{Any}   # operand stack for this activation
end

# bc_invoke: run a bc closure or func to completion (value or Bounce if tail-out to non-bc)
@inline function bc_invoke(bcf::BytecodeFunc, args::Vector{Any}, upvals::Vector{Any}=Any[])
    return vm_exec(bcf, args, upvals)
end
@inline function bc_invoke(clos::BCClosure, args::Vector{Any})
    return vm_exec(clos.template, args, clos.upvals)
end

# Main VM: drives explicit frames; returns concrete or Bounce (for trampoline handoff)
# Wire public FRAME_STACK (ActivationRecord) on every bc activation (push on enter, pop on return)
# so that init/prolog/stlib using bc (or future kernel bc) get bounded Julia stack + measured
# max KL depth (coord with source self-tail while). Uses bcf.name for KL-level fn label.
#
# Perf notes (Julia performance-tips):
# - The outer per-frame and inner pc loop are marked @inbounds.
# - Self-tail (0x06) and some tail cases mutate in place to avoid allocs (like a register VM).
# - Small arities dominate in practice; the carg/newloc copies are the main per-call cost.
# - Future: a contiguous value stack + frame base pointers (instead of per-frame vals Vector)
#   would reduce indirection and allow better escape analysis / less GC pressure.
function vm_exec(bcf::BytecodeFunc, args::Vector{Any}, upvals::Vector{Any}=Any[])::Any
    push_frame!(bcf.name, Dict{String,Any}())
    frames = _VMFrame[]
    nloc = max(bcf.nlocals, length(args))
    locs = Vector{Any}(undef, nloc)
    @inbounds for i in 1:length(args)
        locs[i] = args[i]
    end
    # Pre-allocate a modest operand stack per frame. Most KL expressions have small
    # stack depth (a few temporaries). push!/pop! will grow if needed.
    vals = Vector{Any}()
    sizehint!(vals, 8)
    frame = _VMFrame(bcf, locs, upvals, 0, vals)
    push!(frames, frame)
    cur = frame

    @inbounds while !isempty(frames)
        codev = cur.bcf.code
        clen = length(codev)
        while cur.pc < clen
            ins = codev[cur.pc + 1]
            cur.pc += 1
            op = ins.op
            a = Int(ins.a)
            b = Int(ins.b)

            if op == 0x00  # LOAD_LOCAL
                push!(cur.vals, cur.locals[a + 1])
            elseif op == 0x01  # STORE_LOCAL
                cur.locals[a + 1] = pop!(cur.vals)
            elseif op == 0x02  # LOAD_CONST
                push!(cur.vals, cur.bcf.consts[a + 1])
            elseif op == 0x03  # LOAD_UPVAL
                push!(cur.vals, cur.upvals[a + 1])
            elseif op == 0x07  # RETURN
                ret = pop!(cur.vals)
                pop_frame!()
                pop!(frames)
                if isempty(frames)
                    return ret
                end
                cur = frames[end]
                push!(cur.vals, ret)
                # continue in caller after its CALL instr (pc already advanced by caller)
            elseif op == 0x08  # JUMP
                cur.pc = a
            elseif op == 0x09  # JUMP_FALSE
                condv = pop!(cur.vals)
                if condv === false
                    cur.pc = a
                end
            elseif op == 0x0a  # MAKE_CLOSURE
                # consts[a] holds (tmpl::BytecodeFunc, upslotlist::Vector{Int})
                entry = cur.bcf.consts[a + 1]
                tmpl, upslots = entry
                # Pre-allocate captured upvals vector (usually tiny for closures).
                captured = Vector{Any}(undef, length(upslots))
                @inbounds for (j, sl) in enumerate(upslots)
                    captured[j] = (sl + 1 <= length(cur.locals) ? cur.locals[sl + 1] : nothing)
                end
                push!(cur.vals, BCClosure(tmpl, captured))
            elseif op == 0x0b  # POP
                if !isempty(cur.vals); pop!(cur.vals); end
            elseif op == 0x04 || op == 0x05 || op == 0x06  # CALL / TAIL_CALL / SELF_TAIL_CALL
                narg = b
                # Small-arity fast path (0-3 args cover the vast majority of KL calls in core + tests).
                # Avoids Vector{Any} allocation + reverse loop for the common cases. This is a direct
                # application of "specialize hot paths" and "reduce allocations in the interpreter loop".
                target = cur.bcf.consts[a + 1]
                is_self = (op == 0x06)
                is_tail = (op == 0x05 || is_self)

                if narg == 0
                    carg0 = ()
                    carg = carg0
                elseif narg == 1
                    v1 = pop!(cur.vals)
                    carg = (v1,)
                elseif narg == 2
                    v2 = pop!(cur.vals); v1 = pop!(cur.vals)
                    carg = (v1, v2)
                elseif narg == 3
                    v3 = pop!(cur.vals); v2 = pop!(cur.vals); v1 = pop!(cur.vals)
                    carg = (v1, v2, v3)
                else
                    carg = Vector{Any}(undef, narg)
                    @inbounds for i in narg:-1:1
                        carg[i] = pop!(cur.vals)
                    end
                end

                # resolve target if symbol fallback
                if is_symbol(target)
                    nm = target.name
                    if haskey(BC_F, nm)
                        target = BC_F[nm]
                    else
                        target = get(F, nm, target)
                    end
                elseif target === :__computed_fn__
                    # fnval was pushed before args for computed head; pop it now as target
                    fnval = pop!(cur.vals)  # the head val (may be BCClosure, BytecodeFunc, fn, symbol)
                    target = fnval
                end

                if is_self || (target isa BytecodeFunc && target.name == cur.bcf.name && target.arity == narg)
                    # zero-cost self tail: mutate current frame locals, reset pc.
                    # This is the key "register VM" style win for self-rec (no alloc, no new frame).
                    if narg == 0
                    elseif narg == 1
                        cur.locals[1] = carg[1]
                    elseif narg == 2
                        cur.locals[1] = carg[1]; cur.locals[2] = carg[2]
                    elseif narg == 3
                        cur.locals[1] = carg[1]; cur.locals[2] = carg[2]; cur.locals[3] = carg[3]
                    else
                        @inbounds for i in 1:narg
                            cur.locals[i] = carg[i]
                        end
                    end
                    cur.pc = 0
                    continue
                end

                if target isa BytecodeFunc
                    if is_tail
                        # replace current frame (tail to different bc) — reuse the idea of mutation
                        nnew = max(target.nlocals, narg)
                        newloc = Vector{Any}(undef, nnew)
                        if narg <= 3
                            @inbounds for i in 1:narg; newloc[i] = carg[i]; end
                        else
                            @inbounds for i in 1:narg; newloc[i] = carg[i]; end
                        end
                        cur.bcf = target
                        cur.locals = newloc
                        cur.upvals = Any[]
                        cur.pc = 0
                        empty!(cur.vals)
                        continue
                    else
                        # value call: push new frame
                        nnew = max(target.nlocals, narg)
                        newloc = Vector{Any}(undef, nnew)
                        @inbounds for i in 1:narg; newloc[i] = carg[i]; end
                        newf = _VMFrame(target, newloc, Any[], 0, Any[])
                        push!(frames, newf)
                        push_frame!(target.name, Dict{String,Any}())
                        cur = newf
                        continue
                    end
                elseif target isa BCClosure
                    tmpl = target.template
                    if is_tail
                        nnew = max(tmpl.nlocals, narg)
                        newloc = Vector{Any}(undef, nnew)
                        @inbounds for i in 1:narg; newloc[i] = carg[i]; end
                        cur.bcf = tmpl
                        cur.locals = newloc
                        cur.upvals = target.upvals
                        cur.pc = 0
                        empty!(cur.vals)
                        continue
                    else
                        nnew = max(tmpl.nlocals, narg)
                        newloc = Vector{Any}(undef, nnew)
                        @inbounds for i in 1:narg; newloc[i] = carg[i]; end
                        newf = _VMFrame(tmpl, newloc, target.upvals, 0, Any[])
                        push!(frames, newf)
                        push_frame!(tmpl.name, Dict{String,Any}())
                        cur = newf
                        continue
                    end
                else
                    # non-bc target: Julia fn / symbol / other. Use APP path for semantics (curries, bounces)
                    # In value pos (CALL): force to concrete. In tail: return the Bounce so upper can tramp
                    app_res = if narg == 0
                        APP(target)
                    elseif narg == 1
                        APP(target, carg[1])
                    elseif narg == 2
                        APP(target, carg[1], carg[2])
                    elseif narg == 3
                        APP(target, carg[1], carg[2], carg[3])
                    else
                        APP(target, carg...)
                    end
                    if is_tail
                        if is_bounce(app_res) || app_res isa BytecodeFunc || app_res isa BCClosure
                            pop_frame!()  # ending this vm activation (handoff); paired with entry push
                            return app_res   # handoff to trampoline; unwind this vm
                        else
                            push!(cur.vals, app_res)
                        end
                    else
                        push!(cur.vals, force(app_res))
                    end
                end
            else
                # unknown / future op -- fallback or error
                ERR("bad bytecode op $(op) at pc=$(cur.pc-1)")
            end
        end
        # fell off end: implicit return
        if !isempty(cur.vals)
            ret = pop!(cur.vals)
            pop_frame!()
            pop!(frames)
            if isempty(frames); return ret; end
            cur = frames[end]
            push!(cur.vals, ret)
        else
            pop_frame!()
            pop!(frames)
            if !isempty(frames)
                cur = frames[end]
                push!(cur.vals, NIL)
            end
        end
    end
    pop_frame!()
    return NIL
end

# Small helper for common case (0-ary thunks / expr chunks). Keeps call sites clean.
@inline vm_exec0(bcf::BytecodeFunc) = vm_exec(bcf, Any[])

# Wrapper creator for bc: produces a plain Julia callable (no late raw, world-age safe)
# that APP / F can use uniformly. Returns concrete or Bounce for tramp integration.
# Note: the Any[args...] is a necessary cost to bridge the vararg Function interface
# into the typed vm_exec. The small-arity paths in APP + vm_exec help callers.
@inline function make_bc_wrapper(bcf::BytecodeFunc)
    return function(args...)
        # Fast path for tiny arg counts (common) to avoid the general Any[] in some call sites.
        # vm_exec still receives a Vector internally for now.
        res = if length(args) == 0
            vm_exec(bcf, Any[])
        elseif length(args) == 1
            vm_exec(bcf, Any[args[1]])
        elseif length(args) == 2
            vm_exec(bcf, Any[args[1], args[2]])
        else
            vm_exec(bcf, Any[args...])
        end
        if is_bounce(res)
            return res
        end
        return res
    end
end

# Register bc-compiled defun: store template, create wrapper (returns Bounce for tails), but
# wrap entry in _safe_caller (with KL name) so F[] public calls always concrete (force inside),
# and FRAME_STACK tracks the activation (for depth/measure). This completes bc path wiring.
function register_bc_func!(bcf::Runtime.BytecodeFunc)
    BC_F[bcf.name] = bcf
    bcw = make_bc_wrapper(bcf)
    # inner to bcw may yield bounce; _safe will force result for public, and push with KL name
    wrapped = _safe_caller(bcw, bcf.name)
    F[bcf.name] = wrapped
    FA[wrapped] = bcf.arity
    Compiler.ARITY[bcf.name] = bcf.arity
end

function ERR(msg)
    throw(mkexcn(msg))
end

function TOEXCN(e)
    e isa ShenExcn && return e
    return mkexcn(string(e))
end

@inline function MKFUN(arity::Int, fn::Function, klname::String="")
    wrapped = _safe_caller(fn, klname)
    FA[wrapped] = arity
    return wrapped
end

@inline function PARTIAL(f, ar::Int, have::Vector)
    need = ar - length(have)
    g = function(args...)
        extra = collect(args)
        all = copy(have)
        append!(all, extra)
        # Use invokelatest for the completion call (f may be late user wrapper or raw);
        # _safe_caller is applied by the MKFUN below (and explicitly in other paths).
        return Base.invokelatest(f, all...)
    end
    return MKFUN(need, g)
end

# BIND: hoisted freeze body wrapper (41.1 from shen-lua).
# Prolog CPS (and typechecker) emit enormous chains of nested (freeze ...)
# continuations inside arg positions (60+ deep in einsteins-riddle, t-star etc).
# Naive codegen would produce deeply nested `MKFUN(0, () -> cexpr(body))`
# i.e. `function() ... end` literals inside the generated Julia, blowing
# parser limits or creating huge closure objects with heavy env capture
# (causing SO in stlib/prolog/init paths).
#
# Solution: per-defun, hoist each freeze *body* to a flat KB table entry:
#   KB[i] = function(cap1, cap2, ...) return <compiled body using caps as params> end
# At use site (in cexpr for freeze): emit `BIND(KB[i], cap1, cap2, ...)`
# which returns a fresh 0-ary thunk capturing the snapshot. The call site
# itself has no function literal.
#
# BIND here returns a 0-ary Function (no FA entry written -- thaws call
# via APP which handles; avoids hot-path weak table write).
# See shen-lua prims.lua:BIND + compiler.lua CTX/kbodies/collect_free/cdefun.
function BIND(fn, args...)
    n = length(args)
    if n == 0
        raw_thunk = fn
    elseif n == 1
        a1 = args[1]
        raw_thunk = () -> Base.invokelatest(fn, a1)
    elseif n == 2
        a1, a2 = args
        raw_thunk = () -> Base.invokelatest(fn, a1, a2)
    elseif n == 3
        a1, a2, a3 = args
        raw_thunk = () -> Base.invokelatest(fn, a1, a2, a3)
    else
        caps = collect(args)
        raw_thunk = () -> Base.invokelatest(fn, caps...)
    end
    # Ensure _safe_caller used for BIND thunks (world-age + always force result);
    # thaws/APP will go through bounce/force which invokelatest the (wrapped) thunk.
    return _safe_caller(raw_thunk, "freeze-thunk")
end

@inline function APP(f, args...)
    if is_symbol(f)
        fn = get(F, f.name, nothing)
        fn === nothing && ERR("not a function: $(f.name)")
        f = fn
    end
    f isa Function || ERR("attempt to apply a non-function")
    n = length(args)
    ar = get(FA, f, n)

    if n == ar
        # Tail-intent boundary: return a Bounce so the caller's frame can unwind if this
        # was a tail call in the KL sense. force() at the driver (value pos, thaw, top-level eval,
        # run_kl_string) will drive it to completion. This is the core of the trampoline.
        # Small-arity fast path avoids collecting into Vector{Any} for bounce in common cases.
        if n == 0
            return bounce(f)
        elseif n == 1
            return bounce(f, args[1])
        elseif n == 2
            return bounce(f, args[1], args[2])
        elseif n == 3
            return bounce(f, args[1], args[2], args[3])
        else
            return bounce(f, args...)
        end
    elseif n < ar
        # Currying path — still needs to collect for the PARTIAL representation.
        # (Future: could use a linked "partial chain" or pre-sized buffer to reduce allocs.)
        if n <= 3
            if n == 0
                return PARTIAL(f, ar, Any[])
            elseif n == 1
                return PARTIAL(f, ar, Any[args[1]])
            elseif n == 2
                return PARTIAL(f, ar, Any[args[1], args[2]])
            else
                return PARTIAL(f, ar, Any[args[1], args[2], args[3]])
            end
        else
            return PARTIAL(f, ar, collect(args))
        end
    else
        first = args[1:ar]
        rest = args[ar+1:end]
        r = force(Base.invokelatest(f, first...))  # force the prefix (rare over-apply)
        return APP(r, rest...)
    end
end

function equal(a, b)
    a === b && return true
    # Specialize common cases (symbols are intern-unique so === suffices but we keep name for robustness;
    # numbers/strings use === or == which are fast; avoids recursion overhead).
    if is_symbol(a) && is_symbol(b)
        return a.name == b.name
    end
    if a isa Number && b isa Number
        return a == b
    end
    if a isa String && b isa String
        return a == b
    end
    if a isa Cons && b isa Cons
        # Iterative to avoid stack overflow on long/deep lists (powerset, prolog results, append chains etc).
        # This is a hot path win for list-heavy reports.
        ca, cb = a, b
        while ca isa Cons && cb isa Cons
            equal(ca.h, cb.h) || return false
            ca, cb = ca.t, cb.t
        end
        return ca === cb   # both NIL or same improper tail
    end
    if a isa AbsVector && b isa AbsVector
        a.n != b.n && return false
        for i in 1:a.n
            get(a.data, i, nothing) != get(b.data, i, nothing) && return false
        end
        return true
    end
    return false
end

function defprim(name::String, arity::Int, fn::Function)
    wrapped = _safe_caller(fn, name)
    F[name] = wrapped
    FA[wrapped] = arity
    Compiler.ARITY[name] = arity
    # Register for prim direct bypass in codegen (trampoline agent).
    push!(Compiler.PRIMS, name)
end

function tonum(x)
    x isa Number || ERR("not a number: $(to_str(x))")
    return x
end

const FAILOBJ = intern("shen.fail!")

# arithmetic
defprim("+", 2, (a, b) -> tonum(a) + tonum(b))
defprim("-", 2, (a, b) -> tonum(a) - tonum(b))
defprim("*", 2, (a, b) -> tonum(a) * tonum(b))
defprim("/", 2, function(a, b)
    b = tonum(b)
    b == 0 && ERR("division by zero")
    return tonum(a) / b
end)
defprim(">", 2, (a, b) -> tonum(a) > tonum(b))
defprim("<", 2, (a, b) -> tonum(a) < tonum(b))
defprim(">=", 2, (a, b) -> tonum(a) >= tonum(b))
defprim("<=", 2, (a, b) -> tonum(a) <= tonum(b))
defprim("=", 2, (a, b) -> equal(a, b))

# lists
defprim("cons", 2, (a, b) -> cons(a, b))
defprim("hd", 1, function(x)
    x isa Cons || ERR("hd of non-cons")
    return x.h
end)
defprim("tl", 1, function(x)
    x isa Cons || ERR("tl of non-cons")
    return x.t
end)
defprim("cons?", 1, x -> x isa Cons)

# predicates
defprim("number?", 1, x -> x isa Number && !isa(x, Bool))
defprim("string?", 1, x -> x isa String)
defprim("symbol?", 1, is_symbol)
defprim("boolean?", 1, x -> x isa Bool)
defprim("not", 1, function(x)
    x isa Bool || ERR("not: not boolean")
    return !x
end)
defprim("integer?", 1, function(x)
    return x isa Integer && !isa(x, Bool) && isfinite(x)
end)

# symbols / strings
defprim("intern", 1, function(s)
    s isa String || ERR("intern: not a string")
    s == "true" && return true
    s == "false" && return false
    return intern(s)
end)

function num_to_str(n)
    if n isa Integer && !isa(n, Bool)
        return string(n)
    end
    return string(n)
end

defprim("str", 1, function(x)
    if x isa Number
        return num_to_str(x)
    elseif x isa String
        return x
    elseif x isa Bool
        return x ? "true" : "false"
    elseif is_symbol(x)
        return x.name
    elseif x === NIL
        ERR("str: cannot convert ()")
    else
        ERR("str: cannot convert")
    end
end)

defprim("cn", 2, function(a, b)
    a isa String && b isa String || ERR("cn: not strings")
    return a * b
end)
defprim("pos", 2, function(s, n)
    s isa String || ERR("pos: not a string")
    idx = Int(tonum(n)) + 1
    return string(s[idx])
end)
defprim("tlstr", 1, function(s)
    s isa String || ERR("tlstr: not a string")
    return s[2:end]
end)
defprim("string->n", 1, function(s)
    s isa String || ERR("string->n: not a string")
    return Int(codeunit(s, 1))
end)
defprim("n->string", 1, function(n)
    return string(Char(Int(tonum(n))))
end)
defprim("string->symbol", 1, function(s)
    s isa String || ERR("string->symbol: not a string")
    return intern(s)
end)

defprim("empty?", 1, x -> x === NIL)

# globals (dual namespace)
defprim("set", 2, function(sym, v)
    key = is_symbol(sym) ? sym.name : string(sym)
    GLOBALS[key] = v
    return v
end)
defprim("value", 1, function(sym)
    key = is_symbol(sym) ? sym.name : string(sym)
    if !haskey(GLOBALS, key)
        ERR("variable $key has no value")
    end
    return GLOBALS[key]
end)

defprim("simple-error", 1, function(msg)
    ERR(msg isa String ? msg : to_str(msg))
end)
defprim("error-to-string", 1, function(e)
    e isa ShenExcn && return e.msg
    return string(e)
end)

# vectors
defprim("absvector", 1, function(n)
    sz = Int(tonum(n))
    return make_absvector(sz, FAILOBJ)
end)
defprim("absvector?", 1, is_absvector)
defprim("<-address", 2, function(v, i)
    v isa AbsVector || ERR("<-address: not a vector")
    return v.data[Int(tonum(i)) + 1]
end)
defprim("address->", 3, function(v, i, x)
    v isa AbsVector || ERR("address->: not a vector")
    v.data[Int(tonum(i)) + 1] = x
    return v
end)

defprim("thaw", 1, x -> APP(x))

defprim("type", 2, (x, _ty) -> x)

defprim("eval-kl", 1, form -> eval_kl(form))

const _t0_real = time()
defprim("get-time", 1, function(sym)
    name = is_symbol(sym) ? sym.name : string(sym)
    if name == "run"
        return time_ns() / 1e9
    else
        return time() - _t0_real
    end
end)

# streams
function mk_out_stream(writefn, closefn, name)
    return OutStream(writefn, closefn, name)
end

function mk_in_stream(readfn, closefn, name)
    return InStream(readfn, closefn, name, false)
end

defprim("write-byte", 2, function(n, st)
    st isa OutStream || ERR("write-byte: not an output stream")
    st.write(string(Char(Int(tonum(n)))))
    return n
end)

defprim("read-byte", 1, function(st)
    st isa InStream || ERR("read-byte: not an input stream")
    st.eof && return -1
    b = st.readbyte()
    if b === nothing
        st.eof = true
        b = -1
    end
    if (b === -1) && (st === get(GLOBALS, "*stinput*", nothing) || (hasproperty(st, :name) && occursin("input", lowercase(string(st.name)))))
        println(stderr, "[READ-BYTE DEBUG] hit -1 on *stinput* or input stream (this will cause empty-stream in read-loop if no bytes accumulated yet)")
    end
    return b
end)

defprim("open", 2, function(name, dir)
    name isa String || ERR("open: filename not a string")
    d = is_symbol(dir) ? dir.name : string(dir)
    if d == "in"
        fh = open(name, "r")
        return mk_in_stream(
            () -> begin
                eof(fh) && return nothing
                c = read(fh, Char)
                return Int(c)
            end,
            () -> close(fh),
            name,
        )
    elseif d == "out"
        fh = open(name, "w")
        return mk_out_stream(
            s -> write(fh, s),
            () -> close(fh),
            name,
        )
    else
        ERR("open: bad direction $d")
    end
end)

defprim("close", 1, function(st)
    if is_stream(st) && st.closefn !== nothing
        st.closefn()
    end
    return NIL
end)

# The two port primitives required by reader.kl/writer.kl (and macros) for
# deciding byte vs. char paths on streams. Must be present (returning false for
# our byte streams) before any writer/reader code runs during init or load.
# Registered via defprim so ARITY + F + FA are populated early.
defprim("shen.char-stinput?", 1, _st -> false)
defprim("shen.char-stoutput?", 1, _st -> false)

# Re-ensure (for sysimage binding pruning + partial init + post-load loss).
# Under --sysimage, top-level defprim side effects for these (only host-provided,
# never in klambda defuns) may result in F having only ~45 entries and no shen.*
# at "using" time; kernel load populates other shen.* but not these. Reader/writer
# .shen loads (even plain define .shen) hit "not a function: shen.char-stoutput?"
# via APP symbol lookup unless present. Safe/idempotent to re-call; also sets FA/ARITY/PRIMS.
function ensure_port_prims!()
    defprim("shen.char-stinput?", 1, _st -> false)
    defprim("shen.char-stoutput?", 1, _st -> false)
end

defprim("exit", 1, function(n)
    flush(stdout)
    exit(Int(tonum(n)))
end)

function MKLIST(arr, tail)
    acc = tail
    for i in length(arr):-1:1
        acc = cons(arr[i], acc)
    end
    return acc
end

# Names visible to eval'd kernel code
const S = intern
const KDATA = Compiler.KDATA
# BIND and MKTREE (and MKLIST) are function bindings at module top-level,
# so compiler-emitted calls like BIND(KB[3], ...) and MKTREE(...) resolve
# during Core.eval in compile_and_load! (Prims module). No extra const needed.
# (MKTREE fn already binds the name; _MKTREE alias above for any legacy emit.)

function compile_and_load!(src::String, chunkname::String)
    mod = @__MODULE__
    try
        ex = Meta.parse(src)
        Core.eval(mod, ex)
    catch e
        error("Julia load error in $chunkname: $e\n$src")
    end
end

function eval_kl(form)
    if form isa Number || form isa String || form isa Bool
        return form
    end
    form === NIL && return form
    if is_symbol(form)
        v = get(GLOBALS, form.name, form)
        return v
    end
    if is_absvector(form) || is_stream(form) || form isa ShenExcn
        return form
    end
    if form isa Cons && is_symbol(form.h) && form.h.name == "defun"
        # Prefer bytecode path (data driven, no parse/eval/JIT, explicit frames, fast self-tail)
        try
            bcf = Compiler.bc_compile_top(form)
            if bcf isa Runtime.BytecodeFunc
                register_bc_func!(bcf)
                return form.t.h
            end
            println(stderr, "[bc-debug] defun bc produced non-bc: ", typeof(bcf))
        catch e
            println(stderr, "[bc-debug] defun bc err, fallback: ", typeof(e))
            # fallback to source for unsupported (e.g. trap-error in prototype)
        end
        compile_and_load!(Compiler.compile_top(form), "defun")
        return form.t.h
    end
    # For expr chunks, try bc too for prototype perf (user code, run_kl_string etc)
    try
        bcf = Compiler.bc_compile_expr_chunk(form)
        if bcf isa Runtime.BytecodeFunc
            # run as 0-ary thunk via vm (value context)
            res = vm_exec(bcf, Any[])
            return is_bounce(res) ? force(res) : res
        end
    catch e
        println(stderr, "[bc-debug] expr bc err: ", typeof(e))
    end
    src = Compiler.compile_expr_chunk(form)
    mod = @__MODULE__
    return Base.invokelatest(Core.eval, mod, Meta.parse(src))
end

# Root key trampoline / cross-module names at module init time. This ensures the
# bindings for `force`, `bounce`, `is_bounce`, `Bounce` (and transitively Compiler
# via `using`) remain visible via names()/isdefined()/getproperty even under
# PackageCompiler sysimages (ShenJulia.sys), where untraced top-level bindings can
# disappear from the module's reflected globals unless referenced in the precomp
# workload or here. Fixes UndefVarError(:force, ..., ShenJulia.Prims) and similar
# in run-tests.jl micros/smoke/harness loads when using --sysimage.
let _ = force, _ = bounce, _ = is_bounce, _ = Bounce, _ = Compiler
    # also ensure APP etc already are, but force is the main one used by driver
end

end # module Prims