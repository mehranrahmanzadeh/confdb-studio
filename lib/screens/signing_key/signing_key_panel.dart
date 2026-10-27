import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/account_names.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/signing_key_badge.dart';
import '../store/store_login_dialog.dart';

/// 7.5 Signing key (the editor's step between the playground and the sign
/// dialog): pick a key registered to the Store, or create one.
class SigningKeyPanel extends StatefulWidget {
  const SigningKeyPanel({super.key, required this.draft, required this.selected, required this.onSelectionChanged});
  final ConfdbSchema draft;

  /// The step remembers the selection across rebuilds; the editor keeps it
  /// too, so it survives navigating back from the sign dialog.
  final SigningKey? selected;

  /// Reports both the key and whether it's known to be registered, so the
  /// header can gate "Sign & acknowledge" on a *confirmed* unregistered key.
  final void Function(SigningKey? key, bool? registered) onSelectionChanged;

  @override
  State<SigningKeyPanel> createState() => _SigningKeyPanelState();
}

class _SigningKeyPanelState extends State<SigningKeyPanel> {
  late Future<(List<SigningKey>, Set<String>?)> _context = _load();
  bool _creatingKey = false;
  String? _registeringKeyName;

  /// The name of a just-created key, picked up once it shows in the next load.
  String? _pendingSelect;

  Future<(List<SigningKey>, Set<String>?)> _load() async {
    final repo = context.scope.repository;
    final r = await Future.wait([repo.signingKeys(), repo.registeredStoreKeyDigests()]);
    return (r[0] as List<SigningKey>, r[1] as Set<String>?);
  }

  void _refreshKeys() {
    setState(() {
      _context = _load();
    });
  }

  /// null means "can't tell" (signed out/offline) rather than "not
  /// registered" — the list shouldn't claim a key is unregistered when it
  /// simply couldn't check.
  bool? _registered(SigningKey key, Set<String>? digests) {
    if (digests == null || key.sha3384.isEmpty) return null;
    return digests.contains(key.sha3384);
  }

  void _select(SigningKey key, Set<String>? digests) => widget.onSelectionChanged(key, _registered(key, digests));

  Future<void> _createKey() async {
    final scope = context.scope;
    final messenger = ScaffoldMessenger.of(context);
    final account = widget.draft.id.account;
    final suggested = '${context.accounts?.alias(account) ?? account}-release';
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _CreateKeyDialog(suggestedName: suggested),
    );
    if (name == null || !mounted) return;
    setState(() => _creatingKey = true);
    try {
      final key = await scope.repository.createSigningKey(name);
      if (!mounted) return;
      _pendingSelect = key.name;
      _refreshKeys();
    } catch (e) {
      if (mounted) showToast(messenger, CodeText('Couldn’t create `$name`: $e'), kind: MessageKind.error);
    } finally {
      if (mounted) setState(() => _creatingKey = false);
    }
  }

  Future<void> _registerKey(SigningKey key, Set<String>? digests, {bool retried = false}) async {
    final scope = context.scope;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _registeringKeyName = key.name);
    try {
      await scope.repository.registerKey(key);
      if (!mounted) return;
      _pendingSelect = key.name;
      _refreshKeys();
      showToast(messenger, CodeText('`${key.name}` is now registered to the Snap Store.'), kind: MessageKind.success);
    } on ConfdbException catch (e) {
      if (!mounted) return;
      if (e.kind == ConfdbErrorKind.signedOut && !retried) {
        // The persisted macaroon's SSO discharge expired or was revoked;
        // there's no silent refresh, so reflect it in the Store session
        // (the rail shows "Log in" again) and offer to sign back in and
        // retry once, instead of leaving the user with a bare 401. Capped
        // at one retry: if it's still rejected right after a fresh sign-in,
        // looping would just reopen the dialog forever.
        context.store.markSignedOut(e.message);
        final loggedIn = await showStoreLoginDialog(context);
        if (loggedIn && mounted) await _registerKey(key, digests, retried: true);
      } else {
        showToast(messenger, CodeText('Couldn’t register `${key.name}`: $e'), kind: MessageKind.error);
      }
    } catch (e) {
      if (mounted) showToast(messenger, CodeText('Couldn’t register `${key.name}`: $e'), kind: MessageKind.error);
    } finally {
      if (mounted) setState(() => _registeringKeyName = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FutureBuilder(
      future: _context,
      builder: (context, snap) {
        final keys = snap.data?.$1 ?? const <SigningKey>[];
        final digests = snap.data?.$2;
        if (_pendingSelect case final name? when keys.any((k) => k.name == name)) {
          _pendingSelect = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _select(keys.firstWhere((k) => k.name == name), digests);
          });
        }
        final loading = snap.connectionState == ConnectionState.waiting;

        return PageBody(
          gap: 20,
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          children: [
            Text(
              'Schemas are signed with a key registered to the account '
              '`${context.accounts?.alias(widget.draft.id.account) ?? widget.draft.id.account}`. '
              'Select one, or create and register a new one.',
              style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
            ),
            if (loading)
              const _LoadingKeys()
            else if (keys.isEmpty)
              _NoKeys(
                account: widget.draft.id.account,
                error: snap.error,
                loggedOut: !(context.store.session?.signedIn ?? true),
                creating: _creatingKey,
                onCreateKey: _createKey,
                onRefresh: _refreshKeys,
              )
            else ...[
              SectionCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < keys.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: c.outlineVariant),
                      _KeyRow(
                        signingKey: keys[i],
                        selected: widget.selected?.name == keys[i].name,
                        registered: _registered(keys[i], digests),
                        registering: _registeringKeyName == keys[i].name,
                        onSelect: () => _select(keys[i], digests),
                        onRegister: () => _registerKey(keys[i], digests),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TertiaryButton(
                  label: _creatingKey ? 'Creating…' : 'Create key',
                  icon: AppIcons.add,
                  onPressed: _creatingKey ? null : _createKey,
                ),
              ),
            ],
            if (widget.selected != null && _registered(widget.selected!, digests) == false)
              InlineMessage(
                kind: MessageKind.warning,
                title: '`${widget.selected!.name}` isn’t registered in the Snap Store',
                body: const Text(
                  'snapd can’t verify its signature until the key is registered to this account. Register it above to continue.',
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Shown while `snap keys` and the Store's registered-key check are in
/// flight (initial load, or a refresh after creating/registering a key).
class _LoadingKeys extends StatelessWidget {
  const _LoadingKeys();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SectionCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c.primary)),
            const SizedBox(width: 12),
            Text('Loading signing keys…', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// One selectable row: name, fingerprint, registration badge and (if
/// unregistered) a register action.
class _KeyRow extends StatelessWidget {
  const _KeyRow({
    required this.signingKey,
    required this.selected,
    required this.registered,
    required this.registering,
    required this.onSelect,
    required this.onRegister,
  });
  final SigningKey signingKey;
  final bool selected;
  final bool? registered;
  final bool registering;
  final VoidCallback onSelect;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.secondaryContainer.withValues(alpha: 0.4) : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: Semantics(
          button: true,
          selected: selected,
          label: 'Signing key ${signingKey.name}',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(selected ? Icons.check_circle : Icons.circle_outlined, size: 22, color: selected ? c.primary : c.outline),
                const SizedBox(width: 8),
                Icon(AppIcons.key, size: 20, color: c.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(signingKey.name, style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                      Text(
                        'SHA3-384 · ${signingKey.shortFingerprint}',
                        style: context.text.bodySmall?.mono.copyWith(color: c.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                RegistrationBadge(registered: registered),
                if (registered == false) ...[
                  const SizedBox(width: 8),
                  TertiaryButton(
                    label: registering ? 'Registering…' : 'Register',
                    icon: AppIcons.push,
                    onPressed: registering ? null : onRegister,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the key list when `snap keys` lists nothing.
class _NoKeys extends StatelessWidget {
  const _NoKeys({
    required this.account,
    required this.error,
    required this.loggedOut,
    required this.creating,
    required this.onCreateKey,
    required this.onRefresh,
  });
  final String account;
  final Object? error;
  final bool loggedOut;
  final bool creating;
  final VoidCallback onCreateKey;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return InlineMessage(
      kind: MessageKind.warning,
      title: error == null ? 'No signing keys found' : 'Couldn’t list signing keys',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null) ...[CodeText('$error'), const SizedBox(height: 8)],
          CodeText(
            'Schemas are signed with a key registered to the account `$account`. '
            'Create one, register it to the account, then refresh.',
          ),
          if (loggedOut) ...[const SizedBox(height: 8), Text('Sign in to the Snap Store first to register a key.')],
        ],
      ),
      actions: [
        if (loggedOut) OnContainerButton(label: 'Sign in', icon: AppIcons.signIn, onPressed: () => showStoreLoginDialog(context)),
        OnContainerButton(label: creating ? 'Creating…' : 'Create key', icon: AppIcons.add, onPressed: creating ? null : onCreateKey),
        OnContainerButton(label: 'Refresh keys', icon: AppIcons.retry, onPressed: onRefresh),
      ],
    );
  }
}

/// Prompts for a new key's name; creation itself (and the pinentry prompt)
/// happens after this returns.
class _CreateKeyDialog extends StatefulWidget {
  const _CreateKeyDialog({required this.suggestedName});
  final String suggestedName;

  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  late final _controller = TextEditingController(text: widget.suggestedName);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create a signing key'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Key name'),
                validator: (v) {
                  final name = v?.trim() ?? '';
                  if (name.isEmpty) return 'Required.';
                  if (!RegExp(r'^(?:[a-z0-9]+-?)*[a-z](?:-?[a-z0-9])*$').hasMatch(name)) {
                    return 'Lowercase letters, digits and dashes only.';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              Text(
                'Creates an RSA-4096 key in the keyring `snap sign` uses. GPG asks for a '
                'passphrase in a system dialog — it never passes through Confdb Studio.',
                style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
