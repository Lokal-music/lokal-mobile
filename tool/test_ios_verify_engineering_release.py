"""Portable release-package verifier contracts (no Apple signing required)."""
from __future__ import annotations

from io import BytesIO
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

from ios_verify_engineering_release import ReleaseAuditError, verify


class ReleasePackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.repo = base / "repo"
        self.repo.mkdir()
        self.artifact = base / "artifact"
        self.artifact.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email",
                        "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name",
                        "Test"], check=True)
        (self.repo / "README.md").write_text("release source\n")
        (self.repo / "example.dart").write_text("void main() {}\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "snapshot"],
                       check=True)
        self.commit = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True
        ).strip()
        self.tree = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD^{tree}"], text=True
        ).strip()

        self.source = self.artifact / "Lokal-source.tar.gz"
        self._write_source()
        app = "Payload/Runner.app/"
        info = {
            "CFBundleExecutable": "Runner",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "MinimumOSVersion": "16.0",
            "CFBundleIdentifier": "app.lokal",
            "CFBundleVersion": "87",
            "CFBundleShortVersionString": "1.0",
        }
        self.ipa = self.artifact / "Lokal-unsigned.ipa"
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(app + "Info.plist", plistlib.dumps(info))
            archive.writestr(app + "Runner", b"device executable")
            archive.writestr(app + "Frameworks/Native.framework/Native",
                             b"device framework")

        symbols = self.artifact / "Symbols"
        native = symbols / "Runner.app.dSYM/Contents/Resources/DWARF/Runner"
        native.parent.mkdir(parents=True)
        native.write_bytes(b"debug symbols")
        (symbols / "app.ios-arm64.symbols").write_bytes(b"dart symbols")
        self.metadata = {
            "source_commit": self.commit,
            "source_tree": self.tree,
            "minimum_ios": "16.0",
            "signing": "Unsigned build",
            "release_status": "Engineering build",
            "bundle_id": "app.lokal",
            "build": "87",
            "version": "1.0",
            "binary_uuids": {
                "Runner": ["TEST-UUID"],
                "Frameworks/Native.framework/Native": ["ANOTHER-UUID"],
            },
            "cast_resources_verified": [],
            "symbols": {
                "matching_native_bundles": ["Runner.app.dSYM"],
                "dart_aot_files": ["app.ios-arm64.symbols"],
            },
        }
        self._write_manifest()

    def _write_source(self, replacement: str | None = None) -> None:
        with tarfile.open(self.source, "w:gz") as archive:
            for name in ("README.md", "example.dart"):
                content = (self.repo / name).read_bytes()
                if replacement is not None and name == "README.md":
                    content = replacement.encode()
                info = tarfile.TarInfo(name)
                info.size = len(content)
                archive.addfile(info, BytesIO(content))

    def _write_manifest(self) -> None:
        sha = hashlib.sha256(self.ipa.read_bytes()).hexdigest()
        self.metadata["sha256"] = sha
        (self.artifact / "Lokal-unsigned.ipa.sha256").write_text(
            f"{sha}  Lokal-unsigned.ipa\n"
        )
        (self.artifact / "Lokal-unsigned.ipa.json").write_text(
            json.dumps(self.metadata)
        )

    def test_accepted_engineering_package(self) -> None:
        report = verify(self.artifact, self.repo, min_sources=2)
        self.assertEqual(report["source_files_checked"], 2)
        self.assertEqual(report["binaries"], 2)

    def test_nested_actions_artifact_layout(self) -> None:
        parent = self.artifact.parent
        self.artifact.rename(parent / "ipa")
        report = verify(parent, self.repo, min_sources=2)
        self.assertEqual(report["binaries"], 2)

    def test_rejects_changed_ipa_bytes(self) -> None:
        with self.ipa.open("ab") as handle:
            handle.write(b"tamper")
        with self.assertRaisesRegex(ReleaseAuditError, "metadata SHA-256"):
            verify(self.artifact, self.repo, min_sources=2)

    def test_rejects_uncommitted_source_archive(self) -> None:
        self._write_source(replacement="different source\n")
        with self.assertRaisesRegex(ReleaseAuditError, "bytes differ"):
            verify(self.artifact, self.repo, min_sources=2)

    def test_rejects_missing_symbols(self) -> None:
        (self.artifact / "Symbols/app.ios-arm64.symbols").unlink()
        with self.assertRaisesRegex(ReleaseAuditError, "Dart AOT"):
            verify(self.artifact, self.repo, min_sources=2)

    def test_rejects_commit_mismatch(self) -> None:
        self.metadata["source_commit"] = "0" * 40
        self._write_manifest()
        with self.assertRaisesRegex(ReleaseAuditError, "source commit"):
            verify(self.artifact, self.repo, min_sources=2)


if __name__ == "__main__":
    unittest.main()
