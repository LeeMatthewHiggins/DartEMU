#!/bin/bash
# Cross-compiles the agent for the guest.
#
# The result is static on purpose. The guest is Alpine, so its libc is musl,
# and a dynamically linked glibc binary would not start there. Static also
# means the agent keeps working after the model has rearranged the machine.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT="${SCRIPT_DIR}/build/agentos-riscv64"
BUILDER_IMAGE="dartemu-agentos-builder"

mkdir -p "${SCRIPT_DIR}/build"

echo "==> Preparing the cross toolchain..."
docker build -t "${BUILDER_IMAGE}" -f - "${SCRIPT_DIR}" >/dev/null <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-riscv64-linux-gnu libc6-dev-riscv64-cross make \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE

echo "==> Building agentos for riscv64..."
docker run --rm \
  -v "${REPO_DIR}:/work" \
  -w /work/agentos \
  "${BUILDER_IMAGE}" \
  make guest

echo
echo "Agent ready at: ${OUTPUT}"
file "${OUTPUT}" 2>/dev/null || true
