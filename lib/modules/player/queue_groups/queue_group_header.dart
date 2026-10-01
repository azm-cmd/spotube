import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/ui/button_tile.dart';
import 'package:spotube/modules/player/queue_groups/group_title_dialog.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_strings.dart';

/// The header row of a queue group: title, number of tracks, a chevron that
/// shows whether the group is expanded, a marker while one of its tracks
/// plays, and a menu with Rename, Collapse/Expand and Ungroup.
///
/// It keeps no state of its own: whether the group is collapsed is [collapsed],
/// and every change is reported through the callbacks.
class QueueGroupHeader extends StatelessWidget {
  final String title;

  /// The number of tracks in the group.
  final int count;
  final bool collapsed;

  /// Whether the playing track is one of the group's.
  final bool containsPlaying;

  /// Tapping the header or the chevron.
  final VoidCallback onToggle;

  /// The new title chosen in the rename dialog.
  final ValueChanged<String> onRename;
  final VoidCallback onUngroup;

  /// The drag handle shown before the chevron, or `null` when the group cannot
  /// be moved right now.
  final Widget? dragHandle;

  const QueueGroupHeader({
    super.key,
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    required this.onRename,
    required this.onUngroup,
    this.containsPlaying = false,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = containsPlaying ? theme.colorScheme.primary : null;

    return Semantics(
      container: true,
      button: true,
      label: QueueGroupStrings.headerLabel(title, count, collapsed),
      onTap: onToggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.muted,
            borderRadius: theme.borderRadiusMd,
            border: containsPlaying
                ? Border.all(color: theme.colorScheme.primary.withAlpha(120))
                : null,
          ),
          child: Row(
            children: [
              if (dragHandle != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: dragHandle,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  collapsed ? SpotubeIcons.angleRight : SpotubeIcons.angleDown,
                  key: Key(
                    collapsed
                        ? 'queue-group-chevron-collapsed'
                        : 'queue-group-chevron-expanded',
                  ),
                  size: 20,
                  color: accent,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      key: const Key('queue-group-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                    Text(
                      QueueGroupStrings.tracks(count),
                      key: const Key('queue-group-count'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.xSmall.copyWith(
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (containsPlaying)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    key: const Key('queue-group-playing'),
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
              _GroupMenuButton(
                title: title,
                collapsed: collapsed,
                onToggle: onToggle,
                onRename: onRename,
                onUngroup: onUngroup,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupMenuButton extends StatelessWidget {
  final String title;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<String> onRename;
  final VoidCallback onUngroup;

  const _GroupMenuButton({
    required this.title,
    required this.collapsed,
    required this.onToggle,
    required this.onRename,
    required this.onUngroup,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: QueueGroupStrings.groupMenu,
      button: true,
      child: IconButton.ghost(
        key: const Key('queue-group-menu'),
        icon: const Icon(SpotubeIcons.moreHorizontal),
        onPressed: () {
          showPopover(
            context: context,
            alignment: Alignment.bottomRight,
            builder: (popoverContext) {
              void close() => closeOverlay(popoverContext);

              return SizedBox(
                width: 220,
                child: Card(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      ButtonTile(
                        key: const Key('queue-group-menu-rename'),
                        style: ButtonVariance.menu,
                        leading: const Icon(SpotubeIcons.edit),
                        title: const Text(QueueGroupStrings.rename),
                        onPressed: () async {
                          close();
                          final renamed = await showGroupTitleDialog(
                            context,
                            heading: QueueGroupStrings.rename,
                            confirmLabel: QueueGroupStrings.renameConfirm,
                            initialTitle: title,
                          );
                          if (renamed != null && renamed != title) {
                            onRename(renamed);
                          }
                        },
                      ),
                      ButtonTile(
                        key: const Key('queue-group-menu-toggle'),
                        style: ButtonVariance.menu,
                        leading: Icon(
                          collapsed
                              ? SpotubeIcons.angleDown
                              : SpotubeIcons.angleRight,
                        ),
                        title: Text(
                          collapsed
                              ? QueueGroupStrings.expand
                              : QueueGroupStrings.collapse,
                        ),
                        onPressed: () {
                          close();
                          onToggle();
                        },
                      ),
                      ButtonTile(
                        key: const Key('queue-group-menu-ungroup'),
                        style: ButtonVariance.menu,
                        leading: const Icon(SpotubeIcons.playlistRemove),
                        title: const Text(QueueGroupStrings.ungroup),
                        onPressed: () {
                          close();
                          onUngroup();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
