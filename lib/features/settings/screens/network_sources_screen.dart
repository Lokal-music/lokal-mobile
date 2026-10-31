import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:isar_community/isar.dart';

import '../../../core/utils/app_haptics.dart';
import '../../../data/database.dart';
import '../../../data/repositories/song_repository.dart';
import '../../../services/library_scanner_service.dart' show ScanProgress;
import '../../../services/sources/network_source_service.dart';
import '../../../services/sources/smb_service.dart';
import 'network_server_edit_screen.dart';

import 'package:flick/l10n/l10n.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/widgets/lokal/settings/lokal_settings_kit.dart';

/// Manage configured network music servers (Subsonic, Jellyfin, WebDAV,
/// UPnP/DLNA, SMB, Tidal).
class NetworkSourcesScreen extends StatefulWidget {
  const NetworkSourcesScreen({super.key});

  @override
  State<NetworkSourcesScreen> createState() => _NetworkSourcesScreenState();
}

class _NetworkSourcesScreenState extends State<NetworkSourcesScreen> {
  List<NetworkServerEntity> _servers = [];
  final _songCounts = <int, int>{};
  int? _syncingId;
  ScanProgress? _syncProgress;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    final servers = await Database.networkServers.where().findAll();
    servers.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    final repo = SongRepository();
    final counts = <int, int>{};
    for (final s in servers) {
      counts[s.id] = await repo.countSongsByRemoteServer(s.id);
    }
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _songCounts
        ..clear()
        ..addAll(counts);
    });
  }

  Future<void> _openEditor({NetworkServerEntity? server}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NetworkServerEditScreen(server: server),
      ),
    );
    if (changed == true) {
      await _loadServers();
      await _autoSyncFreshTidal();
    }
  }

  /// A just-connected Tidal server has favorites waiting — kick the first
  /// sync automatically so signing in visibly leads to a library (bug report:
  /// "signed in but nothing happens"). Only fires for servers that have
  /// never synced.
  Future<void> _autoSyncFreshTidal() async {
    if (_syncingId != null) return;
    final fresh = _servers.where(
      (s) => s.protocol == NetworkProtocol.tidal && s.lastSyncedAt == null,
    );
    if (fresh.isEmpty) return;
    await _syncServer(fresh.first);
  }

  // Keep a direct route back to server settings for failures requiring
  // credentials, share configuration, or explicit TLS certificate approval.
  bool _needsConnectionFix(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('401') ||
        s.contains('403') ||
        s.contains('has no stored credentials') ||
        s.contains('authentication failed') ||
        s.contains('session expired') ||
        s.contains('status_access_denied') ||
        s.contains('certificate_verify_failed') ||
        s.contains('certificate validation failed') ||
        s.contains('handshakeexception');
  }

  String _syncFailureMessage(NetworkServerEntity server, Object error) {
    final raw = error.toString().toLowerCase();
    if (server.protocol == NetworkProtocol.smb &&
        (raw.contains('status_access_denied') ||
            raw.contains('authentication failed') ||
            raw.contains('session setup'))) {
      return '${server.label}: ${SmbService.describePingError(error)}';
    }
    if (server.protocol == NetworkProtocol.webdav &&
        (raw.contains('certificate') || raw.contains('handshakeexception'))) {
      return '${server.label}: WebDAV HTTPS certificate rejected. Open this '
          'server, tap Test connection, then independently verify and approve '
          'the displayed fingerprint. Certificates are never trusted silently.';
    }
    return l10n.syncFailed(error);
  }

  Future<void> _syncServer(NetworkServerEntity server) async {
    if (_syncingId != null) return;
    setState(() {
      _syncingId = server.id;
      _syncProgress = null;
    });
    try {
      await for (final progress in networkSourceServiceFor(
        server.protocol,
      ).syncLibrary(server)) {
        if (mounted && _syncingId == server.id) {
          setState(() => _syncProgress = progress);
        }
      }
    } catch (e) {
      if (mounted) {
        final needsFix = _needsConnectionFix(e);
        LokalToast.fromSnackBar(context,
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(_syncFailureMessage(server, e)),
            action: needsFix
                ? SnackBarAction(
                    label: l10n.fix,
                    onPressed: () => _openEditor(server: server),
                  )
                : null,
          ),
        );
      }
    }
    if (mounted) {
      setState(() {
        _syncingId = null;
        _syncProgress = null;
      });
      await _loadServers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LokalSettingsScaffold(
      title: l10n.networkSources,
      subtitle: 'Your own music servers, synced into your library.',
      children: [
        if (_servers.isEmpty)
          LokalSettingsBlock(child: _buildEmptyState(context))
        else
          LokalSettingsSection(
            title: 'Servers',
            children: [
              for (final server in _servers) _buildServerRow(context, server),
            ],
          ),
        if (_servers.isNotEmpty)
          LokalSettingsSection(
            title: 'Add',
            children: [
              LokalSettingRow(
                label: l10n.addServer,
                description: l10n.connectAMusicServer,
                icon: Icons.add_rounded,
                onTap: () => _openEditor(),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final t = context.lokal;
    return LokalSettingsCard(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_rounded, size: 36, color: t.muted),
          const SizedBox(height: 14),
          Text(
            l10n.noServersConnected,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: LokalTheme.sans,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: t.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.connectASubsonicJellyfinWebdavUpnp,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.4, color: t.muted),
          ),
          const SizedBox(height: 20),
          LokalSettingsActionButton(
            label: l10n.addServer,
            icon: Icons.add_rounded,
            expand: true,
            onPressed: () => _openEditor(),
          ),
        ],
      ),
    );
  }

  Widget _buildServerRow(BuildContext context, NetworkServerEntity server) {
    final t = context.lokal;
    final isSyncing = _syncingId == server.id;
    final songCount = _songCounts[server.id] ?? 0;

    return InkWell(
      onTap: isSyncing ? null : () => _openEditor(server: server),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              server.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: LokalTheme.sans,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: t.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          LokalStatusPill(label: server.protocol),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        server.baseUrl,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: t.muted),
                      ),
                    ],
                  ),
                ),
                if (!isSyncing)
                  IconButton(
                    tooltip: l10n.syncNow,
                    onPressed: () {
                      AppHaptics.tap();
                      _syncServer(server);
                    },
                    icon: Icon(Icons.sync_rounded, size: 20, color: t.muted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: isSyncing
                  ? _buildSyncPanel(context)
                  : _buildMetaRow(context, server, songCount),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(
    BuildContext context,
    NetworkServerEntity server,
    int songCount,
  ) {
    final t = context.lokal;
    final synced = server.lastSyncedAt;
    final parts = <String>[
      if (songCount > 0) l10n.song2(songCount),
      synced == null ? l10n.neverSynced : l10n.synced2(_formatDate(synced)),
    ];
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: synced == null ? t.muted2 : t.accent,
          ),
        ),
        Flexible(
          child: Text(
            parts.join('  ·  ').toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: LokalTheme.label(t, size: 10.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncPanel(BuildContext context) {
    final t = context.lokal;
    final p = _syncProgress;
    final fraction = p?.progressFraction ?? 0.0;
    final total = p?.totalFiles ?? 0;
    final done = p?.filesProcessed ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: t.accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p?.phase ?? l10n.syncing,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (total > 0)
              Text('$done / $total', style: LokalTheme.label(t, size: 11)),
          ],
        ),
        if (p?.currentFile != null && p!.currentFile!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            p.currentFile!,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: TextStyle(fontSize: 12, color: t.muted),
          ),
        ],
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: t.surface3,
            color: t.accent,
          ),
        ),
        if ((p?.songsFound ?? 0) > 0) ...[
          const SizedBox(height: 4),
          Text(
            l10n.songsFound(p!.songsFound),
            style: TextStyle(fontSize: 12, color: t.muted),
          ),
        ],
      ],
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
