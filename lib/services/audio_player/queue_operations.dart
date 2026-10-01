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
///
/// Queue entry identity: a track can be in the queue more than once, so the
/// track id cannot tell two occurrences apart. A [QueueEntry] pairs a track
/// with an id that belongs to that *occurrence* alone. The helpers above work
/// on any list, so they apply to `List<QueueEntry<T>>` unchanged and the
/// identity travels with the entry through moves, insertions and removals.
library;

import 'dart:collection';
import 'dart:math';

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

/// Where "play next" puts tracks in a queue of [length] entries whose playing
/// position is [currentIndex]: right after the playing one. With nothing
/// playing it is after the first entry, and it is never past the end.
int playNextIndex(int length, int currentIndex) {
  return min(max(currentIndex, 0) + 1, length);
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

/// Produces an identity that has never been handed out before.
typedef QueueEntryIdGenerator = String Function();

/// One occurrence of a track in the queue.
///
/// [id] identifies the *occurrence*, never the track: two copies of the same
/// track are two entries with different ids. It is unrelated to the track id
/// and to any grouping, and it never changes while the entry stays in the
/// queue, whatever happens to its position.
class QueueEntry<T> {
  final String id;
  final T track;

  const QueueEntry(this.id, this.track);

  @override
  bool operator ==(Object other) =>
      other is QueueEntry<T> && other.id == id && other.track == track;

  @override
  int get hashCode => Object.hash(id, track);

  @override
  String toString() => 'QueueEntry($id, $track)';
}

/// Wraps every track in a new entry with a fresh identity from [nextId],
/// keeping the order of [tracks].
List<QueueEntry<T>> createEntries<T>(
  Iterable<T> tracks,
  QueueEntryIdGenerator nextId,
) {
  return [for (final track in tracks) QueueEntry(nextId(), track)];
}

/// Pairs [tracks] and [ids] that are stored as two parallel lists.
///
/// Throws an [ArgumentError] when the lists differ in length, as that means
/// the identities no longer describe the tracks.
List<QueueEntry<T>> pairEntries<T>(List<T> tracks, List<String> ids) {
  if (tracks.length != ids.length) {
    throw ArgumentError(
      'Cannot pair ${tracks.length} tracks with ${ids.length} entry ids',
    );
  }
  return [
    for (var i = 0; i < tracks.length; i++) QueueEntry(ids[i], tracks[i]),
  ];
}

/// Whether no two [entries] share an id.
bool hasUniqueEntryIds(Iterable<QueueEntry<Object?>> entries) {
  final ids = <String>{};
  return entries.every((entry) => ids.add(entry.id));
}

/// Position of the entry with [entryId], or `-1` when it is not in [entries].
int indexOfEntry<T>(List<QueueEntry<T>> entries, String entryId) {
  return entries.indexWhere((entry) => entry.id == entryId);
}

/// Rebuilds the order of [entries] to follow [orderedKeys], the keys of the
/// queue as the player reports it.
///
/// Used to mirror the player's playlist order (after a shuffle or any other
/// change the player made on its own) back onto the app's entries. Entries are
/// matched by `keyOf(entry.track)`, and every entry is used at most once: the
/// n-th time a key shows up in [orderedKeys] it claims the n-th entry that has
/// that key. Copies of the same track therefore stay separate entries, keep
/// their ids, and keep their order relative to each other.
///
/// Keys without a matching entry are skipped; entries whose key does not
/// appear (often enough) in [orderedKeys] are dropped.
///
/// The player only sees keys, so it cannot report *which* copy of a track it
/// moved. Moves the app makes itself must be applied to the entries first (see
/// [moveEntry]) so that this function only has to confirm them.
List<QueueEntry<T>> reconcileEntries<T, K>(
  List<QueueEntry<T>> entries,
  Iterable<K> orderedKeys,
  K Function(T track) keyOf,
) {
  final pending = <K, Queue<QueueEntry<T>>>{};
  for (final entry in entries) {
    pending.putIfAbsent(keyOf(entry.track), Queue.new).add(entry);
  }

  final result = <QueueEntry<T>>[];
  for (final key in orderedKeys) {
    final candidates = pending[key];
    if (candidates != null && candidates.isNotEmpty) {
      result.add(candidates.removeFirst());
    }
  }
  return result;
}
