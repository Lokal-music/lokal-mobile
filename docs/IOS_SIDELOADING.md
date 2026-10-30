# Install the iPhone build from Windows

The iPhone port is experimental. An unsigned IPA must be signed for the target
iPhone before installation. The build pipeline uses hosted macOS/Xcode; you can
develop, download and install from Windows without owning a Mac. A real iPhone
is required to perform these installation and acceptance steps.

iOS Home Screen widgets are excluded from this release. Standard lock-screen
and Control Center playback controls remain available; no WidgetKit/App Group
setup is required for the sideloaded app.

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
The latest complete hosted engineering checkpoint recorded for this stack is
[build 111 on PR349](https://github.com/lokal-music/lokal-mobile/actions/runs/41005225249).
Its iPhone build, iOS26 acceptance and independent IPA-audit jobs passed. Use
its own packaged manifest and checksum when downloading; a checksum from an
earlier build does not verify build111.

The separately qualified
[build103 on PR345](https://github.com/lokal-music/lokal-mobile/actions/runs/40992683570)
also passed iOS18.6/26 acceptance and its independent package audit. Its artifact
is `Lokal-iPhone-engineering-unsigned-103-attempt1`, with IPA SHA-256
`b976c72a458edd43ad743da8241ddd1d1368e4aae821218824f86d3e72d62a7d`
and source tree `4e94d6a6c0ed685428ed7dad3afcc27a6939d0b6`.
These qualification records are distinct from downloading and reinspecting
the packages in this workspace, and neither is physical-device acceptance.

Newer source through PR355 and the subsequent Clear/Forget preservation
continuation is **not contained in those earlier artifacts**. CI waits are
skipped at the user's request; use a successful matching newer artifact to
test that source. Native product import/upload remain disabled; ordinary
foreground copies remain active. Signing, installation/upgrade, live services
and receivers, and physical playback acceptance remain outstanding. Future
native background-transfer activation also requires OS suspension/relaunch
and the remaining [transfer gates](IOS_TRANSFERS.md).

Build86 remains a separately preserved older fallback:
[run40951126722](https://github.com/lokal-music/lokal-mobile/actions/runs/40951126722),
IPA SHA-256 `398d7b2f4d17de1f143bcb33c92673e379a2bcad669c9b13746b58dd94c7159e`.
Keep every package's frozen source and crash symbols with that exact build.

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
