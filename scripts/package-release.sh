#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/.dist"
APP_DIR="$DIST_DIR/Portpal.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="${VERSION:-0.1.0}"

cargo build --release --manifest-path "$ROOT_DIR/Cargo.toml"
swift build -c release --product PortpalMenuBar --package-path "$ROOT_DIR"

rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/packaging/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/release/PortpalMenuBar" "$MACOS_DIR/Portpal"
cp "$ROOT_DIR/target/release/portpal" "$DIST_DIR/portpal"

chmod +x "$MACOS_DIR/Portpal" "$DIST_DIR/portpal"

codesign --force --deep --sign - "$APP_DIR"

rm -f "$DIST_DIR/Portpal.app.zip" "$DIST_DIR/portpal-cli.tar.gz"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/Portpal.app.zip"
tar -C "$DIST_DIR" -czf "$DIST_DIR/portpal-cli.tar.gz" portpal

APP_SHA="$(shasum -a 256 "$DIST_DIR/Portpal.app.zip" | cut -d' ' -f1)"
CLI_SHA="$(shasum -a 256 "$DIST_DIR/portpal-cli.tar.gz" | cut -d' ' -f1)"

printf 'Created release artifacts in %s\n' "$DIST_DIR"
printf 'Version: %s\n' "$VERSION"
printf '  - %s\n' "$APP_DIR"
printf '  - %s\n' "$DIST_DIR/Portpal.app.zip"
printf '  - %s\n' "$DIST_DIR/portpal"
printf '  - %s\n' "$DIST_DIR/portpal-cli.tar.gz"
printf 'SHA256 Portpal.app.zip: %s\n' "$APP_SHA"
printf 'SHA256 portpal-cli.tar.gz: %s\n' "$CLI_SHA"
