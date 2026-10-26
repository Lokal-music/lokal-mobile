import 'bini_lyrics_matcher.dart';
import 'lyricsplus_normalizer.dart';
import 'graceful_http_client.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/models/song.dart';

const lyricsSources = <String, String>{
  'binilyrics': 'BiniLyrics',
  'betterlyrics': 'BetterLyrics',
  'betterlyrics_qq': 'BetterLyrics Portato',
  'lyricsplus': 'LyricsPlus',
  'unison': 'Unison',
  'lrclib': 'LRCLIB',
  'kugou': 'KuGou',
  'lyricsovh': 'lyrics.ovh',
};

class LyricsSourcesState {
  const LyricsSourcesState({
    this.order = const [
      'binilyrics',
      'betterlyrics',
      'betterlyrics_qq',
      'lyricsplus',
      'unison',
      'lrclib',
      'kugou',
      'lyricsovh',
    ],
    this.disabled = const {},
    this.preferWords = true,
  });
  final List<String> order;
  final Set<String> disabled;
  final bool preferWords;
  static Future<LyricsSourcesState> load() async {
    final prefs = await SharedPreferences.getInstance();
    var saved =
        prefs.getStringList('lokal.lyrics.sources.order') ?? const <String>[];
    const legacy =
        'lrclib,binilyrics,betterlyrics,betterlyrics_qq,lyricsplus,unison,kugou,lyricsovh';
    if (saved.join(',') == legacy) saved = const [];

    return LyricsSourcesState(
      order: {
        ...saved.where(lyricsSources.containsKey),
        ...lyricsSources.keys,
      }.toList(),
      disabled: (prefs.getStringList('lokal.lyrics.sources.disabled') ?? [])
          .toSet(),
      preferWords: prefs.getBool('lokal.lyrics.sources.words') ?? true,
    );
  }
}

class LyricsSourcesNotifier extends Notifier<LyricsSourcesState> {
  @override
  LyricsSourcesState build() {
    unawaited(_load());
    return const LyricsSourcesState();
  }

  Future<void> _load() async {
    final saved = await LyricsSourcesState.load();
    if (ref.mounted) state = saved;
  }

  Future<void> set({
    List<String>? order,
    Set<String>? disabled,
    bool? preferWords,
  }) async {
    state = LyricsSourcesState(
      order: order ?? state.order,
      disabled: disabled ?? state.disabled,
      preferWords: preferWords ?? state.preferWords,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('lokal.lyrics.sources.order', state.order);
    await prefs.setStringList(
      'lokal.lyrics.sources.disabled',
      state.disabled.toList(),
    );
    await prefs.setBool('lokal.lyrics.sources.words', state.preferWords);
  }
}

final lyricsSourcesProvider =
    NotifierProvider<LyricsSourcesNotifier, LyricsSourcesState>(
      LyricsSourcesNotifier.new,
    );

/// Desktop's public, unkeyed provider protocols. A miss/failure falls through;
/// bounded requests are closed after completion and never change local files.
class AdditionalLyricsSources {
  static Future<String?> fetch(
    String source,
    Song song, {
    bool Function()? stillCurrent,
  }) async {
    final client = GracefulHttpClient();
    Future<String?> text(String endpoint, Map<String, String> query) async {
      if (stillCurrent != null && !stillCurrent()) return null;
      final uri = Uri.parse(endpoint)
          .replace(queryParameters: query.isEmpty ? null : query);
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return null;
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 2 * 1024 * 1024) {
        return null;
      }
      return utf8.decode(response.bodyBytes);
    }

    Future<dynamic> json(String endpoint, Map<String, String> query) async {
      final raw = await text(endpoint, query);
      return raw == null ? null : jsonDecode(raw);
    }

    final duration = '${song.duration.inSeconds}';
    try {
      switch (source) {
        case 'betterlyrics':
        case 'betterlyrics_qq':
          final raw = await text(
            source == 'betterlyrics'
                ? 'https://lyrics-api.boidu.dev/getLyrics'
                : 'https://lyrics-api.boidu.dev/qq/getLyrics',
            {
              's': song.title,
              'a': song.artist,
              'd': duration,
              if (song.album != null) 'al': song.album!,
            },
          );
          return raw == null || raw.trimLeft().startsWith('{') ? null : raw;
        case 'unison':
          final body = await json('https://unison.boidu.dev/lyrics', {
            'song': song.title,
            'artist': song.artist,
            'duration': duration,
            if (song.album != null) 'album': song.album!,
          });
          return body?['success'] == true
              ? (body['data']?['lyrics'] as String?)
              : null;
        case 'lyricsovh':
          final body = await json(
            'https://api.lyrics.ovh/v1/${Uri.encodeComponent(song.artist)}/${Uri.encodeComponent(song.title)}',
            {},
          );
          return body?['lyrics'] as String?;
        case 'binilyrics':
          final body = await json('https://lyrics-api.binimum.org/', {
            'track': song.title,
            'artist': song.artist,
            'duration': duration,
          });
          final results = body?['results'];
          if (results is! List) return null;
          final hit = pickBiniLyrics(results, song);
          final url = hit?['lyricsUrl'];
          return url is String ? await text(url, {}) : null;
        case 'lyricsplus':
          for (final host in [
            'lyricsplus.binimum.org',
            'lyricsplus.atomix.one',
            'lyricsplus.prjktla.my.id',
          ]) {
            try {
              final body = await json('https://$host/v2/lyrics/get', {
                'title': song.title,
                'artist': song.artist,
                'duration': duration,
                if (song.album != null) 'album': song.album!,
              });
              final normalized = normalizeLyricsPlusV2(
                body,
                duration: song.duration,
              );
              if (normalized != null) return normalized;
              // No usable match on this mirror: continue to the next one.
            } catch (_) {
              /* Try the next community mirror. */
            }
          }
          return null;
        case 'kugou':
          final body = await json('https://lyrics.kugou.com/search', {
            'ver': '1',
            'man': 'yes',
            'client': 'pc',
            'keyword': '${song.artist} - ${song.title}',
            'duration': '${song.duration.inMilliseconds}',
          });
          final candidates = body?['candidates'];
          if (candidates is! List) return null;
          final match = candidates
              .whereType<Map>()
              .where(
                (r) =>
                    song.duration == Duration.zero ||
                    r['duration'] is! num ||
                    ((r['duration'] as num).toDouble() -
                                song.duration.inMilliseconds)
                            .abs() <=
                        8000,
              )
              .firstOrNull;
          if (match == null) return null;
          final result = await json('https://lyrics.kugou.com/download', {
            'fmt': 'lrc',
            'charset': 'utf8',
            'client': 'pc',
            'ver': '1',
            'id': '${match['id']}',
            'accesskey': '${match['accesskey']}',
          });
          final content = result?['content'];
          return content is String ? utf8.decode(base64Decode(content)) : null;
      }
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
    return null;
  }


}
