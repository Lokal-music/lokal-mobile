import '../providers/search_filter_provider.dart';
import '../providers/recent_search_tracks.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/discovery/discovery_artwork.dart';
import 'package:flick/features/discovery/discovery_http.dart';
import 'package:flick/features/discovery/discovery_models.dart';
import 'package:flick/features/konnekted/konnekted_discovery.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/features/search/widgets/online_result_actions.dart';
import 'package:flick/features/settings/lokal/lokal_settings_group.dart';
import 'package:flick/features/settings/lokal/lokal_settings_page.dart';
import 'package:flick/features/morneye/morneye_service.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/providers.dart';
import 'package:flick/widgets/lokal/lokal_status_snack.dart';
import 'package:flick/widgets/lokal/lokal_quality.dart';
import 'package:flick/services/catalogue_quality.dart';
import 'package:flick/services/graceful_http_client.dart';
import 'package:flick/core/utils/app_log.dart';
import 'package:flick/features/discovery/youtube_audio.dart';
import 'package:flick/services/queue_pre_resolver.dart';
import 'package:flick/services/atmos_playback_support.dart';
import 'package:flick/widgets/lokal/lokal_swipe_to_queue.dart';

/// All results in one selected provider belong to the same playback queue.
/// The selected result may request Atmos, but its neighbours remain normal
/// playable versions until the user explicitly selects Atmos for each one.
@visibleForTesting
({Song selected, List<Song> queue}) buildOnlineSearchPlaybackQueue({
  required List<OnlineResult> results,
  required OnlineResult selected,
  required bool atmos,
  required Song Function(DiscoveryTrack track) pendingSong,
}) {
  final queue = <Song>[];
  final seen = <String>{};
  Song? selectedSong;
  // Cap enormous provider responses, not the 15-item visual preview.
  final rows = results.take(100);
  for (final entry in rows) {
    final isSelected = identical(entry, selected) ||
        entry.track.key == selected.track.key;
    final track = isSelected && atmos
        ? entry.track.requestAtmos()
        : entry.track;
    final song = pendingSong(track);
    if (seen.add(song.id)) queue.add(song);
    if (isSelected) selectedSong ??= song;
  }
  if (selectedSong == null) {
    final chosen = pendingSong(
      atmos ? selected.track.requestAtmos() : selected.track,
    );
    if (seen.add(chosen.id)) queue.insert(0, chosen);
    selectedSong = chosen;
  }
  return (selected: selectedSong, queue: queue);
}

/// Songs you don't have, under your library's results: desktop's Search
/// "online" block. One source at a time (YouTube Music or an add-on you
/// installed), switched with chips; a tap finds the song and plays it, a
/// long press (or ⋯) offers Play next, Add to queue and Download to library.
class OnlineSearchSection extends ConsumerStatefulWidget {
  const OnlineSearchSection({
    super.key,
    required this.query,
    this.sources,
    this.pendingSong,
    this.prepare,
    this.downloader,
    this.qualityLookup,
  });

  final String query;

  /// Replaces native/network stream inspection in controlled widget tests.
  final Future<String?> Function(String videoId, Future<void> cancel)? qualityLookup;

  @visibleForTesting
  static void resetSourceSelection() => _OnlineSearchSectionState._remembered = null;

  /// Loads the sources; replaced in tests.
  final Future<List<OnlineSource>> Function(
    http.Client client,
    void Function(String status) onStatus,
  )?
  sources;

  /// A queue placeholder for a result, got ready ahead of its turn
  /// ([onlinePendingSong]); replaced in tests.
  final Song Function(OnlineSource source, DiscoveryTrack track)? pendingSong;

  /// Downloads a result to save it ([playOnlineTrack]); replaced in tests.
  final Future<Song> Function(
    OnlineSource source,
    DiscoveryTrack track,
    void Function(String status) onStatus,
  )?
  prepare;

  /// Saves a downloaded result to the library; replaced in tests.
  final LibraryDownloader? downloader;

  @override
  ConsumerState<OnlineSearchSection> createState() =>
      _OnlineSearchSectionState();
}

class _OnlineSearchSectionState extends ConsumerState<OnlineSearchSection> {
  static String? _remembered; // The chosen source, for the app's lifetime.

  final _client = GracefulHttpClient();
  late final _progress = LokalStatusSnack(
    () => mounted ? context : null,
  );
  List<OnlineSource>? _sources;
  String? _chosen;
  Future<List<OnlineResult>>? _results;
  String? _searched;
  final _saving = <String>{};
  int _inactiveAddons = 0;
  int _searchGeneration = 0;
  final _youtubeQuality = <String, Future<String?>>{};
  Future<void> _youtubeLookupTail = Future<void>.value();
  Completer<void> _youtubeQualityCancelled = Completer<void>();
  bool _youtubeQualityPaused = false;

  void _prioritizePlayback() {
    // The Android resolver serializes native format extraction. Cancel
    // background badge work before playing/queueing so a 15-result Search
    // cannot hold up the tapped recording.
    _youtubeQualityPaused = true;
    if (!_youtubeQualityCancelled.isCompleted) {
      _youtubeQualityCancelled.complete();
    }
    _youtubeQuality.clear();
  }

  /// Search snippets don't contain a selected audio format. Resolve each
  /// result's actual audio rendition in the background (serially to avoid
  /// monopolizing InnerTubeX's native playback resolver), not by guessing
  /// AAC/Opus for every title. Store only the label, never signed media URLs.
  Future<String?> _resolvedYoutubeQuality(String videoId) {
    if (_youtubeQualityPaused) return Future<String?>.value(null);
    return _youtubeQuality.putIfAbsent(videoId, () {
        final gate = _youtubeLookupTail.catchError((Object _) {});
        final cancelled = _youtubeQualityCancelled;
        final lookup = gate.then((_) async {
          if (!mounted || cancelled.isCompleted) return null;
          try {
            if (widget.qualityLookup != null) {
              return await widget.qualityLookup!(videoId, cancelled.future);
            }
            final audio = await YoutubeAudio(DiscoveryHttp(_client))
                .resolve(videoId, cancel: cancelled.future)
                .timeout(const Duration(seconds: 55));
            final codec = audio.codec;
            final bitrate = audio.bitrate;
            if (codec == null) return null;
            return catalogueAudioDetails(
              codec: codec,
              sampleRate: audio.sampleRate,
              quality: measuredLossyBitrate(
                codec: codec, bitsPerSecond: bitrate,
              ),
            );
          } catch (_) {
            return null; // Unsupported/expired streams have no proven badge.
          }
        });
        _youtubeLookupTail = lookup.then<void>((_) {});
        while (_youtubeQuality.length > 64) {
          _youtubeQuality.remove(_youtubeQuality.keys.first);
        }
        return lookup;
      });
  }

  @override
  void initState() {
    super.initState();
    MorneyeService.instance.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    MorneyeService.instance.removeListener(_load);
    if (!_youtubeQualityCancelled.isCompleted) {
      _youtubeQualityCancelled.complete();
    }
    _progress.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    final load =
        widget.sources ??
        (client, onStatus) => onlineSources(client, onStatus: onStatus);
    List<OnlineSource> sources;
    try {
      sources = await load(_client, _status);
    } catch (error) {
      // An add-on registry/network failure must not erase previously loaded
      // sources or silently make all providers disappear from Search.
      AppLog.instance.add(
        '[OnlineSource] source list refresh failed '
        'errorClass=${error.runtimeType}',
      );
      sources = _sources ?? const [];
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _searched = null; // Search again: the add-ons may have changed.
      _youtubeQualityPaused = false;
      if (_youtubeQualityCancelled.isCompleted) {
        _youtubeQualityCancelled = Completer<void>();
        _youtubeLookupTail = Future<void>.value();
      }
    });
    if (widget.sources != null) return; // Tests give their own sources.
    try {
      final packages = await MorneyeService.instance.packages;
      final playable = await MorneyeService.instance.playable();
      final inactive =
          packages.addons.where((a) => a.enabled && a.searches).length -
          playable.length;
      if (mounted) setState(() => _inactiveAddons = inactive);
    } catch (_) {}
  }

  OnlineSource? get _source {
    final sources = _sources;
    if (sources == null || sources.isEmpty) return null;
    final wanted = _chosen ?? _remembered;
    final exact = sources.where((s) => s.id == wanted).firstOrNull;
    if (exact != null) return exact;
    if (wanted?.startsWith('w-') == true) {
      // Before HTTP providers had stable config IDs, Search remembered their
      // mutable display labels. Do not silently switch a one-addon user back
      // to native YouTube when the old selection is restored or renamed.
      final label = wanted!.substring(2);
      final byOldLabel = sources.where(
        (s) => s.id.startsWith('w-') && s.name == label,
      ).firstOrNull;
      if (byOldLabel != null) return byOldLabel;
      final httpSources = sources.where((s) => s.id.startsWith('w-')).toList();
      if (httpSources.length == 1) return httpSources.single;
    }
    return sources.first;
  }

  Future<void> _choose(OnlineSource source) async {
    HapticFeedback.selectionClick();
    if (!await _verify(source)) return;
    setState(() {
      _chosen = _remembered = source.id;
      _searched = null;
    });
  }

  Future<bool> _verify(OnlineSource source) async {
    try {
      if (source.verify != null && !await source.verify!(context)) return false;
      return mounted;
    } catch (_) {
      _say('Could not verify ${source.name}. Tap it to retry.');
      return false;
    }
  }

  Future<List<OnlineResult>> _search(OnlineSource source, String query) async {
    final generation = ++_searchGeneration;
    // The results section already shows search loading inline. Reserve the
    // status snackbar for preparing, downloading and saving a selected song.
    await Future<void>.delayed(Duration.zero);
    if (!mounted || generation != _searchGeneration) return const [];
    try {
      return await source.results(query);
    } catch (error) {
      AppLog.instance.add(
        '[OnlineSource] Search failed source=${source.id} '
        'errorClass=${error.runtimeType}',
      );
      rethrow;
    }
  }

  /// Download progress: one line, updated in place, only while a song is
  /// being got ready.
  void _status(String message) {
    if (!mounted) return;
    _progress.update(message);
  }

  /// A one-off message that goes after a while (and takes any progress
  /// line with it).
  void _say(String message) {
    if (mounted) _progress.fail(message);
  }

  Future<void> _play(
    OnlineSource source,
    OnlineResult result, {
    bool atmos = false,
    List<OnlineResult>? results,
  }) async {
    if (source.id == 'yt') _prioritizePlayback();
    // Source verification can take seconds: feedback must precede its await.
    _progress.update('Preparing ${result.track.title} from ${source.name}…');
    if (!await _verify(source)) {
      _progress.clear();
      return;
    }
    if (atmos) {
      if (!result.track.atmosAvailable && !result.track.atmosRequestable) {
        _say('This track has no advertised Dolby Atmos version.');
        return;
      }
      if (!await AtmosPlaybackSupport.availableFor(result.track.atmosRequestable ? 'ac4' : 'eac3-joc')) {
        _say('This device does not report native support for the selected Dolby audio codec.');
        return;
      }
    }
    unawaited(
      ref
          .read(recentSearchTracksProvider.notifier)
          .add(
            RecentSearchTrack(
              title: result.track.title,
              artist: result.track.artist,
              artwork: result.artwork,
            ),
          ),
    );
    final createPending = widget.pendingSong ??
        (OnlineSource source, DiscoveryTrack track) =>
            onlinePendingSong(source.id, track);
    final playback = buildOnlineSearchPlaybackQueue(
      results: results ?? [result],
      selected: result,
      atmos: atmos,
      pendingSong: (track) => createPending(source, track),
    );
    // Search owns only the pre-verification toast. Once playback starts the
    // shell's QueuePreResolver owns all ongoing progress; otherwise two
    // LokalStatusSnack owners continuously replace the global toast.
    _progress.clear();
    await ref.read(playerProvider.notifier).play(
      playback.selected, playlist: playback.queue,
    );
    // Play has established the actual queue and current index now. Kick the
    // production four-ahead resolver explicitly: some Media3 handoffs don't
    // emit a separate queue mutation once the selected pending item swaps.
    // The resolver coalesces duplicate requests with existing timers/jobs.
    if (widget.pendingSong == null) QueuePreResolver.shared.schedule();
  }

  /// Play next / Add to queue: a placeholder that's found and downloaded
  /// ahead of its turn. With nothing playing, it just plays.
  Future<void> _enqueue(
    OnlineSource source,
    OnlineResult result, {
    required bool next,
  }) async {
    if (source.id == 'yt') _prioritizePlayback();
    if (!await _verify(source)) return;
    final track = result.track;
    if (ref.read(playerProvider).currentSong == null) {
      return _play(source, result);
    }
    final pending =
        (widget.pendingSong ??
        (source, track) => onlinePendingSong(source.id, track))(source, track);
    final player = ref.read(playerProvider.notifier);
    try {
      final index = await player.addToQueue(pending);
      if (next) await player.moveQueueItemToNext(index);
      _say(
        next
            ? '${track.title} plays next'
            : 'Added ${track.title} to the queue',
      );
    } catch (error) {
      _say('Couldn’t queue ${track.title}. ${discoveryError(error)}');
    }
  }

  /// The cover to save with a song: the source's, else Discovery's lookup.
  Future<String?> _cover(OnlineResult result) async {
    final url = discoveryImageUrl(result.artwork);
    if (url.isNotEmpty) return url;
    try {
      final found = await ref
          .read(discoveryArtworkResolverProvider)
          .resolve(
            DiscoveryArtworkRequest(
              kind: DiscoveryArtworkKind.track,
              title: result.track.title,
              artist: result.track.artist,
            ),
          )
          .timeout(const Duration(seconds: 8));
      return found.isEmpty ? null : found;
    } catch (_) {
      return null;
    }
  }

  /// Desktop's "Save to library": downloads the song through the same
  /// source, then copies it into your music folder and library.
  Future<void> _download(OnlineSource source, OnlineResult result, {bool atmos = false}) async {
    if (!await _verify(source)) return;
    final track = atmos ? result.track.requestAtmos(downloadOnly: true) : result.track;
    final key = '${source.id}:${track.id}';
    if (!_saving.add(key)) return;
    setState(() {});
    _progress.update('Downloading ${track.title} from ${source.name}…');
    try {
      final prepare =
          widget.prepare ??
          (source, track, onStatus) =>
              playOnlineTrack(source.id, track, onStatus: onStatus,
                forDownload: true);
      final song = await prepare(source, track, (message) {
        if (mounted && _saving.contains(key)) _progress.update(message);
      });
      if (mounted) {
        _progress.update('Saving ${track.title} to your library…');
      }
      final cover = await _cover(result);
      final saved = await (widget.downloader ?? LibraryDownloader()).save(
        song,
        artwork: cover,
      );
      _say(
        saved.fallback
            ? 'Saved ${track.title}. Your music folders can’t be written '
                  'to, so it’s in Music/${LibraryDownloader.folderName}, '
                  'now part of your library.'
            : 'Saved ${track.title} to your library '
                  '(${saved.folderName}).',
      );
    } catch (error) {
      _say('Couldn’t save ${track.title}. ${discoveryError(error)}');
    } finally {
      _saving.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _actions(
    OnlineSource source,
    OnlineResult result,
    List<OnlineResult> results,
  ) async {
    HapticFeedback.mediumImpact();
    final action = await showOnlineResultActions(
      context,
      result: result,
      sourceName: source.name,
      saving: _saving.contains('${source.id}:${result.track.id}'),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case OnlineResultAction.play:
        await _play(source, result, results: results);
      case OnlineResultAction.playAtmos:
        await _play(source, result, atmos: true, results: results);
      case OnlineResultAction.playNext:
        await _enqueue(source, result, next: true);
      case OnlineResultAction.addToQueue:
        await _enqueue(source, result, next: false);
      case OnlineResultAction.download:
        await _download(source, result);
      case OnlineResultAction.downloadAtmos:
        await _download(source, result, atmos: true);
    }
  }

  void _openAddons() => unawaited(
    openLokalSettings(
      context,
      group: LokalSettingsGroup.integrations,
      section: LokalOnlineSections.addons,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final source = _source;
    final query = widget.query.trim();
    if (source != null && query.isNotEmpty) {
      final key = '${source.id}\n$query';
      if (_searched != key) {
        _searched = key;
        _results = source.needsVerification?.call() == true
            ? Future.value(const <OnlineResult>[])
            : _search(source, query);
      }
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_sources case final sources? when sources.length > 1) ...[
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in sources)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _SourceChip(
                          label: s.name,
                          selected: s.id == source?.id,
                          onTap: () => _choose(s),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (source != null && source.needsVerification?.call() == true)
              TextButton.icon(
                onPressed: () => _choose(source),
                icon: const Icon(Icons.verified_user_outlined),
                label: Text('Verify ${source.name} to search'),
              ),
            if (_inactiveAddons > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: _openAddons,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _inactiveAddons == 1
                          ? 'One add-on needs setting up before it can search. '
                                'Open add-ons'
                          : '$_inactiveAddons add-ons need setting up before '
                                'they can search. Open add-ons',
                      style: TextStyle(color: t.accent, fontSize: 12),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (source != null)
              FutureBuilder<List<OnlineResult>>(
                future: _results,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: t.muted,
                          ),
                        ),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _Note(
                      '${source.name} couldn’t search right now. '
                      '${discoveryError(snapshot.error!)}',
                    );
                  }
                  final results = snapshot.data ?? const [];
                  if (results.isEmpty) {
                    return _Note('No songs found on ${source.name}.');
                  }
                  return Column(
                    children: [
                      for (final result in results.take(15))
                        if (source.id == 'yt')
                          FutureBuilder<String?>(
                            future: _resolvedYoutubeQuality(result.track.id),
                            builder: (context, snapshot) => _OnlineTile(
                              result: result,
                              verifiedQuality: snapshot.data,
                              busy: _saving.contains(
                                '${source.id}:${result.track.id}',
                              ),
                              onTap: () => _play(source, result, results: results),
                              onAtmos: () => _play(source, result, atmos: true, results: results),
                              onMore: () => _actions(source, result, results),
                              onQueue: () => _enqueue(source, result, next: false),
                              onNext: () => _enqueue(source, result, next: true),
                            ),
                          )
                        else
                          _OnlineTile(
                            result: result,
                            busy: _saving.contains(
                              '${source.id}:${result.track.id}',
                            ),
                            onTap: () => _play(source, result, results: results),
                            onAtmos: () => _play(source, result, atmos: true, results: results),
                            onMore: () => _actions(source, result, results),
                            onQueue: () => _enqueue(source, result, next: false),
                            onNext: () => _enqueue(source, result, next: true),
                          ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? t.accent.withValues(alpha: .2)
                : t.surface2.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: selected ? t.accent : t.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? t.accent : t.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      text,
      style: TextStyle(color: context.lokal.muted, fontSize: 13),
    ),
  );
}

class _OnlineTile extends StatelessWidget {
  const _OnlineTile({
    required this.result,
    required this.busy,
    required this.onTap,
    required this.onAtmos,
    required this.onQueue,
    required this.onNext,
    required this.onMore,
    this.verifiedQuality,
  });

  final String? verifiedQuality;
  final OnlineResult result;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onAtmos;
  final Future<void> Function() onQueue;
  final Future<void> Function() onNext;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final track = result.track;
    final duration = track.duration;
    final badge = onlineSearchAudioBadge(
      verifiedQuality: verifiedQuality,
      requestedQuality: track.requestedQuality,
      catalogueQuality: track.catalogueQuality,
      catalogueBitDepth: track.catalogueBitDepth,
      catalogueSampleRate: track.catalogueSampleRate,
      catalogueCodec: track.catalogueCodec,
    );
    final displayQuality = badge.label;
    return LokalSwipeToQueue(
      onQueue: onQueue,
      onNext: onNext,
      enabled: !busy,
      child: InkWell(
        onTap: busy ? null : onTap,
        onLongPress: onMore,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              OnlineResultCover(result: result, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      [
                        track.artist,
                        if (track.album case final album? when album.isNotEmpty)
                          album,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (displayQuality.isNotEmpty)
                        Tooltip(
                          message: badge.tooltip,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(color: t.muted.withValues(alpha: .35)),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              displayQuality,
                              style: TextStyle(color: t.muted, fontSize: 10),
                            ),
                          ),
                        ),
                          if (track.atmosAvailable || track.atmosRequestable)
                            Tooltip(
                              message: track.atmosRequestable && !track.atmosAvailable
                                  ? 'Try Amazon AC-4 (catalogue Atmos unverified; needs native Android AC-4 support)'
                                  : 'Play original Dolby Atmos (requires a native E-AC-3 JOC decoder or direct output)',
                              child: InkWell(
                                onTap: busy ? null : onAtmos,
                                borderRadius: BorderRadius.circular(6),
                                child: const LokalAtmosPill(),
                              ),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: t.accent,
                    ),
                  ),
                )
              else if (duration != null)
                Text(
                  '${duration.inMinutes}:'
                  '${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: TextStyle(color: t.muted2, fontSize: 12),
                ),
              IconButton(
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                onPressed: onMore,
                icon: Icon(Icons.more_horiz_rounded, color: t.muted, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
