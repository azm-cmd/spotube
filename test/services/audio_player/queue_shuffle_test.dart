import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_shuffle.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

import 'queue_test_support.dart';

/// Entries e1, e2, ... for [trackIds], with the given groups (group id ->
/// member entry ids) already made.
TestQueue queueOf(
  List<String> trackIds, [
  Map<String, List<String>> groups = const {},
]) {
  var queue = GroupedQueue.ungrouped([
    for (var i = 0; i < trackIds.length; i++)
      QueueEntry('e${i + 1}', TestTrack(trackIds[i])),
  ]);
  groups.forEach((id, members) {
    queue = queue.createGroup(groupId: id, title: id, entryIds: members);
  });
  return queue;
}

/// `e1`, or `G1[e2,e3]` for a group: the top-level rows as text.
List<String> shapeOf(TestQueue queue) => [
      for (final item in queue.items)
        switch (item) {
          EntryItem<TestTrack>(:final entry) => entry.id,
          GroupItem<TestTrack>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ];

List<String> flatOf(TestQueue queue) => [for (final e in queue.entries) e.id];

/// A stand-in for `Random.nextInt` that returns [values] in turn and records
/// the bounds it was asked for.
int Function(int) scripted(List<int> values, [List<int>? bounds]) {
  var next = 0;
  return (bound) {
    bounds?.add(bound);
    return values[next++];
  };
}

void main() {
  group('shuffledOrder', () {
    test('Fisher-Yates with scripted values gives an exact permutation', () {
      final bounds = <int>[];
      expect(shuffledOrder(4, scripted([2, 1, 0], bounds)), [3, 0, 1, 2]);
      expect(bounds, [4, 3, 2]); // never asks for more than the remaining rows
    });

    test('scripted values can also leave the order alone, or reverse it', () {
      expect(shuffledOrder(4, scripted([3, 2, 1])), [0, 1, 2, 3]);
      expect(shuffledOrder(4, scripted([0, 1, 1])), [3, 2, 1, 0]);
      expect(shuffledOrder(5, scripted([1, 3, 0, 1])), [2, 4, 0, 3, 1]);
    });

    test('nothing to shuffle for zero or one row, and no random numbers used',
        () {
      var calls = 0;
      int count(int bound) {
        calls++;
        return 0;
      }

      expect(shuffledOrder(0, count), isEmpty);
      expect(shuffledOrder(1, count), [0]);
      expect(calls, 0);
    });

    test('the same seed always gives the same order', () {
      expect(shuffledOrder(9, Random(5).nextInt),
          shuffledOrder(9, Random(5).nextInt));
    });

    test('every seed gives a permutation', () {
      for (var seed = 0; seed < 200; seed++) {
        final order = shuffledOrder(1 + seed % 15, Random(seed).nextInt);
        expect(order.toSet().length, order.length, reason: 'seed $seed');
        expect([...order]..sort(), [for (var i = 0; i < order.length; i++) i]);
      }
    });

    test('a value outside 0..bound-1 is refused', () {
      expect(() => shuffledOrder(3, scripted([3, 0])), throwsRangeError);
      expect(() => shuffledOrder(3, scripted([-1, 0])), throwsRangeError);
    });
  });

  group('shuffleQueue: groups move as one unit', () {
    test('the example: a group is shuffled as one, members in order', () {
      // A  [G1: B C D]  E  [G2: F G]
      final queue = queueOf([
        'A',
        'B',
        'C',
        'D',
        'E',
        'F',
        'G'
      ], {
        'G1': ['e2', 'e3', 'e4'],
        'G2': ['e6', 'e7'],
      });
      expect(shapeOf(queue), ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]']);

      final shuffled = shuffleQueue(queue, scripted([2, 1, 0]));

      // [G2: F G]  A  [G1: B C D]  E
      expect(shapeOf(shuffled), ['G2[e6,e7]', 'e1', 'G1[e2,e3,e4]', 'e5']);
      expect(flatOf(shuffled), ['e6', 'e7', 'e1', 'e2', 'e3', 'e4', 'e5']);
      expect(shuffled.validate(), isEmpty);
    });

    test('members of a group are never reordered, however it is shuffled', () {
      final queue = queueOf([
        'A',
        'B',
        'C',
        'D'
      ], {
        'G1': ['e1', 'e2', 'e3'],
      });
      expect(shapeOf(queue), ['G1[e1,e2,e3]', 'e4']);

      // two rows: one random number decides whether they swap
      final swapped = shuffleQueue(queue, scripted([0]));
      final kept = shuffleQueue(queue, scripted([1]));

      expect(shapeOf(swapped), ['e4', 'G1[e1,e2,e3]']);
      expect(shapeOf(kept), ['G1[e1,e2,e3]', 'e4']);
      // [G1: D B C]-style results do not exist: the group is one unit
      expect(swapped.groupById('G1')!.memberIds, ['e1', 'e2', 'e3']);
      expect(kept.groupById('G1')!.memberIds, ['e1', 'e2', 'e3']);
    });

    test('all entries ungrouped: an ordinary shuffle of single rows', () {
      final queue = queueOf(['a', 'b', 'c', 'd', 'e']);
      final shuffled = shuffleQueue(queue, scripted([1, 3, 0, 1]));
      expect(flatOf(shuffled), ['e3', 'e5', 'e1', 'e4', 'e2']);
      expect(shuffled.groups, isEmpty);
    });

    test('a queue that is one single group stays that group', () {
      final queue = queueOf([
        'a',
        'b',
        'c'
      ], {
        'G': ['e1', 'e2', 'e3'],
      });
      var asked = 0;
      final shuffled = shuffleQueue(queue, (bound) {
        asked++;
        return 0;
      });
      expect(shapeOf(shuffled), ['G[e1,e2,e3]']);
      expect(asked, 0); // one row: nothing to choose
    });

    test('one group among loose entries', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd',
        'e'
      ], {
        'G': ['e2', 'e3', 'e4'],
      });
      expect(shapeOf(queue), ['e1', 'G[e2,e3,e4]', 'e5']);

      final shuffled = shuffleQueue(queue, scripted([1, 0]));

      expect(shapeOf(shuffled), ['e5', 'e1', 'G[e2,e3,e4]']);
      expect(flatOf(shuffled), ['e5', 'e1', 'e2', 'e3', 'e4']);
    });

    test('several groups, no loose entries', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd',
        'e'
      ], {
        'G1': ['e1', 'e2'],
        'G2': ['e3', 'e4'],
        'G3': ['e5'],
      });
      final shuffled = shuffleQueue(queue, scripted([0, 1]));
      expect(shapeOf(shuffled), ['G3[e5]', 'G2[e3,e4]', 'G1[e1,e2]']);
      expect(shuffled.groups.map((g) => g.id), ['G3', 'G2', 'G1']);
    });

    test('groups separated by loose entries', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd',
        'e',
        'f'
      ], {
        'G1': ['e1', 'e2'],
        'G2': ['e4', 'e5'],
      });
      expect(shapeOf(queue), ['G1[e1,e2]', 'e3', 'G2[e4,e5]', 'e6']);

      final shuffled = shuffleQueue(queue, scripted([0, 1, 1]));

      expect(shapeOf(shuffled), ['e6', 'G2[e4,e5]', 'e3', 'G1[e1,e2]']);
      expect(flatOf(shuffled), ['e6', 'e4', 'e5', 'e3', 'e1', 'e2']);
    });

    test('adjacent groups', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd'
      ], {
        'G1': ['e1', 'e2'],
        'G2': ['e3', 'e4'],
      });
      final shuffled = shuffleQueue(queue, scripted([0]));
      expect(shapeOf(shuffled), ['G2[e3,e4]', 'G1[e1,e2]']);
      expect(shuffled.validate(), isEmpty);
    });

    test('single-entry groups stay groups of one', () {
      final queue = queueOf([
        'a',
        'b',
        'c'
      ], {
        'G1': ['e1'],
        'G2': ['e2'],
      });
      final shuffled = shuffleQueue(queue, scripted([1, 0]));
      expect(shapeOf(shuffled), ['e3', 'G1[e1]', 'G2[e2]']);
      expect(shuffled.groups.every((g) => g.length == 1), isTrue);
    });

    test('duplicate track ids: units are told apart by entry id', () {
      final queue = queueOf([
        'a',
        'a',
        'a',
        'a',
        'a',
        'a'
      ], {
        'G1': ['e2', 'e3'],
        'G2': ['e5', 'e6'],
      });
      expect(shapeOf(queue), ['e1', 'G1[e2,e3]', 'e4', 'G2[e5,e6]']);

      final shuffled = shuffleQueue(queue, scripted([2, 1, 0]));

      expect(shapeOf(shuffled), ['G2[e5,e6]', 'e1', 'G1[e2,e3]', 'e4']);
      // every entry still carries its own identity and its own group
      expect(shuffled.groupOf('e2')!.id, 'G1');
      expect(shuffled.groupOf('e5')!.id, 'G2');
      expect(shuffled.groupOf('e1'), isNull);
      expect(shuffled.groupOf('e4'), isNull);
      expect(flatOf(shuffled).toSet().length, 6);
    });

    test('an empty queue stays empty and asks for no random numbers', () {
      final shuffled = shuffleQueue(
        GroupedQueue.ungrouped(<QueueEntry<TestTrack>>[]),
        (bound) => fail('no random number should be needed'),
      );
      expect(shuffled.entries, isEmpty);
      expect(shuffled.groups, isEmpty);
    });

    test('a one-item queue stays as it is', () {
      final shuffled = shuffleQueue(
        queueOf(['a']),
        (bound) => fail('no random number should be needed'),
      );
      expect(flatOf(shuffled), ['e1']);
    });

    test('the queue it is given is not changed', () {
      final queue = queueOf([
        'a',
        'b',
        'c',
        'd'
      ], {
        'G': ['e2', 'e3'],
      });
      final before = shapeOf(queue);
      shuffleQueue(queue, scripted([1, 0]));
      expect(shapeOf(queue), before);
    });

    test('a queue that already breaks the group rules is refused', () {
      final broken = GroupedQueue(
        queueOf(['a', 'b', 'c']).entries,
        const [
          QueueGroup(id: 'G', title: '', memberIds: ['e1', 'e3'])
        ],
      );
      expect(() => shuffleQueue(broken, scripted([0, 0])),
          throwsA(isA<QueueGroupError>()));
    });

    test('whatever the seed: groups whole, members in order, nothing lost', () {
      for (var seed = 0; seed < 300; seed++) {
        final random = Random(seed);
        final size = random.nextInt(14);
        final tracks = [
          for (var i = 0; i < size; i++) 'a${random.nextInt(3)}',
        ];
        var queue = queueOf(tracks);
        var groupNumber = 0;
        for (var attempt = 0; attempt < 3; attempt++) {
          final loose = queue.ungroupedEntries.map((e) => e.id).toList()
            ..shuffle(random);
          if (loose.isEmpty) break;
          queue = queue.createGroup(
            groupId: 'G${groupNumber++}',
            title: 't',
            entryIds: loose.take(1 + random.nextInt(4)),
          );
        }

        final shuffled = shuffleQueue(queue, Random(seed * 7 + 1).nextInt);

        final reason = 'seed $seed';
        expect(shuffled.validate(), isEmpty, reason: reason);
        // no entry lost or duplicated, none invented
        expect(flatOf(shuffled).toSet(), flatOf(queue).toSet(), reason: reason);
        expect(flatOf(shuffled).length, flatOf(queue).length, reason: reason);
        // every group still there, with exactly the members it had, in order
        expect(shuffled.groups.map((g) => g.id).toSet(),
            queue.groups.map((g) => g.id).toSet(),
            reason: reason);
        for (final group in queue.groups) {
          expect(shuffled.groupById(group.id)!.memberIds, group.memberIds,
              reason: '$reason: ${group.id} changed');
          expect(shuffled.groupById(group.id)!.title, group.title);
        }
        // loose entries are the same set
        expect(shuffled.ungroupedEntries.map((e) => e.id).toSet(),
            queue.ungroupedEntries.map((e) => e.id).toSet(),
            reason: reason);
        // the entries of one group are consecutive and in their original order
        for (final group in shuffled.groups) {
          final at = flatOf(shuffled).indexOf(group.memberIds.first);
          expect(
              flatOf(shuffled).sublist(at, at + group.length), group.memberIds,
              reason: '$reason: ${group.id} is not a block');
        }
      }
    });
  });

  group('unshuffleQueue', () {
    // e1, [G1: e2 e3], e4, [G2: e5 e6]
    TestQueue sample() => queueOf([
          'a',
          'b',
          'c',
          'd',
          'e',
          'f'
        ], {
          'G1': ['e2', 'e3'],
          'G2': ['e5', 'e6'],
        });
    List<String> original(TestQueue q) => flatOf(q);

    test('puts the rows back in their original order', () {
      final queue = sample();
      final shuffled = queue.reorderItems([3, 1, 0, 2]);
      expect(shapeOf(shuffled), ['G2[e5,e6]', 'G1[e2,e3]', 'e1', 'e4']);

      final restored = unshuffleQueue(shuffled, original(queue));

      expect(shapeOf(restored), shapeOf(queue));
      expect(flatOf(restored), original(queue));
    });

    test('shuffle then unshuffle gives back the same queue, for any seed', () {
      for (var seed = 0; seed < 300; seed++) {
        final queue = sample();
        final shuffled = shuffleQueue(queue, Random(seed).nextInt);
        final restored = unshuffleQueue(shuffled, original(queue));
        expect(flatOf(restored), original(queue), reason: 'seed $seed');
        expect(restored.groups, queue.groups, reason: 'seed $seed');
      }
    });

    test('group membership and member order are untouched', () {
      final queue = sample();
      final restored = unshuffleQueue(
          shuffleQueue(queue, scripted([2, 1, 0])), original(queue));
      expect(restored.groupById('G1')!.memberIds, ['e2', 'e3']);
      expect(restored.groupById('G2')!.memberIds, ['e5', 'e6']);
    });

    test('identity is the entry id: copies of one track are restored exactly',
        () {
      final queue = queueOf([
        'a',
        'a',
        'a',
        'a',
        'a',
        'a'
      ], {
        'G1': ['e2', 'e3'],
        'G2': ['e5', 'e6'],
      });
      for (var seed = 0; seed < 50; seed++) {
        final restored = unshuffleQueue(
            shuffleQueue(queue, Random(seed).nextInt), original(queue));
        expect(flatOf(restored), original(queue), reason: 'seed $seed');
      }
    });

    test('entries added after the shuffle follow the known ones', () {
      final queue = sample();
      final shuffled = queue.reorderItems([3, 1, 0, 2]);
      final grown = shuffled.insertUngrouped(
        2, // between the groups, in the middle of the shuffled queue
        [const QueueEntry('e9', TestTrack('new'))],
      );

      final restored = unshuffleQueue(grown, original(queue));

      expect(shapeOf(restored), ['e1', 'G1[e2,e3]', 'e4', 'G2[e5,e6]', 'e9']);
    });

    test('entries removed after the shuffle are simply ignored', () {
      final queue = sample();
      final shuffled = queue.reorderItems([3, 1, 0, 2]).removeEntries(['e4']);
      final restored = unshuffleQueue(shuffled, original(queue));
      expect(shapeOf(restored), ['e1', 'G1[e2,e3]', 'G2[e5,e6]']);
    });

    test('a group made after the shuffle sits where its earliest member was',
        () {
      final plain = queueOf(['a', 'b', 'c', 'd', 'e']);
      // shuffled to e4 e1 e5 e2 e3, then e5 and e2 are grouped
      final shuffled = plain.reorderItems([3, 0, 4, 1, 2]).createGroup(
          groupId: 'G', title: 't', entryIds: ['e5', 'e2']);
      expect(shapeOf(shuffled), ['e4', 'e1', 'G[e5,e2]', 'e3']);

      final restored = unshuffleQueue(shuffled, original(plain));

      // earliest member is e2 (second originally), so G goes second;
      // its own member order is not changed
      expect(shapeOf(restored), ['e1', 'G[e5,e2]', 'e3', 'e4']);
    });

    test('with nothing remembered the order is left alone', () {
      final shuffled = sample().reorderItems([3, 1, 0, 2]);
      final restored = unshuffleQueue(shuffled, const []);
      expect(shapeOf(restored), shapeOf(shuffled));
    });

    test('an empty queue, and a one-item queue', () {
      expect(
        unshuffleQueue(
            GroupedQueue.ungrouped(<QueueEntry<TestTrack>>[]), ['e1']).entries,
        isEmpty,
      );
      expect(flatOf(unshuffleQueue(queueOf(['a']), ['e1'])), ['e1']);
    });
  });

  group('QueueShuffler: which engine does the work', () {
    late QueueRig rig;
    late FakeShufflePort port;
    late QueueShuffler<TestTrack> shuffler;
    var script = <int>[];

    void setUpFor(QueueRig queueRig) {
      rig = queueRig;
      port = FakeShufflePort(rig.mpv);
      var next = 0;
      shuffler = QueueShuffler(
        sync: rig.sync,
        port: port,
        nextInt: (bound) => script[next++ % script.length],
      );
    }

    Future<bool> shuffle(bool on) => shuffler.setShuffle(
          on,
          read: () => rig.snapshot,
          commit: (confirmed) => rig.snapshot = confirmed,
        );

    // e1, [G1: e2 e3 e4], e5, [G2: e6 e7], e8 (e1 playing unless told)
    Future<void> withGroups({int playing = 0}) async {
      setUpFor(await mixedRig(playing: playing));
      script = [0, 1, 2, 1]; // reverses the five rows
    }

    // Distinct tracks, so a player-side shuffle can be followed exactly.
    void withoutGroups() {
      setUpFor(QueueRig(['a', 'b', 'c', 'd', 'e', 'f']));
      script = [0, 1, 2, 1];
    }

    group('a queue with groups', () {
      test('is shuffled in Dart and never by mpv', () async {
        await withGroups();
        final changed = await shuffle(true);

        expect(changed, isTrue);
        expect(port.flatCalls, isEmpty); // mpv's own shuffle was never called
        expect(rig.shape, ['e8', 'G2[e6,e7]', 'e5', 'G1[e2,e3,e4]', 'e1']);
        expect(rig.flat, ['e8', 'e6', 'e7', 'e5', 'e2', 'e3', 'e4', 'e1']);
        rig.expectInSync();
      });

      test('reports itself as shuffled, whatever mpv\'s flag says', () async {
        await withGroups();
        await shuffle(true);
        expect(port.isShuffled, isTrue);
        expect(port.isFlatShuffled, isFalse);
        expect(port.published, [true]);
      });

      test('groups stay whole and in order through the player', () async {
        await withGroups();
        await shuffle(true);
        expect(rig.queue.groupById('G1')!.memberIds, ['e2', 'e3', 'e4']);
        expect(rig.queue.groupById('G2')!.memberIds, ['e6', 'e7']);
        expect(rig.mpv.physicalEntryIds.sublist(4, 7), ['e2', 'e3', 'e4']);
        rig.expectInSync();
      });

      test('turning it off restores the order from before', () async {
        await withGroups();
        await shuffle(true);
        final changed = await shuffle(false);

        expect(changed, isTrue);
        expect(port.flatCalls, isEmpty);
        expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
        expect(port.isShuffled, isFalse);
        expect(port.reported, isNull); // handed back to mpv: it agrees (off)
        rig.expectInSync();
      });

      test('asking for the state it is already in does nothing', () async {
        await withGroups();
        await shuffle(true);
        rig.mpv.commands.clear();

        expect(await shuffle(true), isFalse);
        expect(rig.mpv.commands, isEmpty);

        await shuffle(false);
        rig.mpv.commands.clear();
        expect(await shuffle(false), isFalse);
        expect(rig.mpv.commands, isEmpty);
        expect(port.flatCalls, isEmpty);
      });

      test('the playing entry inside a group keeps playing', () async {
        await withGroups(playing: 2); // e3, in G1
        await shuffle(true);

        expect(rig.snapshot.currentEntryId, 'e3');
        expect(rig.mpv.playing!.entryId, 'e3');
        expect(rig.snapshot.currentIndex, 5);
        rig.expectInSync();

        await shuffle(false);
        expect(rig.snapshot.currentEntryId, 'e3');
        expect(rig.snapshot.currentIndex, 2);
        rig.expectInSync();
      });

      test('the playing loose entry keeps playing', () async {
        await withGroups(playing: 4); // e5, loose
        await shuffle(true);

        expect(rig.snapshot.currentEntryId, 'e5');
        expect(rig.mpv.playing!.entryId, 'e5');
        expect(rig.snapshot.currentIndex, 3);
        rig.expectInSync();
      });

      test('copies of one track stay separate through shuffle and back',
          () async {
        await withGroups(); // the track ids repeat: a at e1/e3/e5, b at e2/e7
        await shuffle(true);
        expect(rig.mpv.physicalEntryIds, rig.flat); // the same physical entries
        await shuffle(false);
        expect(rig.mpv.physicalEntryIds,
            ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8']);
        rig.expectInSync();
      });

      test('a failed shuffle leaves the state unchanged', () async {
        await withGroups();
        rig.mpv.failMoveNumber(1);

        await expectLater(shuffle(true), throwsStateError);

        expect(port.published, isEmpty);
        expect(port.isShuffled, isFalse);
        expect(port.flatCalls, isEmpty);
        // and nothing is "remembered": turning it off now has nothing to do
        rig.mpv.stopFailing();
        expect(await shuffle(false), isFalse);
      });
    });

    group('a queue without groups', () {
      test('is shuffled by mpv, exactly as before', () async {
        withoutGroups();
        final changed = await shuffle(true);

        expect(changed, isFalse); // nothing for the app to save: mpv reports
        expect(port.flatCalls, [true]);
        expect(port.published, isEmpty);
        expect(port.isShuffled, isTrue);
        rig.expectInSync();
      });

      test('and unshuffled by mpv', () async {
        withoutGroups();
        await shuffle(true);
        await shuffle(false);

        expect(port.flatCalls, [true, false]);
        expect(rig.flat, ['e1', 'e2', 'e3', 'e4', 'e5', 'e6']);
        rig.expectInSync();
      });

      test('"on" while already on is left to mpv, as before', () async {
        withoutGroups();
        await shuffle(true);
        expect(await shuffle(true), isFalse);
        expect(port.flatCalls, [true]); // not even asked a second time
      });

      test('nothing is done in Dart', () async {
        withoutGroups();
        rig.mpv.commands.clear();
        await shuffle(true);
        expect(rig.mpv.commands, isEmpty); // no playlist-move from the app
      });
    });

    group('moving between the two', () {
      test('groups dissolved after a Dart shuffle: off still restores',
          () async {
        await withGroups();
        await shuffle(true);
        await rig.run((q) => q.ungroup('G1'));
        await rig.run((q) => q.ungroup('G2'));
        expect(rig.queue.groups, isEmpty);

        final changed = await shuffle(false);

        expect(changed, isTrue);
        expect(port.flatCalls, isEmpty); // still not mpv's job
        expect(rig.flat, ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8']);
        rig.expectInSync();
      });

      test('groups made after a flat shuffle are not torn apart by "off"',
          () async {
        withoutGroups();
        await shuffle(true); // mpv shuffles: e6 e5 e4 e3 e2 e1
        await rig.run((q) =>
            q.createGroup(groupId: 'G', title: 't', entryIds: ['e6', 'e5']));
        final groupedFlat = rig.flat;

        await shuffle(false);

        expect(port.flatCalls, [true]); // mpv's unshuffle was NOT called
        expect(rig.queue.groupById('G'), isNotNull);
        expect(rig.flat, groupedFlat);
        expect(port.isShuffled, isFalse);
        rig.expectInSync();
      });

      test('mpv\'s stale flag is cleared before "on" shuffles again', () async {
        withoutGroups();
        await shuffle(true);
        await rig.run((q) =>
            q.createGroup(groupId: 'G', title: 't', entryIds: ['e6', 'e5']));
        await shuffle(false); // handled in Dart; mpv's flag is still on
        expect(port.isFlatShuffled, isTrue);
        expect(port.isShuffled, isFalse);
        await rig.run((q) => q.ungroup('G'));

        await shuffle(true); // no groups: mpv's job again

        // mpv ignores "on" while its flag is on, so the flag was cleared first
        expect(port.flatCalls, [true, false, true]);
        expect(port.isShuffled, isTrue);
        rig.expectInSync();
      });

      test('reset (a new queue) forgets the Dart shuffle', () async {
        await withGroups();
        await shuffle(true);
        expect(port.reported, isTrue);

        shuffler.reset();

        expect(port.reported, isNull);
        expect(port.isShuffled, port.isFlatShuffled);
      });
    });

    test('randomized: mpv\'s flat shuffle is never called while groups exist',
        () async {
      final random = Random(2024);
      setUpFor(QueueRig(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'],
          playing: 4));
      shuffler = QueueShuffler(
        sync: rig.sync,
        port: port,
        nextInt: random.nextInt,
      );

      final flatCallsWhileGrouped = <String>[];
      var calls = 0;
      var group = 0;

      for (var step = 0; step < 300; step++) {
        final groupsBefore = rig.queue.groups.length;
        final callsBefore = port.flatCalls.length;
        final loose = rig.queue.ungroupedEntries.map((e) => e.id).toList()
          ..shuffle(random);
        final groupIds = rig.queue.groups.map((g) => g.id).toList();

        switch (random.nextInt(7)) {
          case 0 when loose.length >= 2:
            await rig.run((q) => q.createGroup(
                groupId: 'G${group++}',
                title: 't',
                entryIds:
                    loose.take(2 + random.nextInt(min(2, loose.length - 1)))));
          case 1 when groupIds.isNotEmpty:
            await rig.run(
                (q) => q.ungroup(groupIds[random.nextInt(groupIds.length)]));
          case 2 when groupIds.isNotEmpty:
            await rig.run((q) => q.moveGroup(
                groupIds[random.nextInt(groupIds.length)],
                random.nextInt(rig.queue.items.length + 1)));
          case 3 when rig.flat.length > 5:
            await rig.run((q) =>
                q.removeEntries([rig.flat[random.nextInt(rig.flat.length)]]));
          case 4:
            await shuffle(true);
          case 5:
            await shuffle(false);
          default:
            continue;
        }
        calls++;

        // every flat call must have been made on a queue with no groups
        if (port.flatCalls.length > callsBefore && groupsBefore > 0) {
          flatCallsWhileGrouped.add('step $step');
        }
        final reason = 'step $step';
        rig.expectInSync(reason: reason);
        expect(rig.flat.toSet().length, rig.flat.length, reason: reason);
      }

      expect(calls, greaterThan(100));
      expect(flatCallsWhileGrouped, isEmpty);
    });
  });
}
