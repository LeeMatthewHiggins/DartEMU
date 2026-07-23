# Builds a lean riscv64 rootfs whose C compiler is TCC (Tiny C Compiler).
#
# Stage 1 cross-compiles a statically-linked TCC that runs on any
# riscv64 Linux. Stage 2 (Alpine, run privileged) assembles a musl
# rootfs with musl-dev headers/libc so TCC can compile and link C, and
# drops the TCC binary in.

FROM ubuntu:24.04 AS tccbuild

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-riscv64-linux-gnu \
    libc6-dev-riscv64-cross \
    libc6-riscv64-cross \
    qemu-user-static \
    git \
    make \
    file \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# TCC's build runs a few target-compiled helper tools (and the freshly
# built riscv64 tcc, to make libtcc1) on the build host. Docker's binfmt
# routes those to qemu-riscv64; point it at the riscv64 sysroot so it can
# find the loader and libc.
ENV QEMU_LD_PREFIX=/usr/riscv64-linux-gnu
# When the just-built riscv64 tcc compiles libtcc1's helpers (e.g.
# tcov.c #includes stdio.h), let it find the riscv64 sysroot headers.
ENV C_INCLUDE_PATH=/usr/riscv64-linux-gnu/include

# Pinned to an exact upstream commit: the build is reproducible, and the
# redistributed binary can be attributed to a specific revision (see
# THIRD_PARTY_NOTICES.md). "mob" is a rolling branch, so it is not a
# usable provenance record on its own.
ARG TCC_COMMIT=d9d02c56401e43be43760b63f7d82f771a7ed1f6
RUN git clone https://repo.or.cz/tinycc.git /tcc \
 && cd /tcc \
 && git checkout --detach "${TCC_COMMIT}"

WORKDIR /tcc
# Compile TCC's own sources with the riscv64 cross gcc, producing a tcc
# that runs on riscv64. --config-musl emits the musl loader path for the
# programs tcc links; a static tcc binary needs no host libc on the guest.
RUN ./configure \
      --cpu=riscv64 \
      --cross-prefix=riscv64-linux-gnu- \
      --config-musl \
      --prefix=/usr/local \
      --crtprefix=/usr/lib \
      --libpaths='{B}:/usr/lib:/lib:/usr/local/lib' \
      --elfinterp=/lib/ld-musl-riscv64.so.1 \
      --extra-ldflags=-static \
  && make \
  && make DESTDIR=/tccroot install \
  && riscv64-linux-gnu-strip /tccroot/usr/local/bin/tcc 2>/dev/null || true \
  && file /tccroot/usr/local/bin/tcc

# TCC is LGPL-2.1: ship its licence and provenance alongside the binary
# we redistribute inside the guest image.
RUN mkdir -p /tccroot/usr/local/share/licenses/tcc \
 && cp /tcc/COPYING /tcc/RELICENSING /tccroot/usr/local/share/licenses/tcc/ \
 && printf '%s\n' \
      'Tiny C Compiler (TCC)' \
      'Upstream: https://repo.or.cz/tinycc.git' \
      "Revision: ${TCC_COMMIT}" \
      'Licence:  LGPL-2.1-or-later (see COPYING)' \
      'Built by: tool/image_builder/tcc/Dockerfile in the dart_emu repo,' \
      '          which reproduces this binary from the revision above.' \
      > /tccroot/usr/local/share/licenses/tcc/PROVENANCE.txt

FROM alpine:latest

RUN apk add --no-cache \
    alpine-keys apk-tools e2fsprogs e2fsprogs-extra wget tar

COPY --from=tccbuild /tccroot /tccroot
COPY build_tcc_image.sh /build_tcc_image.sh
RUN chmod +x /build_tcc_image.sh

ENTRYPOINT ["/build_tcc_image.sh"]
