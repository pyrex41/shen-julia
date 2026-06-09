# Prims: KL primitives, apply/curry machinery, and eval loader.

module Prims

using ..Runtime
import ..Runtime: make_absvector, NIL, Cons, is_cons, is_symbol, intern
using ..Compiler

export F, FA, GLOBALS, ERR, APP, MKFUN, PARTIAL, equal, BIND, MKTREE
export defprim, eval_kl, compile_and_load!, force, is_bounce, bounce, Bounce, mk_in_stream, mk_out_stream
export max_frame_depth, reset_max_frame_depth!, ensure_port_prims!, install_fast_builtins!

const F = Dict{String, Function}()      # public/APP table (string-keyed; ergonomic)
const FA = Dict{Function, Int}()
const GLOBALS = Dict{String, Any}()

# Integer-slot dispatch table that compiled code calls through (codegen emits FV[slot];
# see Compiler.fnslot). Removes the per-call string hash. setfn! is the single registration
# point that keeps FV and F in sync, so there is no way for them to drift.
const FV = Function[]
_undef_fn_slot(args...) = ERR("call to unregistered function slot")
function setfn!(name::String, fn::Function)
    s = Compiler.fnslot(name)
    while length(FV) < s
        push!(FV, _undef_fn_slot)
    end
    @inbounds FV[s] = fn
    F[name] = fn
    return fn
end

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
    # Most returns are already concrete values; skip the loop on the common case.
    is_bounce(x) || return x
    # The bounced fn is reached under a top-level `invokelatest` (every public entry point
    # establishes one), so we are already in the latest world age and can call it directly.
    while true
        b = x
        x = b.f(b.args...)
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

# Diagnostic call-depth API kept only for the boot/test drivers that print it. Nothing
# increments it any more (the explicit frame stack went away with the bytecode VM), so
# these are inert stubs.
max_frame_depth() = 0
reset_max_frame_depth!() = nothing

# Early-world wrapper for all user-defined and prim fns (world-age mitigation from
# dedicated subagent). Every entry in F and every key in FA is one of these.
# The wrapper itself is created in the initial module world; it does the invokelatest
# on the (possibly late) raw impl and *always forces the result* so that all "public"
# calls to KL fns (via F table, from init, smoke, tests, REPL, user Julia code) return
# concrete values, never a pending Bounce. Internal self-tail bounces (if the while
# opt is active inside the raw) are driven here at the boundary.
function _safe_caller(rawfn::Function, klname::String="")
    # Wrapper for user/kernel functions. Its only job is to drive the trampoline: the raw
    # compiled body may return a Bounce for a cross-function tail call, and value-position
    # callers expect a concrete value, so we force here. No `invokelatest` (we run under a
    # top-level one — see force) and no per-call frame/Dict allocation (that was diagnostic
    # only). This is on the hot path for every KL function call.
    return function(args...)
        force(rawfn(args...))
    end
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
        # Direct call (no invokelatest — we run under a top-level one). The MKFUN wrapper
        # below forces the result.
        return f(all...)
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
        raw_thunk = () -> fn(a1)
    elseif n == 2
        a1, a2 = args
        raw_thunk = () -> fn(a1, a2)
    elseif n == 3
        a1, a2, a3 = args
        raw_thunk = () -> fn(a1, a2, a3)
    else
        caps = collect(args)
        raw_thunk = () -> fn(caps...)
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
        r = force(f(first...))  # force the prefix (rare over-apply)
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
    # Primitives are host functions defined in the module's initial world age: they have
    # NO world-age hazard and never need the `_safe_caller` wrapper (which would add a
    # per-call Dict allocation, frame push/pop, and two `invokelatest` dispatches — pure
    # overhead on the hottest path in the system). Store the raw fn directly. Prims that
    # delegate to APP (and could yield a Bounce, e.g. `thaw`) force their own result.
    setfn!(name, fn)          # populates both FV (codegen) and F (public/APP)
    FA[fn] = arity
    Compiler.ARITY[name] = arity
    # Register for prim direct bypass in codegen.
    push!(Compiler.PRIMS, name)
end

function tonum(x)
    x isa Number || ERR("not a number: $(to_str(x))")
    return x
end

const FAILOBJ = intern("shen.fail!")

# Named, @inline-able implementations of the hottest primitives. These are the single
# source of truth: `defprim` registers them in F (for currying / value-position / APP),
# and the compiler emits *direct* calls to them (Compiler.INLINE_PRIM) when the prim is
# applied at exact arity in head position — skipping the F string-Dict lookup, the FA
# arity check, and (in tail position) the Bounce allocation. Julia can then inline them
# straight into the generated function body. This is the "peephole optimisation" the
# Shen porting guide recommends for oft-used low-level functions.
# Multiple dispatch: a concrete fast method for Real operands (which Julia specializes per
# concrete type into static, unboxed arithmetic) plus a generic fallback that validates via
# tonum. KL is dynamically typed, so operands arrive as Any; the runtime dispatch lands on
# the Real method when they are numbers, ~2-2.5x faster than routing everything through
# tonum + an abstract-typed operator (see bin/bench_dispatch.jl). Behaviour is identical to
# the old tonum-only form (Real == what tonum accepts), just type-specialized.
@inline kl_add(a::Real, b::Real) = a + b
@inline kl_add(a, b) = tonum(a) + tonum(b)
@inline kl_sub(a::Real, b::Real) = a - b
@inline kl_sub(a, b) = tonum(a) - tonum(b)
@inline kl_mul(a::Real, b::Real) = a * b
@inline kl_mul(a, b) = tonum(a) * tonum(b)
@inline kl_div(a::Real, b::Real) = (b == 0 && ERR("division by zero"); a / b)
@inline kl_div(a, b) = (bn = tonum(b); bn == 0 && ERR("division by zero"); tonum(a) / bn)
@inline kl_gt(a::Real, b::Real)  = a > b
@inline kl_gt(a, b)  = tonum(a) > tonum(b)
@inline kl_lt(a::Real, b::Real)  = a < b
@inline kl_lt(a, b)  = tonum(a) < tonum(b)
@inline kl_gte(a::Real, b::Real) = a >= b
@inline kl_gte(a, b) = tonum(a) >= tonum(b)
@inline kl_lte(a::Real, b::Real) = a <= b
@inline kl_lte(a, b) = tonum(a) <= tonum(b)
@inline kl_eq(a, b)  = equal(a, b)
@inline kl_cons(a, b) = cons(a, b)
@inline kl_hd(x) = x isa Cons ? x.h : ERR("hd of non-cons")
@inline kl_tl(x) = x isa Cons ? x.t : ERR("tl of non-cons")

# arithmetic
defprim("+", 2, kl_add)
defprim("-", 2, kl_sub)
defprim("*", 2, kl_mul)
defprim("/", 2, kl_div)
defprim(">", 2, kl_gt)
defprim("<", 2, kl_lt)
defprim(">=", 2, kl_gte)
defprim("<=", 2, kl_lte)
defprim("=", 2, kl_eq)

# lists
defprim("cons", 2, kl_cons)
defprim("hd", 1, kl_hd)
defprim("tl", 1, kl_tl)
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

defprim("thaw", 1, x -> force(APP(x)))

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

# ---------------------------------------------------------------------------
# "Overwrite" peephole builtins (Shen porting guide §Optimising your Port).
# The kernel defines append/reverse/length/map in KL as recursive functions; every
# element costs a full KL call to the recursive driver (through F + the trampoline).
# These host versions are behaviour-conformant drop-in replacements that walk the Cons
# spine in a tight loop instead. Bonus: `append` here is iterative, whereas the kernel's
# `append` is NOT tail-recursive and overflows the stack on long lists.
# install_fast_builtins!() swaps them into F after boot (so they override the KL defs);
# the originals are stashed in SLOW_BUILTINS for A/B benchmarking.
# ---------------------------------------------------------------------------
const SLOW_BUILTINS = Dict{String, Function}()

# append: () ++ b = b; (h.t) ++ b = h : (t ++ b); improper spine -> simple-error.
function kl_append(a, b)
    rev = NIL
    c = a
    while c isa Cons
        rev = cons(c.h, rev); c = c.t
    end
    c === NIL || ERR("attempt to append a non-list")
    acc = b
    while rev isa Cons
        acc = cons(rev.h, acc); rev = rev.t
    end
    return acc
end

# reverse: proper-list reversal; improper spine -> simple-error (as shen.reverse-help).
function kl_reverse(a)
    acc = NIL
    c = a
    while c isa Cons
        acc = cons(c.h, acc); c = c.t
    end
    c === NIL || ERR("attempt to reverse a non-list")
    return acc
end

# length: count of a proper list; the KL shen.length-h calls (tl x) on a non-cons tail,
# so an improper/atom argument errors with "tl of non-cons" — matched here.
function kl_length(a)
    n = 0
    c = a
    while c isa Cons
        n += 1; c = c.t
    end
    c === NIL || ERR("tl of non-cons")
    return n
end

# map: validate the spine first (so an improper list defers to the original kernel map
# for exact shen.f-error semantics, with no premature side effects), then apply f
# left-to-right (f is a KL closure -> APP/force) and reverse once, exactly like shen.map-h.
function kl_map_fast(f, a, origmap)
    buf = Any[]
    c = a
    while c isa Cons
        push!(buf, c.h); c = c.t
    end
    c === NIL || return origmap(f, a)
    rev = NIL
    @inbounds for i in 1:length(buf)
        rev = cons(force(APP(f, buf[i])), rev)
    end
    acc = NIL
    while rev isa Cons
        acc = cons(rev.h, acc); rev = rev.t
    end
    return acc
end

function _override_builtin!(nm::String, ar::Int, fn::Function)
    haskey(F, nm) || return  # only replace what the kernel actually defined
    SLOW_BUILTINS[nm] = F[nm]
    setfn!(nm, fn)           # updates both FV (codegen path) and F (public/APP)
    FA[fn] = ar
end

# Which builtins to override is an empirical, per-function decision (see bin/bench_builtins.jl):
#   reverse  -> 5.7x faster, identical semantics                       [install]
#   length   -> ~1.35x faster, identical semantics                     [install]
#   append   -> ~1.4x SLOWER, but stack-safe (kernel append is non-
#               tail-recursive and overflows on very long lists)       [install for safety]
#   map      -> slower AND changes semantics (kernel leaves per-element
#               results as unforced Bounces); NOT overridden.
# kl_map_fast/kl_map are kept available for callers that want a forced, host-side map.
function install_fast_builtins!()
    _override_builtin!("reverse", 1, kl_reverse)
    _override_builtin!("length", 1, kl_length)
    _override_builtin!("append", 2, kl_append)
    return nothing
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
        # Source-codegen path: compile to Julia and let the JIT specialize it. This is the
        # same path the kernel boots through (proven correct) and benchmarks ~6x faster than
        # the old bytecode VM, which also produced wrong results.
        compile_and_load!(Compiler.compile_top(form), "defun")
        return form.t.h
    end
    # Expression chunk: compile + eval. invokelatest because this form may reference functions
    # that were just defined (yacc/eval re-entry) in a newer world age than our caller.
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
let _ = force, _ = bounce, _ = is_bounce, _ = Bounce, _ = Compiler, _ = FV, _ = setfn!
    # FV and setfn! are referenced by name in Core.eval'd codegen output, so pin them too.
end

end # module Prims