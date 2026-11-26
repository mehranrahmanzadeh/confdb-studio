import 'dart:async';

import 'package:flutter/material.dart';

import 'data/confdb_repository.dart';
import 'data/models.dart';
import 'data/remote/fake_message_service.dart';
import 'data/remote/message_service.dart';
import 'shell/app_shell.dart';
import 'shell/product_tour.dart';
import 'state/account_names.dart';
import 'state/app_controller.dart';
import 'state/app_scope.dart';
import 'state/remote_controller.dart';
import 'state/staging_controller.dart';
import 'state/store_controller.dart';
import 'theme/app_theme.dart';

class ConfdbStudioApp extends StatefulWidget {
  const ConfdbStudioApp({super.key, required this.repository, this.initialRoute = const OverviewRoute(), this.remote});

  final ConfdbRepository repository;

  /// The Remote tab's controller; the sample devices when not given. The
  /// app disposes it.
  final RemoteController? remote;

  /// Where to start; onboarding replaces it when confdb isn't enabled.
  final AppRoute initialRoute;

  @override
  State<ConfdbStudioApp> createState() => _ConfdbStudioAppState();
}

/// The Remote tab on sample devices that answer a few seconds after a
/// request is sent.
RemoteController sampleRemoteController() {
  final service = FakeMessageService();
  return RemoteController(connect: (_) => service, signer: FakeRequestSigner(), storage: MemoryRemoteStorage(sampleRemoteState()));
}

class _ConfdbStudioAppState extends State<ConfdbStudioApp> {
  late final _app = AppController(initial: widget.initialRoute);
  final _staging = StagingController();
  late final _accounts = AccountNames(widget.repository);
  late final _store = StoreController(widget.repository);
  late final _remote = widget.remote ?? sampleRemoteController();
  final _theme = buildAppTheme();
  StreamSubscription<void>? _sub;
  bool _firstStatus = true;

  @override
  void initState() {
    super.initState();
    ProductTour.ensureRegistered();
    _sub = widget.repository.onChanged.listen((_) {
      _refreshStatus();
      _resolveAccounts();
    });
    _refreshStatus();
    _resolveAccounts();
    _remote.load();
    _store.refresh().then((_) => _accounts.resolve([for (final s in _store.schemas ?? const <ConfdbSchema>[]) s.id.account]));
    widget.repository.developerAccount().then((a) {
      if (a != null) {
        _app.setAccount(a);
        _accounts.resolve([a]);
        _remote.suggestAccount(a);
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
    _store.dispose();
    _remote.dispose();
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
      store: _store,
      remote: _remote,
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
