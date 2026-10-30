# Third-party notices

## Flick

The Flutter player, Android platform integration, Rust engine, generated bridge, tests and bundled assets are derived from [Lokal-Konnekt/Flick](https://github.com/Lokal-Konnekt/Flick), upstream [moss-apps/Flick](https://github.com/moss-apps/Flick), commit `a309b9fd222735774f7d3e1643da2ed7114cf7c0`.

MIT License

Copyright (c) 2026 Flick Player Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Konnekted / BitChord

Flow rules and experience are ported from [Lokal-Konnekt/Konnekted](https://github.com/Lokal-Konnekt/Konnekted), branch `flow-feature`, commit `2dcadb44a46948cb6d7b3eb707db0727e9d436d0`. Credits include BitChord contributors, kushagrasinghx, and the BitChord Next community fork. These contributions are GPL-3.0; the combined work is distributed under the GPL-3.0 license in `LICENSE`. This does not remove the original licenses from MIT components.

## Bundled components

The Android build-script overlays for Rive Native 0.1.11 and Home Widget 0.10.0
are described in `android/compat/README.md`. Original copyright/license notices
for those adapted build configurations are retained in `android/compat/LICENSES.md`.

Keep the license files distributed with `rust/vendor`, `rust_builder/cargokit`, and `assets/fonts`. Google Sans Flex and Noto Sans SC are SIL Open Font License fonts. Other third-party dependencies retain their respective licenses, available through Flutter's license registry and Cargo package metadata.

No affiliation with or endorsement by Google, YouTube, Spotify, Tidal, Deezer, Discord, Last.fm or ListenBrainz is implied.

Unicode normalization for local lyrics search uses `unorm_dart` 0.3.2
(Copyright © 2018 Yasuhiro Shimizu), under the MIT License. Its original
`LICENSE` is retained by the package and Flutter's bundled license registry;
the exact source archive digest is pinned in `pubspec.lock`.

## Google Cast iOS SDK

The iPhone build links Google's unmodified Google Cast SDK 4.8.6 static binary.
This SDK is supplied under the [Google APIs Terms of Service](https://developers.google.com/terms/)
and [Google Cast SDK Additional Developer Terms](https://developers.google.com/cast/docs/terms/);
it is not relicensed as GPL or Apache software by this repository. The pinned
specification is in `ios/CastSDK.podspec.json`. Its resource bundles and privacy
manifest are retained, and upstream dependency notices are shipped in the app's
`LokalCastNotices.bundle`. GTMSessionFetcher 3.5.0 retains its upstream Apache 2.0
notices, also collected by CocoaPods. Engineering integration does not establish
public distribution qualification.

## iPhone native dependencies

The locked `ffmpeg_kit_flutter_new_audio` 2.5.7 plugin uses the FFmpegKit 8.1.2
audio distribution from [sk3llo/ffmpeg_kit_flutter](https://github.com/sk3llo/ffmpeg_kit_flutter/releases/tag/8.1.2-audio).
The plugin and native FFmpeg/FFmpegKit framework notices identify LGPL-3.0;
bundled codecs retain their separate licenses. The IPA preserves the native
framework `LICENSE` and codec `LICENSE.*` files, together with Flutter's generated
`NOTICES.Z` license registry. Do not strip these when repackaging or re-signing.
The application's source archive and dependency lockfiles accompany engineering
artifacts; upstream source/build scripts remain available from the linked project.

## Mornye Discord Social SDK bridge

Android native bridge adapted from [Mornye](https://github.com/mornyeapp/Mornye) (Copyright © 2026 zarzet), under the MIT License. Full license: `third_party/mornye_discord/LICENSE`. Discord SDK binaries are separately licensed; when staged, their official notices are packaged in Android assets.

## Native SMB2/3 transport (dart_smb2 / libsmb2)

Lokal uses `dart_smb2` version 0.1.3 (BSD-3-Clause) to communicate with SMB2/SMB3 NAS shares. Its dynamically linked `libsmb2` native binary is LGPL-2.1 licensed. The complete LGPL license appears in the installed application's **About → Licences** page and `assets/licenses/libsmb2.txt`. Corresponding LGPL library source and native build/patch scripts are available at https://github.com/sahlberg/libsmb2 and https://github.com/ales-drnz/libsmb2-scripts . This library is not part of Lokal's application source code and users retain the rights described in LGPL-2.1.
