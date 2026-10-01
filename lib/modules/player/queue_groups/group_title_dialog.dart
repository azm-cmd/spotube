import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/modules/player/queue_groups/queue_group_strings.dart';

/// Asks for the title of a group. Resolves to the title (never empty: a blank
/// one becomes [QueueGroupStrings.defaultTitle]), or `null` when cancelled.
Future<String?> showGroupTitleDialog(
  BuildContext context, {
  required String heading,
  required String confirmLabel,
  String initialTitle = '',
}) {
  return showDialog<String>(
    context: context,
    alignment: Alignment.center,
    builder: (context) => GroupTitleDialog(
      heading: heading,
      confirmLabel: confirmLabel,
      initialTitle: initialTitle,
    ),
  );
}

class GroupTitleDialog extends HookWidget {
  final String heading;
  final String confirmLabel;
  final String initialTitle;

  const GroupTitleDialog({
    super.key,
    required this.heading,
    required this.confirmLabel,
    this.initialTitle = '',
  });

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: initialTitle);

    void submit() {
      final title = controller.text.trim();
      Navigator.of(context).pop(
        title.isEmpty ? QueueGroupStrings.defaultTitle : title,
      );
    }

    return AlertDialog(
      title: Text(heading),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          key: const Key('queue-group-title-field'),
          controller: controller,
          autofocus: true,
          placeholder: const Text(QueueGroupStrings.groupName),
          onSubmitted: (_) => submit(),
        ),
      ),
      actions: [
        Button.ghost(
          key: const Key('queue-group-title-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(QueueGroupStrings.cancel),
        ),
        Button.primary(
          key: const Key('queue-group-title-confirm'),
          onPressed: submit,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
