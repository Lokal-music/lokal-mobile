import 'dart:convert';

import 'package:flick/data/entities/network_server_entity.dart';
import 'package:flick/services/sources/native_smb_transport.dart';
import 'package:flick/services/sources/smb_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements NativeSmbSession {
  _Session({this.error});
  final Object? error;
  String? listed;
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
  Future<List<int>> read(String path) async => [1, 2, 3];

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
