#!/usr/bin/env julia
# Shen/Julia launcher.
#
# For eval / script / --version / --help this drives the kernel's *standard*
# launcher (shen.x.launcher.main, from extension-launcher.kl) — the same entry
# point shen-go / shen-rust / ShenScript use — so the CLI is byte-compatible
# across ports:
#
#   shen eval -e "(+ 40 2)"     -> prints the value of the expression + newline
#   shen eval -l prog.shen -e EXPR
#   shen script prog.shen       -> quiet-loads + runs prog.shen (no defun echo)
#   shen --version              -> "<version> port ..." banner (contains 41.2)
#   shen                        -> interactive REPL
#   shen --boot-only            -> boot the kernel, print version, exit (timing aid)
#
# The interactive REPL is handled host-side so that closing stdin (EOF) exits
# cleanly instead of looping forever (the canonical shen.repl behaviour).

# The bin/shen wrapper always passes --project, so the environment is already
# active; we deliberately do NOT call Pkg.activate here (it prints an "Activating
# project ..." banner that would pollute captured stdout for bifrost goldens).
using ShenJulia
using ShenJulia: Prims, Runtime, Boot

# Build a Shen list (Cons chain) from a vector of Julia values.
function _shen_list(xs)
    acc = Runtime.NIL
    for x in Iterators.reverse(xs)
        acc = Runtime.cons(x, acc)
    end
    return acc
end

const ARGV = ARGS

if length(ARGV) >= 1 && ARGV[1] == "--boot-only"
    t0 = time()
    boot!(get(ENV, "SHEN_VERBOSE", "") == "1")
    t1 = time()
    println("Kernel loaded in $(round(t1 - t0, digits=3))s")
    println("version: ", Prims.force(Base.invokelatest(Prims.F["version"])))
    exit(0)
end

# Bare invocation, or an explicit `repl` with no extra args: interactive REPL
# with clean-on-EOF exit (repl() boots the kernel itself).
if isempty(ARGV) || (length(ARGV) == 1 && ARGV[1] == "repl")
    repl()
    exit(0)
end

# Everything else: hand off to the kernel's standard launcher for cross-port
# parity. argv[0] is the program name (used in --help / error text).
boot!(get(ENV, "SHEN_VERBOSE", "") == "1")
Prims.with_shen_stack() do
    argv = _shen_list(vcat(["shen"], ARGV))
    Base.invokelatest(Prims.F["shen.x.launcher.main"], argv)
end
flush(stdout)
