import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import 'account_button.dart';
import 'snapd_status.dart';

/// Rail.dc.html: Overview, Schemas, Data, Access, Activity. Icons only (with
/// tooltips) when compact.
class AppRail extends StatelessWidget {
  const AppRail({super.key, required this.selected, required this.onSelected, required this.compact});

  final Destination selected;
  final ValueChanged<Destination> onSelected;
  final bool compact;

  static const _items = [
    (Destination.overview, 'Overview', AppIcons.overview, AppIcons.overviewSelected),
    (Destination.schemas, 'Schemas', AppIcons.schemas, AppIcons.schemasSelected),
    (Destination.data, 'Data', AppIcons.data, AppIcons.dataSelected),
    (Destination.access, 'Access', AppIcons.access, AppIcons.accessSelected),
    (Destination.activity, 'Activity', AppIcons.activity, AppIcons.activity),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget icon(IconData i, String label) => compact ? Tooltip(message: label, child: Icon(i)) : Icon(i);
    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.outlineVariant)),
      ),
      child: NavigationRail(
        minWidth: compact ? 72 : 88,
        groupAlignment: -1,
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AccountButton(compact: compact),
            SnapdStatus(compact: compact),
          ],
        ),
        trailingAtBottom: true,
        labelType: compact ? NavigationRailLabelType.none : NavigationRailLabelType.all,
        selectedIndex: _items.indexWhere((i) => i.$1 == selected),
        onDestinationSelected: (i) => onSelected(_items[i].$1),
        selectedLabelTextStyle: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: c.onSurface, letterSpacing: 0.5),
        unselectedLabelTextStyle: context.text.labelMedium?.copyWith(color: c.onSurfaceVariant, letterSpacing: 0.5),
        destinations: [
          for (final (_, label, i, sel) in _items)
            NavigationRailDestination(icon: icon(i, label), selectedIcon: icon(sel, label), label: Text(label)),
        ],
      ),
    );
  }
}
