# What does Vector{Any}/Any-fields actually cost, and what would concrete typing buy?
# Sum 100k Ints stored four ways. No kernel boot.
const N = 100_000

struct ConsAny; h::Any; t::Any; end           # current Shen cell (heterogeneous-capable)
struct Nil end; const NL = Nil()
struct ConsT{T}; h::T; t::Union{ConsT{T},Nil}; end   # homogeneous, fully typed (the "what if")

build_any(n) = (acc=NL; for i in n:-1:1; acc=ConsAny(i,acc); end; acc)
build_typed(n) = (acc::Union{ConsT{Int},Nil}=NL; for i in n:-1:1; acc=ConsT{Int}(i,acc); end; acc)

function sum_consany(c)              # .h is ::Any -> boxed Int, dynamic +
    s = 0
    while c isa ConsAny; s += c.h; c = c.t; end
    s
end
function sum_const(c)                # .h is ::Int -> unboxed
    s = 0
    while c isa ConsT; s += c.h; c = c.t; end
    s
end
sum_vec(v) = (s = 0; @inbounds for i in eachindex(v); s += v[i]; end; s)

function best(f, x; reps=300)
    f(x); t = Inf
    for _ in 1:reps; g=time(); f(x); t=min(t,time()-g); end
    t*1e6
end

ca = build_any(N); ct = build_typed(N)
va = Any[i for i in 1:N]; vi = collect(1:N)
@assert sum_consany(ca) == sum_const(ct) == sum_vec(va) == sum_vec(vi) == N*(N+1)÷2

println("sum of $N Ints (microseconds, best of 300):")
println("  Cons{Any}    (linked, boxed h) : ", round(best(sum_consany, ca), digits=2))
println("  Cons{Int}    (linked, typed h) : ", round(best(sum_const, ct), digits=2))
println("  Vector{Any}  (contig, boxed)   : ", round(best(sum_vec, va), digits=2))
println("  Vector{Int}  (contig, unboxed) : ", round(best(sum_vec, vi), digits=2))
