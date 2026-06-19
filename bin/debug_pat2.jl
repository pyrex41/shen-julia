using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false
cd("tests") do; call("load", "cartprod.shen"); end

l = Runtime.from_vec(Any[1,2,3])
println("KL of cartesian-product:")
println("  ", Runtime.to_str(call("ps", intern("cartesian-product"))))
println("direct F[cartesian-product](l,l) = ",
    try Runtime.to_str(call("cartesian-product", l, l)) catch e; e isa Runtime.ShenExcn ? "ShenExcn: $(e.msg[1:min(50,end)])" : "THREW $(typeof(e))" end)
print("via run_kl_string = ")
try
    println(Runtime.to_str(fc(ShenJulia.run_kl_string("(cartesian-product [1 2 3] [1 2 3])"))))
catch e; println(e isa Runtime.ShenExcn ? "ShenExcn: $(e.msg[1:min(50,end)])" : "THREW $(typeof(e))") end
# what does run_kl_string make of just [1 2 3]?
print("eval of [1 2 3] = ")
try; println(Runtime.to_str(fc(ShenJulia.run_kl_string("[1 2 3]")))); catch e; println("THREW ", typeof(e)) end
println("done")
