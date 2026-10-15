import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';

/// The snapcraft.yaml `plugs:` block declaring a plug for [view]. The plug is
/// named after the view, which keeps `snapctl --view :<plug>` readable.
String viewPlugYaml(ViewRef view, {bool custodian = false}) => [
  'plugs:',
  '  ${view.view}:',
  '    interface: confdb',
  '    account: ${view.account}',
  '    view: ${view.schema}/${view.view}',
  if (custodian) '    role: custodian',
].join('\n');

/// "How to add a plug": guides giving [snap] a confdb plug for [view].
Future<void> showAddPlugGuide(BuildContext context, {required String snap, required ViewRef view}) => showDialog<void>(
  context: context,
  builder: (context) => _AddPlugGuide(snap: snap, view: view),
);

class _AddPlugGuide extends StatefulWidget {
  const _AddPlugGuide({required this.snap, required this.view});
  final String snap;
  final ViewRef view;

  @override
  State<_AddPlugGuide> createState() => _AddPlugGuideState();
}

class _AddPlugGuideState extends State<_AddPlugGuide> {
  bool _custodian = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);
    final plug = widget.view.view;

    Widget step(int n, String title, List<Widget> body) => Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: c.secondaryContainer,
            foregroundColor: c.onSecondaryContainer,
            child: Text('$n', style: context.text.labelMedium?.copyWith(color: c.onSecondaryContainer)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Text(title, style: context.text.titleSmall),
                ),
                ...body,
              ],
            ),
          ),
        ],
      ),
    );

    return AlertDialog(
      title: CodeText('Add a plug for `${widget.view.path}` to `${widget.snap}`'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              CodeText(
                'A snap reaches a view only through a confdb plug that names it. `${widget.snap}` doesn’t declare one for this view, '
                'so snapd rejects its `snapctl` requests before checking any rules.',
                style: muted,
              ),
              step(1, 'Choose the plug’s role', [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Observer')),
                    ButtonSegment(value: true, label: Text('Custodian')),
                  ],
                  selected: {_custodian},
                  onSelectionChanged: (s) => setState(() => _custodian = s.first),
                ),
                const SizedBox(height: 6),
                Text(
                  _custodian
                      ? 'The snap owns the view: snapd runs its change, save and load hooks for values written or read through it.'
                      : 'The snap reads and writes through the view; its observe-view hook, if any, runs when others change it.',
                  style: muted,
                ),
              ]),
              step(2, 'Declare the plug in snapcraft.yaml', [
                CodeText('The plug name is yours to choose; this one is named after the view.', style: muted),
                const SizedBox(height: 4),
                CliDisclosure(viewPlugYaml(widget.view, custodian: _custodian), label: 'snapcraft.yaml', initiallyOpen: true),
              ]),
              step(3, 'Rebuild and install the snap', [
                const CliDisclosure('snapcraft pack', label: 'Build', initiallyOpen: true),
                const CliDisclosure(
                  'sudo snap install --dangerous ./<your-snap>_<version>_<arch>.snap',
                  label: 'Install',
                  initiallyOpen: true,
                ),
              ]),
              step(4, 'Connect the plug', [
                Text(
                  'Snaps installed from a file aren’t connected automatically. Store snaps auto-connect only when the store grants it.',
                  style: muted,
                ),
                const SizedBox(height: 4),
                CliDisclosure('sudo snap connect ${widget.snap}:$plug', initiallyOpen: true),
                const SizedBox(height: 8),
                const InlineMessage(
                  kind: MessageKind.info,
                  padding: EdgeInsets.all(12),
                  title: 'The view must be acknowledged',
                  body: Text(
                    'snapd connects plugs only to views of an acknowledged schema. If this view is new in the draft, sign and acknowledge it first.',
                  ),
                ),
              ]),
              step(5, 'Use it from the snap', [
                CodeText('Name the plug, not the view, after `--view`:', style: muted),
                const SizedBox(height: 4),
                CliDisclosure('snapctl get --view :$plug', initiallyOpen: true),
              ]),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
