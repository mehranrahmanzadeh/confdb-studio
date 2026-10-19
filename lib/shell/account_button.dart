import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/cli_disclosure.dart';
import '../widgets/code_text.dart';
import '../widgets/common.dart';
import '../widgets/copyable_text.dart';
import '../widgets/status_badge.dart';
import '../screens/store/store_login_dialog.dart';

/// Bottom of the rail: the Snap Store (snapcraft) account. Warns when
/// snapcraft isn't logged in, because signing schemas needs a registered key.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final account = app.storeAccount;
        final c = context.colors;
        final s = context.status;
        final warn = account != null && !account.isLoggedIn;
        final (String label, String tooltip) = switch (account?.login) {
          null => ('Account', 'Checking snapcraft login…'),
          StoreLogin.loggedIn => (
            account!.username ?? 'Account',
            'Logged in to snapcraft as ${account.username ?? account.email ?? 'unknown'}',
          ),
          StoreLogin.loggedOut => ('Log in', 'Not logged in to snapcraft: you can’t sign schemas'),
          StoreLogin.unavailable => ('Snapcraft', 'snapcraft isn’t available: you can’t sign schemas'),
        };

        final avatar = Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.surfaceContainerHigh, shape: BoxShape.circle),
              child: Icon(Icons.person_outline, color: account?.isLoggedIn ?? false ? c.onSurface : c.onSurfaceVariant),
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
            menuChildren: [_AccountPanel(account: account, checking: app.checkingStore)],
            builder: (context, controller, _) => Tooltip(
              message: tooltip,
              child: Semantics(
                button: true,
                label: 'Snapcraft account. $tooltip',
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
  const _AccountPanel({required this.account, required this.checking});
  final StoreAccount? account;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = account;
    final check = SecondaryButton(
      label: 'Check again',
      icon: AppIcons.retry,
      busy: checking,
      onPressed: () => context.app.refreshStoreAccount(context.repo),
    );
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);

    final List<Widget> body;
    if (a == null) {
      body = [Text('Checking snapcraft login…', style: muted), const SizedBox(height: 12), const LinearProgressIndicator()];
    } else if (a.isLoggedIn) {
      body = [
        Text('snapcraft · signing keys', style: context.text.titleSmall),
        const SizedBox(height: 12),
        DetailList(
          labelWidth: 96,
          rows: [
            if (a.username != null) ('Username', MonoText(a.username!)),
            if (a.email != null) ('Email', Text(a.email!)),
            if (a.accountId != null) ('Account ID', CopyableText(a.accountId!, what: 'account ID', alias: false)),
          ],
        ),
        const SizedBox(height: 12),
        CodeText(
          'Schemas you sign use this account ID, with a key registered to it (`snap keys`).',
          style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        const CliDisclosure('snapcraft whoami'),
        const SizedBox(height: 8),
        check,
      ];
    } else {
      final unavailable = a.login == StoreLogin.unavailable;
      body = [
        InlineMessage(
          kind: MessageKind.warning,
          padding: const EdgeInsets.all(12),
          title: unavailable ? 'Warning · snapcraft isn’t available' : 'Warning · not logged in to snapcraft',
          body: Text('You can create and test drafts, but signing a schema needs a key registered to your Snap Store developer account.'),
        ),
        if (a.detail != null) ...[
          const SizedBox(height: 8),
          CodeText(a.detail!, style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
        ],
        const SizedBox(height: 16),
        Text(unavailable ? 'Install snapcraft, then log in' : 'Log in from a terminal', style: context.text.titleSmall),
        const SizedBox(height: 8),
        if (unavailable) const CliDisclosure('sudo snap install snapcraft --classic', initiallyOpen: true),
        const CliDisclosure('snapcraft login', initiallyOpen: true),
        const SizedBox(height: 12),
        Text('First time signing? Create and register a key once:', style: muted),
        const SizedBox(height: 4),
        const CliDisclosure('snap create-key <name> && snapcraft register-key <name>'),
        const SizedBox(height: 12),
        check,
      ];
    }

    return Semantics(
      container: true,
      label: 'Snapcraft account',
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [const _StoreSection(), const Divider(height: 32), ...body],
          ),
        ),
      ),
    );
  }
}

/// The app's own Snap Store login (via the vendored Rust backend), for listing and pushing schemas.
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
              Text('Sign in to see the schemas registered to your account and push new revisions.', style: muted),
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
