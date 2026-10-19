import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/code_text.dart';
import '../widgets/common.dart';
import '../widgets/copyable_text.dart';
import '../widgets/status_badge.dart';
import '../screens/store/store_login_dialog.dart';

/// Bottom of the rail: the Snap Store account (via the vendored Rust
/// backend). Warns when it isn't signed in, because signing schemas needs a
/// key registered to that account.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final session = store.session;
        final c = context.colors;
        final s = context.status;
        final warn = session != null && !session.signedIn;
        final (String label, String tooltip) = switch (session) {
          null => ('Account', 'Checking Snap Store login…'),
          _ when session.signedIn => (
            session.username ?? 'Account',
            'Signed in to the Snap Store as ${session.username ?? session.email ?? 'unknown'}',
          ),
          _ => ('Sign in', 'Not signed in to the Snap Store: you can’t sign schemas'),
        };

        final avatar = Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.surfaceContainerHigh, shape: BoxShape.circle),
              child: Icon(Icons.person_outline, color: session?.signedIn ?? false ? c.onSurface : c.onSurfaceVariant),
            ),
            if (warn)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: s.warningContainer,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.surface, width: 2),
                  ),
                  child: Icon(Icons.priority_high, size: 11, color: s.warning),
                ),
              ),
          ],
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: MenuAnchor(
            // Opens beside the rail (and shifts up to fit), not over it.
            alignmentOffset: const Offset(12, 0),
            style: MenuStyle(
              alignment: AlignmentDirectional.topEnd,
              side: WidgetStatePropertyAll(BorderSide(color: c.outlineVariant)),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
            menuChildren: const [_AccountPanel()],
            builder: (context, controller, _) => Tooltip(
              message: tooltip,
              child: Semantics(
                button: true,
                label: 'Snap Store account. $tooltip',
                excludeSemantics: true,
                child: InkWell(
                  mouseCursor: WidgetStateMouseCursor.clickable,
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => controller.isOpen ? controller.close() : controller.open(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: SizedBox(
                      width: compact ? 48 : 72,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          avatar,
                          if (!compact) ...[
                            const SizedBox(height: 4),
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: context.text.labelMedium?.copyWith(
                                color: warn ? s.warning : c.onSurfaceVariant,
                                fontWeight: warn ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Snap Store account',
      child: SizedBox(
        width: 380,
        child: Padding(padding: const EdgeInsets.all(16), child: _StoreSection()),
      ),
    );
  }
}

/// The app's own Snap Store login (via the vendored Rust backend), for listing and pushing schemas,
/// and for registering and checking the signing keys schemas are signed with.
class _StoreSection extends StatelessWidget {
  const _StoreSection();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.colors;
        final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
        final session = store.session;
        final title = Row(
          children: [
            Icon(session?.signedIn ?? false ? AppIcons.storeSynced : AppIcons.store, size: 20, color: c.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text('Snap Store', style: context.text.titleSmall)),
            if (session?.env == StoreEnv.staging) const StatusBadge.warning('Staging'),
          ],
        );
        if (session == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 12), const LinearProgressIndicator()],
          );
        }
        if (!session.signedIn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 8),
              Text(
                'Sign in to see the schemas registered to your account, push new revisions, and '
                'register signing keys.',
                style: muted,
              ),
              if (session.detail != null) ...[const SizedBox(height: 8), CodeText(session.detail!, style: muted)],
              const SizedBox(height: 12),
              PrimaryButton(label: 'Sign in', icon: AppIcons.signIn, onPressed: () => showStoreLoginDialog(context)),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title,
            const SizedBox(height: 12),
            DetailList(
              labelWidth: 96,
              rows: [
                if (session.username != null) ('Username', MonoText(session.username!)),
                if (session.email != null) ('Email', Text(session.email!)),
                ('Store', Text(session.env!.host)),
                if (session.accountId != null) ('Account ID', CopyableText(session.accountId!, what: 'account ID', alias: false)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SecondaryButton(label: 'Refresh', icon: AppIcons.retry, busy: store.checking || store.loading, onPressed: store.refresh),
                TertiaryButton(label: 'Sign out', icon: AppIcons.signOut, onPressed: store.logout),
              ],
            ),
          ],
        );
      },
    );
  }
}

