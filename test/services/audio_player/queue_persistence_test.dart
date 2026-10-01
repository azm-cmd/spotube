import 'dart:convert';
import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_persistence.dart';
import 'package:spotube/services/audio_player/queue_shuffle.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

import 'queue_test_support.dart';

// The track of these tests is `{"id": "<track id>"}`; "BAD" cannot be read.
Object? encodeTrack(TestTrack track) => {'id': track.id};

TestTrack decodeTrack(Map<String, dynamic> json) {
  final id = json['id'];
  if (id is! String || id == 'BAD') throw FormatException('bad track $json');
  return TestTrack(id);
}

/// A generator of ids `n1`, `n2`, ... for entries that have none.
String Function() freshIds() {
  var n = 0;
  return () => 'n${++n}';
}

String save(SavedQueue<TestTrack> queue) =>
    encodeSavedQueue(queue, encodeTrack);

SavedQueue<TestTrack> load(String? raw, [String Function()? newId]) =>
    decodeSavedQueue<TestTrack>(
      raw,
      decodeTrack: decodeTrack,
      newId: newId ?? freshIds(),
    );

/// What survives a save and a load.
SavedQueue<TestTrack> roundTrip(SavedQueue<TestTrack> queue) =>
    load(save(queue));

/// Entries e1.. for [trackIds], with groups made through the real operations.
TestQueue queueOf(
  List<String> trackIds, [
  Map<String, List<String>> groups = const {},
]) {
  var queue = GroupedQueue.ungrouped([
    for (var i = 0; i < trackIds.length; i++)
      QueueEntry('e${i + 1}', TestTrack(trackIds[i])),
  ]);
  groups.forEach((id, members) {
    queue =
        queue.createGroup(groupId: id, title: 'Group $id', entryIds: members);
  });
  return queue;
}

SavedQueue<TestTrack> savedOf(TestQueue queue, {List<String>? shuffleOrder}) =>
    SavedQueue(
      entries: queue.entries,
      groups: queue.groups,
      shuffleOrder: shuffleOrder,
    );

List<String> ids(SavedQueue<TestTrack> q) => [for (final e in q.entries) e.id];
List<String> trackIds(SavedQueue<TestTrack> q) =>
    [for (final e in q.entries) e.track.id];

List<String> shape(SavedQueue<TestTrack> q) => [
      for (final item in q.queue.items)
        switch (item) {
          EntryItem<TestTrack>(:final entry) => entry.id,
          GroupItem<TestTrack>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ];

/// The JSON text of a version 1 queue, written by hand so that a test can
/// break exactly one thing.
String doc({
  Object? entries,
  Object? groups = const [],
  Object? shuffleOrder,
  Object? version = 1,
}) =>
    jsonEncode({
      if (version != null) 'version': version,
      'entries': entries ??
          [
            for (var i = 1; i <= 5; i++)
              {
                'id': 'e$i',
                'track': {'id': 't$i'},
              },
          ],
      'groups': groups,
      if (shuffleOrder != null) 'shuffleOrder': shuffleOrder,
    });

Map<String, Object?> grp(String id, List<Object?> members,
        {Object? title = 'T', Object? collapsed = true}) =>
    {'id': id, 'title': title, 'collapsed': collapsed, 'memberIds': members};

void main() {
  group('the saved format', () {
    test('is a versioned object with entries, groups and no shuffle', () {
      final text = save(savedOf(queueOf([
        'a',
        'b'
      ], {
        'G1': ['e1', 'e2']
      })));
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(json.keys, unorderedEquals(['version', 'entries', 'groups']));
      expect(json['version'], 1);
      expect(json['entries'], [
        {
          'id': 'e1',
          'track': {'id': 'a'}
        },
        {
          'id': 'e2',
          'track': {'id': 'b'}
        },
      ]);
      expect(json['groups'], [
        {
          'id': 'G1',
          'title': 'Group G1',
          'collapsed': true,
          'memberIds': ['e1', 'e2'],
        },
      ]);
    });

    test('the shuffle order is only written while shuffled', () {
      final queue = queueOf(['a', 'b']);
      expect(jsonDecode(save(savedOf(queue))), isNot(contains('shuffleOrder')));
      expect(
        (jsonDecode(save(savedOf(queue, shuffleOrder: ['e2', 'e1'])))
            as Map)['shuffleOrder'],
        ['e2', 'e1'],
      );
    });

    test('saving is deterministic', () {
      final saved = savedOf(queueOf([
        'a',
        'b',
        'a'
      ], {
        'G1': ['e2', 'e3']
      }));
      expect(save(saved), save(saved));
    });
  });

  group('save, then load', () {
    void expectSame(TestQueue queue, {List<String>? shuffleOrder}) {
      final back = roundTrip(savedOf(queue, shuffleOrder: shuffleOrder));

      expect(ids(back), [for (final e in queue.entries) e.id]);
      expect(trackIds(back), [for (final e in queue.entries) e.track.id]);
      expect(back.groups, queue.groups);
      expect(back.queue.items.length, queue.items.length);
      expect(back.queue.validate(), isEmpty);
      expect(back.shuffleOrder, shuffleOrder);
      expect(back.issues, isEmpty);
      expect(back.droppedPositions, isEmpty);
    }

    test('a queue without groups', () {
      expectSame(queueOf(['a', 'b', 'c', 'd']));
    });

    test('an empty queue', () {
      final back = roundTrip(const SavedQueue.empty());
      expect(back.entries, isEmpty);
      expect(back.groups, isEmpty);
      expect(back.issues, isEmpty);
    });

    test('a queue of one entry', () {
      expectSame(queueOf(['a']));
    });

    test('one group', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd',
        'e'
      ], {
        'G1': ['e2', 'e3', 'e4']
      });
      expectSame(queue);
      expect(shape(roundTrip(savedOf(queue))), ['e1', 'G1[e2,e3,e4]', 'e5']);
    });

    test('several groups', () {
      expectSame(queueOf([
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g'
      ], {
        'G1': ['e1', 'e2'],
        'G2': ['e4', 'e5', 'e6'],
      }));
    });

    test('groups separated by loose entries', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g'
      ], {
        'G1': ['e2', 'e3'],
        'G2': ['e5', 'e6'],
      });
      expectSame(queue);
      expect(
        shape(roundTrip(savedOf(queue))),
        ['e1', 'G1[e2,e3]', 'e4', 'G2[e5,e6]', 'e7'],
      );
    });

    test('adjacent groups stay two groups', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd'
      ], {
        'G1': ['e1', 'e2'],
        'G2': ['e3', 'e4'],
      });
      expectSame(queue);
      expect(shape(roundTrip(savedOf(queue))), ['G1[e1,e2]', 'G2[e3,e4]']);
    });

    test('single-entry groups', () {
      final queue = queueOf([
        'a',
        'b',
        'c'
      ], {
        'G1': ['e1'],
        'G2': ['e3'],
      });
      expectSame(queue);
      expect(shape(roundTrip(savedOf(queue))), ['G1[e1]', 'e2', 'G2[e3]']);
    });

    test('a group that covers the whole queue', () {
      expectSame(queueOf([
        'a',
        'b',
        'c'
      ], {
        'G1': ['e1', 'e2', 'e3']
      }));
    });

    test('titles and collapsed state, whatever they are', () {
      var queue = queueOf(['a', 'b', 'c', 'd', 'e', 'f']);
      queue = queue
          .createGroup(groupId: 'G1', title: '', entryIds: ['e1', 'e2'])
          .createGroup(
              groupId: 'G2',
              title: 'He said "hi" \\ \n ünï 🎵 </script>',
              entryIds: ['e3', 'e4'])
          .createGroup(groupId: 'G3', title: '  ', entryIds: ['e6'])
          .setCollapsed('G1', false)
          .setCollapsed('G2', true)
          .setCollapsed('G3', false);

      final back = roundTrip(savedOf(queue));

      expect(back.groups, queue.groups);
      expect([
        for (final g in back.groups) g.title
      ], [
        '',
        'He said "hi" \\ \n ünï 🎵 </script>',
        '  ',
      ]);
      expect([for (final g in back.groups) g.collapsed], [false, true, false]);
    });

    test('the same track twice stays two entries with two ids', () {
      final queue = queueOf([
        'a',
        'a',
        'a',
        'b'
      ], {
        'G1': ['e2']
      });
      final back = roundTrip(savedOf(queue));

      expect(trackIds(back), ['a', 'a', 'a', 'b']);
      expect(ids(back), ['e1', 'e2', 'e3', 'e4']);
      expect(back.entries.map((e) => e.id).toSet(), hasLength(4));
      // Only the second copy is in the group.
      expect(shape(back), ['e1', 'G1[e2]', 'e3', 'e4']);
    });

    test('ids come back as saved, not as issued by the loader', () {
      final back = load(
        save(savedOf(queueOf(['a', 'b']))),
        () => fail('no entry needed a new id'),
      );
      expect(ids(back), ['e1', 'e2']);
    });

    test('identity is never taken from the track id', () {
      // Two entries with one track id and different ids; the ids are kept
      // apart, and a track id is not accepted as the id of an entry.
      final back = roundTrip(SavedQueue(entries: [
        QueueEntry('x', const TestTrack('same')),
        QueueEntry('y', const TestTrack('same')),
      ]));
      expect(ids(back), ['x', 'y']);
      expect(back.entries.every((e) => e.id != e.track.id), isTrue);
    });

    test('saving and loading again changes nothing', () {
      final queue = queueOf([
        'a',
        'b',
        'a',
        'c',
        'a'
      ], {
        'G1': ['e2', 'e3'],
        'G2': ['e5'],
      });
      final once = save(savedOf(queue));
      final twice = save(load(once));
      expect(twice, once);
    });

    test('the playing entry stays the playing entry', () {
      final queue = queueOf([
        'a',
        'b',
        'a',
        'c',
        'd'
      ], {
        'G1': ['e2', 'e3', 'e4']
      });
      for (var playing = 0; playing < 5; playing++) {
        final before = QueueSnapshot(queue, playing);
        final back = roundTrip(savedOf(queue));
        final index = remapCurrentIndex(
            playing, back.droppedPositions, back.entries.length);
        final after = QueueSnapshot(back.queue, index);

        expect(after.currentEntryId, before.currentEntryId, reason: '$playing');
      }
    });

    test('shuffle order, when there is one', () {
      expectSame(
        queueOf([
          'a',
          'b',
          'c',
          'd'
        ], {
          'G1': ['e1', 'e2']
        }),
        shuffleOrder: ['e3', 'e1', 'e2', 'e4'],
      );
    });
  });

  group('shuffled queues', () {
    // The real shuffler on a fake player, saved and restored the way the
    // notifier does it.

    TestQueue original() => queueOf(
          ['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e'],
          {
            'G1': ['e2', 'e3', 'e4'],
            'G2': ['e6', 'e7'],
          },
        );

    (QueueShuffler<TestTrack>, FakeShufflePort, FakeMpv) start(
      TestQueue queue,
      int playing,
    ) {
      final mpv = FakeMpv(queue.entries);
      mpv.playing = mpv.playlist[playing];
      final sync = GroupedQueueSync(port: mpv, keyOf: (TestTrack t) => t.id);
      final port = FakeShufflePort(mpv);
      return (
        QueueShuffler<TestTrack>(
          sync: sync,
          port: port,
          nextInt: (bound) => 0, // a fixed shuffle: the rows rotate by one
        ),
        port,
        mpv,
      );
    }

    test('shuffle, save, restart, unshuffle: back to the original order',
        () async {
      final before = original();
      var snapshot = QueueSnapshot(before, 2); // e3 plays, inside G1

      final (shuffler, port, mpv) = start(before, 2);
      final changed = await shuffler.setShuffle(
        true,
        read: () => snapshot,
        commit: (s) => snapshot = s,
      );
      expect(changed, isTrue);
      expect(port.flatCalls, isEmpty);
      expect(flatIds(snapshot.queue), isNot(flatIds(before)));

      // Save.
      final text = save(SavedQueue(
        entries: snapshot.queue.entries,
        groups: snapshot.queue.groups,
        shuffleOrder: shuffler.orderBeforeShuffle,
      ));
      final playingBefore = snapshot.currentEntryId;

      // Restart: load, then give the saved shuffle to a new shuffler.
      final saved = load(text);
      expect(saved.shuffleOrder, flatIds(before));
      expect(saved.queue.validate(), isEmpty);
      expect(shape(saved), shapeOfQueue(snapshot.queue));

      var restored = QueueSnapshot(saved.queue, snapshot.currentIndex);
      expect(restored.currentEntryId, playingBefore);

      final (shuffler2, port2, mpv2) =
          start(saved.queue, snapshot.currentIndex);
      await shuffler2.restore(saved.shuffleOrder!);
      expect(port2.isShuffled, isTrue); // reported as shuffled again
      expect(shuffler2.orderBeforeShuffle, flatIds(before));

      // Unshuffle: the original order, groups whole, the playing entry kept.
      await shuffler2.setShuffle(
        false,
        read: () => restored,
        commit: (s) => restored = s,
      );
      expect(port2.flatCalls, isEmpty);
      expect(flatIds(restored.queue), flatIds(before));
      expect(shapeOfQueue(restored.queue), shapeOfQueue(before));
      expect(restored.currentEntryId, playingBefore);
      expect(port2.isShuffled, isFalse);
      expect(shuffler2.orderBeforeShuffle, isNull);
      expect(mpv2.physicalEntryIds, flatIds(before));
    });

    test('a queue that is not shuffled in Dart saves no order', () async {
      final queue = original();
      var snapshot = QueueSnapshot(queue, 0);
      final (shuffler, _, _) = start(queue, 0);
      expect(shuffler.orderBeforeShuffle, isNull);

      final back = roundTrip(SavedQueue(
        entries: queue.entries,
        groups: queue.groups,
        shuffleOrder: shuffler.orderBeforeShuffle,
      ));
      expect(back.shuffleOrder, isNull);
    });

    test('switching the shuffle off leaves nothing to save', () async {
      final queue = original();
      var snapshot = QueueSnapshot(queue, 0);
      final (shuffler, _, mpv) = start(queue, 0);
      await shuffler.setShuffle(true,
          read: () => snapshot, commit: (s) => snapshot = s);
      expect(shuffler.orderBeforeShuffle, isNotNull);
      await shuffler.setShuffle(false,
          read: () => snapshot, commit: (s) => snapshot = s);
      expect(shuffler.orderBeforeShuffle, isNull);
    });

    test('entries added after the shuffle survive the restart and unshuffle',
        () async {
      final order = ['e1', 'e2', 'e3'];
      // Saved queue: shuffled order e3 e1 e2 plus e9 added later.
      final queue = GroupedQueue.ungrouped([
        for (final id in ['e3', 'e1', 'e2', 'e9'])
          QueueEntry(id, TestTrack('t$id')),
      ]);
      final back = roundTrip(savedOf(queue, shuffleOrder: order));
      var restored = QueueSnapshot(back.queue, 0);
      final (shuffler, _, mpv) = start(back.queue, 0);
      await shuffler.restore(back.shuffleOrder!);

      // No groups any more: the shuffle was still done in Dart, so it is
      // undone in Dart too.
      await shuffler.setShuffle(false,
          read: () => restored, commit: (s) => restored = s);
      expect(flatIds(restored.queue), ['e1', 'e2', 'e3', 'e9']);
    });
  });

  group('a queue saved before Queue Groups', () {
    String legacy(List<String> tracks) => jsonEncode([
          for (final t in tracks) {'id': t}
        ]);

    test('loads, with new ids and no groups', () {
      final back = load(legacy(['a', 'b', 'c']));

      expect(trackIds(back), ['a', 'b', 'c']);
      expect(ids(back), ['n1', 'n2', 'n3']);
      expect(back.groups, isEmpty);
      expect(back.shuffleOrder, isNull);
      expect(back.issues, isEmpty);
      expect(back.droppedPositions, isEmpty);
    });

    test('keeps the order and the copies of a track apart', () {
      final back = load(legacy(['a', 'b', 'a', 'a']));
      expect(trackIds(back), ['a', 'b', 'a', 'a']);
      expect(ids(back).toSet(), hasLength(4));
    });

    test('an empty list is an empty queue', () {
      final back = load('[]');
      expect(back.entries, isEmpty);
      expect(back.issues, isEmpty);
    });

    test('is saved in the new format afterwards, with the same ids', () {
      final back = load(legacy(['a', 'b']));
      final again = load(save(back), () => fail('ids were saved'));
      expect(ids(again), ids(back));
      expect(trackIds(again), ['a', 'b']);
    });

    test('a track that cannot be read is skipped, the rest is kept', () {
      final back = load(legacy(['a', 'BAD', 'c']));
      expect(trackIds(back), ['a', 'c']);
      expect(back.droppedPositions, [1]);
      expect(back.issues, hasLength(1));
    });

    test('a list item that is not a track is skipped', () {
      final back = load(jsonEncode([
        {'id': 'a'},
        'oops',
        42,
        null,
        {'id': 'b'},
      ]));
      expect(trackIds(back), ['a', 'b']);
      expect(back.droppedPositions, [1, 2, 3]);
    });
  });

  group('current index after skipped tracks', () {
    test('is unchanged when nothing was skipped', () {
      expect(remapCurrentIndex(3, const [], 10), 3);
      expect(
          remapCurrentIndex(30, const [], 10), 30); // not this function's job
    });

    test('moves up past the tracks skipped before it', () {
      expect(remapCurrentIndex(4, const [0, 2], 6), 2);
      expect(remapCurrentIndex(4, const [5], 6), 4);
    });

    test('goes to the next track when the playing one was skipped', () {
      expect(remapCurrentIndex(2, const [2], 4), 2);
    });

    test('stays inside the shortened queue', () {
      expect(remapCurrentIndex(3, const [3], 3), 2);
      expect(remapCurrentIndex(3, const [0, 1, 2, 3], 0), 0);
    });

    test('follows the playing entry through the loader', () {
      final raw = doc(entries: [
        {
          'id': 'e1',
          'track': {'id': 'BAD'}
        },
        {
          'id': 'e2',
          'track': {'id': 'a'}
        },
        {
          'id': 'e3',
          'track': {'id': 'BAD'}
        },
        {
          'id': 'e4',
          'track': {'id': 'b'}
        },
        {
          'id': 'e5',
          'track': {'id': 'c'}
        },
      ]);
      final back = load(raw);
      expect(ids(back), ['e2', 'e4', 'e5']);
      // Position 3 (e4) plays.
      final index = remapCurrentIndex(3, back.droppedPositions, 3);
      expect(back.entries[index].id, 'e4');
    });
  });

  group('entry ids that are missing', () {
    test('an entry without an id gets a new one, the others keep theirs', () {
      final back = load(doc(entries: [
        {
          'id': 'e1',
          'track': {'id': 'a'}
        },
        {
          'track': {'id': 'b'}
        },
        {
          'id': '',
          'track': {'id': 'c'}
        },
        {
          'id': 7,
          'track': {'id': 'd'}
        },
        {
          'id': 'e5',
          'track': {'id': 'e'}
        },
      ]));

      expect(trackIds(back), ['a', 'b', 'c', 'd', 'e']);
      expect(ids(back), ['e1', 'n1', 'n2', 'n3', 'e5']);
    });

    test('groups still work around the entries that got new ids', () {
      final back = load(doc(
        entries: [
          {
            'id': 'e1',
            'track': {'id': 'a'}
          },
          {
            'track': {'id': 'b'}
          },
          {
            'id': 'e3',
            'track': {'id': 'c'}
          },
        ],
        groups: [
          grp('G1', ['e1']),
          grp('G2', ['e3']),
        ],
      ));
      expect(shape(back), ['G1[e1]', 'n1', 'G2[e3]']);
    });

    test('a group naming an entry that lost its id loses that member', () {
      final back = load(doc(
        entries: [
          {
            'id': 'e1',
            'track': {'id': 'a'}
          },
          {
            'track': {'id': 'b'}
          },
          {
            'id': 'e3',
            'track': {'id': 'c'}
          },
        ],
        groups: [
          grp('G1', ['e1', 'e2', 'e3']),
        ],
      ));
      // e2 is not in the queue any more: e1 and e3 are not one block.
      expect(back.groups, isEmpty);
      expect(trackIds(back), ['a', 'b', 'c']);
    });
  });

  group('entry ids that are used twice', () {
    String twice({List<Object?> groups = const [], Object? shuffle}) => doc(
          entries: [
            {
              'id': 'e1',
              'track': {'id': 'a'}
            },
            {
              'id': 'dup',
              'track': {'id': 'b'}
            },
            {
              'id': 'dup',
              'track': {'id': 'c'}
            },
            {
              'id': 'e4',
              'track': {'id': 'd'}
            },
          ],
          groups: groups,
          shuffleOrder: shuffle,
        );

    test('every entry is kept, and no two share an id', () {
      final back = load(twice());
      expect(trackIds(back), ['a', 'b', 'c', 'd']);
      expect(ids(back).toSet(), hasLength(4));
      expect(back.issues, isNotEmpty);
    });

    test('a group cannot name an id that stands for two entries', () {
      final back = load(twice(groups: [
        grp('G1', ['dup']),
        grp('G2', ['e1']),
      ]));
      expect(back.groups.map((g) => g.id), ['G2']);
      expect(back.queue.validate(), isEmpty);
    });

    test('the shuffle order ignores it too', () {
      final back = load(twice(shuffle: ['dup', 'e4', 'e1']));
      expect(back.shuffleOrder, ['e4', 'e1']);
    });

    test('three copies of one id are all kept', () {
      final back = load(doc(entries: [
        for (final t in ['a', 'b', 'c'])
          {
            'id': 'x',
            'track': {'id': t}
          },
      ]));
      expect(trackIds(back), ['a', 'b', 'c']);
      expect(ids(back).toSet(), hasLength(3));
    });
  });

  group('groups that cannot be trusted', () {
    SavedQueue<TestTrack> withGroups(List<Object?> groups) =>
        load(doc(groups: groups));

    test('a member that is not in the queue is dropped from its group', () {
      final back = withGroups([
        grp('G1', ['e2', 'gone', 'e3']),
      ]);
      expect(shape(back), ['e1', 'G1[e2,e3]', 'e4', 'e5']);
    });

    test('a group whose members are all gone is discarded', () {
      final back = withGroups([
        grp('G1', ['x', 'y']),
        grp('G2', ['e4']),
      ]);
      expect(shape(back), ['e1', 'e2', 'e3', 'G2[e4]', 'e5']);
    });

    test('a group with no members is discarded', () {
      expect(withGroups([grp('G1', [])]).groups, isEmpty);
    });

    test('a group that is not one block is discarded, entries are kept', () {
      final back = withGroups([
        grp('G1', ['e1', 'e3']),
        grp('G2', ['e4', 'e5']),
      ]);
      expect(shape(back), ['e1', 'e2', 'e3', 'G2[e4,e5]']);
      expect(ids(back), ['e1', 'e2', 'e3', 'e4', 'e5']);
    });

    test('members listed out of queue order are discarded', () {
      expect(
          withGroups([
            grp('G1', ['e3', 'e2'])
          ]).groups,
          isEmpty);
    });

    test('a member listed twice discards the group', () {
      final back = withGroups([
        grp('G1', ['e2', 'e2'])
      ]);
      expect(back.groups, isEmpty);
      expect(back.issues, anyElement(contains('twice')));
      expect(ids(back), ['e1', 'e2', 'e3', 'e4', 'e5']);
    });

    test('an entry in two groups: the first group is kept', () {
      final back = withGroups([
        grp('G1', ['e1', 'e2']),
        grp('G2', ['e2', 'e3']),
      ]);
      expect(shape(back), ['G1[e1,e2]', 'e3', 'e4', 'e5']);
    });

    test('two groups with one id: the first is kept', () {
      final back = withGroups([
        grp('G', ['e1', 'e2']),
        grp('G', ['e4', 'e5']),
      ]);
      expect(shape(back), ['G[e1,e2]', 'e3', 'e4', 'e5']);
    });

    test('groups listed out of queue order come back in queue order', () {
      final back = withGroups([
        grp('G2', ['e4', 'e5']),
        grp('G1', ['e1', 'e2']),
      ]);
      expect(back.groups.map((g) => g.id), ['G1', 'G2']);
      expect(back.queue.validate(), isEmpty);
    });

    test('wrong types discard only the group they are in', () {
      final back = withGroups([
        grp('G1', ['e1']),
        'not a group',
        42,
        null,
        {
          'title': 'no id',
          'memberIds': ['e2']
        },
        {
          'id': 7,
          'memberIds': ['e2']
        },
        grp('G2', ['e2'], title: 7),
        grp('G3', ['e2'], collapsed: 'yes'),
        grp('G4', ['e2', 3]),
        {'id': 'G5', 'title': 'x'},
        {'id': 'G6', 'memberIds': 'e2'},
        grp('G7', ['e5']),
      ]);
      expect(shape(back), ['G1[e1]', 'e2', 'e3', 'e4', 'G7[e5]']);
      expect(back.issues, isNotEmpty);
    });

    test('a missing title or collapsed flag falls back to the defaults', () {
      final back = withGroups([
        {
          'id': 'G1',
          'memberIds': ['e1', 'e2']
        },
      ]);
      expect(back.groups.single.title, '');
      expect(back.groups.single.collapsed, isTrue);
    });

    test('groups that are not a list are ignored', () {
      for (final bad in <Object?>[
        'x',
        3,
        {'a': 1},
        true
      ]) {
        final back = load(doc(groups: bad));
        expect(back.groups, isEmpty, reason: '$bad');
        expect(back.entries, hasLength(5));
      }
    });

    test('no groups key at all is a queue without groups', () {
      final text = jsonEncode({
        'version': 1,
        'entries': [
          {
            'id': 'e1',
            'track': {'id': 'a'}
          },
        ],
      });
      final back = load(text);
      expect(back.groups, isEmpty);
      expect(back.issues, isEmpty);
    });

    test('whatever is accepted is a valid grouped queue', () {
      final back = withGroups([
        grp('G1', ['e1', 'e2']),
        grp('G2', ['e2']),
        grp('G3', ['e4', 'e5']),
        grp('G4', ['e3', 'zzz']),
      ]);
      expect(back.queue.validate(), isEmpty);
      expect(ids(back), ['e1', 'e2', 'e3', 'e4', 'e5']);
    });
  });

  group('shuffle order that cannot be trusted', () {
    test('ids that are not in the queue, and repeats, are dropped', () {
      final back = load(doc(shuffleOrder: ['e3', 'gone', 'e1', 'e3', 'e2']));
      expect(back.shuffleOrder, ['e3', 'e1', 'e2']);
    });

    test('an order with nothing left is no order', () {
      expect(load(doc(shuffleOrder: [])).shuffleOrder, isNull);
      expect(load(doc(shuffleOrder: ['gone'])).shuffleOrder, isNull);
    });

    test('malformed orders are discarded, the queue is kept', () {
      for (final bad in <Object?>[
        'e1',
        7,
        {'a': 1},
        [1, 2],
        ['e1', null]
      ]) {
        final back = load(doc(shuffleOrder: bad));
        expect(back.shuffleOrder, isNull, reason: '$bad');
        expect(back.entries, hasLength(5), reason: '$bad');
      }
    });
  });

  group('text that is not a saved queue', () {
    test('nothing, or blank, is an empty queue', () {
      for (final raw in <String?>[null, '', '   ', '\n']) {
        final back = load(raw);
        expect(back.entries, isEmpty, reason: '$raw');
        expect(back.issues, isEmpty, reason: '$raw');
      }
    });

    test('broken JSON is an empty queue and does not throw', () {
      for (final raw in [
        '{',
        '[1,',
        'not json',
        '{"version":1,"entries":[}',
        '\u0000',
        '{"entries": [',
      ]) {
        final back = load(raw);
        expect(back.entries, isEmpty, reason: raw);
        expect(back.groups, isEmpty, reason: raw);
        expect(back.issues, isNotEmpty, reason: raw);
      }
    });

    test('JSON of the wrong kind is an empty queue', () {
      for (final raw in ['null', '3', '"text"', 'true']) {
        final back = load(raw);
        expect(back.entries, isEmpty, reason: raw);
        expect(back.issues, isNotEmpty, reason: raw);
      }
    });

    test('an object without a list of entries is an empty queue', () {
      for (final raw in [
        '{}',
        '{"version":1}',
        '{"version":1,"entries":null}',
        '{"version":1,"entries":"x"}',
        '{"version":1,"entries":{}}',
      ]) {
        final back = load(raw);
        expect(back.entries, isEmpty, reason: raw);
        expect(back.issues, isNotEmpty, reason: raw);
      }
    });

    test('entries that are not readable are skipped one by one', () {
      final back = load(doc(entries: [
        {
          'id': 'e1',
          'track': {'id': 'a'}
        },
        'x',
        null,
        {'id': 'e4'},
        {'id': 'e5', 'track': 'a'},
        {
          'id': 'e6',
          'track': {'id': 'BAD'}
        },
        {
          'id': 'e7',
          'track': {'id': 'b'}
        },
      ]));
      expect(ids(back), ['e1', 'e7']);
      expect(back.droppedPositions, [1, 2, 3, 4, 5]);
    });

    test('a missing or odd version is still read, and noted', () {
      for (final version in <Object?>[null, 'one', 2, 99]) {
        final back = load(doc(version: version));
        expect(back.entries, hasLength(5), reason: '$version');
        expect(back.issues, isNotEmpty, reason: '$version');
      }
      expect(load(doc()).issues, isEmpty);
    });

    test('a damaged queue still gives a queue the player can use', () {
      final back = load(doc(
        entries: [
          {
            'id': 'e1',
            'track': {'id': 'a'}
          },
          {
            'id': 'e2',
            'track': {'id': 'BAD'}
          },
          {
            'id': 'e3',
            'track': {'id': 'a'}
          },
        ],
        groups: [
          grp('G1', ['e1', 'e2', 'e3']),
        ],
      ));
      // e2 vanished, so e1 and e3 now sit next to each other: still a block.
      expect(shape(back), ['G1[e1,e3]']);
      expect(back.queue.validate(), isEmpty);
    });
  });

  group('whatever the text, reading is safe', () {
    // Break a valid document in many random ways. Reading must never throw,
    // never produce an invalid queue, never invent an entry and never repeat an
    // entry id.
    test('random damage to a realistic document', () {
      final queue = queueOf(
        ['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e'],
        {
          'G1': ['e2', 'e3', 'e4'],
          'G2': ['e6', 'e7'],
        },
      );
      final valid = jsonDecode(
        save(savedOf(queue, shuffleOrder: ['e8', 'e6', 'e7', 'e5'])),
      );
      final random = Random(2024);
      const junk = <Object?>[
        null,
        0,
        -1,
        1.5,
        'x',
        '',
        true,
        [],
        {},
        [1],
        'e2'
      ];

      Object? damage(Object? node, int budget) {
        if (budget == 0 || random.nextInt(8) == 0) {
          return junk[random.nextInt(junk.length)];
        }
        if (node is List) {
          final copy = [...node];
          if (copy.isNotEmpty) {
            final i = random.nextInt(copy.length);
            switch (random.nextInt(3)) {
              case 0:
                copy[i] = damage(copy[i], budget - 1);
              case 1:
                copy.removeAt(i);
              default:
                copy.insert(i, copy[random.nextInt(copy.length)]);
            }
          }
          return copy;
        }
        if (node is Map) {
          final copy = {...node};
          if (copy.isNotEmpty) {
            final key = copy.keys.elementAt(random.nextInt(copy.length));
            if (random.nextBool()) {
              copy[key] = damage(copy[key], budget - 1);
            } else {
              copy.remove(key);
            }
          }
          return copy;
        }
        return junk[random.nextInt(junk.length)];
      }

      for (var round = 0; round < 1500; round++) {
        var node = valid;
        for (var hits = random.nextInt(4) + 1; hits > 0; hits--) {
          node = damage(node, 4);
        }
        final raw = jsonEncode(node);

        final back = load(raw);

        expect(back.queue.validate(), isEmpty, reason: raw);
        expect(ids(back).toSet(), hasLength(back.entries.length),
            reason: 'duplicate entry id in $raw');
        // Nothing is invented: at most the entries that were in the text.
        final listed = node is Map && node['entries'] is List
            ? (node['entries'] as List).length
            : (node is List ? node.length : 0);
        expect(back.entries.length, lessThanOrEqualTo(listed), reason: raw);
        final order = back.shuffleOrder;
        if (order != null) {
          expect(order.toSet(), hasLength(order.length), reason: raw);
          expect(order.every(ids(back).contains), isTrue, reason: raw);
        }
        // What was read can be saved and read again unchanged.
        final again = load(save(back), () => fail('ids were saved: $raw'));
        expect(ids(again), ids(back), reason: raw);
        expect(again.groups, back.groups, reason: raw);
      }
    });

    test('random text never throws', () {
      final random = Random(7);
      const pieces = [
        '{',
        '}',
        '[',
        ']',
        '"',
        ',',
        ':',
        'null',
        '"entries"',
        '"groups"',
        '"id"',
        '"track"',
        '1',
        'true',
        ' ',
      ];
      for (var i = 0; i < 2000; i++) {
        final text = [
          for (var n = random.nextInt(25); n > 0; n--)
            pieces[random.nextInt(pieces.length)],
        ].join();
        final back = load(text);
        expect(back.queue.validate(), isEmpty, reason: text);
      }
    });
  });
}

List<String> flatIds(TestQueue queue) => [for (final e in queue.entries) e.id];

List<String> shapeOfQueue(TestQueue queue) => [
      for (final item in queue.items)
        switch (item) {
          EntryItem<TestTrack>(:final entry) => entry.id,
          GroupItem<TestTrack>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ];
