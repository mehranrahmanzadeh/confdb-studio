import 'package:flutter/widgets.dart';

import '../data/confdb_repository.dart';
import 'app_controller.dart';
import 'staging_controller.dart';
import 'store_controller.dart';

/// Hands the repository and app-wide controllers down the tree.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    required this.app,
    required this.staging,
    required this.store,
    required super.child,
  });

  final ConfdbRepository repository;
  final AppController app;
  final StagingController staging;

  /// The Snap Store login and the schemas registered there.
  final StoreController store;

  /// The scope's objects live for the whole app and widgets listen to the
  /// controllers directly, so no dependency is registered (this also makes it
  /// safe to call from initState).
  static AppScope of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository || app != oldWidget.app || staging != oldWidget.staging || store != oldWidget.store;
}

extension AppScopeContext on BuildContext {
  AppScope get scope => AppScope.of(this);
  ConfdbRepository get repo => AppScope.of(this).repository;
  AppController get app => AppScope.of(this).app;
  StagingController get staging => AppScope.of(this).staging;
  StoreController get store => AppScope.of(this).store;
}
