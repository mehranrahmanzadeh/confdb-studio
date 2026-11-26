import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/remote/message_service.dart';
import '../../data/remote/remote_models.dart';
import '../../domain/remote.dart';
import '../../shell/app_shell.dart';
import '../../state/account_names.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../state/remote_controller.dart';
import '../../theme/app_theme.dart';
import '../../util/format.dart';
import '../../widgets/account_name.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../../widgets/status_badge.dart';
import 'compose_dialog.dart';
import 'device_dialog.dart';
import 'remote_schemas.dart';
import 'remote_settings_dialog.dart';

/// Which devices the activity is narrowed to: all, a brand, a model or one
/// device.
@immutable
class DeviceScope {
  const DeviceScope({this.brand, this.model, this.device});
  final String? brand;
  final String? model;
  final String? device;

  bool get isAll => brand == null && device == null;

  bool matches(DeviceId d) {
    if (device != null) return d.id == device;
    if (brand != null && d.brand != brand) return false;
    if (model != null && d.model != model) return false;
    return true;
  }

  /// Whether the device with id [id] is in scope; unparsable ids only match
  /// the whole fleet.
  bool matchesId(String id) {
    if (isAll) return true;
    final d = DeviceId.tryParse(id);
    return d != null && matches(d);
  }

  @override
  bool operator ==(Object other) => other is DeviceScope && other.brand == brand && other.model == model && other.device == device;

  @override
  int get hashCode => Object.hash(brand, model, device);
}

/// Remote: devices (by brand and model) on the left, the requests sent to
/// them and their answers on the right.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.route});
  final RemoteRoute route;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  late DeviceScope _scope = widget.route.device == null ? const DeviceScope() : DeviceScope(device: widget.route.device);
  final _expanded = <String>{};
  KnownSchemas _schemas = const KnownSchemas({});

  @override
  void initState() {
    super.initState();
    context.remote.load();
    loadKnownSchemas(context.repo, context.store).then((s) {
      if (mounted) setState(() => _schemas = s);
    });
  }

  Future<void> _compose([ComposeDraft? draft]) async {
    final remote = context.remote;
    final scoped = [
      for (final d in remote.devices)
        if (!_scope.isAll && _scope.matches(d.id)) d.id,
    ];
    final sent = await showComposeDialog(
      context,
      schemas: _schemas,
      draft: draft ?? ComposeDraft(devices: scoped),
    );
    if (sent != null && mounted) setState(() => _expanded.add(sent.messageId));
  }

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    return ListenableBuilder(
      listenable: remote,
      builder: (context, _) {
        if (!remote.loaded) return const Center(child: LoadingRow('Loading remote devices…'));
        final compact = isCompact(context);
        final devices = _DevicePane(scope: _scope, onScope: (s) => setState(() => _scope = s));
        final activity = _ActivityPane(
          scope: _scope,
          schemas: _schemas,
          expanded: _expanded,
          onToggle: (id) => setState(() => _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id)),
          onDuplicate: (r) => _compose(ComposeDraft.of(r)),
          onCompose: _compose,
        );
        final c = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onCompose: _compose),
            if (!remote.settings.isComplete) const _SetupBanner(),
            if (remote.pollError != null) _PollErrorBanner(error: remote.pollError!),
            Expanded(
              child: compact
                  ? ListView(
                      children: [
                        devices,
                        Divider(height: 1, color: c.outlineVariant),
                        activity,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 320,
                          decoration: BoxDecoration(
                            color: c.surfaceContainerLow,
                            border: Border(right: BorderSide(color: c.outlineVariant)),
                          ),
                          child: SingleChildScrollView(child: devices),
                        ),
                        Expanded(child: SingleChildScrollView(child: activity)),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onCompose});
  final VoidCallback onCompose;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final c = context.colors;
    final ready = remote.settings.isComplete && remote.devices.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: PageHeader(
        title: 'Remote',
        subtitle: Text(
          remote.settings.storeUrl.isEmpty
              ? 'Read and change confdb on devices through the Snap Store’s message service.'
              : 'Requests signed as ${context.aliased(remote.settings.account)} and sent through ${remote.settings.storeUrl}.',
        ),
        trailing: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SecondaryButton(label: 'Settings', icon: AppIcons.settings, onPressed: () => showRemoteSettingsDialog(context)),
            Tooltip(
              message: ready ? '' : (!remote.settings.isComplete ? 'Finish the settings first' : 'Add a device first'),
              child: PrimaryButton(label: 'New message', icon: AppIcons.add, onPressed: ready ? onCompose : null),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
    child: InlineMessage(
      kind: MessageKind.info,
      title: 'Connect to a message service',
      body: const Text(
        'Set the Store URL, the account that signs requests, how to get its token and the signing key. '
        'Devices act on requests signed by an account they’ve delegated the view to.',
      ),
      actions: [OnContainerButton(label: 'Open settings', icon: AppIcons.settings, onPressed: () => showRemoteSettingsDialog(context))],
    ),
  );
}

class _PollErrorBanner extends StatelessWidget {
  const _PollErrorBanner({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final gone = error is MessageServiceException && (error as MessageServiceException).sessionGone;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: InlineMessage(
        kind: MessageKind.error,
        title: gone ? 'The message session is gone' : 'Couldn’t check for answers',
        body: gone
            ? const Text('Requests devices hadn’t collected were dropped with it. A new session opens with the next message.')
            : CodeText('$error'),
        actions: [
          if (!gone) OnContainerButton(label: 'Retry', icon: AppIcons.retry, onPressed: remote.pollNow),
          if (error is ConfdbException && (error as ConfdbException).kind == ConfdbErrorKind.signedOut)
            OnContainerButton(label: 'Settings', icon: AppIcons.settings, onPressed: () => showRemoteSettingsDialog(context)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Devices

class _DevicePane extends StatelessWidget {
  const _DevicePane({required this.scope, required this.onScope});
  final DeviceScope scope;
  final ValueChanged<DeviceScope> onScope;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final c = context.colors;
    final devices = remote.devices;
    final byBrand = <String, Map<String, List<RemoteDevice>>>{};
    for (final d in devices) {
      byBrand.putIfAbsent(d.id.brand, () => {}).putIfAbsent(d.id.model, () => []).add(d);
    }
    final brands = byBrand.keys.toList()..sort((a, b) => context.aliased(a).compareTo(context.aliased(b)));

    Widget row({required DeviceScope target, required Widget child, required double indent, int? count, Widget? trailing}) {
      final selected = scope == target;
      return Material(
        color: selected ? c.secondaryContainer : Colors.transparent,
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: () => onScope(target),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16 + indent, 8, 8, 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(
                children: [
                  Expanded(child: child),
                  if (count != null) CountPill(count),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      );
    }

    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: SectionHeader(
            'Devices',
            action: IconButton(tooltip: 'Add device', icon: const Icon(AppIcons.add), onPressed: () => showDeviceDialog(context)),
          ),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No devices yet.', style: context.text.bodyMedium),
                const SizedBox(height: 4),
                Text('Add one by its ID (serial.model.brand), or paste its `snap known serial` output.', style: muted),
                const SizedBox(height: 12),
                SecondaryButton(label: 'Add device', icon: AppIcons.add, onPressed: () => showDeviceDialog(context)),
              ],
            ),
          )
        else ...[
          row(
            target: const DeviceScope(),
            indent: 0,
            count: devices.length,
            child: Text('All devices', style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          for (final brand in brands) ...[
            row(
              target: DeviceScope(brand: brand),
              indent: 0,
              count: byBrand[brand]!.values.fold<int>(0, (n, l) => n + l.length),
              child: Row(
                children: [
                  Icon(AppIcons.user, size: 16, color: c.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Flexible(
                    child: AccountName(brand, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            for (final model in byBrand[brand]!.keys.toList()..sort()) ...[
              row(
                target: DeviceScope(brand: brand, model: model),
                indent: 16,
                count: byBrand[brand]![model]!.length,
                child: Text(model, style: context.text.bodyMedium?.mono, overflow: TextOverflow.ellipsis),
              ),
              for (final d in byBrand[brand]![model]!)
                row(
                  target: DeviceScope(device: d.id.id),
                  indent: 32,
                  trailing: _DeviceMenu(device: d),
                  child: Row(
                    children: [
                      _DeviceDot(device: d.id.id),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(d.name, style: context.text.bodyMedium, overflow: TextOverflow.ellipsis),
                            if (d.label.isNotEmpty) Text(d.id.serial, style: muted?.mono, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

/// The device's latest answer, as a colored icon.
class _DeviceDot extends StatelessWidget {
  const _DeviceDot({required this.device});
  final String device;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final last = remote.requests.where((r) => r.devices.contains(device)).firstOrNull;
    final state = last?.stateOf(device, remote.now);
    final (kind, label) = state == null ? (StatusKind.neutral, 'No requests yet') : _deviceState(state);
    final (_, fg, icon) = StatusBadge.colorsFor(context, kind);
    return Tooltip(
      message: 'Latest: $label',
      child: Icon(
        state == DeviceRequestState.waiting ? Icons.schedule : icon,
        size: 16,
        color: kind == StatusKind.neutral ? context.colors.onSurfaceVariant : fg,
      ),
    );
  }
}

class _DeviceMenu extends StatelessWidget {
  const _DeviceMenu({required this.device});
  final RemoteDevice device;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Device actions',
    icon: const Icon(Icons.more_vert, size: 18),
    onSelected: (v) async {
      switch (v) {
        case 'rename':
          await showDeviceDialog(context, device: device);
        case 'copy':
          await Clipboard.setData(ClipboardData(text: device.id.id));
          if (context.mounted) showConfirmation(context, const Text('Device ID copied'));
        case 'remove':
          final ok = await confirmDestructive(
            context,
            title: Text('Remove ${device.name}?'),
            body: const Text('Its past requests stay in the activity. You can add it again later.'),
            action: 'Remove',
          );
          if (ok && context.mounted) await context.remote.removeDevice(device.id);
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'rename', child: Text('Rename…')),
      PopupMenuItem(value: 'copy', child: Text('Copy device ID')),
      PopupMenuItem(value: 'remove', child: Text('Remove')),
    ],
  );
}

// ----------------------------------------------------------------- Activity

class _ActivityPane extends StatelessWidget {
  const _ActivityPane({
    required this.scope,
    required this.schemas,
    required this.expanded,
    required this.onToggle,
    required this.onDuplicate,
    required this.onCompose,
  });

  final DeviceScope scope;
  final KnownSchemas schemas;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;
  final ValueChanged<RemoteRequest> onDuplicate;
  final VoidCallback onCompose;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final c = context.colors;
    final requests = [
      for (final r in remote.requests)
        if (r.devices.any(scope.matchesId)) r,
    ];
    final scopeLabel = _scopeLabel(context, scope);
    final finished = remote.requests.where((r) => !r.isWaitingAt(remote.now) && (r.sent || r.sendError != null)).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            'Activity',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SessionInfo(remote: remote),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Check for answers now',
                  onPressed: remote.session == null || remote.polling ? null : remote.pollNow,
                  icon: remote.polling
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(AppIcons.retry),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) async {
                    if (v == 'clear') await remote.clearFinished();
                    if (v == 'reset' && context.mounted) await _confirmReset(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'clear', enabled: finished > 0, child: const Text('Clear finished requests')),
                    PopupMenuItem(value: 'reset', enabled: remote.session != null, child: const Text('Start a new session…')),
                  ],
                ),
              ],
            ),
          ),
          if (scopeLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Showing requests for $scopeLabel', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            ),
          const SizedBox(height: 4),
          if (requests.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: EmptyState(
                icon: AppIcons.send,
                title: 'No requests yet',
                body: const Text('Send a get or set to one or more devices. Answers show up here once the devices next check in.'),
                actions: [
                  if (remote.settings.isComplete && remote.devices.isNotEmpty)
                    PrimaryButton(label: 'New message', icon: AppIcons.add, onPressed: onCompose),
                ],
              ),
            )
          else
            for (final r in requests) ...[
              _RequestCard(
                key: ValueKey(r.messageId),
                request: r,
                schemas: schemas,
                expanded: expanded.contains(r.messageId),
                onToggle: () => onToggle(r.messageId),
                onDuplicate: () => onDuplicate(r),
                scope: scope,
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final remote = context.remote;
    final ok = await confirmDestructive(
      context,
      title: const Text('Start a new session?'),
      body: const Text(
        'The current session is removed from the message service. Requests devices haven’t collected yet are dropped, '
        'and answers still on their way won’t arrive.',
      ),
      action: 'Start new session',
    );
    if (ok) await remote.resetSession();
  }
}

String? _scopeLabel(BuildContext context, DeviceScope s) {
  final remote = context.remote;
  if (s.device != null) return remote.device(s.device!)?.name ?? s.device;
  if (s.model != null) return 'model ${s.model}';
  if (s.brand != null) return 'brand ${context.aliased(s.brand!)}';
  return null;
}

class _SessionInfo extends StatelessWidget {
  const _SessionInfo({required this.remote});
  final RemoteController remote;

  @override
  Widget build(BuildContext context) {
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);
    final session = remote.session;
    final waiting = remote.waitingCount;
    final last = remote.lastPoll;
    final parts = [
      if (session == null) 'No session yet' else 'Session ${session.length > 8 ? '${session.substring(0, 8)}…' : session}',
      if (waiting > 0) '${plural(waiting, 'request')} waiting',
      if (last != null) 'checked ${_ago(last, remote.now)}',
    ];
    return Tooltip(
      message: session == null ? 'A session opens with the first message' : 'Session ID: $session',
      child: Text(parts.join(' · '), style: muted),
    );
  }
}

(StatusKind, String) _deviceState(DeviceRequestState s) => switch (s) {
  DeviceRequestState.sending => (StatusKind.running, 'Sending…'),
  DeviceRequestState.notSent => (StatusKind.error, 'Not sent'),
  DeviceRequestState.waiting => (StatusKind.secondary, 'Waiting for device'),
  DeviceRequestState.expired => (StatusKind.warning, 'Expired, no answer'),
  DeviceRequestState.success => (StatusKind.success, 'Success'),
  DeviceRequestState.error => (StatusKind.error, 'Failed on device'),
  DeviceRequestState.unauthorized => (StatusKind.error, 'Unauthorized'),
  DeviceRequestState.rejected => (StatusKind.error, 'Rejected'),
};

/// The request's overall state, e.g. "Waiting · 1 of 3 answered".
(StatusKind, String) requestSummary(RemoteRequest r, DateTime now) {
  final states = [for (final d in r.devices) r.stateOf(d, now)];
  final n = states.length;
  if (states.contains(DeviceRequestState.sending)) return (StatusKind.running, 'Sending…');
  if (states.contains(DeviceRequestState.notSent)) return (StatusKind.error, 'Not sent');
  final answered = r.responses.length;
  if (states.contains(DeviceRequestState.waiting)) {
    return (StatusKind.secondary, n == 1 ? 'Waiting for device' : 'Waiting · $answered of $n answered');
  }
  final failed = states.where((s) => s.isFailure).length;
  if (failed == 0) return (StatusKind.success, n == 1 ? 'Success' : 'All $n succeeded');
  if (n == 1) return _deviceState(states.single);
  if (states.every((s) => s == DeviceRequestState.expired)) return (StatusKind.warning, 'Expired, no answers');
  return (failed == n ? StatusKind.error : StatusKind.warning, '$failed of $n failed');
}

String _ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inSeconds < 10) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds}s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    super.key,
    required this.request,
    required this.schemas,
    required this.expanded,
    required this.onToggle,
    required this.onDuplicate,
    required this.scope,
  });

  final RemoteRequest request;
  final KnownSchemas schemas;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onDuplicate;
  final DeviceScope scope;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final r = request;
    final c = context.colors;
    final now = remote.now;
    final (kind, label) = requestSummary(r, now);
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final targets = r.devices.length == 1
        ? (remote.device(r.devices.single)?.name ?? r.devices.single)
        : plural(r.devices.length, 'device');
    final masker = schemas.masker(r.view);
    final detail = switch (r.action) {
      RemoteAction.get => r.keys.isEmpty ? 'all keys' : r.keys.join(', '),
      RemoteAction.set => [for (final e in r.values.entries) '${e.key} = ${masker.show(e.key, e.value, revealUnknown: true)}'].join(', '),
    };
    final hasFailures = r.devices.any((d) => r.stateOf(d, now).isFailure);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListRow(
            first: true,
            onTap: onToggle,
            semanticLabel: '${r.action.name} ${r.view}, $label',
            child: Row(
              children: [
                _ActionChip(r.action),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.aliased(r.view), style: context.text.bodyMedium?.mono, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text('$detail  →  $targets', style: muted?.mono, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StatusBadge(kind: kind, label: label),
                const SizedBox(width: 12),
                Tooltip(
                  message: r.created.toLocal().toString(),
                  child: Text(_ago(r.created, now), style: muted),
                ),
                Icon(expanded ? AppIcons.collapse : AppIcons.expand, color: c.onSurfaceVariant),
              ],
            ),
          ),
          if (expanded) ...[
            if (r.sendError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: InlineMessage(
                  kind: MessageKind.error,
                  padding: const EdgeInsets.all(12),
                  title: 'The message service didn’t take this request',
                  body: CodeText(r.sendError!),
                ),
              ),
            for (final d in r.devices)
              if (scope.matchesId(d)) _DeviceAnswer(request: r, device: d, masker: masker),
            ListRow(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (hasFailures)
                    SecondaryButton(
                      label: 'Retry failed',
                      icon: AppIcons.retry,
                      onPressed: remote.settings.isComplete ? () => _retry(context) : null,
                    ),
                  TertiaryButton(label: 'Duplicate', icon: AppIcons.copy, onPressed: remote.settings.isComplete ? onDuplicate : null),
                  TertiaryButton(label: 'Delete', icon: AppIcons.delete, onPressed: () => remote.deleteRequest(r.messageId)),
                  Text('ID ${r.messageId} · valid until ${_clock(r.validUntil)}', style: muted?.mono),
                ],
              ),
            ),
            if (r.assertion != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: CliDisclosure(_maskAssertion(r, masker), label: 'Signed request'),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _retry(BuildContext context) async {
    try {
      await context.remote.retryFailed(request);
    } on ConfdbException catch (e) {
      if (context.mounted) showConfirmation(context, Text('Couldn’t retry: ${e.message}'), kind: MessageKind.error);
    }
  }
}

String _clock(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

/// The signed request with secret values in its body replaced, for display.
String _maskAssertion(RemoteRequest r, ValueMasker masker) {
  if (r.action != RemoteAction.set || r.values.keys.every((k) => !masker.isSecret(k))) return r.assertion!;
  final masked = jsonEncode({for (final e in r.values.entries) e.key: masker.isSecret(e.key) ? '••••••' : e.value});
  final raw = jsonEncode(r.values);
  return r.assertion!.replaceAll(raw.substring(1, raw.length - 1), masked.substring(1, masked.length - 1));
}

class _ActionChip extends StatelessWidget {
  const _ActionChip(this.action);
  final RemoteAction action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final set = action == RemoteAction.set;
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: set ? c.tertiaryContainer : c.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
      child: Text(
        action.name.toUpperCase(),
        style: context.text.labelSmall?.mono.copyWith(color: set ? c.onTertiaryContainer : c.onSurfaceVariant, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _DeviceAnswer extends StatefulWidget {
  const _DeviceAnswer({required this.request, required this.device, required this.masker});
  final RemoteRequest request;
  final String device;
  final ValueMasker masker;

  @override
  State<_DeviceAnswer> createState() => _DeviceAnswerState();
}

class _DeviceAnswerState extends State<_DeviceAnswer> {
  bool _reveal = false;

  @override
  Widget build(BuildContext context) {
    final remote = context.remote;
    final r = widget.request;
    final c = context.colors;
    final state = r.stateOf(widget.device, remote.now);
    final (kind, label) = _deviceState(state);
    final response = r.responses[widget.device];
    final dev = remote.device(widget.device);
    final muted = context.text.bodySmall?.copyWith(color: c.onSurfaceVariant);
    final values = response?.values;
    final masker = widget.masker;
    final unknown = !masker.knowsSchema && values != null && values.isNotEmpty;

    return ListRow(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dev?.name ?? widget.device, style: context.text.bodyMedium),
                    Text(widget.device, style: muted?.mono, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (response?.timestamp != null) ...[Text(_ago(response!.timestamp!, remote.now), style: muted), const SizedBox(width: 12)],
              StatusBadge(kind: kind, label: label),
            ],
          ),
          if (response?.message case final m?) ...[
            const SizedBox(height: 8),
            CodeText(m, style: context.text.bodySmall?.copyWith(color: state == DeviceRequestState.success ? null : c.error)),
          ],
          if (state == DeviceRequestState.unauthorized) _DelegationHint(request: r, device: widget.device),
          if (state == DeviceRequestState.expired)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The device didn’t collect this before it expired. Check it’s online, has remote device management enabled, '
                'and run `snap changes` on it for failed exchanges.',
                style: muted,
              ),
            ),
          if (values != null && values.isNotEmpty) ...[
            const SizedBox(height: 8),
            if (unknown)
              Row(
                children: [
                  Expanded(child: Text('Studio doesn’t have this schema, so it can’t tell which values are secret.', style: muted)),
                  TertiaryButton(
                    label: _reveal ? 'Hide values' : 'Show values',
                    icon: _reveal ? AppIcons.eyeOff : AppIcons.eye,
                    onPressed: () => setState(() => _reveal = !_reveal),
                  ),
                ],
              ),
            _ValuesTable(values: values, masker: masker, revealUnknown: _reveal),
          ],
        ],
      ),
    );
  }
}

class _ValuesTable extends StatelessWidget {
  const _ValuesTable({required this.values, required this.masker, required this.revealUnknown});
  final Map<String, Object?> values;
  final ValueMasker masker;
  final bool revealUnknown;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = flattenValues(values);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (path, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 220, child: SelectableText(path, style: context.text.bodySmall?.mono)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: masker.isSecret(path)
                        ? Row(
                            children: [
                              Icon(AppIcons.lock, size: 14, color: c.onSurfaceVariant),
                              const SizedBox(width: 6),
                              Text('secret, hidden', style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                            ],
                          )
                        : SelectableText(masker.show(path, value, revealUnknown: revealUnknown), style: context.text.bodySmall?.mono),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DelegationHint extends StatelessWidget {
  const _DelegationHint({required this.request, required this.device});
  final RemoteRequest request;
  final String device;

  @override
  Widget build(BuildContext context) {
    final account = context.remote.settings.account;
    final body = jsonEncode({
      'action': 'delegate',
      'operator-id': account,
      'authentications': ['operator-key'],
      'views': [request.view],
    });
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InlineMessage(
        kind: MessageKind.warning,
        padding: const EdgeInsets.all(12),
        title: 'The device hasn’t delegated ${context.aliased(request.view)} to ${context.aliased(account)}',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'On the device, with remote device management enabled, delegate the view to this account '
              'with operator-key authentication, then retry.',
            ),
            const SizedBox(height: 8),
            CliDisclosure(
              "sudo snap set system experimental.remote-device-management=true remote-device-management.enabled=true\n"
              "echo '$body' | sudo snap debug api -X POST -H 'Content-Type: application/json' /v2/confdb",
              label: 'Commands to run on the device',
            ),
          ],
        ),
      ),
    );
  }
}
