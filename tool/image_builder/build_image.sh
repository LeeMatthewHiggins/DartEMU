#!/bin/sh
set -e

ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
IMAGE_VARIANT="${IMAGE_VARIANT:-minimal}"
ARCH="${ARCH:-riscv64}"
OUTPUT_DIR="/output"
WORK_DIR="/tmp/image-build"
MOUNT_DIR="${WORK_DIR}/rootfs"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"

case "${ARCH}" in
  riscv64|riscv32) ;;
  *) echo "ERROR: Unsupported architecture: ${ARCH}" && exit 1 ;;
esac

case "${IMAGE_VARIANT}" in
  dev)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-512}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-${ARCH}-dev-rootfs.bin"
    ;;
  agentos)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-256}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-${ARCH}-agentos-rootfs.bin"
    if [ ! -f /input/agentos ]; then
      echo "ERROR: the agent binary was not provided at /input/agentos."
      echo "       Build it first with agentos/build_guest.sh."
      exit 1
    fi
    ;;
  *)
    IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-256}"
    OUTPUT_FILE="${OUTPUT_DIR}/alpine-${ARCH}-rootfs.bin"
    ;;
esac

mkdir -p "${WORK_DIR}" "${MOUNT_DIR}" "${OUTPUT_DIR}"

echo "==> Building ${IMAGE_VARIANT} image for ${ARCH} (${IMAGE_SIZE_MB}MB)..."
echo "==> Resolving Alpine ${ARCH} minirootfs URL..."

RELEASE_DIR="${MIRROR}/${ALPINE_VERSION}/releases/${ARCH}"
TARBALL_NAME=$(wget -qO- "${RELEASE_DIR}/" \
  | grep -oE "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-${ARCH}\.tar\.gz" \
  | sort -V \
  | tail -1)

if [ -z "${TARBALL_NAME}" ]; then
  echo "ERROR: Could not find Alpine ${ARCH} minirootfs tarball at ${RELEASE_DIR}/"
  echo "       Alpine may not provide official ${ARCH} releases."
  echo "       For riscv32, consider using the Buildroot-based builder instead:"
  echo "         tool/image_builder/build_buildroot.sh [minimal|dev]"
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
  echo "==> Installing dev packages (${ARCH})..."
  apk -X "${MIRROR}/${ALPINE_VERSION}/main" \
      -X "${MIRROR}/${ALPINE_VERSION}/community" \
      --root "${MOUNT_DIR}" \
      --arch "${ARCH}" \
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

if [ "${IMAGE_VARIANT}" = "agentos" ]; then
  echo "==> Installing the agent (${ARCH})..."
  mkdir -p "${MOUNT_DIR}/usr/local/bin" "${MOUNT_DIR}/workspace"
  cp /input/agentos "${MOUNT_DIR}/usr/local/bin/agentos"
  chmod +x "${MOUNT_DIR}/usr/local/bin/agentos"

  # The console runs the agent and nothing else. init respawns this, so the
  # agent restarting can never fall through to a shell.
  cat > "${MOUNT_DIR}/usr/local/bin/agentos-console" << 'CONSOLE_EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100
cd /workspace
exec /usr/local/bin/agentos
CONSOLE_EOF
  chmod +x "${MOUNT_DIR}/usr/local/bin/agentos-console"

  echo "==> Writing /llms.txt..."
  cat > "${MOUNT_DIR}/llms.txt" << 'LLMS_EOF'
# AgentOS

> A disposable emulated RISC-V Linux machine you have complete control of.
> These notes say what is here and what it costs, so you can spend your
> commands well.

## The machine

- Alpine Linux on an emulated RISC-V CPU. Busybox provides most commands.
- You are root. Install, change or destroy anything. The machine is thrown
  away when the session ends and nothing here reaches the host.
- Work in /workspace. It is empty and yours.
- No Python. Use the shell, awk, sed and busybox.

## What is expensive

- The CPU is emulated, so it is perhaps a hundred times slower than the one
  running it. Compiling anything large is not worth the wait.
- Every byte of output crosses a serial console and is truncated past the
  limit in your instructions. `du -sh`, `find -maxdepth 1`, `wc -l` and
  `| head` are cheap; printing a whole tree is not.
- `apk add` needs the network, which is restricted. Assume it will fail
  unless the package host is one of the allowed destinations.

## The network

- This machine reaches nothing directly. Its only route out is the host,
  which allows a fixed list of destinations and refuses everything else.
- The host holds every credential. Requests from here carry a placeholder
  naming the key, and the host substitutes the real value. There is no
  secret on this machine to find.
- A refused request comes back as JSON with the reason in it. Read it and
  report it; there is no way around it from in here.

## Files worth knowing

- /workspace — your working directory.
- /llms.txt — this file.
- /etc/agentos/shares.md — present only when a host folder is shared in.
LLMS_EOF
fi

echo "==> Writing /init..."
cat > "${MOUNT_DIR}/init" << INIT_EOF
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null || true

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=vt100

hostname dartemu

echo
echo "  Alpine Linux (${ARCH}) on dartEMU"
echo

if [ -x /sbin/init ]; then
  exec /sbin/init
fi

exec /bin/sh
INIT_EOF
chmod +x "${MOUNT_DIR}/init"

echo "==> Writing /etc/inittab..."
if [ "${IMAGE_VARIANT}" = "agentos" ]; then
  # The console is the agent. There is no getty, so talking to this machine
  # means talking to the agent; there is no shell to drop into.
  CONSOLE_LINE="hvc0::respawn:/usr/local/bin/agentos-console"
else
  CONSOLE_LINE="hvc0::respawn:/sbin/getty -L 115200 hvc0 vt100"
fi

cat > "${MOUNT_DIR}/etc/inittab" << INITTAB_EOF
::sysinit:/bin/hostname dartemu
::sysinit:/bin/sh -c 'ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null && route add default gw 10.0.2.2 2>/dev/null'
${CONSOLE_LINE}
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
nameserver 10.0.2.3
nameserver 8.8.8.8
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
echo "==> Done! (${ARCH} ${IMAGE_VARIANT})"
echo "    Image: ${OUTPUT_FILE}"
echo "    Size:  ${IMAGE_MB}MB"
echo "    Alpine: ${TARBALL_NAME}"
echo
