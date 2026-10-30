#!/usr/bin/env python3
"""Run actual native SMB2 against an authenticated, loopback-only protocol fixture.

Install tool/requirements-smb-fixture.txt into a dedicated test environment.
This does not qualify Apple linkage or a particular NAS/security configuration.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import wave

from impacket.smbserver import SimpleSMBServer
from impacket.ntlm import compute_lmhash, compute_nthash

ROOT = Path(__file__).resolve().parents[1]
LINUX_SHA256 = '78f1a94ab977ab46ce5c8718f2f3f7fc0e0acf707863e14cfa5eb3a5e5119db2'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=shutil.which('dart'))
    parser.add_argument('--library', type=Path, required=True)
    args = parser.parse_args()
    if not args.dart: parser.error('Use the locked Dart SDK')
    library = args.library.resolve(strict=True)
    with library.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != LINUX_SHA256:
            parser.error('Use the pinned libsmb2 r8 Linux-x86_64 fixture binary')
    with tempfile.TemporaryDirectory(prefix='lokal-native-smb-') as directory:
        root = Path(directory)
        album = root / 'share/Album'
        album.mkdir(parents=True)
        with wave.open(str(album / 'Café # %.wav'), 'wb') as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
            audio.writeframes(b'\x00\x00' * 300000)
        (album / 'cover.jpg').write_bytes(bytes([1, 2, 3, 4]))
        with (album / 'oversized.jpg').open('wb') as cover:
            cover.truncate(12 * 1024 * 1024 + 1)
        server = SimpleSMBServer(listenAddress='127.0.0.1', listenPort=445)
        server.setSMB2Support(True)
        server.addShare('Music', str(root / 'share'), 'Synthetic fixture only', readOnly='yes')
        password = 'local-smb-fixture-only'
        server.addCredential('lokal-fixture', 0, compute_lmhash(password), compute_nthash(password))
        thread = threading.Thread(target=server.start, daemon=True)
        thread.start()
        environment = dict(os.environ)
        environment['LD_LIBRARY_PATH'] = str(library.parent) + os.pathsep + environment.get('LD_LIBRARY_PATH', '')
        try:
            subprocess.run([args.dart, '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                            str(ROOT / 'tool/smb_native_contracts.dart'), str(root)],
                           check=True, timeout=100, cwd=ROOT, env=environment)
        finally:
            server.getServer().shutdown()
            server.stop()
            thread.join(timeout=5)


if __name__ == '__main__': main()
