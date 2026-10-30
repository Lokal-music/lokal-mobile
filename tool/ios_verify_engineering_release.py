#!/usr/bin/env python3
"""Independently verify a downloaded unsigned iPhone engineering artifact.

This verifies byte identity, source contents and packaged symbols, not Apple
signing, device installation, codec capabilities or public release readiness.
"""
from __future__ import annotations

import argparse
import hashlib
from itertools import zip_longest
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
import tempfile
import zipfile


class ReleaseAuditError(ValueError):
    pass


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseAuditError(message)


def _git(repo: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repo), *args], text=True
    ).strip()


def _source_blobs(repo: Path) -> dict[str, str]:
    raw = subprocess.check_output(
        ["git", "-C", str(repo), "ls-tree", "-rz", "--full-tree", "HEAD"]
    )
    result: dict[str, str] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        header, name = record.split(b"\t", 1)
        _mode, kind, digest = header.split(b" ", 2)
        if kind == b"blob":
            result[name.decode("utf-8", "surrogateescape")] = digest.decode("ascii")
    return result


def _verify_source_export(source: Path, repo: Path, tracked: dict[str, str]) -> int:
    """Compare every exported member to a fresh Git archive of this checkout.

    Git archive applies export-ignore, export-subst and eol attributes. In
    particular, vendored Opus marks common.props eol=crlf, so the exported
    bytes legitimately differ from the stored Git blob. Comparing against a
    separately generated canonical export preserves byte-level verification
    without weakening it to a line-ending-tolerant comparison.
    """
    seen: set[str] = set()
    with tempfile.TemporaryFile() as canonical:
        subprocess.run(
            ["git", "-C", str(repo), "archive", "--format=tar", "HEAD"],
            stdout=canonical, check=True,
        )
        canonical.seek(0)
        with tarfile.open(source, "r:gz") as packaged, tarfile.open(
            fileobj=canonical, mode="r:"
        ) as reference:
            actual_files = (entry for entry in packaged if not entry.isdir())
            expected_files = (entry for entry in reference if not entry.isdir())
            for actual, expected in zip_longest(actual_files, expected_files):
                _require(actual is not None and expected is not None,
                         "Source archive member count differs from HEAD export")
                _require(actual.name == expected.name,
                         f"Source archive path differs from HEAD export: {actual.name}")
                _require(actual.name not in seen,
                         f"Duplicate source path: {actual.name}")
                seen.add(actual.name)
                _require(actual.name in tracked,
                         f"Untracked source archive path: {actual.name}")
                _require(actual.type == expected.type,
                         f"Source archive type differs from HEAD: {actual.name}")
                _require(actual.isfile() or actual.issym(),
                         f"Unexpected source entry type: {actual.name}")
                if actual.issym():
                    _require(actual.linkname == expected.linkname,
                             f"Source symlink differs from HEAD: {actual.name}")
                else:
                    actual_stream = packaged.extractfile(actual)
                    expected_stream = reference.extractfile(expected)
                    _require(actual_stream is not None and expected_stream is not None,
                             f"Unreadable source: {actual.name}")
                    with actual_stream, expected_stream:
                        while True:
                            actual_chunk = actual_stream.read(1024 * 1024)
                            expected_chunk = expected_stream.read(1024 * 1024)
                            _require(actual_chunk == expected_chunk,
                                     f"Source archive bytes differ from HEAD: {actual.name}")
                            if not actual_chunk:
                                break
    return len(seen)


def verify(artifact: Path, repo: Path, *, min_sources: int = 500) -> dict:
    artifact = artifact.resolve(strict=True)
    # upload-artifact may retain the common 'ipa/' directory when it also
    # uploads matching Xcode dSYMs from the sibling iphoneos directory.
    packages = list(artifact.rglob("Lokal-unsigned.ipa"))
    _require(len(packages) == 1, "Expected exactly one unsigned IPA in artifact")
    artifact = packages[0].parent
    ipa = packages[0]
    sha_file = artifact / "Lokal-unsigned.ipa.sha256"
    manifest_file = artifact / "Lokal-unsigned.ipa.json"
    source = artifact / "Lokal-source.tar.gz"
    for entry in (ipa, sha_file, manifest_file, source):
        _require(entry.is_file(), f"Missing artifact member: {entry.name}")

    metadata = json.loads(manifest_file.read_text(encoding="utf-8"))
    _require(metadata.get("source_commit") == _git(repo, "rev-parse", "HEAD"),
             "Release source commit differs from checkout")
    _require(metadata.get("source_tree") == _git(repo, "rev-parse", "HEAD^{tree}"),
             "Release source tree differs from checkout")
    _require(metadata.get("minimum_ios") == "16.0", "Wrong minimum iOS")
    _require("Unsigned" in metadata.get("signing", ""), "Unexpected signing claim")
    _require("Engineering" in metadata.get("release_status", ""),
             "Unexpected public release claim")

    with ipa.open("rb") as handle:
        sha = hashlib.file_digest(handle, "sha256").hexdigest()
    _require(re.fullmatch(r"[0-9a-f]{64}", sha) is not None, "Bad IPA digest")
    _require(sha == metadata.get("sha256"), "IPA differs from metadata SHA-256")
    _require(
        sha_file.read_text(encoding="utf-8").strip()
        == f"{sha}  Lokal-unsigned.ipa",
        "IPA sidecar checksum mismatch",
    )

    with zipfile.ZipFile(ipa) as archive:
        names = set(archive.namelist())
        _require(archive.testzip() is None, "Corrupt IPA ZIP member")
        _require("Payload/Runner.app/Info.plist" in names, "Missing iPhone app plist")
        info = plistlib.loads(archive.read("Payload/Runner.app/Info.plist"))
        _require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
                 "Simulator binary packaged as iPhone release")
        _require(info.get("MinimumOSVersion") == "16.0", "IPA minimum iOS drift")
        _require(info.get("CFBundleIdentifier") == metadata.get("bundle_id"),
                 "Bundle ID differs from manifest")
        _require(info.get("CFBundleVersion") == metadata.get("build"),
                 "App build differs from manifest")
        _require(info.get("CFBundleShortVersionString") == metadata.get("version"),
                 "App version differs from manifest")
        binaries = metadata.get("binary_uuids")
        _require(isinstance(binaries, dict) and len(binaries) >= 1,
                 "Missing native binary inventory")
        _require(info.get("CFBundleExecutable") in binaries,
                 "Missing main executable in native inventory")
        for relative, uuids in binaries.items():
            _require(f"Payload/Runner.app/{relative}" in names,
                     f"Missing device binary: {relative}")
            _require(isinstance(uuids, list) and bool(uuids),
                     f"Missing binary UUID: {relative}")
        for relative in metadata.get("cast_resources_verified", []):
            package_path = f"Payload/Runner.app/{relative}".rstrip("/")
            _require(package_path in names or
                     any(name.startswith(package_path + "/") for name in names),
                     f"Missing Cast resource: {relative}")
        _require(not any(".appex/" in name for name in names),
                 "Unqualified iOS app extension is embedded")
        _require(any(name.startswith("Payload/Runner.app/Frameworks/")
                     for name in names), "Missing device frameworks")

    symbols = metadata.get("symbols", {})
    dsyms = symbols.get("matching_native_bundles", [])
    _require(bool(dsyms), "No matching native symbols recorded")
    for name in dsyms:
        _require(any(p.is_file() for p in (artifact / "Symbols" / name).rglob("*")),
                 f"Missing native debug bundle: {name}")
    for name in symbols.get("dart_aot_files", []):
        _require((artifact / "Symbols" / name).is_file(),
                 f"Missing Dart AOT symbols: {name}")

    tracked = _source_blobs(repo)
    source_count = _verify_source_export(source, repo, tracked)
    _require(source_count >= min_sources, "Incomplete source archive")
    _require(source_count >= int(len(tracked) * 0.95),
             "Unexpected number of unexported source files")
    return {
        "source_commit": metadata["source_commit"],
        "source_tree": metadata["source_tree"],
        "ipa_sha256": sha,
        "binaries": len(binaries),
        "native_dsyms": len(dsyms),
        "source_files_checked": source_count,
        "disposition": "Unsigned engineering package only",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    print(json.dumps(verify(args.artifact, args.repo), indent=2))


if __name__ == "__main__":
    main()
