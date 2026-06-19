# Run a mini harness file (ARGS[1], relative to tests/) via the real harness,
# report passed/failed. Used to bisect the kerneltests cascade.
using ShenJulia
using ShenJulia: Prims, Runtime
const F = Prims.F; const G = Prims.GLOBALS
boot!(false)
G["shen.*tc*"]=false; G["*tc*"]=false
Prims.define_named!("y-or-n?", 1, _ -> true)
Prims.define_named!("shen.char-stoutput?", 1, _ -> false)
if get(ENV, "SHEN_MAXINF", "") != ""
    G["shen.*maxinferences*"] = parse(Int, ENV["SHEN_MAXINF"])
end
mini = ARGS[1]
cd("tests") do
    Prims.with_shen_stack() do
        Prims.force(Base.invokelatest(F["load"], "harness.shen"))
        Prims.force(Base.invokelatest(F["load"], mini))
    end
end
