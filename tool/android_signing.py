"""Shared Android signing checks. Never include credential values in errors."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess

SIGNING_SECRETS = (
    "SHIORI_KEYSTORE_BASE64", "SHIORI_KEYSTORE_PASSWORD", "SHIORI_KEY_ALIAS",
    "SHIORI_KEY_PASSWORD", "SHIORI_SIGNING_CERT_SHA256",
)


class SigningError(ValueError):
    pass


def normalize_fingerprint(value: str) -> str:
    normalized = re.sub(r"[:\s]", "", value).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise SigningError("Configure a valid SHA-256 certificate fingerprint.")
    return normalized


def is_debug_certificate(metadata: str) -> bool:
    return bool(re.search(r"\bCN\s*=\s*Android Debug\b", metadata, re.IGNORECASE))


def validate_keystore(path: Path, alias: str, store_password: str, key_password: str) -> str:
    """Read the certificate and prove key access without exporting the private key."""
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", alias) or alias.lower() == "androiddebugkey":
        raise SigningError("Use a dedicated release key alias.")
    if not store_password or not key_password:
        raise SigningError("Both keystore and private-key passwords are required.")
    env = dict(os.environ)
    for name in SIGNING_SECRETS:
        env.pop(name, None)
    env["SHIORI_LOCAL_STORE_PASSWORD"] = store_password
    env["SHIORI_LOCAL_KEY_PASSWORD"] = key_password
    base = ["keytool", "-J-Duser.language=en", "-J-Duser.country=US", "-keystore", str(path),
            "-alias", alias, "-storepass:env", "SHIORI_LOCAL_STORE_PASSWORD"]

    def run(options: list[str]) -> bytes:
        try:
            result = subprocess.run(base + options, env=env, capture_output=True, check=False)
        except OSError:
            raise SigningError("Install JDK 17 and make keytool available.") from None
        if result.returncode:
            raise SigningError("Cannot open the release key; check the keystore, alias and passwords.")
        return result.stdout

    certificate = run(["-exportcert"])
    metadata = run(["-list", "-v"]).decode("utf-8", errors="replace")
    if is_debug_certificate(metadata):
        raise SigningError("An Android Debug certificate cannot be used for a release.")
    # A CSR proves access to the private key without exporting it or modifying
    # the keystore. Its public output is captured and discarded.
    run(["-certreq", "-keypass:env", "SHIORI_LOCAL_KEY_PASSWORD"])
    return hashlib.sha256(certificate).hexdigest()


def validate_apk_identity(signature_output: str, badging: str, expected: str | None, *, release: bool) -> dict:
    certificates = {normalize_fingerprint(value) for value in re.findall(
        r"certificate SHA-256 digest:\s*([0-9a-fA-F:]+)", signature_output)}
    if len(certificates) != 1:
        raise SigningError("Expected exactly one APK signing certificate.")
    certificate = certificates.pop()
    debug_certificate = is_debug_certificate(signature_output)
    debuggable = bool(re.search(r"(?m)^application-debuggable\b", badging))
    v2 = bool(re.search(r"Verified using v2 scheme[^\n]*:\s*true\b", signature_output))
    if release:
        if not expected:
            raise SigningError("SHIORI_SIGNING_CERT_SHA256 is required for release verification.")
        if debug_certificate or debuggable:
            raise SigningError("Debug certificates and debuggable APKs cannot be released.")
        if not v2:
            raise SigningError("The release APK must have a verified APK Signature Scheme v2 signature.")
        if certificate != normalize_fingerprint(expected):
            raise SigningError("APK certificate does not match the configured release fingerprint.")
    package = re.search(r"(?m)^package: name='([^']+)'[^\n]*versionCode='([^']+)'[^\n]*versionName='([^']+)'", badging)
    if not package or package[1] != "io.github.jayvoid.shiori":
        raise SigningError("Unexpected APK application ID or missing version metadata.")
    if not re.search(r"(?m)^(?:minSdkVersion|sdkVersion):'24'$", badging):
        raise SigningError("Expected Android 7.0 (API 24) minimum support.")
    return {"schema_version": 1, "verification": "release" if release else "development",
            "certificate_sha256": certificate,
            "expected_certificate_sha256": normalize_fingerprint(expected) if release else None,
            "debug_certificate": debug_certificate, "debuggable": debuggable,
            "signature_v2_verified": v2, "application_id": package[1],
            "version_code": package[2], "version_name": package[3]}


def validate_release_report(apk: Path, report: dict, expected: str) -> None:
    """Bind the release gate to the exact APK verified earlier in the job."""
    pin = normalize_fingerprint(expected)
    if (not isinstance(report, dict) or report.get("schema_version") != 1 or report.get("verification") != "release"
            or report.get("debug_certificate") is not False or report.get("debuggable") is not False
            or report.get("signature_v2_verified") is not True or report.get("certificate_sha256") != pin
            or report.get("expected_certificate_sha256") != pin
            or report.get("application_id") != "io.github.jayvoid.shiori" or report.get("apk_file") != apk.name):
        raise SigningError("A verified release-signing report matching the configured certificate is required.")
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if report.get("apk_sha256") != digest:
        raise SigningError("The APK changed after release-signature verification.")
