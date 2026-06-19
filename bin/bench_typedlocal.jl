# Decisive test for the "typed codegen" endgame: does typing numeric self-tail loop
# locals as Union{Int,Float64} (isbits union -> inline storage + union-split arithmetic)
# beat Any-typed locals, when called with Any arguments (as KL always does)?
# Mimics what cdefun emits for  (defun sum-to-acc (N Acc) (if (= N 0) Acc (sum-to-acc (- N 1) (+ N Acc)))).

const NUM = Union{Int,Float64}

# untyped (current codegen): params flow in as Any, loop locals stay Any -> boxing each iter
function sumacc_any(N, Acc)
    while true
        if N == 0
            return Acc
        else
            st1 = N - 1
            st2 = N + Acc
            N = st1; Acc = st2
            continue
        end
    end
end

# typed codegen (proposed): assert numeric params into a Union at entry -> inline, union-split
function sumacc_union(N0, Acc0)
    N::NUM = N0
    Acc::NUM = Acc0
    while true
        if N == 0
            return Acc
        else
            st1 = N - 1
            st2 = N + Acc
            N = st1; Acc = st2
            continue
        end
    end
end

# fully concrete reference (only valid if we knew it was Int — the 12.5x ceiling)
function sumacc_int(N0::Any, Acc0::Any)
    N = N0::Int; Acc = Acc0::Int
    while true
        N == 0 && return Acc
        N, Acc = N - 1, N + Acc
    end
end

best(f, a, b; reps=20) = (f(a,b); t=Inf; for _ in 1:reps; g=time(); f(a,b); t=min(t,time()-g); end; t*1e3)

N = 1_000_000
a = Any[N][1]; b = Any[0][1]   # force Any-typed arguments
@assert sumacc_any(a,b) == sumacc_union(a,b) == sumacc_int(a,b)
println("sum-to-acc($N) self-tail loop (ms, best of 20):")
println("  Any locals (current)        : ", round(best(sumacc_any, a, b), digits=4))
println("  Union{Int,Float64} locals   : ", round(best(sumacc_union, a, b), digits=4))
println("  Int locals (ceiling)        : ", round(best(sumacc_int, a, b), digits=4))
