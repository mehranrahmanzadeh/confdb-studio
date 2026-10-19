import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_scope.dart';
import '../../state/store_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';

/// Signs in to the Snap Store (through the vendored Rust backend) with an Ubuntu One account.
/// Returns whether it signed in.
Future<bool> showStoreLoginDialog(BuildContext context) async {
  final store = context.store;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _StoreLoginDialog(store: store),
  );
  return ok ?? false;
}

class _StoreLoginDialog extends StatefulWidget {
  const _StoreLoginDialog({required this.store});
  final StoreController store;

  @override
  State<_StoreLoginDialog> createState() => _StoreLoginDialogState();
}

class _StoreLoginDialogState extends State<_StoreLoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _otp = TextEditingController();
  final _otpFocus = FocusNode();
  bool _needsOtp = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email.text = widget.store.session?.email ?? '';
    for (final c in [_email, _password, _otp]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _otp.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  bool get _ready => !_busy && _email.text.trim().isNotEmpty && _password.text.isNotEmpty && (!_needsOtp || _otp.text.trim().isNotEmpty);

  /// Tells the backend to abandon a flow parked waiting on a 2FA code
  /// before closing, so the state machine is back in `Idle` and the next
  /// sign-in attempt doesn't collide with this one (see
  /// `RustAuthClient.cancelLogin`'s doc comment).
  Future<void> _cancel() async {
    await widget.store.cancelLogin();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _submit() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.login(
        email: _email.text.trim(),
        password: _password.text,
        otp: _needsOtp ? _otp.text.trim() : null,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ConfdbException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (e.kind == ConfdbErrorKind.twoFactorRequired && !_needsOtp) {
          _needsOtp = true;
          _otpFocus.requestFocus();
        } else {
          _error = e.message;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);
    return AlertDialog(
      title: const Text('Sign in to the Snap Store'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Use your Ubuntu One account to see the schemas registered to it and push new revisions. '
                'The login is saved on this computer, readable only by you, until you sign out.',
                style: muted,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                enabled: !_busy && !_needsOtp,
                autofocus: _email.text.isEmpty,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !_busy && !_needsOtp,
                autofocus: _email.text.isNotEmpty,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => _submit(),
              ),
              if (_needsOtp) ...[
                const SizedBox(height: 16),
                const InlineMessage(
                  kind: MessageKind.info,
                  padding: EdgeInsets.all(12),
                  title: 'Two-factor authentication',
                  body: Text('Enter the code from your authenticator app or security key.'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _otp,
                  focusNode: _otpFocus,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(labelText: 'Authentication code'),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: InlineMessage(
                    kind: MessageKind.error,
                    padding: const EdgeInsets.all(12),
                    title: 'Couldn’t sign in',
                    body: CodeText(_error!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _cancel, child: const Text('Cancel')),
        PrimaryButton(label: _busy ? 'Signing in…' : 'Sign in', icon: AppIcons.signIn, busy: _busy, onPressed: _ready ? _submit : null),
      ],
    );
  }
}
