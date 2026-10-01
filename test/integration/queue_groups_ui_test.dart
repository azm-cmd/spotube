import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Key, Offset, Size, UniqueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide find, Consumer;
import 'package:spotube/l10n/l10n.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/player_queue.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/logger/logger.dart';

import '../modules/player/queue_test_helpers.dart';
import 'queue_groups_player_test.dart' show findMpv, writeWav;

/// The queue screen, driven like a user would, on top of the real audio player
/// notifier, its database and libmpv. Skipped when libmpv is not installed.
///
/// (The notifier is not mocked: a tap in the list changes the real queue, and
/// the test then checks the queue, the list on screen, and mpv's playlist.)

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

void main() {
  final mpv = findMpv();

  group(
    'the queue screen with the real player',
    skip: mpv == null ? 'libmpv not found' : false,
    () {
      late Directory dir;
      late AppDatabase db;
      late Map<String, SpotubeTrackObject> tracks;

      setUpAll(() async {
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
        // Create the player now, in real time.
        await audioPlayer.stop();
        dir = Directory.systemTemp.createTempSync('queue_groups_ui_');
        tracks = {
          for (final name in ['a', 'b', 'c', 'd', 'e', 'f'])
            name: SpotubeTrackObject.localTrackFromFile(writeWav(dir, name)),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));

      tearDown(() async {
        await audioPlayer.stop();
        await db.close();
      });

      /// Real time for mpv and the database, with frames in between: what the
      /// UI starts is a chain of calls to mpv, each of which needs a reply.
      Future<void> wait(WidgetTester tester, [int ms = 600]) async {
        for (var i = 0; i < ms ~/ 150; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        // Not pumpAndSettle: with a player running there is always something
        // asking for the next frame.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      /// Starts the app on the saved database and shows the queue.
      Future<ProviderContainer> start(WidgetTester tester) async {
        tester.view.physicalSize = const Size(1000, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        // The app, its notifier and mpv live in real time, not in the fake
        // time of the widget test.
        final container = (await tester.runAsync(() async {
          final c = ProviderContainer(overrides: [
            databaseProvider.overrideWithValue(db),
            blacklistProvider.overrideWith(_NoBlacklist.new),
          ]);
          c.read(audioPlayerProvider);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return c;
        }))!;
        addTearDown(container.dispose);
        await wait(tester);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            key: UniqueKey(),
            container: container,
            child: ShadcnApp(
              theme: ThemeData(
                colorScheme: LegacyColorSchemes.lightSlate(),
                radius: .5,
                iconTheme: const IconThemeProperties(),
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ToastLayer(
                child: Scaffold(
                  child: Consumer(
                    builder: (context, ref, _) =>
                        PlayerQueue.fromAudioPlayerNotifier(
                      floating: false,
                      playlist: ref.watch(audioPlayerProvider),
                      notifier: ref.read(audioPlayerProvider.notifier),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await wait(tester);
        return container;
      }

      AudioPlayerState stateOf(ProviderContainer c) =>
          c.read(audioPlayerProvider);

      String name(AudioPlayerState s, int i) =>
          (s.tracks[i] as SpotubeLocalTrackObject)
              .path
              .split('/')
              .last
              .split('.')
              .first;

      /// `a One[b,c] d`: the shape of the queue, by file name.
      String shape(AudioPlayerState s) {
        final queue = s.groupedQueue;
        return [
          for (final item in queue.items)
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

      void expectScreenAndPlayerMatch(
          ProviderContainer c, WidgetTester tester) {
        final s = stateOf(c);
        expect(s.groupedQueue.validate(), isEmpty);
        expect(
          audioPlayer.playlist.medias.map((m) => m.uri).toList(),
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path],
          reason: 'mpv playlist',
        );
        expect(
          visibleRows(tester),
          [
            for (final r in buildQueueRows(
              s.groupedQueue,
              currentIndex: s.currentIndex,
            ))
              r.key,
          ],
          reason: 'rows on screen',
        );
      }

      testWidgets(
          'make a group, open it, play from it, move it, edit it, ungroup it, restart',
          (tester) async {
        var c = await start(tester);
        await tester.runAsync(() => c.read(audioPlayerProvider.notifier).load(
            [for (final t in tracks.values) t],
            autoPlay: false).timeout(const Duration(seconds: 20)));
        await wait(tester);
        expect(shape(stateOf(c)), 'a b c d e f');
        expect(visibleRows(tester).length, 6);

        // 1. Create a group of b and c from the list.
        await tester.tap(find.byKey(const Key('queue-group-select-toggle')));
        await tester.pumpAndSettle();
        final ids = stateOf(c).entryIds;
        await tapRow(tester, ids[1]);
        await tapRow(tester, ids[2]);
        await tester.tap(find.byKey(const Key('queue-group-selection-create')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const Key('queue-group-title-field')), 'Road trip');
        await tester.tap(find.byKey(const Key('queue-group-title-confirm')));
        await wait(tester);

        expect(shape(stateOf(c)), 'a Road trip[b,c] d e f');
        expect(find.text('Road trip'), findsOneWidget);
        expect(find.text('2 tracks'), findsOneWidget);
        expectScreenAndPlayerMatch(c, tester);

        // 2. Open it.
        await tapHeader(tester, stateOf(c).groups.single.id);
        await wait(tester);
        expect(shape(stateOf(c)), 'a Road trip+[b,c] d e f');
        expect(entry(ids[1]), findsOneWidget);
        expect(entry(ids[2]), findsOneWidget);
        expectScreenAndPlayerMatch(c, tester);

        // 3. Play c, inside the group. (The row shows a spinner until mpv has
        // answered, so the frames cannot be settled before real time passes.)
        final rect = tester.getRect(entry(ids[2]));
        await tester.tapAt(Offset(rect.left + 90, rect.center.dy));
        await tester.runAsync(() async {
          final end = DateTime.now().add(const Duration(seconds: 5));
          while (
              audioPlayer.playlist.index != 2 && DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        await wait(tester);
        expect(stateOf(c).currentIndex, 2);
        expect(isMarkedPlaying(ids[2]), isTrue);
        expect(isMarkedPlaying(ids[1]), isFalse);

        // Collapsed, the header says the group is the one playing.
        await tapHeader(tester, stateOf(c).groups.single.id);
        await wait(tester);
        expect(find.byKey(const Key('queue-group-playing')), findsOneWidget);
        await tapHeader(tester, stateOf(c).groups.single.id);
        await wait(tester);

        // 4. Move the whole group to the end.
        final groupKey = 'group:${stateOf(c).groups.single.id}';
        await dragTo(tester,
            from: groupKey, target: 'entry:${ids[5]}', drop: Drop.after);
        await wait(tester);
        expect(shape(stateOf(c)), 'a d e f Road trip+[b,c]');
        expectScreenAndPlayerMatch(c, tester);
        expect(stateOf(c).entryIds[stateOf(c).currentIndex], ids[2]);
        expect(audioPlayer.playlist.index, stateOf(c).currentIndex);

        // 5. Reorder a member inside the expanded group.
        await dragTo(tester,
            from: 'entry:${ids[1]}',
            target: 'entry:${ids[2]}',
            drop: Drop.after);
        await wait(tester);
        expect(shape(stateOf(c)), 'a d e f Road trip+[c,b]');
        expectScreenAndPlayerMatch(c, tester);
        expect(stateOf(c).entryIds[stateOf(c).currentIndex], ids[2]);

        // A member dragged far outside its group stays in it.
        await dragTo(tester,
            from: 'entry:${ids[2]}',
            target: 'entry:${ids[0]}',
            drop: Drop.before);
        await wait(tester);
        expect(stateOf(c).groupedQueue.groupOf(ids[2])?.title, 'Road trip');
        expectScreenAndPlayerMatch(c, tester);

        // 6. Rename.
        await openGroupMenu(tester, stateOf(c).groups.single.id);
        await tester.tap(find.byKey(const Key('queue-group-menu-rename')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const Key('queue-group-title-field')), 'Holiday');
        await tester.tap(find.byKey(const Key('queue-group-title-confirm')));
        await wait(tester);
        expect(find.text('Holiday'), findsOneWidget);

        // 7. Restart: the groups come back as they were.
        final before = shape(stateOf(c));
        final beforeIds = stateOf(c).entryIds;
        final beforeIndex = stateOf(c).currentIndex;
        c.dispose();
        await wait(tester);
        c = await start(tester);
        expect(shape(stateOf(c)), before);
        expect(stateOf(c).entryIds, beforeIds);
        expect(stateOf(c).currentIndex, beforeIndex);
        expect(find.text('Holiday'), findsOneWidget);
        expectScreenAndPlayerMatch(c, tester);

        // 8. Ungroup: the tracks stay where they are.
        final order = stateOf(c).entryIds;
        await openGroupMenu(tester, stateOf(c).groups.single.id);
        await tester.tap(find.byKey(const Key('queue-group-menu-ungroup')));
        await wait(tester);
        expect(stateOf(c).groups, isEmpty);
        expect(stateOf(c).entryIds, order);
        expect(find.byKey(const Key('queue-group-title')), findsNothing);
        expectScreenAndPlayerMatch(c, tester);
      });

      testWidgets(
          'shuffle keeps the groups together; copies of a track stay apart; members can be removed',
          timeout: const Timeout(Duration(minutes: 2)), (tester) async {
        final c = await start(tester);
        final notifier = c.read(audioPlayerProvider.notifier);
        await tester.runAsync(() async {
          await notifier.load(
            [for (final t in tracks.values) t],
            autoPlay: false,
          );
          // A second copy of track a, at the end.
          await notifier.addTracks([tracks['a']!]);
        });
        await wait(tester);
        var ids = stateOf(c).entryIds;
        expect(shape(stateOf(c)), 'a b c d e f a');

        // Two groups: [b c] and [e f]. Group them through the notifier, the
        // way the list does.
        await tester.runAsync(() async {
          await notifier.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
          await notifier.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
        });
        await wait(tester);
        expect(shape(stateOf(c)), 'a One[b,c] d Two[e,f] a');
        expectScreenAndPlayerMatch(c, tester);

        // The second copy of a plays: only that row is marked.
        final rect = tester.getRect(entry(ids[6]));
        await tester.tapAt(Offset(rect.left + 90, rect.center.dy));
        await tester.runAsync(() async {
          final end = DateTime.now().add(const Duration(seconds: 5));
          while (
              audioPlayer.playlist.index != 6 && DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        await wait(tester);
        expect(stateOf(c).currentIndex, 6);
        expect(isMarkedPlaying(ids[6]), isTrue);
        expect(isMarkedPlaying(ids[0]), isFalse);

        // Shuffle: every group stays whole and in order, every entry stays.
        final original = shape(stateOf(c));
        var order = original;
        for (var attempt = 0; attempt < 12 && order == original; attempt++) {
          await tester.runAsync(() async {
            await audioPlayer.setShuffle(false);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await audioPlayer.setShuffle(true);
          });
          await wait(tester);
          order = shape(stateOf(c));
          final parts = order.split(' ');
          expect(
              parts, unorderedEquals(['a', 'One[b,c]', 'd', 'Two[e,f]', 'a']));
          expect(stateOf(c).entryIds.toSet(), ids.toSet());
          expectScreenAndPlayerMatch(c, tester);
          expect(stateOf(c).entryIds[stateOf(c).currentIndex], ids[6]);
          expect(isMarkedPlaying(ids[6]), isTrue);
          expect(isMarkedPlaying(ids[0]), isFalse);
        }
        expect(order, isNot(original));

        // Back to the original order.
        await tester.runAsync(() => audioPlayer.setShuffle(false));
        await wait(tester);
        expect(shape(stateOf(c)), original);
        expectScreenAndPlayerMatch(c, tester);

        // Remove members, the way the row's "Remove from queue" does (it calls
        // removeEntries with the row's entry id): the group shrinks, then goes.
        Future<void> remove(String entryId) async {
          await tester.runAsync(() => notifier.removeEntries([entryId]));
          await wait(tester);
        }

        // Open group One to reach its members.
        await tapHeader(tester, stateOf(c).groups.first.id);
        await wait(tester);
        await remove(ids[1]);
        expect(shape(stateOf(c)), 'a One+[c] d Two[e,f] a');
        expect(find.text('1 track'), findsOneWidget);
        expectScreenAndPlayerMatch(c, tester);

        await remove(ids[2]);
        expect(shape(stateOf(c)), 'a d Two[e,f] a');
        expect(find.text('One'), findsNothing);
        expectScreenAndPlayerMatch(c, tester);

        // The loose copy of a can be removed without touching the playing one.
        await remove(ids[0]);
        expect(stateOf(c).entryIds, contains(ids[6]));
        expect(stateOf(c).entryIds, isNot(contains(ids[0])));
        expectScreenAndPlayerMatch(c, tester);
      });
    },
  );
}
