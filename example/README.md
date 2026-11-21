# DartEMU example and live tutorial

The [live tutorial](https://leematthewhiggins.github.io/DartEMU/) runs five
shell experiments in an embedded Flutter terminal, ending with a Mandelbrot
renderer. Use the
[written tutorial](../docs/browser-tutorial.md) for commands, expected output,
keyboard controls and troubleshooting. The
[Firebase demo](https://dartemu-3ef91.web.app/?boot=32) also supports
[RV64 with a C compiler](https://dartemu-3ef91.web.app/?boot=64).

See [Embedding](../docs/embedding.md) to use the emulator in your own app.

## Run and preview

From this directory:

```sh
flutter pub get
flutter run
```

`flutter run` is for developing the Flutter terminal. To preview the complete
static tutorial and its embedded terminal, serve a release build:

```sh
flutter build web --wasm --release --pwa-strategy=none
python3 -m http.server 8000 --directory build/web
# Open http://localhost:8000/
```

`--wasm` enables RV64 and supplies a JavaScript fallback for browsers without
WasmGC. A JavaScript-only build supports RV32; RV64 options are unavailable.
Use HTTP hosting rather than opening the HTML files directly.

## Pages and URL parameters

| URL | Result |
| --- | --- |
| `/` | Tutorial, with an automatically booted RV32 terminal |
| `terminal.html` | Image picker |
| `terminal.html?boot=32` | New standalone RV32 machine |
| `terminal.html?boot=64` | RV64 on a WasmGC build; otherwise the picker |
| `terminal.html?bundle=vms/rv32-demo.zip` | Preload the included bundle; press Boot to start |
| `terminal.html?crt=full\|flat\|glass\|off` | Choose one CRT effect value |

Older root links containing `?boot=…`, `?bundle=…` or `?crt=…` redirect to
`terminal.html`, preserving the full query and fragment. Relative bundle
URLs still resolve beside the terminal page, so `vms/rv32-demo.zip` works
at both the domain root and `/DartEMU/`. Remote bundle URLs require CORS
permission from their host.

The tutorial embeds `terminal.html?boot=32&tutorial=1`. Its bridge is enabled
only in an iframe with `tutorial=1`. It accepts messages from its parent at
the same origin. It runs five fixed example IDs when the guest shell is idle;
messages cannot supply arbitrary shell text. Users can also type directly
in the terminal.

## What you can boot

| Option | Availability |
| --- | --- |
| RV32 Linux | Bundled small BusyBox image; all web builds |
| RV64 Linux | Bundled image with TCC (`cc`); native or WasmGC |
| AgentOS | In-guest agent; asks for a model and optional API key; WasmGC browser only |
| Mount a folder | RV64 with a 9P share; requires WasmGC and browser folder picker support |
| ZIP bundle | Drag and drop or file picker; matching guest architecture required |
| YAML config | Desktop only; resolves host file paths |

The small `web/vms/rv32-demo.zip` is tracked and deployed with the page.
Generated bundles under the repository's `data/` directory are not included
in a normal checkout. See [Bundles](../docs/configuration.md#bundles) for
the archive format and [Building images](../docs/images.md) for guest images.

The ordinary browser demos configure no external upstreams. They do not
provide general Internet access or package downloads. AgentOS uses a
configured HTTP proxy upstream, with its API key held in the page and
injected into outbound requests. The supplied image sends the placeholder
`${OPENROUTER_KEY}`. Leaving the key empty boots the guest but model requests
return a missing-credential error. See [Networking](../docs/networking.md).

## Structure and assets

| Path or component | Role |
| --- | --- |
| `web/index.html`, `web/tutorial/` | Static tutorial, lesson controls and layout |
| `web/terminal.html` | Flutter bootstrap for the terminal and image picker |
| `TutorialSession`, tutorial bridge | Fixed commands, shell readiness, parent/iframe messages |
| `EmulatorController` | Loads images and drives `Emulator` from a Flutter `Ticker` |
| `TerminalScreen` | Guest output, keystrokes and tutorial integration |
| `ConfigPickerScreen`, `ZipConfigLoader` | Demo selection and custom bundles |
| `AgentOsDemo`, `ApiKeyDialog` | Agent configuration, model and host-held credentials |

`assets/` contains BBL firmware, matching legacy Linux kernels, RV32/RV64
root filesystems, the AgentOS image and the bundled JetBrains Mono font.
Image licences and source links are in
[Third-party notices](../THIRD_PARTY_NOTICES.md).

For UI changes, follow [DESIGN.md](../DESIGN.md) and update the shared
[tokens.css](web/tutorial/tokens.css) before changing component styles.

## Deployment

### GitHub Pages

The [Pages workflow](../.github/workflows/pages.yaml) tests the tutorial
controls, builds a JavaScript release for RV32, and publishes from `main`.
Pull requests build without deploying. In repository **Settings → Pages →
Build and deployment**, select **GitHub Actions** as the source. Run
**GitHub Pages demo** manually or merge a relevant change to `main`.

The tutorial URL is
[GitHub Pages tutorial](https://leematthewhiggins.github.io/DartEMU/).
Forks use `https://<owner>.github.io/<repository>/`. No Firebase account or
extra deployment secrets are needed.

To check the repository subpath locally, from this directory:

```sh
flutter pub get
flutter build web --release --base-href /DartEMU/ --pwa-strategy=none
mkdir -p build/pages/DartEMU
cp -R build/web/. build/pages/DartEMU/
python3 -m http.server 8000 --directory build/pages
# Open http://localhost:8000/DartEMU/
# Standalone terminal: http://localhost:8000/DartEMU/terminal.html?boot=32
```

### Firebase Hosting

The [Firebase workflow](../.github/workflows/deploy.yaml) publishes a Wasm
release on relevant changes merged to `main`. It requires the repository
secret `FIREBASE_SERVICE_ACCOUNT_DARTEMU_3EF91`.

For a manual deployment from this directory, with the Firebase CLI installed
and authenticated:

```sh
tool/deploy.sh
```

The script uses the same build flags as CI. Both deployments disable the
service worker so returning visitors can receive updated builds.
