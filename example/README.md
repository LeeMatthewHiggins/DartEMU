# DartEMU Flutter Example

A Flutter application that boots RISC-V Linux using the `dart_emu` package.
Runs on all Flutter platforms including web.

## Running

```sh
flutter run
```

For web:

```sh
flutter build web --release
```

To skip the config picker and boot directly on web, add `?boot=32` or
`?boot=64` to the URL.

## Loading VM Images

The app supports three ways to boot:

- **Built-in demo** — Bundled RV32/RV64 boot images from `assets/`
- **ZIP bundles** — Self-contained archives with YAML config, BIOS, kernel,
  and rootfs (works on all platforms including web)
- **YAML config files** — Direct file paths (desktop only)

Pre-built ZIP bundles are available in the `data/` directory of the main
package.

## Deployment

Deployed to Firebase Hosting. To deploy manually:

```sh
tool/deploy.sh
```

Auto-deploys on merge to `main` via GitHub Actions (requires
`FIREBASE_SERVICE_ACCOUNT` secret).

## Boot Images

The bundled demo loads from `assets/`:

- `bbl32.bin` / `bbl64.bin` — OpenSBI firmware
- `kernel-riscv32.bin` / `kernel-riscv64.bin` — Linux kernel
- `root-riscv32.bin` / `root-riscv64.bin` — Root filesystem (ext2)

## Architecture

- `EmulatorController` — Loads assets, creates `MachineConfig`, and manages
  the `Emulator` lifecycle using a `Ticker` for frame-driven execution
- `TerminalScreen` — Displays emulator output in a terminal widget and
  forwards keyboard input to the guest OS
- `ConfigPickerScreen` — Landing screen with drag-and-drop, file picker, and
  demo boot buttons
- `ZipConfigLoader` — Platform-independent ZIP bundle parser
