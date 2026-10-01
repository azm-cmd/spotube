/// Saving and restoring the queue, with its entry ids and groups.
///
/// Pure Dart: nothing here touches the database, the player or Riverpod. A
/// [SavedQueue] is what is kept between runs; [encodeSavedQueue] and
/// [decodeSavedQueue] turn it into text and back.
///
/// Format (version 1), one JSON object:
///
/// ```json
/// {
///   "version": 1,
///   "entries": [ { "id": "<entry id>", "track": { ...track json... } }, ... ],
///   "groups":  [ { "id": "...", "title": "...", "collapsed": true,
///                  "memberIds": ["<entry id>", ...] }, ... ],
///   "shuffleOrder": ["<entry id>", ...]
/// }
/// ```
///
///  * `entries` is the flat queue in playback order. Every occurrence has its
///    own id, so the same track twice stays two entries.
///  * `groups` name contiguous blocks of `entries` by entry id, never by track.
///  * `shuffleOrder` only exists while the queue was shuffled in Dart (see
///    queue_shuffle.dart): the entry ids in the order from before the shuffle,
///    which is what switching the shuffle off goes back to.
///
/// The format before Queue Groups was a bare JSON list of tracks. It is still
/// read: each track becomes a new entry with a fresh id, with no groups.
///
/// Reading never throws and never invents entries. Whatever cannot be trusted
/// is dropped and noted in [SavedQueue.issues]: a track that cannot be read
/// is skipped, a group that does not describe a valid block is discarded, and
/// the flat queue is kept.
library;

import 'dart:convert';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';

/// The version written by [encodeSavedQueue].
const savedQueueVersion = 1;

/// A queue as it is kept between runs.
class SavedQueue<T> {
  /// The flat queue, in playback order.
  final List<QueueEntry<T>> entries;

  /// The groups of [entries], valid for it (see [GroupedQueue.validate]).
  final List<QueueGroup> groups;

  /// The entry ids from before a shuffle done in Dart, or `null` when the queue
  /// is not shuffled that way.
  final List<String>? shuffleOrder;

  /// What reading found, not part of what is saved: the positions (in the saved
  /// list) of tracks that could not be read and were skipped.
  final List<int> droppedPositions;

  /// What reading found, not part of what is saved: why anything was dropped.
  final List<String> issues;

  const SavedQueue({
    this.entries = const [],
    this.groups = const [],
    this.shuffleOrder,
    this.droppedPositions = const [],
    this.issues = const [],
  });

  const SavedQueue.empty() : this();

  /// The tracks, in playback order.
  List<T> get tracks => [for (final entry in entries) entry.track];

  /// The entries and groups as a [GroupedQueue].
  GroupedQueue<T> get queue => GroupedQueue(entries, groups);

  @override
  String toString() => 'SavedQueue(${entries.length} entries, '
      '${groups.length} groups'
      '${shuffleOrder == null ? '' : ', shuffled'})';
}

/// The position to use after [droppedPositions] were skipped from a saved list:
/// the same entry as before, or the next one when the playing entry itself was
/// dropped. Kept inside the shortened list.
int remapCurrentIndex(
  int index,
  List<int> droppedPositions,
  int length,
) {
  if (droppedPositions.isEmpty) return index;
  final skippedBefore = droppedPositions.where((p) => p < index).length;
  final mapped = index - skippedBefore;
  if (length <= 0) return 0;
  return mapped.clamp(0, length - 1);
}

/// Turns [queue] into text, with [encodeTrack] giving the JSON of a track.
String encodeSavedQueue<T>(
  SavedQueue<T> queue,
  Object? Function(T track) encodeTrack,
) {
  return jsonEncode({
    'version': savedQueueVersion,
    'entries': [
      for (final entry in queue.entries)
        {'id': entry.id, 'track': encodeTrack(entry.track)},
    ],
    'groups': [
      for (final group in queue.groups)
        {
          'id': group.id,
          'title': group.title,
          'collapsed': group.collapsed,
          'memberIds': group.memberIds,
        },
    ],
    if (queue.shuffleOrder != null) 'shuffleOrder': queue.shuffleOrder,
  });
}

/// Reads [raw] back. Never throws: text that cannot be read as a queue gives an
/// empty one.
///
/// [decodeTrack] turns the JSON of one track into a track and may throw for one
/// that is broken. [newId] issues the id of an entry that has none (the old
/// format, or a missing id) or whose id was already taken.
SavedQueue<T> decodeSavedQueue<T>(
  String? raw, {
  required T Function(Map<String, dynamic> json) decodeTrack,
  required String Function() newId,
}) {
  final issues = <String>[];

  if (raw == null || raw.trim().isEmpty) return const SavedQueue.empty();

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    return SavedQueue(issues: ['saved queue is not valid JSON']);
  }

  final List<Object?> rawEntries;
  final bool legacy;
  Object? rawGroups;
  Object? rawShuffle;

  if (decoded is List) {
    // Before Queue Groups: a plain list of tracks.
    legacy = true;
    rawEntries = decoded;
  } else if (decoded is Map) {
    legacy = false;
    final entries = decoded['entries'];
    if (entries is! List) {
      return SavedQueue(issues: ['saved queue has no list of entries']);
    }
    rawEntries = entries;
    rawGroups = decoded['groups'];
    rawShuffle = decoded['shuffleOrder'];
    final version = decoded['version'];
    if (version is! int || version > savedQueueVersion) {
      issues.add('saved queue has version $version, reading it as '
          '$savedQueueVersion');
    }
  } else {
    return SavedQueue(issues: ['saved queue is neither a list nor an object']);
  }

  // --- Entries -----------------------------------------------------------

  final entries = <QueueEntry<T>>[];
  final dropped = <int>[];
  final taken = <String>{};

  // Ids that appeared more than once: they cannot say which occurrence a group
  // or the shuffle order means, so nothing may refer to them.
  final ambiguous = <String>{};

  for (var at = 0; at < rawEntries.length; at++) {
    final item = rawEntries[at];
    try {
      final Object? trackJson;
      String? savedId;
      if (legacy) {
        trackJson = item;
      } else {
        if (item is! Map) throw const FormatException('entry is not an object');
        trackJson = item['track'];
        final id = item['id'];
        if (id is String && id.isNotEmpty) savedId = id;
      }
      if (trackJson is! Map) {
        throw const FormatException('track is not an object');
      }
      final track = decodeTrack(trackJson.cast<String, dynamic>());

      String id;
      if (savedId == null) {
        id = newId();
      } else if (taken.contains(savedId)) {
        ambiguous.add(savedId);
        issues.add('entry id "$savedId" is used more than once');
        id = newId();
      } else {
        id = savedId;
      }
      taken.add(id);
      entries.add(QueueEntry(id, track));
    } catch (e) {
      dropped.add(at);
      issues.add('entry at position $at could not be read');
    }
  }

  // The first holder of an ambiguous id keeps it, but nothing refers to it.
  final positionOf = <String, int>{
    for (var i = 0; i < entries.length; i++)
      if (!ambiguous.contains(entries[i].id)) entries[i].id: i,
  };

  // --- Groups ------------------------------------------------------------

  var groups = const <QueueGroup>[];
  if (rawGroups != null) {
    if (rawGroups is! List) {
      issues.add('saved groups are not a list');
    } else {
      groups = _readGroups(rawGroups, positionOf, issues);
    }
  }
  if (groups.isNotEmpty && !GroupedQueue(entries, groups).isValid) {
    // Not expected after _readGroups; the flat queue is what must survive.
    issues.add('saved groups are not valid for the queue, discarded');
    groups = const [];
  }

  // --- Shuffle -----------------------------------------------------------

  List<String>? shuffleOrder;
  if (rawShuffle != null) {
    if (rawShuffle is! List || rawShuffle.any((e) => e is! String)) {
      issues.add('saved shuffle order is malformed, discarded');
    } else {
      final seen = <String>{};
      final order = [
        for (final id in rawShuffle.cast<String>())
          if (positionOf.containsKey(id) && seen.add(id)) id,
      ];
      if (order.isNotEmpty) shuffleOrder = order;
    }
  }

  return SavedQueue(
    entries: entries,
    groups: groups,
    shuffleOrder: shuffleOrder,
    droppedPositions: dropped,
    issues: issues,
  );
}

/// The groups of [raw] that describe a valid block of the queue, in queue
/// order. [position] maps every usable entry id to its place in the queue.
///
///  * A member that is not in the queue (stale) is dropped from its group.
///  * A group that is then empty, is listed twice, repeats a member, claims a
///    member already taken, or is not one block in queue order is discarded.
List<QueueGroup> _readGroups(
  List<Object?> raw,
  Map<String, int> position,
  List<String> issues,
) {
  final groups = <(int start, QueueGroup group)>[];
  final groupIds = <String>{};
  final claimed = <String>{};

  for (final item in raw) {
    final group = _readGroup(item, position, claimed, groupIds, issues);
    if (group == null) continue;
    groupIds.add(group.id);
    claimed.addAll(group.memberIds);
    groups.add((position[group.memberIds.first]!, group));
  }

  groups.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, group) in groups) group];
}

QueueGroup? _readGroup(
  Object? item,
  Map<String, int> position,
  Set<String> claimed,
  Set<String> groupIds,
  List<String> issues,
) {
  if (item is! Map) {
    issues.add('a saved group is not an object, discarded');
    return null;
  }
  final id = item['id'];
  final title = item['title'] ?? '';
  final collapsed = item['collapsed'] ?? true;
  final memberIds = item['memberIds'];
  if (id is! String ||
      id.isEmpty ||
      title is! String ||
      collapsed is! bool ||
      memberIds is! List ||
      memberIds.any((m) => m is! String)) {
    issues.add('a saved group is malformed, discarded');
    return null;
  }
  if (groupIds.contains(id)) {
    issues.add('group id "$id" is used more than once, discarded');
    return null;
  }

  final listed = memberIds.cast<String>();
  if (listed.toSet().length != listed.length) {
    issues.add('group "$id" lists a member twice, discarded');
    return null;
  }

  // Members that are no longer in the queue are simply gone.
  final members = [
    for (final member in listed)
      if (position.containsKey(member)) member,
  ];
  if (members.isEmpty) {
    issues.add('group "$id" has no members left, discarded');
    return null;
  }
  if (members.any(claimed.contains)) {
    issues.add('group "$id" shares a member with another group, discarded');
    return null;
  }

  // One unbroken block, listed in queue order.
  for (var i = 1; i < members.length; i++) {
    if (position[members[i]] != position[members[i - 1]]! + 1) {
      issues.add('group "$id" is not one block of the queue, discarded');
      return null;
    }
  }

  return QueueGroup(
    id: id,
    title: title,
    memberIds: List.unmodifiable(members),
    collapsed: collapsed,
  );
}
