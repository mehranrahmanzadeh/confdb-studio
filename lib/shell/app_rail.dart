import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import 'account_button.dart';
import 'product_tour.dart';
import 'snapd_status.dart';

/// Rail.dc.html: Overview (with the schemas), Data, Access. Icons only (with
/// tooltips) when compact.
class AppRail extends StatelessWidget {
  const AppRail({super.key, required this.selected, required this.onSelected, required this.compact});

  final Destination selected;
  final ValueChanged<Destination> onSelected;
  final bool compact;

  static const _items = [
    (Destination.overview, 'Schema', AppIcons.schemas, AppIcons.schemasSelected),
    (Destination.data, 'Data', AppIcons.data, AppIcons.dataSelected),
    (Destination.access, 'Access', AppIcons.access, AppIcons.accessSelected),
  ];

  static const _tourCopy = {
    Destination.overview: ('Schemas', 'Every schema you own or can see lives here, local and Snap Store alike.'),
    Destination.data: ('Data', 'Browse and edit the live confdb data behind each view.'),
    Destination.access: ('Access', 'See which snaps plug which views, and manage who can read or write what.'),
  };

  static final _tourKeys = {
    Destination.overview: TourKeys.railSchema,
    Destination.data: TourKeys.railData,
    Destination.access: TourKeys.railAccess,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget icon(Destination d, IconData i, String label) {
      final plain = compact ? Tooltip(message: label, child: Icon(i)) : Icon(i);
      final (title, description) = _tourCopy[d]!;
      return tourShowcase(context, key: _tourKeys[d]!, title: title, description: description, child: plain);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.outlineVariant)),
      ),
      child: _DestinationCursor(
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
            for (final (d, label, i, sel) in _items)
              NavigationRailDestination(icon: icon(d, i, label), selectedIcon: icon(d, sel, label), label: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// NavigationRail's destinations keep Flutter's desktop cursor (the arrow) and
/// take no cursor of their own. This translucent layer over the rail shows the
/// hand instead while the pointer is over one: their ink responses are the only
/// regions in the rail that ask for the plain arrow.
class _DestinationCursor extends StatefulWidget {
  const _DestinationCursor({required this.child});
  final Widget child;

  @override
  State<_DestinationCursor> createState() => _DestinationCursorState();
}

class _DestinationCursorState extends State<_DestinationCursor> {
  MouseCursor _cursor = MouseCursor.defer;

  void _hover(PointerEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, View.of(context).viewId);
    final overDestination = result.path.any(
      (e) => e.target is RenderMouseRegion && (e.target as RenderMouseRegion).cursor == SystemMouseCursors.basic,
    );
    final cursor = overDestination ? SystemMouseCursors.click : MouseCursor.defer;
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned.fill(
        child: MouseRegion(
          hitTestBehavior: HitTestBehavior.translucent,
          cursor: _cursor,
          onHover: _hover,
          onExit: (_) => setState(() => _cursor = MouseCursor.defer),
        ),
      ),
    ],
  );
}
