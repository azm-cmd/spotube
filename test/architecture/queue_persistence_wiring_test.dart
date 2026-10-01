import 'dart:io';

import 'package:test/test.dart';

/// The notifier cannot be built without the app around it, so these tests read
/// its source and check the rules that keep the saved queue complete:
///
///  * every write of the queue saves the whole of it (entries with their ids,
///    groups and shuffle order), never the bare list of tracks;
///  * a saved queue is restored with its ids and groups, not with new ids;
///  * a saved Dart shuffle is restored before the queue is opened.
///
/// Run from the package root (as `flutter test` does).
void main() {
  final source =
      File('lib/provider/audio_player/audio_player.dart').readAsStringSync();

  /// The text of the method that starts at [signature], up to the next method.
  String methodBody(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    final next = source.indexOf(RegExp(r'\n  @override|\n  (Future|void|late)'),
        start + signature.length);
    return source.substring(start, next == -1 ? source.length : next);
  }

  test('every write of `tracks` saves the whole saved queue', () {
    final writes = RegExp(r'tracks:\s*(const\s+)?Value\(([^)]*\)?)\)')
        .allMatches(source)
        .map((m) => m.group(0)!)
        .toList();

    expect(writes, isNotEmpty);
    for (final write in writes) {
      expect(
        write.contains('_savedQueue') ||
            write.contains('SavedQueue<SpotubeTrackObject>.empty()'),
        isTrue,
        reason: 'saves less than the whole queue: $write',
      );
    }
    expect(source.contains('Value(state.tracks)'), isFalse);
  });

  test('the saved queue is built from the grouped queue and the shuffler', () {
    final body = methodBody('SavedQueue<SpotubeTrackObject> get _savedQueue');
    expect(body, contains('_grouped'));
    expect(body, contains('queue.groups'));
    expect(body, contains('_shuffler.orderBeforeShuffle'));
  });

  test('restoring keeps the saved ids and groups', () {
    final body = methodBody('Future<void> _syncSavedState()');
    expect(body, contains('withGroupedQueue(saved.queue)'));
    expect(body, isNot(contains('createEntries(')));
    expect(body, isNot(contains('groups: []')));
  });

  test('a saved Dart shuffle is restored before the queue is opened', () {
    final body = methodBody('Future<void> _syncSavedState()');
    final restore = body.indexOf('_shuffler.restore(');
    final open = body.indexOf('audioPlayer.openPlaylist(');

    expect(restore, isNonNegative);
    expect(open, isNonNegative);
    expect(restore, lessThan(open));
  });

  test('tracks that could not be read do not move the playing track', () {
    final body = methodBody('Future<void> _syncSavedState()');
    expect(body, contains('remapCurrentIndex('));
    expect(body, contains('saved.droppedPositions'));
  });

  test('the row is read through the converter, which never throws', () {
    final table = File('lib/models/database/tables/audio_player_state.dart')
        .readAsStringSync();
    expect(table, contains('SavedQueueConverter'));
    expect(table, contains('decodeSavedQueue'));
    expect(table, isNot(contains('jsonDecode(fromDb) as List')));
  });
}
