import 'dart:math';

import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:spotube/extensions/list.dart';
import 'package:spotube/models/database/database.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/models/playback/track_sources.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/provider/database/database.dart';
import 'package:spotube/provider/discord_provider.dart';
import 'package:spotube/provider/server/track_sources.dart';
import 'package:spotube/services/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:uuid/uuid.dart';

class AudioPlayerNotifier extends Notifier<AudioPlayerState> {
  static const _uuid = Uuid();

  BlackListNotifier get _blacklist => ref.read(blacklistProvider.notifier);

  /// A new identity for a queue occurrence. Not derived from the track, so the
  /// same track queued twice gets two different ids.
  String _newEntryId() => _uuid.v4();

  /// The queue as entries: every track together with its occurrence id.
  ///
  /// [AudioPlayerState.entryIds] is kept aligned with the tracks by every
  /// method below. Should that ever not hold, identities are issued afresh
  /// instead of failing in the middle of playback.
  List<QueueEntry<SpotubeTrackObject>> get _entries {
    if (state.entryIds.length != state.tracks.length) {
      AppLogger.log.w(
        "Queue entry ids out of sync with tracks. Re-issuing... "
        "Ids: ${state.entryIds.length}, tracks: ${state.tracks.length}",
      );
      return createEntries(state.tracks, _newEntryId);
    }
    return pairEntries(state.tracks, state.entryIds);
  }

  void _assertAllowedTracks(Iterable<SpotubeTrackObject> tracks) {
    assert(
      tracks.every(
        (track) =>
            track is SpotubeFullTrackObject || track is SpotubeLocalTrackObject,
      ),
      'All tracks must be either SpotubeFullTrackObject or SpotubeLocalTrackObject',
    );
  }

  void _assertAllowedTrack(SpotubeTrackObject tracks) {
    assert(
      tracks is SpotubeFullTrackObject || tracks is SpotubeLocalTrackObject,
      'Track must be either SpotubeFullTrackObject or SpotubeLocalTrackObject',
    );
  }

  Future<void> _syncSavedState() async {
    final database = ref.read(databaseProvider);

    var playerState =
        await database.select(database.audioPlayerStateTable).getSingleOrNull();

    if (playerState == null) {
      await database.into(database.audioPlayerStateTable).insert(
            AudioPlayerStateTableCompanion.insert(
              playing: audioPlayer.isPlaying,
              loopMode: audioPlayer.loopMode,
              shuffled: audioPlayer.isShuffled,
              collections: <String>[],
              tracks: const Value(<SpotubeTrackObject>[]),
              currentIndex: const Value(0),
              id: const Value(0),
            ),
          );

      playerState =
          await database.select(database.audioPlayerStateTable).getSingle();
    } else {
      await audioPlayer.setLoopMode(playerState.loopMode);
      await audioPlayer.setShuffle(playerState.shuffled);
    }

    final tracks = playerState.tracks;
    final currentIndex = playerState.currentIndex;

    if (tracks.isEmpty && state.tracks.isNotEmpty) {
      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: Value(currentIndex),
        ),
      );
    } else if (tracks.isNotEmpty) {
      // Identities only live as long as the app: the saved queue is a plain
      // list of tracks, so every restored track becomes a new entry.
      state = state
          .withEntries(createEntries(tracks, _newEntryId))
          .copyWith(currentIndex: currentIndex);
      await audioPlayer.openPlaylist(
        tracks.asMediaList(),
        initialIndex: currentIndex,
        autoPlay: false,
      );
    }

    if (playerState.collections.isNotEmpty) {
      state = state.copyWith(
        collections: playerState.collections,
      );
    }
  }

  Future<void> _updatePlayerState(
    AudioPlayerStateTableCompanion companion,
  ) async {
    final database = ref.read(databaseProvider);

    await (database.update(database.audioPlayerStateTable)
          ..where((tb) => tb.id.equals(0)))
        .write(companion);
  }

  @override
  build() {
    final subscriptions = [
      audioPlayer.playingStream.listen((playing) async {
        try {
          state = state.copyWith(playing: playing);

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              playing: Value(playing),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.loopModeStream.listen((loopMode) async {
        try {
          state = state.copyWith(loopMode: loopMode);

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              loopMode: Value(loopMode),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.shuffledStream.listen((shuffled) async {
        try {
          state = state.copyWith(shuffled: shuffled);

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              shuffled: Value(shuffled),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
      audioPlayer.playlistStream.listen((playlist) async {
        try {
          // Playlist and state has to be in sync. This is only meant for
          // the shuffle/re-ordering indices to be in sync
          if (playlist.medias.length != state.tracks.length) {
            AppLogger.log.w(
              "Playlist length does not match state tracks length. Ignoring... "
              "Playlist length: ${playlist.medias.length}, "
              "State tracks length: ${state.tracks.length}",
            );
            return;
          }

          // Every entry is matched at most once, so copies of the same track
          // stay separate entries instead of all becoming the first copy.
          final current = _entries;
          final entries = reconcileEntries(
            current,
            playlist.medias.map(
              (media) => TrackSourceQuery.parseUri(media.uri).id,
            ),
            (track) => track.id,
          );

          if (entries.length != current.length) {
            AppLogger.log.w("Mismatch in tracks after reordering/shuffling.");
            final keptIds = entries.map((entry) => entry.id).toSet();
            final missingTracks = current
                .where((entry) => !keptIds.contains(entry.id))
                .map((entry) => entry.track)
                .toList();
            AppLogger.log.w(
              "Missing tracks: ${missingTracks.map((e) => e.id).join(", ")}",
            );
          }

          state = state.withEntries(entries).copyWith(
                currentIndex: playlist.index,
              );

          await _updatePlayerState(
            AudioPlayerStateTableCompanion(
              currentIndex: Value(state.currentIndex),
              tracks: Value(state.tracks),
            ),
          );
        } catch (e, stack) {
          AppLogger.reportError(e, stack);
        }
      }),
    ];

    _syncSavedState();

    ref.onDispose(() {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    });

    return AudioPlayerState(
      loopMode: audioPlayer.loopMode,
      playing: audioPlayer.isPlaying,
      shuffled: audioPlayer.isShuffled,
      tracks: [],
      collections: [],
    );
  }

  // Collection related methods
  Future<void> addCollections(List<String> collectionIds) async {
    state = state.copyWith(collections: [
      ...state.collections,
      ...collectionIds,
    ]);

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        collections: Value(state.collections),
      ),
    );
  }

  Future<void> addCollection(String collectionId) async {
    await addCollections([collectionId]);
  }

  Future<void> removeCollections(List<String> collectionIds) async {
    state = state.copyWith(
      collections: state.collections
          .where((element) => !collectionIds.contains(element))
          .toList(),
    );

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        collections: Value(state.collections),
      ),
    );
  }

  Future<void> removeCollection(String collectionId) async {
    await removeCollections([collectionId]);
  }

  Future<void> addTracksAtFirst(
    Iterable<SpotubeTrackObject> tracks, {
    bool allowDuplicates = false,
  }) async {
    _assertAllowedTracks(tracks);
    if (state.tracks.length == 1) {
      return addTracks(tracks);
    }

    final addableTracks = _blacklist.filter(tracks).where(
          (track) =>
              allowDuplicates ||
              !state.tracks.any((element) => _compareTracks(element, track)),
        );

    state = state.withEntries([
      ...createEntries(addableTracks, _newEntryId),
      ..._entries,
    ]);

    for (int i = 0; i < addableTracks.length; i++) {
      final track = addableTracks.elementAt(i);

      await audioPlayer.addTrackAt(
        SpotubeMedia(track),
        max(state.currentIndex, 0) + i + 1,
      );
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  Future<void> addTrack(SpotubeTrackObject track) async {
    _assertAllowedTrack(track);

    if (_blacklist.contains(track)) return;
    if (state.tracks.any((element) => _compareTracks(element, track))) return;

    state = state.withEntries([
      ..._entries,
      QueueEntry(_newEntryId(), track),
    ]);

    await audioPlayer.addTrack(SpotubeMedia(track));

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  Future<void> addTracks(Iterable<SpotubeTrackObject> tracks) async {
    _assertAllowedTracks(tracks);

    tracks = _blacklist.filter(tracks).toList();
    state = state.withEntries([
      ..._entries,
      ...createEntries(tracks, _newEntryId),
    ]);

    for (final track in tracks) {
      await audioPlayer.addTrack(SpotubeMedia(track));
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  Future<void> removeTrack(String trackId) async {
    final index = state.tracks.indexWhere((element) => element.id == trackId);

    if (index == -1) return;

    state = state.withEntries(removeIndexes(_entries, [index]));

    await audioPlayer.removeTrack(index);

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  Future<void> removeTracks(Iterable<String> trackIds) async {
    final idsToRemove = trackIds.toSet();
    final entries = _entries;

    // Positions in the queue as it is *now*. They are removed back to front
    // so that each removal leaves the positions of the remaining ones intact.
    final trackIndexes = removalOrder(
      indexesWhere(entries, (entry) => idsToRemove.contains(entry.track.id)),
      entries.length,
    );

    state = state.withEntries(removeIndexes(entries, trackIndexes));

    for (final index in trackIndexes) {
      await audioPlayer.removeTrack(index);
    }

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  bool _compareTracks(SpotubeTrackObject a, SpotubeTrackObject b) {
    if ((a is SpotubeLocalTrackObject && b is! SpotubeLocalTrackObject) ||
        (a is! SpotubeLocalTrackObject && b is SpotubeLocalTrackObject)) {
      return false;
    }

    return a is SpotubeLocalTrackObject && b is SpotubeLocalTrackObject
        ? (a).path == (b).path
        : a.id == b.id;
  }

  Future<void> load(
    List<SpotubeTrackObject> tracks, {
    int initialIndex = 0,
    bool autoPlay = false,
  }) async {
    _assertAllowedTracks(tracks);

    final medias = _blacklist
        .filter(tracks)
        .toList()
        .asMediaList()
        .unique((a, b) => a.uri == b.uri);

    // Giving the initial track a boost so MediaKit won't skip
    // because of timeout
    final intendedActiveTrack = medias.elementAt(initialIndex);
    if (intendedActiveTrack.track is! SpotubeLocalTrackObject) {
      await ref.read(
        trackSourcesProvider(
          TrackSourceQuery.fromTrack(
              intendedActiveTrack.track as SpotubeFullTrackObject),
        ).future,
      );
    }

    if (medias.isEmpty) return;

    state = state
        .withEntries(
          // These are filtered tracks as well. Loading replaces the whole
          // queue, so every track becomes a new entry.
          createEntries(medias.map((media) => media.track), _newEntryId),
        )
        .copyWith(
          currentIndex: initialIndex,
          collections: [],
        );

    await audioPlayer.openPlaylist(
      medias,
      initialIndex: initialIndex,
      autoPlay: autoPlay,
    );

    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: Value(max(state.currentIndex, 0)),
      ),
    );
  }

  Future<void> swapActiveSource() async {
    if (state.tracks.isEmpty || state.activeTrack is! SpotubeFullTrackObject) {
      return;
    }

    final currentIndex = state.currentIndex;
    final currentTrack = state.activeTrack as SpotubeFullTrackObject;
    final swappedMedia = SpotubeMedia(currentTrack);

    await audioPlayer.addTrackAt(swappedMedia, currentIndex + 1);
    await audioPlayer.skipToNext();
    await audioPlayer.removeTrack(currentIndex);
  }

  Future<void> jumpToTrack(SpotubeTrackObject track) async {
    final index =
        state.tracks.toList().indexWhere((element) => element.id == track.id);
    if (index == -1) return;
    await audioPlayer.jumpTo(index);
  }

  Future<void> moveTrack(int oldIndex, int newIndex) async {
    if (!canMoveEntry(state.tracks.length, oldIndex, newIndex)) return;

    // The player only reports track ids back, so it could not tell two copies
    // of a track apart. The move is applied to the entries here, and the
    // player's report afterwards just confirms it.
    state = state.withEntries(moveEntry(_entries, oldIndex, newIndex));

    await audioPlayer.moveTrack(oldIndex, newIndex);
  }

  Future<void> stop() async {
    state = state.copyWith(
      tracks: [],
      entryIds: [],
      currentIndex: 0,
      collections: [],
      loopMode: PlaylistMode.none,
      playing: false,
      shuffled: false,
    );
    await audioPlayer.stop();
    await _updatePlayerState(
      AudioPlayerStateTableCompanion(
        tracks: Value(state.tracks),
        currentIndex: const Value(0),
        collections: const Value(<String>[]),
        loopMode: const Value(PlaylistMode.none),
        playing: const Value(false),
        shuffled: const Value(false),
      ),
    );
    ref.read(discordProvider.notifier).clear();
  }
}

final audioPlayerProvider =
    NotifierProvider<AudioPlayerNotifier, AudioPlayerState>(
  () => AudioPlayerNotifier(),
);
