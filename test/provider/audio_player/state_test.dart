import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:test/test.dart';

SpotubeTrackObject _track(String id) {
  return SpotubeTrackObject.full(
    id: id,
    name: 'Track $id',
    externalUri: 'https://example.invalid/track/$id',
    album: SpotubeSimpleAlbumObject(
      id: 'album',
      name: 'Album',
      externalUri: 'https://example.invalid/album',
      artists: const [],
      albumType: SpotubeAlbumType.album,
    ),
    durationMs: 1000,
    isrc: 'ISRC$id',
    explicit: false,
  );
}

AudioPlayerState _emptyState() {
  return AudioPlayerState(
    playing: false,
    loopMode: PlaylistMode.none,
    shuffled: false,
    collections: const [],
  );
}

void main() {
  group('AudioPlayerState queue entries', () {
    test('a new state has no tracks and no entry ids', () {
      final state = _emptyState();
      expect(state.tracks, isEmpty);
      expect(state.entryIds, isEmpty);
    });

    test('withEntries keeps tracks and entry ids aligned', () {
      var n = 0;
      final entries = createEntries(
        [_track('a'), _track('b'), _track('c')],
        () => 'e${++n}',
      );

      final state = _emptyState().withEntries(entries);

      expect(state.tracks.map((t) => t.id), ['a', 'b', 'c']);
      expect(state.entryIds, ['e1', 'e2', 'e3']);
    });

    test('two copies of one track keep two different entry ids', () {
      var n = 0;
      final entries = createEntries(
        [_track('a'), _track('a')],
        () => 'e${++n}',
      );

      final state = _emptyState().withEntries(entries);

      expect(state.tracks.map((t) => t.id), ['a', 'a']);
      expect(state.entryIds, ['e1', 'e2']);
      expect(state.entryIds.toSet().length, 2);
    });

    test('withEntries replaces the previous queue and keeps other fields', () {
      final first = _emptyState()
          .withEntries(createEntries([_track('a')], () => 'old'))
          .copyWith(currentIndex: 0, shuffled: true);

      final second = first.withEntries(
        createEntries([_track('b'), _track('c')], () => 'new'),
      );

      expect(second.tracks.map((t) => t.id), ['b', 'c']);
      expect(second.entryIds, ['new', 'new']);
      expect(second.shuffled, isTrue);
    });

    test('copyWith of other fields leaves the entry ids untouched', () {
      final state = _emptyState()
          .withEntries(createEntries([_track('a')], () => 'e1'))
          .copyWith(currentIndex: 0, playing: true);

      expect(state.entryIds, ['e1']);
    });

    test('the Connect JSON does not carry entry ids', () {
      final state =
          _emptyState().withEntries(createEntries([_track('a')], () => 'e1'));

      final json = state.toJson();

      // Exactly the keys the protocol had before entry ids existed.
      expect(
        json.keys.toSet(),
        {
          'playing',
          'loopMode',
          'shuffled',
          'collections',
          'currentIndex',
          'tracks',
        },
      );
    });

    test('a state read from JSON has tracks but no entry ids', () {
      final original = _emptyState()
          .withEntries(createEntries([_track('a'), _track('b')], () => 'e'));

      final restored = AudioPlayerState.fromJson(original.toJson());

      expect(restored.tracks.map((t) => t.id), ['a', 'b']);
      expect(restored.entryIds, isEmpty);
    });
  });
}
