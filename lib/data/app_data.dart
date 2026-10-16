import 'dart:io';

/// Where Studio keeps its own files: the saved Snap Store login and the
/// local drafts.
///
/// In the snap that's `$SNAP_USER_COMMON` (`~/snap/confdb-studio/common`),
/// which every revision shares, so refreshes and reverts keep them. Outside
/// a snap it's `$XDG_DATA_HOME/confdb-studio` (`~/.local/share/confdb-studio`).
String appDataDir([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final common = env['SNAP_USER_COMMON'];
  if (common != null && common.isNotEmpty) return common;
  return _xdgDataDir(env);
}

String _xdgDataDir(Map<String, String> env) {
  final xdg = env['XDG_DATA_HOME'];
  final base = xdg != null && xdg.isNotEmpty ? xdg : '${env['HOME'] ?? '.'}/.local/share';
  return '$base/confdb-studio';
}

/// The path of [name] in [appDataDir]. In the snap, a file or folder left
/// in the XDG location by earlier versions is moved there first, so a login
/// and drafts survive the move.
String appDataPath(String name, [Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final dir = appDataDir(env);
  final path = '$dir/$name';
  final legacy = '${_xdgDataDir(env)}/$name';
  if (legacy != path) _moveLegacy(legacy, path);
  return path;
}

void _moveLegacy(String from, String to) {
  try {
    if (FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) return;
    final type = FileSystemEntity.typeSync(from);
    if (type == FileSystemEntityType.notFound) return;
    Directory(File(to).parent.path).createSync(recursive: true);
    if (type == FileSystemEntityType.directory) {
      Directory(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
  } on FileSystemException {
    // Leave it where it was; Studio starts afresh in the new place.
  }
}
