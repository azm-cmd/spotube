import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/logger/logger.dart';

import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// Queue changes asked for back to back, without waiting for each other,
/// against the real audio player notifier and libmpv: the result must be what
/// the same changes give one after the other, and the app's queue, its groups
/// and mpv's playlist must agree. Skipped without libmpv.

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

/// A change to the queue, written with the names of the tracks.
sealed class Op {
  const Op();
}

class PlayNext extends Op {
  final List<String> names;
  const PlayNext(this.names);
  @override
  String toString() => 'PlayNext($names)';
}

class AddToQueue extends Op {
  final List<String> names;
  const AddToQueue(this.names);
  @override
  String toString() => 'AddToQueue($names)';
}

class MoveBefore extends Op {
  final String moved;
  final String? before;
  const MoveBefore(this.moved, this.before);
  @override
  String toString() => 'MoveBefore($moved, $before)';
}

class Remove extends Op {
  final List<String> names;
  const Remove(this.names);
  @override
  String toString() => 'Remove($names)';
}

class MoveGroupTo extends Op {
  final String title;
  final int to;
  const MoveGroupTo(this.title, this.to);
  @override
  String toString() => 'MoveGroupTo($title, $to)';
}

class MoveMember extends Op {
  final String title;
  final int from;
  final int to;
  const MoveMember(this.title, this.from, this.to);
  @override
  String toString() => 'MoveMember($title, $from, $to)';
}

class Ungroup extends Op {
  final String title;
  const Ungroup(this.title);
  @override
  String toString() => 'Ungroup($title)';
}

class Jump extends Op {
  final String name;
  const Jump(this.name);
  @override
  String toString() => 'Jump($name)';
}

/// The same changes on a plain queue, one after the other: the entries are
/// named by track name, so this says what the result has to be.
///
/// A change that carries positions (a drag) means the rows at those positions
/// in the queue as it was when the changes were asked for ([initial]): the app
/// names them at that moment, however much the changes before it move things.
class Model {
  Model(this.queue, this.playing) : initial = queue;

  final GroupedQueue<String> initial;
  GroupedQueue<String> queue;
  String playing;

  /// The order of every queue the model went through.
  final steps = <String>[];

  void apply(Op op) {
    switch (op) {
      case PlayNext(:final names):
        final at = queue.entries.indexWhere((e) => e.id == playing);
        queue = queue.insertUngrouped(
          playNextIndex(queue.entries.length, at),
          [for (final n in names) QueueEntry(n, n)],
        );
      case AddToQueue(:final names):
        queue = queue.insertUngrouped(
          queue.entries.length,
          [for (final n in names) QueueEntry(n, n)],
        );
      case MoveBefore(:final moved, :final before):
        // A drop after the last track is ignored, as it always was.
        if (before != null) queue = queue.moveEntryBefore(moved, before);
      case Remove(:final names):
        queue = queue.removeEntries(names);
      case MoveGroupTo(:final title, :final to):
        queue = queue.moveGroupBefore(_groupId(title), initial.itemKeyAt(to));
      case MoveMember(:final title, :final from, :final to):
        final id = _groupId(title);
        final members = initial.groupById(id)!.memberIds;
        queue = queue.moveMemberBefore(
          id,
          members[from],
          to < members.length ? members[to] : null,
        );
      case Ungroup(:final title):
        queue = queue.ungroup(_groupId(title));
      case Jump(:final name):
        if (queue.entries.any((e) => e.id == name)) playing = name;
    }
    steps.add(queue.entries.map((e) => e.id).join(' '));
  }

  String _groupId(String title) => queue.groups
      .firstWhere((g) => g.title == title,
          orElse: () => throw StateError('no group $title'))
      .id;

  String get shape => [
        for (final item in queue.items)
          switch (item) {
            EntryItem<String>(:final entry) => entry.id,
            GroupItem<String>(:final group, :final entries) =>
              '${group.title}[${entries.map((e) => e.id).join(',')}]',
          },
      ].join(' ');
}

void main() {
  final mpv = findMpv();

  group(
    'queue changes asked for back to back, with the real player',
    skip: mpv == null ? 'libmpv not found' : false,
    () {
      late Directory dir;
      late AppDatabase db;
      late Map<String, SpotubeTrackObject> tracks;

      setUpAll(() {
        TestWidgetsFlutterBinding.ensureInitialized();
        AppLogger.initialize(false);
        PackageInfo.setMockInitialValues(
          appName: 'Spotube',
          packageName: 'oss.krtirtho.spotube',
          version: '0.0.0',
          buildNumber: '0',
          buildSignature: '',
        );
        MediaKit.ensureInitialized(libmpv: mpv);
        dir = Directory.systemTemp.createTempSync('queue_groups_concurrency_');
        tracks = {
          for (final name in 'abcdefghijklmnopqrst'.split(''))
            name: SpotubeTrackObject.localTrackFromFile(writeWav(dir, name)),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));

      tearDown(() async {
        await audioPlayer.stop();
        await db.close();
      });

      Future<void> settle([int ms = 500]) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      Future<void> until(Future<bool> Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('timed out waiting');
      }

      String name(AudioPlayerState s, int i) =>
          (s.tracks[i] as SpotubeLocalTrackObject)
              .path
              .split('/')
              .last
              .split('.')
              .first;

      String shape(AudioPlayerState s) => [
            for (final item in s.groupedQueue.items)
              switch (item) {
                EntryItem<SpotubeTrackObject>(:final entry) =>
                  name(s, s.entryIds.indexOf(entry.id)),
                GroupItem<SpotubeTrackObject>(:final group, :final entries) =>
                  '${group.title}[${[
                    for (final e in entries) name(s, s.entryIds.indexOf(e.id))
                  ].join(',')}]',
              },
          ].join(' ');

      void expectInSync(AudioPlayerState s, {String? reason}) {
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length),
            reason: reason);
        expect(s.groupedQueue.validate(), isEmpty, reason: reason);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
          reason: 'mpv playlist $reason',
        );
        expect(audioPlayer.playlist.index, s.currentIndex,
            reason: 'playing position $reason');
      }

      /// A queue a b c d e f g h with groups One[b,c] and Two[e,f], `a` playing.
      Future<(ProviderContainer, AudioPlayerNotifier)> start() async {
        final c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          blacklistProvider.overrideWith(_NoBlacklist.new),
        ]);
        addTearDown(c.dispose);
        final n = c.read(audioPlayerProvider.notifier);
        await until(() async =>
            (await db.select(db.audioPlayerStateTable).get()).isNotEmpty);
        await settle();
        await n.load(
          [for (final k in 'abcdefgh'.split('')) tracks[k]!],
          autoPlay: false,
        );
        await settle();
        final ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
        await settle();
        return (c, n);
      }

      Model modelOf(AudioPlayerState s) => Model(
            GroupedQueue(
              [
                for (var i = 0; i < s.tracks.length; i++)
                  QueueEntry(name(s, i), name(s, i)),
              ],
              [
                for (final g in s.groups)
                  g.copyWith(memberIds: [
                    for (final id in g.memberIds)
                      name(s, s.entryIds.indexOf(id)),
                  ]),
              ],
            ),
            name(s, s.currentIndex),
          );

      /// Asks for [op] now, naming entries as they are now; returns when it is
      /// done (or failed).
      Future<void> ask(
        AudioPlayerNotifier n,
        AudioPlayerState s,
        Op op,
      ) async {
        String id(String track) => s.entryIds[[
              for (var i = 0; i < s.tracks.length; i++) name(s, i)
            ].indexOf(track)];
        String groupId(String title) =>
            s.groups.firstWhere((g) => g.title == title).id;
        try {
          switch (op) {
            case PlayNext(:final names):
              await n.addTracksAtFirst([for (final x in names) tracks[x]!]);
            case AddToQueue(:final names):
              await n.addTracks([for (final x in names) tracks[x]!]);
            case MoveBefore(:final moved, :final before):
              final from = s.entryIds.indexOf(id(moved));
              final to = before == null
                  ? s.entryIds.length
                  : s.entryIds.indexOf(id(before));
              await n.moveTrack(from, to);
            case Remove(:final names):
              await n.removeEntries([for (final x in names) id(x)]);
            case MoveGroupTo(:final title, :final to):
              await n.moveGroup(groupId(title), to);
            case MoveMember(:final title, :final from, :final to):
              await n.moveWithinGroup(groupId(title), from, to);
            case Ungroup(:final title):
              await n.ungroup(groupId(title));
            case Jump(:final name):
              await n.jumpToEntry(id(name));
          }
        } catch (_) {
          // A change that can not be carried out (its group is gone, ...) fails
          // on its own; the ones after it carry on.
        }
      }

      Model run(Model model, List<Op> ops) {
        for (final op in ops) {
          try {
            model.apply(op);
          } catch (_) {}
        }
        return model;
      }

      test('play next, a move, a removal and a group move, back to back',
          () async {
        final (c, n) = await start();
        final s0 = c.read(audioPlayerProvider);
        final ops = <Op>[
          const PlayNext(['i', 'j']),
          const MoveBefore('d', 'b'),
          const Remove(['h']),
          const MoveGroupTo('Two', 0),
          const AddToQueue(['k']),
        ];
        final model = run(modelOf(s0), ops);

        await Future.wait([for (final op in ops) ask(n, s0, op)]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(shape(s), model.shape);
        expectInSync(s);
        expect(name(s, s.currentIndex), 'a');
      });

      test('a jump asked for behind an insert lands on the entry it named',
          () async {
        final (c, n) = await start();
        final s0 = c.read(audioPlayerProvider);
        await Future.wait([
          ask(n, s0, const PlayNext(['i', 'j', 'k'])),
          ask(n, s0, const AddToQueue(['l'])),
          ask(n, s0, const Jump('g')),
        ]);
        await until(() async =>
            name(c.read(audioPlayerProvider), audioPlayer.playlist.index) ==
            'g');
        await settle();
        final s = c.read(audioPlayerProvider);
        expect(name(s, s.currentIndex), 'g');
        expectInSync(s);
      });

      test('the app never shows a half-way order while changes are in flight',
          () async {
        final (c, n) = await start();
        final s0 = c.read(audioPlayerProvider);
        final ops = <Op>[
          const PlayNext(['i', 'j']),
          const MoveGroupTo('One', 3),
          const MoveMember('One', 0, 2),
          const AddToQueue(['k', 'l']),
          const MoveBefore('h', 'a'),
        ];
        final model = run(modelOf(s0), ops);

        // Every order the app shows, in order.
        final shown = <String>[];
        c.listen(audioPlayerProvider, (_, next) {
          final order = [
            for (var i = 0; i < next.tracks.length; i++) name(next, i),
          ].join(' ');
          if (shown.isEmpty || shown.last != order) shown.add(order);
        }, fireImmediately: true);

        await Future.wait([for (final op in ops) ask(n, s0, op)]);
        await settle();

        // Only the queue before, after each change, and after all of them.
        final allowed = {
          [
            for (var i = 0; i < s0.tracks.length; i++) name(s0, i),
          ].join(' '),
          ...model.steps,
        };
        for (final order in shown) {
          expect(allowed, contains(order),
              reason: 'a half-way order was shown: $order');
        }
        expect(shape(c.read(audioPlayerProvider)), model.shape);
        expectInSync(c.read(audioPlayerProvider));
      });

      test(
          'shuffle, unshuffle and inserts asked for together keep groups whole',
          () async {
        final (c, n) = await start();
        await Future.wait([
          audioPlayer.setShuffle(true),
          n.addTracksAtFirst([tracks['i']!]),
          n.addTracks([tracks['j']!]),
          audioPlayer.setShuffle(false),
          n.addTracksAtFirst([tracks['k']!]),
        ]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(s.entryIds, hasLength(11));
        expect(s.groups.map((g) => g.memberIds.length), everyElement(2));
        expectInSync(s);

        await Future.wait([
          audioPlayer.setShuffle(true),
          n.addTracks([tracks['l']!]),
        ]);
        await settle();
        expectInSync(c.read(audioPlayerProvider));
      });

      test('copies of one track: each change reaches the copy it named',
          () async {
        final (c, n) = await start();
        // A second copy of every track in group One, and of the playing one.
        await n.addTracks([tracks['a']!, tracks['b']!, tracks['c']!]);
        await settle();
        final s0 = c.read(audioPlayerProvider);
        expect(shape(s0), 'a One[b,c] d Two[e,f] g h a b c');
        final ids = s0.entryIds;

        // Group the second b and c, move them, play the second a, remove the
        // first b: all named by entry, asked for back to back.
        await Future.wait([
          n.createGroup(title: 'Copies', entryIds: [ids[9], ids[10]]),
          n.moveGroup(s0.groups.first.id, 2),
          n.jumpToEntry(ids[8]),
          n.removeEntries([ids[1]]),
          n.addTracksAtFirst([tracks['a']!], allowDuplicates: true),
        ]);
        await until(() async =>
            c.read(audioPlayerProvider).entryIds[audioPlayer.playlist.index] ==
            ids[8]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length));
        expect(s.entryIds, isNot(contains(ids[1]))); // the first b went
        expect(s.entryIds, contains(ids[9])); // the second b stayed
        expect(s.groupedQueue.groupOf(ids[9])?.title, 'Copies');
        expect(s.groupedQueue.groupOf(ids[10])?.title, 'Copies');
        expect(s.groupedQueue.groupOf(ids[2])?.title, 'One'); // the first c
        expect(s.entryIds[s.currentIndex], ids[8]);
        expectInSync(s);
      });

      test('random changes back to back give what they give one by one',
          timeout: const Timeout(Duration(minutes: 5)), () async {
        for (var seed = 0; seed < 8; seed++) {
          final random = Random(seed);
          final (c, n) = await start();
          final s0 = c.read(audioPlayerProvider);

          // Plan on a model, so that every change is meaningful where it runs.
          final planner = modelOf(s0);
          final spare = 'ijklmnopqrst'.split('')..shuffle(random);
          final ops = <Op>[];
          for (var step = 0; step < 6; step++) {
            final names = [for (final e in planner.queue.entries) e.id]
                .where((x) => 'abcdefgh'.contains(x))
                .toList();
            final op = switch (random.nextInt(8)) {
              0 => PlayNext([
                  spare.removeLast(),
                  if (random.nextBool()) spare.removeLast()
                ]),
              1 => AddToQueue([spare.removeLast()]),
              2 => MoveBefore(
                  names[random.nextInt(names.length)],
                  random.nextInt(5) == 0
                      ? null
                      : names[random.nextInt(names.length)],
                ),
              3 => Remove([
                  names
                      .where((x) => x != planner.playing)
                      .elementAt(random.nextInt(names.length - 1)),
                ]),
              4 => MoveGroupTo(
                  random.nextBool() ? 'One' : 'Two',
                  // A position in the queue as it is when the changes are asked
                  // for (the planner has moved on from it).
                  random.nextInt(s0.groupedQueue.items.length + 1),
                ),
              5 => MoveMember(random.nextBool() ? 'One' : 'Two',
                  random.nextInt(2), random.nextInt(3)),
              6 => Ungroup(random.nextBool() ? 'One' : 'Two'),
              _ => Jump(names[random.nextInt(names.length)]),
            };
            ops.add(op);
            run(planner, [op]);
          }

          final model = run(modelOf(s0), ops);
          await Future.wait([for (final op in ops) ask(n, s0, op)]);
          await settle(700);

          final s = c.read(audioPlayerProvider);
          expect(shape(s), model.shape, reason: 'seed $seed: $ops');
          expectInSync(s, reason: 'seed $seed: $ops');
          await audioPlayer.stop();
          c.dispose();
        }
      });
    },
  );
}
