import 'models.dart';

/// Everything the app reads from or writes to confdb goes through here.
///
/// Implementations:
/// * [FakeConfdbRepository] – seeded with the design's sample data.
/// * [SnapdRepository] – real snapd, over the REST socket (`/run/snapd.socket`)
///   or the shell (`snap debug api`), see [SnapdTransport].
///
/// Writes that snapd runs as changes return the finished [ConfdbChange]; a
/// change that a custodian rejects comes back with [ChangeStatus.error], it
/// doesn't throw. Transport and permission problems throw [ConfdbException].
abstract interface class ConfdbRepository {
  /// Human-readable backend name, e.g. "snapd REST".
  String get backendName;

  /// Fires after any write, so screens can reload.
  Stream<void> get onChanged;

  Future<SystemStatus> systemStatus();

  /// `snap set system experimental.confdb=true`; needs admin authentication.
  Future<void> enableConfdb();

  /// The developer account schemas are created under, if known.
  Future<String?> developerAccount();

  /// Whether snapcraft is logged in to a Snap Store developer account, which
  /// registering signing keys needs (`snapcraft whoami`).
  Future<StoreAccount> storeAccount();

  /// Acknowledged schemas, including built-in ones.
  Future<List<ConfdbSchema>> listSchemas();

  /// Local drafts, each based on an acknowledged revision or new.
  Future<List<ConfdbSchema>> listDrafts();
  Future<void> saveDraft(ConfdbSchema draft);
  Future<void> discardDraft(SchemaId id);

  /// Reads a confdb-schema assertion or a JSON draft from disk as a draft.
  Future<ConfdbSchema> importSchema(String filePath);

  /// Values of every request path in a view (`snap get <view>`).
  Future<ViewSnapshot> readView(ViewRef ref);

  /// Sets values through a view as one change (`snap set <view> k=v …`).
  /// A `null` value unsets the path.
  Future<ConfdbChange> applyValues(ViewRef ref, Map<String, Object?> values);

  Future<List<ConfdbChange>> listChanges();
  Future<ConfdbChange> getChange(int id);

  /// Snaps that have at least one confdb plug.
  Future<List<SnapInfo>> listSnaps();
  Future<ConfdbChange> connect(ConfdbPlug plug);
  Future<ConfdbChange> disconnect(ConfdbPlug plug);

  Future<List<SigningKey>> signingKeys();

  /// Signs [draft] as the next revision with [key] and acknowledges it.
  /// Returns the change when the backend records one (snapd acknowledges
  /// synchronously, so it returns null).
  Future<ConfdbChange?> signAndAcknowledge(ConfdbSchema draft, SigningKey key, {void Function(SignPhase phase)? onPhase});
}
