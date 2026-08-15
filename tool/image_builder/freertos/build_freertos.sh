#!/bin/bash
set -euo pipefail

# Builds FreeRTOS images for the emulator. Unlike the Linux builders this
# needs no Docker: the kernel plus an app is a dozen C files, and any
# LLVM with the RISC-V backend can cross-compile them. zig is preferred
# because it bundles clang, lld and objcopy in one binary; a Homebrew llvm
# with lld installed alongside works too. The results boot as machine-mode
# firmware via the `bios:` config key — no Linux, no BBL, no rootfs.
#
# Usage: build_freertos.sh [app...]
#   Apps live in apps/<name>/; with no argument every app is built.
#   The sensor demo becomes freertos-riscv64.bin, every other app
#   freertos-<name>-riscv64.bin.
#
#   FREERTOS_VERSION=V11.2.0   kernel tag to build (default V11.2.0)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$(cd "${SCRIPT_DIR}/../../../data" && pwd)"
CACHE_DIR="${FREERTOS_CACHE_DIR:-${SCRIPT_DIR}/../.freertos-cache}"
COMMON_DIR="${SCRIPT_DIR}/common"
APPS_DIR="${SCRIPT_DIR}/apps"

FREERTOS_VERSION="${FREERTOS_VERSION:-V11.2.0}"
KERNEL_DIR="${CACHE_DIR}/FreeRTOS-Kernel"
PORT_DIR="${KERNEL_DIR}/portable/GCC/RISC-V"

if [ "$#" -gt 0 ]; then
  APPS=("$@")
else
  APPS=()
  for dir in "${APPS_DIR}"/*/; do
    APPS+=("$(basename "${dir}")")
  done
fi

for app in "${APPS[@]}"; do
  if [ ! -f "${APPS_DIR}/${app}/main.c" ]; then
    echo "error: unknown app '${app}' (no ${APPS_DIR}/${app}/main.c)" >&2
    exit 1
  fi
done

if command -v zig >/dev/null; then
  CC=(zig cc)
  OBJCOPY=(zig objcopy)
  TARGET_FLAGS=(
    --target=riscv64-freestanding-none
    -mcpu=generic_rv64+m+a+c+zicsr
  )
else
  LLVM_PREFIX="$(brew --prefix llvm@19 2>/dev/null || brew --prefix llvm 2>/dev/null || true)"
  if [ -z "${LLVM_PREFIX}" ] || [ ! -x "${LLVM_PREFIX}/bin/clang" ]; then
    echo "error: need zig, or Homebrew llvm and lld (brew install zig)" >&2
    exit 1
  fi
  LLD_PREFIX="$(brew --prefix lld 2>/dev/null || true)"
  if [ ! -x "${LLD_PREFIX}/bin/ld.lld" ]; then
    echo "error: Homebrew llvm needs lld for bare-metal links (brew install lld)" >&2
    exit 1
  fi
  CC=("${LLVM_PREFIX}/bin/clang" -B "${LLD_PREFIX}/bin" -fuse-ld=lld)
  OBJCOPY=("${LLVM_PREFIX}/bin/llvm-objcopy")
  TARGET_FLAGS=(
    --target=riscv64-unknown-elf
    -march=rv64imac_zicsr
  )
fi

if [ ! -d "${KERNEL_DIR}" ]; then
  echo "Fetching FreeRTOS-Kernel ${FREERTOS_VERSION}..."
  mkdir -p "${CACHE_DIR}"
  git clone --depth 1 --branch "${FREERTOS_VERSION}" \
    https://github.com/FreeRTOS/FreeRTOS-Kernel.git "${KERNEL_DIR}"
fi

CFLAGS=(
  "${TARGET_FLAGS[@]}"
  -mabi=lp64
  -mcmodel=medany
  -ffreestanding
  -fno-builtin
  -ffunction-sections
  -fdata-sections
  -O2
  -Wall
  -I "${COMMON_DIR}"
  -isystem "${COMMON_DIR}/shim_include"
  -I "${KERNEL_DIR}/include"
  -I "${PORT_DIR}"
  -I "${PORT_DIR}/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions"
)

COMMON_SOURCES=(
  "${KERNEL_DIR}/tasks.c"
  "${KERNEL_DIR}/list.c"
  "${KERNEL_DIR}/queue.c"
  "${KERNEL_DIR}/portable/MemMang/heap_4.c"
  "${PORT_DIR}/port.c"
  "${PORT_DIR}/portASM.S"
  "${COMMON_DIR}/start.S"
  "${COMMON_DIR}/htif.c"
  "${COMMON_DIR}/hooks.c"
  "${COMMON_DIR}/libc_shim.c"
)

build_app() {
  local app="$1"
  local build_dir="${CACHE_DIR}/build-riscv64-${app}"
  local output
  case "${app}" in
    sensor) output="${DATA_DIR}/freertos-riscv64.bin" ;;
    *) output="${DATA_DIR}/freertos-${app}-riscv64.bin" ;;
  esac

  echo "Compiling FreeRTOS ${FREERTOS_VERSION} app '${app}' for riscv64..."
  mkdir -p "${build_dir}"

  local objects=()
  local src obj
  for src in "${COMMON_SOURCES[@]}" "${APPS_DIR}/${app}/main.c"; do
    obj="${build_dir}/$(basename "${src}").o"
    "${CC[@]}" "${CFLAGS[@]}" -c "${src}" -o "${obj}"
    objects+=("${obj}")
  done

  "${CC[@]}" "${CFLAGS[@]}" -nostdlib \
    -T "${COMMON_DIR}/link.ld" -Wl,--gc-sections \
    "${objects[@]}" -o "${build_dir}/freertos.elf"

  "${OBJCOPY[@]}" -O binary "${build_dir}/freertos.elf" "${output}"

  echo "Built $(du -h "${output}" | cut -f1 | tr -d ' ') ${output}"
}

for app in "${APPS[@]}"; do
  build_app "${app}"
done

echo "Run one with: dart run bin/dart_emu.dart run --config data/freertos_vm.yaml"
