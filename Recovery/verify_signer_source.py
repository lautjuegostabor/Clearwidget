#!/usr/bin/env python3
"""Compile-only preparation. Never sign or install; no Apple account operations."""
import pathlib, shutil, subprocess, sys
import prepare_signer as patch
root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(root/'Tools/verify_vendor.py'),str(root/'Vendor')],check=True)
dest = pathlib.Path(sys.argv[1]).resolve()
if dest.exists(): raise SystemExit("Use a new staging directory")
shutil.copytree(root/'Vendor/BariStore',dest)
p=dest/'src/install.rs'; q=dest/'src/main.rs'; portal=dest/'src/apple/portal.rs'
install=patch.patch_install(p.read_text()); main=patch.replace(q.read_text(),'mod apple;','mod apple;\nmod bridge_entitlements;')
portal_text=patch.patch_portal(portal.read_text())
p.write_text(install); q.write_text(main); portal.write_text(portal_text)
shutil.copy2(root/'Recovery/bridge_entitlements.rs',dest/'src/bridge_entitlements.rs')
print('Prepared narrow signer for compilation/testing only')
