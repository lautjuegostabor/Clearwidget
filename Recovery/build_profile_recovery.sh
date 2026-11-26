#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.clearrecovery-build"
UP="$DEST/upstream"
mkdir -p "$DEST"
python3 "$ROOT/Tools/verify_vendor.py" "$ROOT/Vendor"
rm -rf "$UP"; mkdir -p "$UP"
cp -R "$ROOT/Vendor/BariStore/." "$UP/"
python3 "$ROOT/Signing/patch_renewal_vendor.py" "$UP"
cp "$ROOT/Signing/lib.rs" "$UP/src/lib.rs"
printf '\n[features]\nclear-bootstrap = []\n' >> "$UP/Cargo.toml"
python3 - "$UP/src/lib.rs" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text();s=s.replace('mod setup;\n','')
p.write_text(s)
PY
printf 'pub mod rppairing;\npub mod services;\npub mod session;\npub mod tcp;\npub mod tls_psk;\npub mod xpc;\n' > "$UP/src/device/mod.rs"
printf 'pub mod record;\npub mod tlv8;\npub mod opack;\n' > "$UP/src/pairing/mod.rs"
mkdir -p "$UP/src/bin"
cp "$ROOT/Recovery/clearrecovery.rs" "$UP/src/bin/clearrecovery.rs"
printf '\n[lib]\nname = "clearsign"\npath = "src/lib.rs"\ncrate-type = ["rlib"]\n' >> "$UP/Cargo.toml"
cd "$UP"
TARGET="$1"
test "$TARGET" = aarch64-unknown-linux-musl
cargo test --locked --lib --bin clearrecovery
python3 - <<'PY'
from pathlib import Path
p=Path("scripts/build.sh")
s=p.read_text()
old='cargo build --release --locked --target "$TARGET"'
assert s.count(old)==1
s=s.replace(old,old+' --bin clearrecovery')
s=s.replace('release/baristore','release/clearrecovery')
p.write_text(s)
PY
sh scripts/build.sh
test -s "target/$TARGET/release/clearrecovery"
mkdir -p "$DEST/output"
cp "target/$TARGET/release/clearrecovery" "$DEST/output/clearrecovery"
cp LICENSE THIRD_PARTY_NOTICES.md "$DEST/output/"
