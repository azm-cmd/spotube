import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
import 'package:test/test.dart';

class _Track {
  final String id;
  const _Track(this.id);

  @override
  String toString() => id;
}

typedef _Queue = GroupedQueue<_Track>;

/// One playlist entry inside the fake player. The player only ever sees [key]
/// (the track id, so copies of a track look identical to it); [entryId] is
/// the app's identity, kept here so tests can check the right *physical* entry
/// ended up in the right place.
class _Slot {
  final String entryId;
  final String key;
  _Slot(this.entryId, this.key);
}

/// A stand-in for libmpv + media_kit.
///
///  * `playlist-move` has mpv's meaning: take the entry at `from` and put it
///    before the entry currently at `to` (`to` may be the length).
///  * The playing position follows the playing *entry*, not an index.
///  * Like media_kit it reports the whole playlist after every command, from
///    inside the command.
class _FakeMpv implements QueuePlayerPort {
  _FakeMpv(List<QueueEntry<_Track>> entries)
      : playlist = [for (final e in entries) _Slot(e.id, e.track.id)];

  final List<_Slot> playlist;
  _Slot? playing;

  /// Called after every change, like media_kit's playlist stream.
  void Function()? onReport;

  /// Every command received, in order, e.g. `move 3 1` or `remove 4`.
  final commands = <String>[];

  /// Pretend a `playlist-move` succeeded without doing anything.
  bool ignoreMoves = false;

  int _moves = 0;
  int? _failAtMove;

  /// Throw on the [n]-th `playlist-move` from now on (1 = the next one).
  void failMoveNumber(int n) => _failAtMove = _moves + n;

  void stopFailing() => _failAtMove = null;

  /// The truth: the app's entry id of every physical entry, in order.
  List<String> get physicalEntryIds => [for (final s in playlist) s.entryId];

  @override
  List<String> get playlistKeys => [for (final s in playlist) s.key];

  @override
  int get currentIndex => playing == null ? -1 : playlist.indexOf(playing!);

  @override
  Future<void> moveTrack(int from, int to) async {
    commands.add('move $from $to');
    _moves++;
    if (_failAtMove == _moves) throw StateError('mpv refused the move');
    if (!ignoreMoves) {
      RangeError.checkValidIndex(from, playlist, 'from');
      RangeError.checkValueInInterval(to, 0, playlist.length, 'to');
      final slot = playlist.removeAt(from);
      playlist.insert(from < to ? to - 1 : to, slot);
    }
    onReport?.call();
  }

  @override
  Future<void> removeTrack(int index) async {
    commands.add('remove $index');
    final slot = playlist.removeAt(index);
    if (slot == playing) {
      playing =
          playlist.isEmpty ? null : playlist[min(index, playlist.length - 1)];
    }
    onReport?.call();
  }

  /// The user (or auto-advance) switches to another entry.
  void jump(int index) {
    playing = playlist[index];
    onReport?.call();
  }

  /// A change the app did not ask for, e.g. a shuffle done by the player.
  void externalReorder(List<String> entryIdOrder) {
    final byId = {for (final s in playlist) s.entryId: s};
    playlist
      ..clear()
      ..addAll([for (final id in entryIdOrder) byId[id]!]);
    onReport?.call();
  }
}

/// The app side: what AudioPlayerNotifier does with the player, minus Riverpod.
class _Rig {
  _Rig(List<String> trackIds, {int playing = 0}) {
    final entries = [
      for (var i = 0; i < trackIds.length; i++)
        QueueEntry('e${i + 1}', _Track(trackIds[i])),
    ];
    mpv = _FakeMpv(entries);
    if (entries.isNotEmpty) mpv.playing = mpv.playlist[playing];
    snapshot = QueueSnapshot(GroupedQueue.ungrouped(entries), playing);
    sync = GroupedQueueSync(port: mpv, keyOf: (_Track t) => t.id);
    mpv.onReport = deliverReport;
  }

  late final _FakeMpv mpv;
  late final GroupedQueueSync<_Track> sync;
  late QueueSnapshot<_Track> snapshot;

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

  /// The notifier's `_changeGroups`.
  Future<void> run(_Queue Function(_Queue queue) change) {
    return sync.exclusive(() async {
      final from = snapshot;
      final target = change(from.queue);
      await sync.apply(from, target,
          commit: (confirmed) => snapshot = confirmed);
    });
  }

  _Queue get queue => snapshot.queue;
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
            EntryItem<_Track>(:final entry) => entry.id,
            GroupItem<_Track>(:final group) =>
              '${group.id}[${group.memberIds.join(',')}]',
          },
      ];
}

const _base = ['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e']; // e1..e8

/// ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8'] with e1 playing.
Future<_Rig> _mixed({int playing = 0}) async {
  final rig = _Rig(_base, playing: playing);
  await rig.run((q) =>
      q.createGroup(groupId: 'G1', title: 'One', entryIds: ['e2', 'e3', 'e4']));
  await rig.run((q) =>
      q.createGroup(groupId: 'G2', title: 'Two', entryIds: ['e6', 'e7']));
  return rig;
}

/// Longest increasing subsequence length, the slow obvious way.
int _lisLength(List<int> v) {
  final best = List.filled(v.length, 1);
  var most = 0;
  for (var i = 0; i < v.length; i++) {
    for (var j = 0; j < i; j++) {
      if (v[j] < v[i]) best[i] = max(best[i], best[j] + 1);
    }
    most = max(most, best[i]);
  }
  return most;
}

void main() {
  group('planReorder', () {
    List<String> apply(List<String> order, List<QueueMove> plan) {
      var result = order;
      for (final move in plan) {
        result = moveEntry(result, move.from, move.to);
      }
      return result;
    }

    test('an order that is already right needs no moves', () {
      expect(planReorder(['a', 'b', 'c'], ['a', 'b', 'c']), isEmpty);
      expect(planReorder(<String>[], <String>[]), isEmpty);
      expect(planReorder(['a'], ['a']), isEmpty);
    });

    test('one entry out of place is one move', () {
      final plan = planReorder(['a', 'b', 'c', 'd'], ['b', 'c', 'd', 'a']);
      expect(plan, [const QueueMove(0, 4)]);
      expect(apply(['a', 'b', 'c', 'd'], plan), ['b', 'c', 'd', 'a']);
    });

    test('moving a block moves only the block', () {
      final current = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
      final target = ['a', 'f', 'g', 'b', 'c', 'd', 'e', 'h'];
      final plan = planReorder(current, target);
      expect(plan.length, 2);
      expect(apply(current, plan), target);
    });

    test('moves to the front and to the end', () {
      final current = ['a', 'b', 'c', 'd'];
      expect(apply(current, planReorder(current, ['d', 'a', 'b', 'c'])),
          ['d', 'a', 'b', 'c']);
      expect(planReorder(current, ['d', 'a', 'b', 'c']).length, 1);
      expect(apply(current, planReorder(current, ['b', 'c', 'd', 'a'])),
          ['b', 'c', 'd', 'a']);
    });

    test('a full reversal still ends in the right order', () {
      final current = ['a', 'b', 'c', 'd', 'e'];
      final target = current.reversed.toList();
      final plan = planReorder(current, target);
      expect(plan.length, 4); // n - 1: only one entry can stay
      expect(apply(current, plan), target);
    });

    test('never sends a move that changes nothing', () {
      final plan = planReorder(['a', 'b', 'c', 'd'], ['a', 'c', 'b', 'd']);
      expect(plan.length, 1);
      for (final move in plan) {
        expect(move.from, isNot(move.to));
        expect(move.from + 1, isNot(move.to));
      }
    });

    test('rejects orders that are not permutations of each other', () {
      expect(() => planReorder(['a', 'b'], ['a']), throwsArgumentError);
      expect(() => planReorder(['a', 'b'], ['a', 'c']), throwsArgumentError);
      expect(() => planReorder(['a', 'a'], ['a', 'a']), throwsArgumentError);
    });

    test('random orders: correct result in the fewest moves', () {
      final random = Random(7);
      for (var round = 0; round < 300; round++) {
        final n = random.nextInt(14);
        final current = [for (var i = 0; i < n; i++) 'x$i'];
        final target = [...current]..shuffle(random);

        final plan = planReorder(current, target);

        expect(apply(current, plan), target, reason: '$current -> $target');
        final position = {for (var i = 0; i < n; i++) target[i]: i};
        final stays = _lisLength([for (final id in current) position[id]!]);
        expect(plan.length, n - stays, reason: '$current -> $target');
      }
    });
  });

  group('QueueSnapshot', () {
    test('currentEntryId is the entry at the playing position', () {
      final rig = _Rig(_base, playing: 3);
      expect(rig.snapshot.currentEntryId, 'e4');
    });

    test('currentEntryId is null when nothing valid is playing', () {
      expect(const QueueSnapshot(GroupedQueue<_Track>([]), 0).currentEntryId,
          isNull);
      expect(_Rig(_base).snapshot.queue.entries, isNotEmpty);
      final queue =
          GroupedQueue.ungrouped([const QueueEntry('e1', _Track('a'))]);
      expect(QueueSnapshot(queue, -1).currentEntryId, isNull);
      expect(QueueSnapshot(queue, 1).currentEntryId, isNull);
    });
  });

  group('a queue without groups', () {
    test('keeps working exactly as before', () async {
      final rig = _Rig(_base, playing: 2);
      rig.expectInSync();
      expect(rig.queue.groups, isEmpty);
      expect(rig.shape, ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8']);
    });

    test('a report that changes nothing leaves the queue as it is', () {
      final rig = _Rig(_base, playing: 2);
      final before = rig.flat;
      rig.deliverReport();
      rig.deliverReport();
      expect(rig.flat, before);
      rig.expectInSync();
    });

    test('a report for a different length is ignored, as it always was', () {
      final rig = _Rig(_base);
      final next = rig.sync.onPlayerPlaylist(rig.snapshot, ['a', 'b'], 0);
      expect(next, isNull);
    });

    test('the player reordering on its own is mirrored without merging copies',
        () {
      final rig = _Rig(_base);
      rig.mpv.externalReorder(['e8', 'e7', 'e6', 'e5', 'e4', 'e3', 'e2', 'e1']);

      // The keys are what the player can report; copies of a stay separate.
      expect([for (final e in rig.queue.entries) e.track.id],
          rig.mpv.playlistKeys);
      expect(rig.flat.toSet().length, 8);
      expect(rig.queue.entries.where((e) => e.track.id == 'a').length, 3);
    });

    test('changes to groups only never touch the player', () async {
      final rig = await _mixed();
      rig.mpv.commands.clear();

      await rig.run((q) => q.renameGroup('G1', 'Renamed'));
      await rig.run((q) => q.setCollapsed('G1', false));
      await rig.run((q) => q.ungroup('G2'));

      expect(rig.mpv.commands, isEmpty);
      expect(rig.queue.groupById('G1')!.title, 'Renamed');
      expect(rig.queue.groupById('G1')!.collapsed, isFalse);
      expect(rig.queue.groupById('G2'), isNull);
      rig.expectInSync();
    });
  });

  group('creating and changing groups reaches the player', () {
    test('create group gathers the entries in the player too', () async {
      final rig = _Rig(_base);
      await rig.run((q) => q.createGroup(
          groupId: 'G1', title: 'T', entryIds: ['e6', 'e2', 'e4']));

      expect(rig.flat, ['e1', 'e2', 'e4', 'e6', 'e3', 'e5', 'e7', 'e8']);
      expect(rig.shape, ['e1', 'G1[e2,e4,e6]', 'e3', 'e5', 'e7', 'e8']);
      expect(rig.mpv.commands.length, 2); // only e3 and e5 had to move
      rig.expectInSync();
    });

    test('add to a group moves the entry next to it', () async {
      final rig = await _mixed();
      await rig.run((q) => q.addToGroup('G1', ['e8'], index: 0));

      expect(rig.shape, ['e1', 'G1[e8,e2,e3,e4]', 'e5', 'G2[e6,e7]']);
      rig.expectInSync();
    });

    test('remove from a group: ends stay, the middle moves out', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeFromGroup(['e3']));
      expect(rig.shape, ['e1', 'G1[e2,e4]', 'e3', 'e5', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();

      await rig.run((q) => q.removeFromGroup(['e2']));
      expect(rig.shape, ['e1', 'e2', 'G1[e4]', 'e3', 'e5', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();
    });

    test('ungroup leaves the player exactly as it was', () async {
      final rig = await _mixed();
      final before = rig.mpv.physicalEntryIds;
      rig.mpv.commands.clear();

      await rig.run((q) => q.ungroup('G1'));

      expect(rig.mpv.commands, isEmpty);
      expect(rig.mpv.physicalEntryIds, before);
      expect(rig.shape, ['e1', 'e2', 'e3', 'e4', 'e5', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();
    });

    test('a mixed queue of groups and loose songs stays in step', () async {
      final rig = await _mixed();
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();
    });
  });

  group('moving groups', () {
    test('a group moves forward across a loose song and another group',
        () async {
      final rig = await _mixed();
      await rig.run((q) => q.moveGroup('G1', 5)); // to the very end

      expect(rig.shape, ['e1', 'e5', 'G2[e6,e7]', 'e8', 'G1[e2,e3,e4]']);
      expect(rig.flat, ['e1', 'e5', 'e6', 'e7', 'e8', 'e2', 'e3', 'e4']);
      rig.expectInSync();
    });

    test('a group moves backward to the very beginning', () async {
      final rig = await _mixed();
      await rig.run((q) => q.moveGroup('G2', 0));

      expect(rig.shape, ['G2[e6,e7]', 'e1', 'G1[e2,e3,e4]', 'e5', 'e8']);
      expect(rig.queue.groups.map((g) => g.id), ['G2', 'G1']);
      rig.expectInSync();
    });

    test('a loose song moves between groups, never into one', () async {
      final rig = await _mixed();
      await rig.run((q) => q.moveItem(4, 3)); // e8 before G2

      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'e8', 'G2[e6,e7]']);
      rig.expectInSync();
    });

    test('moving a group sends no more moves than the group is long', () async {
      final rig = await _mixed();
      rig.mpv.commands.clear();
      await rig.run((q) => q.moveGroup('G1', 5));
      expect(rig.mpv.commands.length, lessThanOrEqualTo(3));
    });

    test('reordering inside a group moves nothing outside it', () async {
      final rig = await _mixed();
      await rig.run((q) => q.moveWithinGroup('G1', 0, 3));

      expect(rig.shape, ['e1', 'G1[e3,e4,e2]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(rig.flat, ['e1', 'e3', 'e4', 'e2', 'e5', 'e6', 'e7', 'e8']);
      rig.expectInSync();
    });
  });

  group('duplicate track ids stay distinct all the way to the player', () {
    test('three copies of one track can be grouped and reordered', () async {
      // e1, e3 and e5 are all track "a"; the player cannot tell them apart.
      final rig = _Rig(_base);
      await rig.run((q) => q
          .createGroup(groupId: 'G', title: 'T', entryIds: ['e1', 'e3', 'e5']));
      expect(rig.shape, ['G[e1,e3,e5]', 'e2', 'e4', 'e6', 'e7', 'e8']);
      rig.expectInSync();

      await rig.run((q) => q.moveWithinGroup('G', 2, 0));
      expect(rig.queue.groupById('G')!.memberIds, ['e5', 'e1', 'e3']);
      // The *physical* playlist entries are in that order, not just the keys.
      expect(rig.mpv.physicalEntryIds.take(3), ['e5', 'e1', 'e3']);
      rig.expectInSync();

      await rig.run((q) => q.moveGroup('G', 6)); // to the very end
      expect(rig.mpv.physicalEntryIds.skip(5), ['e5', 'e1', 'e3']);
      rig.expectInSync();
    });

    test('only the chosen copy is grouped, moved or removed', () async {
      final rig = _Rig(_base);
      await rig.run(
          (q) => q.createGroup(groupId: 'G', title: 'T', entryIds: ['e3']));
      await rig.run((q) => q.moveGroup('G', 8)); // to the very end
      expect(rig.mpv.physicalEntryIds.last, 'e3');
      rig.expectInSync();

      await rig.run((q) => q.removeEntries(['e3']));
      expect(
          rig.mpv.physicalEntryIds, ['e1', 'e2', 'e4', 'e5', 'e6', 'e7', 'e8']);
      expect(rig.queue.groups, isEmpty);
      expect(rig.queue.entries.where((e) => e.track.id == 'a').map((e) => e.id),
          ['e1', 'e5']);
      rig.expectInSync();
    });

    test('a track queued twice is two entries even after many reorders',
        () async {
      final rig = _Rig(['a', 'a', 'b', 'a', 'b', 'b']);
      await rig.run((q) => q.createGroup(
          groupId: 'G1', title: 'A', entryIds: ['e1', 'e2', 'e4']));
      await rig.run((q) => q.createGroup(
          groupId: 'G2', title: 'B', entryIds: ['e3', 'e5', 'e6']));
      await rig.run((q) => q.moveGroup('G2', 0));
      await rig.run((q) => q.moveWithinGroup('G1', 0, 3));
      await rig.run((q) => q.moveWithinGroup('G2', 2, 0));

      expect(rig.mpv.physicalEntryIds.toSet().length, 6);
      expect(rig.flat.toSet().length, 6);
      rig.expectInSync();
    });
  });

  group('the playing track', () {
    test('keeps playing when the group it is in moves', () async {
      final rig = await _mixed(playing: 2); // e3, inside G1
      expect(rig.snapshot.currentEntryId, 'e3');

      await rig.run((q) => q.moveGroup('G1', 5));

      expect(rig.flat, ['e1', 'e5', 'e6', 'e7', 'e8', 'e2', 'e3', 'e4']);
      expect(rig.snapshot.currentEntryId, 'e3');
      expect(rig.snapshot.currentIndex, 6);
      expect(rig.mpv.playing!.entryId, 'e3');
      expect(rig.mpv.currentIndex, 6);
      rig.expectInSync();
    });

    test('the index follows the same entry when others move around it',
        () async {
      final rig = await _mixed(playing: 4); // e5, loose, between the groups
      await rig.run((q) => q.moveGroup('G2', 0));
      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.snapshot.currentIndex, 6);
      rig.expectInSync();

      await rig.run((q) => q.moveGroup('G1', 0));
      expect(rig.snapshot.currentEntryId, 'e5');
      expect(rig.snapshot.currentIndex, 6);
      rig.expectInSync();
    });

    test('a copy of the playing track elsewhere is not mistaken for it',
        () async {
      // e1, e3, e5 are all track "a"; e3 is playing.
      final rig = _Rig(_base, playing: 2);
      await rig.run((q) =>
          q.createGroup(groupId: 'G', title: 'T', entryIds: ['e1', 'e5']));
      expect(rig.flat.take(3), ['e1', 'e5', 'e2']);
      expect(rig.snapshot.currentEntryId, 'e3');
      expect(rig.mpv.playing!.entryId, 'e3');
      rig.expectInSync();
    });

    test('a user skip during no operation is still followed', () async {
      final rig = await _mixed(playing: 0);
      rig.mpv.jump(5);
      expect(rig.snapshot.currentEntryId, 'e6');
      rig.expectInSync();
    });

    test('the playing entry survives the removal of other entries', () async {
      final rig = await _mixed(playing: 6); // e7 in G2
      await rig.run((q) => q.removeEntries(['e1', 'e3']));
      expect(rig.snapshot.currentEntryId, 'e7');
      rig.expectInSync();
    });

    test('removing the playing entry leaves the player in charge', () async {
      final rig = await _mixed(playing: 2); // e3
      await rig.run((q) => q.removeEntries(['e3']));
      // The player moves on to the next entry and reports it.
      expect(rig.mpv.playing!.entryId, 'e4');
      expect(rig.snapshot.currentEntryId, 'e4');
      rig.expectInSync();
    });
  });

  group('removing entries', () {
    test('an ungrouped entry', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeEntries(['e5']));
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'G2[e6,e7]', 'e8']);
      rig.expectInSync();
    });

    test('one member leaves the group with the others', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeEntries(['e3']));
      expect(rig.shape, ['e1', 'G1[e2,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(rig.queue.groupOf('e3'), isNull);
      rig.expectInSync();
    });

    test('several members, in different groups, in one go', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeEntries(['e2', 'e4', 'e7', 'e1']));
      expect(rig.shape, ['G1[e3]', 'e5', 'G2[e6]', 'e8']);
      rig.expectInSync();
    });

    test('a whole group, so no empty group is left behind', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeEntries(['e6', 'e7']));
      expect(rig.shape, ['e1', 'G1[e2,e3,e4]', 'e5', 'e8']);
      expect(rig.queue.groups.map((g) => g.id), ['G1']);
      expect(rig.queue.validate(), isEmpty);
      rig.expectInSync();
    });

    test('removes from the player back to front', () async {
      final rig = await _mixed();
      rig.mpv.commands.clear();
      await rig.run((q) => q.removeEntries(['e2', 'e5', 'e8']));
      expect(rig.mpv.commands, ['remove 7', 'remove 4', 'remove 1']);
      rig.expectInSync();
    });

    test('everything at once empties the queue and the groups', () async {
      final rig = await _mixed();
      await rig.run((q) => q.removeEntries(rig.flat));
      expect(rig.flat, isEmpty);
      expect(rig.queue.groups, isEmpty);
      expect(rig.mpv.playlist, isEmpty);
    });

    test('ids that are not in the queue change nothing', () async {
      final rig = await _mixed();
      rig.mpv.commands.clear();
      await rig.run((q) => q.removeEntries(['ghost']));
      expect(rig.mpv.commands, isEmpty);
      rig.expectInSync();
    });

    test('the queue is shorter right away, not only when the player agrees',
        () async {
      final rig = await _mixed();
      var lengthWhenFirstRemoved = -1;
      rig.mpv.onReport = () {
        if (lengthWhenFirstRemoved == -1) {
          lengthWhenFirstRemoved = rig.snapshot.queue.entries.length;
        }
        rig.deliverReport();
      };
      await rig.run((q) => q.removeEntries(['e1', 'e8']));
      expect(lengthWhenFirstRemoved, 6);
    });
  });

  group('while a reorder is in progress', () {
    test('the player\'s intermediate reports are not mirrored', () async {
      final rig = await _mixed();
      rig.reportsIgnored = 0;
      final seenWhileApplying = <List<String>>[];
      rig.mpv.onReport = () {
        if (rig.sync.isApplying) seenWhileApplying.add(rig.flat);
        rig.deliverReport();
      };

      await rig.run((q) => q.moveGroup('G1', 5));

      expect(rig.reportsIgnored, greaterThan(0));
      // The app's queue stayed whole and valid until the confirmed result.
      for (final flat in seenWhileApplying) {
        expect(flat, ['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8']);
      }
      expect(rig.sync.isApplying, isFalse);
      rig.expectInSync();
    });

    test('a late report of the final order changes nothing', () async {
      final rig = await _mixed(playing: 2);
      await rig.run((q) => q.moveGroup('G1', 5));
      final shape = rig.shape;
      final index = rig.snapshot.currentIndex;

      rig.deliverReport();
      rig.deliverReport();

      expect(rig.shape, shape);
      expect(rig.snapshot.currentIndex, index);
      rig.expectInSync();
    });

    test('two requests at once run one after the other', () async {
      final rig = await _mixed();
      final first = rig.run((q) => q.moveGroup('G1', 5));
      final second = rig.run((q) => q.moveGroup('G2', 0));
      await Future.wait([first, second]);

      expect(rig.shape, ['G2[e6,e7]', 'e1', 'e5', 'e8', 'G1[e2,e3,e4]']);
      rig.expectInSync();
    });

    test('a refused request changes nothing and does not block the next',
        () async {
      final rig = await _mixed();
      final before = rig.flat;
      rig.mpv.commands.clear();

      await expectLater(
        rig.run((q) => q.addToGroup('G1', ['e6'])), // already in G2
        throwsA(isA<QueueGroupError>()),
      );
      expect(rig.mpv.commands, isEmpty);
      expect(rig.flat, before);

      await rig.run((q) => q.renameGroup('G1', 'still works'));
      expect(rig.queue.groupById('G1')!.title, 'still works');
    });
  });

  group('when the player does not do what was asked', () {
    test('a move the player ignored: the app follows the player', () async {
      final rig = await _mixed();
      rig.mpv.ignoreMoves = true;

      await rig.run((q) => q.moveGroup('G1', 5));

      // The player kept its order, so the app does too, and the group model
      // is still valid (groups that no longer match are dissolved).
      expect(rig.mpv.playlistKeys,
          [for (final e in rig.queue.entries) e.track.id]);
      expect(rig.queue.validate(), isEmpty);
      expect(rig.sync.isApplying, isFalse);
    });

    test('a move that fails half way: the app follows the player, then throws',
        () async {
      final rig = await _mixed();
      rig.mpv.failMoveNumber(2);

      await expectLater(
        rig.run((q) => q.moveGroup('G1', 5)),
        throwsStateError,
      );

      expect(rig.mpv.playlistKeys,
          [for (final e in rig.queue.entries) e.track.id]);
      expect(rig.queue.validate(), isEmpty);
      expect(rig.queue.entries.length, 8);
      expect(rig.sync.isApplying, isFalse);

      // and the queue is usable again: the lock was released and the player
      // accepts commands once more.
      rig.mpv.stopFailing();
      final loose =
          rig.queue.ungroupedEntries.map((e) => e.id).take(2).toList();
      await rig.run(
          (q) => q.createGroup(groupId: 'after', title: 'ok', entryIds: loose));
      expect(rig.queue.groupById('after'), isNotNull);
      // After a failure only the player's keys are known, so copies of one
      // track may not be matched to the same physical entry: check what can
      // be known.
      expect(rig.queue.validate(), isEmpty);
      expect([for (final e in rig.queue.entries) e.track.id],
          rig.mpv.playlistKeys);
    });

    // Distinct tracks, so the player's report names every entry exactly.
    Future<_Rig> distinct() async {
      final rig = _Rig(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
      await rig.run((q) => q
          .createGroup(groupId: 'G1', title: '', entryIds: ['e2', 'e3', 'e4']));
      await rig.run((q) =>
          q.createGroup(groupId: 'G2', title: '', entryIds: ['e6', 'e7']));
      return rig;
    }

    test('mirror drops members the player no longer has, and empty groups',
        () async {
      final rig = await distinct();
      // The player reports a queue without e3, e6 and e7.
      final keys = [
        for (final e in rig.queue.entries)
          if (!{'e3', 'e6', 'e7'}.contains(e.id)) e.track.id,
      ];

      final next = rig.sync.mirror(rig.snapshot, keys, 0);

      expect([for (final e in next.queue.entries) e.id],
          ['e1', 'e2', 'e4', 'e5', 'e8']);
      expect(next.queue.groupById('G1')!.memberIds, ['e2', 'e4']);
      expect(next.queue.groupById('G2'), isNull);
      expect(next.queue.validate(), isEmpty);
    });

    test('a player-side shuffle that scatters a group dissolves it', () async {
      final rig = await distinct();
      rig.mpv.externalReorder(['e8', 'e2', 'e6', 'e3', 'e1', 'e4', 'e7', 'e5']);

      expect(rig.queue.groupById('G1'), isNull); // e2, e3, e4 are apart
      expect(rig.queue.groupById('G2'), isNull); // e6, e7 are apart
      expect(rig.queue.validate(), isEmpty);
      expect(rig.flat, rig.mpv.physicalEntryIds); // nothing lost or merged
    });

    test('a player-side reorder that keeps a group together keeps the group',
        () async {
      final rig = await distinct();
      rig.mpv.externalReorder(['e8', 'e6', 'e7', 'e2', 'e3', 'e4', 'e5', 'e1']);

      expect(rig.queue.groupById('G1')!.memberIds, ['e2', 'e3', 'e4']);
      expect(rig.queue.groupById('G2')!.memberIds, ['e6', 'e7']);
      expect(rig.queue.groups.map((g) => g.id), ['G2', 'G1']);
      expect(rig.flat, rig.mpv.physicalEntryIds);
      expect(rig.queue.validate(), isEmpty);
    });

    test(
        'limit: after the player reorders identical copies on its own, '
        'nothing is merged but which copy is which cannot be known', () {
      // e1, e3, e5 are all track "a". The player moves e5 to the front; all it
      // can report is the keys, so the app keeps its own order for the copies.
      final rig = _Rig(_base);
      rig.mpv.externalReorder(['e5', 'e1', 'e2', 'e3', 'e4', 'e6', 'e7', 'e8']);

      expect(rig.flat.toSet().length, 8); // still eight separate entries
      expect([for (final e in rig.queue.entries) e.track.id],
          rig.mpv.playlistKeys); // same keys in the same order
      expect(rig.queue.entries.where((e) => e.track.id == 'a').length, 3);
      expect(rig.flat, isNot(rig.mpv.physicalEntryIds));
    });
  });

  group('apply only accepts group-style changes', () {
    test('adding entries is refused before the player is touched', () async {
      final rig = _Rig(_base);
      final grown = GroupedQueue.ungrouped([
        ...rig.queue.entries,
        const QueueEntry('x', _Track('x')),
      ]);
      await expectLater(
        rig.sync.apply(rig.snapshot, grown, commit: (_) {}),
        throwsArgumentError,
      );
      expect(rig.mpv.commands, isEmpty);
    });

    test('a shortening that also reorders is refused', () async {
      final rig = _Rig(_base);
      final odd =
          GroupedQueue.ungrouped(rig.queue.entries.reversed.take(3).toList());
      await expectLater(
        rig.sync.apply(rig.snapshot, odd, commit: (_) {}),
        throwsArgumentError,
      );
      expect(rig.mpv.commands, isEmpty);
    });
  });

  group('randomized: the app, the group model and the player never disagree',
      () {
    test('hundreds of operations, with duplicate tracks and a moving playhead',
        () async {
      final random = Random(1337);
      final rig = _Rig(
        ['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e', 'a', 'f', 'c', 'a', 'b', 'a'],
        playing: 3,
      );
      var nextGroup = 0;
      final tracks = {for (final e in rig.queue.entries) e.id: e.track};

      List<String> pick(List<String> from, int count) =>
          ([...from]..shuffle(random)).take(count).toList();

      for (var step = 0; step < 400; step++) {
        final loose = rig.queue.ungroupedEntries.map((e) => e.id).toList();
        final grouped = rig.queue.groupIdByEntryId.keys.toList();
        final groupIds = rig.queue.groups.map((g) => g.id).toList();
        final rows = rig.queue.items.length;
        final playingBefore = rig.mpv.playing?.entryId;
        var removed = <String>{};
        var ran = true;
        var skipped = false;

        switch (random.nextInt(11)) {
          case 0 when loose.isNotEmpty:
            await rig.run((q) => q.createGroup(
                groupId: 'G${nextGroup++}',
                title: 't',
                entryIds: pick(loose, 1 + random.nextInt(4))));
          case 1 when loose.isNotEmpty && groupIds.isNotEmpty:
            final group =
                rig.queue.groupById(groupIds[random.nextInt(groupIds.length)])!;
            await rig.run((q) => q.addToGroup(
                group.id, pick(loose, 1 + random.nextInt(3)),
                index: random.nextInt(group.length + 1)));
          case 2 when grouped.isNotEmpty:
            await rig.run(
                (q) => q.removeFromGroup(pick(grouped, 1 + random.nextInt(3))));
          case 3 when groupIds.isNotEmpty:
            await rig.run(
                (q) => q.ungroup(groupIds[random.nextInt(groupIds.length)]));
          case 4 when rows > 0:
            await rig.run((q) =>
                q.moveItem(random.nextInt(rows), random.nextInt(rows + 1)));
          case 5 when groupIds.isNotEmpty:
            final group =
                rig.queue.groupById(groupIds[random.nextInt(groupIds.length)])!;
            await rig.run((q) => q.moveWithinGroup(
                group.id,
                random.nextInt(group.length),
                random.nextInt(group.length + 1)));
          case 6 when groupIds.isNotEmpty:
            await rig.run((q) => q.moveGroup(
                groupIds[random.nextInt(groupIds.length)],
                random.nextInt(rows + 1)));
          case 7 when rig.flat.length > 4:
            removed = pick(rig.flat, 1 + random.nextInt(2)).toSet();
            await rig.run((q) => q.removeEntries(removed));
          case 8 when rig.flat.isNotEmpty:
            rig.mpv.jump(random.nextInt(rig.flat.length)); // the user skips
            skipped = true;
          case 9 when groupIds.isNotEmpty:
            await rig.run((q) => q.setCollapsed(
                groupIds[random.nextInt(groupIds.length)], random.nextBool()));
          default:
            ran = false;
        }
        if (!ran) continue;

        final reason = 'step $step';
        rig.expectInSync(reason: reason);

        expect(rig.flat.toSet().length, rig.flat.length, reason: reason);
        for (final entry in rig.queue.entries) {
          expect(identical(entry.track, tracks[entry.id]), isTrue,
              reason: '$reason: ${entry.id} changed track');
        }
        // The playhead never jumps to another entry, unless its own entry went.
        if (!skipped &&
            playingBefore != null &&
            !removed.contains(playingBefore) &&
            rig.mpv.playing != null) {
          expect(rig.mpv.playing!.entryId, playingBefore,
              reason: '$reason: the playing entry changed');
        }
      }
    });
  });
}
