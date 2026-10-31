import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/native_smb_transport.dart';
import 'package:flick/services/sources/smb_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements NativeSmbSession {
  _Session({this.error, this.readBytes});
  final Object? error;
  final List<int>? readBytes;
  String? listed;
  String? readPath;
  bool closed = false;

  @override
  Future<List<NativeSmbEntry>> list(String directory) async {
    listed = directory;
    if (error != null) throw error!;
    return [
      (name: '01.flac', path: '$directory/01.flac', size: 42, isDir: false),
    ];
  }

  @override
  Future<List<int>> read(String path) async {
    readPath = path;
    return readBytes ?? [1, 2, 3];
  }

  @override
  Future<void> download(
    String path, String destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    onProgress?.call(3, 3);
  }

  @override
  Future<void> close() async => closed = true;
}

NetworkServerEntity _server() => NetworkServerEntity()
  ..id = 3
  ..label = 'GL.iNet USB'
  ..baseUrl = 'smb://192.168.8.1/disk1_part1/Music'
  ..protocol = 'smb'
  ..username = 'user1'
  ..token = base64Encode(utf8.encode('secret'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('libsmb2 rejects a nonstandard port before any network call', () async {
    await expectLater(
      Libsmb2Transport.connect(
        host: '192.168.8.1', port: 1445, share: 'disk1_part1',
        username: 'user1', password: 'secret',
      ),
      throwsA(isA<UnsupportedError>().having(
        (error) => error.message, 'message', contains('445'),
      )),
    );
  });

  test('libsmb2 rejects missing named-account password before native login', () async {
    await expectLater(
      Libsmb2Transport.connect(
        host: '192.168.8.1', port: 445, share: 'disk1_part1',
        username: 'user1', password: '',
      ),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message', contains('password missing'),
      )),
    );
  });

  test('native SMB authenticates and lists the configured folder', () async {
    final session = _Session();
    final service = SmbService.create(
      connector: ({
        required host,
        required port,
        required share,
        required username,
        required password,
      }) async {
        expect(host, '192.168.8.1');
        expect(port, 445);
        expect(share, 'disk1_part1');
        expect(username, 'user1');
        expect(password, 'secret');
        return session;
      },
    );
    expect(await service.ping(_server()), isTrue);
    expect(session.listed, 'Music');
    expect(session.closed, isTrue);
  });

  test('SMB embedded FLAC artwork is read through a closed native session',
      () async {
    final image = <int>[0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];
    List<int> u32(int n) => [
      (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255,
    ];
    final mime = utf8.encode('image/jpeg');
    final picture = [
      ...u32(3), ...u32(mime.length), ...mime,
      ...u32(0), ...u32(400), ...u32(400), ...u32(24), ...u32(0),
      ...u32(image.length), ...image,
    ];
    final data = [
      ...utf8.encode('fLaC'),
      0x86, 0, 0, picture.length, ...picture,
    ];
    final session = _Session(readBytes: data);
    final service = SmbService.create(
      connector: ({
        required host,
        required port,
        required share,
        required username,
        required password,
      }) async => session,
    );

    final result =
        await service.getEmbeddedCoverArt(_server(), 'Music/Album/01.flac');
    expect(result, image);
    expect(session.readPath, 'Music/Album/01.flac');
    expect(session.closed, isTrue);
  });

  test('SMB does not connect for unsupported embedded-cover formats', () async {
    var connected = false;
    final service = SmbService.create(
      connector: ({
        required host,
        required port,
        required share,
        required username,
        required password,
      }) async {
        connected = true;
        return _Session();
      },
    );
    expect(
      await service.getEmbeddedCoverArt(_server(), 'Music/Album/01.wav'),
      isEmpty,
    );
    expect(connected, isFalse);
  });

  test('a failed NAS listing closes the SMB native session', () async {
    final session = _Session(error: StateError('Access denied'));
    final service = SmbService.create(
      connector: ({
        required host,
        required port,
        required share,
        required username,
        required password,
      }) async => session,
    );
    expect(await service.ping(_server()), isFalse);
    expect(session.closed, isTrue);
    expect(service.lastPingError?.toLowerCase(), contains('access denied'));
  });
}
