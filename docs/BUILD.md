# Build Konnekted2

The iPhone port builds on hosted macOS using Xcode 26.0.1, Flutter 3.47.1 and
Rust 1.98.0. CI inspects and saves an unsigned release/AOT IPA, checksum, source
and notices. Lokal starts and renders its welcome screen on the iOS 26 simulator;
real scanner, QuickJS, system WAV and Rust DSP/WavPack integration pass on iOS
26.0. Expanded full-screen/older-runtime checks and symbol retention are pending. Physical iPhone and Windows installation are untested.

See the [architecture and validation ledger](IOS_PORT.md) and
[Windows signing/install guide](IOS_SIDELOADING.md). An engineering artifact does
not establish a qualified iPhone release.

## Prerequisites

- Flutter 3.47+ / Dart 3.13+ (verified with 3.47.1 / 3.13.1).
- Gradle 9.8.1 through the checked-in wrapper; AGP 9.4.1 and Kotlin/Compose
  compiler plugin 2.4.21. Kotlin Android compilation is provided by AGP.
- Android SDK platform 37, Android build tools, and an Android NDK supported by
  the Flutter SDK.
- Java 17 or the Android Studio bundled JDK.
- Rust 1.98+ and Android Rust targets for the Rust engine.
- A physical Android phone is required to validate USB DAC, native DSD, DAP
  output and background media behavior. Desktop Flutter is useful for UI tests
  but is not a supported product target.

Use your installed Flutter SDK and JDK 17. On Windows, set these for the current
terminal (replace the example paths; no global settings change is required):

```text
set "FLUTTER_SDK=C:\path\to\flutter"
set "JAVA_HOME=C:\path\to\jdk-17"
set "PATH=%FLUTTER_SDK%\bin;%FLUTTER_SDK%\bin\cache\dart-sdk\bin;%PATH%"
flutter pub get
```

The Flutter/Dart PATH entries matter because Rive and Cargokit invoke Dart from
Gradle. From WSL, run the Windows tools through `cmd.exe /c` from this repository.
Keep SDK paths in ignored local configuration, never in source-controlled files.

## Checks

Run from the repository root:

```text
flutter analyze --no-pub
flutter test --no-pub
cargo test --lib --manifest-path rust/Cargo.toml
flutter build apk --debug --flavor full --target-platform android-arm64 --no-pub
android\gradlew.bat -p android verifyBuiltInKotlin --console=plain
powershell.exe -NoProfile -File tool/test_cargokit_launcher.ps1
```

Gradle **9.8.1** was the latest stable release returned by
`https://services.gradle.org/versions/current` on 2026-10-14. The distribution
SHA-256 is pinned in `android/gradle/wrapper/gradle-wrapper.properties`; wrapper
scripts/JAR were regenerated with Gradle's `wrapper` task and its JAR digest
matches the official checksum. AGP 8.x cannot run on Gradle 9.6+ because of a
removed internal API; application and Rust-library AGP now share version 9.4.1.

The expected debug output is `build/app/outputs/flutter-apk/app-full-debug.apk`.
**An existing APK is not proof of the current build.** The latest full build
failed in Rust bindgen, as detailed below. No post-migration APK is verified.

The repository's source contains Android platform code and Rust crates. A
missing Android license, NDK, Rust target or Gradle download is an environment
failure, not evidence that the corresponding feature is complete.

On Windows, a clean Cargokit Rust build additionally requires a `libclang.dll`
installation discoverable through `LIBCLANG_PATH`; the Android NDK's clang
driver alone is not enough for the vendored `wavpack-sys` and `opus-sys`
bindgen steps. Set `LIBCLANG_PATH` to the directory containing the Windows
library in the build process environment. Do not point Windows bindgen at a
Linux `.so` or substitute the Android target's clang driver for this host library.

Cargokit's Windows launcher previously masked the Dart runner's nonzero exit
code, allowing APK assembly with old native outputs. It now returns failures
and stops immediately after failed dependency setup or kernel compilation.
The isolated launcher regression harness covers 12 success/failure/retry cases.

## Built-in Kotlin migration and current evidence

`android.builtInKotlin=true` is explicit. The app no longer applies
`kotlin-android`, and the old root-project KGP injection was removed. Published
plugin upgrades are locked in `pubspec.lock`:

| Package | Resolved version |
| --- | --- |
| file_picker / android_file_picker | 12.3.0 / 1.1.1 |
| share_plus | 13.3.1 |
| image_picker_android | 0.8.13+25 |
| shared_preferences_android | 2.4.28 |

Share/file-picker callers use the new APIs; tests preserve payloads, captions,
filenames, subjects, cancelled picks and Android content-URI handling. Rive
0.1.11 and Home Widget 0.10.0 use version-guarded, repository-local build scripts;
see `android/compat/README.md`. Shared Pub-cache source is not patched.

`android.newDsl=false` remains deliberate: Flutter 3.47 still accesses legacy
variant APIs, independently of Kotlin compilation. The corresponding AGP 10
migration warnings and upstream source/compiler warnings are **not suppressed**.
The app/plugin KGP migration warnings are resolved.

Verified on 2026-10-14:

- `gradlew.bat --version`, `help` and `wrapper`: passed with Gradle 9.8.1.
- `gradlew.bat verifyBuiltInKotlin --console=plain`: passed for **23 Android
  modules**, checking enabled built-in Kotlin, compiler tasks and absence of
  applied legacy Kotlin Android plugins.
- The following command from `android/` passed with **48 tasks executed**, not
  reused compile results:

  ```text
  gradlew.bat :android_file_picker:compileDebugKotlin :home_widget:compileDebugKotlin :image_picker_android:compileDebugKotlin :rive_native:compileDebugKotlin :share_plus:compileDebugKotlin :shared_preferences_android:compileDebugKotlin --rerun-tasks --console=plain
  ```

- Focused Flutter regression command: **143 passed, 1 skipped** (the opt-in live
  catalog smoke test). This is not the entire inherited repository test suite.

  ```text
  flutter test --no-pub test/spotify test/playlist_links test/flow test/discovery test/konnekted test/l10n/source_guard_test.dart test/widgets/share_actions_test.dart test/features/player/picked_lyrics_file_test.dart
  ```

- Scoped Dart analysis of the feature integrations, modified picker/share
  callers, and their tests: **no issues**. Spotify's three tests passed again
  after final formatting/lint cleanup.
- Windows launcher regression command above: **12/12 passed**.
- Full APK command above: the terminal's 600-second wait expired; the Gradle
  daemon's completed result was **BUILD FAILED in 11m 47s**, with missing
  `libclang.dll` in `wavpack-sys` / `opus-sys`. Cargokit correctly propagated exit
  **1** to Gradle. No native task was skipped to produce a success claim.

Next native-build step: provide a Windows LLVM/libclang installation, set its
process-local `LIBCLANG_PATH`, and rerun the unchanged full APK command. USB,
DSD/DoP, DAP and physical-device behavior still require the checklist below.

## Flavors

- `full`: sideload/GitHub-style build, includes `MANAGE_EXTERNAL_STORAGE` for
  deep local scans. Users still grant access explicitly in Android settings.
- `play`: Google Play-compatible build, uses MediaStore and SAF without All
  Files Access.

Use `flutter build apk --debug --flavor full` for the fastest local smoke build.
Release signing reads `android/key.properties`; no key or password belongs in
this repository.

## Spotify setup

Spotify uses Authorization Code + PKCE and does not embed a client secret. The
listener must create a Spotify developer application, set the redirect URI to
`konnekted://oauth/spotify`, then enter the client ID in the app. Tokens are
stored in Android secure storage. The OAuth channel opens the system browser and
accepts only the exact configured redirect host/path.

## Hardware validation checklist

1. Scan a local FLAC, WAV, DSF and DFF library from both internal and removable
   storage.
2. Connect a UAC 2.0 DAC and check the diagnostics report negotiated rate,
   channel count, bit depth, route and volume tier.
3. Play PCM with DSP disabled and confirm the direct route; repeat with EQ and
   verify the diagnostic label changes to processed/mixed rather than claiming
   bit-perfect.
4. Play native DSD and DoP files; verify unsupported hardware volume does not
   introduce software gain.
5. Test pause/resume, headset/Bluetooth changes, USB detach, screen-off and
   notification/widget controls.
