import 'artist_credits.dart';
import '../../features/discovery/recommendation_match.dart';

/// Only generic soundtrack wording is interchangeable. Language, live, deluxe
/// and score qualifiers remain part of the release identity.
String albumTitleKey(String value) => recommendationKey(
  value.replaceAll(
    RegExp(
      r'\s*[\[(](?:original\s+)?(?:motion\s+picture\s+|movie\s+)?soundtrack[\])]',
      caseSensitive: false,
    ),
    '',
  ),
);

bool albumTitlesMatch(String a, String b) =>
    albumTitleKey(a).isNotEmpty && albumTitleKey(a) == albumTitleKey(b);

String _artistKey(String value) {
  final key = recommendationKey(value);
  // Catalogue transliterations sometimes duplicate a consonant, e.g.
  // Abhyankar/Abhyankkar. Limit this tolerance to substantial multiword names.
  return key.length >= 10 && key.contains(' ')
      ? key.replaceAllMapped(RegExp(r'([a-z])\1+'), (m) => m[1]!)
      : key;
}

bool albumArtistsMatch(String requested, String candidate) {
  final wanted = splitArtistCredits(requested).map(_artistKey).toSet()
    ..removeAll({'', 'various artists', 'unknown artist'});
  return wanted.isNotEmpty &&
      splitArtistCredits(candidate).map(_artistKey).any(wanted.contains);
}
