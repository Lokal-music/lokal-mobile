import 'package:isar_community/isar.dart';

part 'ios_song_identity_entity.g.dart';

/// Private singleton. Song IDs remain retired after clear, CUE edits and
/// receipt pruning. This state never enters the synchronized library journal.
@collection
class IosSongIdentityEntity {
  Id id = 1;
  int schemaVersion = 1;
  int lastAllocated = 0;
}
