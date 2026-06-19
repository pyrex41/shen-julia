using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
haskey(G, "shen.*tc*") || (G["shen.*tc*"] = false); G["*tc*"] = false

function tryload(path, fnname)
    print("load($path): ")
    try
        call("load", path)
        println("returned ok; ", fnname, " defined? ", haskey(F, fnname))
    catch e
        msg = e isa Runtime.ShenExcn ? e.msg : string(e)
        println("THREW ", typeof(e), ": ", msg[1:min(100,end)], " | ", fnname, " defined? ", haskey(F, fnname))
    end
end

# 1. trivial single-clause define via load
write("/tmp/s1.shen", "(define simple-fn X -> X)")
tryload("/tmp/s1.shen", "simple-fn")

# 2. multi-clause, no patterns
write("/tmp/s2.shen", "(define g2\n  0 -> zero\n  X -> other)")
tryload("/tmp/s2.shen", "g2")

# 3. cons-pattern matching (like cartprod)
write("/tmp/s3.shen", "(define g3\n  [ ] -> done\n  [X | Y] -> (g3 Y))")
tryload("/tmp/s3.shen", "g3")

# 4. the real cartprod
cd("tests") do; tryload("cartprod.shen", "cartesian-product"); end
println("done")
