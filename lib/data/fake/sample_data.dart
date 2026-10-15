// Sample data from HANDOFF.md and the design files. Times, change IDs, the
// acme-release key fingerprint and telemetry values are placeholders.
import '../models.dart';

const _r = RuleAccess.read;
const _w = RuleAccess.write;
const _rw = RuleAccess.readWrite;

/// The sample developer's Snap Store `account-id`; its username is `acme`.
const acmeAccountId = 'Ky1RVjc4cN5NnTsZh3ZqNfVyJTDmF2Xq';

/// Account assertions the sample backend knows.
const sampleAccounts = {acmeAccountId: AccountInfo(id: acmeAccountId, username: 'acme', displayName: 'Acme Inc.')};

const networkId = SchemaId(acmeAccountId, 'network');
const telemetryId = SchemaId(acmeAccountId, 'telemetry');
const systemSnapsId = SchemaId('system', 'snaps');

const _wifiStorage = StorageNode(
  key: 'wifi',
  kind: StorageKind.map,
  children: [
    StorageNode(key: 'ssid', kind: StorageKind.string),
    StorageNode(key: 'psk', kind: StorageKind.string, secret: true),
    StorageNode(key: 'band', kind: StorageKind.string, choices: ['2.4GHz', '5GHz', 'auto']),
    StorageNode(key: 'status', kind: StorageKind.string, ephemeral: true),
  ],
);

const _proxyStorage = StorageNode(
  key: 'proxy',
  kind: StorageKind.map,
  children: [
    StorageNode(key: 'http', kind: StorageKind.string, pattern: r'^https?://'),
    StorageNode(key: 'https', kind: StorageKind.string, pattern: r'^https?://'),
    StorageNode(key: 'no-proxy', kind: StorageKind.array, valuesType: 'string'),
  ],
);

const _proxyViews = [
  ViewDef(
    name: 'proxy-admin',
    rules: [
      ViewRule(request: 'http', storage: 'proxy.http', access: _rw),
      ViewRule(request: 'no-proxy', storage: 'proxy.no-proxy', access: _rw),
    ],
  ),
  ViewDef(
    name: 'proxy-state',
    rules: [
      ViewRule(request: 'http', storage: 'proxy.http', access: _r),
      ViewRule(request: 'no-proxy', storage: 'proxy.no-proxy', access: _r),
    ],
  ),
];

/// acme/network rev 4, as acknowledged on the device.
const networkRev4 = ConfdbSchema(
  id: networkId,
  revision: 4,
  summary: 'Wi-Fi and proxy settings',
  signedBy: acmeAccountId,
  storage: StorageNode.root([_wifiStorage, _proxyStorage]),
  views: [
    ViewDef(
      name: 'wifi-admin',
      rules: [
        ViewRule(request: 'ssid', storage: 'wifi.ssid', access: _rw),
        ViewRule(request: 'psk', storage: 'wifi.psk', access: _w),
        ViewRule(request: 'band', storage: 'wifi.band', access: _rw),
        ViewRule(request: 'status', storage: 'wifi.status', access: _r),
      ],
    ),
    ViewDef(
      name: 'wifi-state',
      rules: [
        ViewRule(request: 'ssid', storage: 'wifi.ssid', access: _r),
        ViewRule(request: 'band', storage: 'wifi.band', access: _rw),
        ViewRule(request: 'status', storage: 'wifi.status', access: _r),
      ],
    ),
    ..._proxyViews,
  ],
);

/// Local draft for rev 5: adds `signal → wifi.signal` (missing from storage,
/// which is the lint error) and makes wifi-state's band read-only.
final networkDraft = networkRev4.copyWith(
  isDraft: true,
  baseRevision: 4,
  views: const [
    ViewDef(
      name: 'wifi-admin',
      rules: [
        ViewRule(request: 'ssid', storage: 'wifi.ssid', access: _rw),
        ViewRule(request: 'psk', storage: 'wifi.psk', access: _w),
        ViewRule(request: 'signal', storage: 'wifi.signal', access: _r),
        ViewRule(request: 'band', storage: 'wifi.band', access: _rw),
        ViewRule(request: 'status', storage: 'wifi.status', access: _r),
      ],
    ),
    ViewDef(
      name: 'wifi-state',
      rules: [
        ViewRule(request: 'ssid', storage: 'wifi.ssid', access: _r),
        ViewRule(request: 'band', storage: 'wifi.band', access: _r),
        ViewRule(request: 'status', storage: 'wifi.status', access: _r),
      ],
    ),
    ..._proxyViews,
  ],
);

const telemetryRev1 = ConfdbSchema(
  id: telemetryId,
  revision: 1,
  summary: 'Telemetry reporting',
  signedBy: acmeAccountId,
  storage: StorageNode.root([
    StorageNode(
      key: 'telemetry',
      kind: StorageKind.map,
      children: [
        StorageNode(key: 'enabled', kind: StorageKind.bool),
        StorageNode(key: 'interval', kind: StorageKind.int, min: 60, max: 86400),
        StorageNode(key: 'endpoint', kind: StorageKind.string, pattern: r'^https?://'),
      ],
    ),
  ]),
  views: [
    ViewDef(
      name: 'telemetry-admin',
      rules: [
        ViewRule(request: 'enabled', storage: 'telemetry.enabled', access: _rw),
        ViewRule(request: 'interval', storage: 'telemetry.interval', access: _rw),
      ],
    ),
    ViewDef(
      name: 'telemetry-read',
      rules: [
        ViewRule(request: 'enabled', storage: 'telemetry.enabled', access: _r),
        ViewRule(request: 'interval', storage: 'telemetry.interval', access: _r),
      ],
    ),
  ],
);

const systemSnaps = ConfdbSchema(
  id: systemSnapsId,
  summary: 'State of installed snaps',
  builtIn: true,
  storage: StorageNode.root([StorageNode(key: 'snaps', kind: StorageKind.map, valuesType: 'any')]),
  views: [
    ViewDef(
      name: 'snaps',
      rules: [ViewRule(request: '{name}', storage: 'snaps.{name}', access: _r)],
    ),
  ],
);

/// Persisted values, keyed by schema then storage path.
Map<SchemaId, Map<String, Object?>> seedValues() => {
  networkId: {
    'wifi.ssid': 'acme-office',
    'wifi.psk': 'correct-horse-battery',
    'wifi.band': 'auto',
    'proxy.http': 'http://proxy.acme.internal:3128',
    'proxy.no-proxy': ['localhost', '10.0.0.0/8'],
  },
  telemetryId: {},
  systemSnapsId: {
    'snaps.{name}': {
      'net-manager': {'revision': '112', 'channel': 'latest/stable'},
      'wifi-indicator': {'revision': '27', 'channel': 'latest/stable'},
      'browser-proxy': {'revision': 'x1', 'channel': null},
      'telemetry-agent': {'revision': '8', 'channel': 'latest/stable'},
    },
  },
};

/// Values the custodians' load-view hooks would return.
const ephemeralValues = <String, Object?>{'wifi.status': 'connected', 'wifi.signal': 72};

/// What custodian hooks enforce beyond the storage schema.
const valueHints = <String, ValueHint>{'wifi.psk': ValueHint(minLength: 8, description: 'change-view hook · at least 8 characters')};

List<SnapInfo> seedSnaps() => const [
  SnapInfo(
    name: 'net-manager',
    publisher: 'acme',
    revision: '112',
    plugs: [
      ConfdbPlug(
        snap: 'net-manager',
        plug: 'wifi-admin',
        view: ViewRef(acmeAccountId, 'network', 'wifi-admin'),
        role: PlugRole.custodian,
        state: ConnState.connected,
      ),
      ConfdbPlug(
        snap: 'net-manager',
        plug: 'proxy-admin',
        view: ViewRef(acmeAccountId, 'network', 'proxy-admin'),
        role: PlugRole.custodian,
        state: ConnState.connected,
      ),
    ],
    hooks: [
      DeclaredHook('change-view-wifi-admin'),
      DeclaredHook('save-view-wifi-admin'),
      DeclaredHook('load-view-wifi-admin'),
      DeclaredHook('change-view-proxy-admin'),
      DeclaredHook('save-view-proxy-admin'),
    ],
  ),
  SnapInfo(
    name: 'wifi-indicator',
    publisher: 'acme',
    revision: '27',
    plugs: [
      ConfdbPlug(
        snap: 'wifi-indicator',
        plug: 'wifi-state',
        view: ViewRef(acmeAccountId, 'network', 'wifi-state'),
        role: PlugRole.observer,
        state: ConnState.connected,
      ),
    ],
    hooks: [DeclaredHook('observe-view-wifi-state')],
  ),
  SnapInfo(
    name: 'browser-proxy',
    publisher: 'acme',
    revision: 'x1',
    publisherSigned: false,
    installNote: 'installed from a local file',
    plugs: [
      ConfdbPlug(
        snap: 'browser-proxy',
        plug: 'proxy-state',
        view: ViewRef(acmeAccountId, 'network', 'proxy-state'),
        role: PlugRole.observer,
        state: ConnState.notConnected,
      ),
    ],
    hooks: [DeclaredHook('observe-view-proxy-state')],
  ),
  SnapInfo(
    name: 'telemetry-agent',
    publisher: 'acme',
    revision: '8',
    plugs: [
      ConfdbPlug(
        snap: 'telemetry-agent',
        plug: 'telemetry-admin',
        view: ViewRef(acmeAccountId, 'telemetry', 'telemetry-admin'),
        role: PlugRole.custodian,
        state: ConnState.autoConnected,
      ),
    ],
    hooks: [DeclaredHook('change-view-telemetry-admin'), DeclaredHook('save-view-telemetry-admin')],
  ),
];

const signingKeysSeed = [
  SigningKey(name: 'acme-release', sha3384: '7Hq2Kf9xLwR3d8sYb1nQe5uVj0cTg6hWkPz4aFrM2oXyiNs7lB3DqE9tGmT8vZp41'),
  SigningKey(name: 'acme-dev', sha3384: 'Lp0sDk3QwE8rTy2Uo6Ia4Sf9Gh1Jk5Zx7Cv3Bn0Mq2We8Rt4Yu6Io1Pa9Sd5Fg2H'),
];

const _wifiAdmin = ViewRef(acmeAccountId, 'network', 'wifi-admin');

/// Changes #1840–#1845. New changes start at #1846.
List<ConfdbChange> seedChanges(DateTime now) {
  DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));
  final yesterday = DateTime(now.year, now.month, now.day - 1, 17, 20);
  return [
    ConfdbChange(
      id: 1845,
      kind: 'set-confdb',
      summary: 'Set confdb through `$acmeAccountId/network/wifi-admin`',
      detail: 'band = auto',
      initiator: 'You',
      initiatorKind: InitiatorKind.user,
      spawnTime: ago(12),
      readyTime: ago(12),
      status: ChangeStatus.done,
      view: _wifiAdmin,
      custodian: 'net-manager',
      observers: const ['wifi-indicator'],
      values: const [ValueDiff(key: 'band', storagePath: 'wifi.band', before: '5GHz', after: 'auto', afterRaw: 'auto')],
      steps: const [
        ChangeStep(
          title: 'Initiated by user',
          state: ChangeStepState.user,
          meta: '',
          description: 'You, from Confdb Studio · 1 value through wifi-admin',
        ),
        ChangeStep(
          title: 'Validation against storage schema',
          state: ChangeStepState.passed,
          meta: '3 ms',
          description: '`auto` is one of 2.4GHz, 5GHz, auto.',
        ),
        ChangeStep(
          title: '`change-view-wifi-admin` on `net-manager`',
          state: ChangeStepState.passed,
          meta: 'exit 0 · 38 ms',
          output: HookOutput(stdout: 'band: 5GHz -> auto (accepted)'),
        ),
        ChangeStep(
          title: '`save-view-wifi-admin` on `net-manager`',
          state: ChangeStepState.passed,
          meta: 'exit 0 · 52 ms',
          description: 'Values persisted.',
        ),
        ChangeStep(title: 'Committed', state: ChangeStepState.passed, meta: '', description: '`wifi.band` = auto'),
        ChangeStep(
          title: '`observe-view-wifi-state` on `wifi-indicator`',
          state: ChangeStepState.passed,
          meta: 'exit 0 · 21 ms',
          description: 'Observer notified after commit.',
        ),
      ],
    ),
    ConfdbChange(
      id: 1844,
      kind: 'connect-snap',
      summary: 'Connect `wifi-indicator:wifi-state`',
      detail: 'auto-connect on install',
      initiator: 'snapd',
      initiatorKind: InitiatorKind.snap,
      spawnTime: ago(21),
      readyTime: ago(21),
      status: ChangeStatus.done,
      steps: const [
        ChangeStep(
          title: 'Auto-connect on install',
          state: ChangeStepState.user,
          meta: '',
          description: 'snapd connected the plug when `wifi-indicator` was installed.',
        ),
        ChangeStep(
          title: 'Connect `wifi-indicator:wifi-state` to `$acmeAccountId/network/wifi-state`',
          state: ChangeStepState.passed,
          meta: '9 ms',
        ),
      ],
    ),
    ConfdbChange(
      id: 1842,
      kind: 'set-confdb',
      summary: 'Set confdb through `$acmeAccountId/network/wifi-admin`',
      detail: 'psk = •••',
      initiator: 'You',
      initiatorKind: InitiatorKind.user,
      spawnTime: ago(55),
      readyTime: ago(55),
      status: ChangeStatus.error,
      view: _wifiAdmin,
      custodian: 'net-manager',
      observers: const ['wifi-indicator'],
      error: 'psk must be at least 8 characters',
      rejectedBy: 'net-manager',
      values: const [ValueDiff(key: 'psk', storagePath: 'wifi.psk', before: '••••••', after: '•••', secret: true, afterRaw: 'x7q')],
      steps: const [
        ChangeStep(
          title: 'Initiated by user',
          state: ChangeStepState.user,
          meta: '',
          description: 'You, from Confdb Studio · 1 value through wifi-admin',
        ),
        ChangeStep(
          title: 'Validation against storage schema',
          state: ChangeStepState.passed,
          meta: '4 ms',
          description: '`wifi.psk` is a string.',
        ),
        ChangeStep(
          title: '`change-view-wifi-admin` on `net-manager`',
          state: ChangeStepState.failed,
          meta: 'exit 1 · 120 ms',
          description: 'The custodian rejected the change.',
          output: HookOutput(stderr: 'error: psk must be at least 8 characters'),
        ),
        ChangeStep(
          title: 'Rolled back',
          state: ChangeStepState.rolledBack,
          meta: '',
          description: 'No values were changed. save-view-wifi-admin did not run.',
        ),
      ],
    ),
    ConfdbChange(
      id: 1840,
      kind: 'ack-schema',
      summary: 'Acknowledge `$acmeAccountId/network` rev 4',
      detail: 'signed by $acmeAccountId',
      initiator: 'You',
      initiatorKind: InitiatorKind.user,
      spawnTime: yesterday,
      readyTime: yesterday,
      status: ChangeStatus.done,
      steps: const [
        ChangeStep(title: 'Initiated by user', state: ChangeStepState.user, meta: '', description: 'You, from Confdb Studio'),
        ChangeStep(
          title: 'Check signature of `$acmeAccountId/network` rev 4',
          state: ChangeStepState.passed,
          meta: '6 ms',
          description: 'Signed by account `$acmeAccountId`.',
        ),
        ChangeStep(title: 'Acknowledged', state: ChangeStepState.passed, meta: '', description: 'Revision 4 is now in use.'),
      ],
    ),
  ];
}
