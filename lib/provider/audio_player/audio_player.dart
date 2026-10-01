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
import 'package:spotube/services/audio_player/queue_persistence.dart';
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

  /// What is saved of the queue: the entries with their ids, the groups, and
  /// the order to go back to when a shuffle done in Dart is switched off.
  /// Every write of the queue saves all of it together.
  SavedQueue<SpotubeTrackObject> get _savedQueue {
    final queue = _grouped;
    return SavedQueue(
      entries: queue.entries,
      groups: queue.groups,
      shuffleOrder: _shuffler.orderBeforeShuffle,
    );
  }

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
          tracks: Value(_savedQueue),
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
              tracks: const Value(SavedQueue<SpotubeTrackObject>.empty()),
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

    final saved = playerState.tracks;
    final tracks = saved.tracks;
    if (saved.issues.isNotEmpty) {
      AppLogger.log.w(
        "Saved queue was not fully readable: ${saved.issues.join('; ')}",
      );
    }
    // Tracks that could not be read are left out, which moves the ones after
    // them up; the playing track stays the same one.
    final currentIndex = remapCurrentIndex(
      playerState.currentIndex,
      saved.droppedPositions,
      tracks.length,
    );

    if (tracks.isEmpty && state.tracks.isNotEmpty) {
      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(_savedQueue),
          currentIndex: Value(currentIndex),
        ),
      );
    } else if (tracks.isNotEmpty) {
      // Replacing the queue is a queue change like any other: it waits for the
      // ones in progress and the ones after it wait for it.
      await _sync.exclusive(() async {
        // The saved queue carries its entry ids and groups; a queue saved
        // before Queue Groups has neither, and gets new ids and no groups.
        state = state
            .withGroupedQueue(saved.queue)
            .copyWith(currentIndex: currentIndex);

        // A queue that was shuffled in Dart is still in its shuffled order;
        // this makes it report "shuffled" again and remember how to unshuffle
        // it. It comes before the queue is opened so that the writes the
        // opening causes already save the shuffle order, and so that mpv
        // resetting its own flag while opening is not what the app reports.
        final shuffleOrder = saved.shuffleOrder;
        if (shuffleOrder != null) _shuffler.restoreNow(shuffleOrder);

        await audioPlayer.openPlaylist(
          tracks.asMediaList(),
          initialIndex: currentIndex,
          autoPlay: false,
        );
      });
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
              tracks: Value(_savedQueue),
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

  /// Puts new tracks into the queue as loose entries, each with an identity of
  /// its own (so a track queued twice is two entries), and returns their entry
  /// ids in the order they were given.
  ///
  /// Every way of adding tracks goes through here and through
  /// [GroupedQueueSync.insert], so the queue, its groups and the player agree:
  /// a group is never split, the playing entry stays the playing entry, and
  /// the added entries are never part of a group.
  ///
  ///  * [afterPlaying]: right after the playing entry, or after its group if it
  ///    is in one ("play next"). Otherwise at the end of the queue.
  ///  * [skipQueued]: leave out tracks that are in the queue already.
  Future<List<String>> _insertTracks(
    Iterable<SpotubeTrackObject> tracks, {
    required bool afterPlaying,
    bool skipQueued = false,
  }) {
    return _sync.exclusive(() async {
      final from = _snapshot;
      final length = from.queue.entries.length;

      final added = createEntries(
        _blacklist.filter(tracks).where(
              (track) =>
                  !skipQueued ||
                  !state.tracks
                      .any((element) => _compareTracks(element, track)),
            ),
        _newEntryId,
      );
      if (added.isEmpty) return const <String>[];

      await _sync.insert(
        from,
        afterPlaying ? playNextIndex(length, from.currentIndex) : length,
        added,
        send: (index, entry, {required append}) => append
            ? audioPlayer.addTrack(SpotubeMedia(entry.track))
            : audioPlayer.addTrackAt(SpotubeMedia(entry.track), index),
        commit: _commitSnapshot,
      );

      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(_savedQueue),
          currentIndex: Value(max(state.currentIndex, 0)),
        ),
      );
      return [for (final entry in added) entry.id];
    });
  }

  /// "Play next": after the playing track (after its group, if it is in one).
  /// Tracks that are queued already are left out unless [allowDuplicates].
  Future<void> addTracksAtFirst(
    Iterable<SpotubeTrackObject> tracks, {
    bool allowDuplicates = false,
  }) async {
    _assertAllowedTracks(tracks);
    await _insertTracks(
      tracks,
      afterPlaying: true,
      // With a single track queued there is nothing to compare against.
      skipQueued: !allowDuplicates && state.tracks.length != 1,
    );
  }

  /// "Add to queue" for one track: at the end, unless it is queued already.
  Future<void> addTrack(SpotubeTrackObject track) async {
    _assertAllowedTrack(track);
    await _insertTracks([track], afterPlaying: false, skipQueued: true);
  }

  /// "Add to queue": at the end, in the order given. Returns the entry ids of
  /// what was added, so a caller can take back exactly that.
  Future<List<String>> addTracks(Iterable<SpotubeTrackObject> tracks) async {
    _assertAllowedTracks(tracks);
    return _insertTracks(tracks, afterPlaying: false);
  }

  /// Removes the first entry of the track. Prefer [removeEntries] when the
  /// entry is known: this cannot tell copies of a track apart.
  Future<void> removeTrack(String trackId) async {
    final entries = _entries;
    final index = entries.indexWhere((entry) => entry.track.id == trackId);
    if (index == -1) return;
    await removeEntries([entries[index].id]);
  }

  /// Removes every entry of the given tracks. Prefer [removeEntries] when the
  /// entries are known: this cannot tell copies of a track apart.
  Future<void> removeTracks(Iterable<String> trackIds) {
    final ids = trackIds.toSet();
    return removeEntries([
      for (final entry in _entries)
        if (ids.contains(entry.track.id)) entry.id,
    ]);
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

    // Replacing the queue waits for the queue changes in progress, and the
    // ones after it wait for it.
    await _sync.exclusive(() async {
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

      // Opening a queue switches mpv's shuffle off; the same goes for a
      // shuffle done in Dart, which belonged to the old queue.
      _shuffler.reset();

      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(_savedQueue),
          currentIndex: Value(max(state.currentIndex, 0)),
        ),
      );
    });
  }

  /// Reloads the playing track from a new source: the playlist item of the
  /// playing entry is replaced by a fresh one. The queue does not change (the
  /// entry keeps its id, place and group); only the player's item is swapped,
  /// as one queue change like the others, so nothing else touches the
  /// player's playlist in the middle of it.
  Future<void> swapActiveSource() {
    return _sync.exclusive(() async {
      final from = _snapshot;
      final active = state.activeTrack;
      if (state.tracks.isEmpty || active is! SpotubeFullTrackObject) return;

      await _sync.swapInPlace(
        from,
        swap: (playingIndex) async {
          await audioPlayer.addTrackAt(
            SpotubeMedia(active),
            playingIndex + 1,
          );
          await audioPlayer.skipToNext();
          await audioPlayer.removeTrack(playingIndex);
        },
        commit: _commitSnapshot,
      );
    });
  }

  /// Plays the entry at [index] of the queue, and says so in the app's queue
  /// at once. The player reports its new position a little later; a queue
  /// change that starts in between must already know which entry plays.
  Future<void> _jumpTo(int index) async {
    await audioPlayer.jumpTo(index);
    state = state.copyWith(currentIndex: index);
  }

  Future<void> jumpToTrack(SpotubeTrackObject track) {
    return _sync.exclusive(() async {
      final index =
          state.tracks.indexWhere((element) => element.id == track.id);
      if (index == -1) return;
      await _jumpTo(index);
    });
  }

  /// Plays the queue entry [entryId]. Unlike [jumpToTrack] this reaches the
  /// right copy when a track is queued more than once.
  Future<void> jumpToEntry(String entryId) {
    return _sync.exclusive(() async {
      final index = state.entryIds.indexOf(entryId);
      if (index == -1) return;
      await _jumpTo(index);
    });
  }

  /// Plays the entry at [index] of the queue as it is when this runs (after
  /// the queue changes already asked for).
  Future<void> jumpToIndex(int index) {
    return _sync.exclusive(() async {
      if (index < 0 || index >= state.tracks.length) return;
      await _jumpTo(index);
    });
  }

  /// Moves the track at [oldIndex] so that it sits where the track at
  /// [newIndex] is now: the plain reorder of the flat queue. (A drop after the
  /// last track is ignored, as it always was.)
  ///
  /// The two tracks are named at the moment of the call, by entry id, and the
  /// move waits its turn behind the queue changes already asked for; so it
  /// still moves those entries even if other changes shift their positions
  /// first. A group that the move breaks up is dissolved (see
  /// [GroupedQueue.moveEntryBefore]); moving whole groups and members inside
  /// them is [moveGroup], [moveQueueItem] and [moveWithinGroup].
  Future<void> moveTrack(int oldIndex, int newIndex) {
    final ids = state.entryIds;
    if (ids.length != state.tracks.length ||
        !canMoveEntry(ids.length, oldIndex, newIndex)) {
      return Future<void>.value();
    }
    final movedId = ids[oldIndex];
    final beforeId = newIndex >= ids.length ? null : ids[newIndex];
    return _changeGroups((queue) => queue.moveEntryBefore(movedId, beforeId));
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

      // Groups are part of what is saved, so a change that left the order
      // alone (rename, collapse, ungroup, a group made of entries that were
      // already next to each other) still has something to write.
      await _updatePlayerState(
        AudioPlayerStateTableCompanion(
          tracks: Value(_savedQueue),
          currentIndex: Value(max(state.currentIndex, 0)),
        ),
      );
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

  Future<void> stop() {
    return _sync.exclusive(() async {
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
          tracks: Value(_savedQueue),
          currentIndex: const Value(0),
          collections: const Value(<String>[]),
          loopMode: const Value(PlaylistMode.none),
          playing: const Value(false),
          shuffled: const Value(false),
        ),
      );
      ref.read(discordProvider.notifier).clear();
    });
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
