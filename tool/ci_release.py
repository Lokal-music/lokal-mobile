"""Release metadata, ephemeral signing and verified APK packaging (stdlib only)."""

import base64
import binascii
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

SECRETS = ("ANDROID_KEYSTORE_BASE64", "ANDROID_KEYSTORE_PASSWORD",
           "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")
MAX_VERSION_CODE = 2_100_000_000


def semantic_version(value):
    match = SEMVER.fullmatch(value)
    if not match or any(part.isdigit() and len(part) > 1 and part[0] == "0"
                        for part in (match[4] or "").split(".")):
        raise ValueError("Expected MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-prerelease")
    return value


def positive_number(value):
    if not re.fullmatch(r"[1-9][0-9]*", str(value)) or int(value) > MAX_VERSION_CODE:
        raise ValueError("Build number must be a positive Android versionCode (at most 2100000000)")
    return int(value)


def metadata(pubspec, ref="", run_number="", supplied="", flavor="both"):
    match = re.search(r"^version:\s*([^\s#]+)\s*(?:#.*)?$", pubspec, re.MULTILINE)
    if not match or "+" not in match[1]:
        raise ValueError("pubspec.yaml must have an explicit version and positive build number")
    version, build = match[1].rsplit("+", 1)
    semantic_version(version)
    base = positive_number(build)
    if ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
        if not tag.startswith("v"):
            raise ValueError("Release tags must start with v")
        version = semantic_version(tag[1:])
        original = match[1].rsplit("+", 1)[0]
        if version.split("-")[0] != original.split("-")[0]:
            raise ValueError("Tag MAJOR.MINOR.PATCH must match pubspec.yaml")
        if "-" in original and version != original:
            raise ValueError("A prerelease pubspec must match the tag exactly")
    default_build = base + (positive_number(run_number) if run_number else 0)
    code = positive_number(supplied) if supplied else positive_number(default_build)
    if code < default_build:
        raise ValueError("Supplied build number must be at least pubspec build + workflow run number")
    if flavor not in ("full", "play", "both"):
        raise ValueError("Flavor must be full, play or both")
    return {"version": version, "build_number": str(code),
            "prerelease": str("-" in version).lower(),
            "flavors": json.dumps(["full", "play"] if flavor == "both" else [flavor])}


def check_signing(env):
    missing = [name for name in SECRETS if not env.get(name)]
    if missing:
        raise ValueError("Missing required signing secrets: " + ", ".join(missing))


def signing_directory():
    return Path(os.environ["RUNNER_TEMP"]) / "konnekted-signing"


def cleanup():
    directory = signing_directory()
    if directory.exists():
        shutil.rmtree(directory)


@contextmanager
def signing_material(env, directory):
    check_signing(env)
    directory.mkdir(mode=0o700)  # A stale directory is an error, never silently reused.
    try:
        try:
            decoded = base64.b64decode("".join(env[SECRETS[0]].split()), validate=True)
        except (ValueError, binascii.Error):
            raise ValueError("ANDROID_KEYSTORE_BASE64 is not valid base64") from None
        if not decoded:
            raise ValueError("ANDROID_KEYSTORE_BASE64 decoded to an empty keystore")
        path = directory / "release.keystore"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(decoded)
        child_env = dict(env)
        child_env.pop("ANDROID_KEYSTORE_BASE64", None)
        child_env["ANDROID_KEYSTORE_PATH"] = str(path.resolve())
        yield child_env
    finally:
        shutil.rmtree(directory)


def package_apk(apk, destination, flavor, version, code, env, certificate):
    # Signature verification is mandatory before any uploadable output is made.
    tools = Path(env["ANDROID_HOME"]) / "build-tools/36.0.0"
    safe_env = {key: value for key, value in env.items() if key not in SECRETS}
    verification = subprocess.check_output(
        [str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)],
        env=safe_env, text=True)
    signers = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", verification)
    if [signer.lower() for signer in signers] != [certificate]:
        raise ValueError("APK was not signed exclusively by the supplied release key")
    badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)],
                                     env=safe_env, text=True)
    if (f"versionCode='{code}'" not in badging or f"versionName='{version}'" not in badging
            or "name='com.lokalkonnekt.konnekted2'" not in badging):
        raise ValueError("APK package/version metadata did not match the requested release")
    with zipfile.ZipFile(apk) as archive:
        # A valid signature and manifest do not verify every compressed entry.
        # Catch corrupt/truncated payloads before copying them to Releases.
        bad_entry = archive.testzip()
        if bad_entry is not None:
            raise ValueError(f"APK has a corrupt ZIP entry: {bad_entry}")
        # Fail closed: ship all required native libraries for ARM64, and no
        # second ABI that would inflate the download or confuse installers.
        native_entries = [entry for entry in archive.namelist()
                          if entry.startswith("lib/") and entry.endswith(".so")]
        packaged_abis = {entry.split("/")[1] for entry in native_entries}
        if packaged_abis != {"arm64-v8a"}:
            raise ValueError(f"APK must contain only arm64-v8a native libraries: {sorted(packaged_abis)}")
        for library in ("librust_lib_flick_player.so", "libflutter.so", "libapp.so",
                        "libmornye_discord.so", "libdiscord_partner_sdk.so"):
            if f"lib/arm64-v8a/{library}" not in archive.namelist():
                raise ValueError(f"APK is missing arm64-v8a/{library}")
        for notice in ("Discord-License-Notices.txt", "Mornye-Discord-Bridge-License.txt"):
            if f"assets/{notice}" not in archive.namelist():
                raise ValueError(f"APK is missing {notice}")
    destination.mkdir(exist_ok=True)
    variant = "-Play" if flavor == "play" else ""
    name = f"Lokal-{version}{variant}-arm64.apk"
    output = destination / name
    shutil.copyfile(apk, output)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    (destination / f"SHA256SUMS-{flavor}.txt").write_text(f"{digest}  {name}\n")
    (destination / f"{flavor}-metadata.json").write_text(json.dumps({
        "version": version, "versionCode": code, "flavor": flavor,
        "abis": ["arm64-v8a"], "sha256": digest,
        "signingCertificateSha256": certificate,
        "commit": env.get("GITHUB_SHA"), "run_id": env.get("GITHUB_RUN_ID"),
        "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "flutter": "3.47.1", "dart": "3.13.1", "rust": "1.98.0",
        "ndk": "28.2.13676358", "discordSocialSdk": "1.10.19337",
    }, indent=2) + "\n")



def package_play_bundle(bundle, destination, version, code, env, certificate):
    """Verify a Play-uploadable AAB without changing the GitHub APK releases."""
    safe_env = {key: value for key, value in env.items() if key not in SECRETS}
    verification = subprocess.check_output(
        ["jarsigner", "-verify", "-verbose", str(bundle)], env=safe_env, text=True)
    if "jar verified." not in verification:
        raise ValueError("Play app bundle failed JAR signature verification")
    certificates = subprocess.check_output(
        ["keytool", "-printcert", "-jarfile", str(bundle)], env=safe_env, text=True)
    fingerprints = re.findall(
        r"(?m)^\s*SHA256:\s*((?:[0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}|[0-9a-fA-F]{64})\s*$",
        certificates)
    if [value.replace(":", "").lower() for value in fingerprints] != [certificate]:
        raise ValueError("Play app bundle was not signed exclusively by the supplied release key")

    with zipfile.ZipFile(bundle) as archive:
        bad_entry = archive.testzip()
        if bad_entry is not None:
            raise ValueError(f"Play app bundle has a corrupt ZIP entry: {bad_entry}")
        entries = set(archive.namelist())
        if not {"BundleConfig.pb", "base/manifest/AndroidManifest.xml"} <= entries:
            raise ValueError("Play app bundle is missing required bundle metadata")
        native_entries = [entry for entry in entries
                          if entry.startswith("base/lib/") and entry.endswith(".so")]
        packaged_abis = {entry.split("/")[2] for entry in native_entries}
        if packaged_abis != {"arm64-v8a"}:
            raise ValueError(f"Play app bundle must contain only arm64-v8a: {sorted(packaged_abis)}")
        for library in ("librust_lib_flick_player.so", "libflutter.so", "libapp.so",
                        "libmornye_discord.so", "libdiscord_partner_sdk.so"):
            if f"base/lib/arm64-v8a/{library}" not in entries:
                raise ValueError(f"Play app bundle is missing arm64-v8a/{library}")

    # The corresponding Play APK was built in the same invocation with the
    # same release signing key, package identity, version name and code.
    destination.mkdir(exist_ok=True)
    name = f"Lokal-{version}-Play.aab"
    output = destination / name
    shutil.copyfile(bundle, output)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    # Different filename pattern from SHA256SUMS-*.txt: GitHub release notes
    # currently publish APKs only. The AAB is an Actions artifact for Play Console.
    (destination / f"{name}.sha256").write_text(f"{digest}  {name}\n")



def build():
    env = dict(os.environ)
    flavor = env["RELEASE_FLAVOR"]
    if flavor not in ("full", "play"):
        raise ValueError("Build requires a single full or play flavor")
    version = semantic_version(env["RELEASE_VERSION"])
    code = positive_number(env["RELEASE_BUILD_NUMBER"])
    apk = Path(f"build/app/outputs/flutter-apk/app-{flavor}-release.apk")
    bundle = Path("build/app/outputs/bundle/playRelease/app-play-release.aab")
    if apk.exists() or (flavor == "play" and bundle.exists()):
        raise ValueError("Refusing to reuse an existing release artifact; start from a clean checkout")
    with signing_material(env, signing_directory()) as child_env:
        certificate = hashlib.sha256(subprocess.check_output([
            "keytool", "-exportcert", "-keystore", child_env["ANDROID_KEYSTORE_PATH"],
            "-alias", child_env["ANDROID_KEY_ALIAS"],
            "-storepass:env", "ANDROID_KEYSTORE_PASSWORD",
        ], env=child_env, stderr=subprocess.PIPE)).hexdigest()
        # Flutter 3.47 also skips release plugin registration with --no-pub.
        # Regenerate it here so dev-only plugins (integration_test) are excluded
        # from both the Java registrant and the release Gradle dependencies.
        subprocess.run([
            "flutter", "build", "apk", "--release", "--flavor", flavor,
            "--target-platform", "android-arm64",
            "--build-name", version, "--build-number", str(code),
        ], env=child_env, check=True)
        if flavor == "play":
            # A GitHub-hosted Play APK is still sideloaded. Only an app installed
            # via a trusted Google Play track avoids Android Auto's Unknown sources.
            subprocess.run([
                "flutter", "build", "appbundle", "--release", "--flavor", "play",
                "--target-platform", "android-arm64",
                "--build-name", version, "--build-number", str(code),
            ], env=child_env, check=True)
    # Secrets are no longer needed by verification or packaging.
    destination = Path(env["RUNNER_TEMP"]) / "konnekted-release"
    package_apk(apk, destination, flavor, version, code, env, certificate)
    if flavor == "play":
        package_play_bundle(bundle, destination, version, code, env, certificate)


def main():
    command = sys.argv[1]
    if command == "metadata":
        values = metadata(Path("pubspec.yaml").read_text(), os.environ.get("GITHUB_REF", ""),
                          os.environ.get("GITHUB_RUN_NUMBER", ""),
                          os.environ.get("RELEASE_BUILD_NUMBER", ""),
                          os.environ.get("RELEASE_FLAVOR", "both"))
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")
    elif command == "check-signing":
        check_signing(os.environ)
    elif command == "build":
        build()
    elif command == "cleanup":
        cleanup()
    else:
        raise ValueError("Unknown release helper command")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Do not render subprocess arguments/environment; they may contain secrets.
        sys.exit(f"Release command failed with exit status {error.returncode}")
    except ValueError as error:
        sys.exit(str(error))
    except OSError:
        sys.exit("Release file/tool operation failed; check installed prerequisites and permissions")
