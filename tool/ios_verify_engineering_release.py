#!/usr/bin/env python3
"""Independently verify a downloaded unsigned iPhone engineering artifact.

This verifies byte identity, source contents and packaged symbols, not Apple
signing, device installation, codec capabilities or public release readiness.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
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


def _blob_hash(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def verify(artifact: Path, repo: Path, *, min_sources: int = 500) -> dict:
    artifact = artifact.resolve(strict=True)
    ipa = artifact / "Lokal-unsigned.ipa"
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
    seen: set[str] = set()
    with tarfile.open(source, "r:gz") as archive:
        for entry in archive:
            if entry.isdir():
                continue
            _require(entry.isfile() or entry.issym(),
                     f"Unexpected source entry type: {entry.name}")
            _require(entry.name not in seen, f"Duplicate source path: {entry.name}")
            seen.add(entry.name)
            expected = tracked.get(entry.name)
            _require(expected is not None, f"Untracked source archive path: {entry.name}")
            if entry.issym():
                data = entry.linkname.encode("utf-8", "surrogateescape")
            else:
                handle = archive.extractfile(entry)
                _require(handle is not None, f"Unreadable source: {entry.name}")
                data = handle.read()
            _require(_blob_hash(data) == expected,
                     f"Source archive bytes differ from HEAD: {entry.name}")
    _require(len(seen) >= min_sources, "Incomplete source archive")
    _require(len(seen) >= int(len(tracked) * 0.95),
             "Unexpected number of unexported source files")
    return {
        "source_commit": metadata["source_commit"],
        "source_tree": metadata["source_tree"],
        "ipa_sha256": sha,
        "binaries": len(binaries),
        "native_dsyms": len(dsyms),
        "source_files_checked": len(seen),
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
