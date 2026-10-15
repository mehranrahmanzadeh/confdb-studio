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

  /// The account assertion for [accountId] (on the device, else from the
  /// store), or null if neither has it.
  Future<AccountInfo?> account(String accountId);

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

  /// Snaps that have at least one confdb plug.
  Future<List<SnapInfo>> listSnaps();
  Future<ConfdbChange> connect(ConfdbPlug plug);
  Future<ConfdbChange> disconnect(ConfdbPlug plug);

  Future<List<SigningKey>> signingKeys();

  /// Signs [draft] as the next revision with [key] and acknowledges it. With
  /// [push], registers it in the Snap Store first, so a Store refusal leaves
  /// the device unchanged.
  Future<void> signAndAcknowledge(ConfdbSchema draft, SigningKey key, {bool push = false, void Function(SignPhase phase)? onPhase});

  // ------------------------------------------------------------ Snap Store

  /// The app's Snap Store login (surl), checked with the Store.
  Future<StoreSession> storeSession();

  /// Signs in to the Snap Store with an Ubuntu One account and saves the
  /// login. Throws [ConfdbErrorKind.twoFactorRequired] when [otp] is needed.
  Future<StoreSession> storeLogin({required String email, required String password, String? otp, StoreEnv env = StoreEnv.production});
  Future<void> storeLogout();

  /// Schemas the signed-in account registered in the Store, latest revision
  /// each. [ConfdbSchema.revision] is null when the Store leaves it out.
  Future<List<ConfdbSchema>> listStoreSchemas();

  /// Fetches the Store's signed revision of [id] and acknowledges it here.
  Future<void> installFromStore(SchemaId id);

  /// Registers the revision of [id] acknowledged on this device in the Store.
  Future<void> pushToStore(SchemaId id);
}
