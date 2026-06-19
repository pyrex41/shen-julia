# Decompose per-call overhead for a call-heavy function (fib). Each mechanism isolates one
# layer of the current call path so we can see what actually costs.
struct Bounce; f::Function; args::Vector{Any}; end
@inline isb(x) = x isa Bounce

# A) FULL current path: Dict{String,Function} lookup + _safe_caller wrapper (vararg + force)
const FD = Dict{String,Function}()
safecaller(f) = (args...) -> (r = f(args...); isb(r) ? error("bounce") : r)
rawA(n) = n < 2 ? n : FD["fib"](n-1) + FD["fib"](n-2)
FD["fib"] = safecaller(rawA)
callA(n) = FD["fib"](n)

# B) Dict lookup, but NO wrapper (call raw fn straight from the table)
const FB = Dict{String,Function}()
rawB(n) = n < 2 ? n : FB["fib"](n-1) + FB["fib"](n-2)
FB["fib"] = rawB
callB(n) = FB["fib"](n)

# C) mutable struct field (no string hash) holding an abstract Function, no wrapper
mutable struct Cell; fn::Function; end
const CELL = Cell(identity)
rawC(n) = n < 2 ? n : CELL.fn(n-1) + CELL.fn(n-2)
CELL.fn = rawC
callC(n) = CELL.fn(n)

# D) direct monomorphic recursion (the ceiling: devirtualized, inlinable)
callD(n) = n < 2 ? n : callD(n-1) + callD(n-2)

# E) Dict{Symbol,Function}: codegen would emit :fib (Julia symbols have cached/pointer hashes)
const FE = Dict{Symbol,Function}()
rawE(n) = n < 2 ? n : FE[:fib](n-1) + FE[:fib](n-2)
FE[:fib] = rawE
callE(n) = FE[:fib](n)

# F) integer-slot Vector{Function}: codegen emits FV[slot] (no hash at all)
const FV = Function[identity]
rawF(n) = n < 2 ? n : FV[1](n-1) + FV[1](n-2)
FV[1] = rawF
callF(n) = FV[1](n)

best(f, x; reps=15) = (f(x); t=Inf; for _ in 1:reps; g=time(); f(x); t=min(t,time()-g); end; t*1e3)

n = 30
@assert callA(n) == callB(n) == callC(n) == callD(n) == callE(n) == callF(n)
println("fib($n) per-call-path decomposition (ms, best of 15):")
println("  A) Dict{String} + wrapper/force : ", round(best(callA,n), digits=3))
println("  B) Dict{String}, no wrapper     : ", round(best(callB,n), digits=3))
println("  E) Dict{Symbol}, no wrapper     : ", round(best(callE,n), digits=3))
println("  F) Vector{Function}[slot]       : ", round(best(callF,n), digits=3))
println("  C) struct field                 : ", round(best(callC,n), digits=3))
println("  D) direct recursion (ceiling)   : ", round(best(callD,n), digits=3))
