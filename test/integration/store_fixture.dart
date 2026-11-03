import 'dart:convert';
import 'dart:io';

import 'package:confdb_studio/data/models.dart';
import 'package:confdb_studio/data/store/store_auth_client.dart';
import 'package:confdb_studio/domain/schema_codec.dart';

/// Replaces only the Store boundary, never snapd, signing or the keyring.
class IntegrationStore implements StoreAuthClient {
  IntegrationStore(this.remote, this.keyDigest);

  final Directory remote;
  final String keyDigest;
  final schemas = <SchemaId, Map<String, Object?>>{};
  final registered = <String>[];
  final keyRequests = <String>[];
  ConfdbErrorKind? accountError;
  bool rejectRegistration = false;
  bool cancelled = false;
  bool loggedOut = false;

  static final account = StoreAccountInfo.fromJson({'id': 'developer1', 'username': 'developer1', 'email': 'integration@example.invalid'});

  @override
  Future<StoreAuthSession> login({required StoreEnv env, required String email, required String password, String? otp}) async {
    if (email != account.email || password != 'test-only' || otp != '123456') {
      throw const ConfdbException('Test Store requires a one-time code.', kind: ConfdbErrorKind.twoFactorRequired);
    }
    return StoreAuthSession(account: account, credentialsJson: 'test-only-session');
  }

  @override
  Future<StoreAuthSession> restoreCredentials({required StoreEnv env, required String credentialsJson}) async {
    if (credentialsJson != 'test-only-session') {
      throw const ConfdbException('Unknown test session.', kind: ConfdbErrorKind.signedOut);
    }
    return StoreAuthSession(account: account, credentialsJson: credentialsJson);
  }

  @override
  Future<void> cancelLogin() async => cancelled = true;

  @override
  Future<void> logout() async => loggedOut = true;

  @override
  Future<StoreAccountInfo> whoami() async => account;

  @override
  Future<Map<String, Object?>> accountInfo() async {
    final error = accountError;
    if (error != null) throw ConfdbException('Test account service failed.', kind: error);
    return {
      'account_keys': [
        {'public-key-sha3-384': keyDigest},
      ],
    };
  }

  @override
  Future<void> registerKey(String accountKeyRequest) async => keyRequests.add(accountKeyRequest);

  @override
  Future<StoreApiResponse> request(String method, String path, {String? body, String? contentType}) async {
    const api = '/api/v2/confdb-schemas';
    if (method == 'GET' && path == api) return _response(200);
    if (method == 'POST' && path == '$api/build-assertion') {
      final input = (jsonDecode(body!) as Map).cast<String, Object?>();
      return StoreApiResponse(
        status: 200,
        body: jsonEncode({
          ...input,
          'type': 'confdb-schema',
          'authority-id': input['account-id'],
          'revision': '20',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    }
    if (method == 'POST' && path == api) {
      if (rejectRegistration) {
        return const StoreApiResponse(status: 409, body: '{"message":"test Store rejected schema"}');
      }
      if (contentType != 'application/x.ubuntu.assertion') throw StateError('Expected signed assertion content type');
      final assertion = body!;
      final schema = parseSchemaFile(assertion);
      final input = signInput(schema, revision: schema.revision!, timestamp: DateTime.now());
      schemas[schema.id] = {
        'headers': {...input}..remove('body'),
        'body': input['body'],
      };
      registered.add(assertion);
      await File('${remote.path}/confdb-schema').writeAsString(assertion);
      return _response(201);
    }
    throw StateError('Unexpected Store request: $method $path');
  }

  StoreApiResponse _response(int status) => StoreApiResponse(status: status, body: jsonEncode({'assertions': schemas.values.toList()}));
}
