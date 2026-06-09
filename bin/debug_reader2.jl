# Probe read-file + load on the ACTUAL test files to locate the break.
using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
haskey(G, "shen.*tc*") || (G["shen.*tc*"] = false); G["*tc*"] = false

function probe_readfile(path)
    print("read-file($path): ")
    G["shen.*residue*"] = NIL
    try
        r = call("read-file", path)
        n=0; c=r; while c isa Runtime.Cons; n+=1; c=c.t; end
        println("OK -> ", n, " forms")
        return r
    catch e
        msg = e isa Runtime.ShenExcn ? e.msg : string(e)
        res = get(G, "shen.*residue*", NIL)
        rs = Runtime.to_str(res)
        println("FAIL ", typeof(e), ": ", msg[1:min(60,end)])
        println("   residue(head 120 chars): ", rs[1:min(120,end)])
        return nothing
    end
end

cd("tests") do
    for f in ("cartprod.shen", "powerset.shen", "harness.shen")
        isfile(f) && probe_readfile(f)
    end
end
println("done")
