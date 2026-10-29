# Android Auto installation and trusted distribution

Lokal uses a `MediaBrowserServiceCompat` (`MusicNotificationService`) and
`com.google.android.gms.car.application` with `<uses name="media" />`.
The service and its Flutter browse catalog already provide Android Auto media
integration. **The installation source is a separate Android Auto gate.**

## Why GitHub APK users need "Unknown sources"

Android Auto ordinarily only accepts media apps installed from a trusted
source, such as Google Play. The setting under **Android Auto → Developer
settings → Unknown sources** allows untrusted/sideloaded media packages.
This applies to a GitHub APK regardless of whether it was built from the
`full` or `play` flavor, whether it was release-signed, or whether the
manifest is correctly configured. Lokal cannot turn this Android Auto setting
on programmatically or make a GitHub installer count as a Google Play install.

Google's testing guide confirms both the restriction and the supported test
paths: https://developer.android.com/training/cars/testing

For GitHub APK installs, the user must enable Android Auto developer mode,
enable **Unknown sources**, reconnect the vehicle, and (if necessary) select
Lokal under Android Auto's launcher customization. This setting is distinct
from the Android setting that authorizes an APK installer.

## Supported route that avoids the toggle

Install Lokal from a Google Play track that includes Android Auto, rather than
sideloading it. Internal App Sharing and internal testing tracks are supported
for testing real car installations according to Google's Android Auto testing
guide. Production availability and inclusion of the Android Auto form factor
remain subject to the Play Console requirements and Google's review.

Lokal has a `play` Gradle flavor with the same release application ID and
signing identity as `full`. The Play variant omits All Files Access and uses
MediaStore/SAF. It still requires a policy and car-quality review before it can
be distributed through Google Play.

### Build and upload the Play App Bundle

1. From the repository's **Actions → Release Lokal Mobile** workflow, choose
   `flavor: play` or `flavor: both` (or use the nightly workflow with
   `play`). This calls the shared, signed build workflow.
2. Once the workflow succeeds, download the
   `android-play-<versionCode>` **Actions artifact** from the workflow run.
   In addition to the signed APK and APK metadata, it contains
   `Lokal-<version>-Play.aab` and the corresponding `.aab.sha256` digest.
   The AAB is **not** a phone installer and is **not** attached to the GitHub
   Releases download page.
3. Confirm the expected application ID `com.lokalkonnekt.konnekted2`,
   `versionCode` (higher than all prior Play uploads), app signing/upload
   key configuration, and version name. The helper verifies the signed Play
   APK and AAB signatures before saving either uploadable artifact.
4. In Google Play Console, configure the existing app identity, accept Play
   App Signing as required, add **Android Auto** under supported form factors,
   and complete the applicable car-quality, permissions, data safety,
   functionality and store listing requirements. Upload the AAB to a test
   track and satisfy any review or track-eligibility requirements.
5. Have testers opt into that Google Play track and **install Lokal using
   Google Play**. Reconnect Android Auto and check its launcher customization.
   Do not install the GitHub APK afterward as a replacement for the trusted
   Play-installed version.

Reference: https://developer.android.com/training/cars/distribute

### Signing and upgrades

The AAB upload signature must match the upload key accepted for this Play
application. Google Play App Signing may use a different **app signing key**
to sign APKs delivered to devices. If that key does not match the key that
signed a user's prior sideloaded APK, Android will not upgrade the existing
package in place; plan and communicate a library/data migration before
asking such users to switch. Never silently uninstall Lokal.

Stable/nightly workflows share a time-based versionCode policy. A Play
release must use a code greater than **every** version already uploaded to
that Play app; verify it before upload. The AAB is intentionally an Actions
artifact rather than a public GitHub release attachment; no service-account
credentials or unattended Play publication are configured.

## Validation matrix

| Install source | Expected Android Auto requirement |
| --- | --- |
| GitHub `full` APK | Enable Android Auto **Unknown sources** |
| GitHub `play` APK | Same: **Unknown sources** still required |
| Play internal testing / internal sharing | Trusted Play install; toggle not normally required |
| Google Play production listing | Trusted Play install; toggle not normally required |

Re-test on an actual vehicle or Desktop Head Unit for playback, browsing,
voice search, steering wheel controls and process death. A build passing
CI is not evidence that Google Play accepted the app or that the installed
package appeared in Android Auto. There is no supported manifest, certificate
or MediaBrowserService flag that bypasses Android Auto's install-origin check.

Templated media experiences using the Android for Cars App Library are a
different, more complex UI architecture; adopting them solely to work around
installation trust would be a speculative migration and would not establish
Google Play provenance for the existing GitHub APK.
