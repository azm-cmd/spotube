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
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:spotube/services/audio_player/queue_shuffle.dart';
import 'package:spotube/services/audio_player/queue_sync.dart';
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

  /// The queue with its groups. Groups only mean something while the ids line
  /// up with the tracks, so they are dropped together with re-issued ids.
  GroupedQueue<SpotubeTrackObject> get _grouped {
    final aligned = state.entryIds.length == state.tracks.length;
    return GroupedQueue(_entries, aligned ? state.groups : const []);
  }

  QueueSnapshot<SpotubeTrackObject> get _snapshot =>
      QueueSnapshot(_grouped, state.currentIndex);

  /// Sends queue changes to the player and mirrors the player back.
  late final GroupedQueueSync<SpotubeTrackObject> _sync = GroupedQueueSync(
    port: _AudioPlayerPort(),
    keyOf: (track) => track.id,
  );

  /// Carries out every shuffle request. mpv shuffles a queue without groups;
  /// a queue with groups is shuffled here, in Dart, so groups stay whole.
  late final QueueShuffler<SpotubeTrackObject> _shuffler = QueueShuffler(
    sync: _sync,
    port: _AudioPlayerShufflePort(),
    nextInt: Random().nextInt,
  );

  /// Where `audioPlayer.setShuffle` sends every request, so that nothing can
  /// reach mpv's flat shuffle without passing the group check.
  Future<void> _setShuffle(bool shuffle) async {
    final reordered = await _shuffler.setShuffle(
      shuffle,
      read: () => _snapshot,
      commit: _commitSnapshot,
    );
    if (reordered) {
      // mpv did not shuffle, so it did not report the new order either.
      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(state.tracks),
          currentIndex: Value(max(state.currentIndex, 0)),
        ),
      );
    }
  }

  void _commitSnapshot(QueueSnapshot<SpotubeTrackObject> confirmed) {
    state = state.withGroupedQueue(confirmed.queue).copyWith(
          currentIndex: confirmed.currentIndex,
        );
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
          .copyWith(currentIndex: currentIndex, groups: []);
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
    audioPlayer.shuffleHandler = _setShuffle;

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
          final current = _snapshot;
          // Playlist and state has to be in sync. This is only meant for
          // the shuffle/re-ordering indices to be in sync.
          //
          // Entries are matched at most once, so copies of the same track stay
          // separate entries, and groups follow the order the player reports.
          // While a group operation is moving entries, what the player reports
          // is an intermediate order: that operation commits the result itself.
          final next = _sync.onPlayerPlaylist(
            current,
            [
              for (final media in playlist.medias)
                TrackSourceQuery.parseUri(media.uri).id,
            ],
            playlist.index,
          );
          if (next == null) {
            if (!_sync.isApplying) {
              AppLogger.log.w(
                "Playlist length does not match state tracks length. Ignoring... "
                "Playlist length: ${playlist.medias.length}, "
                "State tracks length: ${state.tracks.length}",
              );
            }
            return;
          }

          if (next.queue.entries.length != current.queue.entries.length) {
            AppLogger.log.w("Mismatch in tracks after reordering/shuffling.");
            final keptIds = next.queue.entries.map((entry) => entry.id).toSet();
            final missingTracks = current.queue.entries
                .where((entry) => !keptIds.contains(entry.id))
                .map((entry) => entry.track)
                .toList();
            AppLogger.log.w(
              "Missing tracks: ${missingTracks.map((e) => e.id).join(", ")}",
            );
          }

          state = state.withGroupedQueue(next.queue).copyWith(
                currentIndex: next.currentIndex,
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
      if (audioPlayer.shuffleHandler == _setShuffle) {
        audioPlayer.shuffleHandler = null;
      }
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

    // The flat result is what it always was; groups lose the removed member.
    final queue = _grouped;
    state = state.withGroupedQueue(
      queue.followPlayer(removeIndexes(queue.entries, [index])),
    );

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
    final queue = _grouped;
    final entries = queue.entries;

    // Positions in the queue as it is *now*. They are removed back to front
    // so that each removal leaves the positions of the remaining ones intact.
    final trackIndexes = removalOrder(
      indexesWhere(entries, (entry) => idsToRemove.contains(entry.track.id)),
      entries.length,
    );

    // Groups lose the removed members (and disappear once empty).
    state = state.withGroupedQueue(
      queue.followPlayer(removeIndexes(entries, trackIndexes)),
    );

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
          groups: [],
        );

    await audioPlayer.openPlaylist(
      medias,
      initialIndex: initialIndex,
      autoPlay: autoPlay,
    );

    // Opening a queue switches mpv's shuffle off; the same goes for a shuffle
    // done in Dart, which belonged to the old queue.
    _shuffler.reset();

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
    //
    // A plain move of one track is not group-aware: a group it breaks up is
    // dissolved (its tracks stay), see GroupedQueue.followPlayer.
    state = state.withGroupedQueue(
      _grouped.followPlayer(moveEntry(_entries, oldIndex, newIndex)),
    );

    await audioPlayer.moveTrack(oldIndex, newIndex);
  }

  // --- Queue groups -----------------------------------------------------------
  //
  // `tracks` stays the flat playback order and the groups name contiguous
  // blocks of it. Every method works out the queue it wants with GroupedQueue,
  // then makes the player follow without interrupting playback and commits the
  // confirmed result. Entries are named by entry id (see
  // AudioPlayerState.entryIds), never by track id. A request that cannot be
  // honoured (unknown or stale id, entry already grouped, ...) throws a
  // QueueGroupError before anything is changed.

  String _newGroupId() => _uuid.v4();

  Future<void> _changeGroups(
    GroupedQueue<SpotubeTrackObject> Function(
      GroupedQueue<SpotubeTrackObject> queue,
    ) change,
  ) {
    return _sync.exclusive(() async {
      final from = _snapshot;
      final target = change(from.queue);

      await _sync.apply(
        from,
        target,
        commit: _commitSnapshot,
      );

      // Only the order of the queue is saved, so a change that left the order
      // alone (rename, collapse, ungroup) has nothing to write.
      if (!sameEntryOrder(from.queue.entries, target.entries)) {
        await _updatePlayerState(
          AudioPlayerStateTableCompanion(
            tracks: Value(state.tracks),
            currentIndex: Value(max(state.currentIndex, 0)),
          ),
        );
      }
    });
  }

  /// Groups the loose entries [entryIds] into a new, collapsed group and
  /// returns its id. The entries are gathered into one block where the first
  /// of them was.
  Future<String> createGroup({
    required String title,
    required Iterable<String> entryIds,
    bool collapsed = true,
  }) async {
    final groupId = _newGroupId();
    await _changeGroups(
      (queue) => queue.createGroup(
        groupId: groupId,
        title: title,
        entryIds: entryIds,
        collapsed: collapsed,
      ),
    );
    return groupId;
  }

  /// Adds loose entries to a group, moving them next to it. [index] is the
  /// position among the group's members (default: the end).
  Future<void> addToGroup(
    String groupId,
    Iterable<String> entryIds, {
    int? index,
  }) {
    return _changeGroups(
      (queue) => queue.addToGroup(groupId, entryIds, index: index),
    );
  }

  /// Takes entries out of their groups. They stay in the queue.
  Future<void> removeFromGroup(Iterable<String> entryIds) {
    return _changeGroups((queue) => queue.removeFromGroup(entryIds));
  }

  /// Dissolves a group. Its entries stay in the queue, in place.
  Future<void> ungroup(String groupId) {
    return _changeGroups((queue) => queue.ungroup(groupId));
  }

  Future<void> renameGroup(String groupId, String title) {
    return _changeGroups((queue) => queue.renameGroup(groupId, title));
  }

  Future<void> setGroupCollapsed(String groupId, bool collapsed) {
    return _changeGroups((queue) => queue.setCollapsed(groupId, collapsed));
  }

  /// Moves a whole group before the top-level row at [toItemIndex] (see
  /// GroupedQueue.items; the length means "to the end").
  Future<void> moveGroup(String groupId, int toItemIndex) {
    return _changeGroups((queue) => queue.moveGroup(groupId, toItemIndex));
  }

  /// Moves one top-level row (a loose entry or a whole group).
  Future<void> moveQueueItem(int fromItemIndex, int toItemIndex) {
    return _changeGroups((queue) => queue.moveItem(fromItemIndex, toItemIndex));
  }

  /// Reorders inside a group; nothing outside it moves.
  Future<void> moveWithinGroup(String groupId, int from, int to) {
    return _changeGroups((queue) => queue.moveWithinGroup(groupId, from, to));
  }

  /// Removes entries from the queue by entry id, and from their groups. A
  /// group that loses all its members disappears. Unknown ids are ignored.
  Future<void> removeEntries(Iterable<String> entryIds) {
    return _changeGroups((queue) => queue.removeEntries(entryIds));
  }

  Future<void> stop() async {
    state = state.copyWith(
      tracks: [],
      entryIds: [],
      groups: [],
      currentIndex: 0,
      collections: [],
      loopMode: PlaylistMode.none,
      playing: false,
      shuffled: false,
    );
    await audioPlayer.stop();
    _shuffler.reset();
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

/// The real player's shuffle, as [QueueShuffler] sees it.
class _AudioPlayerShufflePort implements ShufflePort {
  @override
  bool get isShuffled => audioPlayer.isShuffled;

  @override
  bool get isFlatShuffled => audioPlayer.isFlatShuffled;

  @override
  Future<void> setFlatShuffle(bool shuffle) =>
      audioPlayer.setFlatShuffle(shuffle);

  @override
  void publishShuffle(bool shuffled) => audioPlayer.publishShuffle(shuffled);

  @override
  void releaseShuffle() => audioPlayer.releaseShuffle();
}

/// The real player, as [GroupedQueueSync] sees it.
class _AudioPlayerPort implements QueuePlayerPort {
  @override
  Future<void> moveTrack(int from, int to) => audioPlayer.moveTrack(from, to);

  @override
  Future<void> removeTrack(int index) => audioPlayer.removeTrack(index);

  // Note: media_kit keeps its own copy of the playlist and updates it as it
  // sends each command, so this is that copy, not a fresh read of libmpv.
  @override
  List<String> get playlistKeys => [
        for (final media in audioPlayer.playlist.medias)
          TrackSourceQuery.parseUri(media.uri).id,
      ];

  @override
  int get currentIndex => audioPlayer.currentIndex;
}

final audioPlayerProvider =
    NotifierProvider<AudioPlayerNotifier, AudioPlayerState>(
  () => AudioPlayerNotifier(),
);
