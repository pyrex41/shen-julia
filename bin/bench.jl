# Performance + correctness benchmark for the Shen/Julia port.
# Boots the kernel, defines KL functions via the source-codegen path (the path eval_kl and
# the kernel both use), and times them through the real call path.
#
#   julia --project=. bin/bench.jl
using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
import ShenJulia.Compiler as Compiler

const F = Prims.F
forcer(x) = Base.invokelatest(Prims.force, x)
callkl(name, args...) = forcer(Base.invokelatest(F[name], args...))

t0 = time()
boot!(false)
println("boot: $(round(time()-t0, digits=2))s")

const DEFS = [
    "(defun count-down (X) (if (= X 0) done (count-down (- X 1))))",
    "(defun fib (N) (if (< N 2) N (+ (fib (- N 1)) (fib (- N 2)))))",
    "(defun build (N Acc) (if (= N 0) Acc (build (- N 1) (cons N Acc))))",
    "(defun len-acc (L N) (if (empty? L) N (len-acc (tl L) (+ N 1))))",
    "(defun len* (L) (len-acc L 0))",
]
for d in DEFS
    Base.invokelatest(Prims.eval_kl, read_all(d)[1])
end

function bench(label, f; reps=5)
    f(); best = Inf
    for _ in 1:reps
        t = time(); f(); best = min(best, time()-t)
    end
    println("  $label: $(round(best*1000, digits=3)) ms")
end

println("=== correctness ===")
println("  fib(20) = ", callkl("fib", 20), " (expect 6765)")
println("  build+len 1000 = ", callkl("len*", callkl("build", 1000, NIL)), " (expect 1000)")
println("  count-down(100) = ", callkl("count-down", 100), " (expect done)")

println("=== timings (best of 5) ===")
bench("count-down 1_000_000 (self-tail)", () -> callkl("count-down", 1_000_000))
bench("fib 25 (non-tail recursion)", () -> callkl("fib", 25))
bench("build+len 100_000 (cons/list)", () -> callkl("len*", callkl("build", 100_000, NIL)))
println("done")
