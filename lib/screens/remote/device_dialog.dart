import 'package:flutter/material.dart';

import '../../data/remote/remote_models.dart';
import '../../domain/remote.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';

/// Adds a device, or renames [device].
Future<void> showDeviceDialog(BuildContext context, {RemoteDevice? device}) => showDialog<void>(
  context: context,
  builder: (_) => _DeviceDialog(device: device),
);

class _DeviceDialog extends StatefulWidget {
  const _DeviceDialog({this.device});
  final RemoteDevice? device;

  @override
  State<_DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<_DeviceDialog> {
  late final _id = TextEditingController(text: widget.device?.id.id ?? '');
  late final _label = TextEditingController(text: widget.device?.label ?? '');

  bool get _editing => widget.device != null;

  @override
  void initState() {
    super.initState();
    _id.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    super.dispose();
  }

  (DeviceId?, String?) get _parsed {
    final text = _id.text.trim();
    if (text.isEmpty) return (null, null);
    try {
      return (parseDeviceInput(text), null);
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  Future<void> _save() async {
    final (id, _) = _parsed;
    if (id == null) return;
    final remote = context.remote;
    final exists = !_editing && remote.devices.any((d) => d.id == id);
    await remote.addDevice(RemoteDevice(id, label: _label.text.trim()));
    if (!mounted) return;
    Navigator.of(context).pop();
    if (exists) showConfirmation(context, Text('${id.serial} was already added; its name was updated'));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (id, error) = _parsed;
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);
    return AlertDialog(
      title: Text(_editing ? 'Rename device' : 'Add device'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_editing) ...[
              Text(
                'Devices are addressed as <serial>.<model>.<brand-id>. Paste that, or the output of '
                '`snap known serial` from the device.',
                style: muted,
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _id,
              enabled: !_editing,
              autofocus: !_editing,
              minLines: 1,
              maxLines: _editing ? 1 : 6,
              style: context.text.bodyMedium?.mono,
              decoration: InputDecoration(
                labelText: 'Device ID',
                errorText: error,
                helperText: id == null || _editing ? null : 'Brand ${id.brand} · model ${id.model} · serial ${id.serial}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              autofocus: _editing,
              decoration: const InputDecoration(labelText: 'Name (optional)', helperText: 'Shown instead of the serial'),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        PrimaryButton(label: _editing ? 'Save' : 'Add device', icon: _editing ? null : AppIcons.add, onPressed: id == null ? null : _save),
      ],
    );
  }
}
