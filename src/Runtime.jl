# Runtime: Shen/KLambda data representation and reader for the Julia port.
#
#   numbers  -> Julia Number
#   strings  -> Julia String
#   booleans -> true / false (KL symbols true/false)
#   symbols  -> ShenSymbol (interned, identity ==)
#   ()       -> NIL (empty list singleton)
#   cons     -> Cons(h, t)
#   vectors  -> AbsVector (0-indexed raw store, KL absvector)
#   streams  -> InStream / OutStream
#   exceptions -> ShenExcn

module Runtime

export NIL, Cons, ShenSymbol, ShenExcn, AbsVector, InStream, OutStream
export intern, cons, is_cons, is_symbol, is_stream, is_absvector
export mkexcn, from_vec, to_str, reader, read_all
export Instr, BytecodeFunc, BCClosure

# Transducers.jl (added as dep for ecosystem/perf exploration).
# Prototype: fused pipelines for list map/fold etc inside *host* (avoids deep recursive Shen map/append
# for pure cases; temp vector for fusion then back to proper Cons list for semantics).
# Real wins for chained (map f (map g (filter p xs))) etc that appear after macro; or stlib/tests.
# Shen model is eager proper lists, so we materialize; future codegen could emit transducer exprs directly.
using Transducers
using IterTools

# ---------------------------------------------------------------------------
# Symbols
# ---------------------------------------------------------------------------

mutable struct ShenSymbol
    name::String
end

const _symtab = Dict{String, ShenSymbol}()

function intern(name::String)::ShenSymbol
    # Faster intern with get! (single lookup, closure only on miss). Common symbols benefit.
    get!(() -> ShenSymbol(name), _symtab, name)
end

function intern(name::ShenSymbol)::ShenSymbol
    return name
end

is_symbol(x) = x isa ShenSymbol

Base.show(io::IO, s::ShenSymbol) = print(io, s.name)
Base.:(==)(a::ShenSymbol, b::ShenSymbol) = a.name == b.name
Base.hash(s::ShenSymbol, h::UInt) = hash(s.name, h)

# ---------------------------------------------------------------------------
# Empty list / cons
# ---------------------------------------------------------------------------

struct NilType end
const NIL = NilType()

struct Cons
    h::Any
    t::Any
end

cons(h, t) = Cons(h, t)
is_cons(x) = x isa Cons

Base.show(io::IO, ::NilType) = print(io, "()")

# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

mutable struct ShenExcn
    msg::String
end

mkexcn(msg::String) = ShenExcn(msg)
mkexcn(msg) = ShenExcn(string(msg))

# ---------------------------------------------------------------------------
# Absvectors (KL 0-indexed)
# ---------------------------------------------------------------------------

mutable struct AbsVector
    n::Int
    data::Vector{Any}
end

function make_absvector(n::Int, fill)
    return AbsVector(n, [fill for _ in 1:n])
end

is_absvector(x) = x isa AbsVector

# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

mutable struct OutStream
    write::Function
    closefn::Function
    name::String
end

mutable struct InStream
    readbyte::Function
    closefn::Function
    name::String
    eof::Bool
end

is_stream(x) = x isa OutStream || x isa InStream

# ---------------------------------------------------------------------------
# Bytecode VM types (for alternative to source-codegen path; data-driven,
# world-age free defs, explicit frame stack for deep recursion, flat locals,
# zero-alloc self-tail loops via SELF_TAIL_CALL).
# Instr is compact; BytecodeFunc holds the compiled unit (reused for closures via templates).
# BCClosure carries captured upvals (values at MAKE time; KL lets/lambdas are immutable).
# ---------------------------------------------------------------------------

struct Instr
    op::UInt8
    a::Int32
    b::Int32
end

mutable struct BytecodeFunc
    name::String
    arity::Int
    nlocals::Int
    code::Vector{Instr}
    consts::Vector{Any}
end

struct BCClosure
    template::BytecodeFunc
    upvals::Vector{Any}
end

# ---------------------------------------------------------------------------
# List helpers
# ---------------------------------------------------------------------------

function from_vec(arr::AbstractVector, start::Int=1)
    n = length(arr) - start + 1
    # Pre-allocate by building the tail first (we already cons in reverse order).
    # For large lists this avoids many small allocations in the Cons chain.
    acc = NIL
    @inbounds for i in (length(arr)):-1:start
        acc = cons(arr[i], acc)
    end
    return acc
end

# Overload for known-length cases coming from iterators/collect (helps inference
# and lets callers pre-size the source array).
function from_vec(arr::Vector{Any})
    acc = NIL
    @inbounds for i in length(arr):-1:1
        acc = cons(arr[i], acc)
    end
    return acc
end

# Make Cons and NIL proper Julia iterators.
# This lets us use the full power of Base.Iterators (map, filter, flatten, partition,
# takewhile, countfrom, etc.) and Transducers.jl (Map, Filter, Cat, TakeWhile, foldl,
# eduction for fusion, early termination with reduced, etc.) directly on Shen lists.
#
# Benefits:
# - Lazy composition of transformations (no intermediate Cons until final materialization).
# - Fusion via Transducers (e.g. map+filter in one pass).
# - Access to rich iterator combinators without writing recursive Shen or manual while loops.
# - The numeric self-tail micro (while + rebind) is already optimal for pure recursion;
#   iterators + transducers shine for list processing (powerset, cartesian, primes, nqueens,
#   unification, semantic nets, etc. in the reports/kerneltests).
#
# See:
#   https://docs.julialang.org/en/v1/base/iterators/
#   https://github.com/JuliaFolds/Transducers.jl
#
# We still materialize to proper Cons at the end so that `cons?`, pattern matching,
# `hd`/`tl`, and the rest of the Shen world continue to work.

function Base.iterate(::NilType, state=nothing)
    nothing
end

function Base.iterate(c::Cons, state=c)
    if state === NIL || !is_cons(state)
        nothing
    else
        (state.h, state.t)
    end
end

Base.IteratorSize(::Type{Union{Cons, NilType}}) = Base.SizeUnknown()
Base.eltype(::Type{Union{Cons, NilType}}) = Any

# Fast host-side list processing using Base.Iterators + IterTools + Transducers
# for fusion, laziness where useful, and richer combinators with low allocation.
# These are intended for pure transformations. They traverse the input Cons via the
# iterator protocol (no manual while in our code) and can fuse pipelines before
# materializing the final Cons.
#
# See:
#   https://docs.julialang.org/en/v1/base/iterators/
#   https://github.com/JuliaFolds/Transducers.jl
#   https://juliacollections.github.io/IterTools.jl/stable/
#
# IterTools adds useful things like imap (lazy map), partition, groupby, distinct,
# takenth, repeatedly, chain, nth, etc. We use them to provide more efficient
# host-side implementations of common list ops that appear in stlib/tests/reports.
# The final output is always a proper Shen Cons list for semantics.

function map_list(f, lst)
    # Use IterTools.imap (lazy) + Transducers for the pipeline; collect materializes.
    # Pre-allocation happens inside collect based on hints.
    collect(IterTools.imap(f, lst)) |> from_vec
end

function filter_list(pred, lst)
    collect(IterTools.filter(pred, lst)) |> from_vec
end

function fold_list(op, init, lst)
    foldl(op, lst; init=init)
end

# Additional useful list ops powered by IterTools (can be called from Julia-side
# code or wired into F for pure cases).
function partition_list(n, lst)
    # Returns iterator of tuples; we turn each into a Cons sublist then top-level Cons.
    IterTools.partition(lst, n) .|> (t -> from_vec(collect(t))) |> from_vec
end

function groupby_list(f, lst)
    # Group by key function; returns pairs (key, group_list)
    IterTools.groupby(f, lst) .|> ((k, g) -> cons(k, from_vec(collect(g)))) |> from_vec
end

function distinct_list(lst)
    IterTools.distinct(lst) |> collect |> from_vec
end

export map_list, filter_list, fold_list, partition_list, groupby_list, distinct_list

# Note on multiple dispatch / types:
# The list helpers above are intentionally generic (any callable for f/pred, any
# iterable that yields the elements for lst). Because we defined Base.iterate for
# Cons/NilType, `collect(Map(f), some_cons_list)` and `foldl(..., some_cons_list)`
# automatically use Julia's iterator protocol + Transducers' fusion.
# Adding narrow methods like `map_list(f::Function, lst::Cons)` would risk the
# recursion seen during development; the untyped versions are sufficient and let
# the compiler do union splitting / inference where the call site is concrete.

# ---------------------------------------------------------------------------
# KL reader
# ---------------------------------------------------------------------------

const _TRUE = true
const _FALSE = false

function _is_number_token(t::String)
    occursin(r"^[\+\-]?\d+$", t) && return true
    occursin(r"^[\+\-]?\d*\.\d+$", t) && return true
    occursin(r"^[\+\-]?\d+\.\d*$", t) && return true
    occursin(r"^[\+\-]?\d+[eE][\+\-]?\d+$", t) && return true
    occursin(r"^[\+\-]?\d*\.\d+[eE][\+\-]?\d+$", t) && return true
    return false
end

function reader(src::String)
    pos = Ref(1)
    len = length(src)

    peek() = pos[] <= len ? codeunit(src, pos[]) : 0

    function skipws()
        while pos[] <= len
            c = codeunit(src, pos[])
            if c in (0x20, 0x09, 0x0a, 0x0d, 0x0c)
                pos[] += 1
            else
                break
            end
        end
    end

    function read_form()
        skipws()
        pos[] > len && return nothing
        c = codeunit(src, pos[])
        if c == 0x28
            return read_list()
        elseif c == 0x22
            return read_string()
        elseif c == 0x29
            error("KL reader: unexpected )")
        else
            return read_atom()
        end
    end

    function read_list()
        pos[] += 1
        items = Any[]
        while true
            skipws()
            pos[] > len && error("KL reader: unexpected EOF in list")
            if codeunit(src, pos[]) == 0x29
                pos[] += 1
                break
            end
            push!(items, read_form())
        end
        isempty(items) && return NIL
        return from_vec(items)
    end

    function read_string()
        pos[] += 1
        start = pos[]
        while pos[] <= len && codeunit(src, pos[]) != 0x22
            pos[] += 1
        end
        pos[] > len && error("KL reader: unterminated string")
        s = src[start:pos[]-1]
        pos[] += 1
        return s
    end

    function read_atom()
        start = pos[]
        while pos[] <= len
            c = codeunit(src, pos[])
            if c in (0x20, 0x09, 0x0a, 0x0d, 0x0c, 0x28, 0x29, 0x22)
                break
            end
            pos[] += 1
        end
        t = src[start:pos[]-1]
        if _is_number_token(t)
            if occursin('.', t) || occursin('e', t) || occursin('E', t)
                return parse(Float64, t)
            else
                return parse(Int, t)
            end
        end
        t == "true" && return _TRUE
        t == "false" && return _FALSE
        return intern(t)
    end

    return () -> begin
        skipws()
        pos[] > len && return nothing
        return read_form()
    end
end

function read_all(src::String)
    it = reader(src)
    forms = Any[]
    while true
        f = it()
        f === nothing && break
        push!(forms, f)
    end
    return forms
end

# ---------------------------------------------------------------------------
# Printer (debugging)
# ---------------------------------------------------------------------------

function to_str(x, seen=IdDict{Any,Bool}())
    if x === NIL
        return "()"
    elseif x isa Number
        if x isa Integer && !isa(x, Bool)
            return string(x)
        end
        return string(x)
    elseif x isa Bool
        return x ? "true" : "false"
    elseif x isa String
        return "\"" * x * "\""
    elseif is_symbol(x)
        return x.name
    elseif is_cons(x)
        parts = String[]
        cur = x
        while is_cons(cur)
            push!(parts, to_str(cur.h, seen))
            cur = cur.t
        end
        if cur === NIL
            return "(" * join(parts, " ") * ")"
        else
            return "(" * join(parts, " ") * " . " * to_str(cur, seen) * ")"
        end
    elseif x isa ShenExcn
        return "#<exception: $(x.msg)>"
    elseif x isa Function
        return "#<function>"
    elseif x isa AbsVector
        return "#<vector $(x.n)>"
    else
        return string(x)
    end
end

end # module Runtime