FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    cpio \
    flex \
    gcc-riscv64-linux-gnu \
    libelf-dev \
    libssl-dev \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY build_kernel_image.sh /build_kernel_image.sh
COPY dartemu.config /dartemu.config
RUN chmod +x /build_kernel_image.sh

ENTRYPOINT ["/build_kernel_image.sh"]
