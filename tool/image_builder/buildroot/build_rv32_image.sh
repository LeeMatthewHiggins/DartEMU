#!/bin/bash
set -e

BUILDROOT_VERSION="${BUILDROOT_VERSION:-2024.11.1}"
IMAGE_VARIANT="${IMAGE_VARIANT:-minimal}"
OUTPUT_DIR="/output"
WORK_DIR="/tmp/buildroot-build"
MOUNT_DIR="/tmp/rootfs-mount"

case "${IMAGE_VARIANT}" in
  dev)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-512}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-riscv32-dev-rootfs.bin"
    ;;
  *)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-256}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-riscv32-rootfs.bin"
    ;;
esac

mkdir -p "${WORK_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"

echo "==> Building riscv32 ${IMAGE_VARIANT} image (${IMAGE_SIZE_MB}MB)..."
echo "==> Downloading Buildroot ${BUILDROOT_VERSION}..."

TARBALL="buildroot-${BUILDROOT_VERSION}.tar.xz"
TARBALL_URL="https://buildroot.org/downloads/${TARBALL}"

if [ ! -f "${WORK_DIR}/${TARBALL}" ]; then
  wget -q --show-progress -O "${WORK_DIR}/${TARBALL}" "${TARBALL_URL}"
fi

echo "==> Extracting Buildroot..."
tar xf "${WORK_DIR}/${TARBALL}" -C "${WORK_DIR}"
cd "${WORK_DIR}/buildroot-${BUILDROOT_VERSION}"

echo "==> Configuring Buildroot for riscv32 + musl + busybox..."

BUSYBOX_FRAGMENT="${WORK_DIR}/busybox-rv32.fragment"
cat > "${BUSYBOX_FRAGMENT}" << 'FRAG_EOF'
# CONFIG_HWCLOCK is not set
# CONFIG_NANDWRITE is not set
# CONFIG_NANDDUMP is not set
# CONFIG_UBIATTACH is not set
# CONFIG_UBIDETACH is not set
# CONFIG_UBIMKVOL is not set
# CONFIG_UBIRMVOL is not set
# CONFIG_UBIRSVOL is not set
# CONFIG_UBIUPDATEVOL is not set
FRAG_EOF

cat > .config << DEFCONFIG_EOF
BR2_riscv=y
BR2_RISCV_32=y
BR2_RISCV_ISA_RVM=y
BR2_RISCV_ISA_RVA=y
BR2_RISCV_ISA_RVF=y
BR2_RISCV_ISA_RVD=y
BR2_RISCV_ISA_RVC=y
BR2_RISCV_ABI_ILP32D=y
BR2_TOOLCHAIN_BUILDROOT_MUSL=y
BR2_PACKAGE_BUSYBOX=y
BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES="${BUSYBOX_FRAGMENT}"
BR2_TARGET_GENERIC_HOSTNAME="dartemu"
BR2_TARGET_GENERIC_ISSUE="Alpine-style Linux (riscv32) on dartEMU"
BR2_TARGET_GENERIC_ROOT_PASSWD=""
BR2_SYSTEM_BIN_SH_BUSYBOX=y
BR2_INIT_BUSYBOX=y
BR2_TARGET_GENERIC_GETTY_PORT="hvc0"
BR2_TARGET_GENERIC_GETTY_BAUDRATE_115200=y
DEFCONFIG_EOF

if [ "${IMAGE_VARIANT}" = "dev" ]; then
  echo "==> Adding dev packages to config..."
  cat >> .config << 'DEV_EOF'
BR2_PACKAGE_HOST_GCC_FINAL=y
BR2_PACKAGE_MAKE=y
BR2_PACKAGE_GIT=y
BR2_PACKAGE_NANO=y
BR2_PACKAGE_BINUTILS=y
BR2_PACKAGE_FILE=y
BR2_PACKAGE_PATCH=y
DEV_EOF
fi

make olddefconfig
echo "==> Building rootfs (this may take 15-30 minutes on first run)..."
make -j"$(nproc)"

echo "==> Creating ${IMAGE_SIZE_MB}MB ext2 image..."
dd if=/dev/zero of="${OUTPUT_FILE}" bs=1M count="${IMAGE_SIZE_MB}"
mke2fs -t ext2 -L rootfs -q "${OUTPUT_FILE}"

echo "==> Mounting image and populating rootfs..."
mount -o loop "${OUTPUT_FILE}" "${MOUNT_DIR}"

ROOTFS_TAR="${WORK_DIR}/buildroot-${BUILDROOT_VERSION}/output/images/rootfs.tar"
if [ -f "${ROOTFS_TAR}" ]; then
  tar xf "${ROOTFS_TAR}" -C "${MOUNT_DIR}"
elif [ -f "${ROOTFS_TAR}.gz" ]; then
  tar xzf "${ROOTFS_TAR}.gz" -C "${MOUNT_DIR}"
else
  echo "ERROR: Buildroot rootfs tarball not found"
  umount "${MOUNT_DIR}"
  exit 1
fi

mkdir -p \
  "${MOUNT_DIR}/proc" \
  "${MOUNT_DIR}/sys" \
  "${MOUNT_DIR}/dev" \
  "${MOUNT_DIR}/run" \
  "${MOUNT_DIR}/tmp"

echo "==> Writing /init..."
cat > "${MOUNT_DIR}/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null || true

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100

hostname dartemu

echo
echo "  Alpine-style Linux (riscv32) on dartEMU"
echo

if [ -x /sbin/init ]; then
  exec /sbin/init
fi

exec /bin/sh
INIT_EOF
chmod +x "${MOUNT_DIR}/init"

echo "==> Writing /etc/inittab..."
cat > "${MOUNT_DIR}/etc/inittab" << 'INITTAB_EOF'
::sysinit:/bin/hostname dartemu
hvc0::respawn:/sbin/getty -L 115200 hvc0 vt100
::shutdown:/bin/umount -a -r
INITTAB_EOF

echo "==> Setting up hostname and networking..."
echo "dartemu" > "${MOUNT_DIR}/etc/hostname"

cat > "${MOUNT_DIR}/etc/hosts" << 'HOSTS_EOF'
127.0.0.1	localhost dartemu
::1		localhost dartemu
HOSTS_EOF

cat > "${MOUNT_DIR}/etc/resolv.conf" << 'RESOLV_EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV_EOF

mkdir -p "${MOUNT_DIR}/root"
cat > "${MOUNT_DIR}/root/.profile" << 'PROFILE_EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100
PROFILE_EOF

echo "==> Unmounting image..."
umount "${MOUNT_DIR}"

echo "==> Checking filesystem..."
e2fsck -y -f "${OUTPUT_FILE}" || true

IMAGE_BYTES=$(stat -c %s "${OUTPUT_FILE}" 2>/dev/null || stat -f %z "${OUTPUT_FILE}")
IMAGE_MB=$((IMAGE_BYTES / 1048576))

echo
echo "==> Done! (riscv32 ${IMAGE_VARIANT})"
echo "    Image: ${OUTPUT_FILE}"
echo "    Size:  ${IMAGE_MB}MB"
echo "    Built with: Buildroot ${BUILDROOT_VERSION}"
echo
