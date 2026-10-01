import 'package:flutter/widgets.dart' show Key, Offset, Size, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart'
    show Button, Checkbox, TextField;
import 'package:spotube/collections/spotube_icons.dart';
import 'package:spotube/components/track_tile/track_tile.dart';
import 'package:spotube/modules/player/queue_groups/queue_rows.dart';
import 'package:spotube/services/audio_player/queue_groups.dart';

import 'queue_harness.dart';
import 'queue_test_helpers.dart';

/// The queue UI is tested through the real [PlayerQueue] on top of an
/// in-memory queue (see queue_harness.dart): what is on screen must be what
/// the model holds, and every change must go through the group actions.

Future<QueueHarnessState> open(
  WidgetTester tester,
  TrackQueue queue, {
  int current = 0,
  bool groupsEnabled = true,
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    QueueHarness(queue, current: current, groupsEnabled: groupsEnabled),
  );
  await tester.pumpAndSettle();
  return tester.state<QueueHarnessState>(find.byType(QueueHarness));
}

void main() {
  // e1 [G1: e2 e3] e4 [G2: e5 e6] e7
  TrackQueue mixed({Set<String> expanded = const {}}) => queueOf(
        ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        groups: {
          'G1': ['e2', 'e3'],
          'G2': ['e5', 'e6'],
        },
        expanded: expanded,
      );

  group('a queue without groups', () {
    testWidgets('looks like the normal queue', (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']), current: 1);

      expect(visibleRows(tester), ['entry:e1', 'entry:e2', 'entry:e3']);
      expect(find.byKey(const Key('queue-group-title')), findsNothing);
      for (final name in ['Track a', 'Track b', 'Track c']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(isMarkedPlaying('e2'), isTrue);
      expect(isMarkedPlaying('e1'), isFalse);
      expect(state.calls, isEmpty);
    });

    testWidgets('tapping a track plays that entry', (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']));

      await tapRow(tester, 'e3');

      expect(state.calls, ['jumpToEntry e3']);
      expect(isMarkedPlaying('e3'), isTrue);
    });

    testWidgets('dragging reorders through the plain queue reorder',
        (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c', 'd']));

      await dragTo(tester,
          from: 'entry:e1', target: 'entry:e3', drop: Drop.after);

      expect(state.calls, ['onReorder 0 3']);
      expect(state.queue.entries.map((e) => e.id), ['e2', 'e3', 'e1', 'e4']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('has a drag handle on every row', (tester) async {
      await open(tester, queueOf(['a', 'b']));
      expect(handle('entry:e1'), findsOneWidget);
      expect(handle('entry:e2'), findsOneWidget);
    });
  });

  group('a collapsed group', () {
    testWidgets('shows its title and number of tracks, and hides its tracks',
        (tester) async {
      final state = await open(tester, mixed());

      expect(visibleRows(tester),
          ['entry:e1', 'group:G1', 'entry:e4', 'group:G2', 'entry:e7']);
      expect(
        find.descendant(of: groupRow('G1'), matching: find.text('Group G1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: groupRow('G1'), matching: find.text('2 tracks')),
        findsOneWidget,
      );
      expect(find.text('Track b'), findsNothing);
      expect(find.text('Track c'), findsNothing);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('shows a chevron for collapsed', (tester) async {
      await open(tester, mixed());
      expect(find.byKey(const Key('queue-group-chevron-collapsed')),
          findsNWidgets(2));
      expect(
          find.byKey(const Key('queue-group-chevron-expanded')), findsNothing);
      // Collapsed points right; the glyph is what the user sees.
      for (final id in ['G1', 'G2']) {
        expect(
          find.descendant(
              of: groupRow(id), matching: find.byIcon(SpotubeIcons.angleRight)),
          findsOneWidget,
        );
        expect(
          find.descendant(
              of: groupRow(id), matching: find.byIcon(SpotubeIcons.angleDown)),
          findsNothing,
        );
      }
    });

    testWidgets('says "1 track" for a group of one', (tester) async {
      await open(
        tester,
        queueOf([
          'a',
          'b'
        ], groups: {
          'G1': ['e2']
        }),
      );
      expect(find.text('1 track'), findsOneWidget);
    });
  });

  group('an expanded group', () {
    testWidgets('shows its tracks under the header, in order', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));

      expect(visibleRows(tester), [
        'entry:e1',
        'group:G1',
        'entry:e2',
        'entry:e3',
        'entry:e4',
        'group:G2',
        'entry:e7',
      ]);
      expect(find.text('Track b'), findsOneWidget);
      expect(find.text('Track c'), findsOneWidget);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('indents its tracks and shows an expanded chevron',
        (tester) async {
      await open(tester, mixed(expanded: {'G1'}));

      double left(String id) => tester
          .getTopLeft(
              find.descendant(of: entry(id), matching: find.byType(TrackTile)))
          .dx;

      expect(left('e2'), greaterThan(left('e4')));
      expect(left('e3'), left('e2'));

      expect(find.byKey(const Key('queue-group-chevron-expanded')),
          findsOneWidget);
      expect(find.byKey(const Key('queue-group-chevron-collapsed')),
          findsOneWidget);
      // Expanded points down.
      expect(
        find.descendant(
            of: groupRow('G1'), matching: find.byIcon(SpotubeIcons.angleDown)),
        findsOneWidget,
      );
    });
  });

  group('collapsing and expanding', () {
    testWidgets('tapping the header expands, tapping again collapses',
        (tester) async {
      final state = await open(tester, mixed());

      await tapHeader(tester, 'G1');
      expect(state.calls, ['setCollapsed G1 false']);
      expect(find.text('Track b'), findsOneWidget);
      expect(state.queue.groupById('G1')!.collapsed, isFalse);
      expectScreenMatchesModel(tester, state);

      await tapHeader(tester, 'G1');
      expect(state.calls.last, 'setCollapsed G1 true');
      expect(find.text('Track b'), findsNothing);
      expect(state.queue.groupById('G1')!.collapsed, isTrue);
    });

    testWidgets('tapping the chevron toggles too', (tester) async {
      final state = await open(tester, mixed());

      await tester.tap(find.descendant(
        of: groupRow('G2'),
        matching: find.byKey(const Key('queue-group-chevron-collapsed')),
      ));
      await tester.pumpAndSettle();

      expect(state.calls, ['setCollapsed G2 false']);
      expect(find.text('Track e'), findsOneWidget);
    });

    testWidgets('the collapsed state is the model\'s, not the widget\'s',
        (tester) async {
      final state = await open(tester, mixed());

      // The model changes by itself (as when a saved queue is restored).
      state.change((q) => q.setCollapsed('G1', false));
      await tester.pumpAndSettle();
      expect(find.text('Track b'), findsOneWidget);
      expect(find.byKey(const Key('queue-group-chevron-expanded')),
          findsOneWidget);

      state.change((q) => q.setCollapsed('G1', true));
      await tester.pumpAndSettle();
      expect(find.text('Track b'), findsNothing);
    });

    testWidgets('the menu has Collapse and Expand', (tester) async {
      final state = await open(tester, mixed());

      await openGroupMenu(tester, 'G1');
      expect(find.text('Expand'), findsOneWidget);
      await tester.tap(find.byKey(const Key('queue-group-menu-toggle')));
      await tester.pumpAndSettle();
      expect(state.calls, ['setCollapsed G1 false']);

      await openGroupMenu(tester, 'G1');
      expect(find.text('Collapse'), findsOneWidget);
      await tester.tap(find.byKey(const Key('queue-group-menu-toggle')));
      await tester.pumpAndSettle();
      expect(state.calls.last, 'setCollapsed G1 true');
    });
  });

  group('the playing track', () {
    testWidgets('marks a collapsed group that holds it', (tester) async {
      await open(tester, mixed(), current: 2); // e3, in G1

      expect(
        find.descendant(
            of: groupRow('G1'),
            matching: find.byKey(const Key('queue-group-playing'))),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: groupRow('G2'),
            matching: find.byKey(const Key('queue-group-playing'))),
        findsNothing,
      );
      expect(isMarkedPlaying('e1'), isFalse);
    });

    testWidgets('marks the member, and its group, when expanded',
        (tester) async {
      await open(tester, mixed(expanded: {'G1'}), current: 2); // e3

      expect(isMarkedPlaying('e3'), isTrue);
      expect(isMarkedPlaying('e2'), isFalse);
      expect(
        find.descendant(
            of: groupRow('G1'),
            matching: find.byKey(const Key('queue-group-playing'))),
        findsOneWidget,
      );
    });

    testWidgets('marks a loose track and no group', (tester) async {
      await open(tester, mixed(), current: 3); // e4

      expect(isMarkedPlaying('e4'), isTrue);
      expect(find.byKey(const Key('queue-group-playing')), findsNothing);
    });

    testWidgets('follows the track as it changes', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));
      expect(isMarkedPlaying('e1'), isTrue);

      await tapRow(tester, 'e3');

      expect(state.calls, ['jumpToEntry e3']);
      expect(isMarkedPlaying('e3'), isTrue);
      expect(isMarkedPlaying('e1'), isFalse);
    });

    testWidgets('playing a member does not collapse or move anything',
        (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));
      final before = shapeOf(state.queue);

      await tapRow(tester, 'e2');

      expect(shapeOf(state.queue), before);
      expect(state.queue.groupById('G1')!.collapsed, isFalse);
    });
  });

  group('the same track queued more than once', () {
    // x x x y, with the two middle copies grouped and shown.
    TrackQueue copies() => queueOf(
          ['x', 'x', 'x', 'y'],
          groups: {
            'G1': ['e2', 'e3']
          },
          expanded: {'G1'},
        );

    testWidgets('only the copy that plays is marked', (tester) async {
      for (final playing in [0, 1, 2]) {
        await open(tester, copies(), current: playing);
        for (var i = 0; i < 3; i++) {
          expect(isMarkedPlaying('e${i + 1}'), i == playing,
              reason: 'playing e${playing + 1}, checking e${i + 1}');
        }
      }
    });

    testWidgets('each copy is its own row', (tester) async {
      await open(tester, copies());
      expect(find.text('Track x'), findsNWidgets(3));
      expect(visibleRows(tester), [
        'entry:e1',
        'group:G1',
        'entry:e2',
        'entry:e3',
        'entry:e4',
      ]);
    });

    testWidgets('tapping another copy of the playing track plays that copy',
        (tester) async {
      final state = await open(tester, copies(), current: 0);

      // The second row of 'Track x' is e2.
      await tapRow(tester, 'e3');

      expect(state.calls, ['jumpToEntry e3']);
      expect(isMarkedPlaying('e3'), isTrue);
      expect(isMarkedPlaying('e1'), isFalse);
    });

    testWidgets('tapping the copy that plays does nothing', (tester) async {
      final state = await open(tester, copies(), current: 2);
      await tapRow(tester, 'e3');
      expect(state.calls, isEmpty);
    });

    testWidgets('a collapsed group marks only the group that holds the copy',
        (tester) async {
      final queue = queueOf(
        ['x', 'x', 'x', 'x'],
        groups: {
          'G1': ['e1', 'e2'],
          'G2': ['e3', 'e4'],
        },
      );
      await open(tester, queue, current: 3); // e4, in G2
      expect(
        find.descendant(
            of: groupRow('G2'),
            matching: find.byKey(const Key('queue-group-playing'))),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: groupRow('G1'),
            matching: find.byKey(const Key('queue-group-playing'))),
        findsNothing,
      );
    });
  });

  group('making a group', () {
    Future<void> startChoosing(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('queue-group-select-toggle')));
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String id) async {
      await tester.tap(find.descendant(
        of: entry(id),
        matching: find.byType(Checkbox),
      ));
      await tester.pumpAndSettle();
    }

    Finder createButton() =>
        find.byKey(const Key('queue-group-selection-create'));

    Future<void> confirmTitle(WidgetTester tester, String? title) async {
      if (title != null) {
        await tester.enterText(
            find.byKey(const Key('queue-group-title-field')), title);
      }
      await tester.tap(find.byKey(const Key('queue-group-title-confirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('has no selection until asked', (tester) async {
      await open(tester, queueOf(['a', 'b', 'c']));
      expect(find.byKey(const Key('queue-group-selection-bar')), findsNothing);
      for (final id in ['e1', 'e2', 'e3']) {
        expect(isSelectable(tester, id), isFalse);
      }
    });

    testWidgets('needs at least two tracks', (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']));
      await startChoosing(tester);

      expect(
          find.byKey(const Key('queue-group-selection-bar')), findsOneWidget);
      for (final id in ['e1', 'e2', 'e3']) {
        expect(isSelectable(tester, id), isTrue);
      }

      // Nothing chosen: the button is disabled.
      expect(tester.widget<Button>(createButton()).enabled, isFalse);
      await tester.tap(createButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('queue-group-title-field')), findsNothing);

      // One chosen: still not enough.
      await choose(tester, 'e2');
      expect(tester.widget<Button>(createButton()).enabled, isFalse);
      await tester.tap(createButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('queue-group-title-field')), findsNothing);
      expect(state.calls, isEmpty);

      // Two chosen: it asks for a title.
      await choose(tester, 'e3');
      expect(tester.widget<Button>(createButton()).enabled, isTrue);
      await tester.tap(createButton());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('queue-group-title-field')), findsOneWidget);
    });

    testWidgets('asks for a title and makes a collapsed group', (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c', 'd']));
      await startChoosing(tester);
      await choose(tester, 'e2');
      await choose(tester, 'e3');
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      await confirmTitle(tester, 'Road trip');

      expect(state.calls, ['createGroup "Road trip" e2,e3']);
      expect(shapeOf(state.queue), ['e1', 'N1[e2,e3]', 'e4']);
      expect(state.queue.groupById('N1')!.collapsed, isTrue);
      expect(state.queue.groupById('N1')!.title, 'Road trip');

      // Shown collapsed, and choosing is over.
      expect(visibleRows(tester), ['entry:e1', 'group:N1', 'entry:e4']);
      expect(find.text('Road trip'), findsOneWidget);
      expect(find.text('2 tracks'), findsOneWidget);
      expect(find.byKey(const Key('queue-group-selection-bar')), findsNothing);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('tracks that were apart are gathered, in queue order',
        (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c', 'd', 'e']));
      await startChoosing(tester);
      // Chosen out of order, with others between them.
      await choose(tester, 'e4');
      await choose(tester, 'e2');
      await tester.tap(createButton());
      await tester.pumpAndSettle();
      await confirmTitle(tester, 'Mix');

      expect(state.calls, ['createGroup "Mix" e2,e4']);
      expect(shapeOf(state.queue), ['e1', 'N1[e2,e4]', 'e3', 'e5']);
    });

    testWidgets('a blank title becomes the default one', (tester) async {
      final state = await open(tester, queueOf(['a', 'b']));
      await startChoosing(tester);
      await choose(tester, 'e1');
      await choose(tester, 'e2');
      await tester.tap(createButton());
      await tester.pumpAndSettle();
      await confirmTitle(tester, '   ');

      expect(state.queue.groups.single.title, 'New group');
    });

    testWidgets('cancelling the title makes nothing and keeps the choice',
        (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']));
      await startChoosing(tester);
      await choose(tester, 'e1');
      await choose(tester, 'e2');
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('queue-group-title-cancel')));
      await tester.pumpAndSettle();

      expect(state.calls, isEmpty);
      expect(state.queue.groups, isEmpty);
      expect(
          find.byKey(const Key('queue-group-selection-bar')), findsOneWidget);
      expect(createButton(), findsOneWidget);
    });

    testWidgets('cancelling the selection leaves the queue alone',
        (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']));
      await startChoosing(tester);
      await choose(tester, 'e1');

      await tester.tap(find.byKey(const Key('queue-group-selection-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('queue-group-selection-bar')), findsNothing);
      expect(isSelectable(tester, 'e1'), isFalse);
      expect(state.calls, isEmpty);
    });

    testWidgets('tracks already in a group cannot be chosen', (tester) async {
      await open(tester, mixed(expanded: {'G1'}));
      await startChoosing(tester);

      // Loose rows (e1, e4, e7) can be chosen; the members e2, e3 cannot.
      expect(isSelectable(tester, 'e1'), isTrue);
      expect(isSelectable(tester, 'e4'), isTrue);
      expect(isSelectable(tester, 'e7'), isTrue);
      expect(isSelectable(tester, 'e2'), isFalse);
      expect(isSelectable(tester, 'e3'), isFalse);
    });

    testWidgets('tapping a row while choosing chooses it instead of playing',
        (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c']));
      await startChoosing(tester);

      await tapRow(tester, 'e3');

      expect(state.calls, isEmpty);
      expect(find.text('1 selected'), findsNothing); // not enough yet
      await tapRow(tester, 'e2');
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('rows cannot be dragged while choosing', (tester) async {
      await open(tester, queueOf(['a', 'b', 'c']));
      expect(handle('entry:e1'), findsOneWidget);
      await startChoosing(tester);
      expect(handle('entry:e1'), findsNothing);
    });

    testWidgets('the selection button is not offered when searching',
        (tester) async {
      await open(tester, queueOf(['a', 'b', 'c']));
      await tester.enterText(find.byType(TextField), 'Track b');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('queue-group-select-toggle')), findsNothing);
    });
  });

  group('rename and ungroup', () {
    testWidgets('rename asks for a title, starting from the current one',
        (tester) async {
      final state = await open(tester, mixed());

      await openGroupMenu(tester, 'G1');
      await tester.tap(find.byKey(const Key('queue-group-menu-rename')));
      await tester.pumpAndSettle();

      final field = tester
          .widget<TextField>(find.byKey(const Key('queue-group-title-field')));
      expect(field.controller!.text, 'Group G1');

      await tester.enterText(
          find.byKey(const Key('queue-group-title-field')), 'Workout');
      await tester.tap(find.byKey(const Key('queue-group-title-confirm')));
      await tester.pumpAndSettle();

      expect(state.calls, ['renameGroup G1 "Workout"']);
      expect(find.text('Workout'), findsOneWidget);
      expect(find.text('Group G1'), findsNothing);
      expect(state.queue.groupById('G1')!.title, 'Workout');
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('cancelling a rename changes nothing', (tester) async {
      final state = await open(tester, mixed());
      await openGroupMenu(tester, 'G1');
      await tester.tap(find.byKey(const Key('queue-group-menu-rename')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('queue-group-title-cancel')));
      await tester.pumpAndSettle();

      expect(state.calls, isEmpty);
      expect(find.text('Group G1'), findsOneWidget);
    });

    testWidgets('keeping the same title is not a rename', (tester) async {
      final state = await open(tester, mixed());
      await openGroupMenu(tester, 'G1');
      await tester.tap(find.byKey(const Key('queue-group-menu-rename')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('queue-group-title-confirm')));
      await tester.pumpAndSettle();
      expect(state.calls, isEmpty);
    });

    testWidgets('ungroup dissolves the group and keeps its tracks in place',
        (tester) async {
      final state = await open(tester, mixed(), current: 2);
      final order = state.queue.entries.map((e) => e.id).toList();

      await openGroupMenu(tester, 'G1');
      await tester.tap(find.byKey(const Key('queue-group-menu-ungroup')));
      await tester.pumpAndSettle();

      expect(state.calls, ['ungroup G1']);
      expect(state.queue.groupById('G1'), isNull);
      expect(state.queue.entries.map((e) => e.id), order);
      expect(
        visibleRows(tester),
        [
          'entry:e1',
          'entry:e2',
          'entry:e3',
          'entry:e4',
          'group:G2',
          'entry:e7',
        ],
      );
      // The track that played still plays, now as a loose row.
      expect(isMarkedPlaying('e3'), isTrue);
      expectScreenMatchesModel(tester, state);
    });
  });

  group('dragging', () {
    testWidgets('a collapsed group header moves the whole group',
        (tester) async {
      final state = await open(tester, mixed());

      await dragTo(tester,
          from: 'group:G1', target: 'entry:e7', drop: Drop.after);

      expect(state.calls, ['moveGroup G1 5']);
      expect(
          shapeOf(state.queue), ['e1', 'e4', 'G2[e5,e6]', 'e7', 'G1[e2,e3]']);
      expect(visibleRows(tester),
          ['entry:e1', 'entry:e4', 'group:G2', 'entry:e7', 'group:G1']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('an expanded group header moves the whole group too',
        (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));

      await dragTo(tester,
          from: 'group:G1', target: 'entry:e7', drop: Drop.after);

      expect(state.calls.single, startsWith('moveGroup G1'));
      expect(
          shapeOf(state.queue), ['e1', 'e4', 'G2[e5,e6]', 'e7', 'G1[e2,e3]']);
      expect(state.queue.groupById('G1')!.memberIds, ['e2', 'e3']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('a group can be moved up as well', (tester) async {
      final state = await open(tester, mixed());

      await dragTo(tester,
          from: 'group:G2', target: 'entry:e1', drop: Drop.before);

      expect(state.calls, ['moveGroup G2 0']);
      expect(
          shapeOf(state.queue), ['G2[e5,e6]', 'e1', 'G1[e2,e3]', 'e4', 'e7']);
    });

    testWidgets('a member moves inside its group only', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));

      await dragTo(tester,
          from: 'entry:e2', target: 'entry:e3', drop: Drop.after);

      expect(state.calls, ['moveWithinGroup G1 0 2']);
      expect(
          shapeOf(state.queue), ['e1', 'G1[e3,e2]', 'e4', 'G2[e5,e6]', 'e7']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('a member cannot be dropped outside its group', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));

      // Far below its group, next to e7.
      await dragTo(tester,
          from: 'entry:e2', target: 'entry:e7', drop: Drop.after);

      // It stays in G1, at the nearest end.
      expect(state.calls.every((c) => c.startsWith('moveWithinGroup')), isTrue);
      expect(state.queue.groupOf('e2')!.id, 'G1');
      expect(
          shapeOf(state.queue), ['e1', 'G1[e3,e2]', 'e4', 'G2[e5,e6]', 'e7']);

      // And upwards, above e1.
      await dragTo(tester,
          from: 'entry:e2', target: 'entry:e1', drop: Drop.before);
      expect(state.queue.groupOf('e2')!.id, 'G1');
      expect(state.queue.groupById('G1')!.memberIds, ['e2', 'e3']);
      expect(
          shapeOf(state.queue), ['e1', 'G1[e2,e3]', 'e4', 'G2[e5,e6]', 'e7']);
    });

    testWidgets('a loose track moves among the top-level rows', (tester) async {
      final state = await open(tester, mixed());

      await dragTo(tester,
          from: 'entry:e1', target: 'entry:e4', drop: Drop.after);

      expect(state.calls, ['moveQueueItem 0 3']);
      expect(
          shapeOf(state.queue), ['G1[e2,e3]', 'e4', 'e1', 'G2[e5,e6]', 'e7']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('a loose track dropped on an expanded group stays outside it',
        (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));

      // Onto the first member of G1.
      await dragTo(tester,
          from: 'entry:e4', target: 'entry:e2', drop: Drop.before);

      expect(state.queue.groupOf('e4'), isNull);
      expect(state.queue.groupById('G1')!.memberIds, ['e2', 'e3']);
      expect(state.queue.validate(), isEmpty);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('a group is never split by a drag', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1', 'G2'}));

      await dragTo(tester,
          from: 'entry:e1', target: 'entry:e3', drop: Drop.before);

      expect(state.queue.validate(), isEmpty);
      expect(state.queue.groupById('G1')!.memberIds, ['e2', 'e3']);
      expect(state.queue.groupById('G2')!.memberIds, ['e5', 'e6']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('the same entry keeps playing through every kind of drag',
        (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}), current: 2);
      final playing = state.queue.entries[state.current].id; // e3

      await dragTo(tester,
          from: 'entry:e2', target: 'entry:e3', drop: Drop.after);
      expect(state.queue.entries[state.current].id, playing);
      expect(isMarkedPlaying(playing.replaceFirst('e', 'e')), isTrue);

      await dragTo(tester,
          from: 'group:G1', target: 'entry:e7', drop: Drop.after);
      expect(state.queue.entries[state.current].id, playing);
      expect(isMarkedPlaying(playing), isTrue);

      expect(state.calls.any((c) => c.startsWith('jumpToEntry')), isFalse);
    });

    testWidgets('dropping a row where it is does nothing', (tester) async {
      final state = await open(tester, mixed());

      // Pick e4 up, move it away and put it back.
      final gesture = await tester.startGesture(
        tester.getCenter(handle('entry:e4')),
      );
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(state.calls, isEmpty);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('no drag handles while searching', (tester) async {
      await open(tester, mixed());
      await tester.enterText(find.byType(TextField), 'Track');
      await tester.pumpAndSettle();
      expect(handle('entry:e1'), findsNothing);
      expect(find.byKey(const Key('queue-group-title')), findsNothing);
    });
  });

  group('a mixed queue', () {
    testWidgets('renders exactly the structure of the model', (tester) async {
      final state = await open(tester, mixed(expanded: {'G2'}));
      expect(visibleRows(tester), [
        'entry:e1',
        'group:G1',
        'entry:e4',
        'group:G2',
        'entry:e5',
        'entry:e6',
        'entry:e7',
      ]);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('keeps matching the model through a series of changes',
        (tester) async {
      final state = await open(tester, mixed(), current: 5);

      Future<void> step(void Function() change) async {
        change();
        await tester.pumpAndSettle();
        expectScreenMatchesModel(tester, state);
        expect(state.queue.validate(), isEmpty);
      }

      await step(() => state.change((q) => q.setCollapsed('G2', false)));
      await step(() => state.change((q) => q.moveGroup('G1', 3)));
      await step(() => state.change((q) => q.moveWithinGroup('G2', 0, 2)));
      await step(() => state.change((q) => q.ungroup('G1')));
      await step(() => state.change((q) => q.moveItem(0, 3)));
      await step(() => state.change((q) =>
          q.createGroup(groupId: 'N', title: 'New', entryIds: ['e1', 'e2'])));
    });
  });

  group('removing group members', () {
    testWidgets('losing the last member removes the group from the screen',
        (tester) async {
      final state = await open(tester, mixed());

      state.change((q) => q.removeEntries(['e2']));
      await tester.pumpAndSettle();
      expect(find.text('1 track'), findsOneWidget);

      state.change((q) => q.removeEntries(['e3']));
      await tester.pumpAndSettle();

      expect(state.queue.groupById('G1'), isNull);
      expect(find.text('Group G1'), findsNothing);
      expect(visibleRows(tester),
          ['entry:e1', 'entry:e4', 'group:G2', 'entry:e7']);
      expectScreenMatchesModel(tester, state);
    });

    testWidgets('a group is never shown empty', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1', 'G2'}));
      state.change((q) => q.removeEntries(['e2', 'e3', 'e5', 'e6']));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('queue-group-title')), findsNothing);
      expect(visibleRows(tester), ['entry:e1', 'entry:e4', 'entry:e7']);
    });

    testWidgets('a group of one is shown', (tester) async {
      final state = await open(tester, mixed(expanded: {'G1'}));
      state.change((q) => q.removeEntries(['e3']));
      await tester.pumpAndSettle();

      expect(find.text('1 track'), findsOneWidget);
      expect(find.text('Group G1'), findsOneWidget);
      expect(visibleRows(tester).take(3), ['entry:e1', 'group:G1', 'entry:e2']);
    });
  });

  group('a queue without group support (a remote player\'s)', () {
    // The same queue, but the widget is given no group actions.
    testWidgets('is shown as a flat list, groups or not', (tester) async {
      final state = await open(tester, mixed(), groupsEnabled: false);

      // Every track once, in queue order, with no group rows.
      final names = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];
      final tops = [
        for (final name in names)
          tester.getTopLeft(find.text('Track $name')).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(tops.toSet(), hasLength(7));
      expect(find.byKey(const Key('queue-group-title')), findsNothing);
      expect(find.byKey(const Key('queue-group-select-toggle')), findsNothing);
      for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) {
        expect(find.text('Track $name'), findsOneWidget);
      }
      expect(state.calls, isEmpty);
    });

    testWidgets('plays by track and reorders as it always did', (tester) async {
      final state = await open(tester, queueOf(['a', 'b', 'c', 'd']),
          groupsEnabled: false);

      final rect = tester.getRect(find.byType(TrackTile).at(2));
      await tester.tapAt(Offset(rect.left + 90, rect.center.dy));
      await tester.pumpAndSettle();
      expect(state.calls, ['onJump c']);

      final grip = find.byIcon(SpotubeIcons.dragHandle).first;
      final gesture = await tester.startGesture(tester.getCenter(grip));
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, 130));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.calls.last, startsWith('onReorder 0 '));
    });
  });
}
