# A/B benchmark: KL-recursive builtins (SLOW_BUILTINS, the kernel defs) vs the host
# "overwrite" versions now installed in F. Boots, defines a unary KL fn for map, then
# compares correctness and timing on large Cons lists.
using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims

const F = Prims.F
const SLOW = Prims.SLOW_BUILTINS
forcer(x) = Base.invokelatest(Prims.force, x)
call(fn, args...) = forcer(Base.invokelatest(fn, args...))

boot!(false)
# unary KL function for map (defined via the host eval_kl source path)
Base.invokelatest(Prims.eval_kl, read_all("(defun inc (X) (+ X 1))")[1])
inc = F["inc"]

biglist(n) = Runtime.from_vec(collect(1:n))
len(c) = (n=0; while c isa Runtime.Cons; n+=1; c=c.t; end; n)

function bench(label, f; reps=7)
    try
        f(); best = Inf
        for _ in 1:reps
            t = time(); f(); best = min(best, time()-t)
        end
        println("  $label: $(round(best*1000, digits=3)) ms")
    catch e
        println("  $label: ERROR ", typeof(e), " (e.g. stack overflow on deep non-tail recursion)")
    end
end

println("installed overrides: ", sort(collect(keys(SLOW))))

# correctness on a small list (kernel append is non-tail-recursive — keep it shallow here)
let M = 1000, a = biglist(M), b = biglist(M)
    println("=== correctness (host F vs kernel SLOW) ===")
    println("  append len: ", len(call(F["append"], a, b)), " vs ", len(call(SLOW["append"], a, b)))
    println("  reverse hd: ", call(F["reverse"], a).h, " vs ", call(SLOW["reverse"], a).h)
    println("  length: ", call(F["length"], a), " vs ", call(SLOW["length"], a))
    println("  map inc hd / len: ", call(F["map"], inc, a).h, " / ", len(call(F["map"], inc, a)),
            " vs ", call(SLOW["map"], inc, a).h, " / ", len(call(SLOW["map"], inc, a)))
end

N = 50_000
xs = biglist(N); ys = biglist(N)
println("=== timings (best of 7), N=$N ===")
for (nm, fast, slow, args) in (
        ("append", F["append"], SLOW["append"], (xs, ys)),
        ("reverse", F["reverse"], SLOW["reverse"], (xs,)),
        ("length", F["length"], SLOW["length"], (xs,)),
        ("map inc", F["map"], SLOW["map"], (inc, xs)),
    )
    bench("$nm  KERNEL", () -> call(slow, args...))
    bench("$nm  HOST  ", () -> call(fast, args...))
end
println("done")
