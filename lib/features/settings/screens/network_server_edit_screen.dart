// Main sources
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:isar_community/isar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

// App constants and other app UI libraries
import '../../../core/utils/app_haptics.dart';

// Database, widgets, and service configurations
import '../../../data/database.dart';
import '../../../data/repositories/song_repository.dart';
import '../../../services/playlist_service.dart';
import '../../../services/sources/jellyfin_service.dart';
import '../../../services/sources/network_source_service.dart';
import '../../../services/sources/tidal_service.dart';
import '../../../services/sources/webdav_service.dart';

import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Add or edit a network server. All registered protocols are selectable;
/// each dispatches test/sync/stream through [networkSourceServiceFor].
class NetworkServerEditScreen extends StatefulWidget {
  const NetworkServerEditScreen({super.key, this.server});

  final NetworkServerEntity? server;

  @override
  State<NetworkServerEditScreen> createState() =>
      _NetworkServerEditScreenState();
}

class _ProtocolMeta {
  const _ProtocolMeta({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.urlHint,
    required this.passwordHelper,
  });
  final String id;
  final String label;
  final String subtitle;
  final IconData icon;
  final String urlHint;
  final String passwordHelper;
}

List<_ProtocolMeta> _protocolsFor(AppLocalizations l10n) => [
  _ProtocolMeta(
    id: NetworkProtocol.subsonic,
    label: l10n.subsonic,
    subtitle: l10n.navidromeAirsonicGonic,
    icon: LucideIcons.radio,
    urlHint: 'https://music.example.com/subsonic',
    passwordHelper: l10n.storedAsASaltedHashNever,
  ),
  _ProtocolMeta(
    id: NetworkProtocol.jellyfin,
    label: l10n.jellyfin,
    subtitle: l10n.jellyfinEmby,
    icon: LucideIcons.clapperboard,
    urlHint: 'https://jf.example.com',
    passwordHelper: l10n.keptInSecureStorageToRe,
  ),
  _ProtocolMeta(
    id: NetworkProtocol.webdav,
    label: l10n.webdav,
    subtitle: l10n.nextcloudOwncloudSabredav,
    icon: LucideIcons.cloud,
    urlHint: 'https://cloud.example.com/remote.php/dav/files/user',
    passwordHelper: l10n.httpBasicNeedsItRecoverableStored,
  ),
  _ProtocolMeta(
    id: NetworkProtocol.upnp,
    label: l10n.upnpDlna,
    subtitle: l10n.minimserverServiioKodi,
    icon: LucideIcons.cast,
    urlHint: 'http://192.168.1.10:8200/rootDesc.xml',
    passwordHelper: l10n.mostDlnaServersNeedNoPassword,
  ),
  _ProtocolMeta(
    id: NetworkProtocol.smb,
    label: 'SMB',
    subtitle: l10n.sambaWindowsShareTransportPending,
    icon: LucideIcons.hardDrive,
    urlHint: 'smb://nas/music',
    passwordHelper: l10n.storedEncodedPlaybackUnavailableInThis,
  ),
  _ProtocolMeta(
    id: NetworkProtocol.tidal,
    label: l10n.tidal,
    subtitle: l10n.signInWithYourAccountHifi,
    icon: LucideIcons.waves,
    urlHint: TidalService.tidalBaseUrl,
    passwordHelper: l10n.oauthSignInNoPasswordStored,
  ),
];

class _NetworkServerEditScreenState extends State<NetworkServerEditScreen> {
  late final TextEditingController _labelController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late String _selectedProtocol;
  bool _testing = false;
  bool? _testPassed;
  String? _testError;
  String? _certificateCandidateFingerprint;
  String? _certificateCandidateUrl;

  /// Set when Tidal sign-in can't auto-open the browser; the live banner shows
  /// it for manual copy/open while polling continues.
  String? _testVerificationUri;
  bool _saving = false;
  bool _isValid = false;

  bool get _isNew => widget.server == null;

  bool get _isTidal => _selectedProtocol == NetworkProtocol.tidal;

  /// Tidal OAuth token resolved during this session (device-code login).
  String? _resolvedToken;

  _ProtocolMeta get _meta =>
      _protocolsFor(l10n).firstWhere((p) => p.id == _selectedProtocol);

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _selectedProtocol = (server?.protocol.isNotEmpty ?? false)
        ? server!.protocol
        : NetworkProtocol.subsonic;
    _labelController = TextEditingController(text: server?.label ?? '');
    _urlController = TextEditingController(text: server?.baseUrl ?? '');
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController();
    _labelController.addListener(_updateValidity);
    _urlController.addListener(_updateValidity);
    _isValid =
        _labelController.text.trim().isNotEmpty &&
        _urlController.text.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _labelController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  static String? _safeOrigin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) return null;
    return uri.origin;
  }

  void _updateValidity() {
    if (_certificateCandidateUrl != null &&
        _urlController.text.trim() != _certificateCandidateUrl) {
      _certificateCandidateFingerprint = null;
      _certificateCandidateUrl = null;
      _testPassed = null;
      _testError = null;
      setState(() {});
    }
    final valid =
        _labelController.text.trim().isNotEmpty &&
        (_isTidal || _urlController.text.trim().isNotEmpty);
    if (_isValid != valid) setState(() => _isValid = valid);
  }

  /// Resolve the token to persist. When a password is typed it's resolved
  /// through the protocol service (local transform for Subsonic/WebDAV, a
  /// sign-in round-trip for Jellyfin). Otherwise the existing token is kept.
  /// Tidal has no password field — its device-code token is captured in
  /// [_resolvedToken] during [_testConnection], or the previously-stored
  /// sign-in is reused.
  Future<String?> _resolvePersistedToken() async {
    if (_isTidal) {
      if (_resolvedToken != null) return _resolvedToken;
      return widget.server?.token;
    }
    final password = _passwordController.text;
    if (password.isNotEmpty) {
      final draft = _draftEntity(token: null);
      return await networkSourceServiceFor(_selectedProtocol)
          .resolveToken(draft, password);
    }
    return widget.server?.token;
  }

  // Fresh entity, never the caller's in-memory row. Test Connection resolves
  // tokens from whatever is typed; mutating the shared entity here leaked
  // untested credentials into the list screen even when the edit was abandoned.
  NetworkServerEntity _draftEntity({String? token}) {
    final old = widget.server;
    return NetworkServerEntity()
      ..id = old?.id ?? Isar.autoIncrement
      ..lastSyncedAt = old?.lastSyncedAt
      ..label = _labelController.text.trim().isEmpty
          ? (_isTidal ? l10n.tidal : '')
          : _labelController.text.trim()
      ..protocol = _selectedProtocol
      ..baseUrl = _isTidal
          ? TidalService.tidalBaseUrl
          : _urlController.text.trim().replaceAll(RegExp(r'/+$'), '')
      ..username = _usernameController.text.trim().isEmpty
          ? null
          : _usernameController.text.trim()
      ..token = token ?? old?.token;
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testPassed = null;
      _testError = null;
      _testVerificationUri = null;
      _certificateCandidateFingerprint = null;
      _certificateCandidateUrl = null;
    });
    AppHaptics.tap();
    String? token;
    try {
      token = await _resolvePersistedToken();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = false;
        _testError = _humanError(e);
      });
      return;
    }
    if (_isTidal) {
      await _testTidal(token);
      return;
    }
    final entity = _draftEntity(token: token);
    try {
      final service = networkSourceServiceFor(_selectedProtocol);
      final ok = await service.ping(entity);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = ok;
        if (!ok) _testError = service.lastPingError;
        if (!ok && _selectedProtocol == NetworkProtocol.webdav) {
          final dav = WebdavService.instance;
          if (_safeOrigin(entity.baseUrl) == dav.untrustedCertificateOrigin) {
            _certificateCandidateFingerprint = dav.untrustedCertificateFingerprint;
            _certificateCandidateUrl = _urlController.text.trim();
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = false;
        _testError = _humanError(e);
      });
    }
  }

  /// Tidal's test button means "sign in and connect": ping any stored session,
  /// and when it's missing OR dead (expired/revoked refresh token — the old
  /// flow could never recover from that), run the device-code login. A fresh
  /// sign-in is persisted immediately; previously the token only lived in
  /// [_resolvedToken] and was silently dropped unless the user also tapped
  /// Add Server, so the account never stayed signed in.
  Future<void> _testTidal(String? storedToken) async {
    try {
      var ok =
          storedToken != null &&
          storedToken.isNotEmpty &&
          await TidalService.instance.ping(_draftEntity(token: storedToken));
      if (!ok) {
        final token = await TidalService.instance.signIn(
          onVerificationLink: (uri) {
            if (!mounted) return;
            setState(() => _testVerificationUri = uri);
          },
        );
        _resolvedToken = token;
        if (!mounted) return;
        setState(() => _testVerificationUri = null);
        ok = await TidalService.instance.ping(_draftEntity(token: token));
      }
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = ok;
      });
      if (ok && _resolvedToken != null) await _save(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = false;
        _testError = _humanError(e);
      });
    }
  }

  Future<void> _trustWebdavCertificate() async {
    final approvedFingerprint = _certificateCandidateFingerprint;
    if (_selectedProtocol != NetworkProtocol.webdav ||
        approvedFingerprint == null ||
        _certificateCandidateUrl != _urlController.text.trim()) return;
    setState(() {
      _testing = true;
      _testError = null;
    });
    try {
      final token = await _resolvePersistedToken();
      final ok = await WebdavService.instance
          .trustPresentedCertificate(
            _draftEntity(token: token),
            approvedFingerprint: approvedFingerprint,
          );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = ok;
        if (ok) {
          _certificateCandidateFingerprint = null;
          _certificateCandidateUrl = null;
        }
        if (!ok) _testError = WebdavService.instance.lastPingError ??
            'The certificate was not trusted because the WebDAV check failed.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testPassed = false;
        _testError = _humanError(e);
      });
    }
  }

  Future<void> _save({bool force = false}) async {
    if (!_isValid && !force) return;
    setState(() => _saving = true);
    String? token;
    try {
      token = await _resolvePersistedToken();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _testPassed = false;
        _testError = _humanError(e);
      });
      return;
    }
    final password = _passwordController.text;
    if (_selectedProtocol == NetworkProtocol.jellyfin &&
        token != null &&
        password.isNotEmpty) {
      await JellyfinService.instance.persistPassword(
        _draftEntity(token: token),
        password,
      );
    }
    await Database.instance.writeTxn(() async {
      await Database.networkServers.put(_draftEntity(token: token));
    });
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String _humanError(Object e) {
    final raw = e.toString();
    // Trim the "UnsupportedError: " / "Exception: " boilerplate.
    final colon = raw.indexOf(': ');
    return colon > 0 && colon < 24 ? raw.substring(colon + 2) : raw;
  }

  Future<void> _delete() async {
    final server = widget.server;
    if (server == null) return;
    AppHaptics.tap();
    final confirmed = await showLokalConfirmSheet(
      context: context,
      title: l10n.removeServer,
      message: l10n.deleteAndAllSongsAndPlaylists(server.label),
      confirmLabel: l10n.delete,
      destructive: true,
    );
    if (!confirmed) return;
    if (server.protocol == NetworkProtocol.jellyfin) {
      await JellyfinService.instance.forgetPassword(server.id);
    }
    await Database.instance.writeTxn(() async {
      await Database.networkServers.delete(server.id);
    });
    await SongRepository().deleteSongsForRemoteServer(server.id);
    await PlaylistService.instance.removeNetworkPlaylistsForServer(
      '${server.id}',
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  IconData get _testIcon => _testPassed == null
      ? LucideIcons.wifi
      : _testPassed!
      ? LucideIcons.checkCircle
      : LucideIcons.xCircle;

  String get _testLabel {
    if (_testPassed == true) {
      return _isTidal ? l10n.signedIn : l10n.connectionOk;
    }
    if (_testPassed == false) {
      return _isTidal ? l10n.signInFailedRetry : l10n.connectionFailedRetry;
    }
    if (_isTidal) {
      final hasToken =
          _resolvedToken != null || (widget.server?.token?.isNotEmpty ?? false);
      return hasToken ? l10n.testConnection : l10n.signInWithTidal;
    }
    return l10n.testConnection;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final protocols = _protocolsFor(l10n);
    return LokalSettingsScaffold(
      title: _isNew ? l10n.addServer : l10n.editServer,
      children: [
        LokalSettingsSection(
          title: l10n.protocol,
          children: [
            for (final protocol in protocols)
              LokalSettingRow(
                label: protocol.label,
                description: protocol.subtitle,
                icon: protocol.icon,
                enabled: _isNew || _selectedProtocol == protocol.id,
                trailing: Icon(
                  _selectedProtocol == protocol.id
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: _selectedProtocol == protocol.id ? t.accent : t.muted2,
                ),
                onTap: _isNew
                    ? () {
                        AppHaptics.tap();
                        setState(() {
                          _selectedProtocol = protocol.id;
                          _testPassed = null;
                          _testError = null;
                          _testVerificationUri = null;
                          _resolvedToken = null;
                        });
                      }
                    : null,
              ),
          ],
        ),
        if (_selectedProtocol == NetworkProtocol.smb)
          LokalSettingsBlock(
            top: 12,
            child: LokalSettingsNotice(text: l10n.smbSharesCanBeAddedNow),
          ),
        if (_isTidal)
          LokalSettingsBlock(
            top: 12,
            child: LokalSettingsNotice(text: l10n.signInWithYourOwnTidal),
          ),
        LokalSettingsSection(
          title: l10n.connection,
          children: [
            _TextFieldSetting(
              controller: _labelController,
              label: l10n.label,
              hint: l10n.my(_meta.label),
            ),
            if (!_isTidal) ...[
              _TextFieldSetting(
                controller: _urlController,
                label: l10n.serverUrl,
                hint: _meta.urlHint,
                keyboardType: TextInputType.url,
              ),
              _TextFieldSetting(
                controller: _usernameController,
                label: l10n.username,
              ),
              _TextFieldSetting(
                controller: _passwordController,
                label: l10n.password,
                obscureText: true,
                helperText: _isNew
                    ? _meta.passwordHelper
                    : l10n.leaveEmptyToKeepTheCurrent,
              ),
            ],
          ],
        ),
        LokalSettingsBlock(
          child: LokalSettingsActionButton(
            label: _testing ? '$_testLabel…' : _testLabel,
            icon: _testIcon,
            primary: false,
            expand: true,
            onPressed: _testing || _saving ? null : _testConnection,
          ),
        ),
        if (_testing && _testVerificationUri != null)
          LokalSettingsBlock(top: 10, child: _buildSignInLinkBanner(context)),
        if (_testPassed == false)
          LokalSettingsBlock(top: 10, child: _buildFailureBanner(context)),
        if (!_testing &&
            _testPassed == false &&
            _selectedProtocol == NetworkProtocol.webdav &&
            _certificateCandidateFingerprint != null &&
            _certificateCandidateUrl == _urlController.text.trim() &&
            WebdavService.instance.untrustedCertificateOrigin ==
                _safeOrigin(_urlController.text.trim()))
          LokalSettingsBlock(
            top: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LokalSettingsNotice(
                  warning: true,
                  text: 'Self-signed HTTPS certificate on '
                      '${WebdavService.instance.untrustedCertificateOrigin}. '
                      'Verify its SHA-256 fingerprint independently before '
                      'approving it for this NAS only: '
                      '${_certificateCandidateFingerprint}',
                ),
                const SizedBox(height: 10),
                LokalSettingsActionButton(
                  label: 'Trust this certificate and retry',
                  icon: LucideIcons.shieldCheck,
                  primary: false,
                  expand: true,
                  onPressed: _trustWebdavCertificate,
                ),
              ],
            ),
          ),
        LokalSettingsBlock(
          top: 10,
          child: LokalSettingsActionButton(
            label: _saving
                ? '${_isNew ? l10n.addServer : l10n.save}…'
                : _isNew
                ? l10n.addServer
                : l10n.save,
            expand: true,
            onPressed: (_saving || !_isValid) ? null : _save,
          ),
        ),
        if (!_isNew)
          LokalSettingsBlock(
            child: LokalSettingsActionButton(
              label: l10n.removeServer2,
              icon: Icons.delete_outline_rounded,
              destructive: true,
              expand: true,
              onPressed: _saving ? null : _delete,
            ),
          ),
      ],
    );
  }

  Widget _buildFailureBanner(BuildContext context) => LokalSettingsNotice(
    warning: true,
    text:
        _testError ??
        'Could not reach the server. Check the URL and credentials, '
            'then try again.',
  );

  /// Shown live while Tidal device-code polling runs after the browser failed
  /// to auto-open. Offers manual copy/open of the verification link.
  Widget _buildSignInLinkBanner(BuildContext context) {
    final t = context.lokal;
    final uri = _testVerificationUri!;
    return LokalSettingsCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.couldnTOpenTheBrowserAutomatically,
            style: TextStyle(fontSize: 13, height: 1.4, color: t.text),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: t.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border),
            ),
            child: SelectableText(
              uri,
              style: LokalTheme.label(t, size: 12, color: t.text),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LokalSettingButton(
                label: l10n.openInBrowser,
                onPressed: () => _openLink(uri),
              ),
              LokalSettingButton(
                label: l10n.copyLink,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: uri));
                  AppHaptics.tap();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Open [uri] for the Tidal device flow in the default browser. If no
  /// default browser is set, the system shows its own chooser.
  Future<void> _openLink(String uri) async {
    AppHaptics.tap();
    try {
      await launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
    } catch (_) {
      /* nothing to do — the banner still shows the link */
    }
  }
}

/// A labelled text field as a settings row.
class _TextFieldSetting extends StatefulWidget {
  const _TextFieldSetting({
    required this.controller,
    required this.label,
    this.hint,
    this.helperText,
    this.obscureText = false,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helperText;
  final bool obscureText;
  final TextInputType? keyboardType;

  @override
  State<_TextFieldSetting> createState() => _TextFieldSettingState();
}

class _TextFieldSettingState extends State<_TextFieldSetting> {
  late bool _obscured = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.label.toUpperCase(), style: LokalTheme.label(t)),
          const SizedBox(height: 8),
          TextField(
            controller: widget.controller,
            obscureText: _obscured,
            keyboardType: widget.keyboardType,
            autocorrect: false,
            enableSuggestions: !_obscured,
            style: TextStyle(
              fontFamily: LokalTheme.sans,
              fontSize: 14,
              color: t.text,
            ),
            decoration: lokalInputDecoration(
              context,
              hint: widget.hint,
              helper: widget.helperText,
              suffixIcon: widget.obscureText
                  ? IconButton(
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        size: 18,
                      ),
                      color: t.muted,
                      tooltip: _obscured
                          ? l10n.showPassword
                          : l10n.hidePassword,
                      onPressed: () {
                        AppHaptics.tap();
                        setState(() => _obscured = !_obscured);
                      },
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
