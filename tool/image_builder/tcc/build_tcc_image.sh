#!/bin/sh
set -e

ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
ARCH="riscv64"
# Assembled in a roomy image (apk must unpack musl's 28MB libc.a before
# we delete it), then shrunk to the used size plus SLACK_MB of working
# room for the guest.
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-64}"
SLACK_MB="${SLACK_MB:-8}"
OUTPUT_DIR="/output"
WORK_DIR="/tmp/image-build"
MOUNT_DIR="${WORK_DIR}/rootfs"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"
OUTPUT_FILE="${OUTPUT_DIR}/alpine-${ARCH}-tcc-rootfs.bin"

mkdir -p "${WORK_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"

echo "==> Building riscv64 TCC image (${IMAGE_SIZE_MB}MB)..."
echo "==> Resolving Alpine ${ARCH} minirootfs URL..."
RELEASE_DIR="${MIRROR}/${ALPINE_VERSION}/releases/${ARCH}"
TARBALL_NAME=$(wget -qO- "${RELEASE_DIR}/" \
  | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${ARCH}\.tar\.gz" \
  | sort -V | tail -1)
if [ -z "${TARBALL_NAME}" ]; then
  echo "ERROR: Could not find Alpine ${ARCH} minirootfs tarball."
  exit 1
fi

TARBALL_PATH="${WORK_DIR}/${TARBALL_NAME}"
echo "==> Downloading ${TARBALL_NAME}..."
wget -q -O "${TARBALL_PATH}" "${RELEASE_DIR}/${TARBALL_NAME}"

echo "==> Creating ${IMAGE_SIZE_MB}MB ext2 image..."
dd if=/dev/zero of="${OUTPUT_FILE}" bs=1M count="${IMAGE_SIZE_MB}"
mke2fs -t ext2 -L rootfs -q "${OUTPUT_FILE}"

echo "==> Mounting and extracting Alpine rootfs..."
mount -o loop "${OUTPUT_FILE}" "${MOUNT_DIR}"
tar xzf "${TARBALL_PATH}" -C "${MOUNT_DIR}"

mkdir -p \
  "${MOUNT_DIR}/proc" "${MOUNT_DIR}/sys" "${MOUNT_DIR}/dev" \
  "${MOUNT_DIR}/run" "${MOUNT_DIR}/etc" "${MOUNT_DIR}/tmp"

echo "==> Installing musl-dev (headers, libc, crt) for linking..."
apk -X "${MIRROR}/${ALPINE_VERSION}/main" \
    --root "${MOUNT_DIR}" \
    --arch "${ARCH}" \
    --keys-dir /etc/apk/keys \
    --no-cache --initdb --allow-untrusted \
    add musl-dev

# musl's static archive is ~28MB and TCC links against libc.so by
# default, so drop it to keep the image small. (Trade-off: `tcc -static`
# is not available in this image.)
echo "==> Dropping static libc.a to shrink the image..."
rm -f "${MOUNT_DIR}/usr/lib/libc.a"

echo "==> Installing TCC..."
cp -a /tccroot/usr/local "${MOUNT_DIR}/usr/"
ln -sf /usr/local/bin/tcc "${MOUNT_DIR}/usr/bin/tcc"
ln -sf /usr/local/bin/tcc "${MOUNT_DIR}/usr/bin/cc"

echo "==> Installing busybox init + inittab..."
# The kernel runs /sbin/init as PID 1 for a disk root (it ignores /init
# except for initramfs). Alpine's OpenRC init would bring up a getty
# login, so use busybox init instead: it spawns the shell *with a
# controlling terminal* on hvc0, which job control (and therefore Ctrl-C
# interruption of a runaway command) depends on. Exec'ing a shell
# directly as PID 1 would leave it without a tty and break that.
rm -f "${MOUNT_DIR}/sbin/init"
ln -sf /bin/busybox "${MOUNT_DIR}/sbin/init"

cat > "${MOUNT_DIR}/etc/inittab" << 'INITTAB_EOF'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sys /sys
::sysinit:/bin/mount -t devtmpfs dev /dev
::sysinit:/bin/hostname dartemu
hvc0::respawn:-/bin/sh
::shutdown:/bin/umount -a -r
INITTAB_EOF

# Login shell setup: the shell starts in / by default, but the sandbox
# (and the usual prompt) expect a root home of ~.
cat > "${MOUNT_DIR}/etc/profile" << 'PROFILE_EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100
cd "$HOME" 2>/dev/null || true
PROFILE_EOF

echo "==> Configuring networking and root account..."
echo "dartemu" > "${MOUNT_DIR}/etc/hostname"
cat > "${MOUNT_DIR}/etc/hosts" << 'HOSTS_EOF'
127.0.0.1	localhost dartemu
::1		localhost dartemu
HOSTS_EOF
cat > "${MOUNT_DIR}/etc/resolv.conf" << 'RESOLV_EOF'
nameserver 10.0.2.3
nameserver 8.8.8.8
RESOLV_EOF

if grep -q '^root:' "${MOUNT_DIR}/etc/passwd"; then
  sed -i 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "${MOUNT_DIR}/etc/passwd"
fi
sed -i 's|^root:.*|root::0:0:99999:7:::|' "${MOUNT_DIR}/etc/shadow" 2>/dev/null || true

mkdir -p "${MOUNT_DIR}/root"
cat > "${MOUNT_DIR}/root/.profile" << 'PROFILE_EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100
PROFILE_EOF

echo "==> Unmounting and checking filesystem..."
sync
umount "${MOUNT_DIR}"
e2fsck -y -f "${OUTPUT_FILE}" || true

echo "==> Shrinking image to used size + ${SLACK_MB}MB slack..."
BLOCK_SIZE=$(dumpe2fs -h "${OUTPUT_FILE}" 2>/dev/null \
  | awk '/^Block size:/{print $3}')
USED_BLOCKS=$(dumpe2fs -h "${OUTPUT_FILE}" 2>/dev/null \
  | awk '/^Block count:/{t=$3} /^Free blocks:/{f=$3} END{print t-f}')
SLACK_BLOCKS=$((SLACK_MB * 1024 * 1024 / BLOCK_SIZE))
TARGET_BLOCKS=$((USED_BLOCKS + SLACK_BLOCKS))

resize2fs "${OUTPUT_FILE}" "${TARGET_BLOCKS}"
e2fsck -y -f "${OUTPUT_FILE}" || true
truncate -s $((TARGET_BLOCKS * BLOCK_SIZE)) "${OUTPUT_FILE}"

FINAL_MB=$((TARGET_BLOCKS * BLOCK_SIZE / 1048576))
USED_MB=$((USED_BLOCKS * BLOCK_SIZE / 1048576))
echo
echo "==> Done! riscv64 TCC image"
echo "    Image: ${OUTPUT_FILE}"
echo "    Size:  ${FINAL_MB} MB (${USED_MB} MB used + ${SLACK_MB} MB free)"
echo
