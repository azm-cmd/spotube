/// The rows of the player queue, worked out from a [GroupedQueue].
///
/// Pure Dart: no widgets, no player. [buildQueueRows] turns the top-level
/// [GroupedQueue.items] into the flat list of rows that the queue shows (a
/// header per group, its members below it when it is expanded, loose entries
/// as they are), and [resolveQueueDrop] turns a drag of one of those rows into
/// the queue operation that makes it happen. All reordering rules live in
/// [GroupedQueue]; this only says *which* operation a drag means.
library;

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';

/// One row of the queue list.
sealed class QueueRow<T> {
  const QueueRow();

  /// A key for the row that stays the same while the row moves: it names the
  /// entry or the group, never a position.
  String get key;

  /// The index of the top-level [GroupedQueue.items] row this row belongs to.
  int get itemIndex;
}

/// A queue entry: a loose one, or a member of an expanded group.
final class QueueEntryRow<T> extends QueueRow<T> {
  final QueueEntry<T> entry;

  /// Where the entry sits in the playback order (the player's index).
  final int flatIndex;

  @override
  final int itemIndex;

  /// The group the entry is in, or `null` for a loose entry.
  final String? groupId;

  /// The position among the members of [groupId], or `null` for a loose entry.
  final int? indexInGroup;

  /// Whether this is the playing entry (by position, not by track id).
  final bool isPlaying;

  const QueueEntryRow({
    required this.entry,
    required this.flatIndex,
    required this.itemIndex,
    required this.isPlaying,
    this.groupId,
    this.indexInGroup,
  });

  bool get isMember => groupId != null;

  @override
  String get key => 'entry:${entry.id}';
}

/// The header of a group.
final class QueueGroupRow<T> extends QueueRow<T> {
  final QueueGroup group;

  @override
  final int itemIndex;

  /// The playback position of the first member.
  final int flatStart;

  /// Whether the members are hidden.
  bool get collapsed => group.collapsed;

  /// The number of members.
  int get count => group.memberIds.length;

  /// Whether the playing entry is one of the members.
  final bool containsPlaying;

  const QueueGroupRow({
    required this.group,
    required this.itemIndex,
    required this.flatStart,
    required this.containsPlaying,
  });

  @override
  String get key => 'group:${group.id}';
}

/// The rows to show for [queue], with [currentIndex] the playing position.
///
/// A group is one header row and, when it is not collapsed, one row per
/// member right below it. A group with no members is not shown. A queue that
/// is not valid (which the player never produces) is shown as plain entries,
/// rather than failing to draw.
List<QueueRow<T>> buildQueueRows<T>(
  GroupedQueue<T> queue, {
  required int currentIndex,
}) {
  final List<QueueItem<T>> items;
  try {
    items = queue.items;
  } on QueueGroupError {
    return [
      for (var i = 0; i < queue.entries.length; i++)
        QueueEntryRow<T>(
          entry: queue.entries[i],
          flatIndex: i,
          itemIndex: i,
          isPlaying: i == currentIndex,
        ),
    ];
  }

  final rows = <QueueRow<T>>[];
  var flat = 0;
  for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
    switch (items[itemIndex]) {
      case EntryItem<T>(:final entry):
        rows.add(QueueEntryRow<T>(
          entry: entry,
          flatIndex: flat,
          itemIndex: itemIndex,
          isPlaying: flat == currentIndex,
        ));
        flat++;
      case GroupItem<T>(:final group, :final entries):
        if (entries.isEmpty) continue;
        rows.add(QueueGroupRow<T>(
          group: group,
          itemIndex: itemIndex,
          flatStart: flat,
          containsPlaying:
              currentIndex >= flat && currentIndex < flat + entries.length,
        ));
        for (var m = 0; m < entries.length; m++) {
          if (!group.collapsed) {
            rows.add(QueueEntryRow<T>(
              entry: entries[m],
              flatIndex: flat + m,
              itemIndex: itemIndex,
              isPlaying: flat + m == currentIndex,
              groupId: group.id,
              indexInGroup: m,
            ));
          }
        }
        flat += entries.length;
    }
  }
  return rows;
}

/// The row that shows the playback position [flatIndex]: the entry itself, or
/// the header of its group while the group is collapsed. `null` if there is no
/// such position.
int? rowIndexOfFlatIndex<T>(List<QueueRow<T>> rows, int flatIndex) {
  for (var r = 0; r < rows.length; r++) {
    switch (rows[r]) {
      case QueueEntryRow<T>(flatIndex: final at) when at == flatIndex:
        return r;
      case QueueGroupRow<T>(:final flatStart, :final count, :final collapsed)
          when collapsed &&
              flatIndex >= flatStart &&
              flatIndex < flatStart + count:
        return r;
      default:
    }
  }
  return null;
}

/// What a drag in the queue list means.
sealed class QueueMove {
  const QueueMove();
}

/// A loose entry moves among the top-level rows:
/// `GroupedQueue.moveItem(from, to)`.
final class MoveQueueItem extends QueueMove {
  final int from;
  final int to;
  const MoveQueueItem(this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is MoveQueueItem && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(MoveQueueItem, from, to);

  @override
  String toString() => 'MoveQueueItem($from, $to)';
}

/// A whole group moves among the top-level rows:
/// `GroupedQueue.moveGroup(groupId, to)`.
final class MoveGroup extends QueueMove {
  final String groupId;
  final int to;
  const MoveGroup(this.groupId, this.to);

  @override
  bool operator ==(Object other) =>
      other is MoveGroup && other.groupId == groupId && other.to == to;

  @override
  int get hashCode => Object.hash(MoveGroup, groupId, to);

  @override
  String toString() => 'MoveGroup($groupId, $to)';
}

/// A member moves inside its group:
/// `GroupedQueue.moveWithinGroup(groupId, from, to)`.
final class MoveWithinGroup extends QueueMove {
  final String groupId;
  final int from;
  final int to;
  const MoveWithinGroup(this.groupId, this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is MoveWithinGroup &&
      other.groupId == groupId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(MoveWithinGroup, groupId, from, to);

  @override
  String toString() => 'MoveWithinGroup($groupId, $from, $to)';
}

/// The operation for dragging row [oldIndex] of [rows] to the gap [newGap],
/// or `null` when nothing would change.
///
/// [newGap] is the number a reorderable list reports: the position, counted
/// before the dragged row is taken out, of the gap the row was dropped in
/// (`0` is before the first row, `rows.length` after the last).
///
///  * A loose entry or a group header moves among the top-level rows. A gap
///    inside another expanded group is not a place for it: it goes to the
///    nearer edge of that group, so a group is never split.
///  * Dragging a group header moves the whole group.
///  * A member can only move inside its own group; a gap outside is the
///    nearest end of the group.
QueueMove? resolveQueueDrop<T>(
  List<QueueRow<T>> rows,
  int oldIndex,
  int newGap,
) {
  if (oldIndex < 0 || oldIndex >= rows.length) return null;
  if (newGap < 0 || newGap > rows.length) return null;

  final dragged = rows[oldIndex];

  if (dragged is QueueEntryRow<T> && dragged.isMember) {
    return _resolveWithinGroup(rows, oldIndex, dragged, newGap);
  }

  final to = _topLevelPosition(rows, newGap);
  final from = dragged.itemIndex;
  if (to == from || to == from + 1) return null;

  return switch (dragged) {
    QueueGroupRow<T>(:final group) => MoveGroup(group.id, to),
    _ => MoveQueueItem(from, to),
  };
}

QueueMove? _resolveWithinGroup<T>(
  List<QueueRow<T>> rows,
  int oldIndex,
  QueueEntryRow<T> dragged,
  int newGap,
) {
  final groupId = dragged.groupId!;
  final from = dragged.indexInGroup!;
  // The member rows of the group sit right after its header.
  final first = oldIndex - from;
  final count = _membersAfter(rows, first - 1, groupId);
  final to = (newGap - first).clamp(0, count);
  if (to == from || to == from + 1) return null;
  return MoveWithinGroup(groupId, from, to);
}

/// The top-level position (an index for [GroupedQueue.moveItem]) that the gap
/// [gap] stands for, moving a gap inside an expanded group to its nearer edge.
int _topLevelPosition<T>(List<QueueRow<T>> rows, int gap) {
  if (gap >= rows.length) {
    return rows.isEmpty ? 0 : rows.last.itemIndex + 1;
  }
  final below = rows[gap];
  if (below is! QueueEntryRow<T> || !below.isMember) {
    // The gap is right before a loose entry or a header: a top-level edge.
    return below.itemIndex;
  }

  // Inside a group, before one of its members. Find the group's rows.
  final indexInGroup = below.indexInGroup!;
  final header = gap - indexInGroup - 1;
  final members = _membersAfter(rows, header, below.groupId!);
  final insideGaps = gap - header; // 1 .. members
  final nearerToStart = insideGaps * 2 <= members + 1;
  return nearerToStart ? below.itemIndex : below.itemIndex + 1;
}

/// How many member rows of [groupId] follow the header row [header].
int _membersAfter<T>(List<QueueRow<T>> rows, int header, String groupId) {
  var count = 0;
  while (header + 1 + count < rows.length) {
    final row = rows[header + 1 + count];
    if (row is QueueEntryRow<T> && row.groupId == groupId) {
      count++;
    } else {
      break;
    }
  }
  return count;
}
