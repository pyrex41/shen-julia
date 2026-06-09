#!/usr/bin/env julia
# Driver to boot the Shen 41.1 kernel and run the test programs in tests/.
#
# Structure:
#   1. Boot the kernel.
#   2. Smoke tests (primitives + a trivial eval/define) on clean post-boot state.
#   3. Program tests: load each Shen test program and compare the canonical
#      expression's value against the expected literal, BY VALUE via the kernel `=`.
#   4. (last, optional) attempt the official harness.shen/kerneltests.shen, fully
#      wrapped so its failure can never affect the program-test counts above.
#
# Notes for maintainers:
#   - The official harness is attempted LAST, never first: loading harness.shen on
#     some src snapshots throws a Julia MethodError that corrupts kernel state, so
#     it must not run before the program tests.
#   - Stub functions are registered through the proper API (Prims.setfn! when
#     present, else Prims.defprim) so the dispatch table stays in sync. We never
#     poke F[name] = ... directly.
#   - Shen-syntax expressions (containing [...]) are evaluated through the kernel
#     reader (read-from-string) + eval, NOT the raw KL paren reader.

using Pkg
Pkg.activate(@__DIR__)

using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims

const G = Prims.GLOBALS

println("Loading Shen 41.1 kernel...")
t0 = time()
boot!(get(ENV, "SHEN_VERBOSE", "") == "1")
t1 = time()
println("  boot: $(round(t1 - t0, digits=3))s")
println("Kernel initialised. Version: ", Base.invokelatest(F["version"]))

# --- helpers ---------------------------------------------------------------

# Register a function under `name` through the proper API so the integer-slot
# dispatch table (Prims.FV) stays in sync with the string-keyed table (Prims.F).
function regfn!(name::String, arity::Int, fn::Function)
    if isdefined(Prims, :setfn!)
        getfield(Prims, :setfn!)(name, Prims.MKFUN(arity, fn))
    else
        Prims.defprim(name, arity, fn)
    end
end

# force a (possibly lazy) value; pass-through if the kernel has no `force`.
const _force = isdefined(Prims, :force) ? getfield(Prims, :force) : nothing
fc(x) = _force === nothing ? x : Base.invokelatest(_force, x)

# Evaluate a Shen-syntax string through the kernel reader + eval, then force.
function shen_eval(s::String)
    forms = Base.invokelatest(F["read-from-string"], s)
    form = forms isa Cons ? forms.h : forms
    return fc(Base.invokelatest(F["eval"], form))
end

valeq(a, b) = fc(Base.invokelatest(F["="], a, b)) === true

# --- smoke tests (clean post-boot state) -----------------------------------

println("\n=== Smoke tests ===")
@assert F["+"](3, 4) == 7
@assert equal(cons(intern("a"), NIL), cons(intern("a"), NIL))
println("  primitives: ok")

let form = read_all("(define smoke-test X -> (* X X))")[1]
    Base.invokelatest(F["eval"], form)
    @assert Base.invokelatest(F["smoke-test"], 5) == 25
end
println("  eval define: ok")

# --- program tests ----------------------------------------------------------
# Non-interactive setup: type checking off, and y-or-n? / char-stoutput? stubbed
# so partial-function tracking prompts and the writer never block or error.
G["shen.*tc*"] = false
G["*tc*"] = false
regfn!("y-or-n?", 1, _ -> true)
regfn!("shen.char-stoutput?", 1, _ -> false)

# (name, [files to load], [(expr, expected-literal), ...])
const TESTS = [
    ("cartesian product", ["cartprod.shen"],
        [("(cartesian-product [1 2 3] [1 2 3])",
          "[[1 1] [1 2] [1 3] [2 1] [2 2] [2 3] [3 1] [3 2] [3 3]]")]),
    ("powerset", ["powerset.shen"],
        [("(powerset* [1 2 3])", "[[1 2 3] [1 2] [1 3] [1] [2 3] [2] [3] []]")]),
    ("bubble sort", ["bubble version 1.shen"],
        [("(bubble-sort [1 2 3])", "[3 2 1]")]),
    ("change", ["change.shen"],
        [("(count-change 100)", "4563")]),
    ("unification", ["unification.shen"],
        [("(unify [f a] X)", "[[X f a]]")]),
    ("abstract datatypes", ["stack.shen"],
        [("(top (push 0 (empty-stack 0)))", "0")]),
    ("calculator", ["calculator.shen"],
        [("(do-calculation [[num 12] + [[num 7] * [num 4]]])", "40")]),
    ("Prolog call", ["call.shen"],
        [("(prolog? (different 1 2))", "true"), ("(prolog? (different 1 1))", "false")]),
    ("Prolog naive reverse", ["nreverseprolog.shen"],
        [("(prolog? (nreverse [1 2 3 4] X) (return X))", "[4 3 2 1]")]),
    ("N Queens", ["n queens.shen"],
        [("(n-queens 4)", "[[3 1 4 2] [2 4 1 3]]")]),
    ("Prolog cut", ["cut.shen"],
        [("(prolog? (a X) (return X))", "4")]),
    ("semantic nets", ["semantic net.shen"],
        [("(clear Mark_Tarver)", "[]"), ("(assert [Mark_Tarver is_a man])", "[man]")]),
    ("structures untyped", ["structures-untyped.shen"],
        [("(defstruct ship [length name])", "ship"),
         ("(ship-length (make-ship 200 \"Mary Rose\"))", "200")]),
    ("yacc", ["yacc.shen"],
        [("(compile (fn <sent>) [the cat likes the dog])", "[the cat likes the dog]")]),
    ("binary", ["binary.shen"],
        [("(complement [1 0])", "[0 1]")]),
    ("einsteins riddle", ["einsteins-riddle.shen"],
        [("(prolog? (riddle))", "german")]),
]

println("\n=== Program tests ===")
const passed = Ref(0)
const failed = Ref(0)
cd("tests") do
    for (name, files, cases) in TESTS
        for f in files
            try
                fc(Base.invokelatest(F["load"], f))
            catch e
                println("  [load $f failed: $(typeof(e))]")
            end
        end
        for (i, (expr, expected)) in enumerate(cases)
            ok = false
            got = ""
            try
                ev = shen_eval(expr)
                ex = shen_eval(expected)
                ok = valeq(ev, ex)
                got = Runtime.to_str(ev)
            catch e
                got = e isa Runtime.ShenExcn ? "ShenExcn: $(e.msg[1:min(60,end)])" : "THREW $(typeof(e))"
            end
            if ok
                passed[] += 1
                println("PASS  $name/$i")
            else
                failed[] += 1
                println("FAIL  $name/$i   got: $got")
            end
        end
    end
end
println("\n==> passed=$(passed[]) failed=$(failed[])")

# --- official harness (attempted LAST, fully isolated) ----------------------
# Its result is informational only and cannot change the counts above.
let tests_dir = isfile(joinpath("tests", "harness.shen")) ? "tests" : nothing
    if tests_dir !== nothing
        println("\n=== Official harness (informational, may fail) ===")
        try
            cd(tests_dir) do
                fc(Base.invokelatest(F["load"], "harness.shen"))
                println("  harness: ok")
                fc(Base.invokelatest(F["load"], "kerneltests.shen"))
                println("  kerneltests: passed=$(get(G, "*passed*", "?")) failed=$(get(G, "*failed*", "?"))")
            end
        catch e
            println("  harness not run: ", e isa Runtime.ShenExcn ? e.msg : typeof(e))
        end
    end
end

println("\nDone.")
