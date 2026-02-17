#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../data" && pwd)"
ROOTFS_DIR="${DATA_DIR}/rootfs"
IMAGE_NAME="dartemu-image-builder"
ARCH="${1:-riscv64}"
IMAGE_VARIANT="${2:-minimal}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-}"

case "${ARCH}" in
  riscv64|riscv32) ;;
  minimal|dev)
    IMAGE_VARIANT="${ARCH}"
    ARCH="riscv64"
    ;;
  *)
    echo "Usage: $0 [riscv64|riscv32] [minimal|dev]"
    echo
    echo "Examples:"
    echo "  $0                    # riscv64 minimal (256MB)"
    echo "  $0 riscv64 dev        # riscv64 dev (512MB)"
    echo "  $0 riscv32            # riscv32 minimal (256MB)"
    echo "  $0 riscv32 dev        # riscv32 dev (512MB)"
    echo "  $0 minimal            # riscv64 minimal (legacy)"
    echo "  $0 dev                # riscv64 dev (legacy)"
    exit 1
    ;;
esac

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

mkdir -p "${ROOTFS_DIR}"

echo "Running image builder (arch: ${ARCH}, variant: ${IMAGE_VARIANT})..."
docker run --rm --privileged \
  -v "${ROOTFS_DIR}:/output" \
  -e "ARCH=${ARCH}" \
  -e "IMAGE_VARIANT=${IMAGE_VARIANT}" \
  ${IMAGE_SIZE_MB:+-e "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"} \
  "${IMAGE_NAME}"

case "${IMAGE_VARIANT}" in
  dev)  IMAGE_FILE="alpine-${ARCH}-dev-rootfs.bin" ;;
  *)    IMAGE_FILE="alpine-${ARCH}-rootfs.bin" ;;
esac

if [ -f "${ROOTFS_DIR}/${IMAGE_FILE}" ]; then
  echo
  echo "Image ready at: ${ROOTFS_DIR}/${IMAGE_FILE}"
  echo
  echo "Run with:"
  echo "  dart run bin/dart_emu.dart run --config data/alpine_vm.yaml"
else
  echo "ERROR: Image was not created."
  exit 1
fi
