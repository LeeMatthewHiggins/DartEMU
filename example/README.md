# DartEMU Flutter example

A Flutter application that boots RISC-V Linux with the `dart_emu` package.
Runs on every Flutter platform, including web.

Try the [live RV32 Linux demo](https://dartemu-3ef91.web.app/?boot=32)
or open the [image picker](https://dartemu-3ef91.web.app/).

For how to embed the emulator in your own app, see
[Embedding](../docs/embedding.md).

## Running

```sh
flutter run

flutter build web --wasm --release      # for the web
```

**`--wasm` is not optional if you want RV64.** Without it the build has no
64-bit register file, and every RV64 demo — AgentOS included — disappears
from the picker. The flag ships a JavaScript fallback automatically, so
browsers without WasmGC still get RV32.

## What you can boot

| | |
| --- | --- |
| **RISC-V 32-bit** | Bundled demo image, works on any web backend |
| **AgentOS** | A machine whose console is an agent, not a shell. Asks for an API key and a model first. RV64, so WasmGC only |
| **Mount a folder** | Pick a host directory and boot RV64 with it shared over 9P |
| **A `.zip` bundle** | Drag and drop, or browse. Carries its own config, kernel and rootfs |
| **A `.yaml` config** | Desktop only — needs real file paths |

Pre-built bundles live in the main package's `data/` directory. See
[Bundles](../docs/configuration.md#bundles) for the layout.

## URL parameters

| Parameter | Effect |
| --- | --- |
| `?boot=32` / `?boot=64` | Skip the picker and boot the bundled demo |
| `?bundle=<url>` | Download a `.zip` bundle and preload it — the picker opens with the config parsed and only Boot left to press |
| `?crt=full\|flat\|glass\|off` | Set the CRT effect |

Relative bundle URLs resolve against the page's own address, so a bundle
deployed next to the app (`?bundle=vms/alpine.zip`) always works. A
cross-origin URL needs CORS headers from its host.

## AgentOS and the key

The AgentOS card asks for an OpenRouter key and a model before booting. The
key stays in the browser tab: it is attached to requests on their way out
and never written into the machine, which only ever sees the placeholder
`${OPENROUTER_KEY}`.

Booting with the field empty is a first-class choice — the machine runs,
asks, and is told which credential it is missing. That is the clearest
demonstration that it never had one.

The model matters because an OpenRouter account's data policy decides which
providers it may reach; if one model is refused, another may not be. See
[Networking](../docs/networking.md) for what the guest can and cannot reach.

## Terminal shortcuts

`Ctrl+A` and `Ctrl+V` go to the guest shell (start-of-line and
literal-next), not the terminal UI, so readline behaves the way it does in a
native terminal. Copy and paste use bindings no browser claims:

| Action | Keys |
| --- | --- |
| Copy selection | `Ctrl+Insert` (also `Ctrl+Shift+C`, best effort — Chromium may open DevTools) |
| Paste | `Shift+Insert` (also `Ctrl+Shift+V`) |
| Copy / Paste / Select all | Right-click menu |

On macOS the standard `Cmd+C` / `Cmd+V` / `Cmd+A` work as usual — meta
chords never collide with guest control keys. The right-click menu is the
keyboard-free path and behaves identically in every browser.

## Assets

```
assets/bbl32.bin, bbl64.bin              BBL (Berkeley Boot Loader) firmware
assets/kernel-riscv32.bin, …64.bin       Linux kernels
assets/root-riscv32.bin, …64.bin         Root filesystems (ext2)
assets/agentos-riscv64.bin               AgentOS image
assets/fonts/JetBrainsMonoNL-*.ttf       Terminal font
```

The font is bundled rather than named: the web build resolves only fonts
declared in `pubspec.yaml`, so asking for a system font silently falls back
to a proportional face and the terminal grid spaces every glyph to a cell it
does not fill.

## Structure

| | |
| --- | --- |
| `EmulatorController` | Loads assets, builds a `MachineConfig`, drives the `Emulator` from a `Ticker` |
| `TerminalScreen` | Renders guest output and forwards keystrokes |
| `ConfigPickerScreen` | Landing screen: drop zone, file picker, demo cards |
| `ZipConfigLoader` | Resolves a bundle's config against archive entries |
| `AgentOsDemo` | Upstreams, credentials and command line for the agent image |
| `ApiKeyDialog` | Asks for a key and model, and rejects a key a browser cannot send |

## Deployment

### GitHub Pages

The [Pages workflow](../.github/workflows/pages.yaml) builds the existing
Flutter app and publishes it as a static site. It uses the JavaScript build
for the RV32 demo, with the correct base path for a repository site.

1. In the repository's **Settings → Pages → Build and deployment**, choose
   **GitHub Actions** as the source.
2. Merge the workflow into `main`, or run **GitHub Pages demo**
   from the **Actions** tab after it has been merged.
3. Open the URL in the successful deployment and add `?boot=32` to boot
   directly into Linux.

For this repository the default URL is
[leematthewhiggins.github.io/DartEMU/](https://leematthewhiggins.github.io/DartEMU/?boot=32).
It becomes available after the first successful deployment. Forks use
`https://<owner>.github.io/<repository>/?boot=32`. No Firebase account or
additional deployment secrets are required.

Pull requests build the site without publishing it. Changes to the emulator,
example app, dependencies or workflow publish automatically after merging to
`main`. RV64 demos remain available on the Wasm build hosted on Firebase.

To build and check the Pages layout locally:

```sh
cd example
flutter pub get
flutter build web --release --base-href /DartEMU/ --pwa-strategy=none
mkdir -p build/pages/DartEMU
cp -R build/web/. build/pages/DartEMU/
python3 -m http.server 8000 --directory build/pages
# Open http://localhost:8000/DartEMU/?boot=32
```

The guest runs in the browser tab; refreshing discards its changes. The
bundled RV32 demo has no external network access configured. Guest image
licences and source links are in [Third-party notices](../THIRD_PARTY_NOTICES.md).

### Firebase Hosting

```sh
tool/deploy.sh
```

Auto-deploys on merge to `main` via GitHub Actions (needs the
`FIREBASE_SERVICE_ACCOUNT` secret). The manual script uses the same flags as
CI on purpose.
