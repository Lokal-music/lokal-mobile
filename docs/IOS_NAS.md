# iPhone NAS integration and verification

SMB uses `dart_smb2: 0.1.3` and the upstream libsmb2 r8 native framework.
WebDAV accepts valid DAV multistatus responses with same-origin absolute or
relative paths within the configured share. iPhone local-network permission
continues to use the existing OS declaration. Saved NAS credentials and addresses
remain usable; native SMB supports port445 only.

After `flutter pub get`, run `python3 tool/ios_prepare_smb.py` before `pod install`.
The helper validates the checksum-pinned archive, device/simulator Mach-O slices,
minimum iOS versions, dynamic dependencies and required FFI symbols. CocoaPods
retains a native symbol reference so Dart's process loader can find the library.
The normal iOS workflow runs this preparation and the installed `native_smb_ffi`
probe. That probe exercises actual native contexts in both main and worker
isolates without contacting a NAS. Packaging and independent IPA auditing check
framework inclusion/loading and the source-matching LGPL license.

## Optional real native protocol fixture

Use an isolated Python environment; install `tool/requirements-smb-fixture.txt`.
Use the locked Dart SDK and resolved packages. On Linux x86_64 download
`https://github.com/ales-drnz/dart_smb2/releases/download/libsmb2-r8/libsmb2_linux-x86_64.so`
as `libsmb2.so` into a temporary directory. Its required SHA-256 is
`78f1a94ab977ab46ce5c8718f2f3f7fc0e0acf707863e14cfa5eb3a5e5119db2`.

Run:

```sh
python tool/smb_native_contracts.py --library /temporary/directory/libsmb2.so
```

The fixture binds only `127.0.0.1:445`, uses disposable synthetic credentials and
a read-only generated share, and closes its server afterward. The host must allow
binding that port and have no existing SMB server there. The tool verifies the
library checksum before running the app's actual native transport. It checks
failed authentication, Unicode directory listing, repeated connection disposal,
cover reads, refusal of covers over12MiB, bounded progress, exact WAV bytes
and failed-download cleanup.
No real NAS or account is used.

The database race suite is `test/services/ios_nas_scan_retirement_test.dart`.
It holds a listing across Clear Library/server removal, using the actual Isar
core and iPhone writer policy. Both protocols must reject the retired scan;
a fresh scan after Clear Library must succeed with a new recording identity.

Host protocol/database passes are separate from Apple linkage and real NAS
acceptance. The Apple probe, Release/AOT package and iPhone local-network, playback,
credential and large-file checks still require their respective Apple/device
runs. Native background imports/uploads remain disabled under the fixed release
milestones in `IOS_FIRST_RELEASE.md`.
