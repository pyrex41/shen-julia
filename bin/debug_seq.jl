using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false

showpkg() = println("   shen.*package* = ", repr(get(G, "shen.*package*", :missing)))

cd("tests") do
    println("--- before harness ---"); showpkg()
    print("load harness.shen: ")
    try; call("load", "harness.shen"); println("ok")
    catch e; println("THREW ", typeof(e), ": ", (e isa Runtime.ShenExcn ? e.msg : string(e))[1:min(70,end)]); end
    println("--- after harness ---"); showpkg()

    print("load cartprod.shen: ")
    try; call("load", "cartprod.shen"); println("ok") catch e; println("THREW ", typeof(e)); end
    # search F for any key containing cartesian
    ks = [k for k in keys(F) if occursin("cartesian", k)]
    println("   F keys containing 'cartesian': ", ks)
    println("   cartesian-product defined? ", haskey(F, "cartesian-product"))
end
println("done")
