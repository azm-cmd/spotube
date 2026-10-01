import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

import 'queue_test_support.dart';

/// Adding tracks to a queue with groups, against the fake player: "play next"
/// goes after the playing entry (and its group), "add to queue" at the end,
/// groups are never split, and the playing entry stays the playing entry.

void main() {
  /// e1 [G1: e2 e3 e4] e5 [G2: e6 e7] e8 (tracks a b a c a d b e)
  Future<QueueRig> grouped({int playing = 0}) => mixedRig(playing: playing);

  group('playNextIndex', () {
    test('is right after the playing entry', () {
      expect(playNextIndex(5, 0), 1);
      expect(playNextIndex(5, 2), 3);
    });

    test('is never past the end', () {
      expect(playNextIndex(5, 4), 5);
      expect(playNextIndex(1, 0), 1);
      expect(playNextIndex(0, 0), 0);
    });

    test('with nothing playing it is after the first entry, as it was', () {
      expect(playNextIndex(5, -1), 1);
    });
  });

  group('play next in a queue without groups', () {
    test('goes right after the playing entry', () async {
      final rig = QueueRig(['a', 'b', 'c', 'd'], playing: 1);
      final added = await rig.insert(['x'], afterPlaying: true);

      expect(rig.flat, ['e1', 'e2', 'n1', 'e3', 'e4']);
      expect(added, ['n1']);
      rig.expectInSync();
      expect(rig.mpv.commands, ['insert 2']);
    });

    test('keeps the order of several tracks', () async {
      final rig = QueueRig(['a', 'b', 'c'], playing: 0);
      await rig.insert(['x', 'y', 'z'], afterPlaying: true);

      expect(rig.flat, ['e1', 'n1', 'n2', 'n3', 'e2', 'e3']);
      expect([for (final e in rig.queue.entries) e.track.id],
          ['a', 'x', 'y', 'z', 'b', 'c']);
      rig.expectInSync();
    });

    test('after the last entry is an append', () async {
      final rig = QueueRig(['a', 'b'], playing: 1);
      await rig.insert(['x'], afterPlaying: true);

      expect(rig.flat, ['e1', 'e2', 'n1']);
      expect(rig.mpv.commands, ['append']);
      rig.expectInSync();
    });

    test('into an empty queue', () async {
      final rig = QueueRig([]);
      await rig.insert(['x', 'y'], afterPlaying: true);
      expect(rig.flat, ['n1', 'n2']);
      expect(rig.mpv.physicalEntryIds, ['n1', 'n2']);
    });

    test('the playing entry and index are untouched', () async {
      final rig = QueueRig(['a', 'b', 'c', 'd'], playing: 2);
      await rig.insert(['x', 'y'], afterPlaying: true);

      expect(rig.snapshot.currentEntryId, 'e3');
      expect(rig.snapshot.currentIndex, 2);
      expect(rig.mpv.currentIndex, 2);
    });
  });

  group('play next in a queue with groups', () {
    test('playing a loose entry puts it right after that entry', () async {
      final rig = await grouped(playing: 7); // e8, the last one
      await rig.insert(['x'], afterPlaying: true);
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8', 'n1']);
      rig.expectInSync();
    });

    test('playing the loose entry before a group goes in front of the group',
        () async {
      final rig = await grouped(playing: 0); // e1, then G1
      await rig.insert(['x', 'y'], afterPlaying: true);

      expect(rig.shape,
          ['e1', 'n1', 'n2', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(rig.queue.groupById('G1')!.memberIds, ['e2', 'e3', 'e4']);
      rig.expectInSync();
    });

    for (final playing in [1, 2, 3]) {
      test(
          'playing member ${playing - 1} of a group goes after the whole group',
          () async {
        final rig = await grouped(playing: playing); // inside G1
        await rig.insert(['x', 'y'], afterPlaying: true);

        expect(rig.shape,
            ['e1', 'G1[e2,e3,e4]', 'n1', 'n2', 'e5', 'G2[e6,e7]', 'e8']);
        expect(rig.snapshot.currentEntryId, 'e${playing + 1}');
        expect(rig.snapshot.currentIndex, playing);
        rig.expectInSync();
      });
    }

    test('a collapsed active group is no different', () async {
      final rig = await grouped(playing: 2);
      expect(rig.queue.groupById('G1')!.collapsed, isTrue);
      await rig.insert(['x'], afterPlaying: true);
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'n1', 'e5', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();
    });

    test('an expanded active group is no different', () async {
      final rig = await grouped(playing: 2);
      await rig.run((q) => q.setCollapsed('G1', false));
      await rig.insert(['x'], afterPlaying: true);
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'n1', 'e5', 'G2[e6,e7]', 'e8']);
      expect(rig.queue.groupById('G1')!.collapsed, isFalse);
      rig.expectInSync();
    });

    test('playing the last member of the last group goes after it', () async {
      final rig = await grouped(playing: 6); // e7, last of G2
      await rig.insert(['x'], afterPlaying: true);
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'n1', 'e8']);
      rig.expectInSync();
    });

    test('a group that is the whole queue', () async {
      final rig = QueueRig(['a', 'b', 'c'], playing: 1);
      await rig.run((q) => q.createGroup(
          groupId: 'G', title: 'All', entryIds: ['e1', 'e2', 'e3']));
      await rig.insert(['x'], afterPlaying: true);
      expect(rig.shape, ['G[e1,e2,e3]', 'n1']);
      expect(rig.mpv.commands.last, 'append');
      rig.expectInSync();
    });

    test('the new entries are loose, whatever is around them', () async {
      final rig = await grouped(playing: 2);
      await rig.insert(['x', 'y'], afterPlaying: true);
      for (final id in ['n1', 'n2']) {
        expect(rig.queue.groupOf(id), isNull);
      }
      expect(rig.queue.groups.map((g) => g.memberIds), [
        ['e2', 'e3', 'e4'],
        ['e6', 'e7']
      ]);
    });
  });

  group('add to queue', () {
    test('appends after the whole structure, in order', () async {
      final rig = await grouped(playing: 2);
      await rig.insert(['x', 'y', 'z']);

      expect(rig.shape,
          ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8', 'n1', 'n2', 'n3']);
      expect(rig.mpv.commands, ['append', 'append', 'append']);
      expect(rig.snapshot.currentEntryId, 'e3');
      rig.expectInSync();
    });

    test('after a queue that ends with a group', () async {
      final rig = QueueRig(['a', 'b', 'c'], playing: 0);
      await rig.run((q) =>
          q.createGroup(groupId: 'G', title: 'Tail', entryIds: ['e2', 'e3']));
      await rig.insert(['x']);
      expect(rig.shape, ['e1', 'G[e2,e3]', 'n1']);
      rig.expectInSync();
    });
  });

  group('copies of a track', () {
    test('each added copy is its own entry, next to the originals', () async {
      final rig = await grouped(playing: 0); // tracks a b a c a d b e
      final added = await rig.insert(['a', 'a', 'b'], afterPlaying: true);

      expect(added, ['n1', 'n2', 'n3']);
      expect(rig.queue.entries.map((e) => e.id).toSet(), hasLength(11));
      expect([for (final e in rig.queue.entries) e.track.id],
          ['a', 'a', 'a', 'b', 'b', 'a', 'c', 'a', 'd', 'b', 'e']);
      // The originals are the ones in the groups, the copies are loose.
      expect(rig.queue.groupById('G1')!.memberIds, ['e2', 'e3', 'e4']);
      expect(rig.queue.groupOf('n1'), isNull);
      rig.expectInSync();
    });

    test('the playing copy stays the playing one', () async {
      final rig = QueueRig(['a', 'a', 'a'], playing: 1);
      await rig.insert(['a', 'a'], afterPlaying: true);

      expect(rig.snapshot.currentEntryId, 'e2');
      expect(rig.mpv.playing!.entryId, 'e2');
      expect(rig.flat, ['e1', 'e2', 'n1', 'n2', 'e3']);
      rig.expectInSync();
    });

    test('adding the playing track again is another entry', () async {
      final rig = QueueRig(['a', 'b'], playing: 0);
      await rig.insert(['a'], afterPlaying: true);
      expect(rig.flat, ['e1', 'n1', 'e2']);
      expect(rig.queue.entries[0].id, isNot(rig.queue.entries[1].id));
      rig.expectInSync();
    });
  });

  group('current playback', () {
    test('adding before the playing entry keeps it playing', () async {
      final rig = await grouped(playing: 4); // e5
      await rig.insert(['x', 'y'], index: 0);

      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.snapshot.currentIndex, 6);
      expect(rig.mpv.currentIndex, 6);
      rig.expectInSync();
    });

    test('adding in the middle of a group snaps to after it', () async {
      final rig = await grouped(playing: 4);
      await rig.insert(['x'], index: 3); // between e3 and e4
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'n1', 'e5', 'G2[e6,e7]', 'e8']);
      expect(rig.snapshot.currentEntryId, 'e5');
      rig.expectInSync();
    });

    test('adding nothing changes nothing', () async {
      final rig = await grouped(playing: 2);
      await rig.insert([], afterPlaying: true);
      expect(rig.mpv.commands, isEmpty);
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
    });
  });

  group('when the player does not cooperate', () {
    test('a refused insert leaves the queue as the player has it', () async {
      final rig = await grouped(playing: 0);
      rig.mpv.failInsertNumber(2);

      await expectLater(
        rig.insert(['x', 'y', 'z'], afterPlaying: true),
        throwsA(isA<StateError>()),
      );

      // Only the first one got in; the queue shows exactly that.
      expect(rig.mpv.physicalEntryIds.contains('n1'), isTrue);
      expect(rig.mpv.physicalEntryIds.contains('n2'), isFalse);
      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.queue.validate(), isEmpty);
      expect(rig.snapshot.currentEntryId, 'e1');
    });

    test('the player\'s reports while entries arrive are ignored', () async {
      final rig = await grouped(playing: 2);
      await rig.insert(['x', 'y', 'z'], afterPlaying: true);
      expect(rig.reportsIgnored, rig.reportsSeen); // all were intermediate
      rig.expectInSync();
    });

    test('an insert and a group change never interleave', () async {
      final rig = await grouped(playing: 0);
      final both = Future.wait([
        rig.insert(['x', 'y'], afterPlaying: true),
        rig.run((q) => q.moveGroup('G2', 0)),
        rig.insert(['z']),
      ]);
      await both;
      expect(rig.queue.validate(), isEmpty);
      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.flat.toSet(), hasLength(11));
    });
  });

  group('whatever is added, wherever', () {
    test('random queues, groups, playing entries and batches stay valid',
        () async {
      final random = Random(42);
      for (var round = 0; round < 80; round++) {
        final count = 1 + random.nextInt(9);
        final rig = QueueRig(
          [for (var i = 0; i < count; i++) 't${random.nextInt(4)}'],
          playing: random.nextInt(count),
        );
        // A few groups out of runs of entries.
        var from = 0;
        var next = 0;
        while (from < count) {
          final end = min(count, from + 1 + random.nextInt(3));
          if (random.nextBool()) {
            await rig.run((q) => q.createGroup(
                  groupId: 'G${++next}',
                  title: 'g',
                  entryIds: [for (var i = from; i < end; i++) 'e${i + 1}'],
                ));
          }
          from = end;
        }

        for (var step = 0; step < 4; step++) {
          final before = rig.flat;
          final groupsBefore = {
            for (final g in rig.queue.groups) g.id: [...g.memberIds],
          };
          final playing = rig.snapshot.currentEntryId;
          final batch = [
            for (var i = 0; i < 1 + random.nextInt(3); i++)
              't${random.nextInt(4)}',
          ];
          final added = await rig.insert(
            batch,
            afterPlaying: random.nextBool(),
            index: random.nextBool() ? random.nextInt(before.length + 1) : null,
          );

          final reason = 'round $round step $step';
          expect(rig.queue.validate(), isEmpty, reason: reason);
          rig.expectInSync(reason: reason);
          // The old entries are in the old order, the new ones are loose and
          // next to each other in the order given.
          expect(rig.flat.where((id) => !added.contains(id)), before,
              reason: reason);
          expect([
            for (final id in added) rig.flat.indexOf(id)
          ], [
            for (var i = 0; i < added.length; i++)
              rig.flat.indexOf(added[0]) + i
          ], reason: reason);
          for (final id in added) {
            expect(rig.queue.groupOf(id), isNull, reason: reason);
          }
          // Groups keep exactly their members.
          for (final entry in groupsBefore.entries) {
            expect(rig.queue.groupById(entry.key)!.memberIds, entry.value,
                reason: reason);
          }
          expect(rig.snapshot.currentEntryId, playing, reason: reason);
        }
      }
    });
  });
}
