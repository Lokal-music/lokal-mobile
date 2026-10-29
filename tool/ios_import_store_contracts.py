#!/usr/bin/env python3
"""Exercise the real Isar receipt store and induced child-process exits.

Pure Dart + the locked package's actual native core; no Flutter storage mock.
This does not qualify the product adapter, native lease RPC or media decoder.
"""
import argparse
import hashlib
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
    parser.add_argument('--coordinator', action='store_true')
    parser.add_argument('--ffprobe', help='Actual host FFprobe for coordinator media contracts.')
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
        script = 'ios_import_coordinator_contracts.dart' if args.coordinator else 'ios_import_store_contracts.dart'
        extra = ['--ffprobe', args.ffprobe] if args.ffprobe else []
        if not args.coordinator:
            legacy = Path(directory) / 'legacy-private-media'
            legacy.mkdir()
            job = json.loads((ROOT / 'test/fixtures/ios_transfer_intents_v1.json').read_text())[0]
            job['metadata']['fileExtension'] = 'wav'
            payload = audio.read_bytes()
            job.update(revision=1, direction='download', updatedMs=2000,
                       expectedBytes=len(payload), expectedSHA256=hashlib.sha256(payload).hexdigest(),
                       receivedBytes=len(payload), receivedSHA256=hashlib.sha256(payload).hexdigest())
            (legacy / 'job.json').write_text(json.dumps(job))
            subprocess.run([args.dart, '--packages=' + str(config),
                            str(ROOT / 'tool/ios_import_legacy_schema.dart'),
                            '--isar-library', str(library.resolve()), '--directory', str(legacy)],
                           check=True, timeout=60, cwd=ROOT)
            extra += ['--legacy-root', str(legacy)]
        subprocess.run([args.dart, '--packages=' + str(config),
                        str(ROOT / 'tool' / script),
                        '--isar-library', str(library.resolve()), '--audio', str(audio), *extra],
                       check=True, timeout=240, cwd=ROOT)


if __name__ == '__main__':
    main()
