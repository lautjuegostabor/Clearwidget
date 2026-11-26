#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.clearsign-build"
UP="$DEST/upstream"
PIN=56165783f31d3e441ae9f76df42c3cc55e239777
mkdir -p "$DEST"
python3 "$ROOT/Tools/verify_vendor.py" "$ROOT/Vendor"
rm -rf "$UP"
mkdir -p "$UP"
cp -R "$ROOT/Vendor/BariStore/." "$UP/"
python3 "$ROOT/Signing/patch_renewal_vendor.py" "$UP"
python3 "$ROOT/Signing/patch_bootstrap_vendor.py" "$UP"
# Build a static library, not the Open Minis executable or UI. Only the listed
# modules are reachable. Preserve original MIT attribution.
cp "$ROOT/Signing/lib.rs" "$UP/src/lib.rs"
cp "$ROOT/Signing/setup.rs" "$UP/src/setup.rs"
cp "$ROOT/Signing/bootstrap.rs" "$UP/src/bootstrap.rs"
printf '\n[features]\nclear-bootstrap = []\n' >> "$UP/Cargo.toml"
printf '\n' >> "$UP/src/apple/gsa.rs"
cat "$ROOT/Signing/login_once.rs" >> "$UP/src/apple/gsa.rs"
printf '\n[lib]\nname = "clearsign"\npath = "src/lib.rs"\ncrate-type = ["staticlib"]\n' >> "$UP/Cargo.toml"
printf 'pub mod rppairing;\npub mod services;\npub mod session;\npub mod tcp;\npub mod tls_psk;\npub mod xpc;\n' > "$UP/src/device/mod.rs"
printf 'pub mod record;\npub mod tlv8;\npub mod opack;\npub mod host;\n' > "$UP/src/pairing/mod.rs"
mkdir -p "$ROOT/Signing/Native" "$ROOT/App/Resources"
cp "$UP/LICENSE" "$ROOT/App/Resources/BariStore-LICENSE.txt"
cp "$UP/THIRD_PARTY_NOTICES.md" "$ROOT/App/Resources/BariStore-THIRD-PARTY-NOTICES.txt"
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=27.0
cd "$UP"
cargo test --locked --lib --features clear-bootstrap bootstrap::tests
cargo build --locked --release --lib --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libclearsign.a "$ROOT/Signing/Native/libclearsign.a"
test -s "$ROOT/Signing/Native/libclearsign.a"
