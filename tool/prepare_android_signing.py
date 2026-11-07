#!/usr/bin/env python3
"""Restore a release keystore into a private, temporary Actions directory."""
import base64
import binascii
import os
from pathlib import Path
import shutil
import sys

from android_signing import SIGNING_SECRETS, SigningError, normalize_fingerprint, validate_keystore


def prepare(env):
    if not all(env.get(name) for name in SIGNING_SECRETS):
        raise SigningError("Release signing requires all five SHIORI signing Secrets; see docs/ANDROID_SIGNING.md.")
    pin = normalize_fingerprint(env["SHIORI_SIGNING_CERT_SHA256"])
    try:
        contents = base64.b64decode("".join(env["SHIORI_KEYSTORE_BASE64"].split()), validate=True)
    except (binascii.Error, ValueError):
        raise SigningError("The release keystore Secret must be valid Base64.") from None
    if not 0 < len(contents) <= 1024 * 1024:
        raise SigningError("The release keystore must be a non-empty file smaller than 1 MiB.")
    directory = Path(env["RUNNER_TEMP"]).resolve() / "shiori-android-signing"
    directory.mkdir(mode=0o700)
    path = directory / "release.jks"
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(contents)
        actual = validate_keystore(path, env["SHIORI_KEY_ALIAS"], env["SHIORI_KEYSTORE_PASSWORD"], env["SHIORI_KEY_PASSWORD"])
        if actual != pin:
            raise SigningError("The keystore certificate does not match SHIORI_SIGNING_CERT_SHA256.")
        if any(character in str(path) for character in "\r\n"):
            raise SigningError("Invalid runner temporary path.")
        with Path(env["GITHUB_ENV"]).open("a", encoding="utf-8") as stream:
            stream.write(f"SHIORI_KEYSTORE_PATH={path}\n")
    except BaseException:
        shutil.rmtree(directory)
        raise
    print("Release key restored and validated in the private runner temporary directory.")


def main():
    try:
        prepare(os.environ)
    except (SigningError, OSError, KeyError):
        print("Release signing setup failed. Check all five signing Secrets and docs/ANDROID_SIGNING.md.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
