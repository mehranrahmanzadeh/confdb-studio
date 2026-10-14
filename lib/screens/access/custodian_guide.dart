import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/status_badge.dart';

/// Custodian plugs for [schema] that installed snaps declare but haven't connected.
List<ConfdbPlug> idleCustodianPlugs(ConfdbSchema schema, List<SnapInfo> snaps) => [
  for (final s in snaps)
    for (final p in s.plugs)
      if (p.role == PlugRole.custodian && p.view.schemaId == schema.id && !p.state.isConnected) p,
];

/// The snapcraft.yaml `plugs:` block declaring a custodian plug per view.
/// Plugs are named after their views, which keeps hook names readable.
String custodianPlugsYaml(ConfdbSchema schema) {
  final b = StringBuffer('plugs:\n');
  for (final v in schema.views) {
    b
      ..writeln('  ${v.name}:')
      ..writeln('    interface: confdb')
      ..writeln('    account: ${schema.id.account}')
      ..writeln('    view: ${schema.id.name}/${v.name}')
      ..writeln('    role: custodian');
  }
  return b.toString().trimRight();
}

/// [custodianBadge], except that "No custodian" / "Missing" carries a
/// question mark and opens [showCustodianGuide] when clicked.
class CustodianBadge extends StatelessWidget {
  const CustodianBadge({super.key, required this.schema, required this.snaps, this.short = false});
  final ConfdbSchema schema;
  final List<SnapInfo> snaps;
  final bool short;

  @override
  Widget build(BuildContext context) {
    if (schema.builtIn || custodiansOf(schema.id, snaps).isNotEmpty) return custodianBadge(schema, snaps, short: short);
    const help = 'How to connect a custodian snap';
    final radius = BorderRadius.circular(ConfdbRadii.chip);
    return Tooltip(
      message: help,
      child: Semantics(
        button: true,
        label: '${short ? 'Custodian missing' : 'No custodian'}. $help',
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            borderRadius: radius,
            onTap: () => showCustodianGuide(context, schema: schema, snaps: snaps),
            child: StatusBadge.warning(short ? 'Missing' : 'No custodian', icon: AppIcons.help),
          ),
        ),
      ),
    );
  }
}

/// "How to connect a custodian snap?": opens [showCustodianGuide].
class CustodianHelpLink extends StatelessWidget {
  const CustodianHelpLink({super.key, required this.schema, required this.snaps, this.short = false});
  final ConfdbSchema schema;
  final List<SnapInfo> snaps;

  /// "How to connect?" where space is tight.
  final bool short;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => showCustodianGuide(context, schema: schema, snaps: snaps),
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      visualDensity: VisualDensity.compact,
    ),
    icon: const Icon(AppIcons.help, size: 16),
    label: Text(short ? 'How to connect?' : 'How to connect a custodian snap?'),
  );
}

Future<void> showCustodianGuide(BuildContext context, {required ConfdbSchema schema, required List<SnapInfo> snaps}) => showDialog<void>(
  context: context,
  builder: (context) => _CustodianGuide(schema: schema, snaps: snaps),
);

class _CustodianGuide extends StatefulWidget {
  const _CustodianGuide({required this.schema, required this.snaps});
  final ConfdbSchema schema;
  final List<SnapInfo> snaps;

  @override
  State<_CustodianGuide> createState() => _CustodianGuideState();
}

class _CustodianGuideState extends State<_CustodianGuide> {
  final _busy = <String>{};

  Future<void> _connect(ConfdbPlug plug) async {
    final scope = context.scope;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy.add(plug.id));
    try {
      final change = await scope.repository.connect(plug);
      navigator.pop();
      showToast(
        messenger,
        CodeText('Connected `${plug.id}` · change #${change.id}'),
        actionLabel: 'View',
        onAction: () => scope.app.go(ChangeRoute(change.id)),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy.remove(plug.id));
        showConfirmation(context, Text('Couldn’t connect ${plug.id}: $e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final schema = widget.schema;
    final idle = idleCustodianPlugs(schema, widget.snaps);
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);
    final firstView = schema.views.firstOrNull?.name ?? '<view>';

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

    Widget hook(String name, String what) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: CodeText('`$name-view-$firstView` · $what', style: context.text.bodyMedium),
    );

    return AlertDialog(
      title: CodeText('Connect a custodian snap to `${schema.id.path}`'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'A custodian snap owns a view: snapd runs its hooks to check, apply and load the values written through it. '
                'Without one, values are stored as written, nothing validates them, and ephemeral values can’t be loaded.',
                style: muted,
              ),
              if (schema.revision == null) ...[
                const SizedBox(height: 16),
                const InlineMessage(
                  kind: MessageKind.warning,
                  padding: EdgeInsets.all(12),
                  title: 'Sign and acknowledge the schema first',
                  body: Text('snapd can only connect a plug to views of a schema it has acknowledged.'),
                ),
              ],
              if (idle.isNotEmpty) ...[
                const SizedBox(height: 16),
                InlineMessage(
                  kind: MessageKind.info,
                  padding: const EdgeInsets.all(12),
                  title: idle.length == 1
                      ? 'An installed snap already has a custodian plug'
                      : 'Installed snaps already have custodian plugs',
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        idle.length == 1
                            ? 'It just isn’t connected. Connect it here, or see step 4.'
                            : 'They just aren’t connected. Connect them here, or see step 4.',
                      ),
                      const SizedBox(height: 8),
                      for (final p in idle)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Expanded(child: CodeText('`${p.id}` → `${p.view.path}`', style: context.text.bodyMedium)),
                              SecondaryButton(
                                label: 'Connect',
                                icon: AppIcons.link,
                                busy: _busy.contains(p.id),
                                onPressed: schema.revision == null ? null : () => _connect(p),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              step(1, 'Declare a custodian plug for each view', [
                Text(
                  'In your snap’s snapcraft.yaml. Plug names are yours to choose; naming them after the views keeps hook names readable.',
                  style: muted,
                ),
                const SizedBox(height: 4),
                CliDisclosure(custodianPlugsYaml(schema), label: 'snapcraft.yaml', initiallyOpen: true),
              ]),
              step(2, 'Add the hooks you need', [
                Text('Executable files in snap/hooks/, named after the plug. All are optional.', style: muted),
                const SizedBox(height: 8),
                hook('change', 'checks a pending change; exit non-zero to reject it'),
                hook('save', 'applies committed values, e.g. reconfigures the service'),
                hook('load', 'provides ephemeral values when they’re read'),
                const SizedBox(height: 4),
                Text('Inside a hook, read the view with:', style: muted),
                CliDisclosure('snapctl get --view :$firstView', initiallyOpen: true),
              ]),
              step(3, 'Build and install the snap', [
                const CliDisclosure('snapcraft pack', label: 'Build', initiallyOpen: true),
                const CliDisclosure(
                  'sudo snap install --dangerous ./<your-snap>_<version>_<arch>.snap',
                  label: 'Install',
                  initiallyOpen: true,
                ),
              ]),
              step(4, 'Connect the plugs', [
                Text(
                  'Snaps installed from a file aren’t connected automatically. Store snaps auto-connect only when the store grants it.',
                  style: muted,
                ),
                const SizedBox(height: 4),
                CliDisclosure(
                  [for (final v in schema.views) 'sudo snap connect <your-snap>:${v.name}'].join('\n'),
                  label: 'Connect',
                  initiallyOpen: true,
                ),
              ]),
              step(5, 'Check the connection', [
                Text('This page updates once snapd reports the connection. The Access page shows every plug.', style: muted),
                const CliDisclosure('snap connections <your-snap>', initiallyOpen: true),
              ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            final app = context.app;
            Navigator.of(context).pop();
            app.go(const AccessRoute());
          },
          child: const Text('Open Access'),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
