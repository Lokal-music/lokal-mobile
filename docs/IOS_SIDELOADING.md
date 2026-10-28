# Install the iPhone build from Windows

The iPhone port is experimental. An unsigned IPA must be signed for the target
iPhone before installation. The build pipeline uses hosted macOS/Xcode; you can
develop, download and install from Windows without owning a Mac. A real iPhone
is required to perform these installation and acceptance steps.

## Get the artifact

1. Open the **iPhone build and sideload package** run in the
   repository's Actions tab. During development the runs are linked from
   [the iPhone pull request](https://github.com/lokal-music/lokal-mobile/pull/172).
2. Download the `Lokal-iPhone-engineering-unsigned-<run>-attempt<attempt>` artifact (earlier runs omit the attempt suffix) and extract the outer ZIP.
   The app is **`Lokal-unsigned.ipa`** inside it. Keep the `.ipa` extension.
3. Check its SHA-256 against `Lokal-unsigned.ipa.sha256`, for example in
   PowerShell:

   ```powershell
   Get-FileHash .\Lokal-unsigned.ipa -Algorithm SHA256
   ```

`Lokal-unsigned.ipa.json` identifies the source commit, version/build and Apple
toolchain. The artifact also contains the project's license/notices and matching
source archive. Simulator screenshots/logs are in the diagnostics artifact.
The current independently verified engineering checkpoint is
[build 74](https://github.com/lokal-music/lokal-mobile/actions/runs/40672723535),
through reviewed #272 plus adaptive Rust polling and coherent paused persistence,
passing both complete iOS 18.6 and 26.0 suites on separate hosted Macs.
The artifact is `Lokal-iPhone-engineering-unsigned-74-attempt1`.
Its IPA SHA-256 is
`69417b9c9c560a2748847b3b519bfe1a2ccf2b38b83dd1e28901bd70d126cad4`.
All 34 arm64 iOS binaries, 26 matching native symbol bundles, Dart AOT symbols,
notices and 2,262 exported source files are retained/rechecked. Source/checksums
and limits are recorded in [the evidence ledger](IOS_PORT.md). Later
through-#290 source has separate host/native gates and is not included in this IPA.
The engineering IPA is saved after binary inspection, before runtime tests;
read the associated run's result before choosing a newer artifact. Build 74 also
passes the real WebKit settled-seek, clock/frame and repeated-reset gates on
both runtimes. It packages an iOS 16+ app; actual iOS 16 runtime
acceptance is still open. Physical iPhone installation, background
playback and accessory acceptance remain separate; this is not a qualified
public release.

Builds with a `Symbols` directory include Dart AOT symbols and matching native
dSYMs, identified by binary UUID in the package metadata. Keep these with the
source/build record for crash symbolication. Do not add the symbol directory to
the IPA itself.

## Sign and install

1. Install [Sideloadly for Windows](https://sideloadly.io/) using its official
   instructions, including the Apple device/iTunes/iCloud prerequisites it lists.
   [AltStore Classic for Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
   is an alternative.
2. Connect an unlocked iPhone by USB and accept the computer trust prompt.
3. Select the iPhone, choose `Lokal-unsigned.ipa`, and sign/install using your own
   Apple account in the sideloading tool. Do not put your account/password,
   certificates or provisioning files in GitHub, CI, app logs or chat.
4. Follow iOS prompts to trust the developer profile under **Settings → General
   → VPN & Device Management**. On iOS 16 or later, enable **Developer Mode** in
   **Settings → Privacy & Security** if requested, including the required restart.
5. Launch Lokal. Release builds use AOT and should run without an attached
   debugger. Report the build number and iPhone/iOS version if launch fails.

A paid Apple Developer membership is not required for the free-account install
route documented by these tools. Free-account apps normally expire after seven
days and need refreshing; Apple also limits app/App ID slots. AltStore itself
uses a slot. Refresh requires the tool's current connectivity/setup conditions;
it is not guaranteed merely because an auto-refresh option is enabled.

## Import and listen

- In **You → Library → Folders**, choose **Import music** and select files or a
  folder from Files, including a File Provider such as iCloud Drive.
- Lokal copies the selection into its own `Music` folder. The original files
  remain with their provider. Folders keep artwork/lyrics sidecars alongside the
  music. Imports are snapshots; later changes in the original folder need a new
  import rather than Android-style whole-device watching.
- The copied music is visible through the iPhone Files app and file sharing.
  Database internals are stored separately. Do not delete imported music unless
  you intend to remove those local copies.
- Choose headphones/AirPlay through iPhone system controls or Lokal's iPhone
  output picker. Ordinary USB DAC playback uses iOS's system route. The app does
  not certify that route as bit-perfect or native DSD.

Import music before importing an M3U/M3U8 playlist from Library's playlist menu;
playlist entries are matched to the existing library. iPhone manual imports keep
an app-owned playlist snapshot, so removing the selected File Provider source
does not invalidate it. Later edits to that external source require another
import. M3U/M3U8 export and Replay's CSV/TXT export use the native Files save
picker; cancelling leaves the library unchanged. Playlist text must be UTF-8 and
no larger than 10 MB. These adapters have contract coverage; native picker and
File Provider acceptance remains pending.

## Refresh and update without losing the library

Use the same Apple account and stable app identity in the signing tool. Install
the newer IPA over the existing app. Refresh/re-sign the existing installation
before it expires. **Do not uninstall Lokal as a routine refresh step**: uninstall
can remove imported music and app data. Back up music and user data before
changing signing accounts or bundle identifiers.

The port includes container-path rebasing for iOS updates, but Windows refresh,
upgrade and Keychain preservation still need real-device acceptance testing.
Changing signing identity can affect Keychain access independently of whether
the ordinary app data survives.

## Device acceptance record

Record the exact source commit/build and results for:

- First installation, cold launch without a debugger, and file/folder import.
- Playback with the screen locked and app backgrounded; play/pause/seek/skip from
  lock screen and Control Center, plus radio/library ownership changes.
- Calls/Siri/alarms; wired and Bluetooth detach/reconnect; ordinary USB DAC and
  AirPlay output where hardware is available.
- Playlist/likes/history survival after a second-build upgrade and signing refresh.
- File Provider cancellation/errors, insufficient storage, and desktop copies
  across Wi-Fi changes and app suspension.
- Online source sign-in, playback/downloads and add-ons using opted-in accounts.

Keep tokens, cookies, pairing secrets and personal file paths out of shared logs.
Until these checks pass, the artifact is an engineering build, not a qualified
public release.
