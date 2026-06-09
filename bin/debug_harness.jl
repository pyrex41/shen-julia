using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false
F["y-or-n?"] = Prims.MKFUN(1, _ -> true)
cd("tests") do
    try
        fc(Base.invokelatest(F["read-file"], "harness.shen"))
        println("read-file OK")
    catch e
        println("read-file threw: ", typeof(e))
        for (i, fr) in enumerate(stacktrace(catch_backtrace()))
            i > 18 && break
            println("  ", fr)
        end
    end
end
println("done")
