import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_choice_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flick/providers/playlist_provider.dart';
import 'package:flick/providers/songs_provider.dart';

import 'playlist_link_manager.dart';
import 'playlist_link_models.dart';
import 'playlist_unmatched_downloader.dart';

final linkedPlaylistManagerProvider = Provider.autoDispose<PlaylistLinkManager>(
  (ref) {
    final manager = PlaylistLinkManager();
    ref.onDispose(manager.dispose);
    return manager;
  },
);

/// Screen for linking public streaming playlists to local playlists.
/// The playlists route is owned by the host app; this widget only supplies the
/// link/import surface.
class LinkedPlaylistsScreen extends ConsumerStatefulWidget {
  const LinkedPlaylistsScreen({super.key});

  @override
  ConsumerState<LinkedPlaylistsScreen> createState() =>
      _LinkedPlaylistsScreenState();
}

class _LinkedPlaylistsScreenState extends ConsumerState<LinkedPlaylistsScreen> {
  final _inputController = TextEditingController();
  final _nameController = TextEditingController();
  PlaylistLinkPreview? _preview;
  List<PlaylistLinkRecord> _links = const [];
  String? _error;
  bool _loading = false;
  String? _downloadStatus;
  String? _downloadNotice;
  Completer<void>? _downloadCancellation;

  PlaylistLinkManager get _manager => ref.read(linkedPlaylistManagerProvider);

  @override
  void initState() {
    super.initState();
    _loadLinks();
  }

  @override
  void dispose() {
    final download = _downloadCancellation;
    if (download != null && !download.isCompleted) download.complete();
    _inputController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(linkedPlaylistManagerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Linked playlists')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Paste a public Spotify, YouTube, Tidal, Apple Music, Qobuz or Deezer playlist URL. Tidal, Apple Music and Qobuz need their matching add-on in Settings → Add-ons. Use the full playlist URL, not a shortened share link.',
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _inputController,
            enabled: !_loading,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Playlist link',
              hintText: 'https://open.spotify.com/playlist/…',
            ),
            onSubmitted: (_) => _previewLink(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? _cancel : _previewLink,
            icon: Icon(
              _loading ? Icons.cancel_outlined : Icons.preview_outlined,
            ),
            label: Text(_loading ? 'Cancel' : 'Preview'),
          ),
          if (_downloadStatus != null) ...[
            const SizedBox(height: 12),
            Text(_downloadStatus!),
          ],
          if (_downloadNotice != null) ...[
            const SizedBox(height: 8),
            Text(_downloadNotice!),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_preview != null) ...[
            const SizedBox(height: 20),
            _PreviewCard(
              preview: _preview!,
              nameController: _nameController,
              busy: _loading,
              onOpenSource: () => _openSource(_preview!.link.canonicalUrl),
              onCreate: _create,
              onRefreshAppend: () => _refresh(removeMissing: false),
              onRefreshRemove: _preview!.isComplete
                  ? _confirmRemoveMissing
                  : null,
            ),
          ],
          const SizedBox(height: 28),
          Text('Saved links', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_links.isEmpty)
            const Text('No linked playlists yet.')
          else
            ..._links.map(_buildLinkTile),
        ],
      ),
    );
  }

  Widget _buildLinkTile(PlaylistLinkRecord record) {
    final status = record.isPartial ? 'Partial sync' : 'Synced';
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(record.remoteTitle),
            subtitle: Text(
              '$status · ${record.fetchedEntryCount}/${record.remoteEntryCount} entries · '
              '${record.unmatchedEntries.length} unmatched',
            ),
            isThreeLine: true,
            onTap: () => _previewExisting(record),
            trailing: IconButton(
              tooltip: 'Playlist actions',
              icon: const Icon(Icons.more_horiz_rounded),
              onPressed: () => unawaited(_linkActions(record)),
            ),
          ),
          if (record.unmatchedEntries.isNotEmpty)
            ExpansionTile(
              title: Text('Unmatched entries (${record.unmatchedEntries.length})'),
              subtitle: const Text('Download missing tracks to your library'),
              children: [
                for (final entry in record.unmatchedEntries.take(50))
                  ListTile(
                    dense: true,
                    title: Text(entry.title, maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(entry.artist.isEmpty
                        ? 'YouTube video' : entry.artist,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: 'Download to library and add to playlist',
                      icon: const Icon(Icons.download_rounded),
                      onPressed: _loading
                          ? null
                          : () => _downloadUnmatched(record, only: entry),
                    ),
                  ),
                if (record.unmatchedEntries.length > 50)
                  Text('Showing the first 50. Use Download unmatched for all.'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                  child: OutlinedButton.icon(
                    onPressed: _loading
                        ? null
                        : () => _downloadUnmatched(record),
                    icon: const Icon(Icons.download_rounded),
                    label: Text('Download unmatched (${record.unmatchedEntries.length})'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _linkActions(PlaylistLinkRecord record) async {
    final selected = await showLokalChoiceSheet<String>(
      context: context,
      title: record.remoteTitle,
      choices: const [
        LokalChoice(value: 'refresh', label: 'Preview refresh',
          icon: Icons.refresh_rounded),
        LokalChoice(value: 'source', label: 'View source externally',
          icon: Icons.open_in_new_rounded),
        LokalChoice(value: 'unlink', label: 'Unlink',
          icon: Icons.link_off_rounded, destructive: true),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'refresh':
        _previewExisting(record);
      case 'source':
        _openSource(record.canonicalUrl);
      case 'unlink':
        _unlink(record);
    }
  }

  Future<void> _loadLinks() async {
    try {
      final links = await _manager.getLinks();
      if (!mounted) return;
      setState(() => _links = links);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _previewLink() async {
    final value = _inputController.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Paste a playlist link first.');
      return;
    }
    await _run(
      () => _manager.preview(value).then((preview) {
        if (!mounted) return;
        _nameController.text = preview.remote.title;
        setState(() {
          _preview = preview;
          _error = null;
        });
      }),
    );
  }

  Future<void> _previewExisting(PlaylistLinkRecord record) async {
    _inputController.text = record.canonicalUrl;
    await _run(
      () => _manager.previewLink(record.linkId).then((preview) {
        if (!mounted) return;
        _nameController.text = preview.remote.title;
        setState(() {
          _preview = preview;
          _error = null;
        });
      }),
    );
  }

  Future<void> _create() async {
    final preview = _preview;
    if (preview == null) return;
    await _run(
      () => _manager
          .createFromPreview(preview, name: _nameController.text)
          .then((_) async {
            if (!mounted) return;
            ref.invalidate(playlistsProvider);
            setState(() => _preview = null);
            await _loadLinks();
          }),
    );
  }

  Future<void> _refresh({required bool removeMissing}) async {
    final preview = _preview;
    if (preview == null) return;
    await _run(
      () => _manager
          .refreshFromPreview(preview, removeMissing: removeMissing)
          .then((_) async {
            if (!mounted) return;
            ref.invalidate(playlistsProvider);
            setState(() => _preview = null);
            await _loadLinks();
          }),
    );
  }

  Future<void> _confirmRemoveMissing() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove missing songs?'),
        content: const Text(
          'Songs that were managed by this link but are no longer in the complete remote listing will be removed. Local additions stay saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _refresh(removeMissing: true);
    }
  }

  Future<void> _unlink(PlaylistLinkRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink playlist?'),
        content: const Text('The saved local playlist will remain intact.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => _manager.unlink(record.linkId).then((_) => _loadLinks()));
  }

  Future<void> _openSource(String value) async {
    final launched = await launchUrl(
      Uri.parse(value),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      setState(() => _error = 'Could not open the source link.');
    }
  }

  Future<void> _downloadUnmatched(
    PlaylistLinkRecord record, {
    RemotePlaylistEntry? only,
  }) async {
    if (_loading) return;
    final entries = only == null
        ? List<RemotePlaylistEntry>.of(record.unmatchedEntries)
        : [only];
    if (entries.isEmpty) return;
    final cancel = Completer<void>();
    _downloadCancellation = cancel;
    try {
      await _run(() async {
        var saved = 0;
        var failed = 0;
        String? lastError;
        final downloader = PlaylistUnmatchedDownloader();
        final link = ParsedPlaylistLink(
          source: record.source,
          remoteId: record.remoteId,
          canonicalUrl: record.canonicalUrl,
        );
        for (var i = 0; i < entries.length; i++) {
          if (cancel.isCompleted || !mounted) break;
          final entry = entries[i];
          setState(() => _downloadStatus =
              'Downloading ${i + 1}/${entries.length}: ${entry.title}');
          try {
            final result = await downloader.download(
              link,
              entry,
              cancel: cancel.future,
              cancelled: () => cancel.isCompleted,
              onStatus: (status) {
                if (mounted) setState(() => _downloadStatus = status);
              },
              verifySource: (source) async {
                if (!mounted || source.verify == null) return false;
                return source.verify!(context);
              },
            );
            // Attach only after the existing library downloader indexed the
            // finished file; otherwise the playlist gets a phantom song ID.
            await _manager.attachDownloadedEntry(
              record.linkId,
              entry,
              savedPath: result.path,
            );
            saved++;
            if (!mounted) break;
            ref.invalidate(playlistsProvider);
            ref.invalidate(songsProvider);
          } catch (error) {
            if (cancel.isCompleted) break;
            failed++;
            lastError = error.toString();
          }
        }
        if (mounted) {
          await _loadLinks();
          if (mounted) setState(() {
            _downloadStatus = null;
            _downloadNotice = 'Downloaded $saved of ${entries.length} unmatched '
                'entries${cancel.isCompleted ? ' (cancelled)' : ''}.'
                '${failed > 0 ? ' $failed failed. $lastError' : ''}';
          });
        }
      });
    } finally {
      if (identical(_downloadCancellation, cancel)) {
        _downloadCancellation = null;
      }
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _cancel() {
    final download = _downloadCancellation;
    if (download != null && !download.isCompleted) {
      download.complete();
    } else {
      _manager.cancelCurrent();
    }
  }
}

class _PreviewCard extends StatelessWidget {
  final PlaylistLinkPreview preview;
  final TextEditingController nameController;
  final bool busy;
  final VoidCallback onOpenSource;
  final VoidCallback onCreate;
  final VoidCallback onRefreshAppend;
  final VoidCallback? onRefreshRemove;

  const _PreviewCard({
    required this.preview,
    required this.nameController,
    required this.busy,
    required this.onOpenSource,
    required this.onCreate,
    required this.onRefreshAppend,
    required this.onRefreshRemove,
  });

  @override
  Widget build(BuildContext context) {
    final source = preview.link.source.label;
    final remote = preview.remote;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    remote.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(source),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${remote.entries.length} entries fetched · ${preview.matches.matchedSongCount} matched · '
              '${preview.matches.unmatchedEntries.length} unmatched · '
              '${preview.matches.duplicateMatches} duplicate',
            ),
            if (!remote.complete) ...[
              const SizedBox(height: 8),
              Text(
                'Partial import: ${remote.truncationReason ?? 'the source did not provide a complete listing.'}',
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
              ),
            ],
            const SizedBox(height: 10),
            ...remote.entries
                .take(8)
                .map(
                  (entry) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      entry.artist.isEmpty
                          ? 'Artist not supplied · not matched'
                          : entry.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            if (remote.entries.length > 8)
              Text('… and ${remote.entries.length - 8} more'),
            if (preview.matches.unmatchedEntries.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Unmatched entries',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              ...preview.matches.unmatchedEntries
                  .take(8)
                  .map(
                    (entry) => Text(
                      '• ${entry.title}${entry.artist.isEmpty ? '' : ' — ${entry.artist}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              if (preview.matches.unmatchedEntries.length > 8)
                Text(
                  '… and ${preview.matches.unmatchedEntries.length - 8} more unmatched',
                ),
            ],
            if (preview.isRefresh) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: busy ? null : onRefreshAppend,
                icon: const Icon(Icons.sync),
                label: const Text('Apply safe refresh'),
              ),
              if (onRefreshRemove != null)
                OutlinedButton(
                  onPressed: busy ? null : onRefreshRemove,
                  child: const Text('Refresh and remove missing'),
                ),
            ] else ...[
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Local playlist name',
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: busy ? null : onCreate,
                icon: const Icon(Icons.link),
                label: const Text('Create linked playlist'),
              ),
            ],
            TextButton.icon(
              onPressed: onOpenSource,
              icon: const Icon(Icons.open_in_new),
              label: const Text('View source externally'),
            ),
          ],
        ),
      ),
    );
  }
}
