#!/bin/bash
# Deploys the demo by hand. The flags match .github/workflows/deploy.yaml
# deliberately: without --wasm the build has no 64-bit register file, and
# every RV64 demo — AgentOS among them — disappears from the page.
set -e
cd "$(dirname "$0")/.."
flutter build web --wasm --release --pwa-strategy=none
firebase deploy --only hosting
