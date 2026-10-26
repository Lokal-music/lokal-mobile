#!/usr/bin/env python3
"""Pin the native archive used by the locked FFmpeg plugin's CocoaPods setup."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import urllib.parse
import urllib.request

URL = 'https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/8.1.2-audio/ffmpeg-kit-ios-audio-8.1.2.zip'
SHA256 = '63da3becdd2c7cefd77292054683e4f9b712efd09a4d8a8b2319d92f9fbcdd30'

config = Path('.dart_tool/package_config.json').resolve()
packages = json.loads(config.read_text())['packages']
package = next(p for p in packages if p['name'] == 'ffmpeg_kit_flutter_new_audio')
uri = urllib.parse.urljoin(config.as_uri(), package['rootUri'])
if urllib.parse.urlparse(uri).scheme != 'file':
    raise SystemExit('FFmpeg must resolve to a local locked Pub package')
plugin = Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path))
version = re.search(r'^version:\s*(\S+)', (plugin / 'pubspec.yaml').read_text(), re.M)
if version is None or version.group(1) != '2.5.7':
    raise SystemExit('Review and repin FFmpeg native provenance for the new plugin version')
archive = Path(os.environ['RUNNER_TEMP']) / 'ffmpeg-kit-ios-audio-8.1.2.zip'
with urllib.request.urlopen(URL, timeout=30) as source, archive.open('wb') as target:
    shutil.copyfileobj(source, target)
with archive.open('rb') as source:
    actual = hashlib.file_digest(source, 'sha256').hexdigest()
if actual != SHA256:
    archive.unlink()
    raise SystemExit(f'FFmpeg native archive checksum mismatch: {actual}')

# Pub caches may contain generated frameworks from an earlier job. Regenerate
# those outputs from the verified archive; preserve all package source files.
frameworks = plugin / 'ios/Frameworks'
if frameworks.exists():
    shutil.rmtree(frameworks)
with open(os.environ['GITHUB_ENV'], 'a') as environment:
    environment.write(f'FFMPEG_KIT_IOS_URL={archive.as_uri()}\n')
    environment.write(f'LOKAL_FFMPEG_IOS_SHA256={SHA256}\n')
print(f'Verified FFmpeg 8.1.2 audio iOS archive: {SHA256}')
