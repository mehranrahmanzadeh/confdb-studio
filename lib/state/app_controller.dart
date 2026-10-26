import 'package:flutter/foundation.dart';

import '../data/models.dart';

enum Destination { overview, data, access }

/// Where the app is. Each route knows its rail destination.
sealed class AppRoute {
  const AppRoute();
  Destination get destination;
}

class OverviewRoute extends AppRoute {
  const OverviewRoute({this.justEnabled = false});

  /// Shows the "Confdb enabled" confirmation once, right after enabling.
  final bool justEnabled;
  @override
  Destination get destination => Destination.overview;
}

class OnboardingRoute extends AppRoute {
  const OnboardingRoute({this.choose = false});
  final bool choose;
  @override
  Destination get destination => Destination.overview;
}

/// A schema being authored: the editor, then its playground step.
sealed class AuthoringRoute extends AppRoute {
  const AuthoringRoute();
  SchemaId get id;
  String? get view;

  /// Schemas are listed on the overview.
  @override
  Destination get destination => Destination.overview;
}

class SchemaEditorRoute extends AuthoringRoute {
  const SchemaEditorRoute(this.id, {this.view, this.focusStoragePath});
  @override
  final SchemaId id;
  @override
  final String? view;
  final String? focusStoragePath;
}

/// The editor's preview step: a read-only look at the full confdb-schema
/// assertion (views and storage schema) before picking a signing key.
class PreviewRoute extends AuthoringRoute {
  const PreviewRoute(this.id, {required this.view});
  @override
  final SchemaId id;
  @override
  final String view;
}

/// The editor's signing-key step: pick (or create) the key to sign with,
/// before the sign dialog itself.
class SigningKeyRoute extends AuthoringRoute {
  const SigningKeyRoute(this.id, {required this.view});
  @override
  final SchemaId id;
  @override
  final String view;
}

/// The editor's playground step, reached after signing and acknowledging, to
/// try the newly-applied revision.
class PlaygroundRoute extends AuthoringRoute {
  const PlaygroundRoute(this.id, {required this.view, this.path, this.snap});
  @override
  final SchemaId id;
  @override
  final String view;
  final String? path;
  final String? snap;
}

class DataRoute extends AppRoute {
  const DataRoute({this.view, this.key, this.query});
  final ViewRef? view;
  final String? key;

  final String? query;

  @override
  Destination get destination => Destination.data;
}

class AccessRoute extends AppRoute {
  const AccessRoute({this.snap, this.whyPath});
  final String? snap;
  final String? whyPath;
  @override
  Destination get destination => Destination.access;
}

class AppController extends ChangeNotifier {
  AppController({AppRoute initial = const OverviewRoute()}) : _route = initial;

  AppRoute _route;
  String? _account;
  SystemStatus? _status;

  AppRoute get route => _route;

  /// Developer account ("confdb" until known).
  String get account => _account ?? 'confdb';

  /// Whether the backend reported the developer account.
  bool get accountKnown => _account != null;
  SystemStatus? get status => _status;

  void go(AppRoute route) {
    _route = route;
    notifyListeners();
  }

  /// Refines the current route (selected key, resolved default view). Same as
  /// [go]; named separately so screens read clearly.
  void replace(AppRoute route) {
    _route = route;
    notifyListeners();
  }

  void goTo(Destination d) => go(switch (d) {
    Destination.overview => const OverviewRoute(),
    Destination.data => const DataRoute(),
    Destination.access => const AccessRoute(),
  });

  /// Schema editor pane widths, kept for the session.
  static const defaultViewsPaneWidth = 260.0;
  static const defaultTreePaneWidth = 340.0;
  static const defaultJsonPaneWidth = 500.0;
  double viewsPaneWidth = defaultViewsPaneWidth;
  double treePaneWidth = defaultTreePaneWidth;
  double jsonPaneWidth = defaultJsonPaneWidth;

  bool _statusError = false;

  /// snapd didn't answer the last status check.
  bool get statusError => _statusError;

  void setStatus(SystemStatus status) {
    _status = status;
    _statusError = false;
    notifyListeners();
  }

  void setStatusError() {
    _statusError = true;
    notifyListeners();
  }

  void setAccount(String account) {
    _account = account;
    notifyListeners();
  }
}
