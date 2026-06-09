using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))
boot!(false)
G["shen.*tc*"] = false; G["*tc*"] = false

# define a minimal list-pattern function via load
write("/tmp/pat.shen", "(define g\n  [ ] -> empty\n  [X | Y] -> X)")
call("load", "/tmp/pat.shen")

lst = Runtime.from_vec(Any[1,2,3])
println("g([]) = ", try call("g", NIL) catch e; "THREW $(typeof(e))" end, "  (expect empty)")
println("g([1 2 3]) = ", try call("g", lst) catch e; e isa Runtime.ShenExcn ? "ShenExcn: $(e.msg[1:min(40,end)])" : "THREW $(typeof(e))" end, "  (expect 1)")

# inspect the generated KL for g, to see the compiled patterns
println("--- KL of g (via F? show source not avail; show via ps) ---")
try
    klg = call("ps", intern("g"))
    println(Runtime.to_str(klg))
catch e
    println("ps unavailable: ", typeof(e))
end
println("done")
