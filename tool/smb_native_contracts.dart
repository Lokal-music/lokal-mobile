// Actual native libsmb2 against a loopback SMB2 server; no storage/network mock.
import 'dart:io';
import 'package:flick/services/sources/native_smb_transport.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  final root = Directory(arguments.single);
  final expected = await File('${root.path}/share/Album/Café # %.wav').readAsBytes();
  var denied = false;
  try {
    final invalid = await Libsmb2Transport.connect(host: '127.0.0.1', port: 445,
      share: 'Music', username: 'lokal-fixture', password: 'incorrect-fixture-password');
    await invalid.close();
  } catch (_) { denied = true; }
  require(denied, 'Named-account authentication failure must not fall back to guest');
  for (var attempt = 0; attempt < 2; attempt++) {
    final session = await Libsmb2Transport.connect(host: '127.0.0.1', port: 445,
      share: 'Music', username: 'lokal-fixture', password: 'local-smb-fixture-only');
    try {
      final directories = await session.list('');
      require(directories.any((row) => row.isDir && row.name == 'Album'), 'Actual SMB2 directory listing');
      final tracks = await session.list('Album');
      final track = tracks.singleWhere((row) => row.name == 'Café # %.wav');
      require(track.size == expected.length, 'Actual SMB2 Unicode filename and file size');
      final cover = await session.read('Album/cover.jpg');
      require(cover.join(',') == '1,2,3,4', 'Actual native cover-byte read');
      var largeCoverRefused = false;
      try { await session.read('Album/oversized.jpg'); } catch (_) { largeCoverRefused = true; }
      require(largeCoverRefused, 'Native oversized cover is refused before allocation');
      final destination = '${root.path}/download-$attempt.wav';
      var last = 0, calls = 0;
      await session.download(track.path, destination, onProgress: (bytes, total) {
        require(bytes > last && bytes <= total && total == expected.length, 'Bounded monotonic download progress');
        last = bytes; calls++;
      });
      final received = await File(destination).readAsBytes();
      require(received.length == expected.length &&
          Iterable<int>.generate(expected.length).every((i) => expected[i] == received[i]),
          'Native SMB2 download preserves every actual byte');
      require(calls >= 3 && last == expected.length, 'File copied in multiple bounded chunks');
      await File(destination).writeAsString('Previously cached bytes');
      var refused = false;
      try { await session.download('Album/missing.wav', destination); } catch (_) { refused = true; }
      require(refused && await File(destination).readAsString() == 'Previously cached bytes',
          'Failed SMB download preserves an existing cache entry');
      require(!(await root.list().toList()).any((file) => file.path.contains('.smb-part-')),
          'Failed download leaves no private partial');
    } finally { await session.close(); }
  }
  stdout.writeln('Actual native SMB2 contracts passed: named authentication/refusal, repeated session lifecycle, directory/Unicode names, cover bytes, bounded multi-chunk downloads and failed-copy cache preservation. Not iOS/NAS-device or encryption acceptance.');
}
