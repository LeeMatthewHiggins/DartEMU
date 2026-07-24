# Third-party notices

The `dart_emu` **source code** is MIT licensed (see `LICENSE`).

This repository additionally redistributes several **prebuilt binary
artifacts** — guest images under `example/assets/` and `data/` — that
contain third-party software under its own licences. Those licences
apply to those artifacts, not to the MIT-licensed Dart source. This file
records what is bundled, where it came from, and under what terms.

If you depend on `dart_emu` as a library and supply your own guest
images, none of the notices below apply to you.

---

## `example/assets/root-riscv64.bin` — RV64 root filesystem

Built by `tool/image_builder/build_tcc.sh`. Contains:

### Tiny C Compiler (TCC)

- **Upstream:** <https://repo.or.cz/tinycc.git>
- **Revision:** `d9d02c56401e43be43760b63f7d82f771a7ed1f6` (2026-07-14)
- **Licence:** LGPL-2.1-or-later
- **Where:** `/usr/local/bin/tcc` (plus `libtcc1.a` and headers under
  `/usr/local/lib/tcc/`) inside the image
- **Licence text in the image:** `/usr/local/share/licenses/tcc/COPYING`,
  with provenance in `PROVENANCE.txt` alongside it

Regarding the LGPL: the complete corresponding source is publicly
available at the upstream URL and revision above, and the exact build
recipe used to produce the redistributed binary is in this repository at
`tool/image_builder/tcc/Dockerfile` (the revision is pinned, so the
build is reproducible). TCC is redistributed unmodified.

The repository also vendors a curated subset of TCC's test suite
(`tests/tests2/`) under `test/sandbox/tcc_tests2/`, from the same pinned
revision and under the same LGPL-2.1-or-later licence. These are test
inputs, used to check the emulator; they are unmodified.

### Alpine Linux base system

The image is assembled from an official Alpine Linux `riscv64`
minirootfs plus the `musl-dev` package. Notable components:

| Component | Licence |
| --- | --- |
| BusyBox | GPL-2.0-only |
| musl libc | MIT |
| apk-tools | GPL-2.0-only |
| OpenSSL / LibreSSL (apk dependency) | Apache-2.0 |
| zlib | Zlib |

- **Upstream:** <https://alpinelinux.org> — see
  <https://pkgs.alpinelinux.org> for per-package licences and sources.
- Alpine packages are redistributed unmodified; the assembly steps are
  in `tool/image_builder/tcc/build_tcc_image.sh`.

---

## `example/assets/root-riscv32.bin` — RV32 root filesystem

Built with Buildroot (`tool/image_builder/build_buildroot.sh`) from
BusyBox (GPL-2.0-only) and musl libc (MIT).

- **Buildroot:** <https://buildroot.org> (build tooling, GPL-2.0-or-later)

---

## `example/assets/kernel-riscv32.bin`, `kernel-riscv64.bin` — Linux kernel

- **Licence:** GPL-2.0-only (with the Linux syscall-note exception)
- **Upstream:** <https://www.kernel.org>
- The bundled RV64 kernel self-reports as
  `4.15.0-00049-ga3b1e7a-dirty`, matching the prebuilt kernel
  distributed with [TinyEMU](https://bellard.org/tinyemu/).

## `example/assets/bbl32.bin`, `bbl64.bin` — Berkeley Boot Loader

- **Licence:** BSD-3-Clause
- **Upstream:** <https://github.com/riscv-software-src/riscv-pk>
- Also originally distributed with TinyEMU.

> **Known gap:** these kernel and bootloader binaries predate this
> repository's build tooling and their exact upstream revisions are not
> recorded here. They should either be rebuilt from a pinned source (as
> the RV64 rootfs now is) or have their provenance documented. Tracked
> as follow-up work.

---

## Emulator lineage

The emulator itself is an original Dart implementation, but it was
**ported from** [TinyEMU](https://bellard.org/tinyemu/) by Fabrice
Bellard (MIT licensed), and follows its structure in places.
