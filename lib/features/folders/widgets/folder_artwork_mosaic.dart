import 'package:flutter/material.dart';
import 'package:flick/core/constants/app_constants.dart';
import 'package:flick/core/utils/responsive.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/models/song.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';
import 'package:flick/widgets/common/flick_artwork_placeholder.dart';

/// Folder artwork for root folders and nested subfolders.
///
/// One distinct cover fills the entire square. Only folders with multiple
/// distinct covers use a 2x2 collage; fewer than four covers retain the
/// existing placeholder cells. This is based on artwork, not track count.
class FolderArtworkMosaic extends StatefulWidget {
  const FolderArtworkMosaic({super.key, required this.songs});

  final List<Song> songs;

  /// Return up to four songs with different, nonempty artwork locations.
  /// Song lists may include hundreds of tracks from the same album; the
  /// repeated cover must not count as four separate covers.
  static List<Song> distinctCoverSongs(List<Song> songs) {
    final seen = <String>{};
    final covers = <Song>[];
    for (final song in songs) {
      final art = song.albumArt?.trim();
      if (art != null && art.isNotEmpty && seen.add(art)) {
        covers.add(song);
        if (covers.length == 4) break;
      }
    }
    return covers;
  }

  @override
  State<FolderArtworkMosaic> createState() => _FolderArtworkMosaicState();
}

class _FolderArtworkMosaicState extends State<FolderArtworkMosaic> {
  late List<Song> _covers;
  late int _songCount;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _covers = FolderArtworkMosaic.distinctCoverSongs(widget.songs);
    _songCount = widget.songs.length;
  }

  @override
  void didUpdateWidget(covariant FolderArtworkMosaic oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.songs, widget.songs) ||
        _songCount != widget.songs.length) {
      _refresh();
    }
  }

  Widget _placeholder(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(AppConstants.radiusSm)),
    child: Container(
      color: context.lokal.surface2,
      child: const Center(
        child: FlickArtworkPlaceholder(size: 22, opacity: 0.9),
      ),
    ),
  );

  Widget _cover(BuildContext context, Song song, int size) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(AppConstants.radiusSm)),
    child: CachedImageWidget(
      imagePath: song.albumArt,
      audioSourcePath: song.filePath,
      fit: BoxFit.cover,
      useThumbnail: true,
      thumbnailWidth: size,
      thumbnailHeight: size,
      placeholder: _placeholder(context),
      errorWidget: _placeholder(context),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final cardWidth = context.scaleSize(AppConstants.cardWidthMd);
    final targetWidth = (cardWidth * devicePixelRatio).round();

    // Never split a lone image into a mosaic with three empty cells. Request
    // the full-size thumbnail so its enlarged tile stays sharp.
    if (_covers.length == 1) {
      return _cover(context, _covers.single, targetWidth);
    }

    final cells = <Widget>[
      for (final song in _covers)
        _cover(context, song, targetWidth ~/ 2),
    ];
    while (cells.length < 4) {
      cells.add(_placeholder(context));
    }
    return GridView.count(
      crossAxisCount: 2,
      physics: const NeverScrollableScrollPhysics(),
      children: cells,
    );
  }
}
