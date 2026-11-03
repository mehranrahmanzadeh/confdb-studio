import 'dart:convert';
import 'dart:io';

import 'package:confdb_studio/domain/schema_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration/support/fixtures.dart';

void main() {
  test('the public signed fixture matches its signing template', () {
    final assertion = File(fixtureAssertionPath).readAsStringSync();
    final signed = parseAssertion(assertion);
    final input =
        jsonDecode(File('scripts/integration/fixtures/confdb-studio-integration.json').readAsStringSync()) as Map<String, dynamic>;
    final expected = schemaFromHeaders({...input, 'account-id': signed.id.account}, input['body']);

    expect(signed.id, expected.id);
    expect(signed.id.name, 'confdb-studio-integration');
    expect(signed.signedBy, signed.id.account);
    expect(signed.summary, expected.summary);
    expect(signed.revision, expected.revision);
    expect(encodeViews(signed.views), encodeViews(expected.views));
    expect(encodeStorage(signed.storage), encodeStorage(expected.storage));
    expect(assertion, contains('\ntype: account-key\n'));
    expect(assertion, contains('\ntype: account\n'));
  });
}
