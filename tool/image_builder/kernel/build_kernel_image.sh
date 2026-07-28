#!/bin/bash
set -e

KERNEL_SERIES="${KERNEL_SERIES:-6.12}"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.41}"
OUTPUT_DIR="/output"
WORK_DIR="/cache"
FRAGMENT="/dartemu.config"

CROSS_COMPILE="riscv64-linux-gnu-"
OUTPUT_FILE="${OUTPUT_DIR}/kernel-riscv64-${KERNEL_SERIES}.bin"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

TARBALL="linux-${KERNEL_VERSION}.tar.xz"
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${TARBALL}"

echo "==> Building Linux ${KERNEL_VERSION} for riscv64..."

if [ ! -f "${WORK_DIR}/${TARBALL}" ]; then
  echo "==> Downloading ${TARBALL}..."
  wget -q --show-progress -O "${WORK_DIR}/${TARBALL}" "${TARBALL_URL}"
fi

SRC_DIR="${WORK_DIR}/linux-${KERNEL_VERSION}"
if [ ! -d "${SRC_DIR}" ]; then
  echo "==> Extracting..."
  tar xf "${WORK_DIR}/${TARBALL}" -C "${WORK_DIR}"
fi

cd "${SRC_DIR}"

echo "==> Configuring (defconfig + dartEMU fragment)..."
make ARCH=riscv CROSS_COMPILE="${CROSS_COMPILE}" defconfig
./scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}"
make ARCH=riscv CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

echo "==> Verifying the emulator's devices are built in, not modular..."
REQUIRED=(
  CONFIG_VIRTIO_MMIO
  CONFIG_VIRTIO_BLK
  CONFIG_VIRTIO_CONSOLE
  CONFIG_EXT4_FS
  CONFIG_SERIAL_EARLYCON_RISCV_SBI
  CONFIG_SIFIVE_PLIC
  CONFIG_9P_FS
  CONFIG_NET_9P_VIRTIO
)
MISSING=0
for OPT in "${REQUIRED[@]}"; do
  if ! grep -q "^${OPT}=y$" .config; then
    echo "    MISSING: ${OPT} is not built in ($(grep "${OPT}" .config || echo 'absent'))"
    MISSING=1
  fi
done
if [ "${MISSING}" -ne 0 ]; then
  echo "ERROR: the kernel would not reach its root filesystem. Fix the fragment."
  exit 1
fi
echo "    All required options are =y"

echo "==> Building (this takes several minutes)..."
make ARCH=riscv CROSS_COMPILE="${CROSS_COMPILE}" -j"$(nproc)" Image

cp arch/riscv/boot/Image "${OUTPUT_FILE}"

IMAGE_BYTES=$(stat -c %s "${OUTPUT_FILE}")
echo
echo "==> Done!"
echo "    Kernel:  ${OUTPUT_FILE}"
echo "    Size:    $((IMAGE_BYTES / 1048576))MB (${IMAGE_BYTES} bytes)"
echo "    Version: ${KERNEL_VERSION}"
echo
echo "    Boot it with useBuiltinSbi: true — this kernel expects an SBI and"
echo "    has no HTIF console driver."
