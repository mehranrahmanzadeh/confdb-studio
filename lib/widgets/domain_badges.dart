import 'package:flutter/material.dart';

import '../data/models.dart';
import '../domain/analysis.dart';
import '../util/format.dart';
import 'app_icons.dart';
import 'status_badge.dart';

/// Status of a snapd change: Done, Error, In progress…
class ChangeBadge extends StatelessWidget {
  const ChangeBadge(this.status, {super.key});
  final ChangeStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    ChangeStatus.done => StatusBadge.success(status.label),
    ChangeStatus.error => StatusBadge.error(status.label),
    ChangeStatus.doing || ChangeStatus.waiting => StatusBadge.running(status.label),
    ChangeStatus.undone || ChangeStatus.hold => StatusBadge.neutral(status.label, icon: AppIcons.undo),
  };
}

/// Connected custodian plugs for a schema's views.
List<ConfdbPlug> custodiansOf(SchemaId id, List<SnapInfo> snaps) => [
  for (final s in snaps)
    for (final p in s.plugs)
      if (p.role == PlugRole.custodian && p.view.schemaId == id && p.state.isConnected) p,
];

/// "Custodian installed" (shield), "No custodian" (warning) or "Built-in".
StatusBadge custodianBadge(ConfdbSchema schema, List<SnapInfo> snaps, {bool short = false}) {
  if (schema.builtIn) return const StatusBadge.neutral('Built-in', icon: AppIcons.lock);
  final custodians = custodiansOf(schema.id, snaps);
  if (custodians.isEmpty) return StatusBadge.warning(short ? 'Missing' : 'No custodian');
  return StatusBadge.success(short ? 'Installed' : 'Custodian installed', icon: AppIcons.shield);
}

/// Lint summary badge: "1 error, 1 warning", "1 warning", "No issues".
StatusBadge lintBadge(List<LintIssue> issues, {String prefix = ''}) {
  final errors = issues.where((i) => i.isError).length;
  final warnings = issues.length - errors;
  final parts = [if (errors > 0) plural(errors, 'error'), if (warnings > 0) plural(warnings, 'warning')];
  if (errors > 0) return StatusBadge.error('$prefix${parts.join(', ')}');
  if (warnings > 0) return StatusBadge.warning('$prefix${parts.join(', ')}');
  return StatusBadge.success('${prefix}No issues');
}
