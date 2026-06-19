# Clean test driver: load each test program, eval its canonical expression(s), compare by
# VALUE (kernel `=`) against the eval of the expected literal. Minimal setup (tc off + a
# y-or-n? stub), no elaborate seeding. Mirrors the flow proven to work in bin/debug_run.jl.
using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
rks(s) = fc(ShenJulia.run_kl_string(s))

boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false
# y-or-n? -> true (non-interactive), so partial-function tracking prompts never block.
F["y-or-n?"] = Prims.MKFUN(1, _ -> true)

const TESTS = [
    ("cartesian product", ["cartprod.shen"], [("(cartesian-product [1 2 3] [1 2 3])", "[[1 1] [1 2] [1 3] [2 1] [2 2] [2 3] [3 1] [3 2] [3 3]]")]),
    ("powerset", ["powerset.shen"], [("(powerset* [1 2 3])", "[[1 2 3] [1 2] [1 3] [1] [2 3] [2] [3] []]")]),
    ("bubble sort", ["bubble version 1.shen"], [("(bubble-sort [1 2 3])", "[3 2 1]")]),
    ("change", ["change.shen"], [("(count-change 100)", "4563")]),
    ("unification", ["unification.shen"], [("(unify [f a] X)", "[[X f a]]")]),
    ("abstract datatypes", ["stack.shen"], [("(top (push 0 (empty-stack 0)))", "0")]),
    ("calculator", ["calculator.shen"], [("(do-calculation [[num 12] + [[num 7] * [num 4]]])", "40")]),
    ("Prolog call", ["call.shen"], [("(prolog? (different 1 2))", "true"), ("(prolog? (different 1 1))", "false")]),
    ("Prolog naive reverse", ["nreverseprolog.shen"], [("(prolog? (nreverse [1 2 3 4] X) (return X))", "[4 3 2 1]")]),
    ("N Queens", ["n queens.shen"], [("(n-queens 4)", "[[3 1 4 2] [2 4 1 3]]")]),
    ("Prolog cut", ["cut.shen"], [("(prolog? (a X) (return X))", "4")]),
    ("semantic nets", ["semantic net.shen"], [("(clear Mark_Tarver)", "[]"), ("(assert [Mark_Tarver is_a man])", "[man]")]),
    ("structures untyped", ["structures-untyped.shen"], [("(defstruct ship [length name])", "ship"), ("(ship-length (make-ship 200 \"Mary Rose\"))", "200")]),
    ("yacc", ["yacc.shen"], [("(compile (fn <sent>) [the cat likes the dog])", "[the cat likes the dog]")]),
    ("binary", ["binary.shen"], [("(complement [1 0])", "[0 1]")]),
    ("einsteins riddle", ["einsteins-riddle.shen"], [("(prolog? (riddle))", "german")]),
]

const passed = Ref(0); const failed = Ref(0)
cd("tests") do
    for (name, files, cases) in TESTS
        for f in files
            try; fc(Base.invokelatest(F["load"], f)); catch e
                println("  [load $f failed: ", typeof(e), "]")
            end
        end
        for (i, (expr, expected)) in enumerate(cases)
            ok = false; got = ""
            try
                ev = rks(expr); ex = rks(expected)
                ok = (fc(Base.invokelatest(F["="], ev, ex)) === true)
                got = Runtime.to_str(ev)
            catch e
                got = (e isa Runtime.ShenExcn ? "ShenExcn: $(e.msg[1:min(50,end)])" : "THREW $(typeof(e))")
            end
            if ok; passed[] += 1; println("PASS  $name/$i")
            else;  failed[] += 1; println("FAIL  $name/$i   got: $got"); end
        end
    end
end
println("\n==> passed=$(passed[]) failed=$(failed[])")
