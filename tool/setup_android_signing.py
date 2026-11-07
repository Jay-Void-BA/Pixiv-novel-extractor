#!/usr/bin/env python3
"""Run locally to upload a newly generated release key to GitHub Secrets."""
import argparse
import base64
import getpass
from pathlib import Path
import shutil
import subprocess
import sys

from android_signing import SigningError, validate_keystore


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keystore", type=Path, required=True)
    parser.add_argument("--alias", default="shiori")
    parser.add_argument("--repo", default="Jay-Void-BA/Pixiv-novel-extractor")
    args = parser.parse_args()
    path = args.keystore.expanduser().resolve()
    root = Path(__file__).resolve().parents[1]
    if path.is_relative_to(root):
        parser.error("Keep the private keystore outside the Git checkout.")
    if not path.is_file() or not 0 < path.stat().st_size <= 1024 * 1024:
        parser.error("Select a non-empty release keystore smaller than 1 MiB.")
    if not shutil.which("gh") or not shutil.which("keytool"):
        parser.error("Install GitHub CLI and JDK 17 first.")
    if not sys.stdin.isatty():
        parser.error("Run interactively in a local terminal so passwords remain hidden.")
    store_password = getpass.getpass("Keystore password (hidden): ")
    key_password = getpass.getpass("Private-key password (hidden; Enter = keystore password): ") or store_password
    try:
        fingerprint = validate_keystore(path, args.alias, store_password, key_password)
        values = {"SHIORI_KEYSTORE_BASE64": base64.b64encode(path.read_bytes()).decode("ascii"),
                  "SHIORI_KEYSTORE_PASSWORD": store_password, "SHIORI_KEY_ALIAS": args.alias,
                  "SHIORI_KEY_PASSWORD": key_password, "SHIORI_SIGNING_CERT_SHA256": fingerprint}
        for name, value in values.items():
            result = subprocess.run(["gh", "secret", "set", name, "--repo", args.repo],
                                    input=value, text=True, capture_output=True, check=False)
            if result.returncode:
                raise SigningError("GitHub Secrets upload failed; check gh authentication and repository administration access.")
        print("Configured all five signing Secrets. No keystore contents or passwords were printed.")
        print("Back up the keystore and passwords securely. Next: manually run delivery.yml with verify_android_signing=true.")
    except (SigningError, OSError) as error:
        print(str(error) if isinstance(error, SigningError) else "Could not configure signing Secrets.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
