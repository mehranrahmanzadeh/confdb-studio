import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../domain/templates.dart';
import '../../state/app_controller.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../../theme/confdb_theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/cli_disclosure.dart';
import '../../widgets/code_text.dart';
import '../../widgets/common.dart';
import '../schemas/schemas_section.dart';
import '../schema_editor/naming_conventions_dialog.dart';
import '../../state/account_names.dart';
import '../../widgets/account_name.dart';

/// 7.1 Onboarding (Onboarding.dc.html, Onboarding-Choose).
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.route});
  final OnboardingRoute route;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
    child: Center(child: route.choose ? _Choose(justEnabled: route.justEnabled) : const _Enable()),
  );
}

class _Enable extends StatefulWidget {
  const _Enable();

  @override
  State<_Enable> createState() => _EnableState();
}

class _EnableState extends State<_Enable> {
  bool _busy = false;
  Object? _error;

  Future<void> _enable() async {
    final scope = context.scope;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scope.repository.enableConfdb();
      scope.app.go(const OnboardingRoute(choose: true, justEnabled: true));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(ConfdbRadii.card)),
            child: Icon(AppIcons.data, color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Semantics(header: true, child: Text('Confdb is not enabled on this system', style: context.text.headlineMedium)),
          const SizedBox(height: 16),
          Text(
            'Confdb is snapd’s experimental configuration database. Snaps read and write typed settings through views, defined in signed schemas.',
            style: context.text.bodyLarge?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          PrimaryButton(
            label: _busy ? 'Waiting for authentication…' : 'Enable confdb',
            icon: AppIcons.shield,
            busy: _busy,
            onPressed: _enable,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(AppIcons.lock, size: 16, color: c.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'You’ll be asked to authenticate as an administrator.',
                style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            InlineMessage(
              kind: MessageKind.error,
              title: 'Couldn’t enable confdb',
              body: CodeText('$_error'),
              padding: const EdgeInsets.all(12),
            ),
          ],
          const SizedBox(height: 16),
          const CliDisclosure('sudo snap set system experimental.confdb=true', initiallyOpen: true),
        ],
      ),
    );
  }
}

final _schemaName = RegExp(r'^[a-z0-9](-?[a-z0-9])*$');

/// Default schema name per template; templates without one (e.g. the
/// minimal key/value starting point) leave the name for the user to fill in.
const _defaultNames = {'wifi': 'network'};

class _Choose extends StatefulWidget {
  const _Choose({required this.justEnabled});
  final bool justEnabled;

  @override
  State<_Choose> createState() => _ChooseState();
}

class _ChooseState extends State<_Choose> {
  bool _import = false;
  String _template = 'wifi';
  final _name = TextEditingController(text: _defaultNames['wifi']);
  final _account = TextEditingController();
  bool _nameEdited = false;
  late final _summary = TextEditingController(text: _templateSummary(_template));
  bool _summaryEdited = false;
  Set<SchemaId> _taken = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (context.app.accountKnown) _account.text = context.app.account;
    _name.addListener(() => setState(() {}));
    _loadTaken();
  }

  Future<void> _loadTaken() async {
    final repo = context.repo;
    try {
      final r = await Future.wait([repo.listSchemas(), repo.listDrafts()]);
      if (mounted) {
        setState(
          () => _taken = {
            for (final s in [...r[0], ...r[1]]) s.id,
          },
        );
      }
    } catch (_) {
      // Checked again by snapd on acknowledge.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _summary.dispose();
    _account.dispose();
    super.dispose();
  }

  /// Prefilled summary per template; blank for templates without a default
  /// name (e.g. the minimal key/value starting point), for the user to fill in.
  static String _templateSummary(String id) =>
      _defaultNames.containsKey(id) ? schemaTemplates.firstWhere((t) => t.id == id).build(const SchemaId('', '')).summary : '';

  String? _nameError(String account) {
    final n = _name.text.trim();
    if (n.isEmpty) return 'Enter a name';
    if (!_schemaName.hasMatch(n)) return 'Use lowercase letters, digits and single dashes';
    if (_taken.contains(SchemaId(account, n))) return '$account/$n already exists; open it from Schemas';
    return null;
  }

  Future<void> _open(String account) async {
    if (_import) {
      await importSchemaFromDisk(context);
      return;
    }
    if (_nameError(account) != null) return;
    final scope = context.scope;
    setState(() => _busy = true);
    final template = schemaTemplates.firstWhere((t) => t.id == _template);
    final draft = template.build(SchemaId(account, _name.text.trim())).copyWith(summary: _summary.text.trim());
    try {
      await scope.repository.saveDraft(draft);
      scope.app.go(SchemaEditorRoute(draft.id));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showConfirmation(context, Text('Couldn’t create the draft: $e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = context.app;
    final account = app.accountKnown ? app.account : _account.text.trim();
    final error = account.isEmpty ? 'Enter your developer account ID first' : _nameError(account);

    Widget option({
      required bool isImport,
      required IconData icon,
      required String title,
      required String body,
      List<Widget> children = const [],
    }) {
      final selected = _import == isImport;
      void onTap() => setState(() => _import = isImport);
      return Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: Material(
          color: c.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ConfdbRadii.card),
            side: BorderSide(color: selected ? c.primary : c.outlineVariant, width: selected ? 2 : 1),
          ),
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: onTap,
            borderRadius: BorderRadius.circular(ConfdbRadii.card),
            child: Padding(
              padding: EdgeInsets.all(selected ? 15 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Radio<bool>(value: isImport),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(icon, size: 20, color: c.onSurfaceVariant),
                                  const SizedBox(width: 8),
                                  Flexible(child: Text(title, style: context.text.titleMedium)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(body, style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      );
    }

    final templates = Padding(
      padding: const EdgeInsets.only(left: 32, top: 12),
      child: Semantics(
        label: 'Template',
        container: true,
        child: RadioGroup<String>(
          groupValue: _import ? null : _template,
          onChanged: (v) => setState(() {
            if (v == null) return;
            _import = false;
            _template = v;
            if (!_nameEdited) _name.text = _defaultNames[v] ?? '';
            if (!_summaryEdited) _summary.text = _templateSummary(v);
          }),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  'Template',
                  style: context.text.labelMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.5, color: c.onSurfaceVariant),
                ),
              ),
              for (final t in schemaTemplates)
                Material(
                  color: t.id == _template && !_import ? c.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(ConfdbRadii.card),
                  child: InkWell(
                    mouseCursor: WidgetStateMouseCursor.clickable,
                    borderRadius: BorderRadius.circular(ConfdbRadii.card),
                    onTap: () => setState(() {
                      _import = false;
                      _template = t.id;
                      if (!_nameEdited) _name.text = _defaultNames[t.id] ?? '';
                      if (!_summaryEdited) _summary.text = _templateSummary(t.id);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Radio<String>(value: t.id),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6, bottom: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.label,
                                    style: context.text.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: t.id == _template && !_import ? c.onPrimaryContainer : c.onSurface,
                                    ),
                                  ),
                                  Text(
                                    t.paths,
                                    style: context.text.bodySmall?.mono.copyWith(
                                      color: t.id == _template && !_import ? c.onPrimaryContainer : c.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.justEnabled) ...[
            InlineMessage(
              kind: MessageKind.success,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              title: 'Confdb enabled.',
              body: const CodeText('`experimental.confdb=true` is now set for this system.'),
            ),
            const SizedBox(height: 20),
          ],
          Semantics(
            header: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(widget.justEnabled ? 'Set up your first schema' : 'Create a schema', style: context.text.headlineMedium),
                const SizedBox(width: 4),
                const NamingConventionsButton(),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A schema defines the storage tree and the views snaps use to reach it. You can change both in the editor.',
            style: context.text.bodyLarge?.copyWith(color: c.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          RadioGroup<bool>(
            groupValue: _import,
            onChanged: (v) => setState(() => _import = v ?? false),
            child: AutoGrid(
              minItemWidth: 300,
              stretch: false,
              children: [
                option(
                  isImport: true,
                  icon: AppIcons.upload,
                  title: 'Import an existing schema',
                  body: 'Load a signed confdb-schema assertion, or a JSON draft from disk.',
                ),
                option(
                  isImport: false,
                  icon: AppIcons.template,
                  title: 'Start from a template',
                  body: 'A storage tree and views you can rename and extend.',
                  children: [templates],
                ),
              ],
            ),
          ),
          if (!_import) ...[
            const SizedBox(height: 24),
            AutoGrid(
              minItemWidth: 260,
              stretch: false,
              children: [
                if (app.accountKnown)
                  // Read-only: the alias, with the ID on hover and a click to copy it.
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Account',
                      helperText: 'Read-only · from your developer account',
                      helperMaxLines: 2,
                      filled: true,
                      fillColor: c.surfaceContainerHigh,
                      border: const UnderlineInputBorder(),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.outlineVariant)),
                      suffixIcon: Icon(AppIcons.lock, size: 18, color: c.onSurfaceVariant),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AccountName(account, style: context.text.bodyLarge?.mono),
                    ),
                  )
                else
                  // The backend couldn't tell; snapd doesn't know the store account ID.
                  TextField(
                    controller: _account,
                    style: context.text.bodyLarge?.mono,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Account ID',
                      helperText: 'Your developer account ID (see snapcraft whoami)',
                      helperMaxLines: 2,
                    ),
                  ),
                TextField(
                  controller: _name,
                  style: context.text.bodyLarge?.mono,
                  onChanged: (_) => _nameEdited = true,
                  onSubmitted: (_) => _open(account),
                  decoration: InputDecoration(
                    labelText: 'Schema name',
                    errorText: error == null ? null : 'Error: ${context.aliased(error)}',
                    helper: error == null
                        ? CodeText(
                            'Lowercase letters, digits and dashes · creates `$account/${_name.text.trim()}`',
                            style: context.text.bodySmall?.copyWith(color: c.onSurfaceVariant),
                            codeColor: c.onSurface,
                          )
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _summary,
              onChanged: (_) => _summaryEdited = true,
              onSubmitted: (_) => _open(account),
              decoration: const InputDecoration(
                labelText: 'Summary',
                helperText: 'Optional · one line describing what the schema configures',
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => app.go(const OverviewRoute()), child: const Text('Skip for now')),
              const SizedBox(width: 8),
              PrimaryButton(
                label: _import ? 'Choose file…' : 'Open in schema editor',
                icon: _import ? AppIcons.upload : null,
                busy: _busy,
                onPressed: !_import && error != null ? null : () => _open(account),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
