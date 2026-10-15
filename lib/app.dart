import 'dart:async';

import 'package:flutter/material.dart';

import 'data/confdb_repository.dart';
import 'shell/app_shell.dart';
import 'state/account_names.dart';
import 'state/app_controller.dart';
import 'state/app_scope.dart';
import 'state/staging_controller.dart';
import 'theme/app_theme.dart';

class ConfdbStudioApp extends StatefulWidget {
  const ConfdbStudioApp({super.key, required this.repository, this.initialRoute = const OverviewRoute()});

  final ConfdbRepository repository;

  /// Where to start; onboarding replaces it when confdb isn't enabled.
  final AppRoute initialRoute;

  @override
  State<ConfdbStudioApp> createState() => _ConfdbStudioAppState();
}

class _ConfdbStudioAppState extends State<ConfdbStudioApp> {
  late final _app = AppController(initial: widget.initialRoute);
  final _staging = StagingController();
  late final _accounts = AccountNames(widget.repository);
  final _theme = buildAppTheme();
  StreamSubscription<void>? _sub;
  bool _firstStatus = true;

  @override
  void initState() {
    super.initState();
    _sub = widget.repository.onChanged.listen((_) {
      _refreshStatus();
      _resolveAccounts();
    });
    _refreshStatus();
    _resolveAccounts();
    _app.refreshStoreAccount(widget.repository);
    widget.repository.developerAccount().then((a) {
      if (a != null) {
        _app.setAccount(a);
        _accounts.resolve([a]);
      }
    }, onError: (_) {});
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await widget.repository.systemStatus();
      if (!mounted) return;
      _app.setStatus(status);
      if (_firstStatus && !status.confdbEnabled) _app.go(const OnboardingRoute());
      _firstStatus = false;
    } catch (_) {
      if (mounted) _app.setStatusError();
    }
  }

  /// Looks up the aliases of every account in sight, so sentences that name
  /// them read well from the start.
  Future<void> _resolveAccounts() async {
    try {
      final r = await Future.wait([widget.repository.listSchemas(), widget.repository.listDrafts()]);
      final snaps = await widget.repository.listSnaps();
      _accounts.resolve({
        for (final list in r)
          for (final s in list) s.id.account,
        for (final s in snaps)
          for (final p in s.plugs) p.view.account,
      });
    } catch (_) {
      // The screens report snapd errors; aliases just wait.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _accounts.dispose();
    _app.dispose();
    _staging.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      repository: widget.repository,
      app: _app,
      staging: _staging,
      child: AccountNamesScope(
        names: _accounts,
        child: MaterialApp(
          title: 'Confdb Studio',
          debugShowCheckedModeBanner: false,
          theme: _theme,
          darkTheme: _theme,
          themeMode: ThemeMode.dark,
          home: const AppShell(),
        ),
      ),
    );
  }
}
