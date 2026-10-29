import 'package:flick/services/ios_transfer_scan_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = '62dcde21-562f-4417-b660-cd1385ea44ca';
  test('native operation suffix survives Apple path spelling variations', () {
    for (final path in [
      '/var/app/Music/Desktop Copies/Café - $id-r1.flac',
      '/private/var/app/Music/Desktop Copies/Cafe\u0301 - $id-r1.flac',
      '/VAR/APP/MUSIC/DESKTOP COPIES/TITLE - ${id.toUpperCase()}-r1.FLAC',
      '/app/Music/Desktop Copies/../Desktop Copies/Title - $id-r1.flac',
    ]) {
      expect(iosTransferOperationKeyForPath(path), '$id:1');
    }
  });
  test(
    'ordinary files and malformed operation suffixes are not reservations',
    () {
      for (final path in [
        'Desktop Copies/Title - $id-r1.flac',
        '/app/Music/Title - $id-r1.flac',
        '/app/Music/Desktop Copies/child/Title - $id-r1.flac',
        '/app/Music/Desktop Copies/Title.flac',
        '/app/Music/Desktop Copies/Title - $id-r0.flac',
        '/app/Music/Desktop Copies/Title - $id-r01.flac',
        '/app/Music/Desktop Copies/Title - $id-r-1.flac',
        '/app/Music/Desktop Copies/Title - $id-r999999999999999999999999.flac',
        '/app/Music/Desktop Copies/Title - $id-r1.flac.part',
        '/app/Music/Desktop Copies/Title\u0000 - $id-r1.flac',
        'file:///app/Music/Desktop Copies/Title - $id-r1.flac',
      ]) {
        expect(iosTransferOperationKeyForPath(path), isNull, reason: path);
      }
    },
  );
}
