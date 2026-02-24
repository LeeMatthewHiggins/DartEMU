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
BR2_TOOLCHAIN_BUILDROOT_CXX=y
BR2_INSTALL_LIBSTDCPP=y
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

if [ "${IMAGE_VARIANT}" = "dev" ]; then
  BR_OUTPUT="${WORK_DIR}/buildroot-${BUILDROOT_VERSION}/output"
  CROSS_PREFIX="riscv32-buildroot-linux-musl"
  CROSS_CC="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-gcc"
  CROSS_CXX="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-g++"
  SYSROOT="${BR_OUTPUT}/host/${CROSS_PREFIX}/sysroot"
  export PATH="${BR_OUTPUT}/host/bin:${PATH}"

  echo "==> Building native binutils for riscv32 (Canadian cross)..."
  BINUTILS_BR_DIR=$(ls -d "${BR_OUTPUT}/build/host-binutils-"* 2>/dev/null | head -1)
  if [ -z "${BINUTILS_BR_DIR}" ]; then
    echo "ERROR: Could not find binutils source in Buildroot output"
    exit 1
  fi
  BINUTILS_VERSION=$(basename "${BINUTILS_BR_DIR}" | sed 's/host-binutils-//')
  echo "    Using binutils ${BINUTILS_VERSION} from Buildroot build"

  BINUTILS_SRC_DIR="${WORK_DIR}/binutils-${BINUTILS_VERSION}-src"
  if [ ! -d "${BINUTILS_SRC_DIR}" ]; then
    echo "    Copying clean binutils source..."
    cp -a "${BINUTILS_BR_DIR}" "${BINUTILS_SRC_DIR}"
    make -C "${BINUTILS_SRC_DIR}" distclean 2>/dev/null || true
  fi

  BINUTILS_NATIVE_BUILD="${WORK_DIR}/binutils-native-build"
  BINUTILS_NATIVE_INSTALL="${WORK_DIR}/binutils-native-install"
  mkdir -p "${BINUTILS_NATIVE_BUILD}" "${BINUTILS_NATIVE_INSTALL}"

  cd "${BINUTILS_NATIVE_BUILD}"
  MAKEINFO=true \
  CC="${CROSS_CC}" \
  CXX="${CROSS_CXX}" \
  CC_FOR_BUILD="gcc" \
  CXX_FOR_BUILD="g++" \
  AR="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-ar" \
  RANLIB="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-ranlib" \
  "${BINUTILS_SRC_DIR}/configure" \
    --build="$(gcc -dumpmachine)" \
    --host="${CROSS_PREFIX}" \
    --target="${CROSS_PREFIX}" \
    --prefix=/usr \
    --with-sysroot=/ \
    --disable-nls \
    --disable-werror \
    --disable-gdb \
    --disable-gdbserver \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline

  make -j"$(nproc)" \
    MAKEINFO=true \
    CFLAGS_FOR_BUILD="-O2" \
    CXXFLAGS_FOR_BUILD="-O2"
  make DESTDIR="${BINUTILS_NATIVE_INSTALL}" MAKEINFO=true install

  echo "    Binutils built: $(ls "${BINUTILS_NATIVE_INSTALL}"/usr/bin/ 2>/dev/null | wc -l) binaries"
  cd "${WORK_DIR}/buildroot-${BUILDROOT_VERSION}"

  echo "==> Building native GCC for riscv32 (Canadian cross)..."

  GCC_SRC_DIR=$(ls -d "${BR_OUTPUT}/build/host-gcc-final-"* 2>/dev/null | head -1)
  if [ -z "${GCC_SRC_DIR}" ]; then
    echo "ERROR: Could not find GCC source in Buildroot output"
    exit 1
  fi
  GCC_VERSION=$(basename "${GCC_SRC_DIR}" | sed 's/host-gcc-final-//')
  echo "    Using GCC ${GCC_VERSION} from Buildroot build"

  echo "    Downloading GMP/MPFR/MPC prerequisites..."
  cd "${GCC_SRC_DIR}"
  if [ -x contrib/download_prerequisites ]; then
    contrib/download_prerequisites
  fi

  GCC_NATIVE_BUILD="${WORK_DIR}/gcc-native-build"
  GCC_NATIVE_INSTALL="${WORK_DIR}/gcc-native-install"
  mkdir -p "${GCC_NATIVE_BUILD}" "${GCC_NATIVE_INSTALL}"

  echo "    Patching basename declarations for musl compatibility..."
  sed -i '/^extern char \*basename/s/^/\/\/ /' \
    "${GCC_SRC_DIR}/include/libiberty.h"
  sed -i 's/= basename (input_file_name)/= lbasename (input_file_name)/' \
    "${GCC_SRC_DIR}/gcc/gcov.cc"

  if [ ! -x "${CROSS_CXX}" ]; then
    echo "ERROR: Cross-g++ not found at ${CROSS_CXX}"
    echo "       BR2_INSTALL_LIBSTDCPP=y must be in Buildroot config"
    exit 1
  fi

  cd "${GCC_NATIVE_BUILD}"
  CC="${CROSS_CC}" \
  CXX="${CROSS_CXX}" \
  CC_FOR_BUILD="gcc" \
  CXX_FOR_BUILD="g++" \
  AR="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-ar" \
  RANLIB="${BR_OUTPUT}/host/bin/${CROSS_PREFIX}-ranlib" \
  "${GCC_SRC_DIR}/configure" \
    --build="$(gcc -dumpmachine)" \
    --host="${CROSS_PREFIX}" \
    --target="${CROSS_PREFIX}" \
    --prefix=/usr \
    --with-sysroot=/ \
    --with-build-sysroot="${SYSROOT}" \
    --enable-languages=c \
    --disable-bootstrap \
    --disable-multilib \
    --disable-libsanitizer \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --disable-nls \
    --disable-lto \
    --disable-plugin \
    --disable-threads \
    --without-headers \
    --without-isl

  make -j"$(nproc)" \
    CFLAGS_FOR_BUILD="-O2 -D_GNU_SOURCE" \
    CXXFLAGS_FOR_BUILD="-O2 -D_GNU_SOURCE" \
    all-gcc all-target-libgcc
  make DESTDIR="${GCC_NATIVE_INSTALL}" install-gcc install-target-libgcc

  cd "${WORK_DIR}/buildroot-${BUILDROOT_VERSION}"
fi

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

if [ "${IMAGE_VARIANT}" = "dev" ] && [ -d "${GCC_NATIVE_INSTALL:-/nonexistent}" ]; then
  echo "==> Installing native GCC into rootfs..."
  cp -a "${GCC_NATIVE_INSTALL}/usr/bin/"*gcc* "${MOUNT_DIR}/usr/bin/" 2>/dev/null || true

  if [ -d "${GCC_NATIVE_INSTALL}/usr/lib/gcc" ]; then
    cp -a "${GCC_NATIVE_INSTALL}/usr/lib/gcc" "${MOUNT_DIR}/usr/lib/"
  fi

  for BIN in cc1 collect2 lto-wrapper lto1; do
    SRC=$(find "${GCC_NATIVE_INSTALL}" -name "${BIN}" -type f -print -quit 2>/dev/null)
    if [ -n "${SRC}" ]; then
      REL="${SRC#${GCC_NATIVE_INSTALL}}"
      DEST_DIR="${MOUNT_DIR}$(dirname "${REL}")"
      mkdir -p "${DEST_DIR}"
      cp -a "${SRC}" "${DEST_DIR}/"
      echo "    Installed ${BIN} -> ${REL}"
    fi
  done

  ln -sf "${CROSS_PREFIX}-gcc" "${MOUNT_DIR}/usr/bin/gcc"
  ln -sf "${CROSS_PREFIX}-gcc" "${MOUNT_DIR}/usr/bin/cc"

  echo "==> Installing native binutils into rootfs..."
  if [ -d "${BINUTILS_NATIVE_INSTALL:-/nonexistent}/usr" ]; then
    cp -a "${BINUTILS_NATIVE_INSTALL}/usr/bin/"* "${MOUNT_DIR}/usr/bin/" 2>/dev/null || true
    cp -a "${BINUTILS_NATIVE_INSTALL}/usr/lib/"* "${MOUNT_DIR}/usr/lib/" 2>/dev/null || true
    for TOOL in as ld ar nm ranlib objcopy objdump readelf strip; do
      if [ -x "${MOUNT_DIR}/usr/bin/${CROSS_PREFIX}-${TOOL}" ] && \
         [ ! -e "${MOUNT_DIR}/usr/bin/${TOOL}" ]; then
        ln -sf "${CROSS_PREFIX}-${TOOL}" "${MOUNT_DIR}/usr/bin/${TOOL}"
      fi
    done
    echo "    Binutils installed: $(ls "${MOUNT_DIR}"/usr/bin/*as* "${MOUNT_DIR}"/usr/bin/*ld* 2>/dev/null | wc -l) key binaries"
  fi

  echo "==> Installing sysroot headers and libraries..."
  if [ -d "${SYSROOT}/usr/include" ]; then
    cp -a "${SYSROOT}/usr/include" "${MOUNT_DIR}/usr/"
    echo "    Headers installed"
  fi

  for OBJ in crt1.o crti.o crtn.o Scrt1.o rcrt1.o; do
    SRC=$(find "${SYSROOT}" -name "${OBJ}" -print -quit 2>/dev/null)
    if [ -n "${SRC}" ]; then
      cp -a "${SRC}" "${MOUNT_DIR}/usr/lib/"
    fi
  done
  for LIB in libc.a libc.so libm.a libpthread.a libdl.a librt.a; do
    SRC=$(find "${SYSROOT}" -name "${LIB}" -print -quit 2>/dev/null)
    if [ -n "${SRC}" ]; then
      cp -a "${SRC}" "${MOUNT_DIR}/usr/lib/"
    fi
  done
  echo "    CRT: $(ls "${MOUNT_DIR}"/usr/lib/crt*.o 2>/dev/null | wc -l) objects"
  echo "    Libs: $(ls "${MOUNT_DIR}"/usr/lib/libc.* 2>/dev/null | wc -l) libc files"

  echo "    GCC installed: $(ls "${MOUNT_DIR}"/usr/bin/*gcc* 2>/dev/null | wc -l) binaries"
fi

echo "==> Writing /etc/inittab..."
cat > "${MOUNT_DIR}/etc/inittab" << 'INITTAB_EOF'
::sysinit:/bin/hostname dartemu
::sysinit:/bin/sh -c 'ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null && route add default gw 10.0.2.2 2>/dev/null'
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
nameserver 10.0.2.3
nameserver 8.8.8.8
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
