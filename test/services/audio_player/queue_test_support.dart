import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_shuffle.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

// Shared by the queue sync and shuffle tests: a stand-in for libmpv and the app
// side that talks to it.

class TestTrack {
  final String id;
  const TestTrack(this.id);

  @override
  String toString() => id;
}

typedef TestQueue = GroupedQueue<TestTrack>;

/// One playlist entry inside the fake player. The player only ever sees [key]
/// (the track id, so copies of a track look identical to it); [entryId] is
/// the app's identity, kept here so tests can check the right *physical* entry
/// ended up in the right place.
class FakeSlot {
  final String entryId;
  final String key;
  FakeSlot(this.entryId, this.key);
}

/// A stand-in for libmpv + media_kit.
///
///  * `playlist-move` has mpv's meaning: take the entry at `from` and put it
///    before the entry currently at `to` (`to` may be the length).
///  * The playing position follows the playing *entry*, not an index.
///  * Like media_kit it reports the whole playlist after every command, from
///    inside the command.
class FakeMpv implements QueuePlayerPort {
  FakeMpv(List<QueueEntry<TestTrack>> entries)
      : playlist = [for (final e in entries) FakeSlot(e.id, e.track.id)];

  final List<FakeSlot> playlist;
  FakeSlot? playing;

  /// Called after every change, like media_kit's playlist stream.
  void Function()? onReport;

  /// Every command received, in order, e.g. `move 3 1` or `remove 4`.
  final commands = <String>[];

  /// Pretend a `playlist-move` succeeded without doing anything.
  bool ignoreMoves = false;

  /// Awaited before every command is carried out: a test holds the player
  /// here to put other changes in the queue behind the one in flight, or to
  /// make commands take different times.
  Future<void> Function(String command)? gate;

  int _moves = 0;
  int? _failAtMove;

  /// Throw on the [n]-th `playlist-move` from now on (1 = the next one).
  void failMoveNumber(int n) => _failAtMove = _moves + n;

  void stopFailing() => _failAtMove = null;

  /// The truth: the app's entry id of every physical entry, in order.
  List<String> get physicalEntryIds => [for (final s in playlist) s.entryId];

  @override
  List<String> get playlistKeys => [for (final s in playlist) s.key];

  /// The entry that was playing when the player last reported to the app.
  FakeSlot? _reportedPlaying;

  void _report() {
    _reportedPlaying = playing;
    onReport?.call();
  }

  /// What the app last heard (like media_kit's own copy of the position): it
  /// lags behind [playing] while a report is on its way.
  @override
  int get currentIndex {
    final slot = _reportedPlaying != null && playlist.contains(_reportedPlaying)
        ? _reportedPlaying
        : playing;
    return slot == null ? -1 : playlist.indexOf(slot);
  }

  /// The player's own answer: where it plays now, whatever the app has heard.
  @override
  Future<int> queryPlayingIndex() async =>
      playing == null ? -1 : playlist.indexOf(playing!);

  @override
  Future<void> moveTrack(int from, int to) async {
    await gate?.call('move $from $to');
    commands.add('move $from $to');
    _moves++;
    if (_failAtMove == _moves) throw StateError('mpv refused the move');
    if (!ignoreMoves) {
      RangeError.checkValidIndex(from, playlist, 'from');
      RangeError.checkValueInInterval(to, 0, playlist.length, 'to');
      final slot = playlist.removeAt(from);
      playlist.insert(from < to ? to - 1 : to, slot);
    }
    _report();
  }

  @override
  Future<void> removeTrack(int index) async {
    await gate?.call('remove $index');
    commands.add('remove $index');
    _removes++;
    if (_failAtRemove == _removes) throw StateError('mpv refused the remove');
    final slot = playlist.removeAt(index);
    if (slot == playing) {
      playing =
          playlist.isEmpty ? null : playlist[min(index, playlist.length - 1)];
    }
    _report();
  }

  int _removes = 0;
  int? _failAtRemove;

  /// Throw on the [n]-th remove from now on (1 = the next one).
  void failRemoveNumber(int n) => _failAtRemove = _removes + n;

  int _inserts = 0;
  int? _failAtInsert;

  /// Throw on the [n]-th insert from now on (1 = the next one).
  void failInsertNumber(int n) => _failAtInsert = _inserts + n;

  /// `loadfile ... insert-at` / `append`: the entry goes before the one at
  /// [index] (the length appends). The playing entry stays the playing entry.
  Future<void> insertTrack(
    int index,
    QueueEntry<TestTrack> entry, {
    required bool append,
  }) async {
    // What the app asked for, not what it came to: appending is its own call.
    final command = append ? 'append' : 'insert $index';
    await gate?.call(command);
    commands.add(command);
    _inserts++;
    if (_failAtInsert == _inserts) throw StateError('mpv refused the insert');
    RangeError.checkValueInInterval(index, 0, playlist.length, 'index');
    playlist.insert(index, FakeSlot(entry.id, entry.track.id));
    playing ??= playlist.first;
    _report();
  }

  /// Like the real player, tell the app about a change of the playing entry a
  /// little later, not at once: for a few turns of the event loop the app
  /// still has the old position.
  bool delayedPlayingReports = false;

  /// The track ends by itself and the player goes on to the entry at [index].
  /// Like a jump, the app hears about it a little later when
  /// [delayedPlayingReports] is on.
  void advanceTo(int index) => jump(index);

  /// The user (or auto-advance) switches to another entry.
  void jump(int index) {
    playing = playlist[index];
    if (!delayedPlayingReports) {
      _report();
      return;
    }
    () async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      _report();
    }();
  }

  /// A change the app did not ask for, e.g. a shuffle done by the player.
  void externalReorder(List<String> entryIdOrder) {
    final byId = {for (final s in playlist) s.entryId: s};
    playlist
      ..clear()
      ..addAll([for (final id in entryIdOrder) byId[id]!]);
    _report();
  }
}

/// The app side: what AudioPlayerNotifier does with the player, minus Riverpod.
class QueueRig {
  QueueRig(List<String> trackIds, {int playing = 0}) {
    final entries = [
      for (var i = 0; i < trackIds.length; i++)
        QueueEntry('e${i + 1}', TestTrack(trackIds[i])),
    ];
    mpv = FakeMpv(entries);
    if (entries.isNotEmpty) mpv.playing = mpv.playlist[playing];
    _snapshot = QueueSnapshot(GroupedQueue.ungrouped(entries), playing);
    sync = GroupedQueueSync(port: mpv, keyOf: (TestTrack t) => t.id);
    mpv.onReport = deliverReport;
  }

  late final FakeMpv mpv;
  late final GroupedQueueSync<TestTrack> sync;
  late QueueSnapshot<TestTrack> _snapshot;

  /// The flat order of every queue the app has shown, in order: each time the
  /// app's queue is replaced, what it was replaced by is added here.
  final history = <List<String>>[];

  QueueSnapshot<TestTrack> get snapshot => _snapshot;

  set snapshot(QueueSnapshot<TestTrack> value) {
    _snapshot = value;
    history.add([for (final e in value.queue.entries) e.id]);
  }

  int reportsSeen = 0;
  int reportsIgnored = 0;

  /// The notifier's playlist listener.
  void deliverReport() {
    reportsSeen++;
    final next = sync.onPlayerPlaylist(
      snapshot,
      mpv.playlistKeys,
      mpv.currentIndex,
    );
    if (next == null) {
      reportsIgnored++;
    } else {
      snapshot = next;
    }
  }

  /// The notifier's way of adding tracks: [trackIds] become new entries
  /// (ids n1, n2, ...) at [index], or after the playing entry's group for
  /// "play next".
  Future<List<String>> insert(
    List<String> trackIds, {
    int? index,
    bool afterPlaying = false,
  }) {
    return sync.exclusive(() async {
      final from = await sync.current(snapshot);
      final length = from.queue.entries.length;
      final added = [
        for (final id in trackIds) QueueEntry('n${++_added}', TestTrack(id)),
      ];
      final at = index ??
          (afterPlaying ? playNextIndex(length, from.currentIndex) : length);
      await sync.insert(
        from,
        at,
        added,
        send: (i, entry, {required append}) =>
            mpv.insertTrack(i, entry, append: append),
        commit: (confirmed) => snapshot = confirmed,
      );
      return [for (final e in added) e.id];
    });
  }

  int _added = 0;

  /// The notifier's flat `moveTrack`: the entries are named now, the move
  /// waits its turn.
  Future<void> moveFlat(int oldIndex, int newIndex) {
    final entries = snapshot.queue.entries;
    if (!canMoveEntry(entries.length, oldIndex, newIndex)) {
      return Future<void>.value();
    }
    return moveBefore(
      entries[oldIndex].id,
      newIndex >= entries.length ? null : entries[newIndex].id,
    );
  }

  /// The move itself, for entries that are already named.
  Future<void> moveBefore(String movedId, String? beforeId) =>
      run((q) => q.moveEntryBefore(movedId, beforeId));

  /// The notifier's `jumpToEntry`.
  Future<void> jumpToEntry(String entryId) {
    return sync.exclusive(() async {
      final index = [for (final e in queue.entries) e.id].indexOf(entryId);
      if (index == -1) return;
      await mpv.gate?.call('jump $index');
      mpv.jump(index);
      // The app's queue says at once which entry plays.
      snapshot = QueueSnapshot(queue, index);
    });
  }

  /// The notifier's `swapActiveSource`: the player's item of the playing entry
  /// is replaced by a new one for the same entry.
  Future<void> swapActive() {
    return sync.exclusive(() async {
      final from = await sync.current(snapshot);
      final playingId = from.currentEntryId;
      if (playingId == null) return;
      final entry = from.queue.entries[from.currentIndex];
      await sync.swapInPlace(
        from,
        swap: (playingIndex) async {
          await mpv.insertTrack(playingIndex + 1, entry, append: false);
          mpv.jump(playingIndex + 1);
          await mpv.removeTrack(playingIndex);
        },
        commit: (confirmed) => snapshot = confirmed,
      );
    });
  }

  /// The notifier's `_changeGroups`.
  Future<void> run(TestQueue Function(TestQueue queue) change) {
    return sync.exclusive(() async {
      final from = await sync.current(snapshot);
      final target = change(from.queue);
      await sync.apply(from, target,
          commit: (confirmed) => snapshot = confirmed);
    });
  }

  TestQueue get queue => snapshot.queue;
  List<String> get flat => [for (final e in queue.entries) e.id];

  /// The invariant: app queue == group model == player playlist.
  void expectInSync({String? reason}) {
    expect(queue.validate(), isEmpty, reason: reason);
    expect(flat, mpv.physicalEntryIds,
        reason: 'app queue and player hold different entries ${reason ?? ''}');
    expect([for (final e in queue.entries) e.track.id], mpv.playlistKeys,
        reason: reason);
    expect(snapshot.currentIndex, mpv.currentIndex,
        reason: 'current index ${reason ?? ''}');
    if (mpv.playing != null) {
      expect(snapshot.currentEntryId, mpv.playing!.entryId,
          reason: 'playing entry ${reason ?? ''}');
    }
  }

  /// ['e1', 'G1[e2,e3]', ...]
  List<String> get shape => [
        for (final item in queue.items)
          switch (item) {
            EntryItem<TestTrack>(:final entry) => entry.id,
            GroupItem<TestTrack>(:final group) =>
              '${group.id}[${group.memberIds.join(',')}]',
          },
      ];
}

const baseTracks = ['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e']; // e1..e8

/// ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8'] with e1 playing.
Future<QueueRig> mixedRig({int playing = 0}) async {
  final rig = QueueRig(baseTracks, playing: playing);
  await rig.run((q) =>
      q.createGroup(groupId: 'G1', title: 'One', entryIds: ['e2', 'e3', 'e4']));
  await rig.run((q) =>
      q.createGroup(groupId: 'G2', title: 'Two', entryIds: ['e6', 'e7']));
  return rig;
}

/// The player's shuffle, as the app sees it, on top of a [FakeMpv].
///
/// Records every call to mpv's flat shuffle, so tests can prove it is never
/// called for a queue with groups.
class FakeShufflePort implements ShufflePort {
  FakeShufflePort(this.mpv);

  final FakeMpv mpv;

  /// mpv's own flag.
  bool flatFlag = false;
  bool? reported;

  /// Every call that reached mpv's flat shuffle, with its argument.
  final flatCalls = <bool>[];
  final published = <bool>[];
  List<String>? _orderBeforeFlat;

  @override
  bool get isShuffled => reported ?? flatFlag;

  @override
  bool get isFlatShuffled => flatFlag;

  /// Like media_kit: ignores a request for the state it is already in; "on"
  /// scrambles the whole playlist (reversing it stands in for a shuffle) and
  /// "off" puts it back.
  @override
  Future<void> setFlatShuffle(bool shuffle) async {
    flatCalls.add(shuffle);
    if (shuffle == flatFlag) return;
    flatFlag = shuffle;
    if (shuffle) {
      _orderBeforeFlat = mpv.physicalEntryIds;
      mpv.externalReorder(mpv.physicalEntryIds.reversed.toList());
    } else {
      final before = _orderBeforeFlat ?? mpv.physicalEntryIds;
      final present = mpv.physicalEntryIds.toSet();
      mpv.externalReorder([
        for (final id in before)
          if (present.contains(id)) id,
      ]);
    }
  }

  @override
  void publishShuffle(bool shuffled) {
    reported = shuffled;
    published.add(shuffled);
  }

  @override
  void releaseShuffle() => reported = null;
}
