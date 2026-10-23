import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';

/// A small icon button that opens [showNamingConventionsDialog]; shown next
/// to schema names in schema creation and the schema editor.
class NamingConventionsButton extends StatelessWidget {
  const NamingConventionsButton({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Naming conventions',
    child: IconButton(
      icon: const Icon(AppIcons.info, size: 20),
      visualDensity: VisualDensity.compact,
      onPressed: () => showNamingConventionsDialog(context),
    ),
  );
}

Future<void> showNamingConventionsDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (context) => const _NamingConventionsDialog());

class _NamingConventionsDialog extends StatelessWidget {
  const _NamingConventionsDialog();

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final heading = context.text.titleSmall?.copyWith(fontWeight: FontWeight.w600);

    Widget section(String title, String text, {Widget? code}) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: heading),
          const SizedBox(height: 6),
          CodeText(text, style: muted),
          if (code != null) ...[const SizedBox(height: 8), code],
        ],
      ),
    );

    Widget code(String text) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.colors.surfaceContainerLow, borderRadius: BorderRadius.circular(8)),
      child: SelectableText(text, style: context.text.bodySmall?.mono),
    );

    return AlertDialog(
      title: const Text('Naming conventions'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Confdb doesn’t enforce names, but these conventions keep schemas consistent and predictable to review.',
                  style: muted,
                ),
              ),
              section(
                'Schemas',
                'Prioritise simplicity and brevity for the schema name. Omit words that are already implicit, such as '
                    '“configuration”, “settings” or “status”.',
              ),
              section(
                'Views',
                'A view’s name should answer “What access or control do I get if I have this view?”. Use the pattern '
                    '<noun>-<designation>, where the noun is what’s being administered or read, and the designation is one of '
                    'just two, to avoid inconsistency:\n'
                    '  •  X-admin — administer X on the device, e.g. network-admin\n'
                    '  •  X-state — read-only state of X on the device, e.g. hardware-state\n\n'
                    'Name views for exactly what they grant: a vague name risks silently widening access later, when the '
                    'schema grows to cover something the view’s old name didn’t anticipate. When the schema name already '
                    'narrows the context enough that a noun would be redundant (e.g. a validation-sets schema with nothing '
                    'else to expose), a bare admin or state is fine. As with schema names, omit implicit words like '
                    '“configuration”, “settings” or “status” from the noun.',
              ),
              section(
                'Interfaces',
                'Name a view’s plug <schema>-<view-name>, prefixed with <account>- (or another short identifying string) '
                    'only when there’d otherwise be a lack of clarity:',
                code: code(
                  'plugs:\n'
                  '  validation-sets-state:\n'
                  '    interface: confdb\n'
                  '    account: system\n'
                  '    view: validation-sets/state\n'
                  '    role: custodian',
                ),
              ),
              section(
                'Request paths',
                'Request paths can match or diverge from storage, and split into a parent/child hierarchy with dots (e.g. '
                    '`device.metadata.id`). Any key that stands for a group of objects should be a pluralized noun, such as '
                    'the parent `interfaces` in `interfaces.{name}`, or the child `peers` in `tunnel.peers`.',
              ),
              section(
                'Storage paths',
                'Start storage paths with a non-placeholder version prefix, such as `v1`, so the storage layout can evolve '
                    'later while existing views keep working against the old data:',
                code: code(
                  'views:\n'
                  '  state:\n'
                  '    summary: Read the validation sets state\n'
                  '    rules:\n'
                  '      -\n'
                  '        request: {account}.{validation-set}\n'
                  '        storage: v1.{account}.{validation-set}',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
