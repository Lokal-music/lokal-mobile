import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

import 'morneye_auth_sheet.dart';
import 'morneye_packages.dart';
import 'morneye_service.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';

/// Loads the add-on manager for a panel, or the test's stand-in.
typedef MorneyePackagesLoader = Future<MorneyePackages> Function();

/// Morneye add-ons on a page of their own: the same panels Settings ›
/// Online sources shows, for a link straight to them.
class MorneyeAddonsScreen extends StatelessWidget {
  const MorneyeAddonsScreen({super.key, this.service});

  final MorneyeService? service;

  @override
  Widget build(BuildContext context) => LokalSettingsScaffold(
    title: 'Add-ons',
    subtitle: 'Extra places Search and Discovery can find songs.',
    children: [
      LokalSettingsSection(
        title: 'Add-ons',
        children: [MorneyeAddonsPanel(service: service)],
      ),
      LokalSettingsSection(
        title: 'Add-on repositories',
        children: [MorneyeRepositoriesPanel(service: service)],
      ),
    ],
  );
}

/// The add-on manager, loaded once, with the panel's busy state and its
/// messages.
mixin _MorneyePanel<T extends StatefulWidget> on State<T> {
  MorneyeService? get _injected;
  MorneyePackagesLoader? get _loader;

  MorneyeService get _service => _injected ?? MorneyeService.instance;
  MorneyePackages? _packages;
  Object? _loadError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);
    unawaited(_load());
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final packages = await (_loader?.call() ?? _service.packages);
      if (!mounted) return;
      setState(() => _packages = packages);
      if (_loader == null) {
        await packages.refreshDue();
        _service.changed();
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _say(String message) {
    if (mounted) LokalToast.show(context, message);
  }

  /// Runs [work] with the panel busy; its error, if any, as a message.
  Future<R?> _run<R>(Future<R> Function() work, {String? done}) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final result = await work();
      if (done != null) _say(done);
      return result;
    } catch (error) {
      _say('$error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
      _service.changed();
    }
  }

  void _installed(MorneyeAddon addon) => _say(
    '${addon.displayName} installed. Set it up below, then find it in Search.',
  );

  /// The panel while the manager loads, or why it couldn't.
  Widget? _loading() {
    if (_packages != null) return null;
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: _loadError == null
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.accent,
                ),
              )
            : Text(
                'Add-ons couldn’t be opened: $_loadError',
                textAlign: TextAlign.center,
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
      ),
    );
  }

  Widget _rows(List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const LokalSettingsDivider(),
        rows[i],
      ],
    ],
  );
}

/// Installed add-ons, each with what it can do, its switch and its setup;
/// then installing a package file and the third-party notice.
class MorneyeAddonsPanel extends StatefulWidget implements LokalSearchable {
  const MorneyeAddonsPanel({super.key, this.service, this.loader});

  final MorneyeService? service;

  /// Replaces the app's add-on manager, for tests.
  @visibleForTesting
  final MorneyePackagesLoader? loader;

  @override
  String get searchText =>
      'Morneye add-ons installed setup verify log in install package file';

  @override
  State<MorneyeAddonsPanel> createState() => _MorneyeAddonsPanelState();
}

class _MorneyeAddonsPanelState extends State<MorneyeAddonsPanel>
    with _MorneyePanel {
  @override
  MorneyeService? get _injected => widget.service;
  @override
  MorneyePackagesLoader? get _loader => widget.loader;

  Future<void> _installFile(MorneyePackages packages) async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    if (!morneyeIsPackageFileName(file.name)) {
      _say('Choose a .sflx, .spotiflac-ext or .morneye-ext package');
      return;
    }
    final addon = await _run(
      () async => packages.install(bytes: await file.readAsBytes()),
    );
    if (addon != null) _installed(addon);
  }

  @override
  Widget build(BuildContext context) {
    final loading = _loading();
    if (loading != null) return loading;
    final packages = _packages!;
    final t = context.lokal;
    final addons = packages.addons;
    return _rows([
      if (addons.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No add-ons yet',
                style: TextStyle(
                  fontFamily: LokalTheme.sans,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Install one from a repository below or from a package file. '
                'Installed add-ons appear in Search once they’re set up.',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: t.muted),
              ),
            ],
          ),
        ),
      for (final addon in addons)
        _AddonRow(
          key: ValueKey(addon.key),
          packages: packages,
          addon: addon,
          onChanged: _service.changed,
        ),
      LokalSettingRow(
        label: 'Install from file',
        description: 'A .sflx, .spotiflac-ext or .morneye-ext package.',
        icon: Icons.file_open_rounded,
        enabled: !_busy,
        onTap: () => _installFile(packages),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: LokalSettingsNotice(
          warning: true,
          text:
              'Add-ons are made and run by third parties. Lokal doesn’t host, '
              'check or vouch for any of them, and you’re responsible for the '
              'ones you add. Only add add-ons you trust and are allowed to use '
              'where you live.',
        ),
      ),
    ]);
  }
}

/// Add-on repositories with their refresh and removal, a field to add one,
/// and the packages they offer.
class MorneyeRepositoriesPanel extends StatefulWidget
    implements LokalSearchable {
  const MorneyeRepositoriesPanel({super.key, this.service, this.loader});

  final MorneyeService? service;

  /// Replaces the app's add-on manager, for tests.
  @visibleForTesting
  final MorneyePackagesLoader? loader;

  @override
  String get searchText =>
      'Add-on repositories registry available add-ons install update';

  @override
  State<MorneyeRepositoriesPanel> createState() =>
      _MorneyeRepositoriesPanelState();
}

class _MorneyeRepositoriesPanelState extends State<MorneyeRepositoriesPanel>
    with _MorneyePanel {
  @override
  MorneyeService? get _injected => widget.service;
  @override
  MorneyePackagesLoader? get _loader => widget.loader;

  final _repoUrl = TextEditingController();

  @override
  void dispose() {
    _repoUrl.dispose();
    super.dispose();
  }

  Future<void> _addRepo(MorneyePackages packages) async {
    final url = _repoUrl.text.trim();
    if (url.isEmpty) return;
    final repo = await _run(() => packages.addRepo(url));
    if (repo != null) _repoUrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final loading = _loading();
    if (loading != null) return loading;
    final packages = _packages!;
    final t = context.lokal;
    final catalogue = packages.catalogue();
    return _rows([
      for (final repo in packages.repositories)
        LokalSettingRow(
          label: repo.official ? 'Morneye official' : repo.name,
          description:
              repo.error ??
              (repo.refreshedAt == null
                  ? 'Not refreshed yet'
                  : '${repo.entries.length} add-ons'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Refresh repository',
                onPressed: _busy
                    ? null
                    : () => _run(() => packages.refreshRepo(repo.id)),
                icon: Icon(Icons.refresh_rounded, color: t.muted),
              ),
              if (!repo.official)
                IconButton(
                  tooltip: 'Remove repository',
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          packages.removeRepo(repo.id);
                        }),
                  icon: Icon(Icons.delete_outline_rounded, color: t.muted),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _repoUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: TextStyle(color: t.text, fontSize: 13.5),
                decoration: lokalInputDecoration(
                  context,
                  label: 'Add a repository',
                  hint: 'https://…/registry.json',
                ),
                onSubmitted: (_) => _addRepo(packages),
              ),
            ),
            const SizedBox(width: 10),
            LokalSettingButton(
              label: 'Add',
              onPressed: _busy ? null : () => _addRepo(packages),
            ),
          ],
        ),
      ),
      if (_busy)
        LinearProgressIndicator(
          minHeight: 2,
          color: t.accent,
          backgroundColor: t.surface3,
        ),
      for (final entry in catalogue)
        LokalSettingRow(
          label: entry.name,
          description: [
            'v${entry.version}',
            !entry.compatible
                ? 'Needs a newer Morneye version'
                : entry.category == 'integration'
                ? 'Reads playlist links'
                : entry.description,
          ].where((s) => s.isNotEmpty).join(' · '),
          trailing: LokalSettingButton(
            label: entry.updateAvailable
                ? 'Update'
                : entry.installed != null
                ? 'Installed'
                : 'Install',
            onPressed:
                _busy ||
                    !entry.compatible ||
                    (entry.installed != null && !entry.updateAvailable)
                ? null
                : () async {
                    final addon = await _run(
                      () => packages.install(
                        repositoryId: entry.repositoryId,
                        id: entry.id,
                      ),
                    );
                    if (addon != null) _installed(addon);
                  },
          ),
        ),
    ]);
  }
}

/// One installed add-on: what it can do, its setup state with the action
/// that finishes it, its switch; opened, its settings, account and removal.
class _AddonRow extends StatefulWidget {
  const _AddonRow({
    super.key,
    required this.packages,
    required this.addon,
    required this.onChanged,
  });

  final MorneyePackages packages;
  final MorneyeAddon addon;
  final VoidCallback onChanged;

  @override
  State<_AddonRow> createState() => _AddonRowState();
}

class _AddonRowState extends State<_AddonRow> {
  bool _open = false;
  bool _busy = false;
  bool _confirmRemove = false;
  String? _message;
  late Map<String, Object?> _values = widget.packages.settings(widget.addon);
  Map<String, Object?>? _form;
  final _formInput = <String, Object?>{};

  MorneyePackages get _packages => widget.packages;
  MorneyeAddon get _addon => widget.addon;

  Future<T?> _run<T>(Future<T> Function() work) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      return await work();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  /// Opens [url] in the login sheet, then checks access again.
  Future<void> _openAuth(String url) async {
    if (Uri.tryParse(url)?.scheme != 'https') {
      setState(() => _message = 'The add-on gave a page that isn’t secure.');
      return;
    }
    await MorneyeAuthSheet.show(
      context,
      packages: _packages,
      addon: _addon,
      url: url,
    );
    final status = await _run(() => _packages.authStatus(_addon.key));
    if (!mounted || status == null) return;
    setState(
      () => _message = status['authenticated'] == true
          ? 'Access verified. This add-on can now play and download.'
          : 'Verification wasn’t completed. Try again when you’re ready.',
    );
  }

  Future<void> _verify() async {
    final url = await _run(() => _packages.verify(_addon.key));
    if (!mounted) return;
    if (url == null) {
      if (_message == null) setState(() => _message = 'Access verified.');
      return;
    }
    await _openAuth(url);
  }

  Future<void> _action(String id, {Object? input, String? token}) async {
    final result = await _run(
      () => _packages.invokeAction(_addon.key, id, input: input, token: token),
    );
    if (!mounted || result == null) return;
    final schema = result['action_form'] ?? result['byoa_form'];
    setState(() {
      _form = schema is Map
          ? {...schema.cast<String, Object?>(), 'token': result['formToken']}
          : null;
      _formInput.clear();
      if (result['message'] != null) _message = '${result['message']}';
      if (result['success'] == false) {
        _message = '${result['error'] ?? 'The add-on action failed.'}';
      }
    });
    final auth = '${result['open_auth_url'] ?? ''}';
    if (auth.isNotEmpty) await _openAuth(auth);
  }

  /// What the add-on still needs, in a few words; `null` once it's ready.
  String? _needs(MorneyeAccess access) {
    if (!_addon.enabled || access.ready) return null;
    if (access.missing.isNotEmpty) return 'Needs ${access.missing.join(', ')}';
    return access.kind == 'login' ? 'Needs login' : 'Needs verification';
  }

  /// The button that finishes setup, shown on the row itself.
  Widget? _setupAction(MorneyeAccess access) {
    if (!_addon.enabled || access.ready) return null;
    if (access.kind == 'verification' && !access.verified) {
      return LokalSettingButton(
        label: 'Verify',
        onPressed: _busy ? null : _verify,
      );
    }
    return LokalSettingButton(
      label: access.kind == 'login' ? 'Log in' : 'Set up',
      onPressed: () => setState(() => _open = true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final access = _packages.access(_addon);
    final needs = _needs(access);
    final setup = _setupAction(access);
    final capabilities = [
      if (_addon.searches) 'Search',
      if (_addon.downloads) 'Download',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 14, top: 1),
                  child: Icon(
                    Icons.extension_rounded,
                    size: 22,
                    color: _addon.enabled ? t.accent : t.muted2,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _addon.displayName,
                        style: TextStyle(
                          fontFamily: LokalTheme.sans,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _addon.enabled ? t.text : t.muted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final c in capabilities)
                            LokalStatusPill(label: c),
                          if (!_addon.enabled)
                            const LokalStatusPill(label: 'Off')
                          else if (needs != null)
                            LokalStatusPill(label: needs, warning: true)
                          else
                            const LokalStatusPill(label: 'Ready', active: true),
                        ],
                      ),
                      if (setup != null) ...[const SizedBox(height: 10), setup],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  label: '${_addon.displayName} enabled',
                  child: LokalOnOffPill(
                    value: _addon.enabled,
                    onChanged: _busy
                        ? null
                        : (on) => _run(() async {
                            _packages.setEnabled(_addon.key, on);
                          }),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? _details(access)
              : const SizedBox(width: double.infinity),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 16, 14),
            child: Text(
              _message!,
              style: TextStyle(color: t.muted, fontSize: 12.5),
            ),
          ),
      ],
    );
  }

  Widget _details(MorneyeAccess access) {
    final t = context.lokal;
    final quality = _addon.qualityOptions.whereType<Map>().toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(52, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (_addon.version.isNotEmpty) 'v${_addon.version}',
              if (_addon.description.isNotEmpty) _addon.description,
            ].join(' · '),
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final field in _addon.settingsSchema.whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SettingField(
                field: field,
                value: _values['${field['key']}'],
                onChanged: (value) =>
                    setState(() => _values['${field['key']}'] = value),
                onAction: (action) => _action(action),
              ),
            ),
          if (quality.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SettingField(
                field: {
                  'key': 'downloadQuality',
                  'label': 'Playback & download quality',
                  'type': 'select',
                  'options': [
                    for (final q in quality)
                      {'value': q['id'], 'label': q['label'] ?? q['id']},
                  ],
                },
                value: _values['downloadQuality'] ?? quality.first['id'],
                onChanged: (value) =>
                    setState(() => _values['downloadQuality'] = value),
              ),
            ),
          if (quality.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Lokal requests the selected format on playback and download. '
                'Spatial audio requires native decoder support; availability '
                'is checked from the delivered file, not search tags.',
                style: TextStyle(color: t.muted, fontSize: 12),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_addon.settingsSchema.isNotEmpty || quality.length > 1)
                LokalSettingButton(
                  label: 'Save settings',
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final before = jsonEncode(_packages.settings(_addon));
                          _packages.setSettings(_addon.key, _values);
                          _values = _packages.settings(_addon);
                          final changed = before != jsonEncode(_values);
                          if (changed) {
                            // Every addon and every tier uses the same fresh
                            // playback-resolution path. Never replay cached
                            // audio encoded at the previous quality setting.
                            await onOnlineAddonSettingsChanged(_addon.key);
                          }
                          if (mounted) {
                            setState(() => _message = changed
                                ? 'Settings saved. Playback quality updated.'
                                : 'Settings saved');
                          }
                        }),
                ),
              for (final action in _addon.globalActions.whereType<Map>())
                LokalSettingButton(
                  label: '${action['label'] ?? action['action']}',
                  onPressed: _busy
                      ? null
                      : () => _action('${action['action']}'),
                ),
            ],
          ),
          if (access.kind == 'verification' || access.kind == 'login') ...[
            const SizedBox(height: 12),
            Text(
              access.verified
                  ? 'Access is active.'
                  : access.kind == 'verification'
                  ? 'This add-on needs a one-time verification before it can '
                        'play or download. A page opens; it closes by itself '
                        'when access is confirmed.'
                  : 'Log in with the add-on’s button above to play and '
                        'download from it.',
              style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (access.kind == 'verification' && !access.verified)
                  LokalSettingButton(
                    label: 'Verify access',
                    onPressed: _busy || !_addon.enabled ? null : _verify,
                  ),
                if (access.verified)
                  LokalSettingButton(
                    label: 'Disconnect',
                    onPressed: _busy
                        ? null
                        : () => _run(() => _packages.logout(_addon.key)),
                  ),
              ],
            ),
          ],
          if (_form case final form?) _accountForm(form),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: _confirmRemove
                ? Wrap(
                    spacing: 8,
                    children: [
                      LokalSettingButton(
                        label: 'Cancel',
                        onPressed: () => setState(() => _confirmRemove = false),
                      ),
                      LokalSettingButton(
                        label: 'Remove',
                        destructive: true,
                        onPressed: _busy
                            ? null
                            : () => _run(() => _packages.remove(_addon.key)),
                      ),
                    ],
                  )
                : LokalSettingButton(
                    label: 'Remove add-on',
                    destructive: true,
                    onPressed: () => setState(() => _confirmRemove = true),
                  ),
          ),
        ],
      ),
    );
  }

  /// A login form the add-on asked for (desktop's "action form").
  Widget _accountForm(Map<String, Object?> form) {
    final t = context.lokal;
    final fields = (form['fields'] as List? ?? const []).whereType<Map>();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${form['title'] ?? 'Account details'}',
            style: TextStyle(
              fontFamily: LokalTheme.sans,
              color: t.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (form['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${form['description']}',
                style: TextStyle(color: t.muted, fontSize: 12.5),
              ),
            ),
          const SizedBox(height: 12),
          for (final field in fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SettingField(
                field: {
                  ...field,
                  'secret': const {'password', 'otp'}.contains(field['type']),
                  if (field['options'] is List)
                    'options': [
                      for (final o in field['options'] as List)
                        {'value': o, 'label': o},
                    ],
                },
                value: _formInput['${field['key']}'] ?? field['default'],
                onChanged: (value) =>
                    setState(() => _formInput['${field['key']}'] = value),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              LokalSettingButton(
                label: 'Continue',
                onPressed: _busy
                    ? null
                    : () => _action(
                        '${form['submit_action']}',
                        input: Map.of(_formInput),
                        token: form['token'] as String?,
                      ),
              ),
              LokalSettingButton(
                label: 'Cancel',
                onPressed: () => setState(() {
                  _form = null;
                  _formInput.clear();
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One field from an add-on's manifest `settings`, as desktop draws it.
class _SettingField extends StatelessWidget {
  const _SettingField({
    required this.field,
    required this.value,
    required this.onChanged,
    this.onAction,
  });

  final Map field;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final label = '${field['label'] ?? field['key']}';
    final help = field['description'] ?? field['help'];
    final helpText = help == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '$help',
              style: TextStyle(color: t.muted, fontSize: 11.5),
            ),
          );
    final current = value ?? field['default'];
    switch (field['type']) {
      case 'button':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LokalSettingButton(
              label: label,
              onPressed: () => onAction?.call('${field['action']}'),
            ),
            ?helpText,
          ],
        );
      case 'boolean':
      case 'toggle':
        final on = current == true || current == 'true';
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: LokalTheme.sans,
                      color: t.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  ?helpText,
                ],
              ),
            ),
            const SizedBox(width: 12),
            LokalOnOffPill(value: on, onChanged: onChanged),
          ],
        );
      case 'select':
        final options = [
          for (final o in field['options'] as List? ?? const [])
            o is Map ? o : {'value': o, 'label': o},
        ];
        final selected = options.any((o) => o['value'] == current)
            ? current
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<Object?>(
              initialValue: selected,
              isExpanded: true,
              dropdownColor: t.surface2,
              style: TextStyle(color: t.text, fontSize: 13.5),
              decoration: lokalInputDecoration(context, label: label),
              items: [
                for (final o in options)
                  DropdownMenuItem(
                    value: o['value'],
                    child: Text('${o['label'] ?? o['value']}'),
                  ),
              ],
              onChanged: onChanged,
            ),
            ?helpText,
          ],
        );
      default:
        final secret = field['secret'] == true || field['type'] == 'password';
        final number = field['type'] == 'number';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: secret ? '' : '${current ?? ''}',
              obscureText: secret,
              autocorrect: false,
              keyboardType: number ? TextInputType.number : TextInputType.text,
              style: TextStyle(color: t.text, fontSize: 13.5),
              decoration: lokalInputDecoration(
                context,
                label: label,
                hint: secret
                    ? 'Leave empty to keep the saved value'
                    : field['placeholder'] as String?,
              ),
              onChanged: onChanged,
            ),
            ?helpText,
          ],
        );
    }
  }
}
