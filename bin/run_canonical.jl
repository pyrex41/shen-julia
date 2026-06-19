# Canonical kerneltests run: load harness.shen then the REAL kerneltests.shen,
# exactly as upstream Shen does. The file self-sets (maxinferences 1e7) on line 1
# and manages tc. Only non-interactive stub: y-or-n? -> true.
using ShenJulia
using ShenJulia: Prims, Runtime
const F = Prims.F; const G = Prims.GLOBALS
boot!(false)
Prims.define_named!("y-or-n?", 1, _ -> true)
Prims.define_named!("shen.char-stoutput?", 1, _ -> false)
cd("tests") do
    Prims.with_shen_stack() do
        Prims.force(Base.invokelatest(F["load"], "harness.shen"))
        Prims.force(Base.invokelatest(F["load"], "kerneltests.shen"))
    end
end
println("passed = ", get(G, "test-harness.*passed*", get(G, "*passed*", "?")))
println("failed = ", get(G, "test-harness.*failed*", get(G, "*failed*", "?")))
