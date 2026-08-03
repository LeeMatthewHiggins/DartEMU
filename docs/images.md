# Building guest images

The emulator needs three things: firmware or a built-in SBI, a kernel, and a
root filesystem. Docker-based builders produce all of them.

- [Root filesystems](#root-filesystems)
- [Building a modern kernel](#building-a-modern-kernel)
- [Booting without firmware](#booting-without-firmware)
- [An AgentOS image](#an-agentos-image)
- [Prebuilt images](#prebuilt-images)

## Root filesystems

**RV64 with a C compiler (Alpine + TCC)** — the image bundled as
`example/assets/root-riscv64.bin`:

```sh
tool/image_builder/build_tcc.sh               # ~23 MB, includes cc (TCC)
```

TCC is a few hundred KB and links binaries itself, so the image stays small
enough to ship as a demo asset. The build cross-compiles a statically linked
riscv64 TCC and pairs it with `musl-dev` headers and crt objects, so
`cc hello.c -o hello` works in the guest. (`tcc -static` is unavailable —
musl's 28 MB `libc.a` is dropped to keep the image small.)

**RV64 (Alpine Linux):**

```sh
tool/image_builder/build.sh riscv64           # minimal, 256 MB
tool/image_builder/build.sh riscv64 dev       # + gcc, make, git, nano, 512 MB
```

**RV32 (Buildroot + musl):**

```sh
tool/image_builder/build_buildroot.sh         # minimal, 256 MB
tool/image_builder/build_buildroot.sh dev     # native gcc toolchain, 512 MB
```

The `dev` variants build a full native GCC (a Canadian cross for RV32),
which takes 15–30 minutes and produces a large image. TCC is RV64 only —
upstream TCC has no riscv32 backend.

Set `IMAGE_SIZE_MB` to change the filesystem size. The image is mostly empty
space, and it compresses away to nearly nothing, but it is still a file
someone has to check out.

## Building a modern kernel

The images above pair an older kernel with BBL, which supplies the
Supervisor Binary Interface (SBI) that Linux calls for timers, console
output and shutdown. The emulator can instead act as machine-mode firmware
itself, which lets a current kernel boot with no firmware blob to build,
ship or debug:

```sh
tool/image_builder/build_kernel.sh            # Linux 6.12 for riscv64
tool/image_builder/build_kernel.sh riscv32    # ... and for riscv32
```

This cross-compiles a kernel with everything the emulator presents built in
rather than modular — VirtIO MMIO, block, console and 9P, plus ext4 for the
ext2 root images — because nothing can be loaded as a module before the root
filesystem is mounted. The build refuses to finish if any of those ended up
modular. Override the version with `KERNEL_VERSION=6.12.41`.

The result is around 7 MB and reaches a shell in roughly three seconds. Each
architecture keeps its own tree under `tool/image_builder/.kernel-cache`, so
changing the config fragment costs an incremental rebuild rather than
another download and full compile.

**RV32 needs a matching userspace.** The `root-riscv32.bin` demo asset
predates upstream RISC-V support and is built against a 2017 glibc; RV32 was
upstreamed with a 64-bit-`time_t`-only syscall ABI, so that userspace cannot
run on any current RV32 kernel regardless of configuration. Pair the RV32
kernel with a Buildroot image instead:

```sh
tool/image_builder/build_kernel.sh riscv32
tool/image_builder/build_buildroot.sh
```

## Booting without firmware

Set `use_builtin_sbi`, and note there is no `bios:` line:

```yaml
version: 1
machine: riscv64
memory_size: 256
kernel: kernel/kernel-riscv64-6.12.bin
use_builtin_sbi: true
cmdline: "console=hvc0 earlycon=sbi root=/dev/vda rw init=/init loglevel=7"
drive0:
  file: rootfs/alpine-riscv64-rootfs.bin
```

Three constraints come with this path:

- A modern kernel has no HTIF console driver, so **`earlycon=sbi`** is what
  carries output before VirtIO probes. Without it an early failure is
  silent — the machine appears to hang with nothing to go on.
- **Prefer VirtIO for the interactive console.** A kernel built with
  `CONFIG_HVC_RISCV_SBI` and no VirtIO console does reach a usable shell,
  but its driver polls a byte per environment call: writing 128 KB into the
  guest took 31 s that way against 1.5 s over VirtIO. Enabling both is worse
  still, since the SBI driver claims `hvc0` first.
- **`use_builtin_sbi` must stay off whenever a `bios:` is present.** BBL and
  OpenSBI serve SBI calls from the trap path, so installing the emulator's
  would shadow the firmware.

The equivalent in library code is `MachineConfig(useBuiltinSbi: true)`. The
interface lives in [`lib/src/machine/sbi.dart`](../lib/src/machine/sbi.dart)
and covers SBI v2.0 Base, TIME, IPI, RFENCE, HSM, SRST and DBCN, plus the
v0.1 legacy console calls. It assumes a single hart, so remote fences and
inter-processor interrupts reduce to local operations.

One more thing firmware would otherwise have done: Linux never writes
`scounteren`, so a guest reading `rdtime` from user space traps unless the
emulator enables the counters at boot. It does.

## An AgentOS image

A variant whose console is an agent rather than a shell:

```sh
agentos/build_guest.sh                        # static riscv64 binary
tool/image_builder/build.sh riscv64 agentos
```

It is the minimal Alpine image plus the agent, an inittab entry that
respawns it in place of the getty, and an `/llms.txt` describing the machine
to whatever is driving it. See [Agents](agents.md#agentos--the-agent-inside).

## Prebuilt images

Kernels and the RV32 userspace are attached to each
[GitHub release](https://github.com/LeeMatthewHiggins/DartEMU/releases) as
gzipped assets with checksums — which is also where the `guest-e2e` CI job
fetches them. Building locally is only needed to change them.

Images can also be packaged as `.zip` bundles the Flutter app loads by
drag-and-drop or file picker. See [Bundles](configuration.md#bundles).
