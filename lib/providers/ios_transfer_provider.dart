import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../services/ios_transfer_import_coordinator.dart';
import '../services/ios_transfer_import_store.dart';
import '../services/ios_transfer_media_probe.dart';
import '../services/ios_transfer_session.dart';
import '../services/ios_transfer_transport.dart';
import '../services/ios_transfer_upload_admission.dart';

IosTransferSession? _createSession() {
  if (kIsWeb || !Platform.isIOS) return null;
  final native = IosTransferTransport();
  return IosTransferSession(
    native: native,
    uploadAdmission: () async {
      if (!Database.isInitialized) {
        throw StateError('Library is not available.');
      }
      return IosTransferUploadAdmission(isar: Database.instance, port: native);
    },
    coordinator: IosTransferImportCoordinator(
      native: native,
      store: () async {
        if (!Database.isInitialized) {
          throw StateError('Library is not available.');
        }
        final documents = await getApplicationDocumentsDirectory();
        return IosTransferImportStore(
          Database.instance,
          musicRoot: '${documents.path}/Music',
        );
      },
      readMedia: const IosTransferMediaProbe().inspect,
    ),
  );
}

/// An injectable factory keeps lifetime tests independent of real user storage.
final iosTransferSessionFactoryProvider =
    Provider<IosTransferSession? Function()>((ref) => _createSession);

/// Intentionally not autoDispose: lifecycle and future clear/unpair actions
/// share one owner until the app's ProviderContainer is retired. Constructing
/// the session does not enable the gated native import/upload capabilities.
final iosTransferSessionProvider = Provider<IosTransferSession?>((ref) {
  final session = ref.read(iosTransferSessionFactoryProvider)();
  if (session != null) {
    ref.onDispose(() => unawaited(session.dispose()));
  }
  return session;
});
