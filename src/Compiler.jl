# Compiler: translate KLambda forms to Julia source for eval().
#
# Statement-based codegen: ctail emits statements ending in return, so control
# flow maps to Julia if/elseif. Tail calls emit return (no native TCO in Julia;
# deep recursion workloads may need backend loop transforms later).

module Compiler

using ..Runtime  # bare to allow Runtime.XXX in bc dups + names

export ARITY, KDATA, prescan, compile_top, compile_expr_chunk, cexpr, ctail
export bc_compile_top, bc_cdefun, bc_compile_expr_chunk, BC_F

const ARITY = Dict{String, Int}()
const KDATA = Any[]
const PRIMS = Set{String}()

car(x::Cons) = x.h
cdr(x::Cons) = x.t

function to_array(lst)
    # Pre-allocate when possible (len is O(n) but cheap and we pay it anyway for len()).
    n = len(lst)
    a = Vector{Any}(undef, n)
    i = 1
    @inbounds while is_cons(lst)
        a[i] = lst.h
        lst = lst.t
        i += 1
    end
    return a
end

function len(lst)
    n = 0
    while is_cons(lst)
        n += 1
        lst = lst.t
    end
    return n
end

function extend(env::Dict{String,String}, kname::String, lname::String)
    e = copy(env)
    e[kname] = lname
    return e
end

let _gsn = Ref(0)
    global gen
    function gen(prefix="t")
        _gsn[] += 1
        return prefix * string(_gsn[])
    end
end

# Small helper for codegen temps: pre-allocate with known or estimated capacity
# to reduce realloc churn during cexpr/ctail walks.
function _new_any_vec(hint::Int=16)
    v = Vector{Any}()
    sizehint!(v, hint)
    v
end

function qstr(s::String)
    return repr(s)
end

function symlit(name::String)
    return "S($(qstr(name)))"
end

function cnum(n::Number)
    if n isa Integer && !isa(n, Bool)
        return string(n)
    end
    return repr(n)
end

function catom(form, env::Dict{String,String})
    if form isa Number
        return cnum(form)
    elseif form isa Bool
        return form ? "true" : "false"
    elseif form isa String
        return qstr(form)
    elseif form === NIL
        return "NIL"
    elseif is_symbol(form)
        lname = get(env, form.name, nothing)
        lname !== nothing && return lname
        return symlit(form.name)
    else
        error("catom: cannot compile $(form)")
    end
end

# Leverage multiple dispatch for common literal cases in codegen (helps inference
# in the compiler itself, even if the emitted code is still dynamic for KL values).
catom(x::Number, env) = cnum(x)
catom(x::Bool, env)   = x ? "true" : "false"
catom(x::String, env) = qstr(x)
catom(::typeof(NIL), env) = "NIL"

function ftab_ref(name::String)
    return "F[$(qstr(name))]"
end

function kl_call(form::Cons, env::Dict{String,String})
    head = car(form)
    args = to_array(cdr(form))
    cargs = [cexpr(a, env) for a in args]
    argstr = join(cargs, ", ")

    if is_symbol(head) && !haskey(env, head.name)
        name = head.name
        ar = get(ARITY, name, nothing)
        if ar !== nothing
            if length(args) == ar
                return "$(ftab_ref(name))($(argstr))"
            elseif length(args) < ar
                pack = isempty(args) ? "Any[]" : "[$(argstr)]"
                return "PARTIAL($(ftab_ref(name)), $ar, $pack)"
            else
                first = cargs[1:ar]
                rest = cargs[ar+1:end]
                return "APP($(ftab_ref(name))($(join(first, ", "))), $(join(rest, ", ")))"
            end
        else
            if isempty(args)
                return "APP($(symlit(name)))"
            end
            return "APP($(symlit(name)), $(argstr))"
        end
    else
        hv = cexpr(head, env)
        if isempty(args)
            return "APP($hv)"
        end
        return "APP($hv, $(argstr))"
    end
end

# Tail-call emission for bounce + self rebind+continue support (harden for all defuns).
# For self-tail in tail ctx of cdefun: emit rebind assigns + "continue" (no "return", to loop in while).
# For cross-fn tail: emit "bounce(Fname, args)" so raw returns Bounce (driven by wrapper force, no eager stack growth).
# This + while in cdefun ensures self-rec (common in core/prolog/stlib length, callrec, retract etc) uses Julia loop not stack.
# Threaded only to ctail* (tail pos); cexpr uses kl_call (eager for value pos known fns).
#
# See also TailRec.jl for a general @tailrec macro approach in Julia.
function kl_call_tail(form::Cons, env::Dict{String,String}, selfname::Union{String,Nothing}=nothing, self_lnames::Vector{String}=String[])
    head = car(form)
    args = to_array(cdr(form))
    cargs = [cexpr(a, env) for a in args]
    argstr = join(cargs, ", ")

    if is_symbol(head) && !haskey(env, head.name)
        name = head.name
        ar = get(ARITY, name, nothing)
        if ar !== nothing
            if length(args) == ar
                if selfname !== nothing && name == selfname && length(self_lnames) == ar
                    rebinds = String[]
                    for i in 1:ar
                        push!(rebinds, "$(self_lnames[i]) = $(cargs[i])")
                    end
                    return join(rebinds, "; ") * "; continue"
                end
                return "bounce($(ftab_ref(name)), $(argstr))"
            elseif length(args) < ar
                pack = isempty(args) ? "Any[]" : "[$(argstr)]"
                return "PARTIAL($(ftab_ref(name)), $ar, $pack)"
            else
                first = cargs[1:ar]
                rest = cargs[ar+1:end]
                tmp = gen("r")
                firstcall = "force(bounce($(ftab_ref(name)), $(join(first, ", "))))"
                return "(let $tmp = $firstcall; APP($tmp, $(join(rest, ", "))) end)"
            end
        else
            if isempty(args)
                return "APP($(symlit(name)))"
            end
            return "APP($(symlit(name)), $(argstr))"
        end
    else
        hv = cexpr(head, env)
        if isempty(args)
            return "APP($hv)"
        end
        return "APP($hv, $(argstr))"
    end
end

function cons_chain(form::Cons)
    elems = Any[]
    cur = form
    while is_cons(cur) && is_symbol(car(cur)) && car(cur).name == "cons" &&
          is_cons(cdr(cur)) && is_cons(cdr(cdr(cur))) && cdr(cdr(cdr(cur))) === NIL
        push!(elems, car(cdr(cur)))
        cur = car(cdr(cdr(cur)))
    end
    return elems, cur
end

const _KL_SPECIALS = Set([
    "defun", "lambda", "let", "do", "if", "cond", "and", "or", "not",
    "set", "put", "get", "type", "freeze", "trap-error", "protect",
])

function is_lit(form, env::Dict{String,String})
    if form isa Number || form isa String || form isa Bool
        return true
    end
    form === NIL && return true
    is_symbol(form) && return !haskey(env, form.name)
    if is_cons(form)
        if is_symbol(form.h) && !haskey(env, form.h.name)
            name = form.h.name
            if haskey(ARITY, name) || name in _KL_SPECIALS
                return false
            end
        end
        return is_lit(form.h, env) && is_lit(form.t, env)
    end
    return false
end

function lit_count(form)
    if !is_cons(form)
        return 1
    end
    return 1 + lit_count(form.h) + lit_count(form.t)
end

function try_lit_const(form, env::Dict{String,String})
    is_cons(form) || return nothing
    is_lit(form, env) || return nothing
    lit_count(form) >= 24 || return nothing
    push!(KDATA, form)
    return "KDATA[$(length(KDATA))]"
end

function cexpr(form, env::Dict{String,String})
    if !is_cons(form)
        form isa Number && return cnum(form)
        return catom(form, env)
    end

    head = car(form)
    if is_symbol(head) && head.name == "cons" && !haskey(env, "cons")
        k = try_lit_const(form, env)
        k !== nothing && return k
        elems, tail = cons_chain(form)
        if length(elems) >= 16
            parts = [cexpr(e, env) for e in elems]
            return "MKLIST([$(join(parts, ", "))], $(cexpr(tail, env)))"
        end
    end

    k = try_lit_const(form, env)
    k !== nothing && return k

    if is_symbol(head) && !haskey(env, head.name)
        op = head.name
        if op in ("if", "cond", "let", "do", "trap-error", "and", "or")
            # Force the IIFE result: ctail inside may "return bounce(..)" for calls (from kl_call_tail in value-ctx controls);
            # force drives to concrete so if/let etc in expr pos yield values not Bounce (prevents TypeError if-Bool-Bounce etc).
            return "force((()->($(ctail(form, env))))())"
        elseif op == "lambda"
            v = car(cdr(form))
            body = car(cdr(cdr(form)))
            ln = gen("v")
            e2 = extend(env, v.name, ln)
            return "MKFUN(1, $ln -> $(cexpr(body, e2)))"
        elseif op == "freeze"
            body = car(cdr(form))
            return "MKFUN(0, () -> $(cexpr(body, env)))"
        elseif op == "defun"
            error("defun in expression position")
        elseif op == "type"
            return cexpr(car(cdr(form)), env)
        else
            return kl_call(form, env)
        end
    else
        return kl_call(form, env)
    end
end

# Flatten (do A (do B (do C D))) into [A, B, C, D] to avoid deep nesting
# (critical for init.kl — Julia has no TCO on nested thunks).
function flatten_do(form)
    forms = Any[]
    cur = form
    while is_cons(cur) && is_symbol(car(cur)) && car(cur).name == "do"
        items = to_array(cdr(cur))
        if length(items) == 1
            cur = items[1]
            continue
        end
        for i in 1:length(items)-1
            push!(forms, items[i])
        end
        cur = items[end]
    end
    push!(forms, cur)
    return forms
end

# Nested if/else (not elseif flattening): preserves correct semantics for
# (and A (and B C)) inside cond-test IIFEs.  Wrap nested else branches in
# begin/end so Julia parses them without elseif/end mismatches.
function ctail_and(form::Cons, env::Dict{String,String}, selfname::Union{String,Nothing}=nothing, self_lnames::Vector{String}=String[])
    a = car(cdr(form))
    b = car(cdr(cdr(form)))
    if is_cons(b) && is_symbol(car(b)) && car(b).name == "and"
        return "if $(cexpr(a, env)); begin $(ctail_and(b, env, selfname, self_lnames)) end else return false; end"
    else
        ths = _wrap_for_control(_wrap_else(ctail(b, env, selfname, self_lnames)))
        return "if $(cexpr(a, env)); $ths else return false; end"
    end
end

function ctail_or(form::Cons, env::Dict{String,String}, selfname::Union{String,Nothing}=nothing, self_lnames::Vector{String}=String[])
    a = car(cdr(form))
    b = car(cdr(cdr(form)))
    if is_cons(b) && is_symbol(car(b)) && car(b).name == "or"
        return "if $(cexpr(a, env)); return true else begin $(ctail_or(b, env, selfname, self_lnames)) end end"
    else
        els = _wrap_for_control(_wrap_else(ctail(b, env, selfname, self_lnames)))
        return "if $(cexpr(a, env)); return true else $els end"
    end
end

function _wrap_else(body::String)
    # Julia rejects `else if`; wrap else-branches that begin with `if`.
    if startswith(strip(body), "if ")
        return "begin $body end"
    end
    return body
end

function _wrap_for_control(body::String)
    # Wrap control bodies (that may contain bare "return" or "rebind; continue" from self-tail)
    # in begin/end when they start with if/let/begin or contain continue, so that they can appear
    # as then/else/cond-clause bodies inside larger if/elseif/cond/let/do without breaking the
    # clause structure syntax ( "if t; rebind; continue elseif .." is invalid; needs begin).
    s = strip(body)
    if startswith(s, "if ") || startswith(s, "let ") || startswith(s, "begin ") || occursin("continue", body)
        return "begin $body end"
    end
    return body
end

function ctail_if(form::Cons, env::Dict{String,String}, selfname::Union{String,Nothing}=nothing, self_lnames::Vector{String}=String[])
    test = car(cdr(form))
    th = car(cdr(cdr(form)))
    el = cdr(cdr(cdr(form)))
    ths = _wrap_for_control(ctail(th, env, selfname, self_lnames))
    if is_cons(el)
        els = _wrap_else(_wrap_for_control(ctail(car(el), env, selfname, self_lnames)))
        return "if $(cexpr(test, env)); $ths else $els end"
    else
        return "if $(cexpr(test, env)); $ths else return false; end"
    end
end

function ctail(form, env::Dict{String,String}, selfname::Union{String,Nothing}=nothing, self_lnames::Vector{String}=String[])
    if !is_cons(form)
        v = form isa Number ? cnum(form) : catom(form, env)
        return "return $v"
    end

    head = car(form)
    if is_symbol(head) && !haskey(env, head.name)
        op = head.name
        if op == "if"
            return ctail_if(form, env, selfname, self_lnames)
        elseif op == "cond"
            clauses = to_array(cdr(form))
            parts = String[]
            for (i, cl) in enumerate(clauses)
                test = car(cl)
                res = car(cdr(cl))
                body = _wrap_for_control(_wrap_else(ctail(res, env, selfname, self_lnames)))
                if i == 1
                    push!(parts, "if $(cexpr(test, env)); $body")
                else
                    push!(parts, "elseif $(cexpr(test, env)); $body")
                end
            end
            push!(parts, "else return ERR(\"cond failure\"); end")
            return join(parts, " ")
        elseif op == "let"
            v = car(cdr(form))
            val = car(cdr(cdr(form)))
            body = car(cdr(cdr(cdr(form))))
            ln = gen("v")
            valc = cexpr(val, env)
            e2 = extend(env, v.name, ln)
            btail = _wrap_for_control(ctail(body, e2, selfname, self_lnames))
            return "local $ln = $valc; $btail"
        elseif op == "do"
            forms = flatten_do(form)
            stmts = String[]
            for i in 1:length(forms)-1
                es = cexpr(forms[i], env)
                push!(stmts, "(()->$es)();")
            end
            push!(stmts, _wrap_for_control(ctail(forms[end], env, selfname, self_lnames)))
            return join(stmts, " ")
        elseif op == "and"
            return _wrap_for_control(ctail_and(form, env, selfname, self_lnames))
        elseif op == "or"
            return _wrap_for_control(ctail_or(form, env, selfname, self_lnames))
        elseif op == "trap-error"
            expr = car(cdr(form))
            handler = car(cdr(cdr(form)))
            hc = cexpr(handler, env)
            return """try; return $(cexpr(expr, env)); catch e; return APP($hc, TOEXCN(e)); end"""
        elseif op == "type"
            return ctail(car(cdr(form)), env, selfname, self_lnames)
        elseif op in ("lambda", "freeze")
            return "return $(cexpr(form, env))"
        else
            # tail call pos: use kl_call_tail; for self emit "rebinds; continue" (use as-is for while loop)
            # for other tail emit bounce... which we prefix return to exit raw returning the Bounce.
            ct = kl_call_tail(form, env, selfname, self_lnames)
            if occursin("continue", ct)
                return ct
            else
                return "return $ct"
            end
        end
    else
        ct = kl_call_tail(form, env, selfname, self_lnames)
        if occursin("continue", ct)
            return ct
        else
            return "return $ct"
        end
    end
end

function cdefun(form::Cons)
    name = car(cdr(form)).name
    params = to_array(car(cdr(cdr(form))))
    body = car(cdr(cdr(cdr(form))))
    env = Dict{String,String}()
    lnames = String[]
    for p in params
        ln = gen("a")
        env[p.name] = ln
        push!(lnames, ln)
    end
    ARITY[name] = length(params)
    rawname = "rawf" * gen("impl")
    paramstr = join(lnames, ", ")
    # Self-tail while + rebind + continue for *all* defuns (source path, pre-gen .jls replay, bc already has).
    # Ensures self-rec (e.g. in init/prolog/stlib/core recursive fns) executes as bounded Julia loop inside one raw activation
    # (no additional Julia stack per rec step; trampoline only for mutual/cross). Combined with explicit FRAME_STACK wiring
    # and early env seeding, enables clean full initialise! without SO or partial state ("printF undefined", missing *macros*).
    #
    # This is a custom, zero-overhead implementation of tail-recursion-to-loop (TRO), specialized for our KL compiler.
    # We detect self-tails using threaded `selfname`/`self_lnames` (from the surrounding defun) and emit direct
    # "var = arg; ...; continue" (plus _wrap_for_control to keep it valid inside if/let/etc.).
    # Related work / alternatives in the Julia ecosystem: TailRec.jl (https://github.com/TakekazuKATO/TailRec.jl)
    # provides a @tailrec macro for similar rewriting; Iterators + Transducers (for list pipelines) complement
    # this by reducing the need for recursion on data structures. We roll our own here for tight integration with
    # the Bounce trampoline, _safe_caller world-age wrappers, explicit frames, bc VM, and precompilation .jls path
    # (which snapshots the already-expanded while-loop sources).
    body_src = ctail(body, env, name, lnames)
    src = sanitize_julia("""begin
local $rawname = function($paramstr)
    while true
        $body_src
    end
end
let w = _safe_caller($rawname, $(qstr(name)))
    F[$(qstr(name))] = w
    FA[w] = $(length(params))
end
end""")
    return src
end

function prescan(forms)
    # Pre-size the ARITY table? Not really possible without two passes, but
    # the current O(n) walk over all forms is fine (done once per load or pre-gen).
    for f in forms
        if is_cons(f) && is_symbol(car(f)) && car(f).name == "defun"
            name = car(cdr(f)).name
            params = car(cdr(cdr(f)))
            ARITY[name] = len(params)
        end
    end
end

function compile_expr_chunk(form)
    return sanitize_julia("return ($(cexpr(form, Dict{String,String}())))")
end

function sanitize_julia(src::String)
    return src
end

function compile_top(form)
    if is_cons(form) && is_symbol(car(form)) && car(form).name == "defun"
        return cdefun(form)
    else
        return "($(cexpr(form, Dict{String,String}())));"
    end
end

# ===================================================================
# Bytecode VM compiler prototype (minimal effective)
# - Instr + BytecodeFunc + BCClosure from Runtime
# - bc_* mirror ctail/cexpr emitting ops for core forms only
# - Used by eval_kl for user (define), run_kl, load .shen
# - Kernel boot stays on source for full compat (trap etc)
# ===================================================================

const BC_F = Dict{String, Runtime.BytecodeFunc}()

const _BC_OP = Dict{Symbol,UInt8}(
    :LOAD_LOCAL => 0x00,
    :STORE_LOCAL => 0x01,
    :LOAD_CONST => 0x02,
    :LOAD_UPVAL => 0x03,
    :CALL => 0x04,
    :TAIL_CALL => 0x05,
    :SELF_TAIL_CALL => 0x06,
    :RETURN => 0x07,
    :JUMP => 0x08,
    :JUMP_FALSE => 0x09,
    :MAKE_CLOSURE => 0x0a,
    :POP => 0x0b
)

mutable struct _BCtx
    code::Vector{Runtime.Instr}
    consts::Vector{Any}
    locals::Dict{String,Int}
    nextslot::Int
    maxlocals::Int
    selfname::Union{String,Nothing}
end

function _new_bctx(selfname::Union{String,Nothing}=nothing)
    _BCtx(Runtime.Instr[], Any[], Dict{String,Int}(), 0, 0, selfname)
end

function _alloc_slot!(ctx::_BCtx, nm::String)
    s = ctx.nextslot
    ctx.nextslot += 1
    ctx.locals[nm] = s
    ctx.maxlocals = max(ctx.maxlocals, ctx.nextslot)
    s
end

function _emit!(ctx::_BCtx, op::Symbol, a::Integer=0, b::Integer=0)
    push!(ctx.code, Runtime.Instr(get(_BC_OP, op, 0xff), Int32(a), Int32(b)))
    length(ctx.code) - 1
end

function _addc!(ctx::_BCtx, v::Any)
    push!(ctx.consts, v)
    length(ctx.consts) - 1
end

function _patch!(ctx::_BCtx, pos::Int, tgt::Int)
    old = ctx.code[pos+1]
    ctx.code[pos+1] = Runtime.Instr(old.op, Int32(tgt), old.b)
end

function bc_catom(form, ctx::_BCtx, env::Dict{String,Int})
    if form isa Number || form isa String || form isa Bool || form === NIL
        return (:const, _addc!(ctx, form))
    elseif is_symbol(form)
        if haskey(env, form.name)
            return (:local, env[form.name])
        else
            return (:const, _addc!(ctx, form))
        end
    end
    error("bc_catom")
end

function bc_kl_call(form::Cons, ctx::_BCtx, env::Dict{String,Int}, tailp::Bool)
    head = car(form)
    args = to_array(cdr(form))
    for a in args
        bc_cexpr(a, ctx, env)
    end
    na = length(args)
    if is_symbol(head) && !haskey(env, head.name)
        nm = head.name
        tgt = haskey(BC_F, nm) ? BC_F[nm] : intern(nm)
        ci = _addc!(ctx, tgt)
        if tailp && ctx.selfname !== nothing && nm == ctx.selfname && get(ARITY, nm, -1) == na
            _emit!(ctx, :SELF_TAIL_CALL, ci, na)
            return
        end
        _emit!(ctx, tailp ? :TAIL_CALL : :CALL, ci, na)
    else
        bc_cexpr(head, ctx, env)
        ci = _addc!(ctx, :__computed_fn__)
        _emit!(ctx, tailp ? :TAIL_CALL : :CALL, ci, na)
    end
end

function bc_cexpr(form, ctx::_BCtx, env::Dict{String,Int})
    if !is_cons(form)
        k, v = bc_catom(form, ctx, env)
        _emit!(ctx, k == :local ? :LOAD_LOCAL : :LOAD_CONST, v)
        return
    end
    head = car(form)
    if is_symbol(head) && !haskey(env, head.name)
        op = head.name
        if op == "if"
            test = car(cdr(form))
            th = car(cdr(cdr(form)))
            el = cdr(cdr(cdr(form)))
            bc_cexpr(test, ctx, env)
            jf = _emit!(ctx, :JUMP_FALSE, 0)
            bc_cexpr(th, ctx, env)
            je = _emit!(ctx, :JUMP, 0)
            ep = length(ctx.code)
            _patch!(ctx, jf, ep)
            if is_cons(el)
                bc_cexpr(car(el), ctx, env)
            else
                _emit!(ctx, :LOAD_CONST, _addc!(ctx, false))
            end
            _patch!(ctx, je, length(ctx.code))
            return
        elseif op == "cond"
            clauses = to_array(cdr(form))
            ejs = Int[]
            for (i, cl) in enumerate(clauses)
                bc_cexpr(car(cl), ctx, env)
                jf = _emit!(ctx, :JUMP_FALSE, 0)
                bc_cexpr(car(cdr(cl)), ctx, env)
                if i < length(clauses)
                    push!(ejs, _emit!(ctx, :JUMP, 0))
                end
                _patch!(ctx, jf, length(ctx.code))
            end
            _emit!(ctx, :LOAD_CONST, _addc!(ctx, false))
            for j in ejs
                _patch!(ctx, j, length(ctx.code))
            end
            return
        elseif op == "let"
            v = car(cdr(form))
            val = car(cdr(cdr(form)))
            body = car(cdr(cdr(cdr(form))))
            bc_cexpr(val, ctx, env)
            sl = _alloc_slot!(ctx, v.name)
            _emit!(ctx, :STORE_LOCAL, sl)
            e2 = copy(env)
            e2[v.name] = sl
            bc_cexpr(body, ctx, e2)
            return
        elseif op == "do"
            fs = flatten_do(form)
            for i in 1:length(fs)-1
                bc_cexpr(fs[i], ctx, env)
                _emit!(ctx, :POP)
            end
            bc_cexpr(fs[end], ctx, env)
            return
        elseif op in ("and", "or")
            a = car(cdr(form))
            b = car(cdr(cdr(form)))
            bc_cexpr(a, ctx, env)
            jf = _emit!(ctx, :JUMP_FALSE, 0)
            bc_cexpr(b, ctx, env)
            je = _emit!(ctx, :JUMP, 0)
            _patch!(ctx, jf, length(ctx.code))
            if op == "and"
                _emit!(ctx, :LOAD_CONST, _addc!(ctx, false))
            end
            _patch!(ctx, je, length(ctx.code))
            return
        elseif op == "lambda"
            v = car(cdr(form))
            body = car(cdr(cdr(form)))
            sub = _new_bctx(ctx.selfname)
            _alloc_slot!(sub, v.name)
            e2 = copy(env)
            e2[v.name] = 0
            bc_cexpr(body, sub, e2)
            _emit!(sub, :RETURN)
            tm = Runtime.BytecodeFunc("lam", 1, sub.maxlocals, sub.code, sub.consts)
            ups = collect(values(env))
            ci = _addc!(ctx, (tm, ups))
            _emit!(ctx, :MAKE_CLOSURE, ci, length(ups))
            return
        elseif op == "freeze"
            body = car(cdr(form))
            sub = _new_bctx(ctx.selfname)
            bc_cexpr(body, sub, env)
            _emit!(sub, :RETURN)
            tm = Runtime.BytecodeFunc("frz", 0, sub.maxlocals, sub.code, sub.consts)
            ups = collect(values(env))
            ci = _addc!(ctx, (tm, ups))
            _emit!(ctx, :MAKE_CLOSURE, ci, length(ups))
            return
        elseif op == "type"
            bc_cexpr(car(cdr(form)), ctx, env)
            return
        else
            bc_kl_call(form, ctx, env, false)
            return
        end
    else
        bc_kl_call(form, ctx, env, false)
    end
end

function bc_ctail(form, ctx::_BCtx, env::Dict{String,Int})
    if !is_cons(form)
        k, v = bc_catom(form, ctx, env)
        _emit!(ctx, k == :local ? :LOAD_LOCAL : :LOAD_CONST, v)
        _emit!(ctx, :RETURN)
        return
    end
    head = car(form)
    if is_symbol(head) && !haskey(env, head.name)
        op = head.name
        if op == "if"
            test = car(cdr(form))
            th = car(cdr(cdr(form)))
            el = cdr(cdr(cdr(form)))
            bc_cexpr(test, ctx, env)
            jf = _emit!(ctx, :JUMP_FALSE, 0)
            bc_ctail(th, ctx, env)
            ep = length(ctx.code)
            _patch!(ctx, jf, ep)
            if is_cons(el)
                bc_ctail(car(el), ctx, env)
            else
                _emit!(ctx, :LOAD_CONST, _addc!(ctx, false))
                _emit!(ctx, :RETURN)
            end
            return
        elseif op in ("let", "do", "cond", "and", "or", "type", "lambda", "freeze")
            bc_cexpr(form, ctx, env)
            _emit!(ctx, :RETURN)
            return
        else
            bc_kl_call(form, ctx, env, true)
            return
        end
    else
        bc_kl_call(form, ctx, env, true)
    end
end

function bc_cdefun(form::Cons)
    name = car(cdr(form)).name
    params = to_array(car(cdr(cdr(form))))
    body = car(cdr(cdr(cdr(form))))
    ctx = _new_bctx(name)
    env = Dict{String,Int}()
    for p in params
        if is_symbol(p)
            sl = _alloc_slot!(ctx, p.name)
            env[p.name] = sl
        end
    end
    ctx.nextslot = length(params)
    ctx.maxlocals = max(ctx.maxlocals, ctx.nextslot)
    ARITY[name] = length(params)
    bc_ctail(body, ctx, env)
    if isempty(ctx.code) || ctx.code[end].op != 0x07
        _emit!(ctx, :RETURN)
    end
    Runtime.BytecodeFunc(name, length(params), ctx.maxlocals, ctx.code, ctx.consts)
end

function bc_compile_expr_chunk(form)
    ctx = _new_bctx()
    bc_cexpr(form, ctx, Dict{String,Int}())
    _emit!(ctx, :RETURN)
    Runtime.BytecodeFunc("expr", 0, ctx.maxlocals, ctx.code, ctx.consts)
end

function bc_compile_top(form)
    if is_cons(form) && is_symbol(car(form)) && car(form).name == "defun"
        return bc_cdefun(form)
    else
        return bc_compile_expr_chunk(form)
    end
end

end # module Compiler
