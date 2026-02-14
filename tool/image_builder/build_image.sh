#!/bin/sh
set -e

ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
IMAGE_VARIANT="${IMAGE_VARIANT:-minimal}"
OUTPUT_DIR="/output"
WORK_DIR="/tmp/image-build"
MOUNT_DIR="${WORK_DIR}/rootfs"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"

case "${IMAGE_VARIANT}" in
  dev)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-512}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-riscv64-dev-rootfs.bin"
    ;;
  *)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-256}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-riscv64-rootfs.bin"
    ;;
esac

mkdir -p "${WORK_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"

echo "==> Building ${IMAGE_VARIANT} image (${IMAGE_SIZE_MB}MB)..."
echo "==> Resolving Alpine riscv64 minirootfs URL..."

RELEASE_DIR="${MIRROR}/${ALPINE_VERSION}/releases/riscv64"
TARBALL_NAME=$(wget -qO- "${RELEASE_DIR}/" \
  | grep -oE 'alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-riscv64\.tar\.gz' \
  | sort -V \
  | tail -1)

if [ -z "${TARBALL_NAME}" ]; then
  echo "ERROR: Could not find Alpine riscv64 minirootfs tarball at ${RELEASE_DIR}/"
  exit 1
fi

TARBALL_PATH="${WORK_DIR}/${TARBALL_NAME}"
echo "==> Downloading ${TARBALL_NAME}..."
wget -q --show-progress -O "${TARBALL_PATH}" "${RELEASE_DIR}/${TARBALL_NAME}"

echo "==> Creating ${IMAGE_SIZE_MB}MB ext2 image..."
dd if=/dev/zero of="${OUTPUT_FILE}" bs=1M count="${IMAGE_SIZE_MB}"
mke2fs -t ext2 -L rootfs -q "${OUTPUT_FILE}"

echo "==> Mounting image and extracting Alpine rootfs..."
mount -o loop "${OUTPUT_FILE}" "${MOUNT_DIR}"

tar xzf "${TARBALL_PATH}" -C "${MOUNT_DIR}"

mkdir -p \
  "${MOUNT_DIR}/proc" \
  "${MOUNT_DIR}/sys" \
  "${MOUNT_DIR}/dev" \
  "${MOUNT_DIR}/run" \
  "${MOUNT_DIR}/etc" \
  "${MOUNT_DIR}/tmp"

if [ "${IMAGE_VARIANT}" = "dev" ]; then
  echo "==> Installing dev packages (riscv64)..."
  apk -X "${MIRROR}/${ALPINE_VERSION}/main" \
      -X "${MIRROR}/${ALPINE_VERSION}/community" \
      --root "${MOUNT_DIR}" \
      --arch riscv64 \
      --keys-dir /etc/apk/keys \
      --no-cache \
      --initdb \
      --allow-untrusted \
      add \
        gcc \
        musl-dev \
        make \
        git \
        binutils \
        fortify-headers \
        patch \
        file \
        nano
fi

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
echo "  Alpine Linux (riscv64) on dartEMU"
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

echo "==> Configuring Alpine repositories..."
cat > "${MOUNT_DIR}/etc/apk/repositories" << REPOS_EOF
${MIRROR}/${ALPINE_VERSION}/main
${MIRROR}/${ALPINE_VERSION}/community
REPOS_EOF

echo "==> Setting up hostname and networking basics..."
echo "dartemu" > "${MOUNT_DIR}/etc/hostname"

cat > "${MOUNT_DIR}/etc/hosts" << 'HOSTS_EOF'
127.0.0.1	localhost dartemu
::1		localhost dartemu
HOSTS_EOF

cat > "${MOUNT_DIR}/etc/resolv.conf" << 'RESOLV_EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV_EOF

echo "==> Setting root account (no password)..."
if grep -q '^root:' "${MOUNT_DIR}/etc/passwd"; then
  sed -i 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "${MOUNT_DIR}/etc/passwd"
else
  echo 'root:x:0:0:root:/root:/bin/sh' >> "${MOUNT_DIR}/etc/passwd"
fi

sed -i 's|^root:.*|root::0:0:99999:7:::|' "${MOUNT_DIR}/etc/shadow"

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
echo "==> Done! (${IMAGE_VARIANT})"
echo "    Image: ${OUTPUT_FILE}"
echo "    Size:  ${IMAGE_MB}MB"
echo "    Alpine: ${TARBALL_NAME}"
echo
