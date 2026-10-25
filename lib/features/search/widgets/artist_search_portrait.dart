import 'package:flutter/material.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/services/apple_music/apple_music_metadata_service.dart';
import 'package:flick/widgets/common/cached_image_widget.dart';

/// A verified artist portrait, not a track or album cover. Spotify supplies
/// artist imagery in catalogue responses; Apple's iTunes search does not.
/// For missing artwork, resolve an exact-named Apple Music artist and fetch
/// its dedicated editorial portrait. Cache lookups across scrolling tiles.
class ArtistSearchPortrait extends StatefulWidget {
  const ArtistSearchPortrait({
    super.key, required this.name, this.artworkUrl, this.size = 48,
  });
  final String name;
  final String? artworkUrl;
  final double size;

  @override
  State<ArtistSearchPortrait> createState() => _ArtistSearchPortraitState();
}

class _ArtistSearchPortraitState extends State<ArtistSearchPortrait> {
  static final _lookups = <String, Future<String?>>{};
  static String normalize(String value) => value.trim().toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  static Future<String?> lookup(String name) {
    final key = normalize(name);
    if (key.isEmpty) return Future.value(null);
    if (!_lookups.containsKey(key)) {
      if (_lookups.length >= 180) _lookups.remove(_lookups.keys.first);
      _lookups[key] = () async {
        try {
          final service = AppleMusicMetadataService.instance;
          final artist = await service.resolveArtist(name);
          if (artist == null || normalize(artist.name) != key) return null;
          final info = await service.getArtistInfo(artist.artistId);
          final candidate = info?.imageUrl;
          return candidate != null && candidate.startsWith('https://')
              ? candidate : null;
        } catch (_) { return null; }
      }();
    }
    return _lookups[key]!;
  }

  late Future<String?> _fallback;

  @override
  void initState() {
    super.initState();
    _fallback = _future();
  }

  Future<String?> _future() {
    if (widget.artworkUrl?.startsWith('https://') == true) {
      return Future.value(widget.artworkUrl);
    }
    return lookup(widget.name);
  }

  @override
  void didUpdateWidget(covariant ArtistSearchPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name ||
        oldWidget.artworkUrl != widget.artworkUrl) {
      _fallback = _future();
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: ClipOval(
      child: FutureBuilder<String?>(
        future: _fallback,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image != null && image.isNotEmpty) {
            return CachedImageWidget(
              imagePath: image, fit: BoxFit.cover,
              placeholder: _placeholder(context),
              errorWidget: _placeholder(context),
            );
          }
          return _placeholder(context);
        },
      ),
    ),
  );

  Widget _placeholder(BuildContext context) => ColoredBox(
    color: context.lokal.surface2,
    child: Center(
      child: Icon(Icons.person_outline, color: context.lokal.muted, size: widget.size * .45),
    ),
  );
}
