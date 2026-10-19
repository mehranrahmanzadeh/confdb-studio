import 'package:flutter/widgets.dart';

import 'app_icons.dart';
import 'status_badge.dart';

/// A "Registered"/"Not registered" chip for a signing key; blank when it
/// can't be checked (signed out or offline — `null`).
class RegistrationBadge extends StatelessWidget {
  const RegistrationBadge({super.key, required this.registered});
  final bool? registered;

  @override
  Widget build(BuildContext context) => switch (registered) {
    true => const StatusBadge.success('Registered', icon: AppIcons.verified),
    false => const StatusBadge.warning('Not registered'),
    null => const SizedBox.shrink(),
  };
}
