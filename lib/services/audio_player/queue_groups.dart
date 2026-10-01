/// Pure model and algorithms for queue groups.
///
/// A [GroupedQueue] is the flat queue (the order the player holds) plus a list
/// of [QueueGroup]s that name runs of that queue. Nothing here touches the
/// player, the UI, the database or Riverpod: every operation takes a
/// [GroupedQueue] and returns a new one, so the rules can be tested alone.
///
/// Identity: groups refer to entries by [QueueEntry.id], never by track id, so
/// the same track can be queued twice and only the intended copy is grouped.
///
/// Invariants (see [GroupedQueue.validate]):
///  * entry ids are unique within the queue and group ids within the groups;
///  * a group is never empty and lists each member once;
///  * every member exists in the queue and belongs to no other group;
///  * the members of a group are *contiguous* in the queue and listed in queue
///    order, so a group is a block that can be moved as one unit;
///  * [GroupedQueue.groups] is ordered by where each group starts in the queue.
///
/// Every operation checks these first and keeps them true, so a valid queue can
/// only ever produce a valid queue, and entries are never lost or duplicated.
///
/// The queue as the UI sees it is [GroupedQueue.items]: a list of top-level
/// [QueueItem]s, each either a loose [EntryItem] or a whole [GroupItem].
/// Moving a group is moving one item; reordering inside a group is
/// [GroupedQueue.moveWithinGroup]. All "to" positions use the same convention
/// as [moveEntry]: the entry is placed *before* the one currently at `to`, and
/// `to` may equal the length to move to the end.
///
/// Behaviours worth knowing before wiring this to anything:
///  * [GroupedQueue.createGroup] gathers the selected entries into one block
///    at the position of the first selected entry, in queue order.
///  * [GroupedQueue.removeFromGroup] only moves members that sat *between*
///    remaining members, to just after the group; the ones at the ends stay.
///  * [GroupedQueue.insertUngrouped] never lands inside a group: a position
///    in the middle of a group becomes the position right after the group.
library;

import 'package:spotube/services/audio_player/queue_operations.dart';

/// A named block of queue entries.
///
/// [memberIds] are entry ids in queue order. Treat instances as immutable.
class QueueGroup {
  final String id;
  final String title;
  final List<String> memberIds;

  /// Whether the group is shown as a single header row. Groups start
  /// collapsed.
  final bool collapsed;

  const QueueGroup({
    required this.id,
    required this.title,
    required this.memberIds,
    this.collapsed = true,
  });

  /// Number of songs in the group.
  int get length => memberIds.length;

  QueueGroup copyWith({
    String? title,
    List<String>? memberIds,
    bool? collapsed,
  }) {
    return QueueGroup(
      id: id,
      title: title ?? this.title,
      memberIds: List.unmodifiable(memberIds ?? this.memberIds),
      collapsed: collapsed ?? this.collapsed,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! QueueGroup ||
        other.id != id ||
        other.title != title ||
        other.collapsed != collapsed ||
        other.memberIds.length != memberIds.length) {
      return false;
    }
    for (var i = 0; i < memberIds.length; i++) {
      if (other.memberIds[i] != memberIds[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(id, title, collapsed, Object.hashAll(memberIds));

  @override
  String toString() =>
      'QueueGroup($id, "$title", $memberIds${collapsed ? ', collapsed' : ''})';
}

/// One top-level row of the queue: a loose entry or a whole group.
sealed class QueueItem<T> {
  const QueueItem();
}

/// An entry that is not in any group.
final class EntryItem<T> extends QueueItem<T> {
  final QueueEntry<T> entry;

  const EntryItem(this.entry);
}

/// A group together with its member entries, in queue order.
final class GroupItem<T> extends QueueItem<T> {
  final QueueGroup group;
  final List<QueueEntry<T>> entries;

  const GroupItem(this.group, this.entries);
}

/// Why [GroupedQueue.validate] rejected a queue.
enum QueueGroupViolationKind {
  /// Two queue entries share an id.
  duplicateEntryId,

  /// Two groups share an id.
  duplicateGroupId,

  /// A group has no members.
  emptyGroup,

  /// A group lists the same entry twice.
  duplicateMember,

  /// A group lists an entry that is not in the queue.
  unknownMember,

  /// An entry is a member of more than one group.
  entryInMultipleGroups,

  /// The members of a group are not one unbroken block of the queue.
  notContiguous,

  /// The members form a block but are listed in a different order than the
  /// queue holds them.
  membersOutOfOrder,

  /// The groups are not ordered by where they start in the queue.
  groupsOutOfOrder,
}

/// One broken invariant, with whatever it concerns.
class QueueGroupViolation {
  final QueueGroupViolationKind kind;
  final String? groupId;
  final String? entryId;

  const QueueGroupViolation(this.kind, {this.groupId, this.entryId});

  @override
  bool operator ==(Object other) =>
      other is QueueGroupViolation &&
      other.kind == kind &&
      other.groupId == groupId &&
      other.entryId == entryId;

  @override
  int get hashCode => Object.hash(kind, groupId, entryId);

  @override
  String toString() {
    final details = [
      if (groupId != null) 'group $groupId',
      if (entryId != null) 'entry $entryId',
    ].join(', ');
    return details.isEmpty ? kind.name : '${kind.name} ($details)';
  }
}

/// Why an operation on a [GroupedQueue] was refused.
enum QueueGroupErrorReason {
  /// The queue the operation started from breaks an invariant.
  invalidQueue,

  /// An entry id is not in the queue (often a stale id).
  unknownEntry,

  /// A group id does not exist (often a stale id).
  unknownGroup,

  /// The entry already belongs to a group; an entry can only be in one.
  entryAlreadyGrouped,

  /// The entry is not in any group.
  entryNotGrouped,

  /// The group id is already taken.
  duplicateGroupId,

  /// The entry id is already in the queue.
  duplicateEntryId,

  /// No entries were given where at least one is needed.
  noEntries,
}

/// Thrown when a request cannot be honoured without breaking an invariant.
///
/// The queue is never partly changed: operations either return a new, valid
/// queue or throw this.
class QueueGroupError implements Exception {
  final QueueGroupErrorReason reason;
  final String message;

  /// The entry or group ids the problem is about.
  final List<String> ids;

  /// The broken invariants, for [QueueGroupErrorReason.invalidQueue].
  final List<QueueGroupViolation> violations;

  const QueueGroupError(
    this.reason,
    this.message, {
    this.ids = const [],
    this.violations = const [],
  });

  @override
  String toString() => 'QueueGroupError(${reason.name}): $message';
}

/// The flat queue plus the groups that name runs of it.
///
/// The constructor does not check anything, so invalid values can be built and
/// inspected with [validate]; use [GroupedQueue.checked] to refuse them.
/// [entries] is the playback order. Operations never mutate it.
class GroupedQueue<T> {
  final List<QueueEntry<T>> entries;
  final List<QueueGroup> groups;

  const GroupedQueue(this.entries, [this.groups = const []]);

  /// A queue without groups.
  factory GroupedQueue.ungrouped(List<QueueEntry<T>> entries) =>
      GroupedQueue(List.unmodifiable(entries));

  /// Like the constructor, but throws a [QueueGroupError] when an invariant
  /// does not hold.
  factory GroupedQueue.checked(
    List<QueueEntry<T>> entries,
    List<QueueGroup> groups,
  ) {
    final queue = GroupedQueue(entries, groups);
    queue._requireValid();
    return queue;
  }

  // --- Lookups ---------------------------------------------------------------

  /// For every grouped entry, the id of its group. Loose entries are absent.
  ///
  /// If an entry is (invalidly) in several groups, the first group wins.
  Map<String, String> get groupIdByEntryId {
    final result = <String, String>{};
    for (final group in groups) {
      for (final memberId in group.memberIds) {
        result.putIfAbsent(memberId, () => group.id);
      }
    }
    return result;
  }

  QueueGroup? groupById(String groupId) {
    for (final group in groups) {
      if (group.id == groupId) return group;
    }
    return null;
  }

  /// The group the entry belongs to, or `null` for a loose or unknown entry.
  QueueGroup? groupOf(String entryId) {
    final groupId = groupIdByEntryId[entryId];
    return groupId == null ? null : groupById(groupId);
  }

  /// The entries of a group, in queue order.
  List<QueueEntry<T>> membersOf(String groupId) {
    final group = _requireGroup(groupId);
    final byId = {for (final entry in entries) entry.id: entry};
    return [
      for (final id in group.memberIds)
        if (byId[id] case final entry?) entry,
    ];
  }

  /// The entries that are in no group, in queue order.
  List<QueueEntry<T>> get ungroupedEntries {
    final grouped = groupIdByEntryId;
    return [
      for (final entry in entries)
        if (!grouped.containsKey(entry.id)) entry,
    ];
  }

  /// The queue as top-level rows: loose entries and whole groups, in order.
  ///
  /// Throws a [QueueGroupError] when the queue is not valid.
  List<QueueItem<T>> get items {
    _requireValid();
    return _items();
  }

  // --- Validation --------------------------------------------------------------

  /// Every broken invariant, in a stable order. Empty means valid.
  List<QueueGroupViolation> validate() {
    final violations = <QueueGroupViolation>[];

    final positionOf = <String, int>{};
    final repeatedEntries = <String>{};
    for (var i = 0; i < entries.length; i++) {
      final id = entries[i].id;
      if (positionOf.containsKey(id)) {
        if (repeatedEntries.add(id)) {
          violations.add(QueueGroupViolation(
            QueueGroupViolationKind.duplicateEntryId,
            entryId: id,
          ));
        }
      } else {
        positionOf[id] = i;
      }
    }

    final seenGroups = <String>{};
    final repeatedGroups = <String>{};
    final firstGroupOfEntry = <String, String>{};
    final reportedMultiple = <String>{};
    final startOfGroup = <String, int>{};

    for (final group in groups) {
      if (!seenGroups.add(group.id) && repeatedGroups.add(group.id)) {
        violations.add(QueueGroupViolation(
          QueueGroupViolationKind.duplicateGroupId,
          groupId: group.id,
        ));
      }

      if (group.memberIds.isEmpty) {
        violations.add(QueueGroupViolation(
          QueueGroupViolationKind.emptyGroup,
          groupId: group.id,
        ));
        continue;
      }

      var sound = true;
      final inThisGroup = <String>{};
      for (final memberId in group.memberIds) {
        if (!inThisGroup.add(memberId)) {
          violations.add(QueueGroupViolation(
            QueueGroupViolationKind.duplicateMember,
            groupId: group.id,
            entryId: memberId,
          ));
          sound = false;
          continue;
        }
        if (!positionOf.containsKey(memberId)) {
          violations.add(QueueGroupViolation(
            QueueGroupViolationKind.unknownMember,
            groupId: group.id,
            entryId: memberId,
          ));
          sound = false;
        }
        final owner = firstGroupOfEntry.putIfAbsent(memberId, () => group.id);
        if (owner != group.id &&
            reportedMultiple.add('$memberId|${group.id}')) {
          violations.add(QueueGroupViolation(
            QueueGroupViolationKind.entryInMultipleGroups,
            groupId: group.id,
            entryId: memberId,
          ));
          sound = false;
        }
      }

      if (!sound) continue;

      final positions = [for (final id in group.memberIds) positionOf[id]!];
      if (!isContiguous(positions)) {
        violations.add(QueueGroupViolation(
          QueueGroupViolationKind.notContiguous,
          groupId: group.id,
        ));
        continue;
      }
      var inOrder = true;
      for (var i = 1; i < positions.length; i++) {
        if (positions[i] < positions[i - 1]) inOrder = false;
      }
      if (!inOrder) {
        violations.add(QueueGroupViolation(
          QueueGroupViolationKind.membersOutOfOrder,
          groupId: group.id,
        ));
        continue;
      }
      startOfGroup.putIfAbsent(group.id, () => positions.first);
    }

    var previousStart = -1;
    for (final group in groups) {
      final start = startOfGroup[group.id];
      if (start == null) continue;
      if (start < previousStart) {
        violations.add(QueueGroupViolation(
          QueueGroupViolationKind.groupsOutOfOrder,
          groupId: group.id,
        ));
      }
      previousStart = start;
    }

    return violations;
  }

  bool get isValid => validate().isEmpty;

  // --- Creating, changing and dissolving groups --------------------------------

  /// Groups the loose entries [entryIds] into a new group [groupId].
  ///
  /// The members are gathered, in queue order, into one block placed where the
  /// first selected entry was; the order of [entryIds] does not matter and
  /// repeated ids count once. New groups start [collapsed].
  ///
  /// Throws [QueueGroupError] if [entryIds] is empty, contains an unknown
  /// entry or one that is already grouped, or if [groupId] is taken.
  GroupedQueue<T> createGroup({
    required String groupId,
    required String title,
    required Iterable<String> entryIds,
    bool collapsed = true,
  }) {
    _requireValid();
    if (groupById(groupId) != null) {
      throw QueueGroupError(
        QueueGroupErrorReason.duplicateGroupId,
        'A group with id "$groupId" already exists',
        ids: [groupId],
      );
    }
    final selected = entryIds.toSet();
    if (selected.isEmpty) {
      throw const QueueGroupError(
        QueueGroupErrorReason.noEntries,
        'A group needs at least one entry',
      );
    }
    _requireLooseEntries(selected);

    final members = [
      for (final entry in entries)
        if (selected.contains(entry.id)) entry,
    ];
    final group = QueueGroup(
      id: groupId,
      title: title,
      memberIds: List.unmodifiable([for (final entry in members) entry.id]),
      collapsed: collapsed,
    );

    var placed = false;
    final result = <QueueItem<T>>[];
    for (final item in _items()) {
      if (item is EntryItem<T> && selected.contains(item.entry.id)) {
        if (!placed) {
          placed = true;
          result.add(GroupItem(group, members));
        }
        continue;
      }
      result.add(item);
    }
    return _fromItems(result);
  }

  /// Adds the loose entries [entryIds] to the group [groupId], moving them
  /// next to it.
  ///
  /// [index] is the position among the group's members where the first added
  /// entry goes (default: the end). The added entries keep their queue order.
  /// Adding nothing returns the queue unchanged.
  ///
  /// Throws [QueueGroupError] for an unknown group, an unknown entry, or an
  /// entry that is already in a group (this one or another). Throws a
  /// [RangeError] for an [index] outside `0..group.length`.
  GroupedQueue<T> addToGroup(
    String groupId,
    Iterable<String> entryIds, {
    int? index,
  }) {
    _requireValid();
    final group = _requireGroup(groupId);
    final at = index ?? group.length;
    RangeError.checkValueInInterval(at, 0, group.length, 'index');

    final added = entryIds.toSet();
    if (added.isEmpty) return this;
    _requireLooseEntries(added);

    final addedEntries = [
      for (final entry in entries)
        if (added.contains(entry.id)) entry,
    ];

    final result = <QueueItem<T>>[];
    for (final item in _items()) {
      if (item is EntryItem<T> && added.contains(item.entry.id)) continue;
      if (item is GroupItem<T> && item.group.id == groupId) {
        final members = [
          ...item.entries.take(at),
          ...addedEntries,
          ...item.entries.skip(at),
        ];
        result.add(GroupItem(
          item.group.copyWith(memberIds: [for (final e in members) e.id]),
          members,
        ));
        continue;
      }
      result.add(item);
    }
    return _fromItems(result);
  }

  /// Takes [entryIds] out of their groups. The entries stay in the queue.
  ///
  /// Members at the start or end of a group stay where they are, so they end
  /// up just before or after it. Members that sat between remaining members
  /// move to just after the group, in queue order. A group that loses all its
  /// members is deleted and its entries stay exactly where they were.
  ///
  /// Throws [QueueGroupError] for an unknown entry or one that is in no group.
  GroupedQueue<T> removeFromGroup(Iterable<String> entryIds) {
    _requireValid();
    final removed = entryIds.toSet();
    if (removed.isEmpty) return this;

    final known = {for (final entry in entries) entry.id};
    final unknown = removed.where((id) => !known.contains(id)).toList();
    if (unknown.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.unknownEntry,
        'Not in the queue: ${unknown.join(', ')}',
        ids: unknown,
      );
    }
    final grouped = groupIdByEntryId;
    final loose = removed.where((id) => !grouped.containsKey(id)).toList();
    if (loose.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.entryNotGrouped,
        'Not in any group: ${loose.join(', ')}',
        ids: loose,
      );
    }

    final result = <QueueItem<T>>[];
    for (final item in _items()) {
      if (item is! GroupItem<T> ||
          !item.entries.any((e) => removed.contains(e.id))) {
        result.add(item);
        continue;
      }

      final remaining = [
        for (final e in item.entries)
          if (!removed.contains(e.id)) e,
      ];
      if (remaining.isEmpty) {
        result.addAll(item.entries.map(EntryItem.new));
        continue;
      }

      final first = item.entries.indexOf(remaining.first);
      final last = item.entries.indexOf(remaining.last);
      result
        ..addAll(item.entries.take(first).map(EntryItem.new))
        ..add(GroupItem(
          item.group.copyWith(memberIds: [for (final e in remaining) e.id]),
          remaining,
        ))
        ..addAll(
          item.entries
              .skip(first)
              .take(last - first + 1)
              .where((e) => removed.contains(e.id))
              .map(EntryItem.new),
        )
        ..addAll(item.entries.skip(last + 1).map(EntryItem.new));
    }
    return _fromItems(result);
  }

  /// Dissolves the group [groupId]. Its entries stay in the queue, in place.
  ///
  /// Throws [QueueGroupError] for an unknown group.
  GroupedQueue<T> ungroup(String groupId) {
    _requireValid();
    _requireGroup(groupId);

    final result = <QueueItem<T>>[];
    for (final item in _items()) {
      if (item is GroupItem<T> && item.group.id == groupId) {
        result.addAll(item.entries.map(EntryItem.new));
      } else {
        result.add(item);
      }
    }
    return _fromItems(result);
  }

  GroupedQueue<T> renameGroup(String groupId, String title) {
    _requireValid();
    _requireGroup(groupId);
    return GroupedQueue(entries, [
      for (final group in groups)
        group.id == groupId ? group.copyWith(title: title) : group,
    ]);
  }

  GroupedQueue<T> setCollapsed(String groupId, bool collapsed) {
    _requireValid();
    _requireGroup(groupId);
    return GroupedQueue(entries, [
      for (final group in groups)
        group.id == groupId ? group.copyWith(collapsed: collapsed) : group,
    ]);
  }

  // --- Reordering ---------------------------------------------------------------

  /// Moves one top-level [items] row (a loose entry or a whole group) so that
  /// it sits before the row currently at [to]. [to] may equal `items.length`.
  ///
  /// Throws a [RangeError] for an invalid position.
  GroupedQueue<T> moveItem(int from, int to) {
    _requireValid();
    return _fromItems(moveEntry(_items(), from, to));
  }

  /// Moves the whole group [groupId] before the top-level row at [to].
  ///
  /// Throws [QueueGroupError] for an unknown group and a [RangeError] for an
  /// invalid [to].
  GroupedQueue<T> moveGroup(String groupId, int to) {
    _requireValid();
    _requireGroup(groupId);
    final rows = _items();
    final from = rows.indexWhere(
      (item) => item is GroupItem<T> && item.group.id == groupId,
    );
    return _fromItems(moveEntry(rows, from, to));
  }

  /// Reorders inside a group: moves the member at [from] before the member
  /// currently at [to]. [to] may equal the group's length. Nothing outside the
  /// group changes.
  ///
  /// Throws [QueueGroupError] for an unknown group and a [RangeError] for an
  /// invalid position.
  GroupedQueue<T> moveWithinGroup(String groupId, int from, int to) {
    _requireValid();
    final group = _requireGroup(groupId);
    final order = moveEntry(group.memberIds, from, to);
    final byId = {for (final entry in entries) entry.id: entry};

    return _fromItems([
      for (final item in _items())
        if (item is GroupItem<T> && item.group.id == groupId)
          GroupItem(group.copyWith(memberIds: order), [
            for (final id in order) byId[id]!,
          ])
        else
          item,
    ]);
  }

  // --- Changing the queue itself --------------------------------------------------

  /// Removes entries from the queue, and from any group they were in. A group
  /// that loses all its members is deleted. Unknown ids are ignored.
  GroupedQueue<T> removeEntries(Iterable<String> entryIds) {
    _requireValid();
    final removed = entryIds.toSet();
    if (!entries.any((entry) => removed.contains(entry.id))) return this;

    final result = <QueueItem<T>>[];
    for (final item in _items()) {
      switch (item) {
        case EntryItem<T>():
          if (!removed.contains(item.entry.id)) result.add(item);
        case GroupItem<T>():
          final kept = [
            for (final e in item.entries)
              if (!removed.contains(e.id)) e,
          ];
          result.add(GroupItem(
            item.group.copyWith(memberIds: [for (final e in kept) e.id]),
            kept,
          ));
      }
    }
    return _fromItems(result);
  }

  /// Inserts new, ungrouped [newEntries] at queue position [index].
  ///
  /// An [index] that falls in the middle of a group would put a loose entry
  /// inside it, so it becomes the position right after the group instead.
  ///
  /// Throws [QueueGroupError] if an id is already in the queue (or repeated),
  /// and a [RangeError] for an [index] outside `0..entries.length`.
  GroupedQueue<T> insertUngrouped(
      int index, Iterable<QueueEntry<T>> newEntries) {
    _requireValid();
    RangeError.checkValueInInterval(index, 0, entries.length, 'index');
    final added = newEntries.toList();
    if (added.isEmpty) return this;

    final known = {for (final entry in entries) entry.id};
    final taken = <String>{};
    final repeated = <String>[];
    for (final entry in added) {
      if (known.contains(entry.id) || !taken.add(entry.id)) {
        repeated.add(entry.id);
      }
    }
    if (repeated.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.duplicateEntryId,
        'Already in the queue: ${repeated.join(', ')}',
        ids: repeated,
      );
    }

    return GroupedQueue(
      List.unmodifiable(insertEntries(entries, _outsideGroups(index), added)),
      groups,
    );
  }

  // --- Internals ------------------------------------------------------------------

  /// [index] moved to the end of the group it is inside of, if any.
  int _outsideGroups(int index) {
    if (index <= 0 || index >= entries.length) return index;
    final groupIds = groupIdByEntryId;
    final before = groupIds[entries[index - 1].id];
    if (before == null || before != groupIds[entries[index].id]) return index;

    var end = index;
    while (end < entries.length && groupIds[entries[end].id] == before) {
      end++;
    }
    return end;
  }

  QueueGroup _requireGroup(String groupId) {
    final group = groupById(groupId);
    if (group == null) {
      throw QueueGroupError(
        QueueGroupErrorReason.unknownGroup,
        'No group with id "$groupId"',
        ids: [groupId],
      );
    }
    return group;
  }

  /// Every id must be in the queue and in no group.
  void _requireLooseEntries(Set<String> entryIds) {
    final known = {for (final entry in entries) entry.id};
    final unknown = entryIds.where((id) => !known.contains(id)).toList();
    if (unknown.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.unknownEntry,
        'Not in the queue: ${unknown.join(', ')}',
        ids: unknown,
      );
    }
    final grouped = groupIdByEntryId;
    final taken = entryIds.where(grouped.containsKey).toList();
    if (taken.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.entryAlreadyGrouped,
        'Already in a group: ${taken.join(', ')}',
        ids: taken,
      );
    }
  }

  void _requireValid() {
    final violations = validate();
    if (violations.isNotEmpty) {
      throw QueueGroupError(
        QueueGroupErrorReason.invalidQueue,
        'The queue breaks its group invariants: ${violations.join('; ')}',
        violations: violations,
      );
    }
  }

  /// [items] for a queue already known to be valid.
  List<QueueItem<T>> _items() {
    final groupIds = groupIdByEntryId;
    final groupsById = {for (final group in groups) group.id: group};
    final entriesById = {for (final entry in entries) entry.id: entry};
    final placed = <String>{};

    final result = <QueueItem<T>>[];
    for (final entry in entries) {
      final groupId = groupIds[entry.id];
      if (groupId == null) {
        result.add(EntryItem(entry));
      } else if (placed.add(groupId)) {
        final group = groupsById[groupId]!;
        result.add(GroupItem(group, [
          for (final id in group.memberIds) entriesById[id]!,
        ]));
      }
    }
    return result;
  }

  /// The queue described by [items]. A group left without entries is dropped,
  /// which is what keeps empty groups from ever surviving an operation.
  static GroupedQueue<T> _fromItems<T>(List<QueueItem<T>> items) {
    final entries = <QueueEntry<T>>[];
    final groups = <QueueGroup>[];
    for (final item in items) {
      switch (item) {
        case EntryItem<T>():
          entries.add(item.entry);
        case GroupItem<T>():
          if (item.entries.isEmpty) continue;
          groups.add(item.group.copyWith(
            memberIds: [for (final e in item.entries) e.id],
          ));
          entries.addAll(item.entries);
      }
    }
    return GroupedQueue(List.unmodifiable(entries), List.unmodifiable(groups));
  }
}
