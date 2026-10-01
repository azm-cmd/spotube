part of '../database.dart';

class AudioPlayerStateTable extends Table {
  IntColumn get id => integer().autoIncrement()();
  BoolColumn get playing => boolean()();
  TextColumn get loopMode => textEnum<PlaylistMode>()();
  BoolColumn get shuffled => boolean()();
  TextColumn get collections => text().map(const StringListConverter())();

  /// The saved queue: tracks with their entry ids, the groups and the shuffle
  /// order. The column keeps its name and type from before Queue Groups; its
  /// text is now a versioned object, and the old list of tracks still reads.
  TextColumn get tracks => text()
      .map(const SavedQueueConverter())
      .withDefault(const Constant("[]"))();
  IntColumn get currentIndex => integer().withDefault(const Constant(0))();
}

/// Reads and writes the saved queue (see queue_persistence.dart).
///
/// Reading never throws: a row from before Queue Groups (a plain JSON list of
/// tracks) comes back as entries with fresh ids and no groups, and anything
/// unreadable comes back as an empty or shortened queue with the reasons in
/// [SavedQueue.issues].
class SavedQueueConverter
    extends TypeConverter<SavedQueue<SpotubeTrackObject>, String> {
  const SavedQueueConverter();

  static const _uuid = Uuid();

  @override
  SavedQueue<SpotubeTrackObject> fromSql(String fromDb) {
    return decodeSavedQueue<SpotubeTrackObject>(
      fromDb,
      decodeTrack: SpotubeTrackObject.fromJson,
      newId: _uuid.v4,
    );
  }

  @override
  String toSql(SavedQueue<SpotubeTrackObject> value) {
    return encodeSavedQueue<SpotubeTrackObject>(value, (t) => t.toJson());
  }
}
