import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/album_art_service.dart';
import 'package:flick/services/color_extraction_service.dart';
import 'package:flick/services/gallery_save_service.dart';
import 'package:flick/services/lyrics_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/widgets/lokal/lokal_logo.dart';

import 'share_cards/konnekted_share_card.dart';
import 'share_template.dart';

class ShareBottomSheet extends StatefulWidget {
  const ShareBottomSheet({super.key, required this.song});
  final Song song;

  @override
  State<ShareBottomSheet> createState() => _ShareBottomSheetState();
}

class _ShareBottomSheetState extends State<ShareBottomSheet> {
  final _cardKey = GlobalKey();
  final _lyricController = TextEditingController();
  ShareTemplate _template = ShareTemplate.albumArt;
  ImageProvider? _artwork;
  Color? _color;
  bool _preparing = true, _busy = false, _saving = false;
  bool _lyricEdited = false, _autoFit = true;
  bool _lyricsLoading = true;
  bool _preparationStarted = false;
  double _lyricSize = 32;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLyric();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // precacheImage reads inherited image configuration (including MediaQuery).
    // Start after dependencies are available, once for this mounted preview.
    if (!_preparationStarted) {
      _preparationStarted = true;
      _prepare();
    }
  }

  @override
  void dispose() {
    _lyricController.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    ImageProvider? image;
    Color? color;
    try {
      final song = widget.song;
      String? path = song.albumArt;
      if (path != null &&
          (path.startsWith('https://') || path.startsWith('http://'))) {
        path = (await DefaultCacheManager().getSingleFile(path)).path;
      } else if (song.filePath?.isNotEmpty == true) {
        path = await AlbumArtService.instance.resolveArtworkPath(
          existingPath: path,
          audioSourcePath: song.filePath!,
        );
      }
      if (path != null && await File(path).exists()) {
        final file = File(path);
        if (await file.length() <= 32 * 1024 * 1024) {
          image = MemoryImage(await file.readAsBytes());
          if (!mounted) return;
          var decoded = true;
          await precacheImage(
            image,
            context,
            onError: (_, _) => decoded = false,
          );
          if (!decoded) image = null;
          color = await ColorExtractionService().extractDominantColor(path);
        }
      }
    } catch (_) {
      // A missing or corrupt cover still produces a complete branded card.
    }
    if (!mounted) return;
    // Export waits for the same assets the preview uses, including branding.
    await Future.wait([
      precacheImage(const AssetImage(LokalLogo.asset), context),
      precacheImage(const AssetImage(LokalLogo.stickerAsset), context),
    ]);
    if (mounted)
      setState(() {
        _artwork = image;
        _color = color;
        _preparing = false;
      });
  }

  Future<void> _loadLyric() async {
    try {
      final service = LyricsService();
      final data = await service.loadLyricsForSong(widget.song);
      if (!mounted || _lyricEdited || data == null || data.lines.isEmpty)
        return;
      final player = PlayerService();
      final index =
          player.currentSongNotifier.value?.id == widget.song.id &&
              data.isSynchronized
          ? service.findCurrentLineIndex(data, player.positionNotifier.value)
          : -1;
      final text =
          index >= 0 &&
              index < data.lines.length &&
              data.lines[index].text.trim().isNotEmpty
          ? data.lines[index].text
          : data.lines
                .firstWhere(
                  (line) => line.text.trim().isNotEmpty,
                  orElse: () => data.lines.first,
                )
                .text;
      setState(() => _lyricController.text = text.trim());
    } catch (_) {
      /* Lyrics can be entered manually when unavailable. */
    } finally {
      if (mounted) setState(() => _lyricsLoading = false);
    }
  }

  Future<Uint8List> _captureCard() async {
    // Paint the selected, fully decoded card. No arbitrary delay and no
    // capture key on an offscreen item in a lazy template carousel.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) throw StateError('Share preview closed.');
    final boundary = _cardKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary)
      throw StateError('Card is unavailable.');
    final image = await boundary.toImage(pixelRatio: 3);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Card could not be encoded.');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Future<void> _export({required bool save}) async {
    if (_busy ||
        _preparing ||
        (_template == ShareTemplate.lyric && _lyricsLoading))
      return;
    setState(() {
      _busy = true;
      _saving = save;
      _error = null;
    });
    try {
      final bytes = await _captureCard();
      if (!mounted) return;
      if (save) {
        await GallerySaveService().saveImage(
          bytes: bytes,
          fileName: 'konnekted_card_${DateTime.now().millisecondsSinceEpoch}',
        );
        if (mounted)
          LokalToast.fromSnackBar(context, SnackBar(content: Text(l10n.savedToGallery)));
      } else {
        final cache = await getTemporaryDirectory();
        final directory = await Directory('${cache.path}/share_cards')
            .create(recursive: true);
        final output = await directory.createTemp('card-');
        final file = await File('${output.path}/konnekted-card.png')
            .writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        final box = context.findRenderObject();
        final origin = box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'image/png')],
            text: '${widget.song.title} — ${widget.song.artist}\nKonnekted',
            sharePositionOrigin: origin,
          ),
        );
      }
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error is GallerySaveException
              ? error.message
              : l10n.shareFailed(error),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    final screen = MediaQuery.sizeOf(context);
    final availableHeight = math.max(
      120.0,
      screen.height -
          MediaQuery.viewInsetsOf(context).bottom -
          MediaQuery.paddingOf(context).top -
          24,
    );
    final previewHeight = (screen.height * .42).clamp(150.0, 360.0);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Material(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: t.muted.withValues(alpha: .4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(Icons.style_rounded, color: t.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          lokalText('Share as card'),
                          style: TextStyle(
                            color: t.text,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.close,
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.close_rounded, color: t.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // The canvas always lays out at 360x450. Preview scaling is
                  // outside the capture boundary, so PNGs are always 1080x1350.
                  SizedBox(
                    height: previewHeight,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: RepaintBoundary(
                        key: _cardKey,
                        child: SizedBox(
                          width: KonnektedShareCard.width,
                          height: KonnektedShareCard.height,
                          child: KonnektedShareCard(
                            song: widget.song,
                            template: _template,
                            artwork: _artwork,
                            color: _color,
                            lyric: _lyricController.text,
                            lyricFontSize: _autoFit ? null : _lyricSize,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final template in ShareTemplate.values)
                        ChoiceChip(
                          avatar: Icon(template.icon, size: 17),
                          label: Text(template.label(context.l10n)),
                          selected: _template == template,
                          onSelected: _busy
                              ? null
                              : (_) => setState(() => _template = template),
                          selectedColor: t.accentSoft,
                          labelStyle: TextStyle(
                            color: _template == template ? t.accent : t.text,
                          ),
                        ),
                    ],
                  ),
                  if (_template == ShareTemplate.lyric) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _lyricController,
                      enabled: !_busy,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 700,
                      style: TextStyle(color: t.text),
                      decoration: InputDecoration(labelText: l10n.lyrics),
                      onChanged: (_) {
                        _lyricEdited = true;
                        setState(() {});
                      },
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: l10n.textSize,
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _autoFit = false;
                                  _lyricSize = (_lyricSize - 2)
                                      .clamp(14, 40)
                                      .toDouble();
                                }),
                          icon: const Icon(Icons.text_decrease_rounded),
                        ),
                        FilterChip(
                          label: Text(l10n.auto),
                          selected: _autoFit,
                          onSelected: _busy
                              ? null
                              : (value) => setState(() => _autoFit = value),
                        ),
                        IconButton(
                          tooltip: l10n.textSize,
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _autoFit = false;
                                  _lyricSize = (_lyricSize + 2)
                                      .clamp(14, 40)
                                      .toDouble();
                                }),
                          icon: const Icon(Icons.text_increase_rounded),
                        ),
                      ],
                    ),
                  ],
                  if (_preparing ||
                      (_template == ShareTemplate.lyric && _lyricsLoading)) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _busy ||
                                _preparing ||
                                (_template == ShareTemplate.lyric &&
                                    _lyricsLoading)
                            ? null
                            : () => _export(save: true),
                        icon: _busy && _saving
                            ? const _Progress()
                            : const Icon(Icons.download_rounded),
                        label: Text(l10n.save),
                      ),
                      FilledButton.icon(
                        onPressed:
                            _busy ||
                                _preparing ||
                                (_template == ShareTemplate.lyric &&
                                    _lyricsLoading)
                            ? null
                            : () => _export(save: false),
                        style: FilledButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: t.bg,
                        ),
                        icon: _busy && !_saving
                            ? const _Progress()
                            : const Icon(Icons.ios_share_rounded),
                        label: Text(l10n.share),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress();
  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
