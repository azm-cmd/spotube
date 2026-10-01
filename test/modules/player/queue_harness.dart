import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/l10n/l10n.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/player/player_queue.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_actions.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/audio_player/state.dart';
import 'package:spotube/provider/blacklist_provider.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';

SpotubeTrackObject track(String id) {
  return SpotubeTrackObject.full(
    id: id,
    name: 'Track $id',
    externalUri: 'https://example.invalid/track/$id',
    album: SpotubeSimpleAlbumObject(
      id: 'album',
      name: 'Album',
      externalUri: 'https://example.invalid/album',
      artists: const [],
      albumType: SpotubeAlbumType.album,
    ),
    durationMs: 1000,
    isrc: 'ISRC$id',
    explicit: false,
  );
}

typedef TrackQueue = GroupedQueue<SpotubeTrackObject>;

/// Entries e1.. for the track ids, with groups made through the real model
/// (group id -> member entry ids). Groups are collapsed unless in [expanded].
TrackQueue queueOf(
  List<String> trackIds, {
  Map<String, List<String>> groups = const {},
  Set<String> expanded = const {},
}) {
  var queue = GroupedQueue.ungrouped([
    for (var i = 0; i < trackIds.length; i++)
      QueueEntry('e${i + 1}', track(trackIds[i])),
  ]);
  groups.forEach((id, members) {
    queue = queue.createGroup(
      groupId: id,
      title: 'Group $id',
      entryIds: members,
      collapsed: !expanded.contains(id),
    );
  });
  return queue;
}

class FakeBlacklist extends BlackListNotifier {
  @override
  build() async => [];
}

/// The queue UI on top of an in-memory queue: [QueueGroupActions] that apply
/// the real group operations to it (what the audio player notifier does, minus
/// the player), recording every call in [calls]. The queue is the one source of
/// truth: the widget only shows what it holds.
class QueueHarnessState extends State<QueueHarness> {
  late TrackQueue queue = widget.initial;
  late int current = widget.current;
  final calls = <String>[];
  var _groups = 0;

  /// Applies [change] and keeps the same entry playing.
  void change(TrackQueue Function(TrackQueue queue) change) {
    final playing = current >= 0 && current < queue.entries.length
        ? queue.entries[current].id
        : null;
    setState(() {
      queue = change(queue);
      if (playing != null) {
        final at = queue.entries.indexWhere((e) => e.id == playing);
        current = at == -1 ? 0 : at;
      }
    });
  }

  late final QueueGroupActions actions = QueueGroupActions(
    jumpToEntry: (id) async {
      calls.add('jumpToEntry $id');
      setState(() => current = queue.entries.indexWhere((e) => e.id == id));
    },
    createGroup: ({required title, required entryIds}) async {
      final ids = entryIds.toList();
      calls.add('createGroup "$title" ${ids.join(',')}');
      final id = 'N${++_groups}';
      change((q) => q.createGroup(groupId: id, title: title, entryIds: ids));
      return id;
    },
    renameGroup: (id, title) async {
      calls.add('renameGroup $id "$title"');
      change((q) => q.renameGroup(id, title));
    },
    setCollapsed: (id, collapsed) async {
      calls.add('setCollapsed $id $collapsed');
      change((q) => q.setCollapsed(id, collapsed));
    },
    ungroup: (id) async {
      calls.add('ungroup $id');
      change((q) => q.ungroup(id));
    },
    moveGroup: (id, to) async {
      calls.add('moveGroup $id $to');
      change((q) => q.moveGroup(id, to));
    },
    moveQueueItem: (from, to) async {
      calls.add('moveQueueItem $from $to');
      change((q) => q.moveItem(from, to));
    },
    moveWithinGroup: (id, from, to) async {
      calls.add('moveWithinGroup $id $from $to');
      change((q) => q.moveWithinGroup(id, from, to));
    },
    removeEntries: (ids) async {
      calls.add('removeEntries ${ids.join(',')}');
      change((q) => q.removeEntries(ids));
    },
  );

  AudioPlayerState get playerState => AudioPlayerState(
        playing: false,
        loopMode: PlaylistMode.none,
        shuffled: false,
        collections: const [],
        currentIndex: current,
      ).withGroupedQueue(queue);

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        blacklistProvider.overrideWith(FakeBlacklist.new),
        queryingTrackInfoProvider.overrideWithValue(false),
      ],
      child: ShadcnApp(
        theme: ThemeData(
            colorScheme: LegacyColorSchemes.lightSlate(),
            radius: .5,
            iconTheme: const IconThemeProperties()),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          child: PlayerQueue(
            floating: false,
            playlist: playerState,
            groupActions: widget.groupsEnabled ? actions : null,
            onJump: (track) async => calls.add('onJump ${track.id}'),
            onRemove: (id) async => calls.add('onRemove $id'),
            onStop: () async => calls.add('onStop'),
            onReorder: (oldIndex, newIndex) async {
              calls.add('onReorder $oldIndex $newIndex');
              change(
                (q) => GroupedQueue.ungrouped(
                  moveEntry(q.entries, oldIndex, newIndex),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class QueueHarness extends StatefulWidget {
  final TrackQueue initial;
  final int current;

  /// False for a queue without group support (a remote player's).
  final bool groupsEnabled;

  QueueHarness(this.initial, {this.current = 0, this.groupsEnabled = true})
      : super(key: UniqueKey());

  @override
  State<QueueHarness> createState() => QueueHarnessState();
}
