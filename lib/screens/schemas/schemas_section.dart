import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/analysis.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../util/format.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/domain_badges.dart';
import '../../widgets/fields.dart';
import '../../widgets/status_badge.dart';
import '../access/custodian_guide.dart';
import '../../state/account_names.dart';
import '../../widgets/account_name.dart';
import '../../domain/store_sync.dart';
import '../../state/store_controller.dart';
import '../../widgets/code_text.dart';
import '../../widgets/cli_disclosure.dart';
import '../store/store_login_dialog.dart';

/// What the schemas section shows: acknowledged schemas, local drafts, and
/// the snaps plugging them (for custodians).
class SchemasData {
  const SchemasData(this.schemas, this.drafts, this.snaps);
  final List<ConfdbSchema> schemas;
  final List<ConfdbSchema> drafts;
  final List<SnapInfo> snaps;
}

/// Picks an assertion or JSON draft and imports it, then opens the editor.
Future<void> importSchemaFromDisk(BuildContext context) async {
  final scope = context.scope;
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Schemas', extensions: ['assert', 'json']),
      XTypeGroup(label: 'All files'),
    ],
  );
  if (file == null) return;
  try {
    final draft = await scope.repository.importSchema(file.path);
    scope.app.go(SchemaEditorRoute(draft.id));
  } catch (e) {
    if (context.mounted) showConfirmation(context, Text('Couldn’t import ${file.name}: $e'));
  }
}

/// The schemas table on the overview (was 7.3 Schemas, SchemasList.dc.html):
/// search and filters, the Snap Store state, and per-schema actions. Shows a
/// skeleton while [data] is null.
class SchemasSection extends StatefulWidget {
  const SchemasSection({super.key, required this.data});
  final SchemasData? data;

  @override
  State<SchemasSection> createState() => _SchemasSectionState();
}

class _SchemasSectionState extends State<SchemasSection> {
  final _search = TextEditingController();
  bool _problems = false;
  bool _draftsOnly = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return ListenableBuilder(
      listenable: context.store,
      builder: (context, _) => Semantics(
        container: true,
        label: 'Schemas',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            const SizedBox(height: 16),
            _toolbar(context, data),
            const SizedBox(height: 16),
            if (data == null)
              const TableSkeleton(message: 'Loading schemas from snapd…', columns: [3, 5, 1, 2, 2], rows: [0.7, 0.55, 0.4, 0.65, 0.5])
            else ...[
              if (_storeMessage(context) case final message?) ...[message, const SizedBox(height: 16)],
              _body(context, data),
            ],
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, SchemasData? data) {
    final c = context.colors;
    final withProblems = data == null ? 0 : _merged(data).where((s) => lintSchema(s).isNotEmpty).length;
    final drafts = data?.drafts.length ?? 0;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                controller: _search,
                enabled: data != null,
                decoration: const InputDecoration(
                  hintText: 'Search schemas',
                  prefixIcon: Icon(AppIcons.search),
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            FilterChip(
              mouseCursor: WidgetStateMouseCursor.clickable,
              avatar: Icon(AppIcons.warning, size: 18, color: c.onSurfaceVariant),
              label: Text('Has problems · $withProblems'),
              selected: _problems,
              onSelected: data == null ? null : (v) => setState(() => _problems = v),
            ),
            FilterChip(
              mouseCursor: WidgetStateMouseCursor.clickable,
              avatar: Icon(AppIcons.edit, size: 18, color: c.onSurfaceVariant),
              label: Text('Drafts · $drafts'),
              selected: _draftsOnly,
              onSelected: data == null ? null : (v) => setState(() => _draftsOnly = v),
            ),
          ],
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (context.store.signedIn)
              SecondaryButton(
                label: 'Refresh Store',
                icon: AppIcons.retry,
                busy: context.store.loading,
                onPressed: context.store.reloadSchemas,
              ),
            SecondaryButton(label: 'Import', icon: AppIcons.upload, onPressed: () => importSchemaFromDisk(context)),
          ],
        ),
      ],
    );
  }

  /// Why the Snap Store column is empty: signed out, or the Store failed.
  Widget? _storeMessage(BuildContext context) {
    final store = context.store;
    final session = store.session;
    if (session != null && !session.signedIn) {
      return InlineMessage(
        kind: MessageKind.info,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        title: 'Not signed in to the Snap Store',
        body: CodeText(
          session.detail ?? 'Sign in to see the schemas registered to your account, install them here, and push new revisions.',
        ),
        actions: [OnContainerButton(label: 'Sign in', icon: AppIcons.signIn, onPressed: () => showStoreLoginDialog(context))],
      );
    }
    if (store.error != null && store.schemas == null) {
      return InlineMessage(
        kind: MessageKind.warning,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        title: 'Couldn’t load schemas from the Snap Store',
        body: CodeText('${store.error} Schemas on this device are shown.'),
        actions: [OnContainerButton(label: 'Retry', icon: AppIcons.retry, onPressed: store.reloadSchemas)],
      );
    }
    return null;
  }

  /// Acknowledged schemas, with drafts of new schemas and schemas only in
  /// the Snap Store appended.
  List<ConfdbSchema> _merged(SchemasData d) {
    final local = [
      ...d.schemas,
      for (final draft in d.drafts)
        if (!d.schemas.any((s) => s.id == draft.id)) draft,
    ];
    return [
      ...local,
      for (final s in context.store.schemas ?? const <ConfdbSchema>[])
        if (!local.any((l) => l.id == s.id)) s,
    ];
  }

  Widget _body(BuildContext context, SchemasData data) {
    final app = context.app;
    final all = _merged(data);
    if (all.isEmpty) {
      return EmptyState(
        icon: AppIcons.schemas,
        title: 'No schemas yet',
        body: const Text(
          'A schema defines the typed settings snaps can read and write. Import a signed assertion, or create one from a template.',
        ),
        actions: [
          SecondaryButton(label: 'Import', icon: AppIcons.upload, onPressed: () => importSchemaFromDisk(context)),
          PrimaryButton(label: 'Create schema', icon: AppIcons.add, onPressed: () => app.go(const OnboardingRoute(choose: true))),
        ],
        command: 'sudo snap ack network.assert',
      );
    }
    final q = _search.text.trim().toLowerCase();
    final draftIds = {for (final d in data.drafts) d.id};
    final shown = all.where((s) {
      if (q.isNotEmpty && !s.id.path.toLowerCase().contains(q) && !s.summary.toLowerCase().contains(q)) return false;
      if (_draftsOnly && !draftIds.contains(s.id)) return false;
      if (_problems && lintSchema(data.drafts.where((d) => d.id == s.id).firstOrNull ?? s).isEmpty) return false;
      return true;
    }).toList();
    if (shown.isEmpty) {
      return EmptyState(
        icon: AppIcons.search,
        title: 'No schemas match',
        body: Text('${plural(all.length, 'schema')} in total.'),
        actions: [
          SecondaryButton(
            label: 'Clear filters',
            onPressed: () => setState(() {
              _search.clear();
              _problems = _draftsOnly = false;
            }),
          ),
        ],
      );
    }
    final groups = <String, List<ConfdbSchema>>{};
    for (final s in shown) {
      groups.putIfAbsent(s.id.account, () => []).add(s);
    }
    return _SchemaTable(groups: groups, data: data, store: context.store);
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Schemas', style: context.text.titleLarge),
      const SizedBox(height: 4),
      Text(
        'Signed confdb-schema assertions on this device and in the Snap Store, and your local drafts.',
        style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    ],
  );
}

class _SchemaTable extends StatefulWidget {
  const _SchemaTable({required this.groups, required this.data, required this.store});
  final Map<String, List<ConfdbSchema>> groups;
  final SchemasData data;
  final StoreController store;

  @override
  State<_SchemaTable> createState() => _SchemaTableState();
}

class _SchemaTableState extends State<_SchemaTable> {
  final _collapsed = <String>{};

  SchemasData get data => widget.data;
  StoreController get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final c = context.colors;
    final head = tableHeaderStyle(context);
    Widget cells(List<Widget> w) => Row(
      children: [
        Expanded(flex: 10, child: w[0]),
        const SizedBox(width: 16),
        Expanded(flex: 16, child: w[1]),
        const SizedBox(width: 16),
        SizedBox(width: 80, child: w[2]),
        const SizedBox(width: 16),
        Expanded(flex: 10, child: w[3]),
        const SizedBox(width: 16),
        Expanded(flex: 12, child: w[4]),
        const SizedBox(width: 16),
        SizedBox(width: 150, child: w[5]),
        const SizedBox(width: 16),
        Expanded(flex: 10, child: w[6]),
        const SizedBox(width: 16),
        // Untitled: a badge when a signed schema has unsigned draft changes.
        SizedBox(width: 132, child: w[7]),
        SizedBox(width: 40, child: w[8]),
      ],
    );

    return Semantics(
      label: 'Schemas by account',
      container: true,
      child: SectionCard(
        child: MinWidthScroll(
          minWidth: 1180,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outlineVariant)),
                ),
                child: cells([
                  for (final h in ['Name', 'Summary', 'Revision', 'Custodian', 'Signature', 'Snap Store', 'Lint']) Text(h, style: head),
                  const SizedBox.shrink(),
                  const SizedBox.shrink(),
                ]),
              ),
              for (final g in groups.entries) ...[
                InkWell(
                  onTap: () => setState(() {
                    if (!_collapsed.add(g.key)) _collapsed.remove(g.key);
                  }),
                  child: GroupHeaderRow(
                    minHeight: 40,
                    child: Row(
                      children: [
                        Semantics(
                          button: true,
                          label: '${_collapsed.contains(g.key) ? 'Expand' : 'Collapse'} ${g.key}',
                          excludeSemantics: true,
                          child: Icon(
                            _collapsed.contains(g.key) ? AppIcons.chevronRight : AppIcons.expand,
                            size: 18,
                            color: c.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                        AccountName(g.key, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Text(
                          g.value.every((s) => s.builtIn)
                              ? '${plural(g.value.length, 'schema')} · built-in, read-only'
                              : plural(g.value.length, 'schema'),
                          style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!_collapsed.contains(g.key)) for (final s in g.value) _row(context, s, cells),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ConfdbSchema s, Widget Function(List<Widget>) cells) {
    final c = context.colors;
    final draft = data.drafts.where((d) => d.id == s.id).firstOrNull;
    final device = data.schemas.where((d) => d.id == s.id).firstOrNull;
    // Listed only because the Snap Store has it.
    final storeOnly = device == null && draft == null;
    final linted = draft ?? s;
    final custodians = custodiansOf(s.id, data.snaps);
    // A draft of a new schema is already marked "Local draft" under Signature.
    final changes = draft == null || s.revision == null ? 0 : diffSchemas(s, draft).length;
    final open = s.builtIn || storeOnly ? null : () => context.app.go(SchemaEditorRoute(s.id));
    final inStore = store.schema(s.id);
    final sync = store.compare(s.id, device);
    final busy = store.busy(s.id);
    final canPush =
        store.signedIn &&
        !busy &&
        device?.revision != null &&
        const {StoreSync.notInStore, StoreSync.deviceNewer, StoreSync.differs}.contains(sync);
    final canInstall = store.signedIn && !busy && const {StoreSync.storeOnly, StoreSync.storeNewer, StoreSync.differs}.contains(sync);
    final canOpenDraft = canInstall && draft == null && inStore != null;
    final actions = <PopupMenuEntry<void>>[
      if (canInstall)
        _menuItem(
          icon: AppIcons.pull,
          label: inStore?.revision == null ? 'Install from Store' : 'Install rev ${inStore!.revision} from Store',
          onTap: () => _install(context, s.id, device, inStore),
        ),
      if (canOpenDraft)
        _menuItem(icon: AppIcons.edit, label: 'Open Store revision as draft', onTap: () => _openDraft(context, inStore, device)),
      if (canPush) _menuItem(icon: AppIcons.push, label: 'Push rev ${device!.revision} to Store', onTap: () => _push(context, device)),
      if (draft != null) ...[
        if (canInstall || canPush) const PopupMenuDivider(),
        PopupMenuItem(
          onTap: () => _discard(context, draft),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(AppIcons.delete, color: c.error),
            title: Text(draft.baseRevision == null ? 'Delete draft' : 'Discard draft'),
          ),
        ),
      ],
    ];
    return Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: cells([
        Align(
          alignment: Alignment.centerLeft,
          child: open == null
              ? Text(s.id.name, style: context.text.bodyMedium?.mono.copyWith(fontWeight: FontWeight.w500))
              : TextButton(
                  onPressed: open,
                  style: TextButton.styleFrom(
                    foregroundColor: c.onSurface,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 40),
                    textStyle: context.text.bodyMedium?.mono.copyWith(
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                      decorationColor: c.outlineVariant,
                    ),
                  ),
                  child: Text(s.id.name),
                ),
        ),
        Text(s.summary, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
        Text(
          s.builtIn
              ? 'built-in'
              : s.revision != null
              ? 'rev ${s.revision}'
              : storeOnly
              ? '—'
              : 'draft',
          style: context.text.bodyMedium?.mono,
        ),
        if (storeOnly)
          // Custodians are snaps on this device; the schema isn't here yet.
          Tooltip(
            message: 'Not installed on this device',
            child: Text('—', style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
          )
        else if (!s.builtIn && custodians.isNotEmpty)
          Text(custodians.map((p) => p.snap).toSet().join(', '), style: context.text.bodyMedium?.mono)
        else
          Align(
            alignment: Alignment.centerLeft,
            child: CustodianBadge(schema: draft ?? s, snaps: data.snaps, short: true),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (s.builtIn)
              const StatusBadge.neutral('Built-in', icon: AppIcons.lock)
            else if (s.revision != null || storeOnly)
              const StatusBadge.success('Signed', icon: AppIcons.verified)
            else
              // Only a draft so far: nothing signed yet.
              const StatusBadge.info('Local draft', icon: AppIcons.edit),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _storeCell(context, s, device, inStore, sync, onPush: canPush ? () => _push(context, device!) : null),
        ),
        Align(alignment: Alignment.centerLeft, child: lintBadge(lintSchema(linted))),
        if (changes == 0)
          const SizedBox.shrink()
        else
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: '${plural(changes, 'change')} not signed yet',
              child: const StatusBadge.info('Draft changes', icon: AppIcons.edit),
            ),
          ),
        if (actions.isEmpty)
          const SizedBox.shrink()
        else
          PopupMenuButton<void>(
            tooltip: 'Actions for ${context.aliased(s.id.path)}',
            icon: const Icon(Icons.more_vert),
            itemBuilder: (_) => actions,
          ),
      ]),
    );
  }

  PopupMenuItem<void> _menuItem({required IconData icon, required String label, required VoidCallback onTap}) => PopupMenuItem(
    onTap: onTap,
    child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(icon), title: Text(label)),
  );

  /// The Snap Store column: how this device's revision compares with the Store's.
  /// [onPush] makes "Not in Store" a button that offers to push.
  Widget _storeCell(
    BuildContext context,
    ConfdbSchema s,
    ConfdbSchema? device,
    ConfdbSchema? inStore,
    StoreSync sync, {
    VoidCallback? onPush,
  }) {
    final c = context.colors;
    final muted = context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant);
    Widget tip(String message, Widget child) => Tooltip(message: message, child: child);
    if (s.builtIn) return const SizedBox.shrink();
    if (!store.signedIn) return tip('Not signed in to the Snap Store', Text('—', style: muted));
    if (store.busy(s.id)) {
      return Row(
        children: [
          SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.secondary)),
          const SizedBox(width: 8),
          Text('Working…', style: muted),
        ],
      );
    }
    if (store.schemas == null) {
      return store.loading ? Text('Checking…', style: muted) : tip('${store.error ?? 'Not loaded'}', Text('—', style: muted));
    }
    final theirs = inStore?.revision;
    final ours = device?.revision;
    return switch (sync) {
      StoreSync.unknown => const SizedBox.shrink(),
      StoreSync.inSync => tip(
        'The Snap Store has the same revision as this device.',
        StatusBadge.success(theirs == null ? 'In Store' : 'In Store · rev $theirs', icon: AppIcons.storeSynced),
      ),
      StoreSync.notInStore =>
        onPush == null
            ? tip(
                'Signed on this device only. Push it to register it in the Snap Store.',
                const StatusBadge.neutral('Not in Store', icon: AppIcons.storeOff),
              )
            : tip(
                'Signed on this device only. Click to push it to the Snap Store.',
                Semantics(
                  button: true,
                  child: InkWell(
                    onTap: onPush,
                    mouseCursor: WidgetStateMouseCursor.clickable,
                    borderRadius: BorderRadius.circular(ConfdbRadii.chip),
                    child: const StatusBadge.neutral('Not in Store', icon: AppIcons.storeOff),
                  ),
                ),
              ),
      StoreSync.storeOnly => tip(
        'Registered in the Snap Store, not installed on this device.',
        const StatusBadge.info('Only in Store', icon: AppIcons.store),
      ),
      StoreSync.storeNewer => tip(
        'The Snap Store has revision $theirs; this device has revision $ours.',
        StatusBadge.info('Rev $theirs in Store', icon: AppIcons.pull),
      ),
      StoreSync.deviceNewer => tip(
        'This device has revision $ours; the Snap Store has revision $theirs. Push it to update the Store.',
        StatusBadge.warning('Store has rev $theirs', icon: AppIcons.push),
      ),
      StoreSync.differs => tip(
        'The Snap Store’s latest revision differs from the one on this device.',
        const StatusBadge.warning('Differs from Store', icon: AppIcons.store),
      ),
    };
  }

  Future<void> _push(BuildContext context, ConfdbSchema device) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = context.aliased(device.id.path);
    final ok = await confirmAction(
      context,
      title: CodeText('Push `$path` rev ${device.revision} to the Snap Store?'),
      action: 'Push to Store',
      body: const Text(
        'The Store registers the signed assertion acknowledged on this device. Registered revisions can’t be removed; '
        'later changes need a new revision.',
      ),
    );
    if (!ok) return;
    try {
      await store.push(device.id);
      showToast(messenger, CodeText('Pushed `$path` rev ${device.revision} to the Snap Store'));
    } catch (e) {
      if (context.mounted) await _failed(context, 'Couldn’t push `$path`', e);
    }
  }

  Future<void> _install(BuildContext context, SchemaId id, ConfdbSchema? device, ConfdbSchema? inStore) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = context.aliased(id.path);
    final rev = inStore?.revision == null ? 'the Store’s latest revision' : 'revision ${inStore!.revision}';
    final ok = await confirmAction(
      context,
      title: CodeText('Install `$path` from the Snap Store?'),
      action: 'Install',
      body: Text(
        device?.revision == null
            ? 'snapd fetches $rev and acknowledges it, so snaps on this device can plug its views.'
            : 'snapd fetches $rev and acknowledges it. It replaces revision ${device!.revision} for all connected snaps.',
      ),
    );
    if (!ok) return;
    try {
      await store.install(id);
      showToast(messenger, CodeText('Installed `$path` from the Snap Store'));
    } catch (e) {
      if (context.mounted) await _failed(context, 'Couldn’t install `$path`', e);
    }
  }

  /// Starts a draft from the Store's revision, to edit and sign here.
  Future<void> _openDraft(BuildContext context, ConfdbSchema inStore, ConfdbSchema? device) async {
    final app = context.app;
    await context.repo.saveDraft(
      ConfdbSchema(
        id: inStore.id,
        summary: inStore.summary,
        views: inStore.views,
        storage: inStore.storage,
        isDraft: true,
        baseRevision: device?.revision,
      ),
    );
    app.go(SchemaEditorRoute(inStore.id));
  }

  Future<void> _failed(BuildContext context, String title, Object e) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: CodeText(title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CodeText('$e'),
            if (e case ConfdbException(:final command?)) ...[const SizedBox(height: 12), CliDisclosure(command, initiallyOpen: true)],
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );

  /// Drops the local draft. Signed revisions stay: snapd can't remove them.
  Future<void> _discard(BuildContext context, ConfdbSchema draft) async {
    final repo = context.repo;
    final isNew = draft.baseRevision == null;
    final ok = await confirmDestructive(
      context,
      title: Text(context.aliased(isNew ? 'Delete draft ${draft.id.path}?' : 'Discard draft of ${draft.id.path}?')),
      action: isNew ? 'Delete draft' : 'Discard draft',
      body: Text(
        isNew && store.schema(draft.id) != null
            ? 'Unsigned changes are lost. The Snap Store’s revision stays.'
            : isNew
            ? 'It was never signed, so it exists only as this local draft. This can’t be undone.'
            : 'Unsigned changes are lost. Revision ${draft.baseRevision} stays acknowledged on this device.',
      ),
    );
    if (!ok) return;
    await repo.discardDraft(draft.id);
    if (context.mounted) {
      showConfirmation(context, Text(context.aliased(isNew ? 'Deleted draft ${draft.id.path}' : 'Discarded draft of ${draft.id.path}')));
    }
  }
}
