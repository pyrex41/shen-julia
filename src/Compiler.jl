# Compiler: translate KLambda forms to Julia source for eval().
#
# Statement-based codegen: ctail emits statements ending in return, so control
# flow maps to Julia if/elseif.
#
# Calling convention (the core design decision of this port): each KL defun
# compiles to a NAMED top-level Julia method (`function K_foo(a1, a2) ... end`)
# and statically-known calls are emitted as plain direct calls (`K_foo(x, y)`).
# This rides Julia's own machinery instead of re-implementing it:
#   - dispatch:      Julia static dispatch + inlining (~0-2ns/call, zero alloc)
#                    instead of a Vector{Function} slot table (~16ns + no inlining)
#   - redefinition:  Julia method replacement + automatic invalidation/recompile
#                    of callers, instead of mutating a function table
#   - tail calls:    plain calls on a Task with a multi-GB reserved stack
#                    (see Prims.with_shen_stack), instead of a Bounce trampoline
#                    (~35ns + 2 allocs per tail call, and it nested force loops)
# Self-tail recursion still compiles to `while true ... continue` (a real loop
# beats any calling convention). Only dynamic calls (computed heads, unknown
# names, partial application) go through APP — a genuine slow path now.

module Compiler

using ..Runtime  # bare to allow Runtime.XXX in bc dups + names

export ARITY, KDATA, prescan, compile_top, compile_expr_chunk, cexpr, ctail, fnident, cdefun_parts

const ARITY = Dict{String, Int}()
const KDATA = Any[]
const PRIMS = Set{String}()

# Peephole: KL prims that are never redefined and have a named @inline host implementation
# in Prims. When applied at exact arity in head position, the compiler emits a direct call
# to the host function (resolved in the Prims module where generated code is eval'd) instead
# of `F[name](…)` — no Dict lookup, no Bounce in tail position, and Julia can inline it.
const INLINE_PRIM = Dict{String, String}(
    "+" => "kl_add", "-" => "kl_sub", "*" => "kl_mul", "/" => "kl_div",
    ">" => "kl_gt", "<" => "kl_lt", ">=" => "kl_gte", "<=" => "kl_lte",
    "=" => "kl_eq", "cons" => "kl_cons", "hd" => "kl_hd", "tl" => "kl_tl",
    "empty?" => "kl_emptyp", "cons?" => "kl_consp",
)

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

# Mangle a KL function name to a valid Julia identifier, injectively and
# deterministically (no table needed — the same name always mangles the same way,
# so pre-generated artifact sources and fresh codegen agree by construction).
# Letters/digits pass through, '_' doubles, anything else becomes _<hex>_.
const FNAME = Dict{String, String}()   # memo only
function fnident(name::String)::String
    get!(FNAME, name) do
        io = IOBuffer()
        print(io, "K_")
        for c in name
            if c == '_'
                print(io, "__")
            elseif isletter(c) || isdigit(c)
                print(io, c)
            else
                print(io, '_', string(UInt32(c), base=16), '_')
            end
        end
        String(take!(io))
    end
end

# Call emission. Value and tail position are identical now (direct calls return
# concrete values; there is no trampoline) EXCEPT self-tail calls, which rebind the
# params and `continue` the enclosing while loop — pass selfname/self_lnames from
# ctail for that. kl_call (value position) is the same emitter without self info.
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
                    # Self-tail call -> rebind params and loop. This is a PARALLEL assignment:
                    # a later argument's new value may read a parameter that an earlier rebind
                    # would already have overwritten (e.g. shen.reverse-help does
                    # (self (tl L) (cons (hd L) Acc)) — the new Acc needs the OLD L). Snapshot
                    # every new value into a temp first, then assign all params.
                    if ar == 1
                        return "$(self_lnames[1]) = $(cargs[1]); continue"
                    end
                    tmps = [gen("st") for _ in 1:ar]
                    lines = String[]
                    for i in 1:ar
                        push!(lines, "$(tmps[i]) = $(cargs[i])")
                    end
                    for i in 1:ar
                        push!(lines, "$(self_lnames[i]) = $(tmps[i])")
                    end
                    return join(lines, "; ") * "; continue"
                end
                inl = get(INLINE_PRIM, name, nothing)
                inl !== nothing && return "$inl($(argstr))"
                # Direct static call to the named method — Julia resolves, specializes,
                # and can inline it. This is the hot path for all kernel-to-kernel calls.
                return "$(fnident(name))($(argstr))"
            elseif length(args) < ar
                # Under-application. We could bake PARTIAL($(fnident(name)), $ar, ...)
                # here, but $ar is the arity *at compile time*. Shen semantics decide
                # partial-vs-full from the function's CURRENT arity at call time, so a
                # name redefined to a smaller arity between compile and call (e.g. a
                # (defprolog complement ...) earlier, then (define complement ...) loaded
                # inside the same report) would wrongly stay a partial. Route through
                # dynamic APP so the arity is resolved at runtime. The kernel never emits
                # this branch (0 PARTIAL calls baked), so there is no hot-path cost.
                return isempty(args) ? "APP($(symlit(name)))" : "APP($(symlit(name)), $(argstr))"
            else
                # Over-application: more args than the compile-time arity. Baking
                # $ar here splits the args at the wrong boundary if $name is redefined
                # to a *larger* arity between compile and call. This actually happens in
                # the kerneltests harness: search.shen defines depth/3, then the
                # "depth first search" report compiles (depth 4 L1 L2 L3) — 4 args vs the
                # stale arity 3 — and only afterwards loads depth.shen's depth/4. The baked
                # split would call the stale depth/3 (dropping the 4th arg) and diverge.
                # Route through dynamic APP so the current arity decides the split at call
                # time. APP itself handles the over-application (apply ar, then APP the rest).
                return "APP($(symlit(name)), $(argstr))"
            end
        else
            # Dynamic function name (arity unknown at compile time): resolve + call via APP.
            if isempty(args)
                return "APP($(symlit(name)))"
            end
            return "APP($(symlit(name)), $(argstr))"
        end
    else
        # Computed head (e.g. a variable holding a function, as in shen.map-h's (V f x)).
        hv = cexpr(head, env)
        if isempty(args)
            return "APP($hv)"
        end
        return "APP($hv, $(argstr))"
    end
end

kl_call(form::Cons, env::Dict{String,String}) = kl_call_tail(form, env, nothing, String[])

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

# Collect the KL variable names that occur free in `form` and are bound to a Julia
# local in `env` (so they could be a mutable while-loop param/let-local). `bound` holds
# names introduced by enclosing lambdas inside `form` (shadowed — not captured).
#
# Why: closures emitted for (freeze ...) / (lambda ...) capture Julia locals *by
# reference*. cdefun compiles self-tail recursion as a `while true ... continue` loop that
# rebinds the param locals in place (parallel-assignment snapshot fixes the order, but the
# vars themselves are still mutated). A closure created in one iteration and thawed later
# (the norm for Prolog CPS continuations, e.g. shen.lzy=! / shen.lzy / left) would then see
# the *mutated* values, not the ones live when it was created — manifesting as "tl of
# non-cons" deep in einsteins-riddle. Snapshotting the free vars into fresh `let` bindings
# per closure makes each capture immutable, matching the BIND design in Prims.jl.
function collect_free_env!(acc::Vector{String}, seen::Set{String}, form, env::Dict{String,String}, bound::Set{String})
    if is_symbol(form)
        n = form.name
        if !(n in bound) && haskey(env, n) && !(n in seen)
            push!(seen, n); push!(acc, n)
        end
        return
    end
    is_cons(form) || return
    head = car(form)
    if is_symbol(head) && !(head.name in bound) && !haskey(env, head.name)
        op = head.name
        if op == "lambda"
            v = car(cdr(form))
            body = car(cdr(cdr(form)))
            if is_symbol(v)
                inner = copy(bound); push!(inner, v.name)
                collect_free_env!(acc, seen, body, env, inner)
                return
            end
        elseif op == "let"
            # `let` binds its var only in the body; the value expr sees the outer scope.
            v = car(cdr(form)); val = car(cdr(cdr(form))); lbody = car(cdr(cdr(cdr(form))))
            collect_free_env!(acc, seen, val, env, bound)
            if is_symbol(v)
                inner = copy(bound); push!(inner, v.name)
                collect_free_env!(acc, seen, lbody, env, inner)
                return
            end
        end
    end
    cur = form
    while is_cons(cur)
        collect_free_env!(acc, seen, cur.h, env, bound)
        cur = cur.t
    end
end

function free_env_vars(form, env::Dict{String,String}, bound::Set{String})
    acc = String[]; seen = Set{String}()
    collect_free_env!(acc, seen, form, env, bound)
    return acc
end

# Wrap a closure expression so that each free variable captured from the enclosing
# (mutable) scope is snapshotted into a fresh `let` binding. `mkclosure(env2)` builds the
# closure source given the (possibly remapped) env. The remap points captured KL names at
# fresh cap-locals so the closure body reads the snapshot, not the live loop-local.
function snapshot_closure(mkclosure, form_body, env::Dict{String,String}, extra_bound::Set{String})
    frees = free_env_vars(form_body, env, extra_bound)
    if isempty(frees)
        return mkclosure(env)
    end
    binds = String[]
    env2 = copy(env)
    for kn in frees
        cap = gen("cap")
        push!(binds, "$cap = $(env[kn])")
        env2[kn] = cap
    end
    return "(let $(join(binds, ", ")); $(mkclosure(env2)) end)"
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
            # Statement forms in value position: IIFE. All calls return concrete
            # values (no trampoline), so the result needs no driving.
            return "((()->($(ctail(form, env))))())"
        elseif op == "lambda"
            v = car(cdr(form))
            body = car(cdr(cdr(form)))
            # Snapshot captured outer locals (the lambda param is bound, not captured).
            return snapshot_closure(body, env, Set{String}([v.name])) do envc
                ln = gen("v")
                e2 = extend(envc, v.name, ln)
                "MKFUN(1, $ln -> $(cexpr(body, e2)))"
            end
        elseif op == "freeze"
            body = car(cdr(form))
            return snapshot_closure(body, env, Set{String}()) do envc
                "MKFUN(0, () -> $(cexpr(body, envc)))"
            end
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

# Compile a defun into its constituent pieces:
#   name        the KL name (for setfn!)
#   arity       parameter count
#   ident       the mangled Julia identifier (K_...)
#   method_src  the bare `function K_...(...) ... end` definition
# This is the single source of truth for defun codegen. `cdefun` assembles the
# usual begin/method/setfn! block from it (the Core.eval boot path); the
# ahead-of-time generator (bin/gen_kernel.jl) keeps the method at top level (so
# precompilation bakes it) and emits the setfn! registration separately.
function cdefun_parts(form::Cons)
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
    ident = fnident(name)
    paramstr = join(lnames, ", ")
    # Each defun becomes a named global method. Self-tail recursion compiles to the
    # while/rebind/continue loop (see kl_call_tail); cross-function calls are plain
    # Julia calls on the big reserved stack. Redefinition re-evals the method and
    # Julia's invalidation machinery recompiles callers automatically.
    body_src = ctail(body, env, name, lnames)
    method_src = sanitize_julia("""function $ident($paramstr)
    while true
        $body_src
    end
end""")
    return (name, length(params), ident, method_src)
end

function cdefun(form::Cons)
    name, arity, ident, method_src = cdefun_parts(form)
    return sanitize_julia("""begin
$method_src
setfn!($(qstr(name)), $ident, $arity)
end""")
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

end # module Compiler
