# Prims: KL primitives, apply/curry machinery, and eval loader.

module Prims

using ..Runtime
import ..Runtime: make_absvector, NIL, Cons, is_cons, is_symbol, intern
using ..Compiler

export F, FA, GLOBALS, ERR, APP, MKFUN, PARTIAL, equal, BIND, MKTREE, ShenFn
export defprim, eval_kl, compile_and_load!, force, mk_in_stream, mk_out_stream
export max_frame_depth, reset_max_frame_depth!, ensure_port_prims!, install_fast_builtins!
export with_shen_stack

const F = Dict{String, Function}()      # public/dynamic table (string-keyed)
const FA = Dict{Function, Int}()        # legacy, unused on any path; kept for old scripts
const GLOBALS = Dict{String, Any}()

# A Shen function value: a callable that knows its own arity, so the dynamic
# path (APP) never needs a side-table lookup, and creating one (lambda, freeze,
# partial) is a single cheap immutable-struct allocation — no Dict write, no leak.
# Subtypes Function so existing `isa Function` checks and Dict{String,Function} hold.
struct ShenFn <: Function
    fn::Function
    arity::Int
end
@inline (s::ShenFn)(args...) = s.fn(args...)
Base.show(io::IO, s::ShenFn) = print(io, "#<function/", s.arity, ">")

# Registration point for named compiled functions (codegen emits
# `setfn!("name", K_name, arity)` after each defun). The named method itself IS
# the dispatch mechanism — this just maintains the string-keyed table for
# dynamic lookup (APP on a symbol, drivers, REPL) and the codegen arity table.
function setfn!(name::String, fn::Function, arity::Int)
    F[name] = fn isa ShenFn ? fn : ShenFn(fn, arity)
    Compiler.ARITY[name] = arity
    return fn
end
setfn!(name::String, fn::ShenFn) = setfn!(name, fn, fn.arity)

# There is no trampoline: compiled calls are plain Julia calls. force() remains as
# an identity for drivers/scripts written against the old API.
@inline force(x) = x

# Deep recursion support: Julia has no TCO, so cross-function tail recursion
# (Prolog CPS, the typechecker, mutual recursion) consumes Julia stack. Instead of
# a trampoline (which costs an allocation + dynamic dispatch on EVERY call), run the
# Shen world on a Task with a larger reserved stack. The OS commits pages only as the
# stack actually grows, but deep recursion DOES commit them — so the size is also the
# ceiling that turns a runaway (e.g. a non-terminating recursion) into a prompt
# StackOverflowError instead of an OOM. 512 MiB ≈ a few hundred-thousand frames, which
# covers legitimate Prolog/typechecker depth. Override with $SHEN_STACK_MB.
function _shen_stack_bytes()
    mb = tryparse(Int, get(ENV, "SHEN_STACK_MB", ""))
    (mb === nothing || mb <= 0) ? 512 : mb
end

# Re-entrant: if we are ALREADY running on a shen-stack task, just call f directly —
# never stack a second reservation. This is what makes nested entry points (boot! and
# the driver/REPL each wrapping their work) cost only ONE reserved stack at a time.
function with_shen_stack(f)
    get(task_local_storage(), :shen_big_stack, false) && return f()
    t = Task(_shen_stack_bytes() * (1 << 20)) do
        task_local_storage(:shen_big_stack, true)
        f()
    end
    schedule(t)
    try
        return fetch(t)
    catch e
        # Unwrap so ShenExcn (and friends) propagate to drivers as themselves.
        if e isa TaskFailedException
            inner = t.exception
            inner !== nothing && throw(inner)
        end
        rethrow()
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

function ERR(msg)
    throw(mkexcn(msg))
end

function TOEXCN(e)
    e isa ShenExcn && return e
    return mkexcn(string(e))
end

# Invoke a dynamically-obtained function value with world-age recovery: `f` may be
# a method `Core.eval`d at *runtime* (a define/defmacro, a yacc-compiled fn, a macro
# closure from *macros*) living in a world NEWER than this frame. A direct call then
# throws a "method too new" MethodError whose `.f` is `f` itself; retry that one
# call in the latest world. Free on the success path; only dynamic calls pay even
# the try — direct compiled calls never come through here.
@inline function callfn(f::Function, args...)
    try
        return f(args...)
    catch e
        if e isa MethodError && e.f === f
            return Base.invokelatest(f, args...)
        end
        rethrow()
    end
end

@inline MKFUN(arity::Int, fn::Function, klname::String="") = ShenFn(fn, arity)

@inline function PARTIAL(f, ar::Int, have::Vector)
    need = ar - length(have)
    g = function(args...)
        all = copy(have)
        append!(all, args)
        return callfn(_rawfn(f), all...)
    end
    return ShenFn(g, need)
end

@inline _rawfn(f::ShenFn) = f.fn
@inline _rawfn(f::Function) = f

# BIND: hoisted freeze body wrapper. Returns the 0-ary thunk as a ShenFn so thaw/APP
# know its arity without any table.
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
    return ShenFn(raw_thunk, 0)
end

# The dynamic-call boundary: symbol heads, computed heads, partial application,
# over-application. Returns a concrete value (there is no trampoline). For a bare
# host Function (driver stubs, host closures) the arity is assumed exact.
function APP(f, args...)
    # When the head is a SYMBOL we resolve it by name in F and must call it in the
    # LATEST world age (invokelatest), not the caller's. Shen semantics are that a
    # `(define foo ...)` takes effect immediately — but with named-method dispatch a
    # single already-executing compiled chunk (e.g. the kerneltests `do` block that
    # loads a file and then calls one of its functions) is pinned to its start world,
    # so a redefinition done earlier in that same chunk would otherwise be invisible
    # and the stale method would run. Resolving + invokelatest here makes redefinition
    # visible. Direct K_ calls and higher-order APP-of-a-function-value stay fast.
    from_symbol = false
    if is_symbol(f)
        fn = get(F, f.name, nothing)
        fn === nothing && ERR("not a function: $(f.name)")
        f = fn
        from_symbol = true
    end
    n = length(args)
    if f isa ShenFn
        ar = f.arity
        g = f.fn
    elseif f isa Function
        ar = n
        g = f
    else
        ERR("attempt to apply a non-function")
    end

    if n == ar
        return from_symbol ? Base.invokelatest(g, args...) : callfn(g, args...)
    elseif n < ar
        return PARTIAL(f, ar, collect(args))
    else
        r = from_symbol ? Base.invokelatest(g, args[1:ar]...) : callfn(g, args[1:ar]...)
        return APP(r, args[ar+1:end]...)
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

# Define (or redefine) the mangled named method `K_<name>` that compiled code calls
# directly (see Compiler.kl_call_tail / Compiler.fnident). It forwards to the host
# implementation `fn` at fixed arity, so Julia can specialize and inline it. KL defuns
# get their `K_<name>` from cdefun's codegen; prims and fast-builtin overrides get theirs
# here. Redefining an existing `K_<name>` triggers Julia's caller invalidation, so already
# compiled kernel callers transparently pick up the new body (used by _override_builtin!).
function define_named!(name::String, arity::Int, fn::Function)
    ident = Symbol(Compiler.fnident(name))
    params = [Symbol(:a, i) for i in 1:arity]
    @eval @inline $ident($(params...)) = $fn($(params...))
    return nothing
end

function defprim(name::String, arity::Int, fn::Function)
    # Register in the string-keyed table (dynamic APP-of-symbol, REPL, drivers) and the
    # codegen arity table; wrap as a ShenFn so the dynamic path knows the arity with no
    # side-table lookup. No world-age hazard: prims live in the module's initial world.
    setfn!(name, fn, arity)
    push!(Compiler.PRIMS, name)
    # Compiled code emits direct calls `K_<name>(args)` for non-inlined prims at exact
    # arity; define that method so they resolve. (INLINE_PRIM prims also get one — it is
    # harmless and keeps APP→named dispatch uniform.)
    define_named!(name, arity, fn)
    return fn
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
# Shen `/` returns an INTEGER when the division of two integers is exact (e.g.
# (/ 4 2) => 2, not 2.0), matching the reference ports; otherwise a float.
@inline function kl_div(a::Real, b::Real)
    b == 0 && ERR("division by zero")
    (a isa Integer && b isa Integer && rem(a, b) == 0) ? div(a, b) : a / b
end
@inline function kl_div(a, b)
    an = tonum(a); bn = tonum(b)
    bn == 0 && ERR("division by zero")
    (an isa Integer && bn isa Integer && rem(an, bn) == 0) ? div(an, bn) : an / bn
end
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
# `empty?`/`cons?` are pure predicates over the runtime list representation
# ([] === NIL, pairs are Cons), so they inline to a single type/identity check —
# the same hot-path assumption as the inlined hd/tl/+ above. Removes a function
# call per iteration in list-walking loops (sum/map/reverse/...).
@inline kl_emptyp(x) = x === NIL
@inline kl_consp(x) = x isa Cons

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
    setfn!(nm, fn, ar)       # dynamic table + arity
    define_named!(nm, ar, fn) # redefine K_<nm> so compiled callers use the fast version
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
    install_hush_fix!()
    return nothing
end

# Override `pr` so *hush* gates ONLY the standard output stream, never an explicit
# file stream. The 41.2 kernel `pr` does `(if (value *hush*) STR ...)`, which silences
# EVERY stream under -q. The other ports converged on the opposite (shen-cl via a
# native pr override; shen-lua/shen-rust via fix/hush-pr-file): -q hushes chatter to
# stdout, but `pr` to a real file stream always writes. Match that so shen-julia agrees
# on bifrost's hardened hush-file-write case. Compares stream identity to *stoutput*
# (host ===), avoiding any KL stream-equality semantics.
function install_hush_fix!()
    haskey(F, "pr") || return
    cso = get(F, "shen.char-stoutput?", nothing)
    sws = get(F, "shen.write-string", nothing)
    swc = get(F, "shen.write-chars", nothing)
    s2b = get(F, "shen.string->byte", nothing)
    (swc === nothing || s2b === nothing) && return  # kernel not as expected; leave pr alone
    pr = function(str, stream)
        if get(GLOBALS, "*hush*", false) === true && stream === get(GLOBALS, "*stoutput*", nothing)
            return str
        end
        if sws !== nothing && cso !== nothing && Base.invokelatest(cso, stream) === true
            return Base.invokelatest(sws, str, stream)
        end
        return Base.invokelatest(swc, str, stream, Base.invokelatest(s2b, str, 0), 1)
    end
    _override_builtin!("pr", 2, pr)
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

# Root key cross-module names at module init time. This ensures the bindings the
# compiler emits (`force`, `APP`, `PARTIAL`, `BIND`, `MKTREE`, `S`, `setfn!`, … — and
# transitively Compiler via `using`) remain visible via names()/isdefined()/getproperty even under
# PackageCompiler sysimages (ShenJulia.sys), where untraced top-level bindings can
# disappear from the module's reflected globals unless referenced in the precomp
# workload or here. Fixes UndefVarError(:force, ..., ShenJulia.Prims) and similar
# in run-tests.jl micros/smoke/harness loads when using --sysimage.
let _ = force, _ = Compiler, _ = setfn!, _ = APP, _ = PARTIAL, _ = BIND, _ = MKTREE,
    _ = MKLIST, _ = S, _ = ShenFn, _ = callfn, _ = with_shen_stack, _ = KDATA
    # These names are emitted by the compiler into Core.eval'd codegen output (and the
    # named-method bridge), so pin them so PackageCompiler sysimages keep the bindings.
end

# --- Baked kernel (fast boot) ---------------------------------------------
# bin/gen_kernel.jl compiles the whole 41.2 kernel ahead of time into
# kernel_generated.jl: top-level `function K_...` methods (so PRECOMPILATION
# bakes them — no per-startup Core.eval/JIT of ~1138 functions) plus
# `_register_baked_kernel!()` which wires them into F/ARITY at boot. Every name
# the generated file references (setfn!, S, APP, PARTIAL, MKFUN, BIND, MKTREE,
# force, callfn, ShenFn, TOEXCN, KDATA, and the K_ methods) is in scope here.
# Guarded so the source path still works before the file has been generated.
# NOTE: Julia does not track an isfile() result as a precompile dependency, so if
# you (re)generate kernel_generated.jl you must force a recompile of this module
# (a content change here, or `Base.compilecache`), or the stale image silently
# keeps HAS_BAKED_KERNEL=false. [baked-kernel guard v6 — S41.2 refresh + world-age demod fix]
if isfile(joinpath(@__DIR__, "kernel_generated.jl"))
    include(joinpath(@__DIR__, "kernel_generated.jl"))
    const HAS_BAKED_KERNEL = true
else
    const HAS_BAKED_KERNEL = false
    _register_baked_kernel!() = error("baked kernel not generated — run: julia --project=. bin/gen_kernel.jl")
end

end # module Prims