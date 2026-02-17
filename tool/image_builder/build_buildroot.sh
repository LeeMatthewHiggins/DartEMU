#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../data" && pwd)"
ROOTFS_DIR="${DATA_DIR}/rootfs"
IMAGE_NAME="dartemu-buildroot-builder"
IMAGE_VARIANT="${1:-minimal}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-}"

case "${IMAGE_VARIANT}" in
  minimal|dev) ;;
  *)
    echo "Usage: $0 [minimal|dev]"
    echo
    echo "Builds a riscv32 rootfs using Buildroot (musl + busybox)."
    echo "First run takes 15-30 minutes to cross-compile the toolchain."
    echo
    echo "Examples:"
    echo "  $0              # riscv32 minimal (256MB)"
    echo "  $0 dev          # riscv32 dev with gcc, make, git (512MB)"
    exit 1
    ;;
esac

echo "Building Docker image for Buildroot builder..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/buildroot"

mkdir -p "${ROOTFS_DIR}"

echo "Running Buildroot builder (variant: ${IMAGE_VARIANT})..."
echo "This may take 15-30 minutes on first run."
docker run --rm --privileged \
  -v "${ROOTFS_DIR}:/output" \
  -e "IMAGE_VARIANT=${IMAGE_VARIANT}" \
  ${IMAGE_SIZE_MB:+-e "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"} \
  "${IMAGE_NAME}"

case "${IMAGE_VARIANT}" in
  dev)
    IMAGE_FILE="alpine-riscv32-dev-rootfs.bin"
    CONFIG_FILE="alpine_dev_vm_rv32.yaml"
    ;;
  *)
    IMAGE_FILE="alpine-riscv32-rootfs.bin"
    CONFIG_FILE="alpine_vm_rv32.yaml"
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
