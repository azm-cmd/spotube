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
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/logger/logger.dart';

import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// Edge cases of the queue with the real player: a drop after the last track,
/// and a track queued more than once (every operation on one copy leaves the
/// others alone). Skipped without libmpv.

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

void main() {
  final mpv = findMpv();

  group(
    'queue edge cases, with the real player',
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
        dir = Directory.systemTemp.createTempSync('queue_groups_edges_');
        tracks = {
          for (final name in 'abcdef'.split(''))
            name: SpotubeTrackObject.localTrackFromFile(
              writeWav(dir, name, seconds: 120),
            ),
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

      Future<(ProviderContainer, AudioPlayerNotifier)> app(
        List<String> names,
      ) async {
        final c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          blacklistProvider.overrideWith(_NoBlacklist.new),
        ]);
        addTearDown(c.dispose);
        final n = c.read(audioPlayerProvider.notifier);
        await until(() async =>
            (await db.select(db.audioPlayerStateTable).get()).isNotEmpty);
        await settle();
        await n.load([for (final k in names) tracks[k]!], autoPlay: true);
        await settle(300);
        return (c, n);
      }

      String order(ProviderContainer c) => [
            for (final t in c.read(audioPlayerProvider).tracks)
              (t as SpotubeLocalTrackObject).path.split('/').last[0],
          ].join();

      Future<void> expectPlayerHasQueue(ProviderContainer c) async {
        final s = c.read(audioPlayerProvider);
        expect(s.groupedQueue.validate(), isEmpty);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
        );
        expect(await audioPlayer.queryPlayingIndex(), s.currentIndex);
      }

      group('a drop after the last track', () {
        test('is ignored by the flat move, as it always was', () async {
          final (c, n) = await app(['a', 'b', 'c', 'd']);

          await n.moveTrack(0, 4); // newIndex == length: below the last row
          await settle(300);
          expect(order(c), 'abcd');

          await n.moveTrack(0, 3); // onto the last track's place: works
          await settle(300);
          expect(order(c), 'bcad'); // before d: not past it
          await expectPlayerHasQueue(c);
        });

        test('is a move to the end for a drag of whole rows', () async {
          final (c, n) = await app(['a', 'b', 'c', 'd']);
          final ids = c.read(audioPlayerProvider).entryIds;
          await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);

          await n.moveQueueItem(0, 3); // rows: a, One, d -> after d
          await settle(300);
          expect(order(c), 'bcda');
          await expectPlayerHasQueue(c);
        });
      });

      group('a track queued more than once', () {
        // Loading a queue leaves out repeated tracks (as it always did); a
        // track is queued twice by adding it again.
        Future<(ProviderContainer, AudioPlayerNotifier)> withCopies(
          List<String> names,
          List<String> more,
        ) async {
          final (c, n) = await app(names);
          await n.addTracks([for (final k in more) tracks[k]!]);
          await settle(300);
          return (c, n);
        }

        test('removing one copy leaves the other', () async {
          final (c, n) = await withCopies(['a', 'b', 'c'], ['a']);
          final ids = c.read(audioPlayerProvider).entryIds;
          expect(order(c), 'abca');

          await n.removeEntries([ids[3]]);
          await settle(300);
          expect(order(c), 'abc');
          expect(c.read(audioPlayerProvider).entryIds, ids.sublist(0, 3));
          await expectPlayerHasQueue(c);

          await n.addTracks([tracks['a']!]);
          await settle(300);
          final again = c.read(audioPlayerProvider).entryIds;
          await n.removeEntries([again[0]]); // the first copy, not the new one
          await settle(300);
          expect(order(c), 'bca');
          expect(c.read(audioPlayerProvider).entryIds,
              ids.sublist(1, 3) + [again[3]]);
          await expectPlayerHasQueue(c);
        });

        test('jumping to a copy plays that copy', () async {
          final (c, n) = await withCopies(['a', 'b', 'c'], ['a']);
          final ids = c.read(audioPlayerProvider).entryIds;

          await n.jumpToEntry(ids[3]);
          await settle(500);
          final s = c.read(audioPlayerProvider);
          expect(s.currentIndex, 3);
          expect(s.entryIds[s.currentIndex], ids[3]);
          await expectPlayerHasQueue(c);

          await n.jumpToIndex(0); // and the first one again
          await settle(500);
          expect(
              c
                  .read(audioPlayerProvider)
                  .entryIds[c.read(audioPlayerProvider).currentIndex],
              ids[0]);
          await expectPlayerHasQueue(c);
        });

        test('moving, grouping and reordering a copy touch only that copy',
            () async {
          final (c, n) = await withCopies(['a', 'b', 'c'], ['a', 'a']);
          final ids = c.read(audioPlayerProvider).entryIds;
          expect(order(c), 'abcaa');

          await n.moveTrack(4, 0); // the last a to the front
          await settle(300);
          expect(c.read(audioPlayerProvider).entryIds,
              [ids[4], ids[0], ids[1], ids[2], ids[3]]);

          // Group the two copies that are side by side now: ids[4], ids[0].
          await n.createGroup(title: 'Twice', entryIds: [ids[4], ids[0]]);
          await settle(300);
          final group = c.read(audioPlayerProvider).groups.single;
          expect(group.memberIds, [ids[4], ids[0]]);

          await n.moveWithinGroup(group.id, 1, 0); // ids[0] first in the group
          await settle(300);
          expect(c.read(audioPlayerProvider).groups.single.memberIds,
              [ids[0], ids[4]]);
          expect(c.read(audioPlayerProvider).entryIds,
              [ids[0], ids[4], ids[1], ids[2], ids[3]]);
          expect(order(c), 'aabca');
          await expectPlayerHasQueue(c);
        });

        test(
            'adding a track that is queued puts a second entry, not a '
            'second identity', () async {
          final (c, n) = await app(['a', 'b']);

          await n.addTracksAtFirst([tracks['a']!], allowDuplicates: true);
          await settle(300);
          final s = c.read(audioPlayerProvider);
          expect(order(c), 'aab');
          expect(s.entryIds.toSet(), hasLength(3));
          await expectPlayerHasQueue(c);
        });
      });
    },
  );
}
