import 'lyrics_source_button.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fading_marquee_widget/fading_marquee_widget.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/lyrics_playback_prefetch.dart';
import 'package:flick/models/song.dart';
import 'package:flick/core/theme/app_colors.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/features/player/widgets/lyrics_alignment.dart';

import 'picked_lyrics_file.dart';
import 'lyrics_file_export.dart';
import 'lyrics_subline_buttons.dart';

import 'package:flick/features/player/widgets/online_lyrics_search_sheet.dart';
import 'package:flick/features/player/widgets/synced_lyrics_view.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/l10n/l10n.dart';

class InlineLyricsPanel extends ConsumerStatefulWidget {
  final PlayerService playerService;
  final LyricsService lyricsService;
  final Song song;
  final Color? albumColor;
  final ValueNotifier<Duration>? positionNotifier;
  final bool active;

  const InlineLyricsPanel({
    super.key,
    required this.playerService,
    required this.lyricsService,
    required this.song,
    this.albumColor,
    this.positionNotifier,
    this.active = true,
  });

  @override
  ConsumerState<InlineLyricsPanel> createState() => _InlineLyricsPanelState();
}

class _InlineLyricsPanelState extends ConsumerState<InlineLyricsPanel> {
  final ScrollController _scrollController = ScrollController();
  LyricsData? _lyricsData;
  LyricsData? _sublineLyrics;
  bool _isLoading = true;
  bool _savingLyricsFile = false;
  String? _loadedSongId;
  String _selectedLyricsSource = 'auto';
  int _lyricsRequest = 0;
  bool _hasManualLyricsSelection = false;
  bool _isMetaCollapsed = false;

  @override
  void initState() {
    super.initState();
    _loadLyricsForSong(widget.song);
  }

  @override
  void didUpdateWidget(covariant InlineLyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      // Source overrides apply to one song; a new song starts in Automatic.
      _selectedLyricsSource = 'auto';
      _loadLyricsForSong(widget.song);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyricsForSong(
    Song song, {
    bool refreshOnline = false,
  }) async {
    if (!mounted) return;
    final request = ++_lyricsRequest;
    setState(() {
      _isLoading = true;
      if (_loadedSongId != song.id) _lyricsData = null;
      _sublineLyrics = null;
    });
    try {
      final selected = _selectedLyricsSource;
      final warm = !refreshOnline && selected == 'auto';
      // Choosing an online provider must not fetch it twice (first as
      // "local", then once more as "enhanced"). Keep the displayed lyrics
      // while the explicit provider is being checked.
      final local = selected != 'auto' && selected != 'local'
          ? _lyricsData
          : warm
          ? await LyricsPlaybackPrefetch.instance.local(song)
          : await widget.lyricsService.loadLyricsForSong(
              song, forceRefresh: refreshOnline, fetchOnline: false,
              source: selected,
            );
      if (!mounted || request != _lyricsRequest ||
          widget.song.id != song.id) return;
      setState(() {
        _lyricsData = local;
        _loadedSongId = song.id;
        _isLoading = local == null;
      });
      // This metadata lookup and any online providers happen after the local
      // lyrics have already been painted. Opening Lyrics never starts its
      // first remote request; the player prefetches it on track changes.
      final manual = widget.lyricsService.getManualLyricsPathForSong(song);
      final best = selected == 'local'
          ? local
          : warm
          ? await LyricsPlaybackPrefetch.instance.enhanced(song)
          : await widget.lyricsService.loadLyricsForSong(
              song, forceRefresh: refreshOnline,
              refreshOnline: refreshOnline,
              source: _selectedLyricsSource,
              stillCurrent: () => mounted && request == _lyricsRequest,
              fetchOnline: refreshOnline ||
                  ref.read(appPreferencesProvider).lyricsAutoFetch,
            );
      final manualPath = await manual;
      if (!mounted || request != _lyricsRequest ||
          widget.song.id != song.id) return;
      setState(() {
        // A manual source choice is intentional, even if its timing quality
        // is lower than Automatic's. A miss still retains the previous words.
        if (selected != 'auto' && best != null) {
          _lyricsData = best;
        } else if (lyricQualityRank(best) > lyricQualityRank(_lyricsData)) {
          _lyricsData = best;
        } else {
          _lyricsData ??= best;
        }
        _hasManualLyricsSelection =
            manualPath != null && manualPath.isNotEmpty;
        _isLoading = false;
      });
    } catch (_) {
      if (mounted && request == _lyricsRequest) {
        setState(() => _isLoading = false);
      }
    }
  }

  String? _lyricsSourceLabel(String? source) {
    if (source == null || source.isEmpty) return null;
    final normalized = source.replaceAll('\\', '/');
    return normalized.split('/').last;
  }

  void _showMessage(String message) {
    LokalToast.fromSnackBar(context, 
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _saveLyricsFile(LyricsData lyrics) async {
    if (_savingLyricsFile) return;
    final song = widget.song;
    setState(() => _savingLyricsFile = true);
    try {
      final saved = await saveCurrentLyricsFile(song: song, lyrics: lyrics);
      if (saved && mounted) _showMessage(l10n.saved);
    } catch (_) {
      if (mounted) _showMessage('Could not save lyrics to file.');
    } finally {
      if (mounted) setState(() => _savingLyricsFile = false);
    }
  }

  Future<void> _importLyricsFile() async {
    try {
      final pickedFile = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['ttml', 'elrc', 'lrc', 'txt', 'xml'],
      );
      if (pickedFile == null) return;

      final content = await readTextFromPickedLyricsFile(pickedFile);
      if (content == null || content.trim().isEmpty) {
        _showMessage(l10n.couldNotReadTheSelectedLyrics);
        return;
      }

      await widget.lyricsService.importLyricsForSong(
        song: widget.song,
        fileName: pickedFile.name,
        content: content,
      );
      if (!mounted) return;
      await _loadLyricsForSong(widget.song);
      _showMessage(l10n.linkedToThisSong(pickedFile.name));
    } catch (_) {
      _showMessage(l10n.couldNotUseTheSelectedLyrics);
    }
  }

  Future<void> _resetManualLyricsSource() async {
    await widget.lyricsService.clearManualLyricsPathForSong(widget.song);
    if (!mounted) return;
    await _loadLyricsForSong(widget.song);
    if (!mounted) return;
    _showMessage(l10n.switchedBackToTheAutomaticLyrics);
  }

  Future<void> _searchOnlineLyrics() async {
    final result = await OnlineLyricsSearchSheet.show(
      context: context,
      song: widget.song,
      lyricsService: widget.lyricsService,
    );
    if (result == true && mounted) {
      await _loadLyricsForSong(widget.song);
      _showMessage(l10n.lyricsSavedFromLrclib);
    }
  }

  Widget _buildActionButtons() {
    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
      bool emphasized = false,
    }) {
      final fillColor = emphasized
          ? Colors.white.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.08);
      return TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          backgroundColor: fillColor,
          foregroundColor: Colors.white.withValues(alpha: 0.92),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(
            fontFamily: 'GoogleSansFlex',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          action(
            icon: LucideIcons.filePlus,
            label: l10n.useExistingFile,
            onPressed: () => unawaited(_importLyricsFile()),
          ),
          action(
            icon: LucideIcons.globe,
            label: l10n.searchOnline,
            onPressed: () => unawaited(_searchOnlineLyrics()),
          ),
          if (_hasManualLyricsSelection)
            action(
              icon: LucideIcons.refreshCcw,
              label: l10n.useAutoSource,
              onPressed: () => unawaited(_resetManualLyricsSource()),
            ),
        ],
      ),
    );
  }

  Widget _buildLyricsMeta(LyricsData lyrics) {
    final sourceLabel = _lyricsSourceLabel(lyrics.source);
    final textColor = Colors.white.withValues(alpha: 0.82);

    Widget chip(
      IconData icon,
      String label, {
      bool accent = false,
      bool marqueeLabel = false,
    }) {
      final labelStyle = TextStyle(
        fontFamily: 'GoogleSansFlex',
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: accent ? AppColors.accent : textColor,
      );
      final labelWidget = marqueeLabel
          ? SizedBox(
              width: 132,
              child: FadingMarqueeWidget(
                id: label,
                gap: 20,
                delay: const Duration(milliseconds: 1200),
                pause: const Duration(milliseconds: 800),
                duration: const Duration(seconds: 6),
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: labelStyle,
                ),
              ),
            )
          : Text(label, style: labelStyle);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: accent
              ? AppColors.accent.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: accent
                ? AppColors.accent.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: accent ? AppColors.accent : textColor),
            const SizedBox(width: 6),
            labelWidget,
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => setState(() => _isMetaCollapsed = !_isMetaCollapsed),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                chip(
                  lyrics.isSynchronized
                      ? LucideIcons.clock3
                      : LucideIcons.fileText,
                  lyrics.isSynchronized ? l10n.synced : l10n.plain,
                  accent: lyrics.isSynchronized,
                ),
                const SizedBox(width: 8),
                if (sourceLabel != null) ...[
                  chip(LucideIcons.badgeInfo, sourceLabel, marqueeLabel: true),
                  const SizedBox(width: 8),
                ],
                AnimatedRotation(
                  turns: _isMetaCollapsed ? 0.0 : 0.5,
                  duration: AppConstants.animationFast,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AppConstants.animationFast,
          crossFadeState: _isMetaCollapsed
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: _buildActionButtons(),
        ),
      ],
    );
  }

  Widget _buildPlainLyricsView(LyricsData lyrics) {
    final alignment = resolveLyricsAlignment(
      ref.watch(appPreferencesProvider).lyricsTextAlign,
    );
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: SizedBox(
        width: double.infinity,
        child: Text(
          lyrics.lines
              .map(
                (line) => line.translation?.isNotEmpty == true
                    ? '${line.text}\n${line.translation}'
                    : line.text,
              )
              .join('\n'),
          textAlign: alignment.textAlign,
          style: TextStyle(
            fontFamily: 'GoogleSansFlex',
            fontSize: 18,
            height: 1.9,
            color: Colors.white.withValues(alpha: 0.92),
          ),
        ),
      ),
    );
  }

  Widget _buildSynchronizedLyricsView(LyricsData lyrics) {
    return Expanded(
      child: SyncedLyricsView(
        playerService: widget.playerService,
        lyricsService: widget.lyricsService,
        lyrics: lyrics,
        albumColor: widget.albumColor,
        positionNotifier: widget.positionNotifier,
        active: widget.active,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_lyricsData case final lyrics? when lyrics.lines.isNotEmpty)
            IconButton(
              key: const ValueKey('save-inline-lyrics-file'),
              tooltip: 'Save lyrics to file',
              visualDensity: VisualDensity.compact,
              icon: _savingLyricsFile
                  ? const SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.download, size: 19),
              onPressed: _savingLyricsFile
                  ? null
                  : () => unawaited(_saveLyricsFile(lyrics)),
            ),
          if (_lyricsData case final lyrics?)
            LyricsSublineButtons(
              lyrics: lyrics,
              onChanged: (value) => setState(() => _sublineLyrics = value),
            ),
          LyricsSourceButton(
            selected: _selectedLyricsSource,
            lyrics: _lyricsData,
            song: widget.song,
            lyricsService: widget.lyricsService,
            busy: _isLoading,
            onSelected: (source) {
              setState(() => _selectedLyricsSource = source);
              unawaited(_loadLyricsForSong(widget.song));
            },
            onRefresh: () =>
                unawaited(_loadLyricsForSong(widget.song, refreshOnline: true)),
          ),
        ],
      ),
      Expanded(child: _buildLyricsBody(context)),
    ],
  );

  Widget _buildLyricsBody(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading && _lyricsData == null) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }

    final lyrics = _sublineLyrics ?? _lyricsData;
    if (lyrics == null || lyrics.lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Icon(
                  LucideIcons.fileText,
                  size: 24,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.noLyricsYet,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.searchOnlineCreateYourOwnSynced,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 13,
                  height: 1.5,
                  color: Colors.white.withValues(alpha: 0.56),
                ),
              ),
              _buildActionButtons(),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildLyricsMeta(lyrics),
        if (lyrics.isSynchronized)
          _buildSynchronizedLyricsView(lyrics)
        else
          Expanded(child: _buildPlainLyricsView(lyrics)),
      ],
    );
  }
}
