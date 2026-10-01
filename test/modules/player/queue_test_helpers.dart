import 'package:flutter/widgets.dart' show Key, Offset, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/track_tile/track_tile.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';

import 'queue_harness.dart';

/// Finders and gestures for the queue list, shared by the widget tests of the
/// queue UI.

Finder row(String key) => find.byKey(ValueKey<String>(key));
Finder entry(String id) => row('entry:$id');
Finder groupRow(String id) => row('group:$id');
Finder handle(String key) => find.byKey(Key('queue-drag-handle:$key'));

/// The keys of the rows on screen, top to bottom.
List<String> visibleRows(WidgetTester tester) {
  final tags = tester.widgetList<AutoScrollTag>(find.byType(AutoScrollTag));
  final rows = [
    for (final tag in tags)
      (
        tester.getTopLeft(find.byWidget(tag)).dy,
        (tag.key! as ValueKey<String>).value
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final r in rows) r.$2];
}

/// What the model says should be on screen.
List<String> expectedRows(QueueHarnessState state) => [
      for (final r in buildQueueRows(state.queue, currentIndex: state.current))
        r.key,
    ];

void expectScreenMatchesModel(WidgetTester tester, QueueHarnessState state) {
  expect(visibleRows(tester), expectedRows(state));
}

/// `e1`, `G1[e2,e3]` ...: the top-level shape of the model.
List<String> shapeOf(TrackQueue queue) => [
      for (final item in queue.items)
        switch (item) {
          EntryItem<dynamic>(:final entry) => entry.id,
          GroupItem<dynamic>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ];

/// Whether the row shows a checkbox for choosing it.
bool isSelectable(WidgetTester tester, String id) =>
    tester
        .widget<TrackTile>(
            find.descendant(of: entry(id), matching: find.byType(TrackTile)))
        .onChanged !=
    null;

bool isMarkedPlaying(String id) => find
    .descendant(of: entry(id), matching: find.byIcon(SpotubeIcons.pause))
    .evaluate()
    .isNotEmpty;

/// Taps a track row (on its artwork area, not on the link that is its name).
Future<void> tapRow(WidgetTester tester, String id) async {
  final rect = tester.getRect(entry(id));
  await tester.tapAt(Offset(rect.left + 90, rect.center.dy));
  await tester.pumpAndSettle();
}

Future<void> tapHeader(WidgetTester tester, String groupId) async {
  await tester.tap(find.descendant(
    of: groupRow(groupId),
    matching: find.byKey(const Key('queue-group-title')),
  ));
  await tester.pumpAndSettle();
}

Future<void> openGroupMenu(WidgetTester tester, String groupId) async {
  await tester.tap(find.descendant(
    of: groupRow(groupId),
    matching: find.byKey(const Key('queue-group-menu')),
  ));
  await tester.pumpAndSettle();
}

enum Drop { before, after }

/// Drags the row of [from] by its handle until it sits before or after the row
/// [target].
Future<void> dragTo(
  WidgetTester tester, {
  required String from,
  required String target,
  required Drop drop,
}) async {
  final grip = handle(from);
  expect(grip, findsOneWidget, reason: 'no drag handle for $from');
  final dragged = tester.getRect(find.byKey(ValueKey<String>(from)));
  final goal = tester.getRect(find.byKey(ValueKey<String>(target)));
  final start = tester.getCenter(grip);

  // Where the centre of the dragged row has to be for its start (or end) to be
  // in the half of the target row that means "before" (or "after").
  final centre = drop == Drop.before
      ? goal.top + 3 + dragged.height / 2
      : goal.bottom - 3 - dragged.height / 2;
  final delta = centre - (dragged.top + dragged.height / 2);

  final gesture = await tester.startGesture(start);
  await gesture.moveBy(Offset(0, delta.sign * 12));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveBy(Offset(0, delta - delta.sign * 12));
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await tester.pumpAndSettle();
}
