import 'dart:io';

import 'package:test/test.dart';

/// The queue UI must not carry queue logic of its own, and the pieces that
/// cannot be run without the app around them (the notifier, the track options)
/// must stay wired the way the UI relies on. These tests read the source.
///
/// Run from the package root (as `flutter test` does).
void main() {
  String read(String path) => File(path).readAsStringSync();

  final uiFiles = [
    for (final entity
        in Directory('lib/modules/player').listSync(recursive: true))
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          (entity.path.contains('queue_groups/') ||
              entity.path.endsWith('player_queue.dart')))
        entity,
  ];

  test('the UI files were found', () {
    expect(uiFiles.length, greaterThanOrEqualTo(6));
  });

  test('widgets change the queue only through the group actions', () {
    // The group operations of GroupedQueue and the entry mover. The one place
    // that may call them is the pure row resolver's tests, not the UI.
    final mutators = RegExp(
      r'\.(createGroup|addToGroup|removeFromGroup|ungroup|renameGroup|'
      r'setCollapsed|moveItem|moveGroup|moveWithinGroup|reorderItems|'
      r'removeEntries)\(',
    );
    for (final file in uiFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].trimLeft();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        for (final match in mutators.allMatches(code)) {
          final before = code.substring(0, match.start);
          expect(
            RegExp(r'(actions|Actions)!?$').hasMatch(before),
            isTrue,
            reason: '${file.path}:${i + 1} changes the queue itself: $code',
          );
        }
      }
    }
    for (final file in uiFiles) {
      expect(
        file.readAsStringSync(),
        isNot(contains('moveEntry(')),
        reason: '${file.path} implements a reorder',
      );
    }
  });

  test('the header and the list keep no state of their own', () {
    // Whether a group is collapsed is the model's; these widgets only show it.
    for (final name in [
      'queue_group_header.dart',
      'queue_rows_sliver.dart',
      'queue_rows.dart',
    ]) {
      final text = read('lib/modules/player/queue_groups/$name');
      expect(text, isNot(contains('StatefulWidget')), reason: name);
      expect(text, isNot(contains('useState')), reason: name);
      expect(text, isNot(contains('HookWidget')), reason: name);
    }
  });

  test('every group action the UI offers is a notifier method', () {
    final actions =
        read('lib/modules/player/queue_groups/queue_group_actions.dart');
    final notifier = read('lib/provider/audio_player/audio_player.dart');
    for (final name in [
      'jumpToEntry',
      'createGroup',
      'renameGroup',
      'setGroupCollapsed',
      'ungroup',
      'moveGroup',
      'moveQueueItem',
      'moveWithinGroup',
      'removeEntries',
    ]) {
      expect(actions, contains('notifier.$name'), reason: name);
      expect(notifier, contains(' $name('), reason: name);
    }
  });

  test('a group change is saved even when the order did not change', () {
    final notifier = read('lib/provider/audio_player/audio_player.dart');
    final start = notifier.indexOf('Future<void> _changeGroups(');
    final end = notifier.indexOf('Future<String> createGroup(');
    final body = notifier.substring(start, end);

    expect(body, contains('_updatePlayerState('));
    expect(body, isNot(contains('sameEntryOrder')));
  });

  test('the playing row is found by position, not by track id', () {
    final queue = read('lib/modules/player/player_queue.dart');
    expect(queue, contains('isActive: row.isPlaying'));
    expect(queue, contains('queueEntryId: row.entry.id'));
    expect(queue, contains('actions!.jumpToEntry('));
    // The only comparison by track id left is the one for a queue without
    // entry ids (a remote player's).
    expect('activeTrack?.id'.allMatches(queue).length, 1);
  });

  test('removing a row from the queue removes that entry', () {
    final provider =
        read('lib/provider/track_options/track_options_provider.dart');
    final options = read('lib/components/track_tile/track_options.dart');
    final button = read('lib/components/track_tile/track_options_button.dart');
    final tile = read('lib/components/track_tile/track_tile.dart');

    expect(provider, contains('playback.removeEntries([queueEntryId])'));
    expect(options, contains('queueEntryId: queueEntryId'));
    expect(button, contains('queueEntryId: queueEntryId'));
    expect(tile, contains('queueEntryId: queueEntryId'));
  });

  test('the notifier can play an entry, not only a track', () {
    final notifier = read('lib/provider/audio_player/audio_player.dart');
    final start = notifier.indexOf('Future<void> jumpToEntry(');
    final body =
        notifier.substring(start, notifier.indexOf('Future<void> moveTrack('));
    expect(body, contains('state.entryIds.indexOf(entryId)'));
    expect(body, contains('audioPlayer.jumpTo(index)'));
  });
}
