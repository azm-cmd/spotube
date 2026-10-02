import 'dart:io';

import 'package:test/test.dart';

/// Every change to the queue's order, to the player's playlist or to the
/// playing position is carried out inside one place, `_sync.exclusive`, so two
/// of them can never interleave their player commands. These tests read the
/// source to keep it that way: a new method that talks to the player without
/// going through it fails here.
///
/// Run from the package root (as `flutter test` does).
void main() {
  const path = 'lib/provider/audio_player/audio_player.dart';
  final source = File(path).readAsStringSync();

  // The notifier class: from its declaration to the next top-level class.
  final classStart = source.indexOf('class AudioPlayerNotifier');
  final classEnd = source.indexOf('\n}\n', classStart);
  final notifier = source.substring(classStart, classEnd);

  /// Methods of the notifier: name -> text. A method starts at a line indented
  /// by exactly two spaces that declares something with parentheses (or a
  /// getter) and goes on to the next such line.
  final methods = <String, String>{};
  final lines = notifier.split('\n');
  final declaration =
      RegExp(r'^  (?:@override\n)?[A-Za-z].*?\b(\w+)\s*(\(|\{|=>)');
  final getter = RegExp(r'^  [A-Za-z].*\bget (\w+)\b');
  String? current;
  final buffer = StringBuffer();
  void flush() {
    if (current != null) methods[current!] = buffer.toString();
    buffer.clear();
  }

  for (final line in lines) {
    final isTop = line.startsWith('  ') &&
        line.length > 2 &&
        RegExp(r'[A-Za-z]').hasMatch(line[2]);
    if (isTop) {
      final name = getter.firstMatch(line)?.group(1) ??
          declaration.firstMatch(line)?.group(1);
      if (name != null) {
        flush();
        current = name;
      }
    }
    buffer.writeln(line);
  }
  flush();

  test('the notifier was parsed', () {
    expect(methods.keys, containsAll(['load', 'stop', 'swapActiveSource']));
    expect(methods.length, greaterThan(30));
  });

  /// The calls that change the player's playlist or position.
  final playerMutations = RegExp(
    r'audioPlayer\.(addTrack|addTrackAt|removeTrack|moveTrack|openPlaylist|'
    r'jumpTo|stop|clearPlaylist)\(',
  );

  test('only these methods change the player\'s playlist', () {
    final found = <String, List<String>>{};
    methods.forEach((name, text) {
      final calls =
          playerMutations.allMatches(text).map((m) => m.group(1)!).toList();
      if (calls.isNotEmpty) found[name] = calls;
    });

    expect(
        found.keys.toSet(),
        {
          '_syncSavedState', // restoring the saved queue
          '_insertTracks', // play next / add to queue
          'load',
          'swapActiveSource',
          '_jumpTo', // every jump
          'stop',
        },
        reason: found.toString());
  });

  test('each of them does it inside the exclusive section', () {
    for (final name in [
      '_syncSavedState',
      '_insertTracks',
      'load',
      'swapActiveSource',
      'stop',
    ]) {
      final text = methods[name]!;
      final exclusive = text.indexOf('_sync.exclusive(');
      expect(exclusive, isNonNegative, reason: '$name is not serialized');
      final firstCall = playerMutations.firstMatch(text)!.start;
      expect(exclusive, lessThan(firstCall),
          reason: '$name talks to the player before it holds the lock');
    }
  });

  test('a jump tells the app\'s queue which entry plays, at once', () {
    // The player reports its new position a little later; a change that starts
    // in between must not carry the old position into the new queue.
    final jump = methods['_jumpTo']!;
    expect(jump, contains('audioPlayer.jumpTo(index)'));
    expect(jump, contains('state = state.copyWith(currentIndex: index)'));
    expect(jump.indexOf('audioPlayer.jumpTo(index)'),
        lessThan(jump.indexOf('state = state.copyWith')));
  });

  test('a jump holds the lock before it reaches the player', () {
    for (final name in ['jumpToTrack', 'jumpToEntry']) {
      final text = methods[name]!;
      expect(text, contains('_sync.exclusive('), reason: name);
      expect(text, contains('_jumpTo('), reason: name);
      expect(text, isNot(contains('audioPlayer.jumpTo(')), reason: name);
    }
  });

  test('a jump by position names its entry before it waits for the lock', () {
    // The remote player sends positions. The position is turned into an entry
    // id when the request arrives; the jump then waits behind the queue
    // changes already asked for and still plays that entry.
    final text = methods['jumpToIndex']!;
    expect(text, contains('state.entryIds'));
    expect(text, contains('jumpToEntry('));
    expect(text, isNot(contains('audioPlayer.')));
    expect(text, isNot(contains('_jumpTo(')));
    expect(
        text.indexOf('state.entryIds'), lessThan(text.indexOf('jumpToEntry(')));
  });

  test('moving, grouping and removing go through the one change method', () {
    for (final name in [
      'moveTrack',
      'createGroup',
      'addToGroup',
      'removeFromGroup',
      'ungroup',
      'renameGroup',
      'setGroupCollapsed',
      'moveGroup',
      'moveQueueItem',
      'moveWithinGroup',
      'removeEntries',
    ]) {
      expect(methods[name], contains('_changeGroups('), reason: name);
      expect(methods[name], isNot(contains('audioPlayer.')), reason: name);
    }
    final change = methods['_changeGroups']!;
    expect(change, contains('_sync.exclusive('));
    expect(change, contains('_sync.apply('));
  });

  test('a flat move names its entries when asked, not by position later', () {
    final move = methods['moveTrack']!;
    expect(move, contains('moveEntryBefore('));
    expect(move, contains('ids[oldIndex]'));
    expect(move, isNot(contains('moveEntry(')));
    // The positions are turned into entry ids before the move is queued.
    expect(move.indexOf('ids[oldIndex]'),
        lessThan(move.indexOf('_changeGroups(')));
  });

  test('a drag by position names its rows before it waits for the lock', () {
    // Positions are turned into what they point at when the request is made;
    // the change then runs behind the ones already asked for.
    final expected = {
      'moveGroup': 'moveGroupBefore(',
      'moveQueueItem': 'moveItemBefore(',
      'moveWithinGroup': 'moveMemberBefore(',
    };
    expected.forEach((name, call) {
      final text = methods[name]!;
      expect(text, contains(call), reason: name);
      expect(text.indexOf(RegExp(r'_rowAt\(|memberIds')),
          lessThan(text.indexOf('_changeGroups(')),
          reason: '$name reads positions after it waited');
    });
    final rowAt = source.substring(source.indexOf('_rowAt(int index)'));
    expect(
        rowAt.substring(0, rowAt.indexOf('\n  }\n')), contains('itemKeyAt('));
  });

  test('every change starts from the position the player says it is at', () {
    // The player's own answer, not the last thing it reported: it may have
    // moved on by itself (a track that ended) since.
    for (final name in ['_insertTracks', 'swapActiveSource', '_changeGroups']) {
      final text = methods[name]!;
      expect(text, contains('await _sync.current(_snapshot)'), reason: name);
    }
    expect(methods['_setShuffle'], contains('_sync.current(_snapshot)'));
    expect(source, contains('Future<int> queryPlayingIndex()'));
    final impl = File('lib/services/audio_player/audio_player_impl.dart')
        .readAsStringSync();
    final query =
        impl.substring(impl.indexOf('Future<int> queryPlayingIndex()'));
    final body = query.substring(0, query.indexOf('\n  }\n'));
    expect(body, contains("getProperty('playlist-pos')"));
    // It only looks: nothing in it changes the player.
    expect(body, isNot(contains('setProperty')));
    expect(body, isNot(contains('command')));
  });

  test('the saved queue never replaces a queue that is newer than it', () {
    // The restore reads the database in the background at startup. Anything
    // that put a queue in place (or cleared it) before the restore got its
    // turn must be left alone.
    expect(source, contains('bool _queueTouched = false;'));
    for (final name in ['_commitSnapshot', 'load', 'stop']) {
      expect(methods[name], contains('_queueTouched = true'), reason: name);
    }
    final restore = methods['_syncSavedState']!;
    final lock = restore.indexOf('_sync.exclusive(');
    final guard = restore.indexOf('if (_queueTouched) return;');
    expect(guard, greaterThan(lock));
    expect(guard, lessThan(restore.indexOf('state = state')));
    expect(guard, lessThan(restore.indexOf('audioPlayer.openPlaylist(')));
    expect(restore, contains('!_queueTouched'));
  });

  test('the swap of the playing source is one guarded step', () {
    final swap = methods['swapActiveSource']!;
    expect(swap, contains('_sync.exclusive('));
    expect(swap, contains('_sync.swapInPlace('));
    expect(swap, contains('addTrackAt('));
    expect(swap, contains('skipToNext('));
    expect(swap, contains('removeTrack('));
  });

  test('removing by track id is a removal of entries', () {
    expect(methods['removeTrack'], contains('removeEntries('));
    expect(methods['removeTracks'], contains('removeEntries('));
  });

  test('nothing else in the app changes the player\'s playlist', () {
    final tail = RegExp(
      r'audioPlayer\.(addTrack|addTrackAt|removeTrack|moveTrack|openPlaylist|'
      r'jumpTo|clearPlaylist)\(',
    );
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.startsWith('lib/services/audio_player/')) continue;
      if (entity.path == path) continue;
      expect(
        tail.hasMatch(entity.readAsStringSync()),
        isFalse,
        reason: '${entity.path} changes the player\'s playlist by itself',
      );
    }
  });

  test('mpv is only reached through the audio player service', () {
    // The player library's own objects: nothing outside the service layer may
    // hold one, and inside it only the service's implementation file sends
    // commands that change the playlist or the playing position.
    final library = RegExp(
      r'nativePlayer|_mkPlayer|CustomPlayer|package:media_kit/src',
    );
    final queueCommands = RegExp(
      r'_mkPlayer\.(add|insert|remove|move|open|stop|jump|next|previous|'
      r'setShuffle|shuffle)\(',
    );
    final playlistProperties = RegExp(
      "(setProperty|command)\\(\\s*\\[?\\s*['\"](playlist|loadfile|"
      "playlist-)",
    );
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final text = entity.readAsStringSync();
      expect(playlistProperties.hasMatch(text), isFalse,
          reason: '${entity.path} writes mpv\'s playlist directly');
      if (entity.path.startsWith('lib/services/audio_player/')) {
        if (!entity.path.endsWith('audio_player_impl.dart')) {
          expect(queueCommands.hasMatch(text), isFalse,
              reason: '${entity.path} sends queue commands to mpv');
        }
        continue;
      }
      expect(library.hasMatch(text), isFalse,
          reason: '${entity.path} reaches into the player library');
    }
  });

  test('there is one mutex, and it is the sync layer\'s', () {
    expect(source, isNot(contains('synchronized')));
    expect(source, isNot(contains('Completer<')));
    expect(source, isNot(contains('Mutex')));
    expect(source, isNot(contains(' Lock(')));
    final sync =
        File('lib/services/audio_player/queue_sync.dart').readAsStringSync();
    expect(sync, contains('Future<R> exclusive<R>('));
  });

  test('every change reports to the sync layer\'s guard while it sends', () {
    final sync =
        File('lib/services/audio_player/queue_sync.dart').readAsStringSync();
    // apply (reorder, remove), insert and swapInPlace all raise the guard.
    expect('_applying++'.allMatches(sync).length, 4);
    expect('_applying--'.allMatches(sync).length, 4);
  });

  test('a queue is restored under the same lock as any other change', () {
    final restore = methods['_syncSavedState']!;
    expect(restore, contains('_sync.exclusive('));
    // The shuffle restore inside it must not take the lock again.
    expect(restore, contains('_shuffler.restoreNow('));
    expect(restore, isNot(contains('_shuffler.restore(')));
  });

  test('the remote jump goes through the notifier', () {
    final route =
        File('lib/provider/server/routes/connect.dart').readAsStringSync();
    expect(route, contains('audioPlayerNotifier.jumpToIndex('));
    expect(route, isNot(contains('audioPlayer.jumpTo(')));
  });
}
