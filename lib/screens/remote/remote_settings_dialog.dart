import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/remote/remote_models.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/fields.dart';

Future<void> showRemoteSettingsDialog(BuildContext context) =>
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _RemoteSettingsDialog());

enum _Auth { command, token }

const _validities = [Duration(minutes: 15), Duration(hours: 1), Duration(hours: 6), Duration(hours: 24), Duration(days: 7)];

String _validityLabel(Duration d) => d.inDays >= 1
    ? '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'}'
    : d.inHours >= 1
    ? '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'}'
    : '${d.inMinutes} minutes';

class _RemoteSettingsDialog extends StatefulWidget {
  const _RemoteSettingsDialog();

  @override
  State<_RemoteSettingsDialog> createState() => _RemoteSettingsDialogState();
}

class _RemoteSettingsDialogState extends State<_RemoteSettingsDialog> {
  late final RemoteSettings _initial = context.remote.settings;
  late final _url = TextEditingController(text: _initial.storeUrl);
  late final _path = TextEditingController(text: _initial.apiPath);
  late final _account = TextEditingController(text: _initial.account);
  late final _command = TextEditingController(text: _initial.tokenCommand);
  late final _token = TextEditingController(text: _initial.token);
  late final _key = TextEditingController(text: _initial.signingKey);
  late _Auth _auth = _initial.tokenCommand.isEmpty && _initial.token.isNotEmpty ? _Auth.token : _Auth.command;
  late Duration _validity = _initial.validity;
  List<SigningKey>? _keys;
  bool _testing = false;
  (bool, String)? _testResult;

  @override
  void initState() {
    super.initState();
    for (final c in [_url, _path, _account, _command, _token, _key]) {
      c.addListener(() => setState(() => _testResult = null));
    }
    context.repo.signingKeys().then((k) {
      if (mounted) setState(() => _keys = k);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    for (final c in [_url, _path, _account, _command, _token, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  RemoteSettings get _settings => RemoteSettings(
    storeUrl: _url.text.trim(),
    apiPath: _path.text.trim().isEmpty ? RemoteSettings.defaultApiPath : _path.text.trim(),
    account: _account.text.trim(),
    tokenCommand: _auth == _Auth.command ? _command.text.trim() : '',
    token: _auth == _Auth.token ? _token.text.trim() : '',
    signingKey: _key.text.trim(),
    validity: _validity,
  );

  String? get _urlError {
    final u = Uri.tryParse(_url.text.trim());
    if (_url.text.trim().isEmpty) return null;
    if (u == null || !u.hasScheme || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      return 'Use an http:// or https:// URL';
    }
    return null;
  }

  Future<void> _test() async {
    final s = _settings;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final service = context.remote.connect(s);
    try {
      final session = await service.createSession();
      await service.removeSession(session);
      if (mounted) setState(() => _testResult = (true, 'Opened and removed a session at ${s.sessionsUri}'));
    } on ConfdbException catch (e) {
      if (mounted) setState(() => _testResult = (false, e.message));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    await context.remote.updateSettings(_settings);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final s = _settings;
    final mono = context.text.bodyMedium?.mono;
    final canTest = !_testing && _urlError == null && s.storeUrl.isNotEmpty && s.account.isNotEmpty && s.hasAuth;
    final remote = context.remote;
    final dropsSession = remote.session != null && !s.sameService(remote.settings);

    return AlertDialog(
      title: const Text('Remote settings'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Message service', style: context.text.titleSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                autofocus: _url.text.isEmpty,
                style: mono,
                decoration: InputDecoration(
                  labelText: 'Store URL',
                  hintText: 'http://test-store.lxd',
                  errorText: _urlError,
                  helperText: 'The Store (or enterprise store) whose publisher gateway hosts the messages API',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _path,
                style: mono,
                decoration: InputDecoration(
                  labelText: 'Messages API path',
                  helperText: '{account} is replaced by the account ID. Sessions: ${s.storeUrl.isEmpty ? '…' : s.sessionsUri}',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _account,
                style: mono,
                decoration: const InputDecoration(
                  labelText: 'Account ID',
                  helperText: 'Signs the requests and owns the session. Devices must delegate views to it.',
                ),
              ),
              const SizedBox(height: 24),
              Text('Authentication', style: context.text.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<_Auth>(
                segments: const [
                  ButtonSegment(value: _Auth.command, label: Text('Token command')),
                  ButtonSegment(value: _Auth.token, label: Text('Paste a token')),
                ],
                selected: {_auth},
                onSelectionChanged: (v) => setState(() {
                  _auth = v.single;
                  _testResult = null;
                }),
              ),
              const SizedBox(height: 12),
              if (_auth == _Auth.command)
                TextField(
                  controller: _command,
                  style: mono,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText:
                        'lxc exec test-store -- curl -s -X POST http://127.0.0.1:8005/tokens/create '
                        '-H \'Content-Type: application/json\' -d \'{"account_id":"{account}","ttl_seconds":3600}\' | jq -r .macaroon',
                    hintMaxLines: 4,
                    helperText: 'Run with sh; prints a macaroon. Run again when the service refuses the token, or after 55 minutes.',
                    helperMaxLines: 2,
                  ),
                )
              else
                TextField(
                  controller: _token,
                  style: mono,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Macaroon', helperText: 'Replace it when it expires'),
                ),
              const SizedBox(height: 24),
              Text('Requests', style: context.text.titleSmall),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _keys == null || _keys!.isEmpty
                        ? TextField(
                            controller: _key,
                            style: mono,
                            decoration: const InputDecoration(labelText: 'Signing key', helperText: 'A key in snap keys'),
                          )
                        : OutlinedSelect<String>(
                            label: 'Signing key',
                            helper: 'From snap keys; registered to the account',
                            items: [
                              for (final k in _keys!) (k.name, Text(k.name, style: context.text.bodyLarge?.mono.copyWith(fontSize: 15))),
                            ],
                            onSelected: (v) => _key.text = v,
                            child: Text(_key.text.isEmpty ? 'Choose a key' : _key.text),
                          ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    child: OutlinedSelect<Duration>(
                      label: 'Valid for',
                      helper: 'Then devices ignore it',
                      items: [for (final d in _validities) (d, Text(_validityLabel(d)))],
                      onSelected: (d) => setState(() => _validity = d),
                      child: Text(_validityLabel(_validity)),
                    ),
                  ),
                ],
              ),
              if (dropsSession) ...[
                const SizedBox(height: 16),
                const InlineMessage(
                  kind: MessageKind.warning,
                  padding: EdgeInsets.all(12),
                  title: 'A new session will be opened',
                  body: Text('Answers to requests sent through the current service won’t arrive.'),
                ),
              ],
              if (_testResult case (final ok, final message)) ...[
                const SizedBox(height: 16),
                InlineMessage(
                  kind: ok ? MessageKind.success : MessageKind.error,
                  padding: const EdgeInsets.all(12),
                  title: ok ? 'Connected' : 'Couldn’t connect',
                  body: CodeText(message),
                ),
              ],
              const SizedBox(height: 8),
              Text('Saved on this computer, readable only by you.', style: muted),
            ],
          ),
        ),
      ),
      actions: [
        SecondaryButton(
          label: _testing ? 'Testing…' : 'Test connection',
          icon: AppIcons.retry,
          busy: _testing,
          onPressed: canTest ? _test : null,
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        PrimaryButton(label: 'Save', onPressed: _urlError == null ? _save : null),
      ],
    );
  }
}
