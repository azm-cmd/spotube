import 'dart:math';

import 'package:spotube/services/audio_player/queue_groups.dart';
import 'package:spotube/services/audio_player/queue_operations.dart';
import 'package:test/test.dart';

/// Stand-in for a track. Only the id matters: several entries can share it.
class _Track {
  final String id;
  const _Track(this.id);

  @override
  String toString() => id;
}

typedef _Queue = GroupedQueue<_Track>;

/// Entries e1, e2, ... for the given track ids.
List<QueueEntry<_Track>> _entries(List<String> trackIds) => [
      for (var i = 0; i < trackIds.length; i++)
        QueueEntry('e${i + 1}', _Track(trackIds[i])),
    ];

/// e1..e8. Track ids repeat on purpose: a at e1/e3/e5, b at e2/e7.
_Queue _base() => GroupedQueue.ungrouped(
      _entries(['a', 'b', 'a', 'c', 'a', 'd', 'b', 'e']),
    );

/// ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']
_Queue _mixed() => _base().createGroup(groupId: 'G1', title: 'One', entryIds: [
      'e2',
      'e3',
      'e4'
    ]).createGroup(groupId: 'G2', title: 'Two', entryIds: ['e6', 'e7']);

/// The top-level rows as text: `e1` for a loose entry, `G1[e2,e3]` for a group.
List<String> _shape(_Queue queue) => [
      for (final item in queue.items)
        switch (item) {
          EntryItem<_Track>(:final entry) => entry.id,
          GroupItem<_Track>(:final group) =>
            '${group.id}[${group.memberIds.join(',')}]',
        },
    ];

List<String> _flat(_Queue queue) => [for (final e in queue.entries) e.id];

/// Runs [body] and returns the [QueueGroupError] it throws.
QueueGroupError _errorOf(void Function() body) {
  try {
    body();
  } on QueueGroupError catch (error) {
    return error;
  }
  fail('Expected a QueueGroupError');
}

Matcher _failsWith(QueueGroupErrorReason reason) => throwsA(
      isA<QueueGroupError>().having((e) => e.reason, 'reason', reason),
    );

void main() {
  group('QueueGroup', () {
    test('groups start collapsed', () {
      expect(const QueueGroup(id: 'g', title: 't', memberIds: ['e1']).collapsed,
          isTrue);
    });

    test('length is the number of members', () {
      expect(
          const QueueGroup(id: 'g', title: 't', memberIds: ['a', 'b']).length,
          2);
    });

    test('has value equality, including member order', () {
      const a = QueueGroup(id: 'g', title: 't', memberIds: ['x', 'y']);
      const b = QueueGroup(id: 'g', title: 't', memberIds: ['x', 'y']);
      const reordered = QueueGroup(id: 'g', title: 't', memberIds: ['y', 'x']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(reordered));
      expect(a, isNot(a.copyWith(title: 'other')));
      expect(a, isNot(a.copyWith(collapsed: false)));
    });

    test('copyWith keeps the id and what it is not given', () {
      const group = QueueGroup(id: 'g', title: 't', memberIds: ['x']);
      final copy = group.copyWith(title: 'new');
      expect(copy.id, 'g');
      expect(copy.title, 'new');
      expect(copy.memberIds, ['x']);
      expect(copy.collapsed, isTrue);
    });

    test('groups made by an operation cannot be edited in place', () {
      final group = _base()
          .createGroup(groupId: 'G', title: 'T', entryIds: ['e1', 'e2'])
          .groups
          .single;
      expect(() => group.memberIds.add('e3'), throwsUnsupportedError);
    });
  });

  group('validate', () {
    test('an ungrouped queue is valid, empty or not', () {
      expect(
          GroupedQueue.ungrouped(<QueueEntry<_Track>>[]).validate(), isEmpty);
      expect(_base().validate(), isEmpty);
      expect(_base().isValid, isTrue);
    });

    test('a mixed queue with several groups is valid', () {
      expect(_mixed().validate(), isEmpty);
    });

    _Queue withGroups(List<QueueGroup> groups) =>
        GroupedQueue(_entries(['a', 'b', 'a', 'c']), groups);

    test('flags a repeated entry id', () {
      final queue = GroupedQueue([
        const QueueEntry('e1', _Track('a')),
        const QueueEntry('e1', _Track('b')),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.duplicateEntryId,
          entryId: 'e1',
        ),
      ]);
    });

    test('flags a repeated group id', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '1', memberIds: ['e1', 'e2']),
        QueueGroup(id: 'G', title: '2', memberIds: ['e3', 'e4']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.duplicateGroupId,
          groupId: 'G',
        ),
      ]);
    });

    test('flags an empty group', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: []),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.emptyGroup,
          groupId: 'G',
        ),
      ]);
    });

    test('flags the same member listed twice', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: ['e1', 'e1']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.duplicateMember,
          groupId: 'G',
          entryId: 'e1',
        ),
      ]);
    });

    test('flags a member that is not in the queue', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: ['e1', 'ghost']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.unknownMember,
          groupId: 'G',
          entryId: 'ghost',
        ),
      ]);
    });

    test('flags an entry that is in two groups', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G1', title: '', memberIds: ['e1', 'e2']),
        QueueGroup(id: 'G2', title: '', memberIds: ['e2', 'e3']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.entryInMultipleGroups,
          groupId: 'G2',
          entryId: 'e2',
        ),
      ]);
    });

    test('flags members that are not one block of the queue', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: ['e1', 'e3']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.notContiguous,
          groupId: 'G',
        ),
      ]);
    });

    test('flags members listed in a different order than the queue', () {
      final queue = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: ['e2', 'e1']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.membersOutOfOrder,
          groupId: 'G',
        ),
      ]);
    });

    test('flags groups that are not ordered by where they start', () {
      final queue = withGroups(const [
        QueueGroup(id: 'late', title: '', memberIds: ['e3', 'e4']),
        QueueGroup(id: 'early', title: '', memberIds: ['e1', 'e2']),
      ]);
      expect(queue.validate(), [
        const QueueGroupViolation(
          QueueGroupViolationKind.groupsOutOfOrder,
          groupId: 'early',
        ),
      ]);
    });

    test('checked() accepts a valid queue and rejects an invalid one', () {
      expect(
        GroupedQueue.checked(_entries(['a', 'b']), const [
          QueueGroup(id: 'G', title: '', memberIds: ['e1', 'e2']),
        ]).groups.length,
        1,
      );

      final error = _errorOf(() => GroupedQueue.checked(_entries(['a']), const [
            QueueGroup(id: 'G', title: '', memberIds: ['ghost']),
          ]));
      expect(error.reason, QueueGroupErrorReason.invalidQueue);
      expect(
          error.violations.single.kind, QueueGroupViolationKind.unknownMember);
    });

    test('every operation refuses to start from an invalid queue', () {
      final broken = withGroups(const [
        QueueGroup(id: 'G', title: '', memberIds: ['e1', 'e3']),
      ]);
      final attempts = <void Function()>[
        () => broken.items,
        () => broken.createGroup(groupId: 'N', title: '', entryIds: ['e2']),
        () => broken.addToGroup('G', ['e2']),
        () => broken.removeFromGroup(['e1']),
        () => broken.ungroup('G'),
        () => broken.moveItem(0, 1),
        () => broken.moveGroup('G', 0),
        () => broken.moveWithinGroup('G', 0, 1),
        () => broken.removeEntries(['e1']),
        () => broken.insertUngrouped(0, [const QueueEntry('x', _Track('x'))]),
        () => broken.renameGroup('G', 'x'),
        () => broken.setCollapsed('G', false),
      ];
      for (final attempt in attempts) {
        expect(attempt, _failsWith(QueueGroupErrorReason.invalidQueue));
      }
    });
  });

  group('lookups', () {
    test('groupOf and groupIdByEntryId say which entries are in which group',
        () {
      final queue = _mixed();
      expect(queue.groupIdByEntryId, {
        'e2': 'G1',
        'e3': 'G1',
        'e4': 'G1',
        'e6': 'G2',
        'e7': 'G2',
      });
      expect(queue.groupOf('e3')!.id, 'G1');
      expect(queue.groupOf('e7')!.title, 'Two');
      expect(queue.groupOf('e1'), isNull);
      expect(queue.groupOf('ghost'), isNull);
      expect(queue.groupById('G2')!.length, 2);
      expect(queue.groupById('nope'), isNull);
    });

    test('membersOf returns the member entries in queue order', () {
      expect(_mixed().membersOf('G1').map((e) => e.id), ['e2', 'e3', 'e4']);
      expect(
        () => _mixed().membersOf('nope'),
        _failsWith(QueueGroupErrorReason.unknownGroup),
      );
    });

    test('ungroupedEntries are the loose ones, in queue order', () {
      expect(_mixed().ungroupedEntries.map((e) => e.id), ['e1', 'e5', 'e8']);
      expect(_base().ungroupedEntries.length, 8);
    });

    test('items has one row per loose entry and one per whole group', () {
      final items = _mixed().items;
      expect(items.length, 5);
      expect(items[0], isA<EntryItem<_Track>>());
      final group = items[1] as GroupItem<_Track>;
      expect(group.group.id, 'G1');
      expect(group.entries.map((e) => e.id), ['e2', 'e3', 'e4']);
      expect(items[4], isA<EntryItem<_Track>>());
    });

    test('items of an empty queue is empty', () {
      expect(GroupedQueue.ungrouped(<QueueEntry<_Track>>[]).items, isEmpty);
    });
  });

  group('createGroup', () {
    test('turns a run of entries into a collapsed group, in place', () {
      final queue = _base().createGroup(
        groupId: 'G1',
        title: 'Album',
        entryIds: ['e3', 'e4'],
      );
      expect(_shape(queue), ['e1', 'e2', 'G1[e3,e4]', 'e5', 'e6', 'e7', 'e8']);
      expect(_flat(queue), _flat(_base()));
      expect(queue.groups.single.title, 'Album');
      expect(queue.groups.single.collapsed, isTrue);
      expect(queue.validate(), isEmpty);
    });

    test('can start expanded', () {
      final queue = _base().createGroup(
        groupId: 'G',
        title: 'T',
        entryIds: ['e1'],
        collapsed: false,
      );
      expect(queue.groups.single.collapsed, isFalse);
    });

    test('gathers scattered entries at the first one, in queue order', () {
      final queue = _base().createGroup(
        groupId: 'G1',
        title: 'T',
        entryIds: ['e6', 'e2', 'e4'],
      );
      expect(_shape(queue), ['e1', 'G1[e2,e4,e6]', 'e3', 'e5', 'e7', 'e8']);
      expect(_flat(queue), ['e1', 'e2', 'e4', 'e6', 'e3', 'e5', 'e7', 'e8']);
    });

    test('the order of the selection does not matter', () {
      final one = _base()
          .createGroup(groupId: 'G', title: 'T', entryIds: ['e2', 'e4', 'e6']);
      final other = _base()
          .createGroup(groupId: 'G', title: 'T', entryIds: ['e6', 'e4', 'e2']);
      expect(_flat(one), _flat(other));
      expect(one.groups, other.groups);
    });

    test('a repeated id counts once', () {
      final queue = _base().createGroup(
        groupId: 'G',
        title: 'T',
        entryIds: ['e2', 'e2', 'e3'],
      );
      expect(queue.groups.single.memberIds, ['e2', 'e3']);
    });

    test('a group of one entry is allowed', () {
      final queue =
          _base().createGroup(groupId: 'G', title: 'T', entryIds: ['e5']);
      expect(_shape(queue)[4], 'G[e5]');
      expect(queue.validate(), isEmpty);
    });

    test('groups only the chosen copy when track ids are duplicated', () {
      // e1, e3 and e5 are all track "a".
      final queue =
          _base().createGroup(groupId: 'G', title: 'T', entryIds: ['e3']);

      expect(queue.groupOf('e3')!.id, 'G');
      expect(queue.groupOf('e1'), isNull);
      expect(queue.groupOf('e5'), isNull);
      expect(queue.membersOf('G').single.track.id, 'a');
      expect(
          queue.ungroupedEntries
              .where((e) => e.track.id == 'a')
              .map((e) => e.id),
          ['e1', 'e5']);
    });

    test('groups several copies of the same track as separate members', () {
      final queue =
          _base().createGroup(groupId: 'G', title: 'T', entryIds: ['e1', 'e5']);

      expect(queue.groups.single.memberIds, ['e1', 'e5']);
      expect(queue.membersOf('G').map((e) => e.track.id), ['a', 'a']);
      expect(_flat(queue), ['e1', 'e5', 'e2', 'e3', 'e4', 'e6', 'e7', 'e8']);
    });

    test('refuses an entry that is already in a group', () {
      final error = _errorOf(() => _mixed()
          .createGroup(groupId: 'G3', title: 'T', entryIds: ['e1', 'e6']));
      expect(error.reason, QueueGroupErrorReason.entryAlreadyGrouped);
      expect(error.ids, ['e6']);
    });

    test('refuses an unknown (stale) entry id', () {
      final error = _errorOf(() => _base()
          .createGroup(groupId: 'G', title: 'T', entryIds: ['e1', 'gone']));
      expect(error.reason, QueueGroupErrorReason.unknownEntry);
      expect(error.ids, ['gone']);
    });

    test('refuses an empty selection', () {
      expect(
        () => _base().createGroup(groupId: 'G', title: 'T', entryIds: const []),
        _failsWith(QueueGroupErrorReason.noEntries),
      );
    });

    test('refuses a group id that is taken', () {
      expect(
        () => _mixed().createGroup(groupId: 'G1', title: 'T', entryIds: ['e1']),
        _failsWith(QueueGroupErrorReason.duplicateGroupId),
      );
    });

    test('leaves the original queue untouched', () {
      final queue = _base();
      final before = _flat(queue);
      queue.createGroup(groupId: 'G', title: 'T', entryIds: ['e2', 'e5']);
      expect(_flat(queue), before);
      expect(queue.groups, isEmpty);
    });
  });

  group('addToGroup', () {
    test('appends a loose entry and moves it next to the group', () {
      final queue = _mixed().addToGroup('G1', ['e5']);
      expect(_shape(queue), ['e1', 'G1[e2,e3,e4,e5]', 'G2[e6,e7]', 'e8']);
      expect(queue.validate(), isEmpty);
    });

    test('puts it at the requested position among the members', () {
      final queue = _mixed().addToGroup('G1', ['e8'], index: 0);
      expect(_shape(queue), ['e1', 'G1[e8,e2,e3,e4]', 'e5', 'G2[e6,e7]']);
      expect(_flat(queue), ['e1', 'e8', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7']);
    });

    test('several entries keep their queue order, wherever they came from', () {
      final queue = _mixed().addToGroup('G1', ['e5', 'e1'], index: 1);
      expect(_shape(queue), ['G1[e2,e1,e5,e3,e4]', 'G2[e6,e7]', 'e8']);
    });

    test('adding at the end position is allowed', () {
      final queue = _mixed().addToGroup('G2', ['e1'], index: 2);
      expect(queue.groupById('G2')!.memberIds, ['e6', 'e7', 'e1']);
    });

    test('adding nothing returns the same queue', () {
      final queue = _mixed();
      expect(identical(queue.addToGroup('G1', const []), queue), isTrue);
    });

    test('refuses an entry that already belongs to a group', () {
      final other = _errorOf(() => _mixed().addToGroup('G1', ['e6']));
      expect(other.reason, QueueGroupErrorReason.entryAlreadyGrouped);
      expect(other.ids, ['e6']);

      final same = _errorOf(() => _mixed().addToGroup('G1', ['e2']));
      expect(same.reason, QueueGroupErrorReason.entryAlreadyGrouped);
    });

    test('an entry can never end up in two groups', () {
      var queue = _mixed().addToGroup('G1', ['e5']);
      expect(() => queue.addToGroup('G2', ['e5']),
          _failsWith(QueueGroupErrorReason.entryAlreadyGrouped));
      queue = queue.removeFromGroup(['e5']).addToGroup('G2', ['e5']);
      expect(queue.groupOf('e5')!.id, 'G2');
      expect(queue.groupById('G1')!.memberIds, isNot(contains('e5')));
    });

    test('refuses unknown (stale) entries and groups', () {
      expect(() => _mixed().addToGroup('G1', ['gone']),
          _failsWith(QueueGroupErrorReason.unknownEntry));
      expect(() => _mixed().addToGroup('nope', ['e1']),
          _failsWith(QueueGroupErrorReason.unknownGroup));
    });

    test('rejects a position outside the group', () {
      expect(
          () => _mixed().addToGroup('G1', ['e1'], index: -1), throwsRangeError);
      expect(
          () => _mixed().addToGroup('G1', ['e1'], index: 4), throwsRangeError);
    });

    test('moves only the chosen copy of a duplicated track', () {
      final queue = _mixed().addToGroup('G1', ['e5']); // e5 is track "a"
      expect(queue.groupOf('e5')!.id, 'G1');
      expect(queue.ungroupedEntries.map((e) => e.id), ['e1', 'e8']);
      // e1 is also track "a" and stays loose.
      expect(queue.entries.where((e) => e.track.id == 'a').length, 3);
    });
  });

  group('removeFromGroup', () {
    test('a first member stays where it is, in front of the group', () {
      final queue = _mixed().removeFromGroup(['e2']);
      expect(_shape(queue), ['e1', 'e2', 'G1[e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_flat(queue), _flat(_mixed()));
    });

    test('a last member stays where it is, after the group', () {
      final queue = _mixed().removeFromGroup(['e4']);
      expect(_shape(queue), ['e1', 'G1[e2,e3]', 'e4', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_flat(queue), _flat(_mixed()));
    });

    test('a member from the middle moves to just after the group', () {
      final queue = _mixed().removeFromGroup(['e3']);
      expect(_shape(queue), ['e1', 'G1[e2,e4]', 'e3', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_flat(queue), ['e1', 'e2', 'e4', 'e3', 'e5', 'e6', 'e7', 'e8']);
    });

    test('leading, interior and trailing members are each placed correctly',
        () {
      final queue = _base().createGroup(groupId: 'G', title: 'T', entryIds: [
        'e1',
        'e2',
        'e3',
        'e4',
        'e5'
      ]).removeFromGroup(['e1', 'e3', 'e5']);
      expect(_shape(queue), ['e1', 'G[e2,e4]', 'e3', 'e5', 'e6', 'e7', 'e8']);
      expect(queue.validate(), isEmpty);
    });

    test('removing every member deletes the group and keeps the entries', () {
      final queue = _mixed().removeFromGroup(['e2', 'e3', 'e4']);
      expect(_shape(queue), ['e1', 'e2', 'e3', 'e4', 'e5', 'G2[e6,e7]', 'e8']);
      expect(queue.groups.map((g) => g.id), ['G2']);
      expect(_flat(queue), _flat(_mixed()));
    });

    test('works across several groups at once', () {
      final queue = _mixed().removeFromGroup(['e2', 'e7']);
      expect(
          _shape(queue), ['e1', 'e2', 'G1[e3,e4]', 'e5', 'G2[e6]', 'e7', 'e8']);
    });

    test('removes exactly the chosen copy of a duplicated track', () {
      final queue = _base().createGroup(
          groupId: 'G',
          title: 'T',
          entryIds: ['e1', 'e3', 'e5']).removeFromGroup(['e3']);
      expect(queue.groups.single.memberIds, ['e1', 'e5']);
      expect(queue.groupOf('e3'), isNull);
      expect(queue.entries.where((e) => e.track.id == 'a').length, 3);
    });

    test('removing nothing returns the same queue', () {
      final queue = _mixed();
      expect(identical(queue.removeFromGroup(const []), queue), isTrue);
    });

    test('refuses entries that are in no group, or not in the queue', () {
      final loose = _errorOf(() => _mixed().removeFromGroup(['e1']));
      expect(loose.reason, QueueGroupErrorReason.entryNotGrouped);
      expect(loose.ids, ['e1']);

      final stale = _errorOf(() => _mixed().removeFromGroup(['gone']));
      expect(stale.reason, QueueGroupErrorReason.unknownEntry);
    });

    test('a refused request changes nothing', () {
      final queue = _mixed();
      final before = _shape(queue);
      expect(() => queue.removeFromGroup(['e2', 'e1']),
          throwsA(isA<QueueGroupError>()));
      expect(_shape(queue), before);
    });
  });

  group('ungroup', () {
    test('dissolves the group and keeps every entry where it was', () {
      final queue = _mixed().ungroup('G1');
      expect(_shape(queue), ['e1', 'e2', 'e3', 'e4', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_flat(queue), _flat(_mixed()));
      expect(queue.entries.length, 8);
      expect(queue.groups.map((g) => g.id), ['G2']);
    });

    test('ungrouping every group leaves a plain queue', () {
      final queue = _mixed().ungroup('G1').ungroup('G2');
      expect(queue.groups, isEmpty);
      expect(_shape(queue), _flat(_base()));
    });

    test('keeps the tracks, including copies of the same track', () {
      final tracks = [
        for (final e in _mixed().ungroup('G1').entries) e.track.id
      ];
      expect(tracks, [for (final e in _base().entries) e.track.id]);
    });

    test('refuses an unknown (stale) group', () {
      expect(() => _mixed().ungroup('nope'),
          _failsWith(QueueGroupErrorReason.unknownGroup));
    });
  });

  group('rename and collapse', () {
    test('renameGroup changes only the title', () {
      final queue = _mixed().renameGroup('G1', 'Renamed');
      expect(queue.groupById('G1')!.title, 'Renamed');
      expect(_shape(queue), _shape(_mixed()));
    });

    test('setCollapsed toggles one group and leaves the order alone', () {
      final queue = _mixed().setCollapsed('G1', false);
      expect(queue.groupById('G1')!.collapsed, isFalse);
      expect(queue.groupById('G2')!.collapsed, isTrue);
      expect(_flat(queue), _flat(_mixed()));
    });

    test('refuse unknown groups', () {
      expect(() => _mixed().renameGroup('nope', 'x'),
          _failsWith(QueueGroupErrorReason.unknownGroup));
      expect(() => _mixed().setCollapsed('nope', true),
          _failsWith(QueueGroupErrorReason.unknownGroup));
    });
  });

  group('moveItem / moveGroup (whole-group reordering)', () {
    // Rows of _mixed(): 0 e1, 1 G1, 2 e5, 3 G2, 4 e8.

    test('moves a group forward as one unit', () {
      final queue = _mixed().moveItem(1, 4);
      expect(_shape(queue), ['e1', 'e5', 'G2[e6,e7]', 'G1[e2,e3,e4]', 'e8']);
      expect(_flat(queue), ['e1', 'e5', 'e6', 'e7', 'e2', 'e3', 'e4', 'e8']);
      expect(queue.validate(), isEmpty);
    });

    test('moves a group backward and keeps the groups ordered', () {
      final queue = _mixed().moveItem(3, 0);
      expect(_shape(queue), ['G2[e6,e7]', 'e1', 'G1[e2,e3,e4]', 'e5', 'e8']);
      expect(queue.groups.map((g) => g.id), ['G2', 'G1']);
      expect(queue.validate(), isEmpty);
    });

    test('moves a group to the very end', () {
      final queue = _mixed().moveItem(1, 5);
      expect(_shape(queue), ['e1', 'e5', 'G2[e6,e7]', 'e8', 'G1[e2,e3,e4]']);
    });

    test('a loose entry moves between rows, never inside a group', () {
      final queue = _mixed().moveItem(4, 1);
      expect(_shape(queue), ['e1', 'e8', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]']);
      expect(queue.validate(), isEmpty);
    });

    test('moving next to its own place changes nothing', () {
      expect(_shape(_mixed().moveItem(1, 1)), _shape(_mixed()));
      expect(_shape(_mixed().moveItem(1, 2)), _shape(_mixed()));
    });

    test('keeps members and their order inside the moved group', () {
      final queue = _mixed().moveItem(1, 4);
      expect(queue.groupById('G1')!.memberIds, ['e2', 'e3', 'e4']);
    });

    test('moveGroup finds the group by id', () {
      expect(
          _shape(_mixed().moveGroup('G2', 0)), _shape(_mixed().moveItem(3, 0)));
      expect(
          _shape(_mixed().moveGroup('G1', 5)), _shape(_mixed().moveItem(1, 5)));
    });

    test('moveGroup refuses an unknown (stale) group', () {
      expect(() => _mixed().moveGroup('nope', 0),
          _failsWith(QueueGroupErrorReason.unknownGroup));
    });

    test('rejects positions outside the rows', () {
      expect(() => _mixed().moveItem(-1, 0), throwsRangeError);
      expect(() => _mixed().moveItem(5, 0), throwsRangeError);
      expect(() => _mixed().moveItem(0, -1), throwsRangeError);
      expect(() => _mixed().moveItem(0, 6), throwsRangeError);
      expect(() => _mixed().moveGroup('G1', 6), throwsRangeError);
    });

    test('an empty queue has nothing to move', () {
      expect(
          () => GroupedQueue.ungrouped(<QueueEntry<_Track>>[]).moveItem(0, 0),
          throwsRangeError);
    });

    test('a single row is a no-op', () {
      final queue = GroupedQueue.ungrouped(_entries(['a']));
      expect(_flat(queue.moveItem(0, 0)), ['e1']);
      expect(_flat(queue.moveItem(0, 1)), ['e1']);
    });

    test('on a queue without groups it is a plain reorder', () {
      final queue = _base().moveItem(0, 3);
      expect(_flat(queue), ['e2', 'e3', 'e1', 'e4', 'e5', 'e6', 'e7', 'e8']);
    });
  });

  group('moveWithinGroup (constrained reordering)', () {
    // G1 is [e2, e3, e4] inside ['e1', G1, 'e5', G2, 'e8'].

    test('moves a member forward', () {
      final queue = _mixed().moveWithinGroup('G1', 0, 2);
      expect(queue.groupById('G1')!.memberIds, ['e3', 'e2', 'e4']);
    });

    test('moves a member backward', () {
      final queue = _mixed().moveWithinGroup('G1', 2, 0);
      expect(queue.groupById('G1')!.memberIds, ['e4', 'e2', 'e3']);
    });

    test('moves a member to the end position', () {
      final queue = _mixed().moveWithinGroup('G1', 0, 3);
      expect(queue.groupById('G1')!.memberIds, ['e3', 'e4', 'e2']);
      expect(_flat(queue), ['e1', 'e3', 'e4', 'e2', 'e5', 'e6', 'e7', 'e8']);
    });

    test('nothing outside the group moves', () {
      final queue = _mixed().moveWithinGroup('G1', 0, 3);
      expect(_shape(queue), ['e1', 'G1[e3,e4,e2]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(queue.groupById('G2'), _mixed().groupById('G2'));
    });

    test('moving next to its own place changes nothing', () {
      expect(_flat(_mixed().moveWithinGroup('G1', 1, 1)), _flat(_mixed()));
      expect(_flat(_mixed().moveWithinGroup('G1', 1, 2)), _flat(_mixed()));
    });

    test('a group of one member is a no-op', () {
      final queue =
          _base().createGroup(groupId: 'G', title: 'T', entryIds: ['e4']);
      expect(_flat(queue.moveWithinGroup('G', 0, 0)), _flat(queue));
      expect(_flat(queue.moveWithinGroup('G', 0, 1)), _flat(queue));
    });

    test('reorders copies of one track by entry, not by track id', () {
      final queue = _base().createGroup(
          groupId: 'G',
          title: 'T',
          entryIds: ['e1', 'e3', 'e5']).moveWithinGroup('G', 2, 0);
      expect(queue.groups.single.memberIds, ['e5', 'e1', 'e3']);
      expect(queue.membersOf('G').map((e) => e.track.id), ['a', 'a', 'a']);
    });

    test('rejects positions outside the group', () {
      expect(() => _mixed().moveWithinGroup('G1', -1, 0), throwsRangeError);
      expect(() => _mixed().moveWithinGroup('G1', 3, 0), throwsRangeError);
      expect(() => _mixed().moveWithinGroup('G1', 0, -1), throwsRangeError);
      expect(() => _mixed().moveWithinGroup('G1', 0, 4), throwsRangeError);
    });

    test('refuses an unknown (stale) group', () {
      expect(() => _mixed().moveWithinGroup('nope', 0, 1),
          _failsWith(QueueGroupErrorReason.unknownGroup));
    });
  });

  group('removeEntries', () {
    test('removes a loose entry', () {
      expect(_shape(_mixed().removeEntries(['e5'])),
          ['e1', 'G1[e2,e3,e4]', 'G2[e6,e7]', 'e8']);
    });

    test('removes a member and shrinks its group', () {
      final queue = _mixed().removeEntries(['e3']);
      expect(_shape(queue), ['e1', 'G1[e2,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(queue.validate(), isEmpty);
    });

    test('deletes a group whose members are all removed', () {
      final queue = _mixed().removeEntries(['e6', 'e7']);
      expect(_shape(queue), ['e1', 'G1[e2,e3,e4]', 'e5', 'e8']);
      expect(queue.groups.map((g) => g.id), ['G1']);
    });

    test('removes exactly the chosen copy of a duplicated track', () {
      final queue = _mixed().removeEntries(['e3']); // track "a"
      expect(queue.entries.where((e) => e.track.id == 'a').map((e) => e.id),
          ['e1', 'e5']);
    });

    test('ignores ids that are not in the queue', () {
      final queue = _mixed();
      expect(identical(queue.removeEntries(['gone']), queue), isTrue);
      expect(_shape(queue.removeEntries(['gone', 'e8'])),
          ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]']);
    });

    test('removing everything empties the queue and the groups', () {
      final queue = _mixed().removeEntries(_flat(_mixed()));
      expect(queue.entries, isEmpty);
      expect(queue.groups, isEmpty);
    });

    test('an empty queue stays empty', () {
      final queue = GroupedQueue.ungrouped(<QueueEntry<_Track>>[]);
      expect(queue.removeEntries(['e1']).entries, isEmpty);
    });
  });

  group('insertUngrouped', () {
    QueueEntry<_Track> fresh(String id, [String track = 'z']) =>
        QueueEntry(id, _Track(track));

    test('inserts at the start, middle and end of loose entries', () {
      expect(_shape(_mixed().insertUngrouped(0, [fresh('n1')])),
          ['n1', 'e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_shape(_mixed().insertUngrouped(8, [fresh('n1')])),
          ['e1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8', 'n1']);
    });

    test('inserts right before and right after a group without joining it', () {
      expect(_shape(_mixed().insertUngrouped(1, [fresh('n1')])),
          ['e1', 'n1', 'G1[e2,e3,e4]', 'e5', 'G2[e6,e7]', 'e8']);
      expect(_shape(_mixed().insertUngrouped(4, [fresh('n1')])),
          ['e1', 'G1[e2,e3,e4]', 'n1', 'e5', 'G2[e6,e7]', 'e8']);
    });

    test('a position inside a group becomes the position after the group', () {
      for (final index in [2, 3]) {
        final queue =
            _mixed().insertUngrouped(index, [fresh('n1'), fresh('n2')]);
        expect(_shape(queue),
            ['e1', 'G1[e2,e3,e4]', 'n1', 'n2', 'e5', 'G2[e6,e7]', 'e8'],
            reason: 'index $index');
        expect(queue.validate(), isEmpty);
      }
    });

    test('between two groups that touch, the new entry goes between them', () {
      final queue = _base().createGroup(groupId: 'A', title: '', entryIds: [
        'e1',
        'e2'
      ]).createGroup(groupId: 'B', title: '', entryIds: ['e3', 'e4']);
      expect(_shape(queue.insertUngrouped(2, [fresh('n1')])).take(3),
          ['A[e1,e2]', 'n1', 'B[e3,e4]']);
    });

    test('a new copy of an existing track gets its own entry', () {
      final queue = _mixed().insertUngrouped(0, [fresh('n1', 'a')]);
      expect(queue.entries.where((e) => e.track.id == 'a').length, 4);
      expect(queue.groupOf('n1'), isNull);
    });

    test('does not touch the existing groups', () {
      final queue = _mixed().insertUngrouped(2, [fresh('n1')]);
      expect(queue.groups, _mixed().groups);
    });

    test('refuses an id that is already in the queue, or repeated', () {
      final existing =
          _errorOf(() => _mixed().insertUngrouped(0, [fresh('e3')]));
      expect(existing.reason, QueueGroupErrorReason.duplicateEntryId);
      expect(existing.ids, ['e3']);
      expect(() => _mixed().insertUngrouped(0, [fresh('n'), fresh('n')]),
          _failsWith(QueueGroupErrorReason.duplicateEntryId));
    });

    test('rejects a position outside the queue', () {
      expect(
          () => _mixed().insertUngrouped(-1, [fresh('n')]), throwsRangeError);
      expect(() => _mixed().insertUngrouped(9, [fresh('n')]), throwsRangeError);
    });

    test('inserting nothing returns the same queue', () {
      final queue = _mixed();
      expect(identical(queue.insertUngrouped(0, const []), queue), isTrue);
    });

    test('works on an empty queue', () {
      final queue = GroupedQueue.ungrouped(<QueueEntry<_Track>>[])
          .insertUngrouped(0, [fresh('n1')]);
      expect(_flat(queue), ['n1']);
    });
  });

  group('immutability', () {
    test('no operation changes the queue it was called on', () {
      final queue = _mixed();
      final flat = _flat(queue);
      final shape = _shape(queue);
      final groups = [...queue.groups];

      queue
        ..createGroup(groupId: 'G3', title: 'x', entryIds: ['e1', 'e5'])
        ..addToGroup('G1', ['e5'])
        ..removeFromGroup(['e3'])
        ..ungroup('G1')
        ..moveItem(1, 4)
        ..moveWithinGroup('G1', 0, 3)
        ..removeEntries(['e2'])
        ..insertUngrouped(0, [const QueueEntry('n', _Track('n'))])
        ..renameGroup('G1', 'x')
        ..setCollapsed('G1', false);

      expect(_flat(queue), flat);
      expect(_shape(queue), shape);
      expect(queue.groups, groups);
    });
  });

  group('randomized: no entry is ever lost, duplicated or swapped', () {
    test('hundreds of operations keep every invariant', () {
      final random = Random(20240607);
      var queue = GroupedQueue.ungrouped(_entries([
        'a', 'b', 'a', 'c', 'a', 'd', 'b', 'e', 'a', 'f', 'c', 'a', //
      ]));

      // What every entry id must keep pointing at.
      final tracks = {for (final e in queue.entries) e.id: e.track};
      var nextEntry = 100;
      var nextGroup = 0;

      List<String> pick(List<String> from, int count) {
        final pool = [...from]..shuffle(random);
        return pool.take(count).toList();
      }

      for (var step = 0; step < 600; step++) {
        final loose = queue.ungroupedEntries.map((e) => e.id).toList();
        final grouped = queue.groupIdByEntryId.keys.toList();
        final groupIds = queue.groups.map((g) => g.id).toList();
        final rows = queue.items.length;
        final expected = _flat(queue).toSet();
        var removed = <String>{};
        var added = <String>[];

        switch (random.nextInt(10)) {
          case 0 when loose.isNotEmpty:
            queue = queue.createGroup(
              groupId: 'G${nextGroup++}',
              title: 'g',
              entryIds: pick(loose, 1 + random.nextInt(4)),
            );
          case 1 when loose.isNotEmpty && groupIds.isNotEmpty:
            final group =
                queue.groupById(groupIds[random.nextInt(groupIds.length)])!;
            queue = queue.addToGroup(
              group.id,
              pick(loose, 1 + random.nextInt(3)),
              index: random.nextInt(group.length + 1),
            );
          case 2 when grouped.isNotEmpty:
            queue = queue.removeFromGroup(pick(grouped, 1 + random.nextInt(3)));
          case 3 when groupIds.isNotEmpty:
            queue = queue.ungroup(groupIds[random.nextInt(groupIds.length)]);
          case 4 when rows > 0:
            queue =
                queue.moveItem(random.nextInt(rows), random.nextInt(rows + 1));
          case 5 when groupIds.isNotEmpty:
            final group =
                queue.groupById(groupIds[random.nextInt(groupIds.length)])!;
            queue = queue.moveWithinGroup(
              group.id,
              random.nextInt(group.length),
              random.nextInt(group.length + 1),
            );
          case 6 when expected.length > 3:
            removed = pick(expected.toList(), 1 + random.nextInt(2)).toSet();
            queue = queue.removeEntries([...removed, 'never-existed']);
          case 7:
            added = [
              for (var i = 0; i < 1 + random.nextInt(2); i++) 'e${nextEntry++}',
            ];
            for (final id in added) {
              tracks[id] = _Track('a'); // often a copy of an existing track
            }
            queue = queue.insertUngrouped(
              random.nextInt(queue.entries.length + 1),
              [for (final id in added) QueueEntry(id, tracks[id]!)],
            );
          case 8 when groupIds.isNotEmpty:
            queue = queue.setCollapsed(
              groupIds[random.nextInt(groupIds.length)],
              random.nextBool(),
            );
          case 9 when groupIds.isNotEmpty:
            queue = queue.moveGroup(
              groupIds[random.nextInt(groupIds.length)],
              random.nextInt(rows + 1),
            );
          default:
            continue;
        }

        final reason = 'step $step';
        expect(queue.validate(), isEmpty, reason: reason);

        final now = _flat(queue);
        expect(now.toSet().length, now.length,
            reason: '$reason: duplicate entry');
        expect(now.toSet(), expected.difference(removed).union(added.toSet()),
            reason: '$reason: entries lost or invented');
        for (final entry in queue.entries) {
          expect(identical(entry.track, tracks[entry.id]), isTrue,
              reason: '$reason: ${entry.id} changed track');
        }
        // Whatever the groups say, the loose entries are exactly the rest.
        final inGroups = queue.groups.expand((g) => g.memberIds).toList();
        expect(inGroups.toSet().length, inGroups.length,
            reason: '$reason: entry in two groups');
        expect(queue.ungroupedEntries.length + inGroups.length, now.length,
            reason: reason);
      }
    });
  });
}
