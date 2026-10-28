#!/usr/bin/env python3
"""Compile/run real transfer storage contracts; optionally check iOS 16 SDKs.

Linux Foundation tests establish journal/file behavior, not URLSession execution,
background delivery, installed-app access or physical-device acceptance.
"""

import argparse
import pathlib
import shutil
import subprocess
import tempfile
import sys

from ios_transfer_fixture import serve_fixture


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / 'ios/Transfers/Contracts/LokalTransferJob.swift',
    ROOT / 'ios/Transfers/Storage/LokalTransferJournal.swift',
    ROOT / 'ios/Transfers/Files/LokalTransferFiles.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferRequest.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferCredentials.swift',
    ROOT / 'ios/Transfers/Networking/LokalTransferRuntime.swift',
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=shutil.which('swiftc'))
    parser.add_argument('--check-ios-sdks', action='store_true')
    parser.add_argument('--sqlite-include', type=pathlib.Path)
    parser.add_argument('--sqlite-library-dir', type=pathlib.Path)
    args = parser.parse_args()
    if not args.swiftc:
        parser.error('Pass an installed Swift compiler with --swiftc or put swiftc on PATH.')
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
        subprocess.run([*command, *map(str, SOURCES),
                        str(ROOT / 'ios/Transfers/Tests/NetworkContracts.swift'),
                        str(ROOT / 'ios/Transfers/Tests/main.swift'),
                        '-o', str(binary)], check=True, timeout=180)
        with serve_fixture() as (origin, length, checksum):
            subprocess.run([str(binary), '--network-fixture', origin, str(length), checksum],
                           check=True, timeout=120, cwd=ROOT)
        if args.check_ios_sdks:
            for sdk, target in [('iphoneos', 'arm64-apple-ios16.0'),
                                ('iphonesimulator', 'arm64-apple-ios16.0-simulator')]:
                sdk_path = subprocess.check_output(
                    ['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
                subprocess.run([*command, '-target', target, '-sdk', sdk_path,
                                '-typecheck', *map(str, SOURCES)], check=True,
                               timeout=120)
                print(f'Transfer journal SDK type check passed: {target}', flush=True)


if __name__ == '__main__':
    main()
