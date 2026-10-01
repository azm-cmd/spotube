import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';

part 'state.freezed.dart';
part 'state.g.dart';

@freezed
class AudioPlayerState with _$AudioPlayerState {
  const AudioPlayerState._();

  factory AudioPlayerState._inner({
    required bool playing,
    required PlaylistMode loopMode,
    required bool shuffled,
    required List<String> collections,
    @Default(0) int currentIndex,
    @Default([]) List<SpotubeTrackObject> tracks,
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default([])
    List<String> entryIds,
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default([])
    List<QueueGroup> groups,
  }) = _AudioPlayerState;

  factory AudioPlayerState({
    required bool playing,
    required PlaylistMode loopMode,
    required bool shuffled,
    required List<String> collections,
    int currentIndex = 0,
    List<SpotubeTrackObject> tracks = const [],
    List<String> entryIds = const [],
    List<QueueGroup> groups = const [],
  }) {
    assert(
      tracks.every((track) =>
          track is SpotubeFullTrackObject || track is SpotubeLocalTrackObject),
      'All tracks must be either SpotubeFullTrackObject or SpotubeLocalTrackObject',
    );

    return AudioPlayerState._inner(
      playing: playing,
      loopMode: loopMode,
      shuffled: shuffled,
      currentIndex: currentIndex,
      tracks: tracks,
      collections: collections,
      entryIds: entryIds,
      groups: groups,
    );
  }

  factory AudioPlayerState.fromJson(Map<String, dynamic> json) =>
      _$AudioPlayerStateFromJson(json);

  /// Replaces the queue with [entries], keeping [tracks] and [entryIds] in
  /// step. Prefer this over assigning either list on its own.
  ///
  /// [groups] is left as it is, so only use this for changes that cannot break
  /// a group: appending, or inserting before every group. Anything else goes
  /// through [withGroupedQueue].
  ///
  /// [entryIds] holds the identity of every queue occurrence, aligned with
  /// [tracks]: `entryIds[i]` belongs to `tracks[i]`, and two copies of the same
  /// track have different ids. It is kept out of the JSON on purpose, so the
  /// Connect protocol is unchanged; a state that was deserialized has no ids.
  AudioPlayerState withEntries(
    Iterable<QueueEntry<SpotubeTrackObject>> entries,
  ) {
    final queue = entries.toList();
    return copyWith(
      tracks: [for (final entry in queue) entry.track],
      entryIds: [for (final entry in queue) entry.id],
    );
  }

  /// The queue as a [GroupedQueue]: [tracks] with their [entryIds], and the
  /// [groups] that name blocks of it. Only meaningful for a state that tracks
  /// entry ids (the local player's, not one read from JSON); throws an
  /// [ArgumentError] when ids and tracks do not line up.
  ///
  /// [groups] holds the grouping of the flat [tracks] order. It is empty for a
  /// queue without groups, and is not part of the JSON.
  GroupedQueue<SpotubeTrackObject> get groupedQueue =>
      GroupedQueue(pairEntries(tracks, entryIds), groups);

  /// Replaces the whole queue, including its groups, keeping [tracks],
  /// [entryIds] and [groups] in step.
  AudioPlayerState withGroupedQueue(GroupedQueue<SpotubeTrackObject> queue) {
    return copyWith(
      tracks: [for (final entry in queue.entries) entry.track],
      entryIds: [for (final entry in queue.entries) entry.id],
      groups: queue.groups,
    );
  }

  SpotubeTrackObject? get activeTrack {
    if (currentIndex < 0 || currentIndex >= tracks.length) return null;
    return tracks[currentIndex];
  }

  bool containsTrack(SpotubeTrackObject track) {
    return tracks.any((t) => t.id == track.id);
  }

  bool containsTracks(List<SpotubeTrackObject> tracks) {
    return tracks.every(containsTrack);
  }

  bool containsCollection(String collectionId) {
    return collections.contains(collectionId);
  }
}
