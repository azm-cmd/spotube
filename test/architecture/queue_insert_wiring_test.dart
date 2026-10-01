import 'dart:io';

import 'package:test/test.dart';

/// Every way of putting tracks into the queue ("play next", "add to queue",
/// album and playlist bulk adds, endless playback) ends in one place, which
/// inserts through the queue sync so that groups are never split. These tests
/// read the source to keep it that way.
///
/// Run from the package root (as `flutter test` does).
void main() {
  String read(String path) => File(path).readAsStringSync();

  final notifier = read('lib/provider/audio_player/audio_player.dart');

  /// The text of the method that starts at [signature], up to the next one.
  String body(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    final next = source.indexOf(
      RegExp(r'\n  (@override\n  )?(Future|void|bool|late|String|List)'),
      start + signature.length,
    );
    return source.substring(start, next == -1 ? source.length : next);
  }

  test('only the insert helper puts tracks into the player', () {
    final lines = notifier.split('\n');
    final callers = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final code = lines[i].trimLeft();
      if (code.startsWith('//')) continue;
      if (RegExp(r'audioPlayer\.addTrack(At)?\(').hasMatch(code)) {
        callers.add('${i + 1}: $code');
      }
    }
    // The helper (append and insert) and swapActiveSource, which swaps the
    // source of the playing entry in place.
    expect(callers, hasLength(3), reason: callers.join('\n'));

    final helper = body(notifier, 'Future<List<String>> _insertTracks(');
    expect(helper, contains('audioPlayer.addTrack('));
    expect(helper, contains('audioPlayer.addTrackAt('));
    final swap = body(notifier, 'Future<void> swapActiveSource()');
    expect(swap, contains('audioPlayer.addTrackAt('));
  });

  test('no other code reaches the player to add tracks', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.startsWith('lib/services/audio_player/')) continue;
      if (entity.path == 'lib/provider/audio_player/audio_player.dart')
        continue;
      final text = entity.readAsStringSync();
      expect(
        RegExp(r'audioPlayer\.addTrack(At)?\(').hasMatch(text),
        isFalse,
        reason: '${entity.path} adds tracks without the queue',
      );
    }
  });

  test('play next, add to queue and bulk adds all use the helper', () {
    final next = body(notifier, 'Future<void> addTracksAtFirst(');
    final one = body(notifier, 'Future<void> addTrack(');
    final many = body(notifier, 'Future<List<String>> addTracks(');

    expect(next, contains('_insertTracks('));
    expect(next, contains('afterPlaying: true'));
    expect(one, contains('_insertTracks('));
    expect(one, contains('afterPlaying: false'));
    expect(many, contains('_insertTracks('));
    expect(many, contains('afterPlaying: false'));
  });

  test('the helper inserts through the sync, one change at a time', () {
    final helper = body(notifier, 'Future<List<String>> _insertTracks(');
    expect(helper, contains('_sync.exclusive('));
    expect(helper, contains('_sync.insert('));
    expect(helper, contains('playNextIndex('));
    expect(helper, contains('createEntries('));
    expect(helper, contains('_newEntryId'));
    // The playing entry is looked up inside the exclusive section.
    expect(helper.indexOf('_sync.exclusive('),
        lessThan(helper.indexOf('_snapshot')));
    // New entries are never made members of a group.
    expect(helper, isNot(contains('createGroup')));
    expect(helper, isNot(contains('addToGroup')));
  });

  test('removing by track id goes through the entry removal', () {
    final one = body(notifier, 'Future<void> removeTrack(');
    final many = body(notifier, 'Future<void> removeTracks(');
    expect(one, contains('removeEntries('));
    expect(many, contains('removeEntries('));
    expect(one, isNot(contains('audioPlayer.removeTrack')));
    expect(many, isNot(contains('audioPlayer.removeTrack')));
  });

  test('taking back a bulk add removes exactly the entries that were added',
      () {
    for (final path in [
      'lib/modules/album/album_card.dart',
      'lib/modules/playlist/playlist_card.dart',
    ]) {
      final text = read(path);
      expect(text, contains('final added = playlistNotifier.addTracks('),
          reason: path);
      expect(text, contains('added.then(playlistNotifier.removeEntries)'),
          reason: path);
      expect(text, isNot(contains('.removeTracks(')), reason: path);
    }
  });

  test('every entry point calls the notifier', () {
    // Single track menu and track page: play next / add to queue.
    final options =
        read('lib/provider/track_options/track_options_provider.dart');
    expect(options, contains('playback.addTracksAtFirst([track])'));
    expect(options, contains('playback.addTrack(track)'));
    expect(read('lib/pages/track/track.dart'),
        contains('.addTracksAtFirst([track])'));

    // Album and playlist pages, selections: play next / add to queue.
    final actions =
        read('lib/components/track_presentation/presentation_actions.dart');
    expect(actions, contains('playlistNotifier.addTracksAtFirst(tracks)'));
    expect(actions, contains('playlistNotifier.addTracks(tracks)'));
  });
}
