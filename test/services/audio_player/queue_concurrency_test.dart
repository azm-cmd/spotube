import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_shuffle.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

import 'queue_test_support.dart';

/// Every change to the queue's order waits for the ones asked for before it.
/// Here changes are asked for back to back, without waiting, while the fake
/// player is slow, and the result must be exactly what the same changes give
/// one after the other.

typedef Change = Future<void> Function(QueueRig rig);

/// A rig for `a b a c a d b e` with groups One[b a c] ... see [mixedRig]:
/// e1 [G1: e2 e3 e4] e5 [G2: e6 e7] e8, e1 playing. Tracks repeat (a, b), so
/// copies of a track are in and out of the groups.
Future<QueueRig> freshRig([int playing = 0]) => mixedRig(playing: playing);

/// A flat move written in positions of the queue as it first is (`e1`..`e8`),
/// the way the UI sees it when it asks: it names the entries now, and moves
/// them when its turn comes, whatever the queue looks like by then.
Change moveFrom(int from, int to) {
  final movedId = 'e${from + 1}';
  final beforeId = to >= 8 ? null : 'e${to + 1}';
  return (r) => r.moveBefore(movedId, beforeId);
}

/// Makes every command of the player take a few turns of the event loop.
void slowPlayer(QueueRig rig, [int turns = 3]) {
  rig.mpv.gate = (_) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  };
}

/// What the app shows, as one comparable thing.
String describe(QueueRig rig) =>
    '${rig.shape.join(' ')} | playing ${rig.snapshot.currentEntryId}';

/// Runs [changes] one after the other on a fresh rig, and returns it.
Future<QueueRig> runOneByOne(
  List<Change> changes, {
  int playing = 0,
  Future<QueueRig> Function(int playing)? make,
}) async {
  final rig = await (make ?? freshRig)(playing);
  for (final change in changes) {
    try {
      await change(rig);
    } catch (_) {}
  }
  return rig;
}

/// Starts all of [changes] without waiting, with a slow player.
Future<QueueRig> runBackToBack(
  List<Change> changes, {
  int playing = 0,
  int turns = 3,
  Future<QueueRig> Function(int playing)? make,
}) async {
  final rig = await (make ?? freshRig)(playing);
  slowPlayer(rig, turns);
  final all = [
    for (final change in changes)
      change(rig).then<void>((_) {}, onError: (_) {}),
  ];
  await Future.wait(all);
  return rig;
}

/// The invariant after any run: app, groups and player agree.
void expectConsistent(QueueRig rig, {String? reason}) {
  rig.expectInSync(reason: reason);
  expect(rig.flat.toSet(), hasLength(rig.flat.length), reason: reason);
}

Future<void> expectSameAsOneByOne(
  List<Change> changes, {
  int playing = 0,
  Future<QueueRig> Function(int playing)? make,
  String? reason,
}) async {
  final expected = await runOneByOne(changes, playing: playing, make: make);
  for (final turns in [0, 1, 4]) {
    final actual = await runBackToBack(
      changes,
      playing: playing,
      turns: turns,
      make: make,
    );
    expect(describe(actual), describe(expected),
        reason: '${reason ?? ''} (player takes $turns turns per command)');
    expect(actual.flat, expected.flat, reason: reason);
    expectConsistent(actual, reason: reason);
  }
}

void main() {
  group('a change waits for the ones before it', () {
    test('insert, then move: the move still moves the entries it was given',
        () async {
      // move(0 -> 4) is asked for right after an insert at the front: it is
      // about e1 and the entry that was at 4 (e5), not about positions.
      await expectSameAsOneByOne([
        (r) => r.insert(['x', 'y'], index: 0),
        moveFrom(0, 4),
      ]);

      final rig = await runBackToBack([
        (r) => r.insert(['x', 'y'], index: 0),
        moveFrom(0, 4),
      ]);
      // e1 moved to just before e5, whatever the insert did.
      final flat = rig.flat;
      expect(flat.indexOf('e1'), flat.indexOf('e5') - 1);
    });

    test('insert, then remove', () async {
      await expectSameAsOneByOne([
        (r) => r.insert(['x'], afterPlaying: true),
        (r) => r.run((q) => q.removeEntries(['e2', 'e5'])),
      ]);
    });

    test('remove, then insert', () async {
      await expectSameAsOneByOne([
        (r) => r.run((q) => q.removeEntries(['e2', 'e3'])),
        (r) => r.insert(['x', 'y'], afterPlaying: true),
      ], playing: 3);
    });

    test('group move, then play next', () async {
      await expectSameAsOneByOne([
        (r) => r.run((q) => q.moveGroup('G2', 0)),
        (r) => r.insert(['x'], afterPlaying: true),
      ], playing: 1);
    });

    test('play next, then group move', () async {
      await expectSameAsOneByOne([
        (r) => r.insert(['x'], afterPlaying: true),
        (r) => r.run((q) => q.moveGroup('G1', 5)),
      ], playing: 2);
    });

    test('member reorder, then play next', () async {
      await expectSameAsOneByOne([
        (r) => r.run((q) => q.moveWithinGroup('G1', 0, 3)),
        (r) => r.insert(['x', 'y'], afterPlaying: true),
      ], playing: 2);
    });

    test('add to queue and play next, back to back', () async {
      await expectSameAsOneByOne([
        (r) => r.insert(['x']),
        (r) => r.insert(['y'], afterPlaying: true),
        (r) => r.insert(['z']),
      ], playing: 3);
    });

    test('five different changes, back to back', () async {
      await expectSameAsOneByOne([
        (r) => r.insert(['x', 'y'], afterPlaying: true),
        moveFrom(7, 1),
        (r) => r.run((q) => q.moveGroup('G2', 1)),
        (r) => r.run((q) => q.removeEntries(['e8'])),
        (r) => r.run((q) => q.moveWithinGroup('G1', 2, 0)),
      ], playing: 4);
    });

    test('a change that fails does not stop the ones after it', () async {
      final rig = await runBackToBack([
        (r) => r.run((q) => q.moveGroup('missing', 0)),
        (r) => r.insert(['x'], afterPlaying: true),
        (r) => r.run((q) => q.renameGroup('G1', 'Still works')),
      ]);
      expect(rig.queue.groupById('G1')!.title, 'Still works');
      expect(rig.flat, contains('n1'));
      expectConsistent(rig);
    });

    test('a jump waits for the insert before it and lands on the right entry',
        () async {
      final changes = <Change>[
        (r) => r.insert(['x', 'y'], index: 0),
        (r) => r.jumpToEntry('e5'),
      ];
      await expectSameAsOneByOne(changes);
      final rig = await runBackToBack(changes);
      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.mpv.playing!.entryId, 'e5');
    });
  });

  group('the playing position', () {
    test('a jump is not undone by the change after it', () async {
      final rig = await freshRig(0);
      rig.mpv.delayedPlayingReports = true;
      slowPlayer(rig, 1);

      await Future.wait([
        rig.jumpToEntry('e5'),
        rig.insert(['x'], afterPlaying: true), // after e5, the entry jumped to
        rig.run((q) => q.moveGroup('G1', 5)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.mpv.playing!.entryId, 'e5');
      expect(rig.snapshot.currentIndex, rig.mpv.currentIndex);
      expect(rig.flat.indexOf('n1'), rig.flat.indexOf('e5') + 1);
      expectConsistent(rig);
    });

    test('a jump followed by a removal keeps the entry jumped to', () async {
      final rig = await freshRig(0);
      rig.mpv.delayedPlayingReports = true;
      await Future.wait([
        rig.jumpToEntry('e5'),
        rig.run((q) => q.removeEntries(['e1', 'e2'])),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.snapshot.currentIndex, rig.mpv.currentIndex);
      expectConsistent(rig);
    });
  });

  group('copies of a track', () {
    // All eight entries are the same track.
    Future<QueueRig> same(int playing) async {
      final rig = QueueRig(List.filled(8, 'a'), playing: playing);
      await rig.run((q) =>
          q.createGroup(groupId: 'G1', title: 'one', entryIds: ['e2', 'e3']));
      await rig.run((q) =>
          q.createGroup(groupId: 'G2', title: 'two', entryIds: ['e5', 'e6']));
      return rig;
    }

    test('insert, move, remove and group changes act on the right copies',
        () async {
      final changes = <Change>[
        (r) => r.insert(['a', 'a'], afterPlaying: true),
        moveFrom(0, 6),
        (r) => r.run((q) => q.removeEntries(['e3', 'e7'])),
        (r) => r.run((q) => q.moveGroup('G2', 0)),
        (r) => r.insert(['a']),
      ];
      await expectSameAsOneByOne(changes, playing: 3, make: same);

      final rig = await runBackToBack(changes, playing: 3, make: same);
      // Nothing was found by track id: every entry is accounted for.
      expect(rig.flat.toSet(), hasLength(rig.flat.length));
      expect(rig.flat, isNot(contains('e3')));
      expect(rig.flat, isNot(contains('e7')));
      expect(rig.queue.groupById('G1')!.memberIds, ['e2']);
    });

    test('the playing copy stays the playing one', () async {
      final rig = await runBackToBack([
        (r) => r.insert(['a'], afterPlaying: true),
        (r) => r.run((q) => q.moveGroup('G1', 5)),
        moveFrom(0, 7),
        (r) => r.insert(['a', 'a']),
      ], playing: 3, make: same);
      expect(rig.snapshot.currentEntryId, 'e4');
      expect(rig.mpv.playing!.entryId, 'e4');
      expect(rig.snapshot.currentIndex, rig.mpv.currentIndex);
    });
  });

  group('the player\'s own reports', () {
    test('never replace the order the app asked for', () async {
      final rig = await freshRig(2);
      slowPlayer(rig, 2);

      final change = rig.run((q) => q.moveGroup('G2', 0));
      final insert = rig.insert(['x', 'y'], afterPlaying: true);
      await Future.wait([change, insert]);

      // The player reported after every command; none of those half-way
      // orders was ever shown as the app's queue.
      expect(rig.mpv.commands, isNotEmpty);
      expect(rig.reportsSeen, greaterThan(3));
      final shown = rig.history.map((h) => h.join(',')).toSet();
      final sequential = await runOneByOne([
        (r) => r.run((q) => q.moveGroup('G2', 0)),
        (r) => r.insert(['x', 'y'], afterPlaying: true),
      ], playing: 2);
      expect(rig.flat, sequential.flat);
      // Every queue that was shown is the queue before, between or after the
      // two changes (or one report of the final one).
      final before = (await freshRig(2)).flat.join(',');
      final between = (await runOneByOne(
              [(r) => r.run((q) => q.moveGroup('G2', 0))],
              playing: 2))
          .flat
          .join(',');
      final after = sequential.flat.join(',');
      for (final queue in shown) {
        expect([before, between, after], contains(queue),
            reason: 'a half-way order was shown: $queue');
      }
    });

    test('a report in the middle of a reorder changes nothing', () async {
      final rig = await freshRig(0);
      final before = rig.flat;
      var reported = 0;
      rig.mpv.gate = (command) async {
        if (command.startsWith('move')) {
          reported++;
          // The player reports a different order while the app is sending
          // its moves.
          rig.deliverReport();
        }
      };

      await rig.run((q) => q.moveGroup('G2', 0));

      expect(reported, greaterThan(0));
      expect(rig.history.where((h) => h.join() == before.join()), isNotEmpty);
      expectConsistent(rig);
      expect(rig.shape.first, startsWith('G2'));
    });

    test('an insert in flight is not undone by a report of the old queue',
        () async {
      final rig = await freshRig(0);
      rig.mpv.gate = (command) async {
        // Before the player has the entry, it reports its old playlist.
        rig.deliverReport();
        await Future<void>.delayed(Duration.zero);
      };
      await rig.insert(['x', 'y'], afterPlaying: true);
      expect(rig.flat.take(3), ['e1', 'n1', 'n2']);
      expectConsistent(rig);
    });
  });

  group('when the player refuses a command', () {
    test('a removal leaves the app showing what the player has', () async {
      final rig = await freshRig(0);
      rig.mpv.failRemoveNumber(2);

      await expectLater(
        rig.run((q) => q.removeEntries(['e2', 'e3', 'e4'])),
        throwsA(isA<StateError>()),
      );

      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.queue.validate(), isEmpty);
      expect(rig.snapshot.currentEntryId, 'e1');
    });

    test('the changes after a refused one still run', () async {
      final rig = await freshRig(0);
      rig.mpv.failRemoveNumber(1);
      final results = await Future.wait([
        rig
            .run((q) => q.removeEntries(['e8']))
            .then((_) => 'ok', onError: (_) => 'refused'),
        rig.insert(['x'], afterPlaying: true).then((_) => 'ok',
            onError: (_) => 'refused'),
      ]);
      expect(results, ['refused', 'ok']);
      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.flat, contains('n1'));
      expectConsistent(rig);
    });
  });

  group('shuffle and insert', () {
    /// A shuffler for the rig, with a fixed shuffle: the rows rotate by one.
    ({QueueShuffler<TestTrack> shuffler, FakeShufflePort port}) shufflerFor(
        QueueRig rig) {
      final port = FakeShufflePort(rig.mpv);
      return (
        shuffler: QueueShuffler<TestTrack>(
          sync: rig.sync,
          port: port,
          nextInt: (bound) => 0,
        ),
        port: port,
      );
    }

    Future<void> shuffle(
      QueueRig rig,
      QueueShuffler<TestTrack> shuffler,
      bool on,
    ) =>
        shuffler.setShuffle(
          on,
          read: () => rig.snapshot,
          commit: (confirmed) => rig.snapshot = confirmed,
        );

    test('play next asked for during a shuffle waits and lands after it',
        () async {
      final one = await freshRig(0);
      final a = shufflerFor(one);
      await shuffle(one, a.shuffler, true);
      await one.insert(['x'], afterPlaying: true);

      final two = await freshRig(0);
      slowPlayer(two);
      final b = shufflerFor(two);
      await Future.wait([
        shuffle(two, b.shuffler, true),
        two.insert(['x'], afterPlaying: true),
      ]);

      expect(describe(two), describe(one));
      expectConsistent(two);
      expect(b.port.flatCalls, isEmpty); // never mpv's own shuffle
    });

    test('a shuffle asked for during an insert waits for it', () async {
      final one = await freshRig(2);
      await one.insert(['x', 'y'], afterPlaying: true);
      await shuffle(one, shufflerFor(one).shuffler, true);

      final two = await freshRig(2);
      slowPlayer(two);
      final s = shufflerFor(two);
      await Future.wait([
        two.insert(['x', 'y'], afterPlaying: true),
        shuffle(two, s.shuffler, true),
      ]);

      expect(describe(two), describe(one));
      expectConsistent(two);
    });

    test('unshuffle, insert and a move, back to back', () async {
      final make = (int playing) async {
        final rig = await freshRig(playing);
        final s = shufflerFor(rig);
        await shuffle(rig, s.shuffler, true);
        return rig;
      };
      // Same sequence both ways; the shuffler of each rig is its own.
      Future<QueueRig> go({required bool together}) async {
        final rig = await make(0);
        final s = shufflerFor(rig);
        // The rig's shuffler remembers nothing; ask it to restore the order
        // from before the shuffle (unshuffle needs it).
        s.shuffler.restoreNow(rig.flat.reversed.toList());
        final steps = <Future<void> Function()>[
          () => shuffle(rig, s.shuffler, false),
          () => rig.insert(['x'], afterPlaying: true),
          () => moveFrom(0, 3)(rig),
        ];
        if (together) {
          slowPlayer(rig, 2);
          await Future.wait([for (final step in steps) step()]);
        } else {
          for (final step in steps) {
            await step();
          }
        }
        return rig;
      }

      final one = await go(together: false);
      final two = await go(together: true);
      expect(describe(two), describe(one));
      expectConsistent(two);
    });

    test('groups stay whole through shuffle, insert, move and unshuffle',
        () async {
      final rig = await freshRig(2);
      slowPlayer(rig, 2);
      final s = shufflerFor(rig);
      await Future.wait([
        shuffle(rig, s.shuffler, true),
        rig.insert(['x', 'y'], afterPlaying: true),
        moveFrom(0, 1)(rig),
        shuffle(rig, s.shuffler, false),
        rig.insert(['z']),
      ]);
      expect(rig.queue.validate(), isEmpty);
      expectConsistent(rig);
      expect(s.port.flatCalls, isEmpty);
    });
  });

  group('swapping the source of the playing track', () {
    test('keeps the entry, its place and its group', () async {
      final rig = await freshRig(2); // e3, in G1
      final before = rig.flat;
      final groups = rig.queue.groups;

      await rig.swapActive();

      expect(rig.flat, before);
      expect(rig.queue.groups, groups);
      expect(rig.snapshot.currentEntryId, 'e3');
      expect(rig.snapshot.currentIndex, 2);
      expect(rig.mpv.playing!.entryId, 'e3');
      expectConsistent(rig);
    });

    test('sends the same commands as before: insert after, skip, remove',
        () async {
      final rig = await freshRig(2);
      rig.mpv.commands.clear();
      await rig.swapActive();
      expect(rig.mpv.commands, ['insert 3', 'remove 2']);
    });

    test('the player\'s intermediate reports are ignored', () async {
      final rig = await freshRig(2);
      slowPlayer(rig);
      await rig.swapActive();
      expect(rig.reportsSeen, greaterThan(0));
      expect(rig.reportsIgnored, rig.reportsSeen);
    });

    test('can not corrupt the queue when changes are asked for around it',
        () async {
      await expectSameAsOneByOne([
        (r) => r.insert(['x'], afterPlaying: true),
        (r) => r.swapActive(),
        (r) => r.run((q) => q.moveGroup('G2', 0)),
        (r) => r.swapActive(),
        (r) => r.run((q) => q.removeEntries(['e8'])),
        moveFrom(0, 5),
        (r) => r.swapActive(),
      ], playing: 3);
    });

    test('with copies of the playing track around, the playing copy is swapped',
        () async {
      Future<QueueRig> same(int playing) async {
        final rig = QueueRig(List.filled(6, 'a'), playing: playing);
        await rig.run((q) =>
            q.createGroup(groupId: 'G', title: 'g', entryIds: ['e3', 'e4']));
        return rig;
      }

      final rig = await runBackToBack([
        (r) => r.insert(['a'], afterPlaying: true),
        (r) => r.swapActive(),
        moveFrom(5, 0),
      ], playing: 3, make: same);
      expect(rig.snapshot.currentEntryId, 'e4');
      expect(rig.mpv.playing!.entryId, 'e4');
      expectConsistent(rig);
    });

    test('if the player plays another entry afterwards, the app follows it',
        () async {
      final rig = await freshRig(1); // e2
      await rig.sync.exclusive(() async {
        await rig.sync.swapInPlace(
          rig.snapshot,
          // The player moves on to the next entry instead of staying put.
          swap: (playingIndex) async => rig.mpv.jump(playingIndex + 1),
          commit: (confirmed) => rig.snapshot = confirmed,
        );
      });
      expect(rig.snapshot.currentEntryId, 'e3');
      expect(rig.snapshot.currentIndex, rig.mpv.currentIndex);
      expectConsistent(rig);
    });

    test('a refused command leaves the app showing what the player has',
        () async {
      final rig = await freshRig(1);
      rig.mpv.failInsertNumber(1);
      await expectLater(rig.swapActive(), throwsA(isA<StateError>()));
      expect(rig.queue.validate(), isEmpty);
      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.snapshot.currentEntryId, 'e2');
    });
  });

  group('whatever is asked for, in whatever order', () {
    Change randomChange(Random random, QueueRig rig, int step) {
      // Pick from what the app shows now, the way the UI does; by the time the
      // change runs, earlier ones may have made it stale.
      final queue = rig.queue;
      final ids = queue.entries.map((e) => e.id).toList();
      final groups = queue.groups.map((g) => g.id).toList();
      String? anyId() => ids.isEmpty ? null : ids[random.nextInt(ids.length)];

      switch (random.nextInt(11)) {
        case 0:
          final batch = [
            for (var i = 0; i < 1 + random.nextInt(3); i++)
              't${random.nextInt(3)}',
          ];
          return (r) => r.insert(batch, afterPlaying: true);
        case 1:
          final track = 't${random.nextInt(3)}';
          return (r) => r.insert([track]);
        case 2:
          final from = ids.isEmpty ? 0 : random.nextInt(ids.length);
          final to = ids.isEmpty ? 0 : random.nextInt(ids.length + 1);
          return moveFrom(from, to);
        case 3:
          final victim = anyId();
          return (r) =>
              r.run((q) => q.removeEntries([if (victim != null) victim]));
        case 4:
          if (groups.isEmpty) return (r) => r.insert(['t0']);
          final g = groups[random.nextInt(groups.length)];
          final to = random.nextInt(queue.items.length + 1);
          return (r) => r.run((q) => q.moveGroup(g, to));
        case 5:
          if (groups.isEmpty) return (r) => r.insert(['t1']);
          final g = groups[random.nextInt(groups.length)];
          final size = queue.groupById(g)!.length;
          final from = random.nextInt(size);
          final to = random.nextInt(size + 1);
          return (r) => r.run((q) => q.moveWithinGroup(g, from, to));
        case 6:
          if (groups.isEmpty) return (r) => r.insert(['t2']);
          final g = groups[random.nextInt(groups.length)];
          return (r) => r.run((q) => q.ungroup(g));
        case 7:
          final pick = anyId();
          return (r) =>
              pick == null ? Future<void>.value() : r.jumpToEntry(pick);
        case 8:
          return (r) => r.swapActive();
        case 9:
          if (groups.isEmpty) return (r) => r.insert(['t0']);
          final g = groups[random.nextInt(groups.length)];
          final collapsed = random.nextBool();
          return (r) => r.run((q) => q.setCollapsed(g, collapsed));
        default:
          final a = anyId(), b = anyId();
          return (r) => r.run((q) => q.createGroup(
                groupId: 'N$step',
                title: 'new',
                entryIds: [if (a != null) a, if (b != null && b != a) b],
              ));
      }
    }

    test('random changes back to back give what they give one by one',
        () async {
      for (var seed = 0; seed < 60; seed++) {
        final random = Random(seed);
        final count = 2 + random.nextInt(6);
        // Both runs are built from the same plan; changes are planned on a
        // rig that is only used to read what is on screen.
        final planner = await freshRig(random.nextInt(8));
        final changes = [
          for (var step = 0; step < count; step++)
            randomChange(random, planner, step),
        ];
        final playing = random.nextInt(8);

        final expected = await runOneByOne(changes, playing: playing);
        final actual = await runBackToBack(
          changes,
          playing: playing,
          turns: random.nextInt(4),
        );

        final reason = 'seed $seed';
        expect(describe(actual), describe(expected), reason: reason);
        expect(actual.flat, expected.flat, reason: reason);
        expect(actual.queue.validate(), isEmpty, reason: reason);
        expectConsistent(actual, reason: reason);
      }
    });
  });
}
