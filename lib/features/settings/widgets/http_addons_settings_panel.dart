import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/discovery/discovery_settings.dart';
import 'package:flick/features/discovery/discovery_sources.dart';
import 'package:flick/services/playback_source_priority.dart';

/// Inline HTTP catalogue setup for Settings › Online sources.
/// A manifest is checked before the source is stored or enabled.
class HttpAddonsSettingsPanel extends StatefulWidget {
  const HttpAddonsSettingsPanel({
    super.key,
    this.initial,
    this.store,
    this.client,
  });

  final DiscoverySettings? initial;
  final DiscoverySettingsStore? store;

  /// An injected client is owned by the caller and is never closed here.
  final http.Client? client;

  @override
  State<HttpAddonsSettingsPanel> createState() => _HttpAddonsSettingsPanelState();
}

class _HttpAddonsSettingsPanelState extends State<HttpAddonsSettingsPanel> {
  late final DiscoverySettingsStore _store;
  late final http.Client _client;
  final _url = TextEditingController();
  DiscoverySettings? _settings;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _message;

  List<DiscoveryAddonConfig> get _addons =>
      _settings?.addons ?? const <DiscoveryAddonConfig>[];

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? DiscoverySettingsStore();
    _client = widget.client ?? http.Client();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = widget.initial ?? await _store.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Saved sources could not be loaded. Try again.';
        _loading = false;
      });
    }
  }

  DiscoverySettings _withAddons(List<DiscoveryAddonConfig> addons) =>
      DiscoverySettings(
        youtubeEnabled: _settings!.youtubeEnabled,
        addons: List.unmodifiable(addons),
      ).validated();

  // A display name must not disclose a path token or an embedded URL.
  String _manifestLabel(String name, String fallback) {
    final label = discoveryText(name, maxLength: 80);
    if (label == null ||
        label.contains('://') ||
        label.contains('/') ||
        label.contains(String.fromCharCode(92)) ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(label)) {
      return fallback;
    }
    return label;
  }

  Future<void> _add() async {
    final current = _settings;
    final raw = _url.text.trim();
    if (_busy || _loading || current == null || raw.isEmpty) return;
    if (current.addons.length >= DiscoverySettings.maxAddons) {
      setState(() => _error = 'Remove a source before adding another.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final endpoint = normalizeAddonEndpoint(raw).toString();
      if (current.addons.any((addon) => addon.endpoint == endpoint)) {
        throw const DiscoveryException('This source is already added.');
      }

      final pastedUri = requireHttps(raw);
      final exactManifest = pastedUri.pathSegments.lastOrNull == 'manifest.json'
          ? pastedUri
          : null;
      final health = await DiscoveryAddon(
        DiscoveryHttp(_client),
        endpoint: endpoint,
      ).health(exactManifestUrl: exactManifest);
      // Streaming-only addons (allowDownloads: 0) are valid sources.
      // Explicit saves remain blocked by DiscoveryAddon.resolve(forDownload: true).

      final host = Uri.parse(endpoint).host.toLowerCase().replaceFirst(
        RegExp(r'^www\\.'),
        '',
      );
      final baseLabel = _manifestLabel(
        health.name,
        host.isEmpty ? 'Music source' : host,
      );
      var label = baseLabel;
      var suffix = 2;
      while (current.addons.any(
        (addon) => addon.label.toLowerCase() == label.toLowerCase(),
      )) {
        label = '$baseLabel ($suffix)';
        suffix++;
      }
      final addon = DiscoveryAddonConfig(
        id: DiscoveryAddonConfig.createId(),
        endpoint: endpoint,
        manifestUrl: exactManifest?.toString(),
        // Safe manifest name, never the credential-bearing endpoint.
        label: label,
        settings: {
          for (final setting in health.settings)
            setting.key: setting.defaultValue,
        },
        enabled: true,
      ).validated();
      final next = _withAddons([...current.addons, addon]);
      await _store.save(next);
      // The source is installed even if device preferences are temporarily
      // unavailable; surface that separately instead of retrying the install.
      var prioritySaved = true;
      try {
        await PlaybackSourcePriority.promoteNewAddon('w-${addon.id}');
      } catch (_) {
        prioritySaved = false;
      }
      if (!mounted) return;
      _url.clear();
      setState(() {
        _settings = next;
        _message = prioritySaved
            ? 'Source added and enabled at the top of playback priority.'
            : 'Source added, but playback priority could not be saved.';
      });
    } catch (error) {
      if (mounted) {
        // Installation only probes the manifest, not a search or stream.
        // Report the failing stage and status without disclosing private
        // addon URLs (which may contain path-based access tokens).
        final message = error is DiscoveryException &&
                error.message.contains('HTTP 404')
            ? 'The add-on manifest returned HTTP 404. Check that the '
                'manifest.json link is valid and still accessible.'
            : discoveryError(error);
        setState(() => _error = message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _persist(DiscoverySettings next, String message) async {
    if (_busy || _loading || _settings == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await _store.save(next);
      if (!mounted) return;
      setState(() {
        _settings = next;
        _message = message;
      });
    } catch (error) {
      if (mounted) setState(() => _error = discoveryError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(int index, bool enabled) async {
    final current = _settings;
    if (current == null || index < 0 || index >= current.addons.length) return;
    final old = current.addons[index];
    final updated = DiscoveryAddonConfig(
      id: old.id,
      endpoint: old.endpoint,
      manifestUrl: old.manifestUrl,
      label: old.label,
      token: old.token,
      settings: old.settings,
      enabled: enabled,
    );
    final addons = [...current.addons];
    addons[index] = updated;
    await _persist(_withAddons(addons), 'Source updated.');
  }

  Future<void> _editSettings(int index) async {
    final current = _settings;
    if (_busy || current == null || index < 0 || index >= current.addons.length) {
      return;
    }
    final old = current.addons[index];
    setState(() {
      _busy = true;
      _error = null;
    });
    AddonHealth health;
    try {
      health = await DiscoveryAddon(
        DiscoveryHttp(_client),
        endpoint: old.endpoint,
        token: old.token,
        exactManifestUrl: old.manifestUrl == null
            ? null
            : Uri.parse(old.manifestUrl!),
      ).health();
    } catch (error) {
      if (mounted) setState(() => _error = discoveryError(error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final selected = <String, String>{
      for (final setting in health.settings)
        setting.key: setting.options.any(
          (option) => option.value == old.settings[setting.key],
        )
          ? old.settings[setting.key]!
          : setting.defaultValue,
    };
    final choices = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Settings · ${old.displayName}'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: health.settings.isEmpty
                    ? [const Text('This add-on has no configurable options.')]
                    : [
                        for (final setting in health.settings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('http-addon-setting-${setting.key}'),
                              value: selected[setting.key],
                              decoration: InputDecoration(
                                labelText: setting.label,
                                border: const OutlineInputBorder(),
                              ),
                              isExpanded: true,
                              items: [
                                for (final option in setting.options)
                                  DropdownMenuItem(
                                    value: option.value,
                                    child: Text(option.label),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setDialogState(
                                    () => selected[setting.key] = value,
                                  );
                                }
                              },
                            ),
                          ),
                      ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                Map<String, String>.from(selected),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choices == null) return;
    final latest = _settings;
    if (latest == null || index >= latest.addons.length ||
        latest.addons[index].id != old.id ||
        latest.addons[index].endpoint != old.endpoint) return;
    final domain = Uri.parse(old.endpoint).host.toLowerCase().replaceFirst(
      RegExp(r'^www\.'),
      '',
    );
    final label = old.label == domain || old.label == 'Music addon'
        ? _manifestLabel(health.name, domain)
        : old.label;
    final edited = DiscoveryAddonConfig(
      id: old.id,
      endpoint: old.endpoint,
      manifestUrl: old.manifestUrl,
      label: label,
      token: old.token,
      settings: choices,
      enabled: old.enabled,
    );
    final addons = [...latest.addons];
    addons[index] = edited;
    await _persist(_withAddons(addons), 'Add-on settings saved.');
  }

  Future<void> _remove(int index) async {
    final current = _settings;
    if (current == null || index < 0 || index >= current.addons.length) return;
    final addons = [...current.addons]..removeAt(index);
    await _persist(_withAddons(addons), 'Source removed.');
  }

  @override
  void dispose() {
    _url.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final addons = _addons;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'HTTP music add-ons',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Paste an HTTPS manifest.json link. It is checked before being added.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('http-addon-manifest-url'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_loading &&
                      !_busy &&
                      addons.length < DiscoverySettings.maxAddons,
                  onSubmitted: (_) => _add(),
                  decoration: const InputDecoration(
                    hintText: 'https://example.com/manifest.json',
                    prefixIcon: Icon(Icons.link_rounded),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('http-addon-add'),
                tooltip: 'Add source',
                onPressed: _loading ||
                        _busy ||
                        _settings == null ||
                        addons.length >= DiscoverySettings.maxAddons
                    ? null
                    : _add,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const ValueKey('http-addon-error'),
              style: TextStyle(color: colors.error),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(
              _message!,
              key: const ValueKey('http-addon-message'),
              style: TextStyle(color: colors.primary),
            ),
          ],
          if (addons.isNotEmpty) ...[
            const Divider(height: 24),
            for (var index = 0; index < addons.length; index++)
              ListTile(
                key: ValueKey('http-addon-${addons[index].id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.extension_rounded),
                title: Text(addons[index].displayName),
                subtitle: Text(addons[index].enabled ? 'Enabled' : 'Disabled'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      key: ValueKey('http-addon-enabled-${addons[index].id}'),
                      value: addons[index].enabled,
                      onChanged: _busy
                          ? null
                          : (enabled) => _setEnabled(index, enabled),
                    ),
                    IconButton(
                      key: ValueKey('http-addon-settings-${addons[index].id}'),
                      tooltip: 'Settings for ${addons[index].displayName}',
                      onPressed: _busy ? null : () => _editSettings(index),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    IconButton(
                      tooltip: 'Remove ${addons[index].displayName}',
                      onPressed: _busy ? null : () => _remove(index),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
          ],
          if (!_loading && addons.isEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'No HTTP add-ons yet.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (addons.length >= DiscoverySettings.maxAddons)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Maximum of ${DiscoverySettings.maxAddons} sources reached.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
