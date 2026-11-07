"""Regression checks for release identity, secret handling and artifact substitution."""
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool"))
from android_signing import SigningError, validate_apk_identity, validate_keystore, validate_release_report
from prepare_android_signing import prepare
import setup_android_signing

PIN = "a" * 64
OTHER_PIN = "b" * 64
BADGING = "package: name='io.github.jayvoid.shiori' versionCode='1' versionName='1.0.0'\nsdkVersion:'24'\n"


def signature(pin=PIN, *, debug=False, v2=True):
    name = "Android Debug" if debug else "Pixiv Novel Extractor Release"
    return (f"Verified using v2 scheme (APK Signature Scheme v2): {str(v2).lower()}\n"
            f"Signer #1 certificate DN: CN={name}, O=Project\n"
            f"Signer #1 certificate SHA-256 digest: {pin}\n")


class ReleasePolicyTests(unittest.TestCase):
    def test_debug_signature_is_rejected_even_with_matching_pin(self):
        with self.assertRaises(SigningError):
            validate_apk_identity(signature(debug=True), BADGING, PIN, release=True)

    def test_debuggable_manifest_is_rejected_even_with_release_certificate(self):
        with self.assertRaises(SigningError):
            validate_apk_identity(signature(), BADGING + "application-debuggable\n", PIN, release=True)

    def test_wrong_missing_or_multiple_signers_and_missing_v2_are_rejected(self):
        for output, pin in [(signature(), None), (signature(OTHER_PIN), PIN), (signature(v2=False), PIN),
                            (signature() + signature(OTHER_PIN), PIN), ("", PIN)]:
            with self.subTest(case=len(output)), self.assertRaises(SigningError):
                validate_apk_identity(output, BADGING, pin, release=True)

    def test_release_pin_and_modern_apksigner_output_are_accepted(self):
        output = signature().replace("Signer #1", "V2 Signer:")
        report = validate_apk_identity(output, BADGING, ":".join(["AA"] * 32), release=True)
        self.assertEqual(report["verification"], "release")
        self.assertFalse(report["debuggable"])
        self.assertEqual(report["certificate_sha256"], PIN)

    def test_development_artifact_cannot_satisfy_release_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "shiori-android.apk"
            apk.write_bytes(b"test artifact")
            report = validate_apk_identity(signature(debug=True), BADGING + "application-debuggable\n", None, release=False)
            report.update(apk_file=apk.name, apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest())
            with self.assertRaises(SigningError):
                validate_release_report(apk, report, PIN)

    def test_verified_report_is_bound_to_the_exact_apk_and_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "shiori-android.apk"
            apk.write_bytes(b"verified artifact")
            report = validate_apk_identity(signature(), BADGING, PIN, release=True)
            report.update(apk_file=apk.name, apk_sha256=hashlib.sha256(apk.read_bytes()).hexdigest())
            validate_release_report(apk, report, PIN)
            with self.assertRaises(SigningError):
                validate_release_report(apk, report, OTHER_PIN)
            apk.write_bytes(b"substituted after verification")
            with self.assertRaises(SigningError):
                validate_release_report(apk, report, PIN)

    def test_release_packaging_requires_a_formal_signing_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["shiori-android.apk", "shiori-linux-x64.tar.gz", "shiori-windows-x64.zip",
                         "shiori-macos-arm64.zip", "shiori-ios-unsigned.zip", "shiori-web-freebsd.zip", "shiori-browser-bridge.zip"]:
                (root / name).write_bytes(b"packaging fixture")
            env = dict(os.environ, SHIORI_SIGNING_CERT_SHA256=PIN)
            command = [sys.executable, str(ROOT / "tool/check_release.py"), str(root)]
            result = subprocess.run(command, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "SHA256SUMS.txt").exists())
            report = validate_apk_identity(signature(), BADGING, PIN, release=True)
            report.update(apk_file="shiori-android.apk", apk_sha256=hashlib.sha256((root / "shiori-android.apk").read_bytes()).hexdigest())
            (root / "android-signing-verification.json").write_text(json.dumps(report))
            result = subprocess.run(command, env=env, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("android-signing-verification.json", (root / "SHA256SUMS.txt").read_text())

    def test_missing_secrets_fail_before_writing_a_keystore(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SigningError):
                prepare({"RUNNER_TEMP": directory})
            self.assertEqual(list(Path(directory).iterdir()), [])


class LocalSetupTests(unittest.TestCase):
    def run_setup(self, *, fail_upload=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "local-release.jks"
            path.write_bytes(b"local setup fixture; key validation is tested separately")
            store_password, key_password = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
            encoded = base64.b64encode(path.read_bytes()).decode("ascii")
            output, error = io.StringIO(), io.StringIO()
            response = subprocess.CompletedProcess([], int(fail_upload), "", store_password + key_password + encoded)
            with mock.patch.object(sys, "argv", ["setup_android_signing.py", "--keystore", str(path)]), \
                    mock.patch.object(sys.stdin, "isatty", return_value=True), \
                    mock.patch.object(setup_android_signing.shutil, "which", return_value="/available"), \
                    mock.patch.object(setup_android_signing.getpass, "getpass", side_effect=[store_password, key_password]), \
                    mock.patch.object(setup_android_signing, "validate_keystore", return_value=PIN), \
                    mock.patch.object(setup_android_signing.subprocess, "run", return_value=response) as upload, \
                    contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                status = setup_android_signing.main()
            log = output.getvalue() + error.getvalue()
            for value in (store_password, key_password, encoded):
                self.assertTrue(value not in log, "Local setup exposed credential contents")
                for call in upload.call_args_list:
                    self.assertTrue(value not in " ".join(call.args[0]), "Credentials must not appear in process arguments")
            return status, upload.call_args_list

    def test_local_setup_uses_stdin_and_does_not_print_values(self):
        status, calls = self.run_setup()
        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 5)
        self.assertTrue(all("input" in call.kwargs for call in calls))

    def test_github_cli_failure_does_not_echo_credentials_from_stderr(self):
        status, _ = self.run_setup(fail_upload=True)
        self.assertEqual(status, 1)


@unittest.skipUnless(shutil.which("keytool"), "JDK keytool is required for real keystore checks")
class RealKeystoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.password = secrets.token_urlsafe(24)
        env = dict(os.environ, SHIORI_TEST_PASSWORD=cls.password)
        for alias, name in [("release-key", "Signing Regression Fixture"), ("debug-fixture", "Android Debug")]:
            path = cls.root / (alias + ".jks")
            result = subprocess.run([
                "keytool", "-genkeypair", "-noprompt", "-storetype", "JKS", "-keystore", str(path),
                "-alias", alias, "-keyalg", "RSA", "-keysize", "2048", "-validity", "2",
                "-dname", f"CN={name}", "-storepass:env", "SHIORI_TEST_PASSWORD", "-keypass:env", "SHIORI_TEST_PASSWORD",
            ], env=env, capture_output=True)
            if result.returncode:
                cls.tmp.cleanup()
                raise RuntimeError("Could not create the temporary signing regression fixture.")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def signing_env(self, directory):
        path = self.root / "release-key.jks"
        pin = validate_keystore(path, "release-key", self.password, self.password)
        return {"RUNNER_TEMP": directory, "GITHUB_ENV": str(Path(directory) / "github-env"),
                "SHIORI_KEYSTORE_BASE64": base64.b64encode(path.read_bytes()).decode("ascii"),
                "SHIORI_KEYSTORE_PASSWORD": self.password, "SHIORI_KEY_PASSWORD": self.password,
                "SHIORI_KEY_ALIAS": "release-key", "SHIORI_SIGNING_CERT_SHA256": pin}

    def test_real_key_is_restored_with_private_permissions_and_no_secret_output(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.signing_env(directory)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                prepare(env)
            path = Path(directory) / "shiori-android-signing/release.jks"
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            public_env = Path(env["GITHUB_ENV"]).read_text()
            self.assertTrue(self.password not in output.getvalue() + public_env, "Credential exposure")
            self.assertTrue(env["SHIORI_KEYSTORE_BASE64"] not in output.getvalue() + public_env, "Keystore exposure")
            self.assertIn("SHIORI_KEYSTORE_PATH=", public_env)

    def test_wrong_certificate_pin_removes_the_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.signing_env(directory)
            env["SHIORI_SIGNING_CERT_SHA256"] = OTHER_PIN
            with self.assertRaises(SigningError):
                prepare(env)
            self.assertFalse((Path(directory) / "shiori-android-signing").exists())
            self.assertFalse(Path(env["GITHUB_ENV"]).exists())

    def test_wrong_private_key_password_fails_without_echoing_it(self):
        wrong = secrets.token_urlsafe(24)
        with self.assertRaises(SigningError) as caught:
            validate_keystore(self.root / "release-key.jks", "release-key", self.password, wrong)
        self.assertTrue(wrong not in str(caught.exception), "Credential exposure")

    def test_debug_keystore_is_rejected_even_with_a_different_alias(self):
        with self.assertRaises(SigningError):
            validate_keystore(self.root / "debug-fixture.jks", "debug-fixture", self.password, self.password)


if __name__ == "__main__":
    unittest.main()
