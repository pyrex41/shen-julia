using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false

function loadrun(file, expr, expected)
    cd("tests") do
        try; call("load", file); catch e; println("  load($file) THREW ", typeof(e)); end
    end
    print("  run ", expr, " => ")
    try
        r = fc(ShenJulia.run_kl_string(expr))
        s = Runtime.to_str(r)
        println(s, s == expected ? "   PASS" : "   FAIL (expected $expected)")
    catch e
        println("THREW ", typeof(e), ": ", (e isa Runtime.ShenExcn ? e.msg : string(e))[1:min(70,end)])
    end
end

loadrun("cartprod.shen", "(cartesian-product [1 2 3] [1 2 3])", "[[1 1] [1 2] [1 3] [2 1] [2 2] [2 3] [3 1] [3 2] [3 3]]")
loadrun("powerset.shen", "(powerset* [1 2 3])", "[[1 2 3] [1 2] [1 3] [1] [2 3] [2] [3] []]")
loadrun("change.shen", "(count-change 100)", "4563")
loadrun("unification.shen", "(unify [f a] X)", "[[X f a]]")
println("done")
