#!/usr/bin/env python3
"""Exercise the real Isar receipt store and induced child-process exits.

Pure Dart + the locked package's actual native core; no Flutter storage mock.
This does not qualify the product adapter, native lease RPC or media decoder.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

from ios_transfer_fixture import audio_bytes

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=shutil.which('dart'))
    parser.add_argument('--isar-library', type=Path)
    args = parser.parse_args()
    if not args.dart:
        parser.error('Install the locked Flutter/Dart toolchain or pass --dart.')
    config = ROOT / '.dart_tool/package_config.json'
    library = args.isar_library
    if library is None:
        package = next(row for row in json.loads(config.read_text())['packages']
                       if row['name'] == 'isar_community_flutter_libs')
        uri = urllib.parse.urljoin(config.as_uri(), package['rootUri'])
        if urllib.parse.urlparse(uri).scheme != 'file':
            parser.error('The locked native package must be local.')
        package_root = Path(urllib.request.url2pathname(urllib.parse.urlparse(uri).path))
        relative = {'linux': 'linux/libisar.so', 'darwin': 'macos/libisar.dylib',
                    'win32': 'windows/isar.dll'}.get(sys.platform)
        if relative is None:
            parser.error('Use a supported native Isar host.')
        library = package_root / relative
    if not library.is_file():
        parser.error('The actual native Isar library is unavailable.')
    with tempfile.TemporaryDirectory(prefix='lokal-import-database-') as directory:
        audio = Path(directory) / 'Generated fixture.wav'
        audio.write_bytes(audio_bytes())
        subprocess.run([args.dart, '--packages=' + str(config),
                        str(ROOT / 'tool/ios_import_store_contracts.dart'),
                        '--isar-library', str(library.resolve()), '--audio', str(audio)],
                       check=True, timeout=240, cwd=ROOT)


if __name__ == '__main__':
    main()
