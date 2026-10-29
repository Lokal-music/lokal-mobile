"""Boundary tests for versioning, signing cleanup, and uploadable release outputs."""

import base64
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import ci_release as release


class MetadataTests(unittest.TestCase):
    pubspec = "name: flick\nversion: 0.1.0+1\n"

    def test_local_defaults_preserve_pubspec(self):
        result = release.metadata(self.pubspec)
        self.assertEqual((result["version"], result["build_number"]), ("0.1.0", "1"))

    def test_ci_codes_increase_and_reruns_are_deterministic(self):
        result = release.metadata(self.pubspec, run_number="22")
        self.assertEqual(result, release.metadata(self.pubspec, run_number="22"))
        self.assertEqual(result["build_number"], "23")
        self.assertEqual(release.metadata(self.pubspec, run_number="23")["build_number"], "24")

    def test_alpha_tag_keeps_prerelease_label(self):
        result = release.metadata(self.pubspec, "refs/tags/v0.1.0-alpha.1", "7", flavor="full")
        self.assertEqual(result["version"], "0.1.0-alpha.1")
        self.assertEqual(result["prerelease"], "true")
        self.assertEqual(result["flavors"], '["full"]')

    def test_stable_tag(self):
        self.assertEqual(release.metadata(self.pubspec, "refs/tags/v0.1.0")["prerelease"], "false")

    def test_manual_version_code(self):
        self.assertEqual(release.metadata(self.pubspec, run_number="2", supplied="300")["build_number"], "300")

    def test_invalid_or_mismatched_tags(self):
        for tag in ("v0.2.0", "0.1.0", "v00.1.0", "v0.1.0-alpha.01",
                    "v0.1.0+3", "v0.1.0-", "v0.1.0\nflavors=oops", "v0.1.0;id"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.metadata(self.pubspec, "refs/tags/" + tag)

    def test_prerelease_pubspec_cannot_be_promoted_implicitly(self):
        with self.assertRaises(ValueError):
            release.metadata("version: 0.1.0-alpha.1+1", "refs/tags/v0.1.0")

    def test_invalid_build_numbers_and_overflow(self):
        for value in ("0", "-1", "01", "1.2", "2100000001", "2\n", " "):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.metadata(self.pubspec, supplied=value)
        with self.assertRaises(ValueError):
            release.metadata("version: 0.1.0+2100000000", run_number="1")

    def test_supplied_code_cannot_go_backwards(self):
        with self.assertRaises(ValueError):
            release.metadata(self.pubspec, run_number="10", supplied="9")

    def test_invalid_flavor(self):
        with self.assertRaises(ValueError):
            release.metadata(self.pubspec, flavor="full;id")

    def test_missing_pubspec_build_number(self):
        with self.assertRaises(ValueError):
            release.metadata("version: 0.1.0")


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "signing"
        self.env = dict(zip(release.SECRETS, [base64.b64encode(b"test-key").decode(),
                                            "private-store-value", "private-alias", "private-key-value"]))

    def test_missing_secrets_report_only_names(self):
        for name in release.SECRETS:
            with self.subTest(name=name):
                env = dict(self.env)
                del env[name]
                with self.assertRaisesRegex(ValueError, name) as raised:
                    release.check_signing(env)
                self.assertNotIn("private-", str(raised.exception))

    def test_material_is_private_and_removed_after_success(self):
        with release.signing_material(self.env, self.directory) as env:
            path = Path(env["ANDROID_KEYSTORE_PATH"])
            self.assertEqual(path.read_bytes(), b"test-key")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
            self.assertNotIn("ANDROID_KEYSTORE_BASE64", env)
        self.assertFalse(self.directory.exists())

    def test_material_removed_on_build_failure(self):
        with self.assertRaises(subprocess.CalledProcessError):
            with release.signing_material(self.env, self.directory):
                raise subprocess.CalledProcessError(1, "flutter")
        self.assertFalse(self.directory.exists())

    def test_bad_base64_is_safe_and_cleaned(self):
        self.env["ANDROID_KEYSTORE_BASE64"] = "private-INVALID!"
        with self.assertRaisesRegex(ValueError, "ANDROID_KEYSTORE_BASE64") as raised:
            with release.signing_material(self.env, self.directory):
                self.fail("Invalid base64 was accepted")
        self.assertNotIn("private-", str(raised.exception))
        self.assertFalse(self.directory.exists())

    def test_wrapped_base64_is_accepted(self):
        self.env["ANDROID_KEYSTORE_BASE64"] += "\n"
        with release.signing_material(self.env, self.directory):
            pass

    def test_empty_decoded_keystore_is_rejected(self):
        self.env["ANDROID_KEYSTORE_BASE64"] = "\n"
        with self.assertRaisesRegex(ValueError, "empty keystore"):
            with release.signing_material(self.env, self.directory):
                self.fail("Empty key was accepted")

    def test_always_cleanup_is_idempotent(self):
        self.directory = Path(self.temp.name) / "konnekted-signing"
        self.directory.mkdir()
        (self.directory / "release.keystore").write_bytes(b"test")
        with patch.dict(os.environ, {"RUNNER_TEMP": self.temp.name}):
            release.cleanup()
            release.cleanup()
        self.assertFalse(self.directory.exists())


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / "input.apk"
        self.dest = self.root / "output"
        self.env = {"ANDROID_HOME": str(self.root), "ANDROID_KEYSTORE_PASSWORD": "private-value"}
        self.signer = "a" * 64
        self.outputs = [f"Signer #1 certificate SHA-256 digest: {self.signer}\n",
                        "package: name='com.lokalkonnekt.konnekted2' versionCode='23' versionName='0.1.0-alpha.1'"]

    def write_apk(self, abis=("arm64-v8a",)):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi in abis:
                for library in ("librust_lib_flick_player.so", "libflutter.so", "libapp.so",
                                "libmornye_discord.so", "libdiscord_partner_sdk.so"):
                    archive.writestr(f"lib/{abi}/{library}", "fixture")
            for notice in ("Discord-License-Notices.txt", "Mornye-Discord-Bridge-License.txt"):
                archive.writestr(f"assets/{notice}", "fixture notice")

    def package(self):
        release.package_apk(self.apk, self.dest, "full", "0.1.0-alpha.1", 23, self.env, self.signer)

    def test_verified_artifacts_have_checksums_and_no_signing_material(self):
        self.write_apk()
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs) as tool:
            self.package()
            for call in tool.call_args_list:
                self.assertNotIn("ANDROID_KEYSTORE_PASSWORD", call.kwargs["env"])
        output = self.dest / "Lokal-0.1.0-alpha.1-arm64.apk"
        self.assertEqual(output.read_bytes(), self.apk.read_bytes())
        self.assertEqual((self.dest / "SHA256SUMS-full.txt").read_text(),
                         f"{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name}\n")
        self.assertEqual(len(list(self.dest.iterdir())), 3)
        import json
        metadata = json.loads((self.dest / "full-metadata.json").read_text())
        self.assertEqual(metadata["abis"], ["arm64-v8a"])

    def test_unsigned_apk_cannot_be_uploaded(self):
        self.write_apk()
        with patch.object(release.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "apksigner")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.package()
        self.assertFalse(self.dest.exists())

    def test_wrong_signer_is_rejected(self):
        self.outputs[0] = "Signer #1 certificate SHA-256 digest: " + "b" * 64
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "supplied release key"):
                self.package()
        self.assertFalse(self.dest.exists())

    def test_wrong_version_is_rejected(self):
        self.outputs[1] = self.outputs[1].replace("versionCode='23'", "versionCode='0'")
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "metadata"):
                self.package()
        self.assertFalse(self.dest.exists())

    def test_missing_arm64_native_library_is_rejected(self):
        self.write_apk(abis=())
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "arm64-v8a"):
                self.package()
        self.assertFalse(self.dest.exists())

    def test_legacy_32_bit_payload_is_rejected(self):
        self.write_apk(abis=("arm64-v8a", "armeabi-v7a"))
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "only arm64-v8a"):
                self.package()
        self.assertFalse(self.dest.exists())

    def test_extra_x86_payload_is_rejected(self):
        self.write_apk(abis=("arm64-v8a", "x86_64"))
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "only arm64-v8a"):
                self.package()
        self.assertFalse(self.dest.exists())


class PlayBundlePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "app-play-release.aab"
        self.output = self.root / "output"
        self.signer = "a" * 64
        self.env = {"ANDROID_KEYSTORE_PASSWORD": "private-value"}
        self.outputs = ["jar verified.\n", "Signer #1:\n SHA256: " +
                        ":".join(["aa"] * 32) + "\n"]

    def write_bundle(self, abis=("arm64-v8a",), include_manifest=True):
        with zipfile.ZipFile(self.bundle, "w") as archive:
            archive.writestr("BundleConfig.pb", b"fixture")
            if include_manifest:
                archive.writestr("base/manifest/AndroidManifest.xml", b"fixture")
            for abi in abis:
                for library in ("librust_lib_flick_player.so", "libflutter.so", "libapp.so",
                                "libmornye_discord.so", "libdiscord_partner_sdk.so"):
                    archive.writestr(f"base/lib/{abi}/{library}", b"fixture")

    def package(self):
        release.package_play_bundle(
            self.bundle, self.output, "0.1.0", 123, self.env, self.signer)

    def test_valid_bundle_is_available_for_play_console_with_checksum(self):
        self.write_bundle()
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs) as tool:
            self.package()
            for call in tool.call_args_list:
                self.assertNotIn("ANDROID_KEYSTORE_PASSWORD", call.kwargs["env"])
        bundle = self.output / "Lokal-0.1.0-Play.aab"
        self.assertEqual(bundle.read_bytes(), self.bundle.read_bytes())
        self.assertEqual(
            (self.output / f"{bundle.name}.sha256").read_text(),
            f"{hashlib.sha256(bundle.read_bytes()).hexdigest()}  {bundle.name}\n")
        self.assertEqual(len(list(self.output.iterdir())), 2)

    def test_unsigned_bundle_is_not_published(self):
        self.write_bundle()
        with patch.object(release.subprocess, "check_output",
                          side_effect=subprocess.CalledProcessError(1, "jarsigner")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.package()
        self.assertFalse(self.output.exists())

    def test_unexpected_certificate_is_not_published(self):
        self.write_bundle()
        self.outputs[1] = "SHA256: " + ":".join(["bb"] * 32)
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "supplied release key"):
                self.package()
        self.assertFalse(self.output.exists())

    def test_missing_manifest_is_not_published(self):
        self.write_bundle(include_manifest=False)
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "metadata"):
                self.package()
        self.assertFalse(self.output.exists())

    def test_extra_abi_is_not_published(self):
        self.write_bundle(abis=("arm64-v8a", "x86_64"))
        with patch.object(release.subprocess, "check_output", side_effect=self.outputs):
            with self.assertRaisesRegex(ValueError, "only arm64-v8a"):
                self.package()
        self.assertFalse(self.output.exists())



if __name__ == "__main__":
    unittest.main()
