# Does push!-into-Vector beat consing an intermediate list, for building Shen lists?
# Standalone: only needs the Cons type + cons. No kernel boot (just module load).
using ShenJulia.Runtime
const NIL = Runtime.NIL
const Cons = Runtime.Cons
cons(h, t) = Runtime.cons(h, t)
ERR(m) = error(m)

# (a) reversed temp cons list (N) then prepend (N) = 2N cons-node allocations
function append_revtemp(a, b)
    rev = NIL; c = a
    while c isa Cons; rev = cons(c.h, rev); c = c.t; end
    c === NIL || ERR("non-list")
    acc = b
    while rev isa Cons; acc = cons(rev.h, acc); rev = rev.t; end
    return acc
end

# (b) push! into Vector{Any} (amortized, contiguous), build result once = N cons + 1 vector
function append_pushvec(a, b)
    buf = Any[]; c = a
    while c isa Cons; push!(buf, c.h); c = c.t; end
    c === NIL || ERR("non-list")
    acc = b
    @inbounds for i in length(buf):-1:1; acc = cons(buf[i], acc); end
    return acc
end

# (b2) count first, allocate exact-sized Vector (no doubling churn), fill, build
function append_countfill(a, b)
    n = 0; c = a
    while c isa Cons; n += 1; c = c.t; end
    c === NIL || ERR("non-list")
    buf = Vector{Any}(undef, n); c = a
    @inbounds for i in 1:n; buf[i] = c.h; c = c.t; end
    acc = b
    @inbounds for i in n:-1:1; acc = cons(buf[i], acc); end
    return acc
end

# (c) reference: kernel-style recursion = N cons, no intermediate, but grows the Julia stack
function append_rec(a, b)
    a isa Cons || return (a === NIL ? b : ERR("non-list"))
    return cons(a.h, append_rec(a.t, b))
end

from_vec(v) = (acc=NIL; @inbounds for i in length(v):-1:1; acc=cons(v[i],acc); end; acc)
len(c) = (n=0; while c isa Cons; n+=1; c=c.t; end; n)

function best(f, a, b; reps=200)
    f(a,b); t = Inf
    for _ in 1:reps
        g0 = time(); f(a,b); t = min(t, time()-g0)
    end
    t*1e6  # microseconds
end

for N in (1000, 100_000)
    a = from_vec(collect(1:N)); b = from_vec(collect(1:N))
    @assert len(append_revtemp(a,b)) == 2N
    @assert len(append_pushvec(a,b)) == 2N
    println("N=$N (microseconds, best of 200):")
    println("  reverse-temp (2N cons)    : ", round(best(append_revtemp,a,b), digits=2))
    println("  push!+Vector (grows)      : ", round(best(append_pushvec,a,b), digits=2))
    println("  count+exact Vector        : ", round(best(append_countfill,a,b), digits=2))
    try
        @assert len(append_rec(a,b)) == 2N
        println("  recursive   (N cons,stack): ", round(best(append_rec,a,b; reps=50), digits=2))
    catch e
        println("  recursive   (N cons,stack): ", typeof(e), "  <- stack overflow on long list")
    end
end
