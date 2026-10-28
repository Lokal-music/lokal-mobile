#!/usr/bin/env python3
"""Compile/run real transfer storage contracts; optionally check iOS 16 SDKs.

Portable Foundation tests establish actual journal/file/HTTP delegate behavior,
not Apple background delivery, installed-app access or physical-device acceptance.
"""

import argparse
import pathlib
import shutil
import subprocess
import tempfile
import sys
import os
import plistlib

from ios_transfer_fixture import serve_fixture


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / 'ios/Transfers/Contracts/LokalTransferJob.swift',
    ROOT / 'ios/Transfers/Contracts/LokalTransferProtocol.swift',
    ROOT / 'ios/Transfers/Storage/LokalTransferJournal.swift',
    ROOT / 'ios/Transfers/Files/LokalTransferFiles.swift',
    ROOT / 'ios/Transfers/Files/LokalTransferLibrary.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferRequest.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferCredentials.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferRuntime.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferHost.swift',
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=shutil.which('swiftc'))
    parser.add_argument('--check-ios-sdks', action='store_true')
    parser.add_argument('--check-flutter-bridge', action='store_true',
                        help='Also type-check the real Flutter/UIKit bridge in both iOS SDKs.')
    parser.add_argument('--sqlite-include', type=pathlib.Path)
    parser.add_argument('--sqlite-library-dir', type=pathlib.Path)
    parser.add_argument('--repeat-native', type=int, default=1,
                        help='Repeat actual file/process/HTTP contracts (1–20 rounds).')
    args = parser.parse_args()
    if not args.swiftc:
        parser.error('Pass an installed Swift compiler with --swiftc or put swiftc on PATH.')
    if not 1 <= args.repeat_native <= 20:
        parser.error('--repeat-native must be between 1 and 20.')
    if args.check_flutter_bridge and not args.check_ios_sdks:
        parser.error('--check-flutter-bridge requires --check-ios-sdks.')
    with tempfile.TemporaryDirectory(prefix='lokal-transfer-contracts-') as temporary:
        output = pathlib.Path(temporary)
        binary = output / 'transfer-contracts'
        command = [args.swiftc, '-swift-version', '6', '-warnings-as-errors',
                   '-module-cache-path', str(output / 'modules')]
        if sys.platform.startswith('linux'):
            command += ['-I', str(ROOT / 'ios/Transfers/LinuxSupport/SQLite3')]
            if args.sqlite_include:
                command += ['-Xcc', '-I' + str(args.sqlite_include)]
            if args.sqlite_library_dir:
                command += ['-L', str(args.sqlite_library_dir)]
        sdk_failed = False
        if args.check_ios_sdks:
            for sdk, target in [('iphoneos', 'arm64-apple-ios16.0'),
                                ('iphonesimulator', 'arm64-apple-ios16.0-simulator')]:
                sdk_path = subprocess.check_output(
                    ['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
                checked = subprocess.run(
                    [*command, '-target', target, '-sdk', sdk_path,
                     '-typecheck', *map(str, SOURCES)],
                    check=False, timeout=120)
                sdk_failed |= checked.returncode != 0
                status = 'passed' if checked.returncode == 0 else 'FAILED'
                print(f'Transfer SDK type check {status}: {target}', flush=True)
                if args.check_flutter_bridge:
                    flutter_root = os.environ.get('FLUTTER_ROOT')
                    if not flutter_root:
                        parser.error('FLUTTER_ROOT must identify the installed Flutter SDK.')
                    engine = pathlib.Path(flutter_root) / 'bin/cache/artifacts/engine/ios/Flutter.xcframework'
                    with (engine / 'Info.plist').open('rb') as source:
                        libraries = plistlib.load(source)['AvailableLibraries']
                    variant = 'simulator' if sdk == 'iphonesimulator' else None
                    item = next(row for row in libraries
                                if row['SupportedPlatform'] == 'ios'
                                and row.get('SupportedPlatformVariant') == variant
                                and 'arm64' in row['SupportedArchitectures'])
                    framework = (engine / item['LibraryIdentifier']).resolve()
                    if not framework.is_relative_to(engine.resolve()):
                        raise ValueError('Flutter framework is outside its installed SDK.')
                    bridge = subprocess.run(
                        [*command, '-target', target, '-sdk', sdk_path,
                         '-F', str(framework), '-typecheck', *map(str, SOURCES),
                         str(ROOT / 'ios/Runner/LokalTransferBridge.swift')],
                        check=False, timeout=180)
                    sdk_failed |= bridge.returncode != 0
                    status = 'passed' if bridge.returncode == 0 else 'FAILED'
                    print(f'Transfer Flutter bridge SDK check {status}: {target}', flush=True)
        subprocess.run([*command, *map(str, SOURCES),
                        str(ROOT / 'ios/Transfers/Tests/NetworkContracts.swift'),
                        str(ROOT / 'ios/Transfers/Tests/LibraryContracts.swift'),
                        str(ROOT / 'ios/Transfers/Tests/main.swift'),
                        '-o', str(binary)], check=True, timeout=180)
        for round_index in range(args.repeat_native):
            with serve_fixture() as (origin, length, checksum):
                subprocess.run([str(binary), '--network-fixture', origin, str(length), checksum],
                               check=True, timeout=120, cwd=ROOT)
            print(f'Native transfer contract round {round_index + 1}/{args.repeat_native} passed.', flush=True)
        if sdk_failed:
            raise SystemExit('One or more iOS SDK type checks failed.')


if __name__ == '__main__':
    main()
