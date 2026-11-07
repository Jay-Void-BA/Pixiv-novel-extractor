#!/usr/bin/env python3
"""Build a relocatable FreeBSD/local Web bundle without any credentials."""
from pathlib import Path
import shutil
import zipfile

root = Path(__file__).resolve().parents[1]
dist = root / "dist"
staging = root / "build" / "web-bundle"
shutil.rmtree(staging, ignore_errors=True)
staging.mkdir(parents=True)
dist.mkdir(exist_ok=True)
shutil.copytree(root / "build/web", staging / "web")
shutil.copy2(root / "freebsd/shiori_server.py", staging / "shiori_server.py")
shutil.copy2(root / "LICENSE", staging / "LICENSE")
shutil.copy2(root / "docs/FREEBSD.md", staging / "README.md")
shutil.copy2(root / "docs/SECURITY_AND_PERFORMANCE.md", staging / "SECURITY_AND_PERFORMANCE.md")
with zipfile.ZipFile(dist / "shiori-web-freebsd.zip", "w", zipfile.ZIP_DEFLATED) as out:
    for path in sorted(staging.rglob("*")):
        if path.is_file(): out.write(path, path.relative_to(staging))
print("Packaged dist/shiori-web-freebsd.zip")
