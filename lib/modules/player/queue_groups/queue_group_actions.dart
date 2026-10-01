import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';

/// What the queue UI can ask of the player queue.
///
/// Every function is a method of the audio player notifier (see
/// [QueueGroupActions.fromNotifier]); the widgets do not change the queue
/// themselves. Entries and groups are named by id, never by track id.
class QueueGroupActions {
  final Future<void> Function(String entryId) jumpToEntry;

  final Future<String> Function({
    required String title,
    required Iterable<String> entryIds,
  }) createGroup;

  final Future<void> Function(String groupId, String title) renameGroup;
  final Future<void> Function(String groupId, bool collapsed) setCollapsed;
  final Future<void> Function(String groupId) ungroup;

  /// Moves a whole group before the top-level row at the given position.
  final Future<void> Function(String groupId, int toItemIndex) moveGroup;

  /// Moves one top-level row (a loose entry or a group).
  final Future<void> Function(int fromItemIndex, int toItemIndex) moveQueueItem;

  final Future<void> Function(String groupId, int from, int to) moveWithinGroup;

  final Future<void> Function(Iterable<String> entryIds) removeEntries;

  const QueueGroupActions({
    required this.jumpToEntry,
    required this.createGroup,
    required this.renameGroup,
    required this.setCollapsed,
    required this.ungroup,
    required this.moveGroup,
    required this.moveQueueItem,
    required this.moveWithinGroup,
    required this.removeEntries,
  });

  factory QueueGroupActions.fromNotifier(AudioPlayerNotifier notifier) {
    return QueueGroupActions(
      jumpToEntry: notifier.jumpToEntry,
      createGroup: notifier.createGroup,
      renameGroup: notifier.renameGroup,
      setCollapsed: notifier.setGroupCollapsed,
      ungroup: notifier.ungroup,
      moveGroup: notifier.moveGroup,
      moveQueueItem: notifier.moveQueueItem,
      moveWithinGroup: notifier.moveWithinGroup,
      removeEntries: notifier.removeEntries,
    );
  }

  /// Carries out what [resolveQueueDrop] decided.
  Future<void> apply(QueueMove move) {
    return switch (move) {
      MoveQueueItem(:final from, :final to) => moveQueueItem(from, to),
      MoveGroup(:final groupId, :final to) => moveGroup(groupId, to),
      MoveWithinGroup(:final groupId, :final from, :final to) =>
        moveWithinGroup(groupId, from, to),
    };
  }
}

/// Carries out a drag of the queue list.
///
/// A queue without groups is reordered by [onReorder], the plain queue reorder
/// the queue always used. Once there are groups, every move goes through the
/// group-aware [QueueGroupActions].
Future<void> applyQueueMove(
  QueueMove move, {
  required QueueGroupActions actions,
  required bool hasGroups,
  required Future<void> Function(int oldIndex, int newIndex) onReorder,
}) {
  if (!hasGroups && move is MoveQueueItem) {
    return onReorder(move.from, move.to);
  }
  return actions.apply(move);
}
