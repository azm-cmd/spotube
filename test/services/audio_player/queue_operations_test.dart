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
        for (
          var i = 0;
          i < queue.where((t) => idsToRemove.contains(t.id)).length;
          i++
        )
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

  group('reorderByKeys', () {
    String idOf(_Track t) => t.id;

    test('empty queue and empty order', () {
      expect(reorderByKeys(<_Track>[], ['a'], idOf), isEmpty);
      expect(
        reorderByKeys([const _Track('a')], const <String>[], idOf),
        isEmpty,
      );
    });

    test('single item', () {
      final a = const _Track('a');
      expect(reorderByKeys([a], ['a'], idOf), [a]);
    });

    test('unchanged order is preserved', () {
      final queue = [const _Track('a'), const _Track('b'), const _Track('c')];
      expect(reorderByKeys(queue, ['a', 'b', 'c'], idOf), queue);
    });

    test('follows a new order such as a shuffle', () {
      final a = const _Track('a');
      final b = const _Track('b');
      final c = const _Track('c');
      expect(reorderByKeys([a, b, c], ['c', 'a', 'b'], idOf), [c, a, b]);
    });

    test('returns the same objects, not copies', () {
      final a = const _Track('a');
      final b = const _Track('b');
      final result = reorderByKeys([a, b], ['b', 'a'], idOf);
      expect(identical(result[0], b), isTrue);
      expect(identical(result[1], a), isTrue);
    });

    test('keys without an item are skipped', () {
      final a = const _Track('a');
      expect(reorderByKeys([a], ['x', 'a', 'y'], idOf), [a]);
    });

    test('items whose key is missing from the order are dropped', () {
      final a = const _Track('a');
      final b = const _Track('b');
      expect(reorderByKeys([a, b], ['b'], idOf), [b]);
    });

    test('duplicate ids: every occurrence resolves to the first item', () {
      // Documents the existing limitation, relied on by
      // AudioPlayerNotifier's playlist listener until entries get their own
      // identity.
      final first = const _Track('a', 'first');
      final second = const _Track('a', 'second');
      final b = const _Track('b');
      final result = reorderByKeys([first, b, second], ['a', 'b', 'a'], idOf);
      expect(result.length, 3);
      expect(identical(result[0], first), isTrue);
      expect(identical(result[2], first), isTrue);
      expect(_ids(result), ['a', 'b', 'a']);
    });

    test('does not mutate its input and works with non-string keys', () {
      final queue = ['bb', 'a', 'ccc'];
      final result = reorderByKeys(queue, [3, 1, 2], (s) => s.length);
      expect(result, ['ccc', 'a', 'bb']);
      expect(queue, ['bb', 'a', 'ccc']);
    });
  });
}
