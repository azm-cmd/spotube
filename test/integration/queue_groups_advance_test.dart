import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';

import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// Tracks that really end, with queue changes asked for right at the end:
/// the app must come out of every one of them knowing which entry plays, with
/// the same queue as the player. Skipped without libmpv.

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

void main() {
  final mpv = findMpv();

  group(
    'a track ends by itself around queue changes, with the real player',
    skip: mpv == null ? 'libmpv not found' : false,
    () {
      late Directory dir;
      late AppDatabase db;
      late Map<String, SpotubeTrackObject> tracks;
      late Map<String, SpotubeTrackObject> longTracks;

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
        dir = Directory.systemTemp.createTempSync('queue_groups_advance_');
        tracks = {
          // One second each: they end while the test runs.
          for (final name in 'abcdefghijklmnop'.split(''))
            name: SpotubeTrackObject.localTrackFromFile(
              writeWav(dir, name, seconds: 1),
            ),
        };
        longTracks = {
          // Long ones: nothing ends unless the test moves on.
          for (final name in 'abcdefghijklmnop'.split(''))
            name: SpotubeTrackObject.localTrackFromFile(
              writeWav(Directory(dir.path)..createSync(), 'long_$name',
                  seconds: 120),
            ),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));

      tearDown(() async {
        await audioPlayer.stop();
        await db.close();
      });

      Future<void> settle([int ms = 600]) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      Future<void> until(Future<bool> Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(end)) {
          if (await condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('timed out waiting');
      }

      test('the app knows what plays and holds the player\'s queue', () async {
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
          autoPlay: true,
        );
        await settle(300);
        var ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[2], ids[3]]);
        await n.createGroup(title: 'Two', entryIds: [ids[5], ids[6]]);

        // Whenever the player goes on to another track by itself, ask for a
        // change in the same breath: it is sent while the player moves on.
        final spare = 'ijklmnop'.split('').toList();
        var fired = 0;
        var lastIndex = audioPlayer.currentIndex;
        final changes = <Future<void>>[];
        final subscription = audioPlayer.playlistStream.listen((playlist) {
          if (playlist.index == lastIndex || fired >= 6) return;
          lastIndex = playlist.index;
          fired++;
          final state = c.read(audioPlayerProvider);
          switch (fired % 4) {
            case 0:
              changes.add(n.addTracksAtFirst([tracks[spare.removeLast()]!]));
            case 1:
              changes.add(n.addTracks([tracks[spare.removeLast()]!]));
            case 2:
              if (state.groups.isNotEmpty) {
                changes.add(n.moveGroup(state.groups.first.id, 0));
              }
            default:
              changes.add(n.moveTrack(0, state.tracks.length - 1));
          }
        });

        // Let several tracks end.
        await until(() async => fired >= 3);
        await settle(1200);
        await subscription.cancel();
        await audioPlayer.pause();
        await Future.wait(changes.map((f) => f.then((_) {}, onError: (_) {})));
        await settle();

        final s = c.read(audioPlayerProvider);
        expect(s.groupedQueue.validate(), isEmpty);
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length));
        // The app's queue is the player's.
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
        );
        // And the entry the app says plays is the one the player plays.
        final truth = await audioPlayer.queryPlayingIndex();
        if (truth >= 0) {
          expect(s.currentIndex, truth);
          expect(audioPlayer.playlist.index, truth);
        }
      });

      test('the player moves on in the middle of a change: the app follows',
          () async {
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
          [for (final k in 'abcdefgh'.split('')) longTracks[k]!],
          autoPlay: true,
        );
        await settle(300);
        final ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[2], ids[3]]);
        await n.createGroup(title: 'Two', entryIds: [ids[5], ids[6]]);
        await settle(300);

        // Each change takes several commands; the player is told to go on
        // while they are being sent (it reports at once, and the report meets
        // the guard of the change).
        final spare = 'ijklmnop'.split('').toList();
        final changes = <String, Future<void> Function()>{
          'play next': () => n.addTracksAtFirst([
                for (var i = 0; i < 3; i++) longTracks[spare.removeLast()]!,
              ]),
          'add to queue': () => n.addTracks([
                for (var i = 0; i < 3; i++) longTracks[spare.removeLast()]!,
              ]),
          'group move': () =>
              n.moveGroup(c.read(audioPlayerProvider).groups.last.id, 0),
          'flat move': () => n.moveTrack(0, 4),
          'removal': () => n.removeEntries([
                c.read(audioPlayerProvider).entryIds.last,
              ]),
          'member reorder': () => n.moveWithinGroup(
              c.read(audioPlayerProvider).groups.first.id, 0, 2),
        };

        for (final entry in changes.entries) {
          final change = entry.value();
          unawaited(audioPlayer.skipToNext());
          await change;
          await settle(500);

          final s = c.read(audioPlayerProvider);
          final truth = await audioPlayer.queryPlayingIndex();
          expect(s.currentIndex, truth, reason: entry.key);
          expect(s.groupedQueue.validate(), isEmpty, reason: entry.key);
          expect(
            audioPlayer.playlist.medias.map((m) => m.uri).toList(),
            [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
            reason: entry.key,
          );
        }
      });

      test(
          'a drag and a jump from an older view still mean the rows they '
          'were made on', () async {
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
          [for (final k in 'abcdef'.split('')) longTracks[k]!],
          autoPlay: true,
        );
        await settle(300);
        var ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[2], ids[3]]);
        await settle(300);

        String name(int i) =>
            (c.read(audioPlayerProvider).tracks[i] as SpotubeLocalTrackObject)
                .path
                .split('long_')
                .last
                .split('.')
                .first;

        // The view the user (or a remote device) acts on:
        //   a  b  [One: c d]  e  f      rows 0..4, entries 0..5
        ids = c.read(audioPlayerProvider).entryIds;
        final eId = ids[4];
        final fId = ids[5];

        // A change is under way (it takes the queue's turn first) when the
        // drag and the jump arrive, both made on the view above.
        final insert = n.addTracksAtFirst([
          longTracks['k']!,
          longTracks['l']!,
        ]);
        final drag = n.moveQueueItem(3, 0); // e to the front
        final jump = n.jumpToIndex(5); // f
        await Future.wait([insert, drag, jump]);
        await settle(600);

        final s = c.read(audioPlayerProvider);
        expect(
          [for (var i = 0; i < s.tracks.length; i++) name(i)],
          ['e', 'a', 'k', 'l', 'b', 'c', 'd', 'f'],
        );
        expect(s.groups.single.memberIds, [ids[2], ids[3]]);
        // The jump went to f, not to whatever was at flat position 5 by then.
        expect(s.entryIds[s.currentIndex], fId);
        expect(s.entryIds.indexOf(eId), 0);
        expect(await audioPlayer.queryPlayingIndex(), s.currentIndex);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
        );
      });

      test(
          'a group drag and a member drag from an older view still mean the '
          'rows they were made on', () async {
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
          [for (final k in 'abcdef'.split('')) longTracks[k]!],
          autoPlay: true,
        );
        await settle(300);
        final ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[2], ids[3]]);
        await settle(300);
        final groupId = c.read(audioPlayerProvider).groups.single.id;

        String order() => [
              for (final t in c.read(audioPlayerProvider).tracks)
                (t as SpotubeLocalTrackObject)
                    .path
                    .split('long_')
                    .last
                    .split('.')
                    .first,
            ].join();

        // The view: a b [One: c d] e f. The drop asked for is "One before b"
        // (row 1) while a play next is still under way, which puts two tracks
        // in front: by position, row 1 would be one of them by then.
        final insert = n.addTracksAtFirst([longTracks['k']!, longTracks['l']!]);
        final drag = n.moveGroup(groupId, 1);
        await Future.wait([insert, drag]);
        await settle(500);
        expect(order(), 'aklcdbef');
        expect(c.read(audioPlayerProvider).groups.single.memberIds,
            [ids[2], ids[3]]);

        // "d before c" asked for while c is being removed: c is gone when it
        // runs, so there is nothing to move (and it is no error).
        final removal = n.removeEntries([ids[2]]);
        final member = n.moveWithinGroup(groupId, 1, 0);
        await Future.wait([removal, member]);
        await settle(500);
        expect(order(), 'akldbef');
        expect(await audioPlayer.queryPlayingIndex(),
            c.read(audioPlayerProvider).currentIndex);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [
            for (final t in c.read(audioPlayerProvider).tracks)
              (t as SpotubeLocalTrackObject).path
          ],
        );
      });

      test(
          'play next right after the player went on by itself goes after '
          'the entry that plays now', () async {
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
          [for (final k in 'abcd'.split('')) longTracks[k]!],
          autoPlay: true,
        );
        await settle(300);

        // mpv is on b; the app may not have heard yet.
        await audioPlayer.skipToNext();
        await n.addTracksAtFirst([longTracks['k']!]);
        await settle(500);

        final s = c.read(audioPlayerProvider);
        expect(
            [
              for (final t in s.tracks)
                (t as SpotubeLocalTrackObject)
                    .path
                    .split('long_')
                    .last
                    .split('.')
                    .first
            ].join(),
            'abkcd');
        expect(s.currentIndex, 1);
        expect(await audioPlayer.queryPlayingIndex(), 1);
      });
    },
  );
}
