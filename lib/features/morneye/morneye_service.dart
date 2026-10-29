import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'morneye_packages.dart';
import 'morneye_runtime.dart';
import 'morneye_storage.dart';

/// The app's one Morneye package manager, as desktop keeps one in its main
/// process. Nothing is read or started until something asks for it.
class MorneyeService extends ChangeNotifier {
  MorneyeService._();

  static final instance = MorneyeService._();

  Future<MorneyePackages>? _packages;

  /// The loaded package manager.
  Future<MorneyePackages> get packages => _packages ??= _open();

  Future<MorneyePackages> _open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'morneye'));
      final legacyRoot = Directory(p.join(support.path, 'spotiflac'));
      if (!root.existsSync() && legacyRoot.existsSync()) {
        await legacyRoot.rename(root.path);
      }
      const native = NativeMorneye();
      final packages = MorneyePackages(
        root,
        storage: MorneyeStorage(root, sealer: native),
      );
      await packages.load();
      // Ship an independent Amazon (New) extension alongside the original
      // Amazon addon. It has its own settings/session namespace and does not
      // replace or silently migrate a user's existing provider.
      // A newer installed version is never overwritten.
      try {
        final installed = packages.addons
            .where((addon) => addon.name == 'amazon-new')
            .firstOrNull;
        if (installed == null ||
            morneyeCompareVersions(installed.version, '2.3.16') < 0) {
          final data = await rootBundle.load('assets/morneye/amazon-new.sflx');
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes, data.lengthInBytes,
          );
          const expected = '967bc8cf940cf39029ef7e33f55bf37c5f686028332570ef484579ebc75c5543';
          if (sha256.convert(bytes).toString() != expected) {
            throw StateError('Bundled Amazon (New) archive checksum mismatch');
          }
          await packages.install(bytes: bytes);
        }
      } catch (error) {
        // Bundled provider installation must not disable other add-ons
        // or prevent the user's existing library and sources from loading.
        debugPrint('[Mornye] Amazon (New) setup failed: ${error.runtimeType}');
      }
      return packages;
    } catch (_) {
      _packages = null; // Try again next time.
      rethrow;
    }
  }

  /// Tells screens showing add-ons that something changed.
  void changed() => notifyListeners();

  /// Enabled installed sources stay listed even while their session needs renewal.
  Future<List<MorneyeAddon>> playable() async {
    final packages = await this.packages;
    return [
      for (final addon in packages.addons)
        if (addon.enabled && addon.downloads && addon.searches) addon,
    ];
  }
}
