# Kernel provenance

These `klambda/*.kl` files are vendored from Mark Tarver's Shen 42.0 (S42)
distribution and are baked by `bin/gen_kernel.jl`.

- Archive: https://www.shenlanguage.org/Download/S42.zip
- Retrieved: 2026-08-27 (archive Last-Modified 2026-08-25)
- SHA-256: `30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23`
- Canonical mirror tag: `s42-pristine-20260825`

The upstream runtime version is the string `"42"`; this port presents it as
Shen 42.0 in human-facing documentation. `extension-launcher.kl` is retained as
a local shen-julia CLI extension and is not part of the upstream archive.
