#!/usr/bin/env python3
from pathlib import Path
import json
import shutil
import zipfile

root = Path(__file__).resolve().parents[1]
staging = root / "build/bridge-bundle"
shutil.rmtree(staging, ignore_errors=True)
staging.mkdir(parents=True)
for browser in ["chromium", "firefox"]:
    target = staging / browser
    shutil.copytree(root / "browser_extension", target)
    manifest = json.loads((target / "manifest.json").read_text())
    if browser == "firefox":
        manifest["background"] = {"scripts": ["validation.js", "background.js"]}
        manifest.pop("minimum_chrome_version", None)
        manifest["browser_specific_settings"] = {"gecko": {
            "id": "shiori-bridge@jay-void-ba.github.io", "strict_min_version": "115.0",
            "data_collection_permissions": {"required": ["authenticationInfo"]},
        }}
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
shutil.copy2(root / "browser_extension/README.md", staging / "README.md")
dist = root / "dist"
dist.mkdir(exist_ok=True)
with zipfile.ZipFile(dist / "shiori-browser-bridge.zip", "w", zipfile.ZIP_DEFLATED) as out:
    for path in sorted(staging.rglob("*")):
        if path.is_file(): out.write(path, path.relative_to(staging))
print("Packaged dist/shiori-browser-bridge.zip")
