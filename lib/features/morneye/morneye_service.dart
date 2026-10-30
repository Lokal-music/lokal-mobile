import 'dart:io';

import 'package:flutter/foundation.dart';
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
