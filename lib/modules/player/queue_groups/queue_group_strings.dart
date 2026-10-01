/// The words of the queue group UI.
///
/// Kept together (and in English) until the app's translation files get these
/// strings.
abstract final class QueueGroupStrings {
  static const defaultTitle = 'New group';

  static const groupTracks = 'Group tracks';
  static const selectTracks = 'Select tracks';
  static const cancel = 'Cancel';
  static const create = 'Create group';
  static const groupName = 'Group name';
  static const rename = 'Rename group';
  static const renameConfirm = 'Rename';
  static const collapse = 'Collapse';
  static const expand = 'Expand';
  static const ungroup = 'Ungroup';
  static const groupMenu = 'Group options';
  static const nowPlaying = 'Playing';

  static String tracks(int count) => count == 1 ? '1 track' : '$count tracks';

  static String groupSelected(int count) => 'Group $count tracks';

  static String selected(int count) => '$count selected';

  static String headerLabel(String title, int count, bool collapsed) =>
      '$title, ${tracks(count)}, ${collapsed ? 'collapsed' : 'expanded'}';
}
