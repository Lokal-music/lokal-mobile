#!/usr/bin/env python3
"""Pin the native archive used by the locked FFmpeg plugin's CocoaPods setup."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request

URL = 'https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/8.1.2-audio/ffmpeg-kit-ios-audio-8.1.2.zip'
SHA256 = '63da3becdd2c7cefd77292054683e4f9b712efd09a4d8a8b2319d92f9fbcdd30'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def download_verified(url, archive, expected_sha, *, opener=urllib.request.urlopen,
                      pause=time.sleep, attempts=3):
    """Retry transient transport failures; never retry or accept a bad digest."""
    if archive.is_file():
        if digest(archive) == expected_sha:
            return
        archive.unlink()
    partial = archive.with_name(archive.name + '.part')
    for attempt in range(1, attempts + 1):
        try:
            with opener(url, timeout=30) as source, partial.open('wb') as target:
                shutil.copyfileobj(source, target)
            actual = digest(partial)
            if actual != expected_sha:
                raise ValueError(f'FFmpeg native archive checksum mismatch: {actual}')
            partial.replace(archive)
            return
        except (urllib.error.URLError, TimeoutError, ConnectionError,
                http.client.IncompleteRead) as error:
            partial.unlink(missing_ok=True)
            if isinstance(error, urllib.error.HTTPError) and error.code not in {
                408, 429, 500, 502, 503, 504,
            }:
                raise
            if attempt == attempts:
                raise
            print(f'FFmpeg transport attempt {attempt}/{attempts} failed '
                  f'({type(error).__name__}); retrying the same pinned archive', flush=True)
            pause(2 ** attempt)
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
    raise ValueError('FFmpeg download needs at least one attempt')


def main():
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
    download_verified(URL, archive, SHA256)

    # Pub caches may contain generated frameworks from an earlier job. Regenerate
    # only those outputs from the verified archive; preserve package source.
    frameworks = plugin / 'ios/Frameworks'
    if frameworks.exists():
        shutil.rmtree(frameworks)
    with open(os.environ['GITHUB_ENV'], 'a') as environment:
        environment.write(f'FFMPEG_KIT_IOS_URL={archive.as_uri()}\n')
        environment.write(f'LOKAL_FFMPEG_IOS_SHA256={SHA256}\n')
    print(f'Verified FFmpeg 8.1.2 audio iOS archive: {SHA256}')


if __name__ == '__main__':
    main()
