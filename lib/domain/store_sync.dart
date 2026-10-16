import 'dart:convert';

import '../data/models.dart';
import 'schema_codec.dart';

/// How a schema on this device compares with the Snap Store's copy.
enum StoreSync {
  /// Built-in, or the Store hasn't been checked.
  unknown,

  /// Signed on this device but never registered in the Store.
  notInStore,

  /// The Store has it; this device doesn't.
  storeOnly,

  /// Same revision (or, when the Store leaves revisions out, same content).
  inSync,

  /// The Store has a later revision than this device.
  storeNewer,

  /// This device has a later revision than the Store.
  deviceNewer,

  /// The Store doesn't say its revision and the content differs.
  differs,
}

/// Same summary, views and storage.
bool sameContent(ConfdbSchema a, ConfdbSchema b) =>
    a.summary == b.summary &&
    jsonEncode(encodeViews(a.views)) == jsonEncode(encodeViews(b.views)) &&
    jsonEncode(encodeStorage(a.storage)) == jsonEncode(encodeStorage(b.storage));

/// Compares the acknowledged [device] revision with the [store]'s latest.
/// Pass null for whichever doesn't have the schema.
StoreSync compareWithStore(ConfdbSchema? device, ConfdbSchema? store) {
  if (device != null && device.builtIn) return StoreSync.unknown;
  if (store == null) return device?.revision == null ? StoreSync.unknown : StoreSync.notInStore;
  if (device == null || device.revision == null) return StoreSync.storeOnly;
  final theirs = store.revision;
  if (theirs == null) return sameContent(device, store) ? StoreSync.inSync : StoreSync.differs;
  if (theirs > device.revision!) return StoreSync.storeNewer;
  if (theirs < device.revision!) return StoreSync.deviceNewer;
  return StoreSync.inSync;
}
