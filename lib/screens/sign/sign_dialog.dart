import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';
import '../../widgets/status_badge.dart';

/// 7.5 Sign & acknowledge (SignDialog.dc.html, -Progress).
Future<void> showSignDialog(BuildContext context, ConfdbSchema draft, ConfdbSchema? base) {
  final scope = context.scope;
  final messenger = ScaffoldMessenger.of(context);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SignDialog(draft: draft, base: base, scope: scope, messenger: messenger),
  );
}

class _SignDialog extends StatefulWidget {
  const _SignDialog({required this.draft, required this.base, required this.scope, required this.messenger});
  final ConfdbSchema draft;
  final ConfdbSchema? base;
  final AppScope scope;
  final ScaffoldMessengerState messenger;

  @override
  State<_SignDialog> createState() => _SignDialogState();
}

class _SignDialogState extends State<_SignDialog> {
  late Future<(List<SigningKey>, List<SnapInfo>)> _context = _load();

  Future<(List<SigningKey>, List<SnapInfo>)> _load() async {
    final repo = widget.scope.repository;
    final r = await Future.wait([repo.signingKeys(), repo.listSnaps()]);
    return (r[0] as List<SigningKey>, r[1] as List<SnapInfo>);
  }

  /// Re-reads `snap keys` after the user created or registered a key.
  void _refreshKeys() {
    setState(() {
      _key = null;
      _context = _load();
    });
    widget.scope.app.refreshStoreAccount(widget.scope.repository);
  }

  SigningKey? _key;
  SignPhase? _phase;
  Object? _error;

  int get _revision => (widget.base?.revision ?? 0) + 1;
  bool get _busy => _phase != null;

  Future<void> _sign() async {
    final key = _key;
    if (key == null) return;
    final app = widget.scope.app;
    setState(() {
      _error = null;
      _phase = SignPhase.signing;
    });
    try {
      final change = await widget.scope.repository.signAndAcknowledge(
        widget.draft,
        key,
        onPhase: (p) {
          if (mounted) setState(() => _phase = p);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      app.go(const OverviewRoute());
      showToast(
        widget.messenger,
        CodeText('`${widget.draft.id.path}` revision $_revision signed and acknowledged'),
        actionLabel: 'View',
        onAction: () => app.go(change == null ? const SchemasRoute() : ChangeRoute(change.id)),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = null;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final draft = widget.draft;
    final diff = diffSchemas(widget.base, draft);
    final added = diff.where((d) => d.added).length;
    final removed = diff.length - added;
    final file = draft.id.name;

    return Dialog(
      backgroundColor: c.surfaceContainerHigh,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: FutureBuilder(
          future: _context,
          builder: (context, snap) {
            final keys = snap.data?.$1 ?? const <SigningKey>[];
            final snaps = snap.data?.$2 ?? const <SnapInfo>[];
            _key ??= keys.firstOrNull;
            final users = {
              for (final s in snaps)
                if (s.plugs.any((p) => p.view.schemaId == draft.id && p.state.isConnected)) s.name,
            }.toList();
            final key = _key;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Semantics(
                container: true,
                label: 'Sign and acknowledge ${draft.id.path}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CodeText('Sign and acknowledge `${draft.id.path}`', style: context.text.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'Signing creates revision $_revision of the confdb-schema assertion. Acknowledging installs it on this device.',
                      style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          widget.base?.revision == null ? 'Contents' : 'Changes from rev ${widget.base!.revision}',
                          style: context.text.titleSmall,
                        ),
                        const SizedBox(width: 8),
                        Text('$added added · $removed removed', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _DiffList(lines: diff),
                    const SizedBox(height: 20),
                    if (snap.connectionState != ConnectionState.waiting && keys.isEmpty)
                      _NoKeys(
                        account: draft.id.account,
                        error: snap.error,
                        loggedOut: !(widget.scope.app.storeAccount?.isLoggedIn ?? true),
                        onRefresh: _refreshKeys,
                      )
                    else
                      Opacity(
                        opacity: _busy ? 0.38 : 1,
                        child: OutlinedSelect<SigningKey>(
                          label: 'Signing key',
                          enabled: !_busy && keys.isNotEmpty,
                          helper: keys.isEmpty
                              ? 'Loading keys…'
                              : 'Registered to account ${draft.id.account} · ${plural(keys.length, 'key')} available',
                          items: [
                            for (final k in keys)
                              (
                                k,
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(k.name, style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                                    Text(
                                      'SHA3-384 · ${k.shortFingerprint}',
                                      style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          onSelected: (k) => setState(() => _key = k),
                          child: Row(
                            children: [
                              Icon(AppIcons.key, size: 20, color: c.onSurfaceVariant),
                              const SizedBox(width: 12),
                              Expanded(
                                child: key == null
                                    ? Text('No key', style: context.text.bodyLarge)
                                    : Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            key.name,
                                            style: context.text.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
                                          ),
                                          Text(
                                            'SHA3-384 · ${key.shortFingerprint}',
                                            style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    InlineMessage(
                      kind: MessageKind.info,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      title: widget.base?.revision == null
                          ? 'Revision 1 becomes available to snaps that plug its views.'
                          : 'Revision $_revision will replace revision ${widget.base!.revision} for all connected snaps.',
                      body: users.isEmpty
                          ? null
                          : Text(
                              '${users.length == 1 ? users.first : '${users.sublist(0, users.length - 1).join(', ')} and ${users.last}'} use the new rules from their next request.',
                            ),
                    ),
                    const SizedBox(height: 16),
                    CliDisclosure('snap sign -k ${key?.name ?? '<key>'} < $file.json > $file.assert && sudo snap ack $file.assert'),
                    if (_busy) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.secondary)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _phase == SignPhase.signing
                                        ? 'Signing with ${key?.name} …'
                                        : 'Signed with ${key?.name} · acknowledging revision $_revision with snapd…',
                                    style: context.text.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: _phase == SignPhase.signing ? 0.25 : 0.62,
                              minHeight: 4,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      InlineMessage(
                        kind: MessageKind.error,
                        title: 'Couldn’t sign and acknowledge',
                        body: CodeText('$_error'),
                        actions: [if (_error case ConfdbException(:final command?)) CliDisclosure(command, initiallyOpen: true)],
                        padding: const EdgeInsets.all(12),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        PrimaryButton(
                          label: _busy ? 'Signing…' : 'Sign and acknowledge',
                          icon: AppIcons.verified,
                          busy: _busy,

                          onPressed: key == null ? null : _sign,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DiffList extends StatelessWidget {
  const _DiffList({required this.lines});
  final List<SchemaDiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final mono = context.text.bodySmall!.mono.copyWith(fontSize: 13, height: 18 / 13);
    if (lines.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
        child: Text('No changes from the acknowledged revision.', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          for (final d in lines)
            Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: Color.alphaBlend((d.added ? s.successContainer : c.errorContainer).withValues(alpha: 0.45), c.surfaceContainerLow),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: ExcludeSemantics(
                      child: Text(
                        d.added ? '+' : '−',
                        style: mono.copyWith(fontWeight: FontWeight.w700, color: d.added ? s.success : c.error),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 96,
                    child: Text(d.where, style: mono.copyWith(color: c.onSurfaceVariant)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(d.what, style: mono)),
                  const SizedBox(width: 8),
                  d.added
                      ? const StatusBadge.success('Added', icon: AppIcons.add)
                      : const StatusBadge.error('Removed', icon: AppIcons.remove),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown instead of the key picker when `snap keys` lists nothing.
class _NoKeys extends StatelessWidget {
  const _NoKeys({required this.account, required this.error, required this.loggedOut, required this.onRefresh});
  final String account;
  final Object? error;
  final bool loggedOut;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final name = '$account-release';
    Widget step(int n, String text, String command) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CodeText('$n. $text', style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          CliDisclosure(command, initiallyOpen: true),
        ],
      ),
    );
    return InlineMessage(
      kind: MessageKind.warning,
      title: error == null ? 'No signing keys found' : 'Couldn’t list signing keys',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null) ...[CodeText('$error'), const SizedBox(height: 8)],
          CodeText(
            'Schemas are signed with a key registered to the account `$account`. '
            'Create one in a terminal (it asks for a passphrase), register it, then refresh.',
          ),
          if (loggedOut) step(1, 'Log in to snapcraft', 'snapcraft login'),
          step(loggedOut ? 2 : 1, 'Create a key', 'snap create-key $name'),
          step(loggedOut ? 3 : 2, 'Register it to `$account`', 'snapcraft register-key $name'),
        ],
      ),
      actions: [OnContainerButton(label: 'Refresh keys', icon: AppIcons.retry, onPressed: onRefresh)],
    );
  }
}
