import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flick/services/playback_secure_storage.dart';

import 'discovery_models.dart';

class DiscoveryAddonConfig {
  const DiscoveryAddonConfig({
    required this.id,
    required this.endpoint,
    this.manifestUrl,
    this.label = '',
    this.token = '',
    this.settings = const {},
    this.enabled = false,
  });

  final String id;
  final String endpoint;
  /// Exact optional manifest URI. Kept in secure storage with the endpoint:
  /// path encodings can be significant to credential-bearing addon servers.
  final String? manifestUrl;
  final String label;
  final String token;
  final Map<String, String> settings;
  final bool enabled;

  // Endpoints can contain credentials, so never derive a name from them.
  String get displayName => label.trim().isEmpty ? 'Music addon' : label.trim();

  DiscoveryAddonConfig validated() {
    if (id.isEmpty ||
        id.length > 80 ||
        RegExp(r'[^A-Za-z0-9_-]').hasMatch(id)) {
      throw const DiscoveryException('The addon ID is invalid.');
    }
    if (label.length > 80 || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(label)) {
      throw const DiscoveryException('The addon label is invalid.');
    }
    final trimmedToken = token.trim();
    if (trimmedToken.length > 4096 ||
        RegExp(r'[^\x21-\x7e]').hasMatch(trimmedToken)) {
      throw const DiscoveryException(
        'The bearer token contains invalid characters or is too long.',
      );
    }
    final String normalizedEndpoint;
    try {
      normalizedEndpoint = normalizeAddonEndpoint(endpoint).toString();
    } on DiscoveryException {
      rethrow;
    } catch (_) {
      throw const DiscoveryException('The addon URL is invalid.');
    }
    if (manifestUrl != null) {
      try {
        if (manifestUrl!.length > 8192) {
          throw const FormatException();
        }
        final exact = requireHttps(manifestUrl!);
        if (exact.hasQuery ||
            exact.hasFragment ||
            exact.pathSegments.lastOrNull != 'manifest.json' ||
            normalizeAddonEndpoint(exact.toString()).toString() !=
                normalizedEndpoint) {
          throw const FormatException();
        }
      } catch (_) {
        throw const DiscoveryException('The add-on manifest URL is invalid.');
      }
    }
    if (settings.length > 16 ||
        settings.entries.any((entry) =>
          entry.key.length > 40 ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(entry.key) ||
          entry.key == 'q' ||
          entry.value.isEmpty ||
          entry.value.length > 120 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value))) {
      throw const DiscoveryException('The addon settings are invalid.');
    }
    return DiscoveryAddonConfig(
      id: id,
      endpoint: normalizedEndpoint,
      manifestUrl: manifestUrl,
      label: label.trim(),
      token: trimmedToken,
      settings: Map.unmodifiable(settings),
      enabled: enabled,
    );
  }

  static String createId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

class DiscoverySettings {
  const DiscoverySettings({
    this.youtubeEnabled = false,
    this.addons = const [],
  });

  static const maxAddons = 8;

  final bool youtubeEnabled;
  final List<DiscoveryAddonConfig> addons;

  List<DiscoveryAddonConfig> get activeAddons =>
      List.unmodifiable(addons.where((addon) => addon.enabled));
  bool get hasSource => youtubeEnabled || addons.any((addon) => addon.enabled);

  DiscoverySettings validated() {
    if (addons.length > maxAddons) {
      throw const DiscoveryException(
        'At most eight music addons can be saved.',
      );
    }
    final ids = <String>{};
    final endpoints = <String>{};
    final validatedAddons = <DiscoveryAddonConfig>[];
    for (final addon in addons) {
      final validated = addon.validated();
      if (!ids.add(validated.id) || !endpoints.add(validated.endpoint)) {
        throw const DiscoveryException('Each music addon must be unique.');
      }
      validatedAddons.add(validated);
    }
    return DiscoverySettings(
      youtubeEnabled: youtubeEnabled,
      addons: List.unmodifiable(validatedAddons),
    );
  }
}

/// Store the whole record securely: reference addons may put secrets in paths.
/// No shared-preferences copy, logs, account cookies or provider credentials.
class DiscoverySettingsStore {
  DiscoverySettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const PlaybackSecureStorage();
  final FlutterSecureStorage _storage;
  // The secure slot stays stable across schema versions.
  static const _key = 'konnekted.discovery.sources.v1';

  Future<DiscoverySettings> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return const DiscoverySettings();
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['version'] is! int ||
          json['youtubeEnabled'] is! bool) {
        throw const FormatException();
      }
      final List<DiscoveryAddonConfig> addons;
      switch (json['version']) {
        case 1:
          final endpoint = json['endpoint'];
          final token = json['token'];
          final enabled = json['addonEnabled'];
          if (endpoint is! String || token is! String || enabled is! bool) {
            throw const FormatException();
          }
          addons = endpoint.trim().isEmpty && token.trim().isEmpty
              ? const []
              : [
                  DiscoveryAddonConfig(
                    id: 'legacy-addon',
                    endpoint: endpoint,
                    token: token,
                    enabled: enabled,
                  ),
                ];
        case 2:
          final entries = json['addons'];
          if (entries is! List ||
              entries.length > DiscoverySettings.maxAddons) {
            throw const FormatException();
          }
          addons = entries.map(_decodeAddon).toList();
        default:
          throw const FormatException();
      }
      return DiscoverySettings(
        youtubeEnabled: json['youtubeEnabled'] as bool,
        addons: addons,
      ).validated();
    } catch (_) {
      throw const DiscoveryException(
        'Saved source settings are invalid. Reconfigure sources to continue.',
      );
    }
  }

  static DiscoveryAddonConfig _decodeAddon(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['endpoint'] is! String ||
        value['label'] is! String ||
        value['token'] is! String ||
        value['enabled'] is! bool) {
      throw const FormatException();
    }
    return DiscoveryAddonConfig(
      id: value['id'] as String,
      endpoint: value['endpoint'] as String,
      manifestUrl: value['manifestUrl'] == null
          ? null
          : value['manifestUrl'] is String
              ? value['manifestUrl'] as String
              : throw const FormatException(),
      label: value['label'] as String,
      token: value['token'] as String,
      enabled: value['enabled'] as bool,
      settings: value['settings'] == null
          ? const {}
          : _decodeSettings(value['settings']),
    );
  }

  static Map<String, String> _decodeSettings(Object? raw) {
    if (raw is! Map || raw.length > 16 ||
        raw.keys.any((key) => key is! String) ||
        raw.values.any((value) => value is! String)) {
      throw const FormatException();
    }
    return Map<String, String>.from(raw);
  }

  Future<void> save(DiscoverySettings settings) async {
    final validated = settings.validated();
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'version': 2,
          'youtubeEnabled': validated.youtubeEnabled,
          'addons': [
            for (final addon in validated.addons)
              {
                'id': addon.id,
                'endpoint': addon.endpoint,
                if (addon.manifestUrl != null) 'manifestUrl': addon.manifestUrl,
                'label': addon.label,
                'token': addon.token,
                if (addon.settings.isNotEmpty) 'settings': addon.settings,
                'enabled': addon.enabled,
              },
          ],
        }),
      );
    } catch (_) {
      throw const DiscoveryException(
        'Source settings could not be saved. Try again.',
      );
    }
  }
}
