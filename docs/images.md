# Building guest images

Linux guests need firmware or the built-in SBI, a matching kernel, and a
root filesystem. The repository includes legacy Linux demo images in
`example/assets/`; use the [README quick start](../README.md#try-it) to run
them without building anything. The Docker-based builders below produce
additional images in `data/`. FreeRTOS guests use only a firmware image.

- [Root filesystems](#root-filesystems)
- [Building a modern kernel](#building-a-modern-kernel)
- [Booting without firmware](#booting-without-firmware)
- [A FreeRTOS image](#a-freertos-image)
- [An AgentOS image](#an-agentos-image)
- [Prebuilt images](#prebuilt-images)

## Root filesystems

**RV64 with a C compiler (Alpine + TCC)** — the image bundled as
`example/assets/root-riscv64.bin`:

```sh
tool/image_builder/build_tcc.sh               # includes cc (TCC)
```

The output is `data/rootfs/alpine-riscv64-tcc-rootfs.bin`; the builder does
not overwrite `example/assets/root-riscv64.bin` automatically.

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

Outputs are written under `data/kernel/`, for example
`kernel-riscv64-6.12.bin`. Size and boot time depend on the architecture,
configuration and host. Each
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

Set `use_builtin_sbi`, and omit `bios:`. Save this example in `data/` after
building the kernel and Alpine rootfs:

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

Load it through the library or a browser bundle. The current CLI does not
forward `use_builtin_sbi` from YAML; use this library path for native runs:

```dart
import 'dart:io';
import 'package:dart_emu/dart_emu_io.dart';

Future<void> main() async {
  final config = ConfigResolver.resolve(
    ConfigLoader.loadFromFile('data/modern_vm.yaml'),
  );
  final emulator = Emulator(config);
  final output = emulator.output.listen(stdout.add);
  final input = stdin.listen(emulator.sendInput);
  try {
    await emulator.start();
  } finally {
    await input.cancel();
    await output.cancel();
    await emulator.dispose();
  }
}
```

This minimal example uses line-buffered host input. Run it from a Dart file
in the checkout; press Enter to send a line to the guest. `data/modern_vm.yaml`
requires its named kernel and rootfs to exist, and its disk is writable.

For in-memory images, set `MachineConfig(useBuiltinSbi: true, kernelData: …)`.
The interface lives in [`lib/src/machine/sbi.dart`](../lib/src/machine/sbi.dart)
and covers SBI v2.0 Base, TIME, IPI, RFENCE, HSM, SRST and DBCN, plus the
v0.1 legacy console calls. It assumes a single hart, so remote fences and
inter-processor interrupts reduce to local operations.

One more thing firmware would otherwise have done: Linux never writes
`scounteren`, so a guest reading `rdtime` from user space traps unless the
emulator enables the counters at boot. It does.

## A FreeRTOS image

The emulator is not limited to Linux. A bare-metal RTOS image runs as
machine-mode firmware via the `bios:` key — no BBL, no rootfs, no VirtIO —
which makes the emulator a stand-in for embedded targets:

```sh
tool/image_builder/freertos/build_freertos.sh # every app under apps/
dart run bin/dart_emu.dart run --config data/freertos_hello_vm.yaml
dart run bin/dart_emu.dart run --config data/freertos_vm.yaml
```

No Docker is needed: the FreeRTOS kernel plus an app is a dozen C files,
and any LLVM with the RISC-V backend cross-compiles them — `zig` (which
bundles clang, lld and objcopy) or a Homebrew `llvm` with `lld` alongside.

The stock FreeRTOS RISC-V port runs unmodified because the machine already
looks like the hardware the port expects: the CLINT sits at the
SiFive-standard addresses (`mtime` at `0x200BFF8`, `mtimecmp` at
`0x2004000`), the boot path jumps to the start of RAM at `0x80000000`, and
the HTIF console makes `putchar` two stores. The pieces an embedded project
would normally get from a vendor BSP live in
[`tool/image_builder/freertos/common`](../tool/image_builder/freertos/common):
a startup stub that installs `freertos_risc_v_trap_handler` in `mtvec` (the
port leaves that to startup code), `FreeRTOSConfig.h` wired to the CLINT
addresses and the 10 MHz RTC, a linker script, and an HTIF console driver.

Apps are one `main.c` each under
[`tool/image_builder/freertos/apps`](../tool/image_builder/freertos/apps),
and every one ends with an HTIF poweroff, so a scripted run exits cleanly.
Two are provided:

- **hello** (~5 KB, `data/freertos-hello-riscv64.bin`) — one task prints a
  greeting and powers off. The smallest proof that boot, the trap handler,
  the scheduler and the console all work, and the template to copy for a
  new app.
- **sensor** (~12 KB, `data/freertos-riscv64.bin`) — an embedded-style
  firmware: a sensor task feeds a queue that a logger task drains to the
  console under a mutex, then prints a summary:

```
FreeRTOS V11.2.0 on DartEMU riscv64
[logger] t=100ms temp=23.0C
...
[logger] done: 25 samples, min=17.6C max=25.3C avg=21.9C
```

Both images are exercised end to end by
[`test/machine/freertos_boot_test.dart`](../test/machine/freertos_boot_test.dart),
which boots the committed binaries and runs them to their poweroff:

```sh
dart test --run-skipped -t machine test/machine/freertos_boot_test.dart
```

One caveat: `mtime` follows the host wall clock, and an interpreted CPU
does not, so tick-relative delays stretch when the guest falls behind.
Logical ordering and tick counts stay exact, which is what the scheduler
and the demo depend on.

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

The `guest-e2e` CI job fetches Linux 6.12 kernels and a modern RV32 userspace
from [release v0.6.0](https://github.com/LeeMatthewHiggins/DartEMU/releases/tag/v0.6.0).
They are not part of a normal checkout. To run those tests locally, download
and decompress these release assets:

| Release asset | Local path |
| --- | --- |
| `kernel-riscv64-6.12.bin.gz` | `data/kernel/kernel-riscv64-6.12.bin` |
| `kernel-riscv32-6.12.bin.gz` | `data/kernel/kernel-riscv32-6.12.bin` |
| `alpine-riscv32-rootfs.bin.gz` | `data/rootfs/alpine-riscv32-rootfs.bin` |

Use the checksums in [the CI workflow](../.github/workflows/dart_emu.yaml)
to verify the decompressed files. The RV32 userspace filename retains the
`alpine` prefix, but the modern RV32 builder uses Buildroot and musl.
Bundled BBL kernels and roots in `example/assets/` remain separate demo
images; do not mix the legacy RV32 rootfs with a modern kernel.

Images can also be packaged as `.zip` bundles the Flutter app loads by
drag-and-drop or file picker. See [Bundles](configuration.md#bundles).
