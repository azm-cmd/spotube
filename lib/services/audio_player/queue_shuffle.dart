/// Shuffling a queue that may contain groups.
///
/// mpv's own shuffle (`playlist-shuffle`) mixes every playlist entry, so on a
/// queue with groups it would tear the groups apart. When a queue has groups
/// the shuffle is therefore done here, in Dart, on [GroupedQueue.items]:
///
///  * a group is one unit and a loose entry is one unit;
///  * the units are put in a random order, and the entries inside a group
///    never change order;
///  * the result is handed to [GroupedQueueSync], which makes the player follow
///    without touching the playing track.
///
/// A queue without groups is left to mpv exactly as before.
///
/// [QueueShuffler] decides which of the two does the work, and is the one place
/// that may ask mpv for its flat shuffle. It owns the "shuffled" state the rest
/// of the app sees while the shuffle is done in Dart, and the order to go back
/// to when the shuffle is switched off.
library;

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';

/// A random permutation of `0..count-1`, by Fisher-Yates.
///
/// [nextInt] has the shape of `Random.nextInt`: `nextInt(bound)` returns a
/// value in `0..bound-1`. Passing a scripted function makes the result exact.
List<int> shuffledOrder(int count, int Function(int bound) nextInt) {
  final order = [for (var i = 0; i < count; i++) i];
  for (var i = count - 1; i > 0; i--) {
    final j = nextInt(i + 1);
    RangeError.checkValueInInterval(j, 0, i, 'nextInt(${i + 1})');
    final held = order[i];
    order[i] = order[j];
    order[j] = held;
  }
  return order;
}

/// [queue] with its top-level rows (loose entries and whole groups) in a
/// random order. Groups stay contiguous and keep their members in order; every
/// entry and every group is kept exactly once.
GroupedQueue<T> shuffleQueue<T>(
  GroupedQueue<T> queue,
  int Function(int bound) nextInt,
) {
  return queue.reorderItems(shuffledOrder(queue.items.length, nextInt));
}

/// Undoes a shuffle: puts the top-level rows of [queue] back in the order of
/// [originalOrder], the entry ids as they were before the shuffle.
///
/// A loose entry goes where it was; a group goes where its earliest known
/// member was. Rows with no known entry (added after the shuffle) follow, in
/// the order they have now. Entries that are gone are ignored. Rows move as
/// wholes, so no group is split and no group's members change order.
GroupedQueue<T> unshuffleQueue<T>(
  GroupedQueue<T> queue,
  List<String> originalOrder,
) {
  final position = <String, int>{};
  for (var i = 0; i < originalOrder.length; i++) {
    position.putIfAbsent(originalOrder[i], () => i);
  }

  final known = <(int position, int row)>[];
  final unknown = <int>[];
  final rows = queue.items;
  for (var row = 0; row < rows.length; row++) {
    final ids = switch (rows[row]) {
      EntryItem<T>(:final entry) => [entry.id],
      GroupItem<T>(:final entries) => [for (final e in entries) e.id],
    };
    int? earliest;
    for (final id in ids) {
      final at = position[id];
      if (at != null && (earliest == null || at < earliest)) earliest = at;
    }
    if (earliest == null) {
      unknown.add(row);
    } else {
      known.add((earliest, row));
    }
  }
  known.sort((a, b) => a.$1.compareTo(b.$1));

  return queue.reorderItems([for (final (_, row) in known) row, ...unknown]);
}

/// What [QueueShuffler] needs from the player.
abstract class ShufflePort {
  /// Whether the app currently reports the queue as shuffled. This is what the
  /// lock screen, tray, Connect and the controls show.
  bool get isShuffled;

  /// mpv's own shuffle flag. It can differ from [isShuffled] while the shuffle
  /// is done in Dart.
  bool get isFlatShuffled;

  /// mpv's flat shuffle (`playlist-shuffle` / `playlist-unshuffle`) of the
  /// whole playlist. Only [QueueShuffler] calls this, and never for a queue
  /// with groups.
  Future<void> setFlatShuffle(bool shuffle);

  /// Reports [shuffled] as the shuffle state, whatever mpv's flag says.
  void publishShuffle(bool shuffled);

  /// Goes back to reporting mpv's own flag.
  void releaseShuffle();
}

/// Carries out shuffle requests, choosing between mpv and Dart.
class QueueShuffler<T> {
  final GroupedQueueSync<T> sync;
  final ShufflePort port;

  /// `Random.nextInt`, or a scripted stand-in.
  final int Function(int bound) nextInt;

  QueueShuffler({
    required this.sync,
    required this.port,
    required this.nextInt,
  });

  /// Whether the current shuffle was done in Dart.
  bool _doneInDart = false;

  /// The entry ids, in queue order, from before the Dart shuffle.
  List<String>? _orderBeforeShuffle;

  /// Switches shuffle on or off. [read] gives the current queue and [commit]
  /// receives the confirmed one after a Dart shuffle.
  ///
  /// Returns `true` when the queue order was changed in Dart (so the caller
  /// should save it); `false` when mpv did the work or nothing needed doing.
  ///
  ///  * Already in the requested state: nothing happens, as with mpv alone.
  ///  * The queue has groups: Dart shuffles (or restores) it. mpv's flat
  ///    shuffle is never called.
  ///  * No groups, and the shuffle was not done in Dart: mpv does it, exactly
  ///    as it always has.
  ///  * No groups left, but the shuffle was done in Dart: switching it off
  ///    still restores the remembered order in Dart.
  Future<bool> setShuffle(
    bool shuffle, {
    required QueueSnapshot<T> Function() read,
    required void Function(QueueSnapshot<T> confirmed) commit,
  }) {
    return sync.exclusive(() async {
      if (shuffle == port.isShuffled) return false;

      final from = read();
      final hasGroups = from.queue.groups.isNotEmpty;
      final inDart = shuffle ? hasGroups : (hasGroups || _doneInDart);

      if (!inDart) {
        await _flat(shuffle);
        return false;
      }
      await _inDart(shuffle, from, commit);
      return true;
    });
  }

  /// A new queue replaced the old one, or playback was stopped: whatever was
  /// remembered about the shuffle no longer applies, and the state reported is
  /// mpv's own again.
  void reset() {
    _doneInDart = false;
    _orderBeforeShuffle = null;
    port.releaseShuffle();
  }

  Future<void> _flat(bool shuffle) async {
    // After a shuffle done in Dart, mpv's flag can still be set from an earlier
    // flat shuffle. mpv ignores "on" when its flag is already on, so clear it
    // first. (There are no groups here, so mpv restoring its order is safe.)
    if (shuffle && port.isFlatShuffled) await port.setFlatShuffle(false);

    await port.setFlatShuffle(shuffle);
    _doneInDart = false;
    _orderBeforeShuffle = null;
    port.releaseShuffle();
  }

  Future<void> _inDart(
    bool shuffle,
    QueueSnapshot<T> from,
    void Function(QueueSnapshot<T>) commit,
  ) async {
    final remembered = _orderBeforeShuffle;
    final GroupedQueue<T> target;
    if (shuffle) {
      target = shuffleQueue(from.queue, nextInt);
    } else {
      target = remembered == null
          ? from.queue
          : unshuffleQueue(from.queue, remembered);
    }

    // Only remember the old order once the shuffle has really been applied.
    await sync.apply(from, target, commit: commit);

    _doneInDart = shuffle;
    _orderBeforeShuffle =
        shuffle ? [for (final e in from.queue.entries) e.id] : null;
    port.publishShuffle(shuffle);
    // mpv's flag is only handed back when it agrees; if an earlier flat shuffle
    // left it on, reporting it would make a switched-off shuffle look on again.
    if (!shuffle && !port.isFlatShuffled) port.releaseShuffle();
  }
}
