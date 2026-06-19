# The real question for typed codegen: KL functions return Any through the F-table/force
# boundary, so (+ (fib ..) (fib ..)) adds two Any values (dynamic dispatch + boxing).
# If a function is declared {number --> number}, codegen could assert the call result as
# Union{Int,Float64}. Does asserting the return type of recursive numeric calls help?
const NUM = Union{Int,Float64}

# barrier that forces an Any return type (mimics F[name]/force returning ::Any)
@noinline anybarrier(x)::Any = x

# untyped: recursive results are Any -> a + b is Any+Any (dynamic, boxed)
function fib_any(n)
    n < 2 && return n
    a = anybarrier(fib_any(n - 1))
    b = anybarrier(fib_any(n - 2))
    return a + b
end

# typed codegen: assert the result of each typed-fn call into the numeric Union
function fib_typed(n)
    n < 2 && return n
    a = anybarrier(fib_typed(n - 1))::NUM
    b = anybarrier(fib_typed(n - 2))::NUM
    return a + b
end

best(f, x; reps=10) = (f(x); t=Inf; for _ in 1:reps; g=time(); f(x); t=min(t,time()-g); end; t*1e3)

for n in (28, 30)
    @assert fib_any(n) == fib_typed(n)
    println("fib($n) with Any-returning recursive calls (ms, best of 10):")
    println("  results as Any (current)        : ", round(best(fib_any, n), digits=3))
    println("  results asserted ::Union{I,F}   : ", round(best(fib_typed, n), digits=3))
end
