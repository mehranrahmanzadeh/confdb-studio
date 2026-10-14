import 'dart:async';

import 'package:flutter/material.dart';

import '../data/confdb_repository.dart';
import '../state/app_scope.dart';

/// Loads data from the repository, shows loading and error states, and
/// reloads (keeping the old data on screen) whenever the repository changes.
class Loader<T> extends StatefulWidget {
  const Loader({
    super.key,
    required this.load,
    required this.builder,
    required this.loading,
    required this.error,
    this.reloadOnChange = true,
  });

  final Future<T> Function(ConfdbRepository repo) load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;
  final WidgetBuilder loading;
  final Widget Function(BuildContext context, Object error, VoidCallback retry) error;
  final bool reloadOnChange;

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;
  StreamSubscription<void>? _sub;
  ConfdbRepository? _repo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = context.repo;
    if (repo != _repo) {
      _repo = repo;
      _sub?.cancel();
      if (widget.reloadOnChange) _sub = repo.onChanged.listen((_) => _reload(silent: true));
      _reload();
    }
  }

  // Callers give the Loader a key derived from its query, so a new query
  // creates a new state instead of updating this one.

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    final gen = ++_generation;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.load(_repo!);
      if (!mounted || gen != _generation) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return widget.error(context, _error!, _reload);
    if (_loading && _data == null) return widget.loading(context);
    return widget.builder(context, _data as T, _reload);
  }
}
