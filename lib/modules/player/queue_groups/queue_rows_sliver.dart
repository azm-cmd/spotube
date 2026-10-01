import 'package:flutter/services.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_header.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows.dart';

/// What [QueueRowsSliver] gives the builder of an entry row, next to the row.
class QueueRowChrome {
  /// The drag handle for the row, or `null` when the row cannot be dragged
  /// right now.
  final Widget? dragHandle;

  /// Set while choosing tracks to group: whether this row is chosen. `null`
  /// when the row cannot be chosen (or nothing is being chosen).
  final bool? selected;

  /// Called with the new state when the row is (de)selected.
  final ValueChanged<bool>? onSelectedChanged;

  const QueueRowChrome({
    this.dragHandle,
    this.selected,
    this.onSelectedChanged,
  });
}

typedef QueueEntryRowBuilder<T> = Widget Function(
  BuildContext context,
  QueueEntryRow<T> row,
  QueueRowChrome chrome,
);

/// The queue list: a [SliverReorderableList] with one item per [QueueRow], so
/// the list is exactly what [buildQueueRows] says.
///
/// Dragging does not change anything by itself. A drop is turned into a
/// [QueueMove] by [resolveQueueDrop] and handed to [onMove]; the list then
/// follows the rows it is given.
///
///  * Rows are keyed by entry id and group id, so they keep their identity
///    when they move.
///  * Members of an expanded group are indented and drawn against a rule on
///    their left, so they read as part of the group.
class QueueRowsSliver<T> extends StatelessWidget {
  final List<QueueRow<T>> rows;

  /// The controller that scrolls to a row, when the list is scrolled to one.
  final AutoScrollController? scrollController;

  /// Whether rows can be dragged.
  final bool reorderEnabled;

  final void Function(QueueMove move) onMove;

  final QueueEntryRowBuilder<T> entryBuilder;

  final void Function(String groupId, bool collapsed) onSetCollapsed;
  final void Function(String groupId, String title) onRenameGroup;
  final void Function(String groupId) onUngroup;

  /// The entry ids chosen for a new group, while choosing; `null` otherwise.
  /// Only loose entries can be chosen.
  final Set<String>? selection;
  final void Function(String entryId, bool selected)? onSelectionChanged;

  const QueueRowsSliver({
    super.key,
    required this.rows,
    required this.onMove,
    required this.entryBuilder,
    required this.onSetCollapsed,
    required this.onRenameGroup,
    required this.onUngroup,
    this.scrollController,
    this.reorderEnabled = true,
    this.selection,
    this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selecting = selection != null;
    final canDrag = reorderEnabled && !selecting;

    return SliverReorderableList(
      itemCount: rows.length,
      onReorder: (oldIndex, newGap) {
        final move = resolveQueueDrop(rows, oldIndex, newGap);
        if (move != null) onMove(move);
      },
      onReorderStart: (_) => HapticFeedback.selectionClick(),
      onReorderEnd: (_) => HapticFeedback.selectionClick(),
      itemBuilder: (context, i) {
        final row = rows[i];

        Widget? handle() => canDrag
            ? ReorderableDragStartListener(
                key: Key('queue-drag-handle:${row.key}'),
                index: i,
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(SpotubeIcons.dragHandle),
                ),
              )
            : null;

        final Widget child;
        switch (row) {
          case QueueGroupRow<T>(:final group):
            child = QueueGroupHeader(
              title: group.title,
              count: row.count,
              collapsed: row.collapsed,
              containsPlaying: row.containsPlaying,
              dragHandle: canDrag
                  ? ReorderableDragStartListener(
                      key: Key('queue-drag-handle:${row.key}'),
                      index: i,
                      child: const Icon(SpotubeIcons.dragHandle),
                    )
                  : null,
              onToggle: () => onSetCollapsed(group.id, !row.collapsed),
              onRename: (title) => onRenameGroup(group.id, title),
              onUngroup: () => onUngroup(group.id),
            );
          case QueueEntryRow<T>():
            final selectable = selecting && !row.isMember;
            final tile = entryBuilder(
              context,
              row,
              QueueRowChrome(
                dragHandle: handle(),
                selected: selectable ? selection!.contains(row.entry.id) : null,
                onSelectedChanged: selectable
                    ? (value) => onSelectionChanged?.call(row.entry.id, value)
                    : null,
              ),
            );
            child = row.isMember ? _Member(child: tile) : tile;
        }

        final key = ValueKey<String>(row.key);
        final controller = scrollController;
        return controller == null
            ? KeyedSubtree(key: key, child: child)
            : AutoScrollTag(
                key: key,
                controller: controller,
                index: i,
                child: child,
              );
      },
    );
  }
}

/// Indents a member of an expanded group and draws a rule beside it.
class _Member extends StatelessWidget {
  final Widget child;

  const _Member({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.border, width: 2),
          ),
        ),
        child: child,
      ),
    );
  }
}
