#!/usr/bin/env python3
"""Fail closed if any promised asset is absent; write checksums after validation."""
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "dist")
patterns = ["shiori-android.apk", "shiori-linux-x64.tar.gz", "shiori-windows-x64.zip",
            "shiori-macos-*.zip", "shiori-ios-unsigned.zip", "shiori-web-freebsd.zip", "shiori-browser-bridge.zip"]
assets = []
for pattern in patterns:
    found = list(root.glob(pattern))
    if not found: raise SystemExit(f"Missing required release asset: {pattern}")
    for file in found:
        if file.stat().st_size == 0: raise SystemExit(f"Empty release asset: {file}")
    assets.extend(found)
with (root / "SHA256SUMS.txt").open("w") as out:
    for path in sorted(assets):
        out.write(f"{hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()}  {path.name}\n")
print(f"Validated {len(assets)} assets; wrote SHA256SUMS.txt")
