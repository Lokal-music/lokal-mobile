import 'dart:ffi';
import 'dart:isolate';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';

bool _nativeContext() {
  final library = DynamicLibrary.process();
  final create = library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'smb2_init_context',
      );
  final destroy = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('smb2_destroy_context');
  final context = create();
  if (context == nullptr) {
    throw StateError('Native SMB context allocation failed.');
  }
  destroy(context);
  return true;
}

/// Actual bundled FFI in both app and worker isolates, without contacting a NAS.
Future<Map<String, Object>> probeIosNativeSmb() async {
  final client = Smb2Client.open();
  expect(client.isConnected, false);
  client.disconnect();
  expect(_nativeContext(), true);
  expect(await Isolate.run(_nativeContext), true);
  return {
    'scope': 'Actual bundled libsmb2 FFI symbols and context lifecycle; no NAS/network acceptance',
    'main_isolate': true,
    'worker_isolate': true,
    'nas_tested': false,
  };
}
