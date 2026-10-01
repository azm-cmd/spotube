import 'dart:io';

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
import 'package:spotube/services/logger/logger.dart';

import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// "Play next" and "add to queue" on a queue with groups, against the real
/// audio player notifier, its database and libmpv. Skipped without libmpv.

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

void main() {
  final mpv = findMpv();

  group(
    'adding tracks to a queue with groups, with the real player',
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
        dir = Directory.systemTemp.createTempSync('queue_groups_insert_');
        tracks = {
          for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'x', 'y', 'z'])
            name: SpotubeTrackObject.localTrackFromFile(writeWav(dir, name)),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));

      tearDown(() async {
        await audioPlayer.stop();
        await db.close();
      });

      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 400));

      Future<void> until(Future<bool> Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('timed out waiting');
      }

      Future<(ProviderContainer, AudioPlayerNotifier)> boot() async {
        final c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          blacklistProvider.overrideWith(_NoBlacklist.new),
        ]);
        addTearDown(c.dispose);
        final notifier = c.read(audioPlayerProvider.notifier);
        await until(() async =>
            (await db.select(db.audioPlayerStateTable).get()).isNotEmpty);
        await settle();
        return (c, notifier);
      }

      String name(AudioPlayerState s, int i) =>
          (s.tracks[i] as SpotubeLocalTrackObject)
              .path
              .split('/')
              .last
              .split('.')
              .first;

      /// `a One[b,c] d`: the top-level shape of the queue, by file name.
      String shape(AudioPlayerState s) {
        return [
          for (final item in s.groupedQueue.items)
            switch (item) {
              EntryItem<SpotubeTrackObject>(:final entry) =>
                name(s, s.entryIds.indexOf(entry.id)),
              GroupItem<SpotubeTrackObject>(:final group, :final entries) =>
                '${group.title}${group.collapsed ? '' : '+'}[${[
                  for (final e in entries) name(s, s.entryIds.indexOf(e.id))
                ].join(',')}]',
            },
        ].join(' ');
      }

      /// The queue, its groups and mpv's playlist agree, the groups are whole,
      /// and the entry that played still plays.
      void expectInSync(AudioPlayerState s, {String? playing, String? reason}) {
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length),
            reason: reason);
        expect(s.groupedQueue.validate(), isEmpty, reason: reason);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
          reason: 'mpv playlist $reason',
        );
        expect(audioPlayer.playlist.index, s.currentIndex, reason: reason);
        if (playing != null) {
          expect(s.entryIds[s.currentIndex], playing,
              reason: 'playing $reason');
        }
      }

      /// A queue a b c d e f with groups One[b,c] and Two[e,f], [playing] (an
      /// index) playing; [expandOne] opens group One.
      Future<(ProviderContainer, AudioPlayerNotifier)> start({
        int playing = 0,
        bool groups = true,
        bool expandOne = false,
      }) async {
        final (c, n) = await boot();
        await n.load(
          [
            for (final k in ['a', 'b', 'c', 'd', 'e', 'f']) tracks[k]!
          ],
          autoPlay: false,
        );
        await settle();
        final ids = c.read(audioPlayerProvider).entryIds;
        if (groups) {
          final one = await n.createGroup(
            title: 'One',
            entryIds: [ids[1], ids[2]],
          );
          await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
          if (expandOne) await n.setGroupCollapsed(one, false);
        }
        await n.jumpToEntry(ids[playing]);
        await until(() async => audioPlayer.playlist.index == playing);
        await settle();
        return (c, n);
      }

      test('flat queue: play next goes right after the playing track',
          () async {
        final (c, n) = await start(playing: 1, groups: false);
        final playing = c.read(audioPlayerProvider).entryIds[1];

        await n.addTracksAtFirst([tracks['x']!]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'a b x c d e f');
        expectInSync(s, playing: playing);
      });

      test('flat queue: several tracks keep their order', () async {
        final (c, n) = await start(playing: 0, groups: false);
        await n.addTracksAtFirst([tracks['x']!, tracks['y']!, tracks['z']!]);
        await settle();
        expect(shape(c.read(audioPlayerProvider)), 'a x y z b c d e f');
        expectInSync(c.read(audioPlayerProvider));
      });

      test('flat queue: add to queue appends', () async {
        final (c, n) = await start(playing: 2, groups: false);
        await n.addTrack(tracks['x']!);
        await n.addTracks([tracks['y']!, tracks['z']!]);
        await settle();
        expect(shape(c.read(audioPlayerProvider)), 'a b c d e f x y z');
        expectInSync(c.read(audioPlayerProvider));
      });

      test(
          'playing a loose track before a group: play next goes in front of it',
          () async {
        final (c, n) = await start(playing: 0);
        final playing = c.read(audioPlayerProvider).entryIds[0];

        await n.addTracksAtFirst([tracks['x']!, tracks['y']!]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'a x y One[b,c] d Two[e,f]');
        expectInSync(s, playing: playing);
      });

      for (final expanded in [false, true]) {
        for (final playingIndex in [1, 2]) {
          test(
              'playing member ${playingIndex - 1} of a '
              '${expanded ? 'expanded' : 'collapsed'} group: play next goes after the group',
              () async {
            final (c, n) =
                await start(playing: playingIndex, expandOne: expanded);
            final playing = c.read(audioPlayerProvider).entryIds[playingIndex];

            await n.addTracksAtFirst([tracks['x']!, tracks['y']!]);
            await settle();

            final s = c.read(audioPlayerProvider);
            expect(shape(s), 'a One${expanded ? '+' : ''}[b,c] x y d Two[e,f]');
            expect(s.groupedQueue.groupOf(s.entryIds[3 + 1]), isNull);
            expectInSync(s, playing: playing);
          });
        }
      }

      test('add to queue puts tracks after the whole structure', () async {
        final (c, n) = await start(playing: 2);
        final playing = c.read(audioPlayerProvider).entryIds[2];

        await n.addTrack(tracks['x']!);
        await n.addTracks([tracks['y']!, tracks['z']!]);
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'a One[b,c] d Two[e,f] x y z');
        expectInSync(s, playing: playing);
      });

      test(
          'copies of a track are separate entries, and a bulk add can be taken back exactly',
          () async {
        final (c, n) = await start(playing: 0);
        final before = c.read(audioPlayerProvider).entryIds;

        // An "album" that holds a track already queued (a), twice.
        final added =
            await n.addTracks([tracks['a']!, tracks['x']!, tracks['a']!]);
        await settle();
        var s = c.read(audioPlayerProvider);
        expect(added, hasLength(3));
        expect(added.toSet(), hasLength(3));
        expect(shape(s), 'a One[b,c] d Two[e,f] a x a');
        expect(s.entryIds.toSet(), hasLength(9));
        expect(s.entryIds.take(6), before);
        expectInSync(s);

        // Play next with the same track again, on purpose.
        await n.addTracksAtFirst([tracks['a']!], allowDuplicates: true);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a a One[b,c] d Two[e,f] a x a');
        expect(s.entryIds[0], before[0]);
        expect(s.entryIds.toSet(), hasLength(10));
        expectInSync(s, playing: before[0]);

        // Without that, a track already queued is not added again.
        await n.addTracksAtFirst([tracks['b']!]);
        await n.addTrack(tracks['a']!);
        await settle();
        expect(shape(c.read(audioPlayerProvider)),
            'a a One[b,c] d Two[e,f] a x a');

        // Undo takes back the three that were added, not the older copies of a.
        await n.removeEntries(added);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a a One[b,c] d Two[e,f]');
        expect(s.entryIds[0], before[0]);
        expect(s.entryIds.toSet().containsAll(before), isTrue);
        expectInSync(s, playing: before[0]);
      });

      test(
          'removing a track by id removes the first copy only, and the group follows',
          () async {
        final (c, n) = await start(playing: 0);
        await n.addTracks([tracks['b']!]); // a second copy of b, loose
        await settle();
        await n.removeTrack(tracks['b']!.id);
        await settle();

        final s = c.read(audioPlayerProvider);
        // The first b (in the group) went; the loose copy stays.
        expect(shape(s), 'a One[c] d Two[e,f] b');
        expectInSync(s);
      });

      test('what was added stays where it was after a restart', () async {
        var (c, n) = await start(playing: 1);
        await n.addTracksAtFirst([tracks['x']!]);
        await n.addTrack(tracks['y']!);
        await settle();
        final before = c.read(audioPlayerProvider);
        expect(shape(before), 'a One[b,c] x d Two[e,f] y');
        c.dispose();

        (c, n) = await boot();
        final s = c.read(audioPlayerProvider);
        expect(shape(s), shape(before));
        expect(s.entryIds, before.entryIds);
        expect(s.currentIndex, before.currentIndex);
        expectInSync(s);
      });

      test('play next while shuffled in Dart keeps the groups whole', () async {
        final (c, n) = await start(playing: 0);
        await audioPlayer.setShuffle(true);
        await settle();
        var s = c.read(audioPlayerProvider);
        final playing = s.entryIds[s.currentIndex];

        await n.addTracksAtFirst([tracks['x']!]);
        await n.addTracks([tracks['y']!]);
        await settle();

        s = c.read(audioPlayerProvider);
        expect(s.groups.map((g) => g.memberIds.length), everyElement(2));
        expect(s.entryIds, hasLength(8));
        expectInSync(s, playing: playing);

        // Unshuffling keeps the groups too; the new tracks come last.
        await audioPlayer.setShuffle(false);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), startsWith('a One[b,c] d Two[e,f]'));
        expect(s.entryIds.toSet(), hasLength(8));
        expectInSync(s);
      });

      test(
          'play next while mpv shuffles a queue without groups still follows the playing track',
          () async {
        final (c, n) = await start(playing: 0, groups: false);
        await audioPlayer.setShuffle(true);
        await settle();
        var s = c.read(audioPlayerProvider);
        final playing = s.entryIds[s.currentIndex];
        final at = s.currentIndex;

        await n.addTracksAtFirst([tracks['x']!]);
        await settle();

        s = c.read(audioPlayerProvider);
        expect(name(s, at + 1), 'x');
        expectInSync(s, playing: playing);
      });
    },
  );
}
