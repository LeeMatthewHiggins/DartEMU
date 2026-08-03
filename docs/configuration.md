# Configuration

A machine is described in YAML, or built directly as a `MachineConfig`.

- [A minimal config](#a-minimal-config)
- [Key reference](#key-reference)
- [How a config becomes a machine](#how-a-config-becomes-a-machine)
- [Bundles](#bundles)
- [The CLI](#the-cli)
- [In code](#in-code)

## A minimal config

```yaml
version: 1
machine: riscv64
memory_size: 256
bios: bbl64.bin
kernel: kernel-riscv64.bin
cmdline: "console=hvc0 root=/dev/vda rw"
drive0:
  file: rootfs/alpine-riscv64-rootfs.bin
eth0:
  driver: user
```

Relative paths resolve against the config file's own directory, not the
working directory.

## Key reference

### Machine

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | int | `1` | Config format. Anything else is refused. |
| `machine` | string | `riscv64` | `riscv64` or `riscv32`. |
| `memory_size` | int | 256 | Guest RAM in MB. |
| `cmdline` | string | — | Kernel command line. |
| `rtc_local_time` | bool | `false` | Guest clock follows local time rather than UTC. |
| `accel` | string | — | Acceleration hint, passed through. |

### Boot

| Key | Type | Meaning |
| --- | --- | --- |
| `bios` | path | Firmware — BBL or OpenSBI. Omit when using `use_builtin_sbi`. |
| `kernel` | path | Kernel image. |
| `initrd` | path | Initial ramdisk. |
| `use_builtin_sbi` | bool | The emulator answers SBI calls itself instead of firmware. |

`use_builtin_sbi` must stay **off** whenever a `bios:` is present — BBL and
OpenSBI serve SBI from the trap path, so installing the emulator's would
shadow the firmware. See [Building a modern
kernel](images.md#building-a-modern-kernel).

### Drives — `drive0` … `drive3`

| Key | Type | Meaning |
| --- | --- | --- |
| `file` | path | Disk image. Required, or the entry is ignored. |
| `device` | string | Device name hint, e.g. `vda`. |

### Shares — `fs0` … `fs3`

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `file` | path | — | Host directory to serve. Required. |
| `tag` | string | `fs<n>` | Mount tag the guest selects. |
| `readonly` | bool | `false` | Enforced by the server, not the guest. |

See [Filesystems and shares](filesystems.md).

### Network — `eth0`

| Key | Type | Meaning |
| --- | --- | --- |
| `driver` | string | `user` for the built-in user-mode stack. |
| `ifname` | string | Interface name, where a backend uses one. |

See [Networking](networking.md).

## How a config becomes a machine

In two steps, deliberately, because only the second knows where bytes live:

```
YAML ──ConfigDocument.parse──▶ ConfigDocument ──resolve──▶ MachineConfig
                               (what it says,              (open devices,
                                paths untouched)            loaded images)
```

`ConfigDocument` is platform-neutral and holds paths exactly as written.
What they are relative to is the resolver's business, and the resolvers
disagree about it:

- **`ConfigLoader` / `ConfigResolver`** (`dart_emu_io.dart`) resolve against
  the filesystem — the only part that needs `dart:io`, and so the only part
  a browser cannot use.
- **`ZipConfigLoader`** (in the example app) resolves against entries in an
  archive.

Splitting them is why both understand the same keys. When each parsed for
itself they drifted, and bundles silently lost every key only one of them
knew.

## Bundles

A `.zip` containing a YAML config and everything it names. This is the only
way to carry a whole machine into a browser, where there is no filesystem to
resolve paths against.

```
my-vm.zip
├── config.yaml
├── bbl64.bin
├── kernel-riscv64.bin
├── rootfs.bin
└── work/            ← an fs0: file: work share
    └── notes.txt
```

The archive must hold exactly one `.yaml` or `.yml` file; paths resolve
against that file's directory inside the archive. A share becomes an
in-memory tree seeded from the entries beneath it — writes last as long as
the machine and go with it.

Anything the config names but the archive lacks is an error, not a silent
omission.

The Flutter example loads a bundle by drag-and-drop, file picker, or a
`?bundle=<url>` query parameter that preloads it so only Boot remains.

## The CLI

```sh
dart pub global activate dart_emu

dart_emu run --config data/alpine_vm.yaml
dart_emu run --bios bbl64.bin --kernel kernel-riscv64.bin --drive rootfs.bin \
             --cmdline "console=hvc0 root=/dev/vda rw"
```

From a checkout, `dart run bin/dart_emu.dart run --config …` does the same.

## In code

Skip YAML entirely and build the config:

```dart
final config = MachineConfig(
  xlen: Xlen.rv64,
  memorySizeMb: 256,
  biosData: biosBytes,
  kernelData: kernelBytes,
  cmdLine: 'console=hvc0 root=/dev/vda rw',
  blockDevices: [MemoryBlockDevice.fromData(rootfsBytes)],
  ethDevices: [UserNetDevice()],
  sharedFolders: [
    NinePShare(tag: 'work', backend: myBackend),
  ],
);
```

`MachineConfig` accepts images either as paths (`biosPath`, `kernelPath`,
`initrdPath`) or as bytes (`biosData`, `kernelData`, `initrdData`). Paths
need a resolver and therefore `dart:io`; bytes work anywhere. `copyWith`
returns a modified copy, which is how the resolvers turn one into the other.
