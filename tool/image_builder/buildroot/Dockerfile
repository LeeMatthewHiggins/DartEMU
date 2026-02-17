FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    build-essential \
    ca-certificates \
    cpio \
    e2fsprogs \
    file \
    git \
    libncurses-dev \
    python3 \
    rsync \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY build_rv32_image.sh /build_rv32_image.sh
RUN chmod +x /build_rv32_image.sh

ENTRYPOINT ["/build_rv32_image.sh"]
