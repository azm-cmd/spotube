/// Keeps the player's playlist in step with a [GroupedQueue].
///
/// The player (libmpv through media_kit) holds the real playback queue. A group
/// operation first works out the queue it wants as a [GroupedQueue]; this file
/// then makes the player follow, without restarting playback, and reports the
/// confirmed result. Everything here is plain Dart: the player is reached only
/// through [QueuePlayerPort], so the logic can be tested with a fake.
///
/// How a reorder reaches the player:
///  1. [planReorder] turns "this order" into the fewest `playlist-move`
///     commands. The plan is computed on entry ids by simulating each move with
///     the player's own semantics, so the *physical* playlist entry that is
///     moved is always the one the entry id stands for. That is what keeps
///     copies of the same track apart: the player never has to tell them apart.
///  2. The commands are sent one by one while [GroupedQueueSync.isApplying] is
///     true. media_kit reports every intermediate order, and those must not be
///     mirrored back into the app's state.
///  3. The player's order is read back and compared with what was asked for.
///     If it matches, the requested queue (with its groups and entry ids) is
///     committed; if it does not, the app follows the player and groups adapt
///     ([GroupedQueue.followPlayer]).
///
/// The playing track is never stopped: moving a playlist entry does not touch
/// playback, and the playing entry is tracked by id, so the playing position
/// ([QueueSnapshot.currentIndex]) is recomputed from where that entry ends up.
library;

import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';

/// One `playlist-move`: take the entry at [from] and put it before the entry
/// currently at [to] (`to` may be the length). Same convention as [moveEntry].
class QueueMove {
  final int from;
  final int to;

  const QueueMove(this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is QueueMove && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'QueueMove($from -> $to)';
}

/// The fewest moves that turn the order [current] into [target].
///
/// Both are lists of unique ids holding the same ids. The entries that already
/// appear in the right relative order (a longest increasing subsequence) stay
/// put; every other entry is moved once, to just after the entry that precedes
/// it in [target]. Applying the moves in order with [moveEntry] gives [target].
///
/// Throws an [ArgumentError] if the two lists are not permutations of each
/// other.
List<QueueMove> planReorder(List<String> current, List<String> target) {
  if (current.length != target.length ||
      current.toSet().length != current.length ||
      target.toSet().length != target.length ||
      !current.toSet().containsAll(target)) {
    throw ArgumentError(
      'planReorder needs two orders of the same unique ids '
      '(current: $current, target: $target)',
    );
  }

  final targetPosition = {
    for (var i = 0; i < target.length; i++) target[i]: i,
  };
  final stays = {
    for (final i in _longestIncreasingRun(
      [for (final id in current) targetPosition[id]!],
    ))
      current[i],
  };

  var working = [...current];
  final moves = <QueueMove>[];
  String? previous;
  for (final id in target) {
    if (!stays.contains(id)) {
      final from = working.indexOf(id);
      final to = previous == null ? 0 : working.indexOf(previous) + 1;
      if (from != to) {
        moves.add(QueueMove(from, to));
        working = moveEntry(working, from, to);
      }
    }
    previous = id;
  }

  assert(
    _sameSequence(working, target),
    'planReorder produced $working instead of $target',
  );
  return moves;
}

/// Indexes of one longest strictly increasing subsequence of [values], which
/// must all be different.
List<int> _longestIncreasingRun(List<int> values) {
  final tails = <int>[]; // tails[k]: index of the best end of a run of k + 1
  final before = List<int>.filled(values.length, -1);

  for (var i = 0; i < values.length; i++) {
    var low = 0;
    var high = tails.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (values[tails[middle]] < values[i]) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    before[i] = low > 0 ? tails[low - 1] : -1;
    if (low == tails.length) {
      tails.add(i);
    } else {
      tails[low] = i;
    }
  }

  final run = <int>[];
  for (var i = tails.isEmpty ? -1 : tails.last; i != -1; i = before[i]) {
    run.add(i);
  }
  return run.reversed.toList();
}

/// Whether two queues hold the same entries in the same order.
bool sameEntryOrder<T>(List<QueueEntry<T>> a, List<QueueEntry<T>> b) {
  return _sameSequence([for (final e in a) e.id], [for (final e in b) e.id]);
}

bool _sameSequence(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What [GroupedQueueSync] needs from the player.
abstract class QueuePlayerPort {
  /// `playlist-move`: see [QueueMove].
  Future<void> moveTrack(int from, int to);

  /// `playlist-remove`.
  Future<void> removeTrack(int index);

  /// The key of every playlist entry, in the player's order. For a track this
  /// is what the app compares against [GroupedQueueSync.keyOf]; copies of one
  /// track have the same key.
  List<String> get playlistKeys;

  /// Position of the playing entry in the player's playlist, as the player
  /// last reported it. A report can still be on its way.
  int get currentIndex;

  /// Asks the player where it is now (`-1` if nowhere). Unlike [currentIndex]
  /// this is the answer of the player itself, after every command sent so far.
  Future<int> queryPlayingIndex();
}

/// A queue together with the position of the playing entry in it.
class QueueSnapshot<T> {
  final GroupedQueue<T> queue;
  final int currentIndex;

  const QueueSnapshot(this.queue, this.currentIndex);

  /// The id of the playing entry, or `null` when nothing valid is playing.
  String? get currentEntryId {
    if (currentIndex < 0 || currentIndex >= queue.entries.length) return null;
    return queue.entries[currentIndex].id;
  }
}

/// Applies [GroupedQueue] changes to the player and mirrors the player back.
class GroupedQueueSync<T> {
  final QueuePlayerPort port;

  /// The key under which the player knows a track.
  final String Function(T track) keyOf;

  GroupedQueueSync({required this.port, required this.keyOf});

  int _applying = 0;
  Future<void> _tail = Future<void>.value();

  /// Whether a reorder is being sent to the player right now. While it is,
  /// playlist reports from the player are intermediate and must be ignored.
  bool get isApplying => _applying > 0;

  /// Runs [body] after every earlier [exclusive] call has finished, so two
  /// queue changes can never interleave their player commands.
  Future<R> exclusive<R>(Future<R> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Where the player is now: asked, so that a report still on its way, or
  /// one that was ignored while a change was being sent, cannot leave the app
  /// with an old position. Falls back to the last report if it can not answer.
  Future<int> _playerPosition() async {
    try {
      return await port.queryPlayingIndex();
    } catch (_) {
      return port.currentIndex;
    }
  }

  /// [snapshot] with the playing position the player has now.
  ///
  /// A change starts from this, not from the app's last known position: the
  /// track may have ended by itself a moment ago, with the report still on its
  /// way. (Only meaningful while the player holds exactly this queue.)
  Future<QueueSnapshot<T>> current(QueueSnapshot<T> snapshot) async {
    if (port.playlistKeys.length != snapshot.queue.entries.length) {
      return snapshot;
    }
    final at = await _playerPosition();
    if (at < 0 ||
        at >= snapshot.queue.entries.length ||
        at == snapshot.currentIndex) {
      return snapshot;
    }
    return QueueSnapshot(snapshot.queue, at);
  }

  /// After a change: if the player plays another entry than [shown], the track
  /// ended by itself while the change was being sent (its report was ignored
  /// like the others). The player is the truth for what plays.
  Future<void> _followPlayer(
    QueueSnapshot<T> shown,
    void Function(QueueSnapshot<T> confirmed) commit,
  ) async {
    final at = await _playerPosition();
    if (at < 0 ||
        at >= shown.queue.entries.length ||
        at == shown.currentIndex) {
      return;
    }
    commit(QueueSnapshot(shown.queue, at));
  }

  /// Makes the player follow [target], which is [from] after a group operation.
  ///
  /// [commit] receives the confirmed queue. It is called synchronously and
  /// before the player's reports are listened to again, so the app never sees
  /// a half-applied queue.
  ///
  ///  * Only groups changed: the player is not touched.
  ///  * Same entries, new order: moved with [planReorder]; [commit] runs once
  ///    the player has them in place.
  ///  * Fewer entries: [commit] runs first, like the existing removal code,
  ///    then the entries are removed from the player back to front.
  ///
  /// Anything else (entries added, or a removal that also reorders) is a
  /// programming error and throws an [ArgumentError].
  Future<void> apply(
    QueueSnapshot<T> from,
    GroupedQueue<T> target, {
    required void Function(QueueSnapshot<T> confirmed) commit,
  }) async {
    final fromIds = _ids(from.queue.entries);
    final targetIds = _ids(target.entries);
    final playingId = from.currentEntryId;

    if (_sameSequence(fromIds, targetIds)) {
      commit(QueueSnapshot(target, from.currentIndex));
      return;
    }

    if (fromIds.length == targetIds.length) {
      await _reorder(from, target, fromIds, targetIds, playingId, commit);
      return;
    }

    await _remove(from, target, fromIds, targetIds, playingId, commit);
  }

  /// Adds [added] (new, loose entries) to the queue at [index] and to the
  /// player, without touching the entries that are already there.
  ///
  /// [index] is where the entries should go; if that is inside a group it
  /// becomes the position right after the group (see
  /// [GroupedQueue.insertUngrouped]), so a group is never split. The added
  /// entries keep their order and sit next to each other.
  ///
  /// [send] puts one entry into the player at its final position; `append` is
  /// true when that position is the end of the player's playlist. Entries are
  /// sent from the front, so every position is final when it is used.
  ///
  /// Like a removal, [commit] runs first: the queue is shown with the new
  /// entries at once, the playing entry is the same entry, and the player's
  /// reports while the entries are on their way (shorter than the queue) are
  /// ignored. If the player ends up with something else, it is the truth.
  Future<void> insert(
    QueueSnapshot<T> from,
    int index,
    List<QueueEntry<T>> added, {
    required Future<void> Function(
      int index,
      QueueEntry<T> entry, {
      required bool append,
    }) send,
    required void Function(QueueSnapshot<T> confirmed) commit,
  }) async {
    if (added.isEmpty) return;

    final target = from.queue.insertUngrouped(index, added);
    final targetIds = _ids(target.entries);
    final addedIds = {for (final entry in added) entry.id};
    final playingId = from.currentEntryId;

    final playingAt = playingId == null ? -1 : targetIds.indexOf(playingId);
    final committed = QueueSnapshot(
      target,
      playingAt == -1 ? from.currentIndex : playingAt,
    );
    commit(committed);

    _applying++;
    try {
      Object? failure;
      StackTrace? failureStack;
      try {
        var length = from.queue.entries.length;
        for (var i = 0; i < target.entries.length; i++) {
          if (!addedIds.contains(target.entries[i].id)) continue;
          await send(i, target.entries[i], append: i == length);
          length++;
        }
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }

      final targetKeys = [for (final e in target.entries) keyOf(e.track)];
      final playerKeys = port.playlistKeys;
      final inStep = failure == null && _sameSequence(playerKeys, targetKeys);
      if (!inStep) {
        // The player is not where it was asked to be: it is the truth.
        commit(mirror(committed, playerKeys, await _playerPosition()));
      }

      // Let reports that are already on their way arrive while still guarded.
      await Future<void>.delayed(Duration.zero);
      if (inStep) await _followPlayer(committed, commit);

      if (failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
    } finally {
      _applying--;
    }
  }

  /// Replaces the player's playlist item of the playing entry by a fresh one,
  /// without changing the queue: the entry keeps its id, its place and its
  /// group. [swap] sends the player commands (the new item goes in right after
  /// the playing one, playback moves on to it, the old item is removed).
  ///
  /// The player's reports while that happens (one item too many) are ignored.
  /// If the player ends up with a different order or playing position, it is
  /// the truth.
  Future<void> swapInPlace(
    QueueSnapshot<T> from, {
    required Future<void> Function(int playingIndex) swap,
    required void Function(QueueSnapshot<T> confirmed) commit,
  }) async {
    _applying++;
    try {
      Object? failure;
      StackTrace? failureStack;
      try {
        await swap(from.currentIndex);
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }

      final keys = [for (final e in from.queue.entries) keyOf(e.track)];
      final playerKeys = port.playlistKeys;
      final position = await _playerPosition();
      final inStep = failure == null && _sameSequence(playerKeys, keys);
      if (!inStep) {
        commit(mirror(from, playerKeys, position));
      } else if (position >= 0 &&
          position < keys.length &&
          position != from.currentIndex) {
        // Playback is on another entry than the one that was swapped.
        commit(QueueSnapshot(from.queue, position));
      }

      await Future<void>.delayed(Duration.zero);

      if (failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
    } finally {
      _applying--;
    }
  }

  Future<void> _reorder(
    QueueSnapshot<T> from,
    GroupedQueue<T> target,
    List<String> fromIds,
    List<String> targetIds,
    String? playingId,
    void Function(QueueSnapshot<T>) commit,
  ) async {
    final plan = planReorder(fromIds, targetIds);

    _applying++;
    try {
      Object? failure;
      StackTrace? failureStack;
      try {
        for (final move in plan) {
          await port.moveTrack(move.from, move.to);
        }
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }

      final targetKeys = [for (final e in target.entries) keyOf(e.track)];
      final playerKeys = port.playlistKeys;

      final inStep = failure == null && _sameSequence(playerKeys, targetKeys);
      QueueSnapshot<T>? shown;
      if (inStep) {
        final index = playingId == null ? -1 : targetIds.indexOf(playingId);
        shown = QueueSnapshot(target, index == -1 ? from.currentIndex : index);
        commit(shown);
      } else {
        // The player is not where it was asked to be: it is the truth. Entries
        // are matched against the order the app had, as nothing else is known.
        commit(mirror(
          failure == null ? QueueSnapshot(target, from.currentIndex) : from,
          playerKeys,
          await _playerPosition(),
        ));
      }

      // Let reports that are already on their way arrive while still guarded.
      await Future<void>.delayed(Duration.zero);
      if (shown != null) await _followPlayer(shown, commit);

      if (failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
    } finally {
      _applying--;
    }
  }

  Future<void> _remove(
    QueueSnapshot<T> from,
    GroupedQueue<T> target,
    List<String> fromIds,
    List<String> targetIds,
    String? playingId,
    void Function(QueueSnapshot<T>) commit,
  ) async {
    final removed = fromIds.toSet().difference(targetIds.toSet());
    final remaining = [
      for (final id in fromIds)
        if (!removed.contains(id)) id,
    ];
    if (!_sameSequence(remaining, targetIds)) {
      throw ArgumentError(
        'A change that shortens the queue may only remove entries '
        '(from: $fromIds, target: $targetIds)',
      );
    }

    final indexes = removalOrder(
      indexesWhere(from.queue.entries, (e) => removed.contains(e.id)),
      fromIds.length,
    );

    final keptAt = playingId == null ? -1 : targetIds.indexOf(playingId);
    final committed = QueueSnapshot(
      target,
      keptAt != -1
          ? keptAt
          : min(max(from.currentIndex, 0), max(targetIds.length - 1, 0)),
    );
    commit(committed);

    // Intermediate reports are longer than the committed queue, so they are
    // ignored by length; the last one confirms it. They are ignored outright
    // while the commands are sent, like for the other changes.
    _applying++;
    try {
      Object? failure;
      StackTrace? failureStack;
      try {
        for (final index in indexes) {
          await port.removeTrack(index);
        }
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }

      final targetKeys = [for (final e in target.entries) keyOf(e.track)];
      final playerKeys = port.playlistKeys;
      final inStep = failure == null && _sameSequence(playerKeys, targetKeys);
      if (!inStep) {
        // The player is not where it was asked to be: it is the truth. Entries
        // are matched against the queue from before, which still has the ones
        // the player did not manage to remove.
        commit(mirror(from, playerKeys, await _playerPosition()));
      }

      await Future<void>.delayed(Duration.zero);
      if (inStep) await _followPlayer(committed, commit);

      if (failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
    } finally {
      _applying--;
    }
  }

  /// The queue to show for a playlist report from the player: [base]'s entries
  /// in the order the player reports, groups adapted, [playerIndex] playing.
  ///
  /// Copies of the same track are told apart by consuming [base]'s entries in
  /// order (see [reconcileEntries]), so none is merged into another.
  QueueSnapshot<T> mirror(
    QueueSnapshot<T> base,
    List<String> playerKeys,
    int playerIndex,
  ) {
    final entries = reconcileEntries(base.queue.entries, playerKeys, keyOf);
    return QueueSnapshot(base.queue.followPlayer(entries), playerIndex);
  }

  /// What to show for a playlist report that arrived on its own, or `null` if
  /// it should be ignored: a reorder is in progress, or the report is not about
  /// a queue of the same length (a multi-step change is still half-way).
  QueueSnapshot<T>? onPlayerPlaylist(
    QueueSnapshot<T> current,
    List<String> playerKeys,
    int playerIndex,
  ) {
    if (isApplying || playerKeys.length != current.queue.entries.length) {
      return null;
    }
    return mirror(current, playerKeys, playerIndex);
  }

  List<String> _ids(List<QueueEntry<T>> entries) => [
        for (final entry in entries) entry.id,
      ];
}
