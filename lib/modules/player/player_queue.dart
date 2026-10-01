import 'package:auto_size_text/auto_size_text.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/button/back_button.dart';
import 'package:spotube/components/fallbacks/not_found.dart';
import 'package:spotube/components/inter_scrollbar/inter_scrollbar.dart';
import 'package:spotube/components/track_tile/track_tile.dart';
import 'package:spotube/extensions/constrains.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/hooks/controllers/use_auto_scroll_controller.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/queue_groups/group_title_dialog.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_actions.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_strings.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows_sliver.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/services/logger/logger.dart';

class PlayerQueue extends HookConsumerWidget {
  final bool floating;
  final AudioPlayerState playlist;

  final Future<void> Function(SpotubeTrackObject track) onJump;
  final Future<void> Function(String trackId) onRemove;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;
  final Future<void> Function() onStop;

  /// What the queue can do with groups. `null` for a queue that has none (the
  /// one of a remote player): it is then shown and edited as a flat list.
  final QueueGroupActions? groupActions;

  const PlayerQueue({
    this.floating = true,
    required this.playlist,
    required this.onJump,
    required this.onRemove,
    required this.onReorder,
    required this.onStop,
    this.groupActions,
    super.key,
  });

  PlayerQueue.fromAudioPlayerNotifier({
    this.floating = true,
    required this.playlist,
    required AudioPlayerNotifier notifier,
    super.key,
  })  : onJump = notifier.jumpToTrack,
        onRemove = notifier.removeTrack,
        onReorder = notifier.moveTrack,
        onStop = notifier.stop,
        groupActions = QueueGroupActions.fromNotifier(notifier);

  @override
  Widget build(BuildContext context, ref) {
    final mediaQuery = MediaQuery.sizeOf(context);

    final controller = useAutoScrollController();
    final searchText = useState('');

    final isSearching = useState(false);

    final tracks = playlist.tracks;

    // Tracks with their place in the queue, so a row can tell which copy of a
    // track it is.
    final filteredTracks = useMemoized(
      () {
        final indexed = [
          for (var i = 0; i < tracks.length; i++) (i, tracks[i]),
        ];
        if (searchText.value.isEmpty) {
          return indexed;
        }
        return indexed
            .map((e) => (
                  weightedRatio(
                    '${e.$2.name} - ${e.$2.artists.asString()}',
                    searchText.value,
                  ),
                  e
                ))
            .sorted((a, b) => b.$1.compareTo(a.$1))
            .where((e) => e.$1 > 50)
            .map((e) => e.$2)
            .toList();
      },
      [tracks, searchText.value],
    );

    final actions = groupActions;

    // The queue with its groups, when this is a queue that has them: it needs
    // the player's actions and an entry id for every track.
    final grouped = useMemoized(
      () => actions == null || playlist.entryIds.length != tracks.length
          ? null
          : playlist.groupedQueue,
      [actions == null, playlist.tracks, playlist.entryIds, playlist.groups],
    );

    final rows = useMemoized(
      () => grouped == null
          ? null
          : buildQueueRows(grouped, currentIndex: playlist.currentIndex),
      [grouped, playlist.currentIndex],
    );

    // The entries chosen for a new group; null when not choosing.
    final selection = useState<Set<String>?>(null);

    final isFiltering = isSearching.value || searchText.value.isNotEmpty;
    final showGroups = rows != null && !isFiltering;

    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } catch (e, stack) {
        AppLogger.reportError(e, stack);
      }
    }

    void onMove(QueueMove move) {
      if (actions == null) return;
      guarded(
        () => applyQueueMove(
          move,
          actions: actions,
          hasGroups: grouped!.groups.isNotEmpty,
          onReorder: onReorder,
        ),
      );
    }

    // Only loose entries that are still in the queue can be grouped.
    Set<String> chosenEntries() {
      final chosen = selection.value;
      if (chosen == null || grouped == null) return const {};
      return {
        for (final entry in grouped.ungroupedEntries)
          if (chosen.contains(entry.id)) entry.id,
      };
    }

    Future<void> createGroupFromSelection() async {
      final chosen = chosenEntries();
      if (chosen.length < 2) return;
      final title = await showGroupTitleDialog(
        context,
        heading: QueueGroupStrings.create,
        confirmLabel: QueueGroupStrings.create,
      );
      if (title == null) return;
      await guarded(
        () => groupActions!.createGroup(title: title, entryIds: chosen),
      );
      selection.value = null;
    }

    if (tracks.isEmpty) {
      return const NotFound();
    }

    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constrains) {
            final searchBar = ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: 40,
                maxWidth: mediaQuery.smAndDown ? mediaQuery.width - 40 : 300,
              ),
              child: TextField(
                onChanged: (value) {
                  searchText.value = value;
                },
                placeholder: Text(context.l10n.search),
              ),
            );
            return CallbackShortcuts(
              bindings: {
                LogicalKeySet(LogicalKeyboardKey.escape): () {
                  if (!isSearching.value) {
                    Navigator.of(context).pop();
                  }
                  isSearching.value = false;
                  searchText.value = '';
                }
              },
              child: Column(
                children: [
                  if (isSearching.value && mediaQuery.smAndDown)
                    AppBar(
                      backgroundColor: Colors.transparent,
                      leading: [
                        if (mediaQuery.smAndDown)
                          IconButton.ghost(
                            icon: const Icon(
                              Icons.arrow_back_ios_new_outlined,
                            ),
                            onPressed: () {
                              isSearching.value = false;
                              searchText.value = '';
                            },
                          )
                      ],
                      surfaceBlur: 0,
                      surfaceOpacity: 0,
                      child: searchBar,
                    )
                  else
                    AppBar(
                      trailingGap: 0,
                      backgroundColor: Colors.transparent,
                      surfaceBlur: 0,
                      surfaceOpacity: 0,
                      title: mediaQuery.mdAndUp || !isSearching.value
                          ? SizedBox(
                              height: 30,
                              child: AutoSizeText(
                                context.l10n.tracks_in_queue(tracks.length),
                                maxLines: 1,
                              ),
                            )
                          : null,
                      trailing: [
                        if (mediaQuery.mdAndUp)
                          searchBar
                        else
                          IconButton.ghost(
                            icon: const Icon(SpotubeIcons.filter),
                            onPressed: () {
                              isSearching.value = !isSearching.value;
                            },
                          ),
                        if (!isSearching.value) ...[
                          if (showGroups) ...[
                            const SizedBox(width: 10),
                            Tooltip(
                              tooltip: const TooltipContainer(
                                child: Text(QueueGroupStrings.groupTracks),
                              ).call,
                              child: IconButton(
                                key: const Key('queue-group-select-toggle'),
                                variance: selection.value != null
                                    ? ButtonVariance.secondary
                                    : ButtonVariance.outline,
                                icon: const Icon(SpotubeIcons.selectionCheck),
                                onPressed: () {
                                  selection.value =
                                      selection.value == null ? {} : null;
                                },
                              ),
                            ),
                          ],
                          const SizedBox(width: 10),
                          Tooltip(
                            tooltip: TooltipContainer(
                                    child: Text(context.l10n.clear_all))
                                .call,
                            child: IconButton.outline(
                              icon: const Icon(SpotubeIcons.playlistRemove),
                              onPressed: () {
                                onStop();
                                closeDrawer(context);
                              },
                            ),
                          ),
                          const Gap(5),
                          if (mediaQuery.smAndDown)
                            const BackButton(icon: SpotubeIcons.angleDown),
                        ],
                      ],
                    ),
                  const Divider(),
                  if (showGroups && selection.value != null)
                    _SelectionBar(
                      count: chosenEntries().length,
                      onCancel: () => selection.value = null,
                      onCreate: createGroupFromSelection,
                    ),
                  Expanded(
                    child: InterScrollbar(
                      controller: controller,
                      child: CustomScrollView(
                        controller: controller,
                        slivers: [
                          const SliverGap(10),
                          if (showGroups)
                            QueueRowsSliver<SpotubeTrackObject>(
                              rows: rows,
                              scrollController: controller,
                              onMove: onMove,
                              selection: selection.value,
                              onSelectionChanged: (entryId, selected) {
                                final chosen = {...?selection.value};
                                selected
                                    ? chosen.add(entryId)
                                    : chosen.remove(entryId);
                                selection.value = chosen;
                              },
                              onSetCollapsed: (groupId, collapsed) => guarded(
                                () => actions!.setCollapsed(groupId, collapsed),
                              ),
                              onRenameGroup: (groupId, title) => guarded(
                                () => actions!.renameGroup(groupId, title),
                              ),
                              onUngroup: (groupId) =>
                                  guarded(() => actions!.ungroup(groupId)),
                              entryBuilder: (context, row, chrome) {
                                final onSelected = chrome.onSelectedChanged;
                                return TrackTile(
                                  playlist: playlist,
                                  index: row.flatIndex,
                                  track: row.entry.track,
                                  isActive: row.isPlaying,
                                  queueEntryId: row.entry.id,
                                  selected: chrome.selected ?? false,
                                  onChanged: onSelected == null
                                      ? null
                                      : (value) => onSelected(value ?? false),
                                  onTap: () async {
                                    final chosen = selection.value;
                                    if (chosen != null) {
                                      onSelected?.call(
                                        !chosen.contains(row.entry.id),
                                      );
                                      return;
                                    }
                                    if (row.isPlaying) return;
                                    await actions!.jumpToEntry(row.entry.id);
                                  },
                                  leadingActions: [
                                    if (chrome.dragHandle != null)
                                      chrome.dragHandle!,
                                  ],
                                );
                              },
                            )
                          else
                            SliverReorderableList(
                              onReorder: onReorder,
                              itemCount: filteredTracks.length,
                              onReorderStart: (index) {
                                HapticFeedback.selectionClick();
                              },
                              onReorderEnd: (index) {
                                HapticFeedback.selectionClick();
                              },
                              itemBuilder: (context, i) {
                                final (flatIndex, track) = filteredTracks[i];
                                // A queue with entry ids knows which copy of a
                                // track is playing; a remote one only has ids.
                                final entryId = grouped == null
                                    ? null
                                    : playlist.entryIds[flatIndex];
                                final isActive = entryId == null
                                    ? null
                                    : flatIndex == playlist.currentIndex;
                                return AutoScrollTag(
                                  key: ValueKey<int>(i),
                                  controller: controller,
                                  index: i,
                                  child: TrackTile(
                                    playlist: playlist,
                                    index: i,
                                    track: track,
                                    isActive: isActive,
                                    queueEntryId: entryId,
                                    onTap: () async {
                                      if (entryId != null) {
                                        if (isActive == true) return;
                                        await actions!.jumpToEntry(entryId);
                                        return;
                                      }
                                      if (playlist.activeTrack?.id ==
                                          track.id) {
                                        return;
                                      }
                                      await onJump(track);
                                    },
                                    leadingActions: [
                                      if (!isSearching.value &&
                                          searchText.value.isEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 8.0),
                                          child: ReorderableDragStartListener(
                                            index: i,
                                            child: const Icon(
                                              SpotubeIcons.dragHandle,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          const SliverSafeArea(sliver: SliverGap(100)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: IconButton.secondary(
            icon: const Icon(SpotubeIcons.angleDown),
            onPressed: () {
              // With groups, the playing track may be hidden in a collapsed
              // group: scroll to the row that shows it.
              controller.scrollToIndex(
                showGroups
                    ? rowIndexOfFlatIndex(rows, playlist.currentIndex) ?? 0
                    : playlist.currentIndex,
                preferPosition: AutoScrollPosition.middle,
              );
            },
          ),
        )
      ],
    );
  }
}

/// The bar shown while choosing tracks to group.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCreate;

  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('queue-group-selection-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count < 2
                  ? QueueGroupStrings.selectTracks
                  : QueueGroupStrings.selected(count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Gap(8),
          Button.ghost(
            key: const Key('queue-group-selection-cancel'),
            onPressed: onCancel,
            child: const Text(QueueGroupStrings.cancel),
          ),
          const Gap(8),
          Button.primary(
            key: const Key('queue-group-selection-create'),
            enabled: count >= 2,
            onPressed: onCreate,
            child: Text(
              count >= 2
                  ? QueueGroupStrings.groupSelected(count)
                  : QueueGroupStrings.create,
            ),
          ),
        ],
      ),
    );
  }
}
