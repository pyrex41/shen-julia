# Compiler: translate KLambda forms to Julia source for eval().
#
# Statement-based codegen: ctail emits statements ending in return, so control
# flow maps to Julia if/elseif. Tail calls emit return (no native TCO in Julia;
# deep recursion workloads may need backend loop transforms later).

module Compiler

using ..Runtime: NIL, Cons, ShenSymbol, cons, is_cons, is_symbol

export ARITY, KDATA, prescan, compile_top, compile_expr_chunk, cexpr, ctail

const ARITY = Dict{String, Int}()
const KDATA = Any[]

car(x::Cons) = x.h
cdr(x::Cons) = x.t

function to_array(lst)
    a = Any[]
    while is_cons(lst)
        push!(a, lst.h)
        lst = lst.t
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
            return "(()->($(ctail(form, env))))()"
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
function ctail_and(form::Cons, env::Dict{String,String})
    a = car(cdr(form))
    b = car(cdr(cdr(form)))
    if is_cons(b) && is_symbol(car(b)) && car(b).name == "and"
        return "if $(cexpr(a, env)); begin $(ctail_and(b, env)) end else return false; end"
    else
        ths = _wrap_else(ctail(b, env))
        return "if $(cexpr(a, env)); $ths else return false; end"
    end
end

function ctail_or(form::Cons, env::Dict{String,String})
    a = car(cdr(form))
    b = car(cdr(cdr(form)))
    if is_cons(b) && is_symbol(car(b)) && car(b).name == "or"
        return "if $(cexpr(a, env)); return true else begin $(ctail_or(b, env)) end end"
    else
        els = _wrap_else(ctail(b, env))
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

function ctail_if(form::Cons, env::Dict{String,String})
    test = car(cdr(form))
    th = car(cdr(cdr(form)))
    el = cdr(cdr(cdr(form)))
    ths = ctail(th, env)
    if is_cons(el)
        els = _wrap_else(ctail(car(el), env))
        return "if $(cexpr(test, env)); $ths else $els end"
    else
        return "if $(cexpr(test, env)); $ths else return false; end"
    end
end

function ctail(form, env::Dict{String,String})
    if !is_cons(form)
        v = form isa Number ? cnum(form) : catom(form, env)
        return "return $v"
    end

    head = car(form)
    if is_symbol(head) && !haskey(env, head.name)
        op = head.name
        if op == "if"
            return ctail_if(form, env)
        elseif op == "cond"
            clauses = to_array(cdr(form))
            parts = String[]
            for (i, cl) in enumerate(clauses)
                test = car(cl)
                res = car(cdr(cl))
                body = _wrap_else(ctail(res, env))
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
            return "local $ln = $valc; $(ctail(body, e2))"
        elseif op == "do"
            forms = flatten_do(form)
            stmts = String[]
            for i in 1:length(forms)-1
                es = cexpr(forms[i], env)
                push!(stmts, "(()->$es)();")
            end
            push!(stmts, ctail(forms[end], env))
            return join(stmts, " ")
        elseif op == "and"
            return ctail_and(form, env)
        elseif op == "or"
            return ctail_or(form, env)
        elseif op == "trap-error"
            expr = car(cdr(form))
            handler = car(cdr(cdr(form)))
            hc = cexpr(handler, env)
            return """try; return $(cexpr(expr, env)); catch e; return APP($hc, TOEXCN(e)); end"""
        elseif op == "type"
            return ctail(car(cdr(form)), env)
        elseif op in ("lambda", "freeze")
            return "return $(cexpr(form, env))"
        else
            return "return $(kl_call(form, env))"
        end
    else
        return "return $(kl_call(form, env))"
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
    fnname = "kl_" * gen("fn")
    paramstr = join(lnames, ", ")
    src = sanitize_julia("""begin
function $fnname($paramstr)
    $(ctail(body, env))
end
F[$(qstr(name))] = $fnname
FA[$fnname] = $(length(params))
end""")
    return src
end

function prescan(forms)
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
    # Only rewrite else-if inside ctail_if_chain elseif ladders; do not
    # flatten nested or/and if-else trees (that leaves stray `end` tokens).
    return src
end

function compile_top(form)
    if is_cons(form) && is_symbol(car(form)) && car(form).name == "defun"
        return cdefun(form)
    else
        return "($(cexpr(form, Dict{String,String}())));"
    end
end

end # module Compiler