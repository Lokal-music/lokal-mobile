#!/usr/bin/env python3
"""Stage and inspect the checksum-pinned libsmb2 Apple framework before CocoaPods.

Flutter uses local development pods, whose prepare_command is not guaranteed to
run. This stages only generated framework outputs; package sources stay intact.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import tempfile
import urllib.parse
import zipfile

from ios_prepare_ffmpeg import download_verified

URL = 'https://github.com/ales-drnz/dart_smb2/releases/download/libsmb2-r8/libsmb2_ios.xcframework.zip'
SHA256 = 'c9b05f037865affe0ebdac71a0013e1b53e72ad007b5f3a00331eeeb56ba43f1'
FRAMEWORK = 'libsmb2.xcframework'


def inspect_binary(data: bytes, *, platform: int, architectures: set[int], symbols: set[str]) -> None:
    slices = [(0, len(data))]
    if data[:4] == bytes.fromhex('cafebabe'):
        count = struct.unpack_from('>I', data, 4)[0]
        if count > 8: raise ValueError('Too many SMB Mach-O slices')
        slices = [struct.unpack_from('>IIIII', data, 8 + i * 20)[2:4] for i in range(count)]
    seen = set()
    for offset, size in slices:
        if offset < 0 or size < 32 or offset + size > len(data): raise ValueError('Invalid SMB binary slice')
        binary = data[offset:offset + size]
        magic, cpu, _, kind, count, command_bytes, _, _ = struct.unpack_from('<8I', binary)
        if magic != 0xfeedfacf or kind != 6 or 32 + command_bytes > len(binary):
            raise ValueError('SMB must be a dynamic 64-bit Mach-O framework')
        seen.add(cpu)
        position = 32
        build = None
        install_name = None
        table = None
        for _ in range(count):
            command, length = struct.unpack_from('<II', binary, position)
            if length < 8 or position + length > 32 + command_bytes: raise ValueError('Invalid SMB load command')
            if command == 0x32:
                build = struct.unpack_from('<II', binary, position + 8)
            if command in {0xc, 0xd, 0x80000018, 0x8000001f}:
                start = struct.unpack_from('<I', binary, position + 8)[0]
                value = binary[position + start:position + length].split(b'\0')[0].decode()
                if command == 0xd:
                    install_name = value
                elif not value.startswith(('/usr/lib/', '/System/Library/')):
                    raise ValueError(f'Unbundled SMB native dependency: {value}')
            if command == 2: table = struct.unpack_from('<4I', binary, position + 8)
            position += length
        if build is None or build[0] != platform or build[1] > 16 << 16:
            raise ValueError('SMB binary platform/minimum iOS mismatch')
        if install_name != '@rpath/libsmb2.framework/libsmb2' or table is None:
            raise ValueError('SMB install name or symbols missing')
        symbol_offset, symbol_count, strings_offset, strings_size = table
        if symbol_offset + 16 * symbol_count > len(binary) or strings_offset + strings_size > len(binary):
            raise ValueError('Invalid SMB symbol inventory')
        strings = binary[strings_offset:strings_offset + strings_size]
        exported = set()
        for i in range(symbol_count):
            index, flags, _, _, _ = struct.unpack_from('<IBBHQ', binary, symbol_offset + i * 16)
            if flags & 1 and flags & 0x0e and index < len(strings):
                exported.add(strings[index:].split(b'\0')[0].decode())
        if not {'_' + name for name in symbols} <= exported:
            raise ValueError('SMB framework lacks required Dart FFI symbols')
    if seen != architectures: raise ValueError('SMB framework architecture mismatch')


def stage(archive: Path, destination: Path, symbols: set[str]) -> None:
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != SHA256:
            raise ValueError('SMB archive checksum mismatch')
    with zipfile.ZipFile(archive) as source:
        total = 0
        for entry in source.infolist():
            path = PurePosixPath(entry.filename)
            total += entry.file_size
            if (path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != FRAMEWORK
                    or stat.S_ISLNK(entry.external_attr >> 16) or total > 16 * 1024 * 1024):
                raise ValueError('Unsafe SMB framework archive')
        with tempfile.TemporaryDirectory(prefix='lokal-smb-framework-') as work:
            source.extractall(work)
            framework = Path(work) / FRAMEWORK
            info = plistlib.loads((framework / 'Info.plist').read_bytes())
            libraries = info['AvailableLibraries']
            expected = {'ios-arm64': (2, {0x100000c}),
                        'ios-arm64_x86_64-simulator': (7, {0x100000c, 0x1000007})}
            if {item['LibraryIdentifier'] for item in libraries} != set(expected):
                raise ValueError('Unexpected SMB framework slices')
            for item in libraries:
                identifier = item['LibraryIdentifier']
                if item['LibraryPath'] != 'libsmb2.framework' or item['SupportedPlatform'] != 'ios':
                    raise ValueError('Invalid SMB framework layout')
                binary = framework / identifier / 'libsmb2.framework/libsmb2'
                inspect_binary(binary.read_bytes(), platform=expected[identifier][0],
                               architectures=expected[identifier][1], symbols=symbols)
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / FRAMEWORK
            if target.exists(): shutil.rmtree(target)
            shutil.copytree(framework, target)


def main() -> None:
    config = Path('.dart_tool/package_config.json').resolve()
    package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'dart_smb2')
    uri = urllib.parse.urlparse(urllib.parse.urljoin(config.as_uri(), package['rootUri']))
    if uri.scheme != 'file': raise ValueError('SMB must use the local locked Pub package')
    plugin = Path(urllib.parse.unquote(uri.path))
    if re.search(r'^version:\s*(\S+)', (plugin / 'pubspec.yaml').read_text(), re.M).group(1) != '0.1.3':
        raise ValueError('Review and repin the new SMB plugin version')
    client = (plugin / 'lib/src/smb2_client.dart').read_text()
    symbols = set(re.findall(r'_native\.(smb2_\w+)', client))
    symbols.update({'smb2_init_context', 'smb2_destroy_context'})
    archive = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'libsmb2-ios-r8.zip'
    download_verified(URL, archive, SHA256)
    stage(archive, plugin / 'ios/dart_smb2/Frameworks', symbols)
    print(f'Verified libsmb2 r8 device/simulator slices and {len(symbols)} FFI exports: {SHA256}')


if __name__ == '__main__': main()
