/// Full-player-only artwork URL upgrades.
///
/// Canvas can hide a low-resolution search/mini-player thumbnail until motion
/// is disabled. Promote only well-known, same-image CDN sizing conventions;
/// the caller must retry the original URL if the larger rendition is absent.
class PlayerArtworkQuality {
  const PlayerArtworkQuality._();

  static List<String> candidates(String? original) {
    if (original == null || original.isEmpty) return const [];
    final uri = Uri.tryParse(original);
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme.toLowerCase())) {
      return [original];
    }
    final host = uri.host.toLowerCase();
    String? upgraded;

    // Spotify album art is the same image hash across these sizes.
    // 640px (b273) is substantially clearer than the 64/160/300px tiles.
    if (host == 'i.scdn.co' && uri.path.startsWith('/image/')) {
      final updated = uri.path.replaceFirst(
        RegExp(r'ab67616d(?:00004851|000082c1|00001e02)'),
        'ab67616d0000b273',
      );
      if (updated != uri.path) upgraded = uri.replace(path: updated).toString();
    }

    // Apple / iTunes artwork URLs encode the requested size in their suffix.
    if (upgraded == null &&
        (host == 'is1-ssl.mzstatic.com' ||
            host == 'is2-ssl.mzstatic.com' ||
            host == 'is3-ssl.mzstatic.com' ||
            host == 'is4-ssl.mzstatic.com' ||
            host == 'is5-ssl.mzstatic.com' ||
            host == 'a1.mzstatic.com')) {
      final updated = uri.path.replaceFirstMapped(
        RegExp(r'/(\d{2,4})x(\d{2,4})bb\.'),
        (m) => int.parse(m[1]!) < 1200 && int.parse(m[2]!) < 1200
            ? '/1200x1200bb.'
            : m[0]!,
      );
      if (updated != uri.path) upgraded = uri.replace(path: updated).toString();
    }

    // Deezer track sleeves include their dimensions after the cover hash.
    if (upgraded == null &&
        host.endsWith('.dzcdn.net') &&
        uri.path.startsWith('/images/cover/')) {
      final updated = uri.path.replaceFirstMapped(
        RegExp(r'/(\d{2,4})x(\d{2,4})-'),
        (m) => int.parse(m[1]!) < 1000 && int.parse(m[2]!) < 1000
            ? '/1000x1000-'
            : m[0]!,
      );
      if (updated != uri.path) upgraded = uri.replace(path: updated).toString();
    }

    // Tidal serves each album hash in independently sized images.
    if (upgraded == null &&
        host == 'resources.tidal.com' &&
        uri.path.startsWith('/images/')) {
      final updated = uri.path.replaceFirstMapped(
        RegExp(r'/(\d{2,4})x(\d{2,4})\.jpg$'),
        (m) => int.parse(m[1]!) < 1280 && int.parse(m[2]!) < 1280
            ? '/1280x1280.jpg'
            : m[0]!,
      );
      if (updated != uri.path) upgraded = uri.replace(path: updated).toString();
    }

    // Google-hosted YouTube Music album covers often arrive as a 60/120px
    // image with explicit =w120-h120-l90-rj or =s120 sizing. Retain all
    // existing crop/quality modifiers while requesting the same image at
    // 1200px. Fallback to the supplied URL if the larger image is unavailable.
    final googleImage = host == 'googleusercontent.com' ||
        host.endsWith('.googleusercontent.com') ||
        host == 'ggpht.com' || host.endsWith('.ggpht.com');
    if (upgraded == null && googleImage) {
      final size = RegExp(r'=w(\d+)-h(\d+)').firstMatch(original);
      if (size != null &&
          (int.parse(size[1]!) < 1200 || int.parse(size[2]!) < 1200)) {
        upgraded = original.replaceFirst(
          RegExp(r'=w\d+-h\d+'), '=w1200-h1200',
        );
      } else {
        final square = RegExp(r'=s(\d+)(?=-|$)').firstMatch(original);
        if (square != null && int.parse(square[1]!) < 1200) {
          upgraded = original.replaceFirst(
            RegExp(r'=s\d+(?=-|$)'), '=s1200',
          );
        }
      }
    }

    // The max-res YouTube video still may not exist. Try SD before reverting
    // all the way to the often blurry 120/480px thumbnail in search.
    if (upgraded == null &&
        (host == 'i.ytimg.com' || host == 'img.youtube.com')) {
      final match = RegExp(
        r'/(?:default|mqdefault|hqdefault|sddefault|hq720)\.jpg      ).firstMatch(uri.path);
      if (match != null) {
        final maxres = uri.replace(
          path: uri.path.replaceFirst(match[0]!, '/maxresdefault.jpg'),
        ).toString();
        final sd = uri.replace(
          path: uri.path.replaceFirst(match[0]!, '/sddefault.jpg'),
        ).toString();
        return {maxres, sd, original}.toList(growable: false);
      }
    }
    return upgraded == null ? [original] : [upgraded, original];
  }
}
,
      ).firstMatch(uri.path);
      if (match != null) {
        final maxres = uri.replace(
          path: uri.path.replaceFirst(match[0]!, '/maxresdefault.jpg'),
        ).toString();
        final sd = uri.replace(
          path: uri.path.replaceFirst(match[0]!, '/sddefault.jpg'),
        ).toString();
        return {maxres, sd, original}.toList(growable: false);
      }
    }
    return upgraded == null ? [original] : [upgraded, original];
  }
}
