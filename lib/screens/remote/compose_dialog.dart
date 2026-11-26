import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/remote/remote_models.dart';
import '../../domain/paths.dart';
import '../../domain/remote.dart';
import '../../state/account_names.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/account_name.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import 'remote_schemas.dart';

/// What the composer starts from: a fresh message, or a copy of a request.
class ComposeDraft {
  const ComposeDraft({
    this.action = RemoteAction.get,
    this.view = '',
    this.devices = const [],
    this.keys = const [],
    this.values = const {},
  });

  factory ComposeDraft.of(RemoteRequest r) => ComposeDraft(
    action: r.action,
    view: r.view,
    devices: [for (final d in r.devices) ?DeviceId.tryParse(d)],
    keys: r.keys,
    values: r.values,
  );

  final RemoteAction action;
  final String view;
  final List<DeviceId> devices;
  final List<String> keys;
  final Map<String, Object?> values;
}

/// New message: targets → action & view → content → review & send. Returns
/// the request when one was sent (or failed to send).
Future<RemoteRequest?> showComposeDialog(
  BuildContext context, {
  required KnownSchemas schemas,
  ComposeDraft draft = const ComposeDraft(),
}) => showDialog<RemoteRequest>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ComposeDialog(schemas: schemas, draft: draft),
);

const _steps = ['Targets', 'Action & view', 'Content', 'Review & send'];

class _ValueRow {
  _ValueRow([String key = '', String value = '', this.unset = false])
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);
  final TextEditingController key;
  final TextEditingController value;
  bool unset;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// Text typed as a value: JSON when it parses (numbers, booleans, lists,
/// maps, quoted strings), otherwise the text itself as a string.
Object? parseValueInput(String text) {
  final t = text.trim();
  try {
    return jsonDecode(t);
  } on FormatException {
    return text;
  }
}

/// [v] as typed into a value field; text that would read as JSON is quoted.
String _valueText(Object? v) => v is String && parseValueInput(v) is String ? v : jsonEncode(v);

class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({required this.schemas, required this.draft});
  final KnownSchemas schemas;
  final ComposeDraft draft;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  int _step = 0;
  late final Set<DeviceId> _targets = {...widget.draft.devices};
  late RemoteAction _action = widget.draft.action;
  late final _view = TextEditingController(text: widget.draft.view);
  final _viewFocus = FocusNode();
  late final _keys = <String>[...widget.draft.keys];
  final _newKey = TextEditingController();
  late final _values = [
    for (final e in widget.draft.values.entries) _ValueRow(e.key, e.value == null ? '' : _valueText(e.value), e.value == null),
  ];
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_values.isEmpty) _values.add(_ValueRow());
    for (final c in [_view, _newKey]) {
      c.addListener(() => setState(() {}));
    }
    for (final r in _values) {
      _listen(r);
    }
    if (_targets.isNotEmpty) _step = 1;
  }

  void _listen(_ValueRow r) {
    r.key.addListener(() => setState(() {}));
    r.value.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _view.dispose();
    _viewFocus.dispose();
    _newKey.dispose();
    for (final r in _values) {
      r.dispose();
    }
    super.dispose();
  }

  String? get _viewError {
    final v = _view.text.trim();
    if (v.isEmpty) return null;
    try {
      final ref = ViewRef.parse(v);
      if (ref.account.isEmpty || ref.schema.isEmpty || ref.view.isEmpty) return 'Expected <account>/<schema>/<view>';
    } on FormatException {
      return 'Expected <account>/<schema>/<view>';
    }
    return null;
  }

  ViewDef? get _viewDef {
    final v = _view.text.trim();
    return widget.schemas.schemaOf(v)?.view(v.split('/').last);
  }

  ValueMasker get _masker => widget.schemas.masker(_view.text.trim());

  /// Rows with a key; null when one is invalid.
  Map<String, Object?>? get _setValues {
    final out = <String, Object?>{};
    for (final r in _values) {
      final k = r.key.text.trim();
      if (k.isEmpty) continue;
      if (tryParsePath(k) == null || out.containsKey(k)) return null;
      out[k] = r.unset ? null : parseValueInput(r.value.text);
    }
    return out;
  }

  bool get _canNext => _stepDone(_step);

  bool _stepDone(int step) => switch (step) {
    0 => _targets.isNotEmpty,
    1 => _view.text.trim().isNotEmpty && _viewError == null,
    2 => _action == RemoteAction.get ? _keys.every((k) => tryParsePath(k) != null) : (_setValues?.isNotEmpty ?? false),
    _ => !_sending,
  };

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final remote = context.remote;
    try {
      final r = await remote.send(
        action: _action,
        view: ViewRef.parse(_view.text.trim()),
        devices: [
          for (final d in remote.devices)
            if (_targets.contains(d.id)) d.id,
        ],
        keys: _action == RemoteAction.get ? _keys : const [],
        values: _action == RemoteAction.set ? _setValues! : const {},
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(r);
      showToast(
        messenger,
        Text(
          r.sendError == null
              ? 'Sent to ${plural(r.devices.length, 'device')}. Answers arrive once they next check in.'
              : 'Not sent: ${r.sendError}',
        ),
        kind: r.sendError == null ? MessageKind.success : MessageKind.error,
      );
    } on ConfdbException catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_step) {
      0 => _targetsStep(),
      1 => _viewStep(),
      2 => _contentStep(),
      _ => _reviewStep(),
    };
    return AlertDialog(
      title: const Text('New message'),
      content: SizedBox(
        width: 680,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StepBar(step: _step, onStep: (i) => setState(() => _step = i), enabledUpTo: _maxReachable()),
            const SizedBox(height: 16),
            Expanded(child: SingleChildScrollView(child: body)),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineMessage(
                kind: MessageKind.error,
                padding: const EdgeInsets.all(12),
                title: 'Couldn’t sign the request',
                body: CodeText(_error!),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _sending ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (_step > 0) SecondaryButton(label: 'Back', icon: AppIcons.back, onPressed: _sending ? null : () => setState(() => _step--)),
        if (_step < 3)
          PrimaryButton(label: 'Next', icon: AppIcons.next, onPressed: _canNext ? () => setState(() => _step++) : null)
        else
          PrimaryButton(
            label: _sending ? 'Signing & sending…' : 'Sign & send',
            icon: AppIcons.send,
            busy: _sending,
            onPressed: _canNext ? _send : null,
          ),
      ],
    );
  }

  /// The furthest step the earlier ones allow.
  int _maxReachable() {
    var i = 0;
    while (i < 3 && _stepDone(i)) {
      i++;
    }
    return i;
  }

  // -------------------------------------------------------------- Targets

  Widget _targetsStep() {
    final remote = context.remote;
    final c = context.colors;
    final byBrand = <String, Map<String, List<RemoteDevice>>>{};
    for (final d in remote.devices) {
      byBrand.putIfAbsent(d.id.brand, () => {}).putIfAbsent(d.id.model, () => []).add(d);
    }
    bool? stateOf(Iterable<RemoteDevice> ds) {
      final n = ds.where((d) => _targets.contains(d.id)).length;
      return n == 0 ? false : (n == ds.length ? true : null);
    }

    void toggle(Iterable<RemoteDevice> ds, bool? v) => setState(() {
      if (v ?? false) {
        _targets.addAll(ds.map((d) => d.id));
      } else {
        _targets.removeAll(ds.map((d) => d.id));
      }
    });

    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Which devices should get it? Each must have delegated the view to ${context.aliased(remote.settings.account)}.',
          style: muted,
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          tristate: true,
          value: stateOf(remote.devices),
          onChanged: (v) => toggle(remote.devices, stateOf(remote.devices) != true),
          title: Text('All devices (${remote.devices.length})', style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        ),
        for (final brand in byBrand.keys) ...[
          CheckboxListTile(
            tristate: true,
            value: stateOf(byBrand[brand]!.values.expand((l) => l)),
            onChanged: (_) {
              final all = byBrand[brand]!.values.expand((l) => l).toList();
              toggle(all, stateOf(all) != true);
            },
            title: AccountName(brand, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
          for (final model in byBrand[brand]!.keys) ...[
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: CheckboxListTile(
                tristate: true,
                value: stateOf(byBrand[brand]![model]!),
                onChanged: (_) => toggle(byBrand[brand]![model]!, stateOf(byBrand[brand]![model]!) != true),
                title: Text(model, style: context.text.bodyMedium?.mono),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ),
            for (final d in byBrand[brand]![model]!)
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: CheckboxListTile(
                  value: _targets.contains(d.id),
                  onChanged: (v) => toggle([d], v),
                  title: Text(d.name),
                  subtitle: Text(d.id.id, style: muted?.mono, overflow: TextOverflow.ellipsis),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              ),
          ],
        ],
      ],
    );
  }

  // ----------------------------------------------------------------- View

  Widget _viewStep() {
    final remote = context.remote;
    final c = context.colors;
    final history = {for (final r in remote.requests) r.view};
    final options = {...history, ...widget.schemas.views}.toList();
    final def = _viewDef;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<RemoteAction>(
          segments: const [
            ButtonSegment(value: RemoteAction.get, label: Text('Get values'), icon: Icon(AppIcons.eye)),
            ButtonSegment(value: RemoteAction.set, label: Text('Set values'), icon: Icon(AppIcons.edit)),
          ],
          selected: {_action},
          onSelectionChanged: (v) => setState(() => _action = v.single),
        ),
        const SizedBox(height: 16),
        RawAutocomplete<String>(
          textEditingController: _view,
          focusNode: _viewFocus,
          optionsBuilder: (v) {
            final q = v.text.toLowerCase();
            return options.where((o) => o.toLowerCase().contains(q) || context.aliased(o).toLowerCase().contains(q));
          },
          fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            style: context.text.bodyLarge?.mono,
            decoration: InputDecoration(
              labelText: 'View',
              hintText: '<account>/<schema>/<view>',
              errorText: _viewError,
              helperText: def == null && _view.text.trim().isNotEmpty && _viewError == null
                  ? 'Studio doesn’t have this schema; the device checks the view.'
                  : 'The device must have this schema and have delegated the view to the account.',
              helperMaxLines: 2,
            ),
          ),
          optionsViewBuilder: (context, onSelected, opts) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              color: c.surfaceContainerHigh,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240, maxWidth: 640),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final o in opts)
                      ListTile(
                        dense: true,
                        title: Text(context.aliased(o), style: context.text.bodyMedium?.mono),
                        trailing: history.contains(o) ? Text('used before', style: muted) : null,
                        onTap: () => onSelected(o),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (def != null) ...[
          const SizedBox(height: 16),
          Text('Rules in this view', style: context.text.titleSmall),
          const SizedBox(height: 8),
          for (final r in def.rules)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 200, child: Text(r.request, style: context.text.bodySmall?.mono)),
                  Expanded(child: Text('→ ${r.storage}', style: muted?.mono)),
                  Text(r.access.label, style: muted),
                ],
              ),
            ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------- Content

  Widget _contentStep() => _action == RemoteAction.get ? _getContent() : _setContent();

  List<String> get _suggestedKeys => [for (final r in _viewDef?.rules ?? const <ViewRule>[]) r.request];

  void _addKey(String k) {
    final t = k.trim();
    if (t.isEmpty || _keys.contains(t)) return;
    setState(() => _keys.add(t));
    _newKey.clear();
  }

  Widget _getContent() {
    final c = context.colors;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final newKey = _newKey.text.trim();
    final suggestions = [
      for (final k in _suggestedKeys)
        if (!_keys.contains(k)) k,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Which keys? Leave empty to get everything the view gives access to.', style: muted),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in _keys)
              InputChip(
                label: Text(k, style: context.text.bodySmall?.mono),
                onDeleted: () => setState(() => _keys.remove(k)),
              ),
            if (_keys.isEmpty) Text('All keys', style: context.text.bodyMedium),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _newKey,
          style: context.text.bodyMedium?.mono,
          decoration: InputDecoration(
            labelText: 'Add a key',
            hintText: 'e.g. https.url',
            errorText: newKey.isNotEmpty && tryParsePath(newKey) == null ? 'Not a valid path' : null,
            suffixIcon: IconButton(
              tooltip: 'Add',
              icon: const Icon(AppIcons.add),
              onPressed: newKey.isEmpty || tryParsePath(newKey) == null ? null : () => _addKey(newKey),
            ),
          ),
          onSubmitted: (v) {
            if (tryParsePath(v.trim()) != null) _addKey(v);
          },
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('From the view', style: muted),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in suggestions)
                ActionChip(
                  label: Text(k, style: context.text.bodySmall?.mono),
                  avatar: const Icon(AppIcons.add, size: 16),
                  onPressed: () => _addKey(k),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _setContent() {
    final c = context.colors;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final masker = _masker;
    final seen = <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Values are read as JSON (numbers, true/false, lists, maps); anything else is sent as text. '
          'All of them are written in one change on each device, and a custodian may reject it.',
          style: muted,
        ),
        const SizedBox(height: 12),
        for (final (i, r) in _values.indexed) ...[
          Builder(
            builder: (context) {
              final k = r.key.text.trim();
              final dup = k.isNotEmpty && !seen.add(k);
              final secret = masker.isSecret(k);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: r.key,
                      style: context.text.bodyMedium?.mono,
                      decoration: InputDecoration(
                        labelText: 'Key',
                        errorText: k.isNotEmpty && tryParsePath(k) == null ? 'Not a valid path' : (dup ? 'Already set above' : null),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: r.value,
                      enabled: !r.unset,
                      obscureText: secret,
                      style: context.text.bodyMedium?.mono,
                      decoration: InputDecoration(
                        labelText: r.unset ? 'Unset' : (secret ? 'Value (secret)' : 'Value'),
                        helperText: r.unset || secret || r.value.text.isEmpty ? null : _typeOf(parseValueInput(r.value.text)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: IconButton(
                      tooltip: r.unset ? 'Set a value instead' : 'Unset this key',
                      isSelected: r.unset,
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: () => setState(() => r.unset = !r.unset),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(AppIcons.delete),
                      onPressed: _values.length == 1
                          ? null
                          : () => setState(() {
                              _values.removeAt(i).dispose();
                            }),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TertiaryButton(
            label: 'Add value',
            icon: AppIcons.add,
            onPressed: () => setState(() {
              final r = _ValueRow();
              _listen(r);
              _values.add(r);
            }),
          ),
        ),
        if (_suggestedKeys.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Keys in this view: ${_suggestedKeys.join(', ')}', style: muted?.mono),
        ],
      ],
    );
  }

  static String _typeOf(Object? v) => switch (v) {
    null => 'null: unsets the key',
    String() => 'text',
    bool() => 'boolean',
    num() => 'number',
    List() => 'list',
    Map() => 'map',
    _ => '',
  };

  // --------------------------------------------------------------- Review

  Widget _reviewStep() {
    final remote = context.remote;
    final c = context.colors;
    final s = remote.settings;
    final masker = _masker;
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final targets = [
      for (final d in remote.devices)
        if (_targets.contains(d.id)) d,
    ];
    final ref = ViewRef.parse(_view.text.trim());
    final values = _action == RemoteAction.set ? _setValues! : const <String, Object?>{};
    final body = confdbMessageBody(
      action: _action,
      view: ref,
      keys: _action == RemoteAction.get ? _keys : const [],
      values: {for (final e in values.entries) e.key: masker.isSecret(e.key) ? ValueMasker.mask : e.value},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailList(
          rows: [
            ('Action', Text(_action == RemoteAction.get ? 'Get values' : 'Set values')),
            ('View', Text(context.aliased(ref.path), style: context.text.bodyMedium?.mono)),
            (
              'Devices',
              Text(
                targets.length <= 4
                    ? targets.map((d) => d.name).join(', ')
                    : '${plural(targets.length, 'device')}: ${targets.take(3).map((d) => d.name).join(', ')}…',
              ),
            ),
            ('Signed by', Text('${context.aliased(s.account)} with key ${s.signingKey}')),
            (
              'Valid for',
              Text(
                '${s.validity.inMinutes >= 60 ? '${s.validity.inHours} h' : '${s.validity.inMinutes} min'} (and 5 minutes back, for clock drift)',
              ),
            ),
            ('Service', Text(s.storeUrl, style: context.text.bodyMedium?.mono)),
          ],
        ),
        const SizedBox(height: 16),
        Text('Message body', style: context.text.titleSmall),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: c.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.outlineVariant),
          ),
          child: SelectableText(const JsonEncoder.withIndent('  ').convert(body), style: context.text.bodySmall?.mono),
        ),
        const SizedBox(height: 12),
        Text(
          'Studio signs a request-message with snap sign and hands it to the message service. Each device collects it the next '
          'time it checks in, and its answer arrives on a later check-in.',
          style: muted,
        ),
      ],
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.onStep, required this.enabledUpTo});
  final int step;
  final ValueChanged<int> onStep;
  final int enabledUpTo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        for (final (i, label) in _steps.indexed) ...[
          if (i > 0) Expanded(child: Divider(color: c.outlineVariant, indent: 8, endIndent: 8)),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            mouseCursor: i <= enabledUpTo ? WidgetStateMouseCursor.clickable : SystemMouseCursors.basic,
            onTap: i <= enabledUpTo ? () => onStep(i) : null,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: i == step ? c.primary : (i < step ? c.secondaryContainer : c.surfaceContainerHigh),
                    child: i < step
                        ? Icon(AppIcons.check, size: 14, color: c.onSecondaryContainer)
                        : Text('${i + 1}', style: context.text.labelSmall?.copyWith(color: i == step ? c.onPrimary : c.onSurfaceVariant)),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: context.text.labelMedium?.copyWith(
                      color: i == step ? c.onSurface : c.onSurfaceVariant,
                      fontWeight: i == step ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
