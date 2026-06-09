# Does adding type-specialized methods (multiple dispatch on Int/Float) beat the generic
# tonum-based prim, when the arguments come in as Any (from Any-typed cells/locals)?
const N = 100_000
struct ConsAny; h::Any; t::Any; end
struct Nil end; const NL = Nil()
ERR() = error("not a number")

# current style: one generic method, tonum guards then Julia's + dispatches at runtime
tonum(x) = x isa Number ? x : ERR()
add_generic(a, b) = tonum(a) + tonum(b)

# multiple-dispatch style: concrete fast methods + generic fallback
add_disp(a::Int, b::Int)         = a + b
add_disp(a::Float64, b::Float64) = a + b
add_disp(a, b)                   = tonum(a) + tonum(b)

build(n, mk) = (acc=NL; for i in n:-1:1; acc=ConsAny(mk(i),acc); end; acc)

function sumloop(addf, c)
    s = 0
    while c isa ConsAny
        s = addf(s, c.h)
        c = c.t
    end
    s
end

best(f, c; reps=300) = (f(c); t=Inf; for _ in 1:reps; g=time(); f(c); t=min(t,time()-g); end; t*1e6)

ints  = build(N, identity)              # homogeneous Int list (stored as Any)
mixed = build(N, i -> isodd(i) ? i : Float64(i))   # heterogeneous Int/Float list

println("sum 100k via per-element add (µs, best of 300):")
println("  Int list,   generic tonum+    : ", round(best(c->sumloop(add_generic,c), ints), digits=2))
println("  Int list,   multi-dispatch    : ", round(best(c->sumloop(add_disp,c), ints), digits=2))
println("  Mixed list, generic tonum+    : ", round(best(c->sumloop(add_generic,c), mixed), digits=2))
println("  Mixed list, multi-dispatch    : ", round(best(c->sumloop(add_disp,c), mixed), digits=2))
