#!/usr/bin/env python3
"""Fail closed if any promised asset is absent; write checksums after validation."""
import hashlib
import json
import os
from pathlib import Path
import sys

from android_signing import SigningError, validate_release_report

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
report_path = root / "android-signing-verification.json"
try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    validate_release_report(root / "shiori-android.apk", report, os.environ.get("SHIORI_SIGNING_CERT_SHA256", ""))
except (OSError, ValueError, SigningError):
    raise SystemExit("Release blocked: a matching official Android signing report is required.") from None
assets.append(report_path)
with (root / "SHA256SUMS.txt").open("w") as out:
    for path in sorted(assets):
        out.write(f"{hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()}  {path.name}\n")
print(f"Validated {len(assets)} assets; wrote SHA256SUMS.txt")
