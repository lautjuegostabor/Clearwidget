#!/usr/bin/env python3
"""Fail closed on any source byte mismatch before building a pinned local snapshot."""
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "BariStore-source.json").read_text())
assert manifest["commit"] == "56165783f31d3e441ae9f76df42c3cc55e239777"
base = root / "BariStore"
expected = {x["path"]: x["sha"] for x in manifest["files"]}
assert len(expected) == 53
actual = {str(p.relative_to(base)) for p in base.rglob("*") if p.is_file()}
assert actual == set(expected), (actual - set(expected), set(expected) - actual)
for name, sha in expected.items():
    f = base / name
    assert not f.is_symlink()
    b = f.read_bytes()
    h = hashlib.sha1(f"blob {len(b)}\0".encode() + b).hexdigest()
    assert h == sha, name
print(f"Verified all {len(expected)} pinned local BariStore files")
