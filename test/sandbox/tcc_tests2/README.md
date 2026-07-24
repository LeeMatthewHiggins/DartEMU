# TCC tests2 conformance fixtures

These `.c` / `.expect` pairs are a curated subset of the Tiny C Compiler
test suite (`tests/tests2/`), used here as an **emulator** correctness
check: each program is compiled by the guest's `cc` (TCC) and run on the
emulated RV64 CPU, then its output is compared against the expected
result. They exercise a broad slice of code generation and the musl
runtime — arithmetic, structs, switch, recursion, pointer arithmetic,
the soft-float math library, VLAs, integer promotion, C11 `_Generic`,
and more.

- **Upstream:** <https://repo.or.cz/tinycc.git>, `tests/tests2/`
- **Revision:** `d9d02c56401e43be43760b63f7d82f771a7ed1f6` (the same
  revision `tool/image_builder/tcc/Dockerfile` builds the bundled
  compiler from)
- **Licence:** LGPL-2.1-or-later (see `THIRD_PARTY_NOTICES.md`)

This is a subset chosen to pass deterministically on the bundled image.
The full suite includes cases that legitimately do not apply here —
architecture-specific inline assembly (x86/arm64/riscv/winarm64),
the bounds checker, TLS/pthread, and cases needing argv or stdin — which
upstream's own runner also skips. To run the whole suite against a local
checkout, see `tool/bench/` (the discovery harness used to select this
subset).
