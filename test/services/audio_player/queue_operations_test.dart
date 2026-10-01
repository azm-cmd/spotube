import 'dart:collection';

import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:test/test.dart';

/// Stand-in for a track: only the id matters to the queue logic, `tag` lets
/// tests tell apart two entries that share an id.
class _Track {
  final String id;
  final String tag;
  const _Track(this.id, [this.tag = '']);

  @override
  String toString() => tag.isEmpty ? id : '$id/$tag';
}

List<String> _ids(Iterable<_Track> tracks) => tracks.map((t) => t.id).toList();

void main() {
  group('QueueRange', () {
    test('length, isEmpty and contains are half-open', () {
      const range = QueueRange(2, 5);
      expect(range.length, 3);
      expect(range.isEmpty, isFalse);
      expect(range.contains(1), isFalse);
      expect(range.contains(2), isTrue);
      expect(range.contains(4), isTrue);
      expect(range.contains(5), isFalse);
      expect(const QueueRange(3, 3).isEmpty, isTrue);
    });

    test('has value equality', () {
      expect(const QueueRange(1, 4), const QueueRange(1, 4));
      expect(const QueueRange(1, 4).hashCode, const QueueRange(1, 4).hashCode);
      expect(const QueueRange(1, 4), isNot(const QueueRange(1, 5)));
    });
  });

  group('validIndexes', () {
    test('empty input and empty queue', () {
      expect(validIndexes(const [], 5), isEmpty);
      expect(validIndexes(const [0, 1], 0), isEmpty);
    });

    test('sorts, de-duplicates and drops out-of-bounds indexes', () {
      expect(validIndexes([3, -1, 0, 3, 7, 2, 5], 5), [0, 2, 3]);
    });

    test('length itself is out of bounds', () {
      expect(validIndexes([4, 5], 5), [4]);
    });
  });

  group('indexesWhere', () {
    test('empty queue', () {
      expect(indexesWhere(<_Track>[], (t) => true), isEmpty);
    });

    test('single item', () {
      expect(indexesWhere([const _Track('a')], (t) => t.id == 'a'), [0]);
      expect(indexesWhere([const _Track('a')], (t) => t.id == 'b'), isEmpty);
    });

    test('returns every match, including duplicate track ids', () {
      final queue = [
        const _Track('a'),
        const _Track('b'),
        const _Track('a', 'second'),
        const _Track('c'),
      ];
      expect(indexesWhere(queue, (t) => t.id == 'a'), [0, 2]);
    });
  });

  group('contiguousRanges / isContiguous', () {
    test('empty input has no ranges and is not contiguous', () {
      expect(contiguousRanges(const []), isEmpty);
      expect(isContiguous(const []), isFalse);
    });

    test('single index', () {
      expect(contiguousRanges([4]), [const QueueRange(4, 5)]);
      expect(isContiguous([4]), isTrue);
    });

    test('one run of consecutive indexes', () {
      expect(contiguousRanges([2, 3, 4]), [const QueueRange(2, 5)]);
      expect(isContiguous([2, 3, 4]), isTrue);
    });

    test('splits on gaps', () {
      expect(contiguousRanges([0, 1, 3, 4, 5, 9]), const [
        QueueRange(0, 2),
        QueueRange(3, 6),
        QueueRange(9, 10),
      ]);
      expect(isContiguous([0, 1, 3]), isFalse);
    });

    test('accepts unsorted input and duplicates', () {
      expect(contiguousRanges([4, 1, 2, 2, 7, 5]), const [
        QueueRange(1, 3),
        QueueRange(4, 6),
        QueueRange(7, 8),
      ]);
      expect(isContiguous([3, 2, 3, 1]), isTrue);
    });

    test('ignores negative indexes', () {
      expect(contiguousRanges([-2, -1, 0, 1]), [const QueueRange(0, 2)]);
      expect(contiguousRanges([-1]), isEmpty);
    });

    test('ranges cover exactly the given indexes', () {
      final indexes = {0, 1, 2, 5, 6, 10};
      final covered = {
        for (final range in contiguousRanges(indexes))
          for (var i = range.start; i < range.end; i++) i,
      };
      expect(covered, indexes);
    });
  });

  group('insertEntries', () {
    test('into an empty queue', () {
      expect(insertEntries(<String>[], 0, ['a', 'b']), ['a', 'b']);
    });

    test('at the start, middle and end', () {
      const queue = ['a', 'b', 'c'];
      expect(insertEntries(queue, 0, ['x', 'y']), ['x', 'y', 'a', 'b', 'c']);
      expect(insertEntries(queue, 1, ['x', 'y']), ['a', 'x', 'y', 'b', 'c']);
      expect(insertEntries(queue, 3, ['x', 'y']), ['a', 'b', 'c', 'x', 'y']);
    });

    test('inserting nothing returns an equal copy', () {
      final queue = ['a', 'b'];
      final result = insertEntries(queue, 1, const <String>[]);
      expect(result, queue);
      expect(identical(result, queue), isFalse);
    });

    test('single item queue', () {
      expect(insertEntries(['a'], 0, ['x']), ['x', 'a']);
      expect(insertEntries(['a'], 1, ['x']), ['a', 'x']);
    });

    test('matches inserting one by one at index, index + 1, ...', () {
      // This is how "play next" feeds the live player.
      final live = ['a', 'b', 'c'];
      const entries = ['x', 'y', 'z'];
      const index = 1;
      for (var i = 0; i < entries.length; i++) {
        live.insert(index + i, entries[i]);
      }
      expect(insertEntries(['a', 'b', 'c'], index, entries), live);
    });

    test('duplicate track ids are inserted as separate entries', () {
      final result = insertEntries(
        [const _Track('a')],
        1,
        [const _Track('a', 'copy')],
      );
      expect(_ids(result), ['a', 'a']);
      expect(result.map((t) => t.tag), ['', 'copy']);
    });

    test('rejects invalid indexes', () {
      expect(() => insertEntries(['a'], -1, ['x']), throwsRangeError);
      expect(() => insertEntries(['a'], 2, ['x']), throwsRangeError);
      expect(() => insertEntries(<String>[], 1, ['x']), throwsRangeError);
    });

    test('does not mutate its input', () {
      final queue = ['a', 'b'];
      insertEntries(queue, 1, ['x']);
      expect(queue, ['a', 'b']);
    });
  });

  group('removeIndexes', () {
    test('empty queue', () {
      expect(removeIndexes(<String>[], [0, 1]), isEmpty);
    });

    test('single item', () {
      expect(removeIndexes(['a'], [0]), isEmpty);
      expect(removeIndexes(['a'], const []), ['a']);
    });

    test('removes multiple items and keeps the order of the rest', () {
      expect(removeIndexes(['a', 'b', 'c', 'd', 'e'], [3, 0, 2]), ['b', 'e']);
    });

    test('ignores duplicate and out-of-bounds indexes', () {
      expect(removeIndexes(['a', 'b', 'c'], [1, 1, -1, 3, 99]), ['a', 'c']);
    });

    test('removing every index empties the queue', () {
      expect(removeIndexes(['a', 'b', 'c'], [0, 1, 2]), isEmpty);
    });

    test('removes by position, so duplicate ids can be told apart', () {
      final queue = [
        const _Track('a', 'first'),
        const _Track('b'),
        const _Track('a', 'second'),
      ];
      final result = removeIndexes(queue, [2]);
      expect(result.map((t) => t.tag), ['first', '']);
    });

    test('does not mutate its input', () {
      final queue = ['a', 'b', 'c'];
      removeIndexes(queue, [0]);
      expect(queue, ['a', 'b', 'c']);
    });
  });

  group('removalOrder', () {
    test('is descending, unique and in bounds', () {
      expect(removalOrder([1, 4, 4, 0, 9, -2], 5), [4, 1, 0]);
    });

    test('empty queue or no indexes', () {
      expect(removalOrder([0, 1], 0), isEmpty);
      expect(removalOrder(const [], 5), isEmpty);
    });
  });

  // Regression tests for AudioPlayerNotifier.removeTracks. The player removes
  // one entry per call and every removal shifts the entries after it, so the
  // positions handed to it matter. A plain list stands in for the live
  // (libmpv) playlist.
  group('removing several tracks from a live playlist', () {
    List<_Track> applyToLive(List<_Track> queue, Iterable<int> positions) {
      final live = [...queue];
      for (final position in positions) {
        live.removeAt(position);
      }
      return live;
    }

    final queue = [
      const _Track('a'),
      const _Track('b'),
      const _Track('c'),
      const _Track('d'),
      const _Track('e'),
    ];
    final idsToRemove = {'b', 'd', 'e'};
    final expected = ['a', 'c'];

    test('the previous computation removed the wrong entries', () {
      // `where(...).mapIndexed((index, _) => index)`: positions within the
      // filtered list (0, 1, 2) instead of positions in the queue (1, 3, 4).
      final oldPositions = [
        for (var i = 0;
            i < queue.where((t) => idsToRemove.contains(t.id)).length;
            i++)
          i,
      ];
      expect(oldPositions, [0, 1, 2]);
      expect(_ids(applyToLive(queue, oldPositions)), isNot(expected));
    });

    test('removalOrder + indexesWhere removes exactly the requested ids', () {
      final positions = removalOrder(
        indexesWhere(queue, (t) => idsToRemove.contains(t.id)),
        queue.length,
      );
      expect(positions, [4, 3, 1]);
      expect(_ids(applyToLive(queue, positions)), expected);
      expect(
        _ids(applyToLive(queue, positions)),
        _ids(removeIndexes(queue, positions)),
      );
    });

    test('removes every occurrence of a duplicated track id', () {
      final withDuplicates = [
        const _Track('a'),
        const _Track('b', 'one'),
        const _Track('c'),
        const _Track('b', 'two'),
      ];
      final positions = removalOrder(
        indexesWhere(withDuplicates, (t) => t.id == 'b'),
        withDuplicates.length,
      );
      expect(_ids(applyToLive(withDuplicates, positions)), ['a', 'c']);
    });

    test('ids that are not in the queue remove nothing', () {
      final positions = removalOrder(
        indexesWhere(queue, (t) => t.id == 'zzz'),
        queue.length,
      );
      expect(positions, isEmpty);
      expect(_ids(applyToLive(queue, positions)), _ids(queue));
    });
  });

  group('canMoveEntry', () {
    test('accepts two different existing positions', () {
      expect(canMoveEntry(3, 0, 2), isTrue);
      expect(canMoveEntry(3, 2, 0), isTrue);
      expect(canMoveEntry(2, 0, 1), isTrue);
    });

    test('rejects a move onto itself', () {
      expect(canMoveEntry(3, 1, 1), isFalse);
    });

    test('rejects negative and out-of-bounds positions', () {
      expect(canMoveEntry(3, -1, 1), isFalse);
      expect(canMoveEntry(3, 1, -1), isFalse);
      expect(canMoveEntry(3, 3, 1), isFalse);
      expect(canMoveEntry(3, 1, 3), isFalse);
    });

    test('rejects everything for an empty queue', () {
      expect(canMoveEntry(0, 0, 0), isFalse);
      expect(canMoveEntry(0, 0, 1), isFalse);
    });

    test('rejects everything for a single item queue', () {
      expect(canMoveEntry(1, 0, 0), isFalse);
      expect(canMoveEntry(1, 0, 1), isFalse);
    });

    test('keeps the original guard: to == length is not forwarded', () {
      // Dropping an item below the last row yields newIndex == length. The
      // app has always ignored that move; this pins the behaviour.
      expect(canMoveEntry(4, 0, 4), isFalse);
    });

    test('is exactly the condition moveTrack used before it was extracted', () {
      bool previousGuardRejects(int length, int oldIndex, int newIndex) {
        return oldIndex == newIndex ||
            newIndex < 0 ||
            oldIndex < 0 ||
            newIndex > length - 1 ||
            oldIndex > length - 1;
      }

      for (var length = 0; length <= 6; length++) {
        for (var from = -3; from <= 9; from++) {
          for (var to = -3; to <= 9; to++) {
            expect(
              canMoveEntry(length, from, to),
              !previousGuardRejects(length, from, to),
              reason: 'length=$length from=$from to=$to',
            );
          }
        }
      }
    });
  });

  group('moveEntry', () {
    const queue = ['a', 'b', 'c', 'd'];

    test('empty queue has nothing to move', () {
      expect(() => moveEntry(<String>[], 0, 0), throwsRangeError);
    });

    test('single item', () {
      expect(moveEntry(['a'], 0, 0), ['a']);
      expect(moveEntry(['a'], 0, 1), ['a']);
    });

    test('moving forward lands before the target entry', () {
      expect(moveEntry(queue, 0, 2), ['b', 'a', 'c', 'd']);
      expect(moveEntry(queue, 0, 3), ['b', 'c', 'a', 'd']);
      expect(moveEntry(queue, 1, 3), ['a', 'c', 'b', 'd']);
    });

    test('moving backward lands at the target position', () {
      expect(moveEntry(queue, 3, 0), ['d', 'a', 'b', 'c']);
      expect(moveEntry(queue, 2, 1), ['a', 'c', 'b', 'd']);
      expect(moveEntry(queue, 3, 2), ['a', 'b', 'd', 'c']);
    });

    test('to == length moves to the very end', () {
      expect(moveEntry(queue, 0, 4), ['b', 'c', 'd', 'a']);
      expect(moveEntry(queue, 3, 4), queue);
    });

    test('moving onto itself or just before the next entry is a no-op', () {
      expect(moveEntry(queue, 1, 1), queue);
      expect(moveEntry(queue, 1, 2), queue);
    });

    test('rejects invalid positions', () {
      expect(() => moveEntry(queue, -1, 1), throwsRangeError);
      expect(() => moveEntry(queue, 4, 1), throwsRangeError);
      expect(() => moveEntry(queue, 1, -1), throwsRangeError);
      expect(() => moveEntry(queue, 1, 5), throwsRangeError);
    });

    test('keeps duplicate entries and moves only the one at `from`', () {
      final withDuplicates = [
        const _Track('a', 'first'),
        const _Track('b'),
        const _Track('a', 'second'),
      ];
      final result = moveEntry(withDuplicates, 2, 0);
      expect(result.map((t) => t.tag), ['second', 'first', '']);
      expect(_ids(result), ['a', 'a', 'b']);
    });

    test('result is a permutation and the input is untouched', () {
      final input = [...queue];
      final result = moveEntry(input, 0, 3);
      expect(input, queue);
      expect(result.toSet(), queue.toSet());
      expect(result.length, queue.length);
    });

    test('matches the move model used by media_kit for every from/to', () {
      // media_kit mirrors `playlist-move` on its Dart side like this
      // (Player.move in native/player/real.dart).
      List<String> mediaKitMove(List<String> current, int from, int to) {
        final map = SplayTreeMap<double, String>.from(
          current.asMap().map((key, value) => MapEntry(key * 1.0, value)),
        );
        final item = map.remove(from * 1.0);
        if (item != null) {
          map[to - 0.5] = item;
        }
        return map.values.toList();
      }

      const items = ['a', 'b', 'c', 'd', 'e'];
      for (var from = 0; from < items.length; from++) {
        for (var to = 0; to <= items.length; to++) {
          expect(
            moveEntry(items, from, to),
            mediaKitMove(items, from, to),
            reason: 'move($from, $to)',
          );
        }
      }
    });
  });

  // --- Queue entry identity -------------------------------------------------

  /// Deterministic id source: e1, e2, ... in the order they are requested.
  QueueEntryIdGenerator counter([String prefix = 'e']) {
    var n = 0;
    return () => '$prefix${++n}';
  }

  List<String> entryIds(Iterable<QueueEntry<_Track>> entries) =>
      entries.map((e) => e.id).toList();

  List<String> trackIds(Iterable<QueueEntry<_Track>> entries) =>
      entries.map((e) => e.track.id).toList();

  group('QueueEntry', () {
    test('has value equality on id and track', () {
      const track = _Track('a');
      expect(const QueueEntry('e1', track), const QueueEntry('e1', track));
      expect(
        const QueueEntry('e1', track).hashCode,
        const QueueEntry('e1', track).hashCode,
      );
      expect(
          const QueueEntry('e1', track), isNot(const QueueEntry('e2', track)));
    });
  });

  group('createEntries', () {
    test('empty queue', () {
      expect(createEntries(<_Track>[], counter()), isEmpty);
    });

    test('single item', () {
      final entries = createEntries([const _Track('a')], counter());
      expect(entries.length, 1);
      expect(entries.single.id, 'e1');
      expect(entries.single.track.id, 'a');
    });

    test('keeps the order of the tracks', () {
      final entries = createEntries(
        [const _Track('c'), const _Track('a'), const _Track('b')],
        counter(),
      );
      expect(trackIds(entries), ['c', 'a', 'b']);
    });

    test('two identical track ids are two distinct entries', () {
      final entries = createEntries(
        [const _Track('a', 'first'), const _Track('a', 'second')],
        counter(),
      );
      expect(trackIds(entries), ['a', 'a']);
      expect(entries[0].id, isNot(entries[1].id));
      expect(hasUniqueEntryIds(entries), isTrue);
      expect(entries[0].track.tag, 'first');
      expect(entries[1].track.tag, 'second');
    });

    test('three identical track ids stay distinguishable', () {
      final entries = createEntries(
        [
          const _Track('a', 'one'),
          const _Track('a', 'two'),
          const _Track('a', 'three'),
        ],
        counter(),
      );
      expect(entries.map((e) => e.id).toSet().length, 3);
      expect(hasUniqueEntryIds(entries), isTrue);
      expect(entries.map((e) => e.track.tag), ['one', 'two', 'three']);
    });

    test('the entry id is not the track id', () {
      final entries =
          createEntries([const _Track('a'), const _Track('b')], counter());
      for (final entry in entries) {
        expect(entry.id, isNot(entry.track.id));
      }
    });

    test('asks the generator once per entry, in order', () {
      var calls = 0;
      final entries = createEntries([const _Track('a'), const _Track('b')], () {
        calls++;
        return 'id$calls';
      });
      expect(calls, 2);
      expect(entryIds(entries), ['id1', 'id2']);
    });
  });

  group('pairEntries / hasUniqueEntryIds / indexOfEntry', () {
    test('pairs parallel lists by position', () {
      final entries = pairEntries(
        [const _Track('a'), const _Track('b')],
        ['x', 'y'],
      );
      expect(entryIds(entries), ['x', 'y']);
      expect(trackIds(entries), ['a', 'b']);
    });

    test('empty lists', () {
      expect(pairEntries(<_Track>[], <String>[]), isEmpty);
    });

    test('rejects lists of different length', () {
      expect(() => pairEntries([const _Track('a')], <String>[]),
          throwsArgumentError);
      expect(
        () => pairEntries(<_Track>[], ['x']),
        throwsArgumentError,
      );
    });

    test('hasUniqueEntryIds detects a repeated id', () {
      const a = _Track('a');
      expect(hasUniqueEntryIds(<QueueEntry<_Track>>[]), isTrue);
      expect(
          hasUniqueEntryIds(
              [const QueueEntry('x', a), const QueueEntry('y', a)]),
          isTrue);
      expect(
          hasUniqueEntryIds(
              [const QueueEntry('x', a), const QueueEntry('x', a)]),
          isFalse);
    });

    test('indexOfEntry finds one occurrence of a duplicated track', () {
      final entries = createEntries(
        [const _Track('a'), const _Track('b'), const _Track('a')],
        counter(),
      );
      expect(indexOfEntry(entries, 'e1'), 0);
      expect(indexOfEntry(entries, 'e3'), 2);
      expect(indexOfEntry(entries, 'missing'), -1);
      expect(indexOfEntry(<QueueEntry<_Track>>[], 'e1'), -1);
    });
  });

  group('identity survives queue operations', () {
    List<QueueEntry<_Track>> queue() => createEntries(
          [
            const _Track('a', 'first'),
            const _Track('b'),
            const _Track('a', 'second'),
            const _Track('c'),
            const _Track('a', 'third'),
          ],
          counter(),
        );

    test('reordering keeps every entry, its id and its track', () {
      final before = queue();
      final after = moveEntry(before, 4, 0);

      expect(entryIds(after), ['e5', 'e1', 'e2', 'e3', 'e4']);
      for (final entry in before) {
        final moved = after.singleWhere((e) => e.id == entry.id);
        expect(identical(moved.track, entry.track), isTrue);
      }
      expect(hasUniqueEntryIds(after), isTrue);
    });

    test('moving forward keeps identities (copies of a track included)', () {
      final after = moveEntry(queue(), 0, 4);
      expect(entryIds(after), ['e2', 'e3', 'e4', 'e1', 'e5']);
      expect(
          after.map((e) => e.track.tag), ['', 'second', '', 'first', 'third']);
    });

    test('many moves in a row never change the set of ids', () {
      var entries = queue();
      final ids = entryIds(entries).toSet();
      for (final (from, to) in [(0, 3), (4, 1), (2, 5), (3, 0), (1, 4)]) {
        entries = moveEntry(entries, from, to);
        expect(entryIds(entries).toSet(), ids);
        expect(hasUniqueEntryIds(entries), isTrue);
      }
    });

    test('identity stays attached to the track it was issued for', () {
      var entries = queue();
      final tagById = {for (final e in entries) e.id: e.track.tag};
      entries = moveEntry(entries, 2, 0);
      entries = moveEntry(entries, 3, 5);
      for (final entry in entries) {
        expect(entry.track.tag, tagById[entry.id]);
      }
    });

    test('removing one copy removes exactly that occurrence', () {
      final entries = queue();
      final target = entries[2]; // the "second" copy of a
      final after = removeIndexes(entries, [indexOfEntry(entries, target.id)]);

      expect(after.length, 4);
      expect(after.any((e) => e.id == target.id), isFalse);
      expect(after.where((e) => e.track.id == 'a').map((e) => e.track.tag), [
        'first',
        'third',
      ]);
    });

    test('removing every copy of a track by id removes all of them', () {
      final entries = queue();
      final indexes = indexesWhere(entries, (e) => e.track.id == 'a');
      final after = removeIndexes(entries, indexes);
      expect(trackIds(after), ['b', 'c']);
      expect(entryIds(after), ['e2', 'e4']);
    });

    test('removal keeps the ids of the entries that remain', () {
      final entries = queue();
      final after = removeIndexes(entries, [0, 3]);
      expect(entryIds(after), ['e2', 'e3', 'e5']);
    });

    test('inserting creates new identities, never reusing existing ones', () {
      final entries = queue();
      final fresh = createEntries(
        [const _Track('a', 'inserted'), const _Track('x')],
        counter('new'),
      );
      final after = insertEntries(entries, 2, fresh);

      expect(after.length, 7);
      expect(entryIds(after), ['e1', 'e2', 'new1', 'new2', 'e3', 'e4', 'e5']);
      expect(hasUniqueEntryIds(after), isTrue);
      // the inserted copy of `a` is a different entry from the existing copies
      expect(after[2].track.id, 'a');
      expect(entries.any((e) => e.id == after[2].id), isFalse);
    });

    test('inserting the same track again gives it a different identity', () {
      final entries = createEntries([const _Track('a')], counter());
      final after = insertEntries(
        entries,
        1,
        createEntries([const _Track('a')], counter('again')),
      );
      expect(trackIds(after), ['a', 'a']);
      expect(entryIds(after), ['e1', 'again1']);
    });

    test('the input list is never mutated', () {
      final entries = queue();
      final snapshot = entryIds(entries);
      moveEntry(entries, 0, 3);
      removeIndexes(entries, [1]);
      insertEntries(
          entries, 0, createEntries([const _Track('z')], counter('n')));
      expect(entryIds(entries), snapshot);
    });
  });

  group('reconcileEntries', () {
    String keyOf(_Track t) => t.id;
    List<QueueEntry<_Track>> entriesOf(List<_Track> tracks) =>
        createEntries(tracks, counter());

    test('empty queue and empty player order', () {
      expect(reconcileEntries(<QueueEntry<_Track>>[], ['a'], keyOf), isEmpty);
      expect(
        reconcileEntries(
            entriesOf([const _Track('a')]), const <String>[], keyOf),
        isEmpty,
      );
    });

    test('single item', () {
      final entries = entriesOf([const _Track('a')]);
      expect(reconcileEntries(entries, ['a'], keyOf), entries);
    });

    test('unchanged order returns the same entries', () {
      final entries = entriesOf(
        [const _Track('a'), const _Track('b'), const _Track('c')],
      );
      expect(reconcileEntries(entries, ['a', 'b', 'c'], keyOf), entries);
    });

    test('follows the player order after a shuffle, keeping ids with tracks',
        () {
      final entries = entriesOf(
        [const _Track('a'), const _Track('b'), const _Track('c')],
      );
      final result = reconcileEntries(entries, ['c', 'a', 'b'], keyOf);
      expect(trackIds(result), ['c', 'a', 'b']);
      expect(entryIds(result), ['e3', 'e1', 'e2']);
    });

    test('returns the same entry objects, not copies', () {
      final entries = entriesOf([const _Track('a'), const _Track('b')]);
      final result = reconcileEntries(entries, ['b', 'a'], keyOf);
      expect(identical(result[0], entries[1]), isTrue);
      expect(identical(result[1], entries[0]), isTrue);
    });

    test('two copies of a track are not collapsed into the first one', () {
      final entries = entriesOf(
        [const _Track('a', 'first'), const _Track('a', 'second')],
      );
      final result = reconcileEntries(entries, ['a', 'a'], keyOf);
      expect(result.length, 2);
      expect(entryIds(result), ['e1', 'e2']);
      expect(result.map((e) => e.track.tag), ['first', 'second']);
    });

    test('three copies keep three distinct entries in their original order',
        () {
      final entries = entriesOf([
        const _Track('a', 'one'),
        const _Track('b'),
        const _Track('a', 'two'),
        const _Track('a', 'three'),
      ]);
      final result = reconcileEntries(entries, ['b', 'a', 'a', 'a'], keyOf);
      expect(entryIds(result), ['e2', 'e1', 'e3', 'e4']);
      expect(result.map((e) => e.track.tag), ['', 'one', 'two', 'three']);
      expect(hasUniqueEntryIds(result), isTrue);
    });

    test('copies stay distinct when the player interleaves them with others',
        () {
      final entries = entriesOf([
        const _Track('a', 'one'),
        const _Track('a', 'two'),
        const _Track('b'),
        const _Track('c'),
      ]);
      final result = reconcileEntries(entries, ['c', 'a', 'b', 'a'], keyOf);
      expect(trackIds(result), ['c', 'a', 'b', 'a']);
      expect(entryIds(result), ['e4', 'e1', 'e3', 'e2']);
    });

    test('a move applied to the entries first is confirmed, not undone', () {
      // The player cannot tell which copy of `a` was moved, so the app applies
      // the move itself and the player's report only has to agree with it.
      final entries = entriesOf([
        const _Track('a', 'first'),
        const _Track('b'),
        const _Track('a', 'second'),
      ]);
      final moved = moveEntry(entries, 2, 0); // second copy to the front
      final result = reconcileEntries(moved, ['a', 'a', 'b'], keyOf);

      expect(entryIds(result), ['e3', 'e1', 'e2']);
      expect(result.map((e) => e.track.tag), ['second', 'first', '']);
    });

    test('identity is stable across repeated reconciliations', () {
      var entries = entriesOf([
        const _Track('a', 'one'),
        const _Track('a', 'two'),
        const _Track('b'),
      ]);
      final original = entryIds(entries);
      for (var i = 0; i < 4; i++) {
        entries = reconcileEntries(entries, ['a', 'a', 'b'], keyOf);
        expect(entryIds(entries), original);
      }
    });

    test('keys the queue does not know are skipped', () {
      final entries = entriesOf([const _Track('a')]);
      expect(
          entryIds(reconcileEntries(entries, ['x', 'a', 'y'], keyOf)), ['e1']);
    });

    test('a key reported more often than it is queued only claims what exists',
        () {
      final entries = entriesOf([const _Track('a')]);
      expect(
          entryIds(reconcileEntries(entries, ['a', 'a', 'a'], keyOf)), ['e1']);
    });

    test('entries missing from the player order are dropped', () {
      final entries = entriesOf([const _Track('a'), const _Track('b')]);
      expect(entryIds(reconcileEntries(entries, ['b'], keyOf)), ['e2']);
    });

    test('does not mutate its input and works with non-string keys', () {
      final entries = createEntries(['bb', 'a', 'ccc'], counter());
      final result = reconcileEntries(entries, [3, 1, 2], (s) => s.length);
      expect(result.map((e) => e.track), ['ccc', 'a', 'bb']);
      expect(entries.map((e) => e.track), ['bb', 'a', 'ccc']);
    });
  });
}
