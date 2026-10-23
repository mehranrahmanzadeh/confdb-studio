import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/shell/account_button.dart';
import 'package:confdb_studio/shell/app_shell.dart';
import 'package:confdb_studio/state/app_controller.dart';
import 'package:confdb_studio/state/app_scope.dart';
import 'package:confdb_studio/state/staging_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/robot.dart';
import 'screenshots_test.dart';

const compact = Size(960, 1480);

/// A large monitor: pages should use the whole width.
const wide = Size(2560, 1200);
const wifiAdmin = ViewRef(acmeAccountId, 'network', 'wifi-admin');
const robotControl = ViewRef('acme', 'robot', 'control');

/// The placeholder schema from test/fixtures/robot.dart, acknowledged, with
/// two accelerometers set.
Future<void> robotWithValues(FakeConfdbRepository repo) async {
  await repo.signAndAcknowledge(robotSchema(), (await repo.signingKeys()).first);
  await repo.applyValues(robotControl, {
    'accelerometers.front': {'x': 0.1, 'y': -0.4},
    'accelerometers.rear': {'x': 0.0, 'y': 0.2},
  });
}

StagingController staging(WidgetTester t) => t.element(find.byType(AppShell)).staging;

const _band = StorageNode(key: 'band', kind: StorageKind.string, choices: ['2.4GHz', '5GHz', 'auto']);
const _ssid = StorageNode(key: 'ssid', kind: StorageKind.string);
const _psk = StorageNode(key: 'psk', kind: StorageKind.string);

Future<void> stageBandSsid(WidgetTester t) async {
  final s = staging(t);
  s.stage(const StagedValue(view: wifiAdmin, key: 'band', storagePath: 'wifi.band', node: _band, before: 'auto', value: '5GHz'));
  s.stage(
    const StagedValue(view: wifiAdmin, key: 'ssid', storagePath: 'wifi.ssid', node: _ssid, before: 'acme-office', value: 'acme-office-5g'),
  );
}

Future<void> stageBand(WidgetTester t) async {
  staging(t).stage(const StagedValue(view: wifiAdmin, key: 'band', storagePath: 'wifi.band', node: _band, before: 'auto', value: '5GHz'));
}

final shots = <Shot>[
  const Shot('overview', OverviewRoute()),
  const Shot('overview-compact', OverviewRoute(), size: compact),
  const Shot('overview-wide', OverviewRoute(), size: wide),
  const Shot('playground-wide', PlaygroundRoute(networkId, view: 'wifi-admin'), size: wide),
  Shot(
    'account-logged-out',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true),
    act: (t) async => t.tap(find.descendant(of: find.byType(AccountButton), matching: find.text('Sign in'))),
  ),
  const Shot(
    'account-logged-out-compact',
    OverviewRoute(),
    size: compact,
    scenario: FakeScenario(latency: Duration.zero, storeSignedOut: true),
  ),
  Shot(
    'account-logged-in',
    const OverviewRoute(),
    act: (t) async => t.tap(find.descendant(of: find.byType(AccountButton), matching: find.text('acme'))),
  ),
  Shot(
    'data-default',
    const DataRoute(view: wifiAdmin, key: 'band', query: 'band'),
    act: stageBandSsid,
  ),
  Shot(
    'data-psk',
    const DataRoute(view: wifiAdmin, key: 'psk'),
    act: (t) async {
      await stageBand(t);
      await t.pump();
      await t.enterText(find.widgetWithText(TextField, 'New value'), 'abc');
    },
  ),
  Shot(
    'data-rejected',
    const DataRoute(view: wifiAdmin, key: 'psk'),
    act: (t) async {
      staging(t).stage(
        const StagedValue(
          view: wifiAdmin,
          key: 'psk',
          storagePath: 'wifi.psk',
          node: _psk,
          before: null,
          value: 'x7q',
          secret: true,
          fromChange: 1842,
          rejection: 'psk must be at least 8 characters',
          rejectedBy: 'net-manager',
        ),
      );
    },
  ),
  const Shot('data-empty', DataRoute(view: ViewRef(acmeAccountId, 'telemetry', 'telemetry-read'))),
  const Shot(
    'data-error',
    DataRoute(view: wifiAdmin, key: 'band'),
    scenario: FakeScenario(latency: Duration.zero, loadViewFailsOnce: true),
  ),
  Shot(
    'data-compact',
    const DataRoute(view: wifiAdmin, key: 'band', query: 'band'),
    size: compact,
    act: stageBandSsid,
  ),
  Shot(
    'review',
    const DataRoute(view: wifiAdmin, key: 'band'),
    act: (t) async {
      await stageBandSsid(t);
      await t.pump();
      await t.tap(find.text('Review & apply'));
    },
  ),
  Shot(
    'applied',
    const DataRoute(view: wifiAdmin, key: 'band'),
    act: (t) async {
      await stageBandSsid(t);
      await t.pump();
      await t.tap(find.text('Review & apply'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Apply 2 changes'));
    },
  ),
  const Shot('access', AccessRoute()),
  Shot(
    'access-pass',
    const AccessRoute(),
    act: (t) async {
      await t.tap(find.text('Connect proxy-state'));
    },
  ),
  Shot(
    'access-disconnect',
    const AccessRoute(snap: 'wifi-indicator'),
    act: (t) async {
      await t.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    },
  ),
  const Shot('access-compact', AccessRoute(), size: compact),
  const Shot('schemas-empty', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, noSchemas: true)),
  const Shot('schemas-loading', OverviewRoute(), scenario: FakeScenario(latency: Duration(seconds: 3))),
  const Shot('schemas-error', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, snapdUnreachableOnce: true)),
  const Shot('editor', SchemaEditorRoute(networkId)),
  const Shot('editor-compact', SchemaEditorRoute(networkId), size: compact),
  Shot(
    'editor-json',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.text('JSON'));
    },
  ),
  Shot(
    'editor-fixed',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
    },
  ),
  const Shot('playground', PlaygroundRoute(networkId, view: 'wifi-admin')),
  const Shot('playground-denied', PlaygroundRoute(networkId, view: 'wifi-admin', snap: 'browser-proxy')),
  Shot(
    'playground-add-plug',
    const PlaygroundRoute(networkId, view: 'wifi-admin', snap: 'browser-proxy'),
    act: (t) async {
      await t.ensureVisible(find.text('More info'));
      await t.tap(find.text('More info'));
    },
  ),
  const Shot('playground-not-connected', PlaygroundRoute(networkId, view: 'proxy-state', snap: 'browser-proxy')),
  const Shot('playground-compact', PlaygroundRoute(networkId, view: 'wifi-admin'), size: compact),
  Shot(
    'sign',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('acme-release'));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('Sign & Acknowledge').last);
    },
  ),
  const Shot('editor-loading', SchemaEditorRoute(networkId), scenario: FakeScenario(latency: Duration(seconds: 3))),
  const Shot(
    'playground-loading',
    PlaygroundRoute(networkId, view: 'wifi-admin'),
    scenario: FakeScenario(latency: Duration(seconds: 3)),
  ),
  Shot(
    'storage-add-enum',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.byTooltip('Add storage path or alias'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Add storage path'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.enterText(find.widgetWithText(TextField, 'Key'), 'security');
      await t.tap(find.widgetWithText(SwitchListTile, 'Fixed choices'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.enterText(find.widgetWithText(TextField, 'Choices'), 'wpa2, wpa3, open');
    },
  ),
  Shot(
    'storage-edit-psk',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.byTooltip('Actions for wifi.psk'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Edit'));
    },
  ),
  const Shot('overview-no-custodian', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, noCustodian: true)),
  Shot(
    'custodian-guide',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, noCustodian: true),
    size: const Size(1440, 1300),
    act: (t) async => t.tap(find.byTooltip('How to connect a custodian snap')),
  ),
  Shot(
    'delete-view',
    const SchemaEditorRoute(networkId, view: 'wifi-state'),
    act: (t) async => t.tap(find.byTooltip('Delete view wifi-state')),
  ),
  Shot(
    'discard-draft',
    const OverviewRoute(),
    act: (t) async {
      await t.tap(find.byTooltip('Actions for acme/network'));
      // Frame by frame, so the menu finishes opening before the tap.
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Discard draft'));
    },
  ),
  Shot(
    'sign-no-keys',
    const SchemaEditorRoute(networkId),
    scenario: const FakeScenario(latency: Duration.zero, noKeys: true, storeSignedOut: true),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    },
  ),
  Shot(
    'sign-progress',
    const SchemaEditorRoute(networkId),
    scenario: const FakeScenario(latency: Duration(milliseconds: 200)),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('acme-release'));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('Sign & Acknowledge').last);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Sign and acknowledge'));
      await t.pump(const Duration(milliseconds: 700));
    },
  ),
  Shot(
    'overview-rev5',
    const SchemaEditorRoute(networkId),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('acme-release'));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('Sign & Acknowledge').last);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Sign and acknowledge'));
    },
  ),
  Shot('editor-placeholders', const SchemaEditorRoute(SchemaId('acme', 'robot'), view: 'control'), setup: robotWithValues),
  Shot(
    'editor-placeholder-errors',
    const SchemaEditorRoute(SchemaId('acme', 'robot'), view: 'control'),
    setup: (repo) => repo.saveDraft(
      robotSchema([
        ...robotRules,
        const ViewRule(request: 'grippers.{g}', storage: 'grippers.{gripper}', access: RuleAccess.readWrite),
        const ViewRule(request: 'limit[0]', storage: 'thresholds[0]', access: RuleAccess.read),
      ]),
    ),
  ),
  Shot(
    'storage-add-placeholder',
    const SchemaEditorRoute(SchemaId('acme', 'bot')),
    setup: (repo) => repo.saveDraft(
      const ConfdbSchema(
        id: SchemaId('acme', 'bot'),
        summary: 'Robot actuators',
        storage: StorageNode.root([StorageNode(key: 'actuators', kind: StorageKind.map)]),
        views: [],
        isDraft: true,
      ),
    ),
    act: (t) async {
      await t.tap(find.byTooltip('Actions for actuators'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Add placeholder'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.enterText(find.widgetWithText(TextField, 'Placeholder pattern (optional)'), r'^[a-z](?:-?[a-z0-9])*$');
    },
  ),
  Shot('storage-menu-placeholder', const SchemaEditorRoute(networkId), act: (t) async => t.tap(find.byTooltip('Actions for wifi'))),
  Shot(
    'data-placeholders',
    const DataRoute(view: robotControl, key: 'accelerometers.{sensor}'),
    setup: robotWithValues,
    act: (t) async => t.enterText(find.widgetWithText(TextField, '{sensor}'), 'front'),
  ),
  const Shot('onboarding', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, confdbDisabled: true)),
  Shot(
    'onboarding-choose',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, confdbDisabled: true),
    act: (t) async {
      await t.tap(find.text('Enable confdb'));
    },
  ),
  const Shot(
    'onboarding-compact',
    OverviewRoute(),
    size: compact,
    scenario: FakeScenario(latency: Duration.zero, confdbDisabled: true),
  ),
  Shot('schemas-store-menu', const OverviewRoute(), act: (t) async => t.tap(find.byTooltip('Actions for acme/fleet'))),
  const Shot('schemas-store-signed-out', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, storeSignedOut: true)),
  const Shot('schemas-store-offline', OverviewRoute(), scenario: FakeScenario(latency: Duration.zero, storeOffline: true)),
  const Shot('schemas-store-compact', OverviewRoute(), size: compact),
  Shot(
    'store-login',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true),
    act: (t) async => t.tap(find.widgetWithText(OutlinedButton, 'Sign in')),
  ),
  Shot(
    'store-login-2fa',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true),
    act: (t) async {
      await t.tap(find.widgetWithText(OutlinedButton, 'Sign in'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.enterText(find.widgetWithText(TextField, 'Email'), 'dev@acme.example');
      await t.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
      await t.pump();
      await t.tap(find.widgetWithText(FilledButton, 'Sign in'));
    },
  ),
  Shot(
    'account-store-signed-out',
    const OverviewRoute(),
    scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true),
    act: (t) async => t.tap(find.descendant(of: find.byType(AccountButton), matching: find.text('Sign in'))),
  ),
  Shot(
    'sign-store-signed-out',
    const SchemaEditorRoute(networkId),
    scenario: const FakeScenario(latency: Duration.zero, storeSignedOut: true),
    act: (t) async {
      await t.tap(find.textContaining('Add wifi.signal'));
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.tap(find.text('Next'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    },
  ),
  const Shot(
    'data-no-custodian',
    DataRoute(view: ViewRef(acmeAccountId, 'telemetry', 'telemetry-admin')),
    scenario: FakeScenario(latency: Duration.zero, noCustodian: true),
  ),
];
