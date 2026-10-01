/// Pure, dependency-free helpers for reasoning about the playback queue.
///
/// The live queue is owned by libmpv (through media_kit) and mirrored into
/// `AudioPlayerState.tracks`. Nothing in this file touches the player: every
/// function takes plain lists/indexes and returns new values, so the ordering
/// rules can be unit-tested without a native player, a database or Flutter.
///
/// Conventions:
///  * Indexes are zero based and refer to the list *before* the operation.
///  * Inputs are never mutated; lists are returned as new, growable lists.
///  * Operations on a single index ([insertEntries], [moveEntry]) throw a
///    [RangeError] when the index is invalid, because that is a caller bug.
///    Operations on a set of indexes ([removeIndexes], [validIndexes]) ignore
///    indexes that are out of bounds.
library;

/// A half-open range `[start, end)` of positions inside a queue.
class QueueRange {
  final int start;
  final int end;

  const QueueRange(this.start, this.end)
    : assert(start >= 0, 'start must not be negative'),
      assert(end >= start, 'end must not be before start');

  /// Number of positions covered by the range.
  int get length => end - start;

  bool get isEmpty => length == 0;

  bool contains(int index) => index >= start && index < end;

  @override
  bool operator ==(Object other) =>
      other is QueueRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'QueueRange($start, $end)';
}

/// Returns [indexes] sorted ascending, without duplicates, keeping only
/// positions that exist in a queue of [length] entries.
List<int> validIndexes(Iterable<int> indexes, int length) {
  return indexes.where((i) => i >= 0 && i < length).toSet().toList()..sort();
}

/// Positions of every item matching [test], in ascending order.
///
/// Unlike `indexWhere`, this returns *all* matches, so queues that contain the
/// same track more than once are handled.
List<int> indexesWhere<T>(List<T> items, bool Function(T item) test) {
  return [
    for (var i = 0; i < items.length; i++)
      if (test(items[i])) i,
  ];
}

/// Groups [indexes] into maximal runs of consecutive positions.
///
/// The input may be unsorted and may contain duplicates; negative indexes are
/// ignored. `[4, 1, 2, 2, 7, 5]` becomes `[1, 3)`, `[4, 6)` and `[7, 8)`.
List<QueueRange> contiguousRanges(Iterable<int> indexes) {
  final sorted = indexes.where((i) => i >= 0).toSet().toList()..sort();
  if (sorted.isEmpty) return const [];

  final ranges = <QueueRange>[];
  var start = sorted.first;
  var previous = start;

  for (final index in sorted.skip(1)) {
    if (index != previous + 1) {
      ranges.add(QueueRange(start, previous + 1));
      start = index;
    }
    previous = index;
  }
  ranges.add(QueueRange(start, previous + 1));

  return ranges;
}

/// Whether [indexes] form exactly one unbroken run of positions.
///
/// An empty set is not contiguous.
bool isContiguous(Iterable<int> indexes) {
  return contiguousRanges(indexes).length == 1;
}

/// Inserts [entries] so that the first one ends up at [index].
///
/// [index] may be `items.length` to append. The result is identical to
/// inserting the entries one by one at `index`, `index + 1`, ... which is how
/// the live player is fed.
List<T> insertEntries<T>(List<T> items, int index, Iterable<T> entries) {
  RangeError.checkValueInInterval(index, 0, items.length, 'index');
  return [...items]..insertAll(index, entries);
}

/// Returns [items] without the entries at [indexes].
///
/// Duplicate and out-of-bounds indexes are ignored.
List<T> removeIndexes<T>(List<T> items, Iterable<int> indexes) {
  final toRemove = validIndexes(indexes, items.length).toSet();
  return [
    for (var i = 0; i < items.length; i++)
      if (!toRemove.contains(i)) items[i],
  ];
}

/// The order in which [indexes] must be applied to a *live* list so that
/// removing one entry does not shift the positions of the ones still to go:
/// valid, unique and descending.
List<int> removalOrder(Iterable<int> indexes, int length) {
  return validIndexes(indexes, length).reversed.toList();
}

/// Whether the app should forward a move of [from] to [to] to the player.
///
/// This is the guard `AudioPlayerNotifier.moveTrack` has always applied: both
/// positions must be existing entries and must differ. It is intentionally
/// stricter than [moveEntry], which also accepts `to == length` (move to the
/// very end).
bool canMoveEntry(int length, int from, int to) {
  return from != to && from >= 0 && to >= 0 && from < length && to < length;
}

/// Moves the entry at [from] so that it is placed *before* the entry that is
/// currently at [to]. [to] may be `items.length` to move to the very end.
///
/// These are the semantics of mpv's `playlist-move`, of media_kit's
/// `Player.move` and of Flutter's `ReorderCallback`'s `newIndex`:
/// [to] names the *target entry*, not the final position. Moving forward
/// (`from < to`) therefore lands at `to - 1`; moving backward lands at `to`.
List<T> moveEntry<T>(List<T> items, int from, int to) {
  RangeError.checkValidIndex(from, items, 'from');
  RangeError.checkValueInInterval(to, 0, items.length, 'to');

  final result = [...items];
  final entry = result.removeAt(from);
  result.insert(from < to ? to - 1 : to, entry);
  return result;
}

/// Rebuilds the order of [items] to follow [orderedKeys].
///
/// Used to mirror the player's playlist order (after a shuffle or a move) back
/// onto the app's own track objects: for every key, in order, the item with
/// that key is emitted.
///
/// Known limitation (kept on purpose, see `AudioPlayerNotifier`): items are
/// matched by key only. When several items share a key, every occurrence of
/// that key resolves to the *first* such item. Keys without a matching item
/// are skipped, and items whose key never appears are dropped.
List<T> reorderByKeys<T, K>(
  List<T> items,
  Iterable<K> orderedKeys,
  K Function(T item) keyOf,
) {
  final firstByKey = <K, T>{};
  for (final item in items) {
    firstByKey.putIfAbsent(keyOf(item), () => item);
  }

  return [
    for (final key in orderedKeys)
      if (firstByKey.containsKey(key)) firstByKey[key] as T,
  ];
}
