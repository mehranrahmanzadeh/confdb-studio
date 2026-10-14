import 'dart:async';

import 'package:flutter/material.dart';

import 'data/confdb_repository.dart';
import 'shell/app_shell.dart';
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
  final _theme = buildAppTheme();
  StreamSubscription<void>? _sub;
  bool _firstStatus = true;

  @override
  void initState() {
    super.initState();
    _sub = widget.repository.onChanged.listen((_) => _refreshStatus());
    _refreshStatus();
    _app.refreshStoreAccount(widget.repository);
    widget.repository.developerAccount().then((a) {
      if (a != null) _app.setAccount(a);
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

  @override
  void dispose() {
    _sub?.cancel();
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
      child: MaterialApp(
        title: 'Confdb Studio',
        debugShowCheckedModeBanner: false,
        theme: _theme,
        darkTheme: _theme,
        themeMode: ThemeMode.dark,
        home: const AppShell(),
      ),
    );
  }
}
