import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/signing_key_badge.dart';
import '../../widgets/status_badge.dart';
import '../store/store_login_dialog.dart';

/// 7.5 Sign & acknowledge (SignDialog.dc.html, -Progress). The signing key
/// is picked on the editor's "Signing key" step; this dialog just confirms
/// and runs the sign (and optional push). On success, it opens the
/// playground step (to [view], when given) so the new revision can be tried.
Future<void> showSignDialog(
  BuildContext context,
  ConfdbSchema draft,
  ConfdbSchema? base,
  SigningKey key, {
  bool? keyRegistered,
  String? view,
  ValueChanged<int>? onSigned,
}) {
  final scope = context.scope;
  final messenger = ScaffoldMessenger.of(context);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SignDialog(
      draft: draft,
      base: base,
      signKey: key,
      keyRegistered: keyRegistered,
      view: view,
      scope: scope,
      messenger: messenger,
      onSigned: onSigned,
    ),
  );
}

class _SignDialog extends StatefulWidget {
  const _SignDialog({
    required this.draft,
    required this.base,
    required this.signKey,
    required this.keyRegistered,
    required this.view,
    required this.scope,
    required this.messenger,
    this.onSigned,
  });
  final ConfdbSchema draft;
  final ConfdbSchema? base;
  final SigningKey signKey;
  final bool? keyRegistered;

  /// The view selected on the editor; opens the post-sign playground step.
  final String? view;
  final AppScope scope;
  final ScaffoldMessengerState messenger;

  /// Notifies the editor of the signed revision, so it can stop treating the
  /// draft's storage paths as newly added.
  final ValueChanged<int>? onSigned;

  @override
  State<_SignDialog> createState() => _SignDialogState();
}

class _SignDialogState extends State<_SignDialog> {
  late final Future<List<SnapInfo>> _snaps = widget.scope.repository.listSnaps();

  SigningKey get _key => widget.signKey;
  SignPhase? _phase;
  Object? _error;

  /// Register in the Snap Store too; on by default when signed in.
  late bool _push = widget.scope.store.signedIn;
  bool get _pushing => _push && widget.scope.store.signedIn;

  /// Past both this device's and the Store's revision, as the backend signs it.
  int get _revision {
    final inStore = widget.scope.store.schema(widget.draft.id)?.revision ?? 0;
    final here = widget.base?.revision ?? 0;
    return (inStore > here ? inStore : here) + 1;
  }

  bool get _busy => _phase != null;

  Future<void> _sign() async {
    final key = _key;
    final app = widget.scope.app;
    setState(() {
      _error = null;
      _phase = SignPhase.signing;
    });
    try {
      final push = _pushing;
      final revision = _revision;
      await widget.scope.repository.signAndAcknowledge(
        widget.draft,
        key,
        push: push,
        onPhase: (p) {
          if (mounted) setState(() => _phase = p);
        },
      );
      if (push) widget.scope.store.reloadSchemas();
      widget.onSigned?.call(revision);
      if (!mounted) return;
      Navigator.of(context).pop();
      // Try the newly-applied revision in the playground, or back to the
      // overview if there's no view left to open it with.
      final view = widget.view ?? widget.draft.views.firstOrNull?.name;
      app.go(view == null ? const OverviewRoute() : PlaygroundRoute(widget.draft.id, view: view));
      showToast(
        widget.messenger,
        CodeText(
          push
              ? '`${widget.draft.id.path}` revision $revision signed, pushed to the Snap Store and acknowledged'
              : '`${widget.draft.id.path}` revision $revision signed and acknowledged',
        ),
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
    final key = _key;

    return Dialog(
      backgroundColor: c.surfaceContainerHigh,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: FutureBuilder(
          future: _snaps,
          builder: (context, snap) {
            final snaps = snap.data ?? const <SnapInfo>[];
            final users = {
              for (final s in snaps)
                if (s.plugs.any((p) => p.view.schemaId == draft.id && p.state.isConnected)) s.name,
            }.toList();

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
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(color: c.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        children: [
                          Icon(AppIcons.key, size: 20, color: c.onSurfaceVariant),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(key.name, style: context.text.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500)),
                                    const SizedBox(width: 8),
                                    RegistrationBadge(registered: widget.keyRegistered),
                                  ],
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
                    const SizedBox(height: 8),
                    _StoreOption(push: _push, busy: _busy, revision: _revision, onChanged: (v) => setState(() => _push = v)),
                    const SizedBox(height: 16),
                    CliDisclosure('snap sign -k ${key.name} < $file.json > $file.assert && sudo snap ack $file.assert'),
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
                                  child: Text(switch (_phase) {
                                    SignPhase.signing => 'Signing with ${key.name} …',
                                    SignPhase.pushing => 'Signed with ${key.name} · registering revision $_revision in the Snap Store…',
                                    _ => 'Signed with ${key.name} · acknowledging revision $_revision with snapd…',
                                  }, style: context.text.bodyMedium),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: switch (_phase) {
                                SignPhase.signing => 0.2,
                                SignPhase.pushing => 0.45,
                                _ => 0.7,
                              },
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

                          onPressed: widget.keyRegistered == false ? null : _sign,
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

/// Whether to also register the revision in the Snap Store.
class _StoreOption extends StatelessWidget {
  const _StoreOption({required this.push, required this.busy, required this.revision, required this.onChanged});
  final bool push;
  final bool busy;
  final int revision;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = context.colors;
        final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
        final session = store.session;
        if (!(session?.signedIn ?? false)) {
          return Row(
            children: [
              Icon(AppIcons.storeOff, size: 20, color: c.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text('Not signed in to the Snap Store: this revision stays on this device.', style: muted)),
              const SizedBox(width: 8),
              TertiaryButton(
                label: 'Sign in',
                icon: AppIcons.signIn,
                onPressed: busy
                    ? null
                    : () async {
                        if (await showStoreLoginDialog(context)) onChanged(true);
                      },
              ),
            ],
          );
        }
        return CheckboxListTile(
          value: push,
          onChanged: busy ? null : (v) => onChanged(v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          mouseCursor: WidgetStateMouseCursor.clickable,
          title: const Text('Push to the Snap Store'),
          subtitle: Text(
            'Registers revision $revision in the Store (${session!.env!.host}) before acknowledging it here. '
            'The signing key must be registered there.',
            style: muted,
          ),
        );
      },
    );
  }
}
