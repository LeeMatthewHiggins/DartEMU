#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../data" && pwd)"
KERNEL_DIR="${DATA_DIR}/kernel"
# Kept outside the container so a config change costs an incremental rebuild
# rather than another kernel download and full compile.
CACHE_DIR="${KERNEL_CACHE_DIR:-${SCRIPT_DIR}/.kernel-cache}"
IMAGE_NAME="dartemu-kernel-builder"
KERNEL_SERIES="${KERNEL_SERIES:-6.12}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.41}"

TARGET_ARCH="${1:-riscv64}"

case "${TARGET_ARCH}" in
  riscv64|riscv32) ;;
  -h|--help|*)
    echo "Usage: $0 [riscv64|riscv32]"
    echo
    echo "Cross-compiles a modern Linux kernel with the devices the emulator"
    echo "presents built in. The result boots directly, with no BBL or"
    echo "OpenSBI: set useBuiltinSbi on the machine config instead."
    echo
    echo "Override the version with:"
    echo "  KERNEL_VERSION=6.12.41 KERNEL_SERIES=6.12 $0"
    case "${TARGET_ARCH}" in
      -h|--help) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
esac

echo "Building Docker image for the kernel builder..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/kernel"

mkdir -p "${KERNEL_DIR}" "${CACHE_DIR}"

echo "Cross-compiling Linux ${KERNEL_VERSION} for ${TARGET_ARCH} (several minutes)..."
docker run --rm \
  -v "${KERNEL_DIR}:/output" \
  -v "${CACHE_DIR}:/cache" \
  -e "KERNEL_SERIES=${KERNEL_SERIES}" \
  -e "KERNEL_VERSION=${KERNEL_VERSION}" \
  -e "TARGET_ARCH=${TARGET_ARCH}" \
  "${IMAGE_NAME}"

KERNEL_FILE="${KERNEL_DIR}/kernel-${TARGET_ARCH}-${KERNEL_SERIES}.bin"

if [ -f "${KERNEL_FILE}" ]; then
  echo
  echo "Kernel ready at: ${KERNEL_FILE}"
  echo
  echo "Run with:"
  echo "  dart run bin/dart_emu.dart run --config data/modern_vm.yaml"
else
  echo "ERROR: Kernel was not created."
  exit 1
fi
