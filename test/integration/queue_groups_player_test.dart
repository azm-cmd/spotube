import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_persistence.dart';
import 'package:spotube/services/logger/logger.dart';

/// Queue groups against the real player: the audio player notifier, its
/// database, and libmpv itself, with short generated audio files as tracks.
///
/// These tests need libmpv on the machine (`libmpv.so.2`) and are skipped when
/// it is not there.

String? findMpv() {
  for (final path in [
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/aarch64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
    '/usr/local/lib/libmpv.so.2',
  ]) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

class _NoBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

/// A silent WAV file, long enough that nothing ends while a test runs.
File writeWav(Directory dir, String name, {int seconds = 120}) {
  const rate = 8000;
  final samples = rate * seconds;
  final data = ByteData(44 + samples);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + samples, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate, Endian.little);
  data.setUint16(32, 1, Endian.little);
  data.setUint16(34, 8, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setUint8(44 + i, 128);
  }
  return File('${dir.path}/$name.wav')
    ..writeAsBytesSync(data.buffer.asUint8List());
}

void main() {
  final mpv = findMpv();

  group(
    'queue groups with the real player',
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
        dir = Directory.systemTemp.createTempSync('queue_groups_');
        tracks = {
          for (final name in ['a', 'b', 'c', 'd', 'e', 'f'])
            name: SpotubeTrackObject.localTrackFromFile(writeWav(dir, name)),
        };
      });

      tearDownAll(() => dir.deleteSync(recursive: true));

      setUp(() {
        db = AppDatabase.forTesting(NativeDatabase.memory());
      });

      tearDown(() async {
        await audioPlayer.stop();
        await db.close();
      });

      /// A new app session on the same database.
      Future<(ProviderContainer, AudioPlayerNotifier)> boot() async {
        final c = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          blacklistProvider.overrideWith(_NoBlacklist.new),
        ]);
        addTearDown(c.dispose);
        final notifier = c.read(audioPlayerProvider.notifier);
        // The row is created in the background when the notifier is built.
        await until(
          () async =>
              (await db.select(db.audioPlayerStateTable).get()).isNotEmpty,
        );
        await settle();
        return (c, notifier);
      }

      List<String> mpvPaths() =>
          audioPlayer.playlist.medias.map((m) => m.uri).toList();

      List<String> paths(AudioPlayerState s) =>
          [for (final t in s.tracks) (t as SpotubeLocalTrackObject).path];

      /// `a`, `G1[b,c]`: the top-level shape of the queue, by file name.
      String shape(AudioPlayerState s) {
        String name(int i) => (s.tracks[i] as SpotubeLocalTrackObject)
            .path
            .split('/')
            .last
            .split('.')
            .first;
        final queue = s.groupedQueue;
        return [
          for (final item in queue.items)
            switch (item) {
              EntryItem<SpotubeTrackObject>(:final entry) =>
                name(s.entryIds.indexOf(entry.id)),
              GroupItem<SpotubeTrackObject>(:final group, :final entries) =>
                '${group.title}${group.collapsed ? '' : '+'}[${[
                  for (final e in entries) name(s.entryIds.indexOf(e.id))
                ].join(',')}]',
            },
        ].join(' ');
      }

      /// The invariant: the queue, its groups and mpv's playlist agree.
      void expectInSync(AudioPlayerState s, {String? reason}) {
        expect(s.entryIds.toSet(), hasLength(s.entryIds.length),
            reason: reason);
        expect(s.groupedQueue.validate(), isEmpty, reason: reason);
        expect(mpvPaths(), paths(s), reason: 'mpv playlist $reason');
      }

      /// The saved queue, read back the way the next start would.
      Future<SavedQueue<SpotubeTrackObject>> saved() async =>
          (await db.select(db.audioPlayerStateTable).getSingle()).tracks;

      Future<void> loadAll(AudioPlayerNotifier n) async {
        await n.load([for (final t in tracks.values) t], autoPlay: false);
        await settle();
      }

      test('groups are made, shown in the player, and kept in step', () async {
        final (c, n) = await boot();
        await loadAll(n);
        var s = c.read(audioPlayerProvider);
        expect(shape(s), 'a b c d e f');
        expectInSync(s);

        final ids = s.entryIds;
        final g1 =
            await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
        await settle();
        s = c.read(audioPlayerProvider);

        expect(shape(s), 'a One[b,c] d Two[e,f]');
        expect(
            s.groups.every((g) => g.collapsed), isTrue); // collapsed by default
        expectInSync(s);

        // Collapse, expand, rename and ungroup change the groups only.
        await n.setGroupCollapsed(g1, false);
        await n.renameGroup(g1, 'Uno');
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a Uno+[b,c] d Two[e,f]');
        expectInSync(s);
      });

      test(
          'moving a group, and a member, keeps the group whole and the playing track playing',
          () async {
        final (c, n) = await boot();
        await loadAll(n);
        var s = c.read(audioPlayerProvider);
        final ids = s.entryIds;
        final g1 =
            await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        await n.setGroupCollapsed(g1, false);
        await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);

        // c plays, inside group One.
        await n.jumpToEntry(ids[2]);
        await until(() async => audioPlayer.playlist.index == 2);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(s.currentIndex, 2);

        // The whole group moves to the end.
        await n.moveGroup(g1, s.groupedQueue.items.length);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a d Two[e,f] One+[b,c]');
        expectInSync(s);
        expect(s.entryIds[s.currentIndex], ids[2]);
        expect(audioPlayer.playlist.index, s.currentIndex);

        // A member moves inside its group only.
        await n.moveWithinGroup(g1, 0, 2);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a d Two[e,f] One+[c,b]');
        expectInSync(s);
        expect(s.entryIds[s.currentIndex], ids[2]);

        // A loose track moves among the top-level rows.
        await n.moveQueueItem(0, 3);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'd Two[e,f] a One+[c,b]');
        expectInSync(s);
        expect(s.entryIds[s.currentIndex], ids[2]);
      });

      test(
          'groups, titles, collapsed state and the playing track survive a restart',
          () async {
        var (c, n) = await boot();
        await loadAll(n);
        var s = c.read(audioPlayerProvider);
        final ids = s.entryIds;
        final g1 =
            await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
        await n.setGroupCollapsed(g1, false);
        await n.renameGroup(g1, 'Road trip');
        await n.jumpToEntry(ids[2]);
        await until(() async => audioPlayer.playlist.index == 2);
        await settle();

        final before = c.read(audioPlayerProvider);
        expect(shape(before), 'a Road trip+[b,c] d Two[e,f]');
        c.dispose();

        // The saved row alone says all of it.
        final row = await saved();
        expect(row.issues, isEmpty);
        expect(row.entries.map((e) => e.id), before.entryIds);
        expect(row.groups, before.groups);

        (c, n) = await boot();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a Road trip+[b,c] d Two[e,f]');
        expect(s.entryIds, before.entryIds);
        expect(s.groups, before.groups);
        expect(s.currentIndex, 2);
        expect(s.entryIds[s.currentIndex], ids[2]);
        expectInSync(s);

        // And it still works after the restart.
        await n.ungroup(s.groups.last.id);
        await settle();
        expect(shape(c.read(audioPlayerProvider)), 'a Road trip+[b,c] d e f');
      });

      test('a collapse or rename that moves nothing is still saved', () async {
        final (c, n) = await boot();
        await loadAll(n);
        final ids = c.read(audioPlayerProvider).entryIds;
        final g = await n.createGroup(title: 'One', entryIds: [ids[1], ids[2]]);
        await settle();
        expect((await saved()).groups.single.title, 'One');
        expect((await saved()).groups.single.collapsed, isTrue);

        await n.setGroupCollapsed(g, false);
        await settle();
        expect((await saved()).groups.single.collapsed, isFalse);

        await n.renameGroup(g, 'Two');
        await settle();
        expect((await saved()).groups.single.title, 'Two');

        await n.ungroup(g);
        await settle();
        expect((await saved()).groups, isEmpty);
      });

      test('two copies of one track are two entries, in and out of a group',
          () async {
        final (c, n) = await boot();
        await loadAll(n);
        // A second copy of `a`, at the end.
        await n.addTracks([tracks['a']!]);
        await settle();
        var s = c.read(audioPlayerProvider);
        expect(shape(s), 'a b c d e f a');
        final ids = s.entryIds;
        expect(ids.toSet(), hasLength(7));

        // Group the last copy of `a` with `f`; the first copy stays loose.
        final g =
            await n.createGroup(title: 'Tail', entryIds: [ids[5], ids[6]]);
        await n.setGroupCollapsed(g, false);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a b c d e Tail+[f,a]');
        expect(s.groupedQueue.groupOf(ids[6])?.title, 'Tail');
        expect(s.groupedQueue.groupOf(ids[0]), isNull);
        expectInSync(s);

        // The second copy plays; the first one does not.
        await n.jumpToEntry(ids[6]);
        await until(() async => audioPlayer.playlist.index == 6);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(s.currentIndex, 6);

        // Moving the group to the front moves the copy that plays with it.
        await n.moveGroup(g, 0);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'Tail+[f,a] a b c d e');
        expect(s.entryIds[s.currentIndex], ids[6]);
        expect(audioPlayer.playlist.index, s.currentIndex);
        expectInSync(s);

        // Remove the loose copy: the grouped copy stays, group and all.
        await n.removeEntries([ids[0]]);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'Tail+[f,a] b c d e');
        expect(s.entryIds, contains(ids[6]));
        expectInSync(s);

        // And they survive a restart as the same two entries.
        c.dispose();
        final (c2, _) = await boot();
        final back = c2.read(audioPlayerProvider);
        expect(back.entryIds, s.entryIds);
        expect(shape(back), 'Tail+[f,a] b c d e');
      });

      test(
          'removing group members: the group shrinks and goes with the last one',
          () async {
        final (c, n) = await boot();
        await loadAll(n);
        final ids = c.read(audioPlayerProvider).entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[1], ids[2], ids[3]]);
        await settle();

        await n.removeEntries([ids[2]]);
        await settle();
        var s = c.read(audioPlayerProvider);
        expect(shape(s), 'a One[b,d] e f');
        expectInSync(s);

        await n.removeEntries([ids[1], ids[3]]);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), 'a e f');
        expect(s.groups, isEmpty);
        expectInSync(s);
        expect((await saved()).groups, isEmpty);
      });

      test(
          'shuffle keeps every group together and in its own order, and survives a restart',
          () async {
        var (c, n) = await boot();
        await loadAll(n);
        var s = c.read(audioPlayerProvider);
        final ids = s.entryIds;
        await n.createGroup(title: 'One', entryIds: [ids[0], ids[1], ids[2]]);
        await n.createGroup(title: 'Two', entryIds: [ids[4], ids[5]]);
        await settle();
        final original = shape(c.read(audioPlayerProvider));
        expect(original, 'One[a,b,c] d Two[e,f]');

        // Shuffle until the order is different (it is random).
        var order = original;
        for (var attempt = 0; attempt < 12 && order == original; attempt++) {
          await audioPlayer.setShuffle(false);
          await settle();
          await audioPlayer.setShuffle(true);
          await settle();
          s = c.read(audioPlayerProvider);
          order = shape(s);

          // Whatever the order: groups whole, members in order, mpv agrees.
          expect(order.split(' '),
              unorderedEquals(['One[a,b,c]', 'd', 'Two[e,f]']));
          expect(audioPlayer.isShuffled, isTrue);
          expectInSync(s, reason: 'shuffled, attempt $attempt');
          expect(s.entryIds.toSet(), ids.toSet());
        }
        expect(order, isNot(original),
            reason: 'twelve shuffles never changed the order');
        final shuffled = shape(s);
        final dartShuffleSaved = (await saved()).shuffleOrder;
        expect(dartShuffleSaved, ids);

        // Restart: still shuffled, same order, groups intact.
        c.dispose();
        (c, n) = await boot();
        s = c.read(audioPlayerProvider);
        expect(shape(s), shuffled);
        expect(audioPlayer.isShuffled, isTrue);
        expectInSync(s);

        // Unshuffle after the restart: the original order is back.
        await audioPlayer.setShuffle(false);
        await settle();
        s = c.read(audioPlayerProvider);
        expect(shape(s), original);
        expect(audioPlayer.isShuffled, isFalse);
        expectInSync(s);
        expect((await saved()).shuffleOrder, isNull);
      });

      test('a queue without groups still shuffles with mpv', () async {
        final (c, n) = await boot();
        await loadAll(n);
        await audioPlayer.setShuffle(true);
        await settle();
        expect(audioPlayer.isShuffled, isTrue);
        final s = c.read(audioPlayerProvider);
        expect(s.groups, isEmpty);
        expect(paths(s).toSet(), {
          for (final t in tracks.values) (t as SpotubeLocalTrackObject).path
        });
        expect(mpvPaths(), paths(s));
        await audioPlayer.setShuffle(false);
        await settle();
        expect(shape(c.read(audioPlayerProvider)), 'a b c d e f');
      });
    },
  );
}

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
