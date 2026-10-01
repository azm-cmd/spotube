import 'dart:math';

import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:test/test.dart';

typedef Q = GroupedQueue<String>;

/// Entries e1.. for [tracks]; [groups] maps group id -> member entry ids, and
/// the ids in [expanded] are not collapsed.
Q queueOf(
  List<String> tracks, {
  Map<String, List<String>> groups = const {},
  Set<String> expanded = const {},
}) {
  var queue = GroupedQueue.ungrouped([
    for (var i = 0; i < tracks.length; i++) QueueEntry('e${i + 1}', tracks[i]),
  ]);
  groups.forEach((id, members) {
    queue = queue.createGroup(
      groupId: id,
      title: 'Title $id',
      entryIds: members,
      collapsed: !expanded.contains(id),
    );
  });
  return queue;
}

/// 'e1', 'G1', 'G1:e2' ... for the rows.
List<String> describe(List<QueueRow<String>> rows) => [
      for (final row in rows)
        switch (row) {
          QueueGroupRow<String>(:final group) => group.id,
          QueueEntryRow<String>(:final entry, :final groupId) =>
            groupId == null ? entry.id : '$groupId:${entry.id}',
        },
    ];

List<QueueRow<String>> rowsOf(Q queue, {int current = 0}) =>
    buildQueueRows(queue, currentIndex: current);

/// The queue after a drag, done the way the notifier does it.
Q drag(Q queue, QueueMove move) => switch (move) {
      MoveQueueItem(:final from, :final to) => queue.moveItem(from, to),
      MoveGroup(:final groupId, :final to) => queue.moveGroup(groupId, to),
      MoveWithinGroup(:final groupId, :final from, :final to) =>
        queue.moveWithinGroup(groupId, from, to),
    };

String shape(Q queue) => [
      for (final item in queue.items)
        switch (item) {
          EntryItem<String>(:final entry) => entry.id,
          GroupItem<String>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ].join(' ');

void main() {
  // e1 [G1: e2 e3] e4 [G2: e5 e6 e7] e8
  final mixed = queueOf(
    ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
    groups: {
      'G1': ['e2', 'e3'],
      'G2': ['e5', 'e6', 'e7'],
    },
  );

  group('buildQueueRows', () {
    test('a queue without groups is one row per entry', () {
      final rows = rowsOf(queueOf(['a', 'b', 'c']), current: 1);

      expect(describe(rows), ['e1', 'e2', 'e3']);
      expect(rows.map((r) => r.itemIndex), [0, 1, 2]);
      expect(
        rows.cast<QueueEntryRow<String>>().map((r) => r.isPlaying),
        [false, true, false],
      );
      expect(
        rows.cast<QueueEntryRow<String>>().map((r) => r.flatIndex),
        [0, 1, 2],
      );
    });

    test('an empty queue has no rows', () {
      expect(rowsOf(queueOf([])), isEmpty);
    });

    test('a collapsed group is its header alone', () {
      expect(describe(rowsOf(mixed)), ['e1', 'G1', 'e4', 'G2', 'e8']);
    });

    test('an expanded group shows its members under the header', () {
      final queue = queueOf(
        ['a', 'b', 'c', 'd'],
        groups: {
          'G1': ['e2', 'e3']
        },
        expanded: {'G1'},
      );
      final rows = rowsOf(queue);

      expect(describe(rows), ['e1', 'G1', 'G1:e2', 'G1:e3', 'e4']);
      // Header and members belong to the same top-level row.
      expect(rows.map((r) => r.itemIndex), [0, 1, 1, 1, 2]);
      final members = rows.whereType<QueueEntryRow<String>>().where(
            (r) => r.isMember,
          );
      expect(members.map((r) => r.indexInGroup), [0, 1]);
      expect(members.map((r) => r.groupId), ['G1', 'G1']);
    });

    test('the header knows its title, size and position', () {
      final rows = rowsOf(mixed);
      final g2 = rows.whereType<QueueGroupRow<String>>().last;

      expect(g2.group.title, 'Title G2');
      expect(g2.count, 3);
      expect(g2.collapsed, isTrue);
      expect(g2.flatStart, 4);
    });

    test('rows are keyed by entry id and group id, never by position', () {
      final before = rowsOf(mixed).map((r) => r.key).toList();
      expect(
          before, ['entry:e1', 'group:G1', 'entry:e4', 'group:G2', 'entry:e8']);

      final after = rowsOf(mixed.moveGroup('G2', 0)).map((r) => r.key).toSet();
      expect(after, before.toSet());
    });

    test('flat indexes follow the playback order, hidden members included', () {
      final rows = rowsOf(mixed);
      final loose = rows.whereType<QueueEntryRow<String>>();
      expect(loose.map((r) => r.entry.id), ['e1', 'e4', 'e8']);
      expect(loose.map((r) => r.flatIndex), [0, 3, 7]);
    });

    group('the playing track', () {
      test('is marked on the loose entry that plays', () {
        final rows = rowsOf(mixed, current: 3); // e4
        expect(
          rows
              .whereType<QueueEntryRow<String>>()
              .where((r) => r.isPlaying)
              .map((r) => r.entry.id),
          ['e4'],
        );
        expect(
          rows.whereType<QueueGroupRow<String>>().any((r) => r.containsPlaying),
          isFalse,
        );
      });

      test('marks a collapsed group that holds it', () {
        final rows = rowsOf(mixed, current: 5); // e6, inside G2
        final headers = rows.whereType<QueueGroupRow<String>>();
        expect(
          headers.map((h) => (h.group.id, h.containsPlaying)),
          [('G1', false), ('G2', true)],
        );
        expect(rows.whereType<QueueEntryRow<String>>().any((r) => r.isPlaying),
            isFalse);
      });

      test('marks the member of an expanded group, and its group', () {
        final queue = queueOf(
          ['a', 'b', 'c', 'd'],
          groups: {
            'G1': ['e2', 'e3']
          },
          expanded: {'G1'},
        );
        final rows = rowsOf(queue, current: 2); // e3

        expect(
          rows
              .whereType<QueueEntryRow<String>>()
              .where((r) => r.isPlaying)
              .map((r) => r.entry.id),
          ['e3'],
        );
        expect(
          rows.whereType<QueueGroupRow<String>>().single.containsPlaying,
          isTrue,
        );
      });

      test('is told apart by position when a track is queued twice', () {
        // The same track in four places: a loose copy, a copy in each group,
        // and another loose one.
        final queue = queueOf(
          ['x', 'x', 'x', 'x', 'x', 'y'],
          groups: {
            'G1': ['e2', 'e3'],
            'G2': ['e5'],
          },
          expanded: {'G1', 'G2'},
        );

        for (var playing = 0; playing < 5; playing++) {
          final rows = rowsOf(queue, current: playing);
          final marked = rows
              .whereType<QueueEntryRow<String>>()
              .where((r) => r.isPlaying)
              .map((r) => r.entry.id)
              .toList();
          expect(marked, ['e${playing + 1}'], reason: 'playing $playing');
        }
      });

      test('nothing is marked when nothing plays', () {
        for (final current in [-1, 99]) {
          final rows = rowsOf(mixed, current: current);
          expect(
            rows.whereType<QueueEntryRow<String>>().any((r) => r.isPlaying),
            isFalse,
          );
          expect(
            rows
                .whereType<QueueGroupRow<String>>()
                .any((r) => r.containsPlaying),
            isFalse,
          );
        }
      });
    });

    test('an invalid queue is still shown, as plain entries', () {
      final broken = GroupedQueue<String>(
        [QueueEntry('e1', 'a'), QueueEntry('e2', 'b')],
        [
          const QueueGroup(id: 'G', title: 't', memberIds: ['e1', 'zzz']),
        ],
      );
      expect(describe(rowsOf(broken)), ['e1', 'e2']);
    });

    test('there is one row per item, and the rows match GroupedQueue.items',
        () {
      final queue = queueOf(
        ['a', 'b', 'c', 'd', 'e', 'f'],
        groups: {
          'G1': ['e1', 'e2'],
          'G2': ['e4', 'e5', 'e6'],
        },
        expanded: {'G2'},
      );
      final rows = rowsOf(queue);
      final tops = <int>{...rows.map((r) => r.itemIndex)};

      expect(tops.length, queue.items.length);
      expect(describe(rows), ['G1', 'e3', 'G2', 'G2:e4', 'G2:e5', 'G2:e6']);
    });
  });

  group('rowIndexOfFlatIndex', () {
    test('finds an entry row', () {
      final rows = rowsOf(mixed);
      expect(rowIndexOfFlatIndex(rows, 0), 0);
      expect(rowIndexOfFlatIndex(rows, 3), 2);
      expect(rowIndexOfFlatIndex(rows, 7), 4);
    });

    test('a hidden member is found at the header of its collapsed group', () {
      final rows = rowsOf(mixed);
      expect(rowIndexOfFlatIndex(rows, 1), 1); // e2 in G1
      expect(rowIndexOfFlatIndex(rows, 2), 1); // e3 in G1
      expect(rowIndexOfFlatIndex(rows, 5), 3); // e6 in G2
    });

    test('an expanded member has its own row', () {
      final queue = queueOf(
        ['a', 'b', 'c'],
        groups: {
          'G1': ['e1', 'e2']
        },
        expanded: {'G1'},
      );
      final rows = rowsOf(queue);
      expect(describe(rows), ['G1', 'G1:e1', 'G1:e2', 'e3']);
      expect(rowIndexOfFlatIndex(rows, 1), 2);
    });

    test('there is none for a position outside the queue', () {
      expect(rowIndexOfFlatIndex(rowsOf(mixed), 8), isNull);
      expect(rowIndexOfFlatIndex(rowsOf(mixed), -1), isNull);
    });
  });

  group('resolveQueueDrop', () {
    // Rows of `mixed` with G1 expanded:
    //   0 e1  1 G1  2 G1:e2  3 G1:e3  4 e4  5 G2  6 e8
    final expandedG1 = mixed.setCollapsed('G1', false);
    final rows = rowsOf(expandedG1);

    test('the fixture is what the tests below assume', () {
      expect(describe(rows), ['e1', 'G1', 'G1:e2', 'G1:e3', 'e4', 'G2', 'e8']);
    });

    group('a loose entry', () {
      test('moves among the top-level rows', () {
        // e1 to just before e4 (gap 4).
        expect(resolveQueueDrop(rows, 0, 4), const MoveQueueItem(0, 2));
        // e8 to the front.
        expect(resolveQueueDrop(rows, 6, 0), const MoveQueueItem(4, 0));
        // e1 to the very end.
        expect(resolveQueueDrop(rows, 0, 7), const MoveQueueItem(0, 5));
      });

      test('dropped where it already is, nothing moves', () {
        expect(resolveQueueDrop(rows, 4, 4), isNull);
        expect(resolveQueueDrop(rows, 4, 5), isNull);
      });

      test('dropped inside an expanded group goes to its nearer edge', () {
        // Gap 2 is between the header and the first member: before the group.
        // (e1 already sits there, so nothing moves; e4 comes up to it.)
        expect(resolveQueueDrop(rows, 0, 2), isNull);
        expect(resolveQueueDrop(rows, 4, 2), const MoveQueueItem(2, 1));
        // Gap 3 is between the two members: with two members, after the group.
        expect(resolveQueueDrop(rows, 6, 3), const MoveQueueItem(4, 2));
      });

      test('a drop never lands between two members of a group', () {
        for (var gap = 0; gap <= rows.length; gap++) {
          for (final from in [0, 4, 6]) {
            final move = resolveQueueDrop(rows, from, gap);
            if (move == null) continue;
            final result = drag(expandedG1, move);
            expect(
              result.validate(),
              isEmpty,
              reason: 'from $from to gap $gap gave ${shape(result)}',
            );
            expect(result.groups.map((g) => g.memberIds),
                expandedG1.groups.map((g) => g.memberIds));
          }
        }
      });
    });

    group('a group header', () {
      test('moves the whole group', () {
        // G1 (item 1) to the end.
        expect(resolveQueueDrop(rows, 1, 7), const MoveGroup('G1', 5));
        // G2 (item 3) to the front.
        expect(resolveQueueDrop(rows, 5, 0), const MoveGroup('G2', 0));
      });

      test('the group arrives whole, members in order', () {
        final move = resolveQueueDrop(rows, 1, 7)!;
        expect(
            shape(drag(expandedG1, move)), 'e1 e4 G2[e5,e6,e7] e8 G1[e2,e3]');
      });

      test('dropped where it is, or inside itself, nothing moves', () {
        expect(resolveQueueDrop(rows, 1, 1), isNull);
        expect(resolveQueueDrop(rows, 1, 2), isNull);
        expect(resolveQueueDrop(rows, 1, 3), isNull);
        expect(resolveQueueDrop(rows, 1, 4), isNull);
      });

      test('dropped inside another expanded group goes beside it, not in it',
          () {
        final both = expandedG1.setCollapsed('G2', false);
        final r = rowsOf(both);
        // 0 e1 1 G1 2 G1:e2 3 G1:e3 4 e4 5 G2 6 G2:e5 7 G2:e6 8 G2:e7 9 e8
        expect(describe(r).length, 10);

        // G1 dropped between G2's first and second members (gap 7).
        final move = resolveQueueDrop(r, 1, 7)!;
        final result = drag(both, move);
        expect(shape(result), contains('G2[e5,e6,e7]'));
        expect(shape(result), contains('G1[e2,e3]'));
        expect(result.validate(), isEmpty);
      });
    });

    group('a member of an expanded group', () {
      test('moves inside its group', () {
        // e2 (member 0) to after e3 (gap 4).
        expect(resolveQueueDrop(rows, 2, 4), const MoveWithinGroup('G1', 0, 2));
        // e3 (member 1) to before e2 (gap 2).
        expect(resolveQueueDrop(rows, 3, 2), const MoveWithinGroup('G1', 1, 0));
      });

      test('cannot leave the group: a far drop is the nearest end', () {
        expect(resolveQueueDrop(rows, 2, 7), const MoveWithinGroup('G1', 0, 2));
        expect(resolveQueueDrop(rows, 3, 0), const MoveWithinGroup('G1', 1, 0));
      });

      test('dropped where it is, nothing moves', () {
        expect(resolveQueueDrop(rows, 2, 2), isNull);
        expect(resolveQueueDrop(rows, 2, 3), isNull);
        expect(resolveQueueDrop(rows, 3, 3), isNull);
        expect(resolveQueueDrop(rows, 3, 4), isNull);
      });

      test('only the members of the group change', () {
        final move = resolveQueueDrop(rows, 2, 4)!;
        expect(
            shape(drag(expandedG1, move)), 'e1 G1[e3,e2] e4 G2[e5,e6,e7] e8');
      });
    });

    test('rows that do not exist resolve to nothing', () {
      expect(resolveQueueDrop(rows, -1, 2), isNull);
      expect(resolveQueueDrop(rows, 99, 2), isNull);
      expect(resolveQueueDrop(rows, 0, -1), isNull);
      expect(resolveQueueDrop(rows, 0, 99), isNull);
      expect(resolveQueueDrop(<QueueRow<String>>[], 0, 0), isNull);
    });

    test('with no groups it is the plain queue move', () {
      final plain = rowsOf(queueOf(['a', 'b', 'c', 'd']));
      expect(resolveQueueDrop(plain, 0, 3), const MoveQueueItem(0, 3));
      expect(resolveQueueDrop(plain, 3, 1), const MoveQueueItem(3, 1));
      expect(resolveQueueDrop(plain, 1, 2), isNull);
    });

    test('a group with one member has just that member to move', () {
      final queue = queueOf(
        ['a', 'b', 'c'],
        groups: {
          'G1': ['e2']
        },
        expanded: {'G1'},
      );
      final r = rowsOf(queue);
      expect(describe(r), ['e1', 'G1', 'G1:e2', 'e3']);
      expect(resolveQueueDrop(r, 2, 0), isNull);
      expect(resolveQueueDrop(r, 2, 4), isNull);
    });
  });

  group('whatever is dragged, the queue stays whole', () {
    // Random queues, random expansion, every drag from every row to every gap.
    // Each resulting queue must be valid, keep every entry once, keep every
    // group's members together and in their own order (except for a move
    // inside the group), and never leave the playing entry behind.
    test('exhaustive over random queues', () {
      final random = Random(11);
      for (var round = 0; round < 60; round++) {
        final count = 1 + random.nextInt(9);
        final tracks = [
          for (var i = 0; i < count; i++) 't${random.nextInt(4)}', // duplicates
        ];
        var queue = queueOf(tracks);
        var next = 0;
        // Make a few groups out of runs of loose entries.
        var from = 0;
        while (from < count) {
          final size = 1 + random.nextInt(3);
          final end = min(count, from + size);
          if (random.nextBool()) {
            queue = queue.createGroup(
              groupId: 'G${++next}',
              title: 'g',
              entryIds: [for (var i = from; i < end; i++) 'e${i + 1}'],
              collapsed: random.nextBool(),
            );
          }
          from = end;
        }

        final rows = rowsOf(queue, current: random.nextInt(count));
        final originalIds = queue.entries.map((e) => e.id).toList()..sort();

        for (var old = 0; old < rows.length; old++) {
          for (var gap = 0; gap <= rows.length; gap++) {
            final move = resolveQueueDrop(rows, old, gap);
            if (move == null) continue;
            final reason = 'queue ${shape(queue)}: row $old to gap $gap';

            final result = drag(queue, move);

            expect(result.validate(), isEmpty, reason: reason);
            expect(
                result.entries.map((e) => e.id).toList()..sort(), originalIds,
                reason: reason);
            expect(result.groups.map((g) => g.id).toSet(),
                queue.groups.map((g) => g.id).toSet(),
                reason: reason);

            final dragged = rows[old];
            for (final g in queue.groups) {
              final after = result.groupById(g.id)!;
              final inside =
                  dragged is QueueEntryRow<String> && dragged.groupId == g.id;
              if (inside) {
                expect(after.memberIds.toSet(), g.memberIds.toSet(),
                    reason: reason);
              } else {
                expect(after.memberIds, g.memberIds, reason: reason);
              }
            }
            // A move of a member touches nothing outside its group.
            if (move is MoveWithinGroup) {
              expect(
                result.items.map((i) => switch (i) {
                      EntryItem<String>(:final entry) => entry.id,
                      GroupItem<String>(:final group) => group.id,
                    }),
                queue.items.map((i) => switch (i) {
                      EntryItem<String>(:final entry) => entry.id,
                      GroupItem<String>(:final group) => group.id,
                    }),
                reason: reason,
              );
            }
          }
        }
      }
    });
  });
}
