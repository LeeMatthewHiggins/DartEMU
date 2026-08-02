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

## URL Parameters

On web, the demo reads query parameters:

| Parameter | Effect |
| --- | --- |
| `?boot=32` / `?boot=64` | Skip the picker and boot the bundled demo |
| `?bundle=<url>` | Download a `.zip` VM bundle and preload it — the picker opens with the config parsed and only Boot left to press |
| `?crt=full\|flat\|glass\|off` | Set the CRT effect |

Relative bundle URLs resolve against the page's own address, so a bundle
deployed next to the app (`?bundle=vms/alpine.zip`) always works. A
cross-origin URL needs CORS headers from its host.

## Terminal Shortcuts

`Ctrl+A` and `Ctrl+V` go to the guest shell (start-of-line and
literal-next), not the terminal UI, so readline behaves the way it does in
a native terminal. Copy and paste use bindings no browser claims:

| Action | Keys |
| --- | --- |
| Copy selection | `Ctrl+Insert` (also `Ctrl+Shift+C`, best effort — Chromium may open DevTools) |
| Paste | `Shift+Insert` (also `Ctrl+Shift+V`) |
| Copy / Paste / Select all | Right-click menu |

On macOS the standard `Cmd+C` / `Cmd+V` / `Cmd+A` work as usual — meta
chords never collide with guest control keys. The right-click menu is the
keyboard-free path and behaves identically in every browser.

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
