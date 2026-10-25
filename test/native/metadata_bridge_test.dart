import 'dart:convert';
import 'dart:io';

import 'package:flick/features/morneye/morneye_bootstrap.dart';
import 'package:flick/src/rust/api/metadata_editor.dart' as tags;
import 'package:flick/src/rust/api/morneye_api.dart';
import 'package:flick/src/rust/api/scanner.dart' as scanner;
import 'package:flick/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/generated_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['LOKAL_NATIVE_LIBRARY'];

  test(
    'real metadata and add-on bridge round trips',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library!));
      addTearDown(RustLib.dispose);
      final directory = await Directory.systemTemp.createTemp('lokal-bridge-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/Été 音楽.wav');
      await file.writeAsBytes(generatedPcmTone(), flush: true);
      final written = await tags.writeTags(
        path: file.path,
        fields: const tags.TagEditFields(
          title: 'Native fixture',
          artist: 'Track artist',
          album: 'Compilation',
          albumArtist: 'Various fixtures',
        ),
      );
      expect(written.success, true, reason: written.error);
      expect(
        (await tags.readTags(path: file.path)).albumArtist,
        'Various fixtures',
      );
      final scan = await scanner.scanRootDir(
        rootPath: directory.path,
        knownFiles: {},
        scanOptions: const scanner.ScanOptions(
          filterNonMusicFilesAndFolders: false,
          forceFullRescan: true,
        ),
      );
      expect(scan.newOrModified, hasLength(1));
      final metadata = scan.newOrModified.single;
      expect(metadata.path, file.path);
      expect(metadata.artist, 'Track artist');
      expect(metadata.albumArtist, 'Various fixtures');
      expect(metadata.sampleRate, 44100);

      // These calls also check the regenerated add-on entrypoints against the
      // actual native library, rather than accepting matching method names.
      final key = List<int>.filled(32, 0x27);
      final nonce = List<int>.filled(12, 0x13);
      final plaintext = utf8.encode('generated add-on fixture');
      final sealed = morneyeSeal(data: plaintext, key: key, nonce: nonce);
      expect(morneyeOpen(data: sealed, key: key), plaintext);
      final guest = await MorneyeEngine.start(
        code: 'registerExtension({echo(value) { return {value}; }});',
        bootstrap: morneyeBootstrap,
        configJson:
            '{"permissions":{"network":[],"storage":false},"settings":{}}',
        host: (_, _) => 'null',
      );
      try {
        expect(
          jsonDecode(
            await guest.invoke(
              method: 'echo',
              argsJson: '[42]',
              timeoutMs: BigInt.from(5000),
            ),
          ),
          {'value': 42},
        );
      } finally {
        guest.close();
      }
    },
    skip: library == null
        ? 'Set LOKAL_NATIVE_LIBRARY to the actual host build.'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
