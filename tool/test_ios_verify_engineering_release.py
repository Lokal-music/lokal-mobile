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

    def _add_smb(self, *, bad_notice=False, bad_uuid=False):
        (self.repo / 'assets/licenses').mkdir(parents=True)
        (self.repo / 'assets/licenses/libsmb2.txt').write_bytes(b'Complete LGPL fixture')
        (self.repo / 'pubspec.lock').write_text('packages:\n  dart_smb2:\n    version: "0.1.3"\n')
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'commit', '-qm', 'native SMB dependency'], check=True)
        self.metadata['source_commit'] = subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()
        self.metadata['source_tree'] = subprocess.check_output(['git', '-C', str(self.repo), 'rev-parse', 'HEAD^{tree}'], text=True).strip()
        with self.source.open('wb') as target:
            subprocess.run(['git', '-C', str(self.repo), 'archive', '--format=tar.gz', 'HEAD'], stdout=target, check=True)
        binary = 'Frameworks/libsmb2.framework/libsmb2'
        notice = 'Frameworks/App.framework/flutter_assets/assets/licenses/libsmb2.txt'
        self.metadata['binary_uuids'][binary] = ['wrong' if bad_uuid else '1052E70C-84DF-3BBE-9541-0D948E7E6FF9']
        self.metadata['native_smb'] = {'framework': binary, 'license': notice, 'ffi_load_reachable': True,
            'upstream_archive_sha256': 'c9b05f037865affe0ebdac71a0013e1b53e72ad007b5f3a00331eeeb56ba43f1'}
        with zipfile.ZipFile(self.ipa, 'a') as archive:
            archive.writestr('Payload/Runner.app/' + binary, b'Native fixture')
            archive.writestr('Payload/Runner.app/' + notice, b'Tampered' if bad_notice else b'Complete LGPL fixture')
        self._write_manifest()

    def test_smb_source_requires_packaged_framework_and_exact_notice(self):
        self._add_smb()
        self.assertEqual(verify(self.artifact, self.repo, min_sources=4)['binaries'], 3)

    def test_smb_notice_tamper_refused_even_with_matching_ipa_checksum(self):
        self._add_smb(bad_notice=True)
        with self.assertRaisesRegex(ReleaseAuditError, 'notice differs'):
            verify(self.artifact, self.repo, min_sources=4)

    def test_smb_upstream_binary_version_drift_refused(self):
        self._add_smb(bad_uuid=True)
        with self.assertRaisesRegex(ReleaseAuditError, 'UUID differs'):
            verify(self.artifact, self.repo, min_sources=4)

    def test_accepted_engineering_package(self) -> None:
        report = verify(self.artifact, self.repo, min_sources=2)
        self.assertEqual(report["source_files_checked"], 2)
        self.assertEqual(report["binaries"], 2)

    def test_nested_actions_artifact_layout(self) -> None:
        parent = self.artifact.parent
        self.artifact.rename(parent / "ipa")
        report = verify(parent, self.repo, min_sources=2)
        self.assertEqual(report["binaries"], 2)

    def test_accepts_canonical_git_archive_crlf_export(self) -> None:
        # The vendored Opus tree uses eol=crlf for Windows project files.
        # Git archive exports CRLF even when the committed blob is LF.
        (self.repo / ".gitattributes").write_text("example.dart eol=crlf\\n".replace("\\n", "\n"))
        subprocess.run(["git", "-C", str(self.repo), "add", ".gitattributes"],
                       check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm",
                        "mark Windows project files CRLF"], check=True)
        self.commit = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True
        ).strip()
        self.tree = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD^{tree}"], text=True
        ).strip()
        with self.source.open("wb") as output:
            subprocess.run(
                ["git", "-C", str(self.repo), "archive", "--format=tar.gz", "HEAD"],
                stdout=output, check=True,
            )
        self.metadata["source_commit"] = self.commit
        self.metadata["source_tree"] = self.tree
        self._write_manifest()
        with tarfile.open(self.source, "r:gz") as archive:
            exported = archive.extractfile("example.dart")
            self.assertIsNotNone(exported)
            self.assertEqual(exported.read(), b"void main() {}\r\n")
        report = verify(self.artifact, self.repo, min_sources=3)
        self.assertEqual(report["source_files_checked"], 3)

    def test_rejects_missing_exported_member(self) -> None:
        with tarfile.open(self.source, "w:gz") as archive:
            content = (self.repo / "README.md").read_bytes()
            entry = tarfile.TarInfo("README.md")
            entry.size = len(content)
            archive.addfile(entry, BytesIO(content))
        with self.assertRaisesRegex(ReleaseAuditError, "member count|path differs"):
            verify(self.artifact, self.repo, min_sources=1)

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
