#!/bin/bash
set -e
cd "$(dirname "$0")/.."
flutter build web --release
firebase deploy --only hosting
