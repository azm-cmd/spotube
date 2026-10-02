import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
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
import 'package:spotube/provider/discord_provider.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/logger/logger.dart';

import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// The saved queue is restored in the background when the app starts. Whatever
/// the user (or a remote device) did in the meantime is newer than it and must
/// not be overwritten. Skipped without libmpv.

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

/// Discord presence is a desktop service that is not running in tests.
class _NoDiscord extends DiscordNotifier {
  @override
  build() async {}

  @override
  Future<void> clear() async {}
}

/// Holds the result of every `SELECT` until released: the restore reads the
/// saved row with one, so this keeps the restore waiting, with the row of
/// before, while the test acts.
class _HoldSelects extends QueryInterceptor {
  Completer<void>? _hold;

  void hold() => _hold = Completer<void>();

  void release() {
    _hold?.complete();
    _hold = null;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    // Read first, then wait: the row handed over is the old one, however much
    // is written to the database in the meantime.
    final rows = await super.runSelect(executor, statement, args);
    await _hold?.future;
    return rows;
  }
}

void main() {
  final mpv = findMpv();

  group(
    'starting the app with a saved queue, with the real player',
    skip: mpv == null ? 'libmpv not found' : false,
    () {
      late Directory dir;
      late AppDatabase db;
      late _HoldSelects selects;
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
        dir = Directory.systemTemp.createTempSync('queue_groups_startup_');
        tracks = {
          for (final name in 'abcdefghijkl'.split(''))
            name: SpotubeTrackObject.localTrackFromFile(writeWav(dir, name)),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() {
        selects = _HoldSelects();
        db = AppDatabase.forTesting(
            NativeDatabase.memory().interceptWith(selects));
      });

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

      ProviderContainer app() {
        final c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          blacklistProvider.overrideWith(_NoBlacklist.new),
          discordProvider.overrideWith(_NoDiscord.new),
        ]);
        addTearDown(c.dispose);
        return c;
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

      /// The app's queue is valid and the player has exactly it.
      ///
      /// [afterStop]: media_kit keeps its own copy of the playlist and does not
      /// clear it in `stop()`, so tracks added to a stopped player show up
      /// after the old ones in that copy (mpv itself has only the new ones).
      /// That is how the player library behaves, not the queue; in that case
      /// only the end of the copy is compared.
      void expectInSync(AudioPlayerState s, {bool afterStop = false}) {
        expect(s.groupedQueue.validate(), isEmpty);
        final player = audioPlayer.playlist.medias.map((m) => m.uri).toList();
        final queue = [
          for (final t in s.tracks) (t as SpotubeLocalTrackObject).path,
        ];
        expect(
          afterStop ? player.sublist(player.length - queue.length) : player,
          queue,
        );
      }

      /// A saved queue `a One[b,c] d` on the database, from an earlier run.
      Future<void> saveEarlierRun({List<String> collections = const []}) async {
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await until(() async =>
            (await db.select(db.audioPlayerStateTable).get()).isNotEmpty);
        await settle();
        await n.load(
          [for (final k in 'abcd'.split('')) tracks[k]!],
          autoPlay: false,
        );
        await settle();
        final ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        if (collections.isNotEmpty) await n.addCollections(collections);
        await settle();
        c.dispose();
        // The next run is a new process: its player starts with nothing in it.
        await audioPlayer.stop();
      }

      test('without anything in between, the saved queue comes back', () async {
        await saveEarlierRun();
        final c = app();
        c.read(audioPlayerProvider);
        await until(() async => c.read(audioPlayerProvider).tracks.isNotEmpty);
        await settle();
        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'a One[b,c] d');
        expectInSync(s);
      });

      test('a queue loaded before the restore is read is not replaced',
          () async {
        await saveEarlierRun();

        selects.hold(); // the restore can not read the saved row yet
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await n.load(
          [for (final k in 'efgh'.split('')) tracks[k]!],
          autoPlay: false,
        );

        selects.release(); // now the restore finds its row...
        await settle(1000);

        // ...and leaves the newer queue alone.
        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'e f g h');
        expectInSync(s);
        final saved = (await db.select(db.audioPlayerStateTable).getSingle());
        expect(saved.tracks.tracks.map((t) => t.name), isNot(contains('a')));
        expect(saved.tracks.groups, isEmpty);
      });

      test(
          'the collections of the earlier queue do not come back to a newer '
          'one', () async {
        await saveEarlierRun(collections: ['old-collection']);

        selects.hold();
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await n.load(
          [for (final k in 'efgh'.split('')) tracks[k]!],
          autoPlay: false,
        );
        selects.release();
        await settle(1000);

        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'e f g h');
        expect(s.collections, isEmpty);
      });

      test('tracks added before the restore is read are not lost', () async {
        await saveEarlierRun();

        selects.hold();
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await n.addTracks([tracks['i']!, tracks['j']!]);
        selects.release();
        await settle(1000);

        final s = c.read(audioPlayerProvider);
        expect(shape(s), 'i j');
        expectInSync(s, afterStop: true);
      });

      test('a queue cleared before the restore is read stays cleared',
          () async {
        await saveEarlierRun();

        selects.hold();
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await n.stop();
        selects.release();
        await settle(1000);

        final s = c.read(audioPlayerProvider);
        expect(s.tracks, isEmpty);
        expect(audioPlayer.playlist.medias, isEmpty);
      });

      test('a change racing the restore leaves one consistent queue', () async {
        await saveEarlierRun();

        selects.hold();
        final c = app();
        final n = c.read(audioPlayerProvider.notifier);
        await settle(); // the restore is waiting for its row
        selects.release();
        // The row arrives and this is asked for at the same moment. Whichever
        // is first, the other does not undo it: either the saved queue is
        // restored and the track added after it, or the track is the queue
        // and the older saved one is left out.
        await n.addTracks([tracks['k']!]);
        await settle(1000);

        final s = c.read(audioPlayerProvider);
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length));
        expect(shape(s), anyOf('k', 'a One[b,c] d k'));
        expectInSync(s, afterStop: true);
      });
    },
  );
}
