import 'package:crypto/crypto.dart';
import 'package:flick/features/morneye/morneye_packages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Amazon (New) package is intact and has independent identity', () async {
    final data = await rootBundle.load('assets/morneye/amazon-new.sflx');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes, data.lengthInBytes,
    );
    expect(sha256.convert(bytes).toString(),
        'ae1ac4dbeb9028939e39bda1a58fabaedf41e8adc37b9b3fc61ee10c9a5bdca7');
    final archive = morneyeReadArchive(bytes);
    expect(archive.manifest['name'], 'amazon-new');
    expect(archive.manifest['displayName'], 'Amazon (New)');
    expect(archive.manifest['version'], '2.3.15');
    expect(archive.code, contains('amazonTrackAudioModes'));
    expect(archive.code, contains('DOLBY_ATMOS'));
    expect(morneyeKeyOf('amazon-new'), isNot(morneyeKeyOf('amazon')),
        reason: 'Legacy Amazon login and settings must not be overwritten');
  });
}
