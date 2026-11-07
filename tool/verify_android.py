#!/usr/bin/env python3
"""Verify APK integrity and identity with Android's official SDK tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

from android_signing import SigningError, validate_apk_identity


def verify(apk: Path, *, release: bool, expected: str | None):
    sdk_value = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk_value:
        raise SigningError("Set ANDROID_HOME to the Android SDK directory.")
    versions = [path for path in (Path(sdk_value) / "build-tools").iterdir() if re.fullmatch(r"\d+\.\d+\.\d+", path.name)]
    if not versions:
        raise SigningError("No stable Android SDK build-tools installation found.")
    tools = max(versions, key=lambda path: tuple(map(int, path.name.split("."))))

    def run(name, *arguments):
        result = subprocess.run([str(tools / name), *arguments, str(apk)], capture_output=True, text=True)
        if result.returncode:
            raise SigningError(f"Android SDK {name} verification failed.")
        return result.stdout

    signature = run("apksigner", "verify", "--verbose", "--print-certs")
    run("zipalign", "-c", "-P", "16", "4")
    badging = run("aapt2", "dump", "badging")
    report = validate_apk_identity(signature, badging, expected, release=release)
    with zipfile.ZipFile(apk) as bundle:
        if bundle.testzip():
            raise SigningError("The APK contains a corrupt ZIP entry.")
        if release:
            for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
                for library in ("libapp.so", "libflutter.so"):
                    if bundle.getinfo(f"lib/{abi}/{library}").file_size == 0:
                        raise SigningError("The release APK is missing a required native library.")
        elif not any(name.startswith("lib/") and name.endswith("/libflutter.so") for name in bundle.namelist()):
            raise SigningError("The development APK is missing the Flutter engine.")
        for resource in ("LICENSE", "assets/fonts/NotoSansSC-Regular.ttf", "assets/fonts/OFL.txt"):
            if bundle.getinfo(f"assets/flutter_assets/{resource}").file_size == 0:
                raise SigningError("The APK is missing a required font or license.")
    with apk.open("rb") as stream:
        report["apk_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
    report["apk_file"] = apk.name
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", nargs="?", type=Path, default=Path("build/app/outputs/flutter-apk/app-release.apk"))
    parser.add_argument("--mode", choices=("release", "development"), default="release")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.apk.resolve(), release=args.mode == "release", expected=os.environ.get("SHIORI_SIGNING_CERT_SHA256"))
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"Verified {args.mode} APK: signature, certificate policy, alignment, package metadata, native libraries and resources.")
    except (SigningError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(str(error) if isinstance(error, SigningError) else "APK verification failed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
