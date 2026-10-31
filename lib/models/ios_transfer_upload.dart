import 'ios_transfer_models.dart';

Map<String, dynamic> _row(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Invalid upload source response.');
  }
  return value;
}

String uploadSourceId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(value)) {
    throw const FormatException('Invalid upload source identifier.');
  }
  return value;
}

bool validUploadSongId(String value) {
  final number = int.tryParse(value);
  return number != null && number > 0 && number.toString() == value;
}

class IosTransferUploadContext {
  const IosTransferUploadContext({
    required this.id,
    required this.rootPath,
    required this.canonicalRootPath,
    required this.pairing,
  });
  final String id, rootPath, canonicalRootPath;
  final IosTransferPairing pairing;
  factory IosTransferUploadContext.fromJson(Object? value) {
    final row = _row(value, {
      'contextID',
      'rootPath',
      'canonicalRootPath',
      'pairing',
    });
    final root = row['rootPath'], canonical = row['canonicalRootPath'];
    final pairing = IosTransferPairing.fromJson(row['pairing']);
    if (root is! String ||
        !root.startsWith('/') ||
        root.length > 4096 ||
        root.contains('\u0000') ||
        canonical is! String ||
        !canonical.startsWith('/') ||
        canonical.length > 4096 ||
        canonical.contains('\u0000') ||
        pairing.scope.pairingId == null) {
      throw const FormatException('Invalid upload source context.');
    }
    return IosTransferUploadContext(
      id: uploadSourceId(row['contextID']),
      rootPath: root,
      canonicalRootPath: canonical,
      pairing: pairing,
    );
  }
}

class IosTransferUploadGrant {
  const IosTransferUploadGrant({
    required this.id,
    required this.songId,
    required this.bytes,
    required this.sha256,
  });
  final String id, songId, sha256;
  final int bytes;
  factory IosTransferUploadGrant.fromJson(Object? value) {
    final row = _row(value, {'grantID', 'songID', 'bytes', 'sha256'});
    final song = row['songID'], bytes = row['bytes'], hash = row['sha256'];
    if (song is! String ||
        !validUploadSongId(song) ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > 1024 * 1024 * 1024 ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid upload source grant.');
    }
    return IosTransferUploadGrant(
      id: uploadSourceId(row['grantID']),
      songId: song,
      bytes: bytes,
      sha256: hash,
    );
  }
}

/// App-owned source admission, separate from the import coordinator contract.
abstract interface class IosTransferUploadPort {
  Future<IosTransferUploadContext> uploadSourceContext();
  Future<IosTransferUploadGrant> authorizeUploadSource({
    required String contextId,
    required String relativePath,
    required String songId,
  });
  Future<void> releaseUploadSource(String id);
  Future<IosTransferSummary> enqueueUpload(
    IosTransferIntent intent, {
    String? grantId,
  });
}
