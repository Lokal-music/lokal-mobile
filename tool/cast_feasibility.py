#!/usr/bin/env python3
"""Compile/link the real pinned Cast SDK for Apple device and simulator.

No receiver discovery, account auth, application integration, or installation is
executed by this probe. It does not change the app's deployment configuration.
"""
import json
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess

SDK_REVISION = '543701c0bea92cfea527fce2fde3b82ee73f2902'
SDK_ARCHIVE_SHA256 = 'e1fe7fd6f2bf4b58e830d378fafc435d159bd755f7ee20fd3033aa1ce313cd6e'

PACKAGE = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LokalCastProbe",
    platforms: [.iOS(.v16)],
    products: [.library(name: "LokalCastProbe", type: .dynamic, targets: ["LokalCastProbe"])],
    dependencies: [.package(url: "https://github.com/googlecast/google-cast-ios-sdk.git", revision: "%s")],
    targets: [.target(name: "LokalCastProbe", dependencies: [
        .product(name: "GoogleCastStatic", package: "google-cast-ios-sdk")
    ])]
)
''' % SDK_REVISION

SOURCE = '''import Foundation
import GoogleCast

// Real SDK symbols: these functions are compiled and linked, never invoked.
@MainActor public func makeLokalCastOptions() -> GCKCastOptions {
    let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
    let options = GCKCastOptions(discoveryCriteria: criteria)
    options.disableDiscoveryAutostart = true
    options.startDiscoveryAfterFirstTapOnCastButton = false
    options.physicalVolumeButtonsWillControlDeviceVolume = false
    return options
}

@MainActor public func configureLokalCastSession() -> GCKSessionManager {
    GCKCastContext.setSharedInstanceWith(makeLokalCastOptions())
    return GCKCastContext.sharedInstance().sessionManager
}

@MainActor public func probeLokalCastDiscovery(_ manager: GCKDiscoveryManager) {
    manager.startDiscovery()
    manager.stopDiscovery()
}

@MainActor public func probeLokalCastPosition(_ client: GCKRemoteMediaClient) -> TimeInterval? {
    client.mediaStatus?.streamPosition
}
'''


def run(args, *, cwd, log=None, timeout=900):
    if log:
        with log.open('w') as output:
            subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
        return ''
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=timeout)


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('This compile/link probe needs macOS and Xcode; use its hosted workflow.')
    root = Path(os.environ['RUNNER_TEMP']) / 'lokal-cast-probe'
    root.mkdir(parents=True, exist_ok=False)
    package = root / 'Package.swift'
    package.write_text(PACKAGE)
    source = root / 'Sources/LokalCastProbe/Probe.swift'
    source.parent.mkdir(parents=True)
    source.write_text(SOURCE)
    controller = Path(__file__).resolve().parents[1] / 'ios/Runner/LokalCastController.swift'
    adapter = source.parent / controller.name
    adapter.write_bytes(controller.read_bytes())
    report = {
        'scope': 'Real Cast SDK Swift compile/link only; no runtime, receiver or app acceptance',
        'sdk_revision': SDK_REVISION,
        'sdk_version': '4.8.6',
        'sdk_static_archive_sha256': SDK_ARCHIVE_SHA256,
        'deployment_target': '16.0',
        'adapter_sha256': hashlib.sha256(adapter.read_bytes()).hexdigest(),
        'adapter_scope': 'Production sender transport compiled; not invoked by this probe',
        'source_commit': os.environ.get('GITHUB_SHA'),
        'run_id': os.environ.get('GITHUB_RUN_ID'),
        'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
        'targets': {},
    }
    report_path = root / 'cast-probe-report.json'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    for sdk, destination, expected in [
        ('iphoneos', 'generic/platform=iOS', 'IOS'),
        ('iphonesimulator', 'generic/platform=iOS Simulator', 'IOSSIMULATOR'),
    ]:
        derived = root / f'derived-{sdk}'
        run(['xcodebuild', '-scheme', 'LokalCastProbe', '-configuration', 'Release',
             '-sdk', sdk, '-destination', destination,
             '-derivedDataPath', str(derived), '-clonedSourcePackagesDirPath', str(root / 'packages'),
             'CODE_SIGNING_ALLOWED=NO', 'IPHONEOS_DEPLOYMENT_TARGET=16.0',
             'ONLY_ACTIVE_ARCH=YES', 'ARCHS=arm64', 'build'],
            cwd=root, log=root / f'build-{sdk}.log')
        products = derived / 'Build/Products'
        binaries = [p for p in products.rglob('*') if p.is_file() and
                    p.name in ('LokalCastProbe', 'libLokalCastProbe.dylib') and
                    not any(part.endswith('.dSYM') for part in p.parts)]
        if not binaries:
            raise RuntimeError(f'No linked {sdk} probe product; inspect build-{sdk}.log')
        evidence = []
        for binary in binaries:
            archs = run(['xcrun', 'lipo', '-archs', str(binary)], cwd=root).split()
            build = run(['xcrun', 'vtool', '-show-build', str(binary)], cwd=root)
            platforms = re.findall(r'^\s*platform\s+(\S+)', build, re.M)
            if archs != ['arm64'] or not platforms or any(p != expected for p in platforms):
                raise RuntimeError(f'Unexpected probe binary platform/architecture: {binary}')
            evidence.append({'binary': str(binary.relative_to(root)), 'architectures': archs,
                             'build_commands': build})
        report['targets'][sdk] = {'compile_and_link': 'passed', 'evidence': evidence}
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
