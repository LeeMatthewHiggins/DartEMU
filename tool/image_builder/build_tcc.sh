#!/bin/bash
set -e

# Builds a lean riscv64 rootfs whose C compiler is TCC (Tiny C Compiler).
#
# TCC is a few hundred KB and does its own linking, so the resulting
# image is small enough to ship as a demo/test asset — unlike the GCC
# "dev" variants, which produce ~512MB images.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../data" && pwd)"
ROOTFS_DIR="${DATA_DIR}/rootfs"
IMAGE_NAME="dartemu-tcc-builder"
IMAGE_FILE="alpine-riscv64-tcc-rootfs.bin"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0"
  echo
  echo "Builds ${IMAGE_FILE} into data/rootfs/."
  echo
  echo "Environment:"
  echo "  IMAGE_SIZE_MB  assembly size before shrinking (default 64)"
  echo "  SLACK_MB       free space left in the final image (default 8)"
  exit 0
fi

echo "Building Docker image (cross-compiles TCC for riscv64)..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/tcc"

mkdir -p "${ROOTFS_DIR}"

echo "Assembling rootfs..."
docker run --rm --privileged \
  -v "${ROOTFS_DIR}:/output" \
  ${IMAGE_SIZE_MB:+-e "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"} \
  ${SLACK_MB:+-e "SLACK_MB=${SLACK_MB}"} \
  "${IMAGE_NAME}"

if [ -f "${ROOTFS_DIR}/${IMAGE_FILE}" ]; then
  echo
  echo "Image ready at: ${ROOTFS_DIR}/${IMAGE_FILE}"
  echo
  echo "To use it as the bundled demo/test rootfs:"
  echo "  cp ${ROOTFS_DIR}/${IMAGE_FILE} example/assets/root-riscv64.bin"
else
  echo "ERROR: Image was not created."
  exit 1
fi
