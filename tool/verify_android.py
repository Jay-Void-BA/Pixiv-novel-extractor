#!/usr/bin/env python3
"""Check the distributable APK using Android's official build tools."""
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

apk = Path(sys.argv[1] if len(sys.argv) > 1 else "build/app/outputs/flutter-apk/app-release.apk").resolve()
sdk_value = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
if not sdk_value:
    raise SystemExit("Set ANDROID_HOME to the Android SDK directory.")
sdk = Path(sdk_value)
versions = [p for p in (sdk / "build-tools").iterdir() if re.fullmatch(r"\d+\.\d+\.\d+", p.name)]
if not versions:
    raise SystemExit("No stable Android SDK build-tools installation found.")
tools = max(versions, key=lambda p: tuple(map(int, p.name.split("."))))
subprocess.run([str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)], check=True)
subprocess.run([str(tools / "zipalign"), "-c", "-P", "16", "4", str(apk)], check=True)
badging = subprocess.check_output([str(tools / "aapt2"), "dump", "badging", str(apk)], text=True)
if "package: name='io.github.jayvoid.shiori'" not in badging:
    raise SystemExit("Unexpected APK application ID.")
if not re.search(r"(?m)^(?:minSdkVersion|sdkVersion):'24'$", badging):
    raise SystemExit("Expected Android 7.0 (API 24) minimum support.")
with zipfile.ZipFile(apk) as bundle:
    damaged = bundle.testzip()
    if damaged:
        raise SystemExit(f"Corrupt APK entry: {damaged}")
    for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
        for library in ("libapp.so", "libflutter.so"):
            if bundle.getinfo(f"lib/{abi}/{library}").file_size == 0:
                raise SystemExit(f"Empty native library: {abi}/{library}")
    for resource in ("LICENSE", "assets/fonts/NotoSansSC-Regular.ttf", "assets/fonts/OFL.txt"):
        if bundle.getinfo(f"assets/flutter_assets/{resource}").file_size == 0:
            raise SystemExit(f"Empty bundled resource: {resource}")
print("APK signature, 16 KB ZIP alignment, application ID, minimum SDK, three ABIs, CJK font and licenses verified.")
