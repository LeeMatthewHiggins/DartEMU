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
  minimal|dev|agentos)
    IMAGE_VARIANT="${ARCH}"
    ARCH="riscv64"
    ;;
  *)
    echo "Usage: $0 [riscv64|riscv32] [minimal|dev|agentos]"
    echo
    echo "Examples:"
    echo "  $0                    # riscv64 minimal (256MB)"
    echo "  $0 riscv64 dev        # riscv64 dev (512MB)"
    echo "  $0 riscv64 agentos    # riscv64 with the agent as its console"
    echo "  $0 riscv32            # riscv32 minimal (256MB)"
    echo "  $0 riscv32 dev        # riscv32 dev (512MB)"
    echo "  $0 minimal            # riscv64 minimal (legacy)"
    echo "  $0 dev                # riscv64 dev (legacy)"
    exit 1
    ;;
esac

BUILDER_INPUT=()
if [ "${IMAGE_VARIANT}" = "agentos" ]; then
  if [ "${ARCH}" != "riscv64" ]; then
    echo "ERROR: the agent is cross-compiled for riscv64 only."
    exit 1
  fi
  AGENT_BINARY="${SCRIPT_DIR}/../../agentos/build/agentos-riscv64"
  if [ ! -f "${AGENT_BINARY}" ]; then
    echo "==> Agent binary missing; building it..."
    "${SCRIPT_DIR}/../../agentos/build_guest.sh"
  fi
  BUILDER_INPUT=(-v "$(cd "$(dirname "${AGENT_BINARY}")" && pwd)/$(basename "${AGENT_BINARY}"):/input/agentos:ro")
fi

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

mkdir -p "${ROOTFS_DIR}"

echo "Running image builder (arch: ${ARCH}, variant: ${IMAGE_VARIANT})..."
docker run --rm --privileged \
  -v "${ROOTFS_DIR}:/output" \
  "${BUILDER_INPUT[@]}" \
  -e "ARCH=${ARCH}" \
  -e "IMAGE_VARIANT=${IMAGE_VARIANT}" \
  ${IMAGE_SIZE_MB:+-e "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"} \
  "${IMAGE_NAME}"

case "${IMAGE_VARIANT}" in
  dev)      IMAGE_FILE="alpine-${ARCH}-dev-rootfs.bin" ;;
  agentos)  IMAGE_FILE="alpine-${ARCH}-agentos-rootfs.bin" ;;
  *)        IMAGE_FILE="alpine-${ARCH}-rootfs.bin" ;;
esac

case "${ARCH}:${IMAGE_VARIANT}" in
  riscv64:agentos) CONFIG_FILE="agentos_vm.yaml" ;;
  riscv32:dev) CONFIG_FILE="alpine_dev_vm_rv32.yaml" ;;
  riscv32:*) CONFIG_FILE="alpine_vm_rv32.yaml" ;;
  riscv64:dev) CONFIG_FILE="alpine_dev_vm.yaml" ;;
  *) CONFIG_FILE="alpine_vm.yaml" ;;
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
