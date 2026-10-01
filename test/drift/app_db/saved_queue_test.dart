import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_persistence.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

SpotubeTrackObject track(String id) {
  return SpotubeTrackObject.full(
    id: id,
    name: 'Track $id',
    externalUri: 'https://example.invalid/track/$id',
    album: SpotubeSimpleAlbumObject(
      id: 'album',
      name: 'Album',
      externalUri: 'https://example.invalid/album',
      artists: const [],
      albumType: SpotubeAlbumType.album,
    ),
    durationMs: 1000,
    isrc: 'ISRC$id',
    explicit: false,
  );
}

/// What a v8 database (before Queue Groups) has for this table. Its `tracks`
/// column is plain TEXT; the converter lives only in Dart.
const _tableAtV8 = '''
CREATE TABLE audio_player_state_table (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  playing BOOLEAN NOT NULL CHECK (playing IN (0, 1)),
  loop_mode TEXT NOT NULL,
  shuffled BOOLEAN NOT NULL CHECK (shuffled IN (0, 1)),
  collections TEXT NOT NULL,
  tracks TEXT NOT NULL DEFAULT '[]',
  current_index INTEGER NOT NULL DEFAULT 0
)''';

AppDatabase openAtV8(void Function(dynamic raw) seed) {
  return AppDatabase.forTesting(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute(_tableAtV8);
        raw.execute('PRAGMA user_version = 8');
        seed(raw);
      },
    ),
  );
}

Future<void> saveQueue(
  AppDatabase db,
  SavedQueue<SpotubeTrackObject> queue, {
  int currentIndex = 0,
  bool shuffled = false,
}) async {
  await db.into(db.audioPlayerStateTable).insertOnConflictUpdate(
        AudioPlayerStateTableCompanion.insert(
          id: const Value(0),
          playing: false,
          loopMode: PlaylistMode.none,
          shuffled: shuffled,
          collections: const [],
          tracks: Value(queue),
          currentIndex: Value(currentIndex),
        ),
      );
}

Future<AudioPlayerStateTableData> loadRow(AppDatabase db) =>
    db.select(db.audioPlayerStateTable).getSingle();

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('the saved queue in the database', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('a realistic queue comes back as it was saved', () async {
      // a b a(copy) c d a(copy) e, with two groups, the playing track inside
      // the first, and the queue shuffled in Dart.
      final tracks = ['a', 'b', 'a', 'c', 'd', 'a', 'e'].map(track).toList();
      var n = 0;
      final entries = createEntries(tracks, () => 'entry-${++n}');
      final queue = GroupedQueue.ungrouped(entries).createGroup(
        groupId: 'g-one',
        title: 'Road trip',
        entryIds: ['entry-2', 'entry-3', 'entry-4'],
      ).createGroup(
        groupId: 'g-two',
        title: 'Gym \u{1F3B5}',
        entryIds: ['entry-6'],
      ).setCollapsed('g-one', false);
      final saved = SavedQueue(
        entries: queue.entries,
        groups: queue.groups,
        shuffleOrder: ['entry-7', 'entry-1', 'entry-2', 'entry-3', 'entry-4'],
      );
      const playingIndex = 2; // entry-3, the second copy of track a

      await saveQueue(db, saved, currentIndex: playingIndex, shuffled: true);
      final row = await loadRow(db);
      final back = row.tracks;

      expect(back.issues, isEmpty);
      expect([
        for (final e in back.entries) e.id
      ], [
        for (final e in saved.entries) e.id,
      ]);
      expect(back.tracks, saved.tracks); // same tracks, same order
      expect(back.groups, saved.groups); // ids, titles, members, collapsed
      expect(back.groups.map((g) => g.collapsed), [false, true]);
      expect(back.shuffleOrder, saved.shuffleOrder);
      expect(back.queue.validate(), isEmpty);

      // The copies of track a are three different entries.
      final copies = [
        for (final e in back.entries)
          if (e.track.id == 'a') e.id,
      ];
      expect(copies, ['entry-1', 'entry-3', 'entry-6']);
      // Only the middle one is in the first group, the last in the second.
      expect(back.queue.groupOf('entry-3')!.id, 'g-one');
      expect(back.queue.groupOf('entry-1'), isNull);
      expect(back.queue.groupOf('entry-6')!.id, 'g-two');

      // The playing entry is the same entry.
      expect(row.currentIndex, playingIndex);
      expect(
        QueueSnapshot(back.queue, row.currentIndex).currentEntryId,
        'entry-3',
      );
      expect(row.shuffled, isTrue);
    });

    test('an empty row reads as an empty queue', () async {
      await db.into(db.audioPlayerStateTable).insert(
            AudioPlayerStateTableCompanion.insert(
              id: const Value(0),
              playing: false,
              loopMode: PlaylistMode.none,
              shuffled: false,
              collections: const [],
            ),
          );
      final row = await loadRow(db);
      expect(row.tracks.entries, isEmpty);
      expect(row.tracks.issues, isEmpty);

      await saveQueue(db, const SavedQueue.empty());
      expect((await loadRow(db)).tracks.entries, isEmpty);
    });

    test('a queue written by the old code still loads', () async {
      final legacy = jsonEncode([
        for (final id in ['a', 'b', 'a']) track(id).toJson(),
      ]);
      await saveQueue(db, const SavedQueue.empty(), currentIndex: 2);
      await db.customStatement(
        'UPDATE audio_player_state_table SET tracks = ?',
        [legacy],
      );

      final row = await loadRow(db);
      final back = row.tracks;

      expect(back.tracks, [track('a'), track('b'), track('a')]);
      expect(back.entries.map((e) => e.id).toSet(), hasLength(3));
      expect(back.groups, isEmpty);
      expect(back.shuffleOrder, isNull);
      expect(back.issues, isEmpty);
      expect(row.currentIndex, 2);
    });

    test('a damaged column does not stop the row from being read', () async {
      await saveQueue(db, const SavedQueue.empty());
      for (final text in ['{', 'null', '[1, 2', '{"version": 1}', '']) {
        await db.customStatement(
          'UPDATE audio_player_state_table SET tracks = ?',
          [text],
        );
        final row = await loadRow(db);
        expect(row.tracks.entries, isEmpty, reason: text);
      }
    });

    test('one unreadable track costs only that track', () async {
      final good = track('a').toJson();
      final text = jsonEncode({
        'version': 1,
        'entries': [
          {'id': 'x1', 'track': good},
          {
            'id': 'x2',
            'track': {'id': 'not a track'}
          },
          {'id': 'x3', 'track': track('c').toJson()},
        ],
        'groups': [
          {
            'id': 'g',
            'title': 'g',
            'collapsed': true,
            'memberIds': ['x1', 'x2', 'x3'],
          },
        ],
      });
      await saveQueue(db, const SavedQueue.empty());
      await db.customStatement(
        'UPDATE audio_player_state_table SET tracks = ?',
        [text],
      );

      final back = (await loadRow(db)).tracks;
      expect([for (final e in back.entries) e.id], ['x1', 'x3']);
      expect(back.droppedPositions, [1]);
      expect(back.groups.single.memberIds, ['x1', 'x3']);
    });

    test('is still the same column: TEXT, default "[]", no new column',
        () async {
      final columns = await db
          .customSelect('PRAGMA table_info(audio_player_state_table)')
          .get();
      expect(
        [for (final c in columns) c.read<String>('name')],
        [
          'id',
          'playing',
          'loop_mode',
          'shuffled',
          'collections',
          'tracks',
          'current_index'
        ],
      );
      final tracks =
          columns.singleWhere((c) => c.read<String>('name') == 'tracks');
      expect(tracks.read<String>('type'), 'TEXT');
      expect(tracks.read<int>('notnull'), 1);
      expect(tracks.read<String>('dflt_value'), "'[]'");
      expect(db.schemaVersion, 8); // no migration
    });
  });

  group('a database created before Queue Groups', () {
    test('opens without a migration and its queue loads', () async {
      final legacy = jsonEncode([
        for (final id in ['a', 'b', 'a', 'c']) track(id).toJson(),
      ]);
      final db = openAtV8((raw) {
        raw.execute(
          'INSERT INTO audio_player_state_table '
          '(id, playing, loop_mode, shuffled, collections, tracks, current_index) '
          "VALUES (0, 0, 'none', 1, '[]', ?, 3)",
          [legacy],
        );
      });
      addTearDown(db.close);

      final row = await loadRow(db);
      expect(row.tracks.tracks.map((t) => t.id), ['a', 'b', 'a', 'c']);
      expect(row.tracks.groups, isEmpty);
      expect(row.currentIndex, 3);
      expect(row.shuffled, isTrue);

      // And it can be written in the new format and read again.
      await saveQueue(
        db,
        SavedQueue(
          entries: row.tracks.entries,
          groups: [
            QueueGroup(
              id: 'g',
              title: 'Kept',
              memberIds: [row.tracks.entries[1].id, row.tracks.entries[2].id],
            ),
          ],
        ),
        currentIndex: 3,
      );
      final again = (await loadRow(db)).tracks;
      expect([for (final e in again.entries) e.id],
          [for (final e in row.tracks.entries) e.id]);
      expect(again.groups.single.title, 'Kept');
    });

    test('an old database that never had a queue still opens', () async {
      final db = openAtV8((raw) {
        raw.execute(
          'INSERT INTO audio_player_state_table '
          '(id, playing, loop_mode, shuffled, collections) '
          "VALUES (0, 0, 'none', 0, '[]')",
        );
      });
      addTearDown(db.close);

      final row = await loadRow(db);
      expect(row.tracks.entries, isEmpty);
      expect(row.currentIndex, 0);
    });
  });
}
