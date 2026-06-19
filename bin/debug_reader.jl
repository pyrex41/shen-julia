# Probe the .shen reader (read-file -> shen.<s-exprs> yacc parse) to see exactly what breaks.
using ShenJulia
using ShenJulia.Runtime
using ShenJulia.Prims
const F = Prims.F
const G = Prims.GLOBALS
fc(x) = Base.invokelatest(Prims.force, x)
call(name, args...) = fc(Base.invokelatest(F[name], args...))

boot!(false)
# minimal seeds the harness relies on (mirror run-tests)
haskey(G, "shen.*tc*") || (G["shen.*tc*"] = false)
G["*tc*"] = false

function probe(label, content)
    path = "/tmp/_probe.shen"
    write(path, content)
    print("[$label] ")
    G["shen.*residue*"] = NIL
    try
        r = call("read-file", path)
        n = 0; c = r; while c isa Runtime.Cons; n += 1; c = c.t; end
        println("OK -> ", n, " top-level form(s): ", first50(r))
    catch e
        msg = e isa Runtime.ShenExcn ? e.msg : string(e)
        res = get(G, "shen.*residue*", NIL)
        println("FAIL: ", typeof(e), " : ", msg[1:min(80,end)])
        println("        residue: ", first50(res))
    end
end
first50(x) = (s = Runtime.to_str(x); s[1:min(70, end)])

probe("atom", "5")
probe("simple form", "(+ 1 2)")
probe("one define", "(define t1 X -> X)")
probe("two defines", "(define t1 X -> X)\n(define t2 Y -> Y)")
probe("typed define", "(define t3 {number --> number} X -> X)")
probe("comment", "\\\\ a comment\n(define t4 X -> X)")
probe("string literal", "(define t5 -> \"hello\")")
probe("list literal", "(define t6 -> [1 2 3])")
probe("package", "(package mypkg- []\n(define foo X -> X))")
println("done")
