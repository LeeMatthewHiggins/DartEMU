#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../data" && pwd)"
ROOTFS_DIR="${DATA_DIR}/rootfs"
IMAGE_NAME="dartemu-image-builder"
IMAGE_VARIANT="${1:-minimal}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-}"

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

mkdir -p "${ROOTFS_DIR}"

echo "Running image builder (variant: ${IMAGE_VARIANT})..."
docker run --rm --privileged \
  -v "${ROOTFS_DIR}:/output" \
  -e "IMAGE_VARIANT=${IMAGE_VARIANT}" \
  ${IMAGE_SIZE_MB:+-e "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"} \
  "${IMAGE_NAME}"

case "${IMAGE_VARIANT}" in
  dev)
    IMAGE_FILE="alpine-riscv64-dev-rootfs.bin"
    CONFIG_FILE="alpine_dev_vm.yaml"
    ;;
  *)
    IMAGE_FILE="alpine-riscv64-rootfs.bin"
    CONFIG_FILE="alpine_vm.yaml"
    ;;
esac

if [ -f "${ROOTFS_DIR}/${IMAGE_FILE}" ]; then
  echo
  echo "Image ready at: ${ROOTFS_DIR}/${IMAGE_FILE}"
  echo
  echo "Run with:"
  echo "  dart run bin/dart_emu.dart run --config data/${CONFIG_FILE}"
else
  echo "ERROR: Image was not created."
  exit 1
fi
