import 'dart:io';

import 'package:test/test.dart';

/// mpv's own shuffle mixes the whole playlist and would tear queue groups
/// apart. These tests read the source and make sure it can only be reached
/// through the one path that checks for groups first, so that a new caller
/// cannot quietly bring the problem back.
///
/// Run from the package root (as `flutter test` does).
void main() {
  final dartFiles = [
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.endsWith('.g.dart') &&
          !entity.path.endsWith('.freezed.dart'))
        entity,
  ];

  /// Lines (as `path:line`) of non-comment code matching [pattern].
  List<String> uses(Pattern pattern) {
    final found = <String>[];
    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].trimLeft();
        if (code.startsWith('//')) continue;
        if (code.contains(pattern)) found.add('${file.path}:${i + 1}');
      }
    }
    return found;
  }

  test('the source was found', () {
    expect(dartFiles, isNotEmpty);
  });

  test('only one place calls the media_kit player\'s shuffle', () {
    final calls = uses(RegExp(r'_mkPlayer\.setShuffle\('));
    expect(calls.length, 1, reason: 'found: $calls');
    expect(calls.single,
        startsWith('lib/services/audio_player/audio_player_impl.dart'));
  });

  test('nothing sends mpv the shuffle commands directly', () {
    expect(uses('playlist-shuffle'), isEmpty);
    expect(uses('playlist-unshuffle'), isEmpty);
    expect(uses(RegExp(r'nativePlayer[^;]*shuffle', caseSensitive: false)),
        isEmpty);
  });

  test('only the shuffle guard may ask for mpv\'s flat shuffle', () {
    final callers = uses(RegExp(r'\bsetFlatShuffle\(')).toSet();
    final files = {for (final c in callers) c.split(':').first};
    expect(files, {
      // the definition, which forwards to media_kit
      'lib/services/audio_player/audio_player_impl.dart',
      // the guard: only used for a queue without groups
      'lib/services/audio_player/queue_shuffle.dart',
      // the adapter that connects the guard to the real player
      'lib/provider/audio_player/audio_player.dart',
    });
  });

  test('every shuffle request goes through the handler first', () {
    final source = File('lib/services/audio_player/audio_player_impl.dart')
        .readAsStringSync();
    final setShuffle = RegExp(
      r'Future<void> setShuffle\(bool shuffle\) async \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(source);
    expect(setShuffle, isNotNull);
    final body = setShuffle!.group(1)!;
    expect(body, contains('shuffleHandler'));
    // the only fall-through is the "no owner installed yet" case
    expect(RegExp(r'_mkPlayer\.').hasMatch(body), isFalse,
        reason: 'setShuffle must not reach media_kit itself');
  });

  test('the queue owner installs the handler', () {
    final source =
        File('lib/provider/audio_player/audio_player.dart').readAsStringSync();
    expect(source, contains('audioPlayer.shuffleHandler = _setShuffle'));
  });

  test('shuffle callers use the guarded setShuffle, not the flat one', () {
    // Everything that toggles shuffle outside the guard must call setShuffle.
    for (final path in [
      'lib/modules/player/player_controls.dart',
      'lib/provider/tray_manager/tray_menu.dart',
      'lib/services/audio_services/mobile_audio_service.dart',
      'lib/provider/server/routes/connect.dart',
      'lib/components/track_presentation/use_action_callbacks.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source.contains('setFlatShuffle'), isFalse, reason: path);
      expect(source.contains('audioPlayer.setShuffle('), isTrue, reason: path);
    }
  });
}
