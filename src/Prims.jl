# Prims: KL primitives, apply/curry machinery, and eval loader.

module Prims

using ..Runtime
import ..Runtime: make_absvector
using ..Compiler

export F, FA, GLOBALS, ERR, APP, MKFUN, PARTIAL, equal
export defprim, eval_kl, compile_and_load!, ENV

const F = Dict{String, Function}()
const FA = Dict{Function, Int}()
const GLOBALS = Dict{String, Any}()

function ERR(msg)
    throw(mkexcn(msg))
end

function TOEXCN(e)
    e isa ShenExcn && return e
    return mkexcn(string(e))
end

function MKFUN(arity::Int, fn::Function)
    FA[fn] = arity
    return fn
end

function PARTIAL(f, ar::Int, have::Vector)
    need = ar - length(have)
    g = function(args...)
        extra = collect(args)
        all = copy(have)
        append!(all, extra)
        return f(all...)
    end
    return MKFUN(need, g)
end

function APP(f, args...)
    if is_symbol(f)
        fn = get(F, f.name, nothing)
        fn === nothing && ERR("not a function: $(f.name)")
        f = fn
    end
    f isa Function || ERR("attempt to apply a non-function")
    n = length(args)
    ar = get(FA, f, n)
    if n == ar
        return Base.invokelatest(f, args...)
    elseif n < ar
        return PARTIAL(f, ar, collect(args))
    else
        first = args[1:ar]
        rest = args[ar+1:end]
        r = Base.invokelatest(f, first...)
        return APP(r, rest...)
    end
end

function equal(a, b)
    a === b && return true
    if a isa Cons && b isa Cons
        return equal(a.h, b.h) && equal(a.t, b.t)
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
    F[name] = fn
    FA[fn] = arity
    Compiler.ARITY[name] = arity
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
        return -1
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
                c = read(fh, Char)
                return eof(fh) ? nothing : Int(c)
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
        compile_and_load!(Compiler.compile_top(form), "defun")
        return form.t.h  # function name symbol
    end
    src = Compiler.compile_expr_chunk(form)
    mod = @__MODULE__
    return Base.invokelatest(Core.eval, mod, Meta.parse(src))
end

end # module Prims