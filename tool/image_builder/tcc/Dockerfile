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

ARG TCC_REF=mob
RUN git clone --depth 1 --branch "${TCC_REF}" \
      https://repo.or.cz/tinycc.git /tcc

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

FROM alpine:latest

RUN apk add --no-cache \
    alpine-keys apk-tools e2fsprogs e2fsprogs-extra wget tar

COPY --from=tccbuild /tccroot /tccroot
COPY build_tcc_image.sh /build_tcc_image.sh
RUN chmod +x /build_tcc_image.sh

ENTRYPOINT ["/build_tcc_image.sh"]
