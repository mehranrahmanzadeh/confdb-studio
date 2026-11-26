import 'package:confdb_studio/app.dart';
import 'package:confdb_studio/data/fake/fake_repository.dart';
import 'package:confdb_studio/data/fake/sample_data.dart';
import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/remote/fake_message_service.dart';
import 'package:confdb_studio/data/remote/message_service.dart';
import 'package:confdb_studio/data/remote/remote_models.dart';
import 'package:confdb_studio/domain/remote.dart';
import 'package:confdb_studio/screens/remote/remote_screen.dart';
import 'package:confdb_studio/state/app_scope.dart';
import 'package:confdb_studio/state/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _gw1 = DeviceId('GW-0001', 'gateway-pro', acmeAccountId);
final _hub = DeviceId('SH-0107', 'sensor-hub', acmeAccountId);
final _core = DeviceId('a1b2c3d4', 'ubuntu-core-24-amd64', 'canonical');
const _wifi = ViewRef(acmeAccountId, 'network', 'wifi-admin');

/// A message service that fails the next exchange with [failNext].
class _FlakyService extends FakeMessageService {
  _FlakyService({super.clock}) : super(answerDelay: Duration.zero);

  MessageServiceException? failNext;

  @override
  Future<ExchangeResult> exchange(String session, {int limit = 0, String? after, List<String> send = const []}) {
    final e = failNext;
    failNext = null;
    if (e != null) throw e;
    return super.exchange(session, limit: limit, after: after, send: send);
  }
}

void main() {
  group('DeviceId', () {
    test('splits from the right', () {
      final d = DeviceId.parse('f1ae97af-4d31-40bc-a2c8-555c7e7456f2.generic-classic.generic');
      expect((d.serial, d.model, d.brand), ('f1ae97af-4d31-40bc-a2c8-555c7e7456f2', 'generic-classic', 'generic'));
    });

    test('rejects malformed IDs', () {
      expect(() => DeviceId.parse('serial.model'), throwsFormatException);
      expect(() => DeviceId.parse('a b.model.brand'), throwsFormatException);
      expect(DeviceId.tryParse('x.-bad.brand'), isNull);
    });

    test('reads pasted snap known serial output', () {
      const pasted = '''type: serial
authority-id: generic
brand-id: generic
model: generic-classic
serial: f1ae97af-4d31-40bc-a2c8-555c7e7456f2
device-key-sha3-384: abc

AcLBcwQAAQoAHRYhBA''';
      expect(parseDeviceInput(pasted).id, 'f1ae97af-4d31-40bc-a2c8-555c7e7456f2.generic-classic.generic');
    });
  });

  test('response-message assertions are read with their JSON body', () {
    const body = '{"values":{"https":{"url":"https://remote.example.com"}}}';
    final text =
        'type: response-message\n'
        'authority-id: generic\n'
        'account-id: acct\n'
        'message-id: req1700000000\n'
        'device: s.m.generic\n'
        'status: success\n'
        'timestamp: 2026-01-02T03:04:05Z\n'
        'body-length: ${body.length}\n'
        'sign-key-sha3-384: k\n\n'
        '$body\n\nAcLB';
    final r = RemoteResponse.fromAssertion(text);
    expect(r.status, MessageStatus.success);
    expect(r.device, 's.m.generic');
    expect(flattenValues(r.values!), [('https.url', 'https://remote.example.com')]);
    expect(() => RemoteResponse.fromAssertion('type: serial\n\nsig'), throwsFormatException);
  });

  test('secret storage stays secret through a view', () {
    expect(isSecretRequestPath(networkRev4, 'wifi-admin', 'psk'), isTrue);
    expect(isSecretRequestPath(networkRev4, 'wifi-admin', 'ssid'), isFalse);
    expect(isSecretRequestPath(networkRev4, 'missing', 'psk'), isFalse);
  });

  test('the sessions URL fills in the account', () {
    const s = RemoteSettings(storeUrl: 'http://test-store.lxd/', account: 'acct');
    expect(s.sessionsUri.toString(), 'http://test-store.lxd/publishergw/v1/brand/acct/messages/sessions');
  });

  group('RemoteController', () {
    late DateTime time;
    late _FlakyService service;
    late RemoteController remote;

    setUp(() {
      time = DateTime.utc(2026, 1, 1, 12);
      service = _FlakyService(clock: () => time);
      remote = RemoteController(
        connect: (_) => service,
        signer: FakeRequestSigner(),
        storage: MemoryRemoteStorage(sampleRemoteState()),
        clock: () => time,
        // Polls only when a test asks.
        pollDelays: const [Duration(days: 1)],
      );
    });
    tearDown(() => remote.dispose());

    test('sends a signed request and files the answers, then acknowledges them', () async {
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1, _core], keys: ['ssid']);
      expect(r.sent, isTrue);
      expect(remote.waitingCount, 1);
      final sent = parseAssertion(service.received.single);
      expect(sent.header('message-id'), r.messageId);
      expect(sent.headers['devices'], [_gw1.id, _core.id]);

      await remote.pollNow();
      final done = remote.request(r.messageId)!;
      expect(done.stateOf(_gw1.id, time), DeviceRequestState.success);
      expect(done.responses[_gw1.id]!.values, {'ssid': 'acme-lobby'});
      expect(done.stateOf(_core.id, time), DeviceRequestState.unauthorized);
      expect(remote.waitingCount, 0);

      final left = await service.exchange(remote.session!, limit: 10);
      expect(left.messages, isEmpty, reason: 'answers are acknowledged once filed');
    });

    test("a device that never answers expires with the request's validity", () async {
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_hub]);
      await remote.pollNow();
      expect(remote.request(r.messageId)!.stateOf(_hub.id, time), DeviceRequestState.waiting);
      time = time.add(remote.settings.validity + const Duration(seconds: 1));
      expect(remote.request(r.messageId)!.stateOf(_hub.id, time), DeviceRequestState.expired);
      expect(remote.waitingCount, 0);
    });

    test('opens a new session when the service lost the old one', () async {
      await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]);
      final first = remote.session;
      service.failNext = const MessageServiceException('session not found', status: 404);
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]);
      expect(r.sent, isTrue);
      expect(remote.session, isNot(first));
    });

    test('concurrent sends share one new session', () async {
      final sent = await Future.wait([
        remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]),
        remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]),
      ]);
      expect(sent.every((r) => r.sent), isTrue);
      await remote.pollNow();
      expect(remote.waitingCount, 0, reason: 'both answers come back on the session in use');
    });

    test('signs again under a new ID when the service saw the ID before', () async {
      service.failNext = const MessageServiceException('duplicate message id', status: 409);
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]);
      expect(r.sent, isTrue);
      expect(remote.requests.map((e) => e.messageId), [r.messageId]);
      expect(parseAssertion(service.received.single).header('message-id'), r.messageId);
    });

    test('keeps a request the service refused, with the reason', () async {
      service.failNext = const MessageServiceException('message 0: invalid', status: 400);
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1]);
      expect(r.sent, isFalse);
      expect(r.sendError, contains('invalid'));
      expect(r.stateOf(_gw1.id, time), DeviceRequestState.notSent);
    });

    test('retries only the devices that failed', () async {
      final r = await remote.send(action: RemoteAction.get, view: _wifi, devices: [_gw1, _core]);
      await remote.pollNow();
      final retry = await remote.retryFailed(remote.request(r.messageId)!);
      expect(retry.devices, [_core.id]);
    });
  });

  testWidgets('the Remote tab lists devices and opens the composer', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();

    expect(find.text('Lobby gateway'), findsOneWidget);
    expect(find.text('gateway-pro'), findsWidgets);
    expect(find.text('Activity'), findsWidgets);

    await tester.tap(find.text('New message').first);
    await tester.pumpAndSettle();
    expect(find.text('Sign & send'), findsNothing, reason: 'starts at the first step');
    expect(find.text('Targets'), findsWidgets);
  });
  testWidgets('a secret set through the composer stays masked', (tester) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ConfdbStudioApp(
        repository: FakeConfdbRepository(scenario: const FakeScenario(latency: Duration.zero)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New message').first);
    await tester.pumpAndSettle();

    final dialog = find.byType(Dialog);
    await tester.tap(find.descendant(of: dialog, matching: find.text('Lobby gateway')));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set values'));
    await tester.enterText(find.widgetWithText(TextField, 'View'), _wifi.path);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Key'), 'psk');
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Value (secret)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Value (secret)'), 'hunter2hunter2');
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.textContaining('hunter2'), findsNothing, reason: 'the review masks secrets');

    await tester.tap(find.text('Sign & send'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.textContaining('psk = ••••••'), findsOneWidget);
    expect(find.textContaining('hunter2'), findsNothing);
    final remote = tester.element(find.byType(RemoteScreen)).remote;
    expect(remote.requests.single.values, {'psk': 'hunter2hunter2'}, reason: 'masking is for display only');
    await tester.pumpWidget(const SizedBox());
  });
}
