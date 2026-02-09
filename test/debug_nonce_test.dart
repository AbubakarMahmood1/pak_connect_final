/// Debug test for nonce tracking issue
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/core/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:logging/logging.dart';
import 'test_helpers/test_setup.dart';

// Mock secure storage
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  late MockSecureStorage mockStorage;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'debug_nonce');
    mockStorage = MockSecureStorage();
    await SecurityManager.instance.initialize(secureStorage: mockStorage);
  });

  setUp(() async {
    logRecords.clear();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    SimpleCrypto.resetDeprecatedWrapperUsageCounts();
    await TestSetup.fullDatabaseReset();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );
    final wrapperUsage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
    expect(
      wrapperUsage['total'],
      equals(0),
      reason:
          'Deprecated SimpleCrypto wrappers were used unexpectedly: $wrapperUsage',
    );
    await TestSetup.completeCleanup();
  });

  tearDownAll(() async {
    SecurityManager.instance.shutdown();
    await DatabaseHelper.deleteDatabase();
  });

  test('Debug nonce tracking with detailed logging', () async {
    print('\n══════════════════════════════════════════════════════════');
    print('STARTING DEBUG NONCE TEST');
    print('══════════════════════════════════════════════════════════\n');

    final aliceContactRepo = ContactRepository();
    final bobContactRepo = ContactRepository();

    late HandshakeCoordinator aliceCoordinator;
    late HandshakeCoordinator bobCoordinator;

    aliceCoordinator = HandshakeCoordinator(
      myEphemeralId: 'alice_id',
      myPublicKey: 'alice_perm',
      myDisplayName: 'Alice',
      sendMessage: (msg) async {
        print('\n>>> ALICE SENDS MESSAGE');
        await Future.delayed(Duration(milliseconds: 1));
        await bobCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        print('\n✅ ALICE HANDSHAKE COMPLETE with $id');
        await aliceContactRepo.saveContact(id, name);
        if (aliceCoordinator.theirNoisePublicKey != null) {
          await aliceContactRepo.updateNoiseSession(
            publicKey: id,
            noisePublicKey: aliceCoordinator.theirNoisePublicKey!,
            sessionState: 'established',
          );
        }
      },
    );

    bobCoordinator = HandshakeCoordinator(
      myEphemeralId: 'bob_id',
      myPublicKey: 'bob_perm',
      myDisplayName: 'Bob',
      sendMessage: (msg) async {
        print('\n<<< BOB SENDS MESSAGE');
        await Future.delayed(Duration(milliseconds: 1));
        await aliceCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        print('\n✅ BOB HANDSHAKE COMPLETE with $id');
      },
    );

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 1: STARTING HANDSHAKE');
    print('──────────────────────────────────────────────────────────\n');

    await aliceCoordinator.startHandshake();

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 2: HANDSHAKE COMPLETE - STARTING ENCRYPTION');
    print('──────────────────────────────────────────────────────────\n');

    // Print session info
    final noiseManager = SecurityManager.instance.noiseService!;
    print('Sessions in manager:');
    print(
      '  - Looking for bob_id session: ${noiseManager.hasEstablishedSession('bob_id')}',
    );
    print(
      '  - Looking for alice_id session: ${noiseManager.hasEstablishedSession('alice_id')}',
    );

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 3: ENCRYPT MESSAGE 1');
    print('──────────────────────────────────────────────────────────\n');

    final message1 = 'Hello Bob! Message #1';
    final plaintext1 = Uint8List.fromList(utf8.encode(message1));

    print('Alice encrypting to bob_id: "$message1"');
    final ciphertext1 = await SecurityManager.instance.noiseService!.encrypt(
      plaintext1,
      'bob_id',
    );
    print('Ciphertext1 length: ${ciphertext1?.length}');

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 4: DECRYPT MESSAGE 1');
    print('──────────────────────────────────────────────────────────\n');

    print('Bob decrypting from alice_id');
    final decrypted1 = await SecurityManager.instance.noiseService!.decrypt(
      ciphertext1!,
      'alice_id',
    );
    print(
      'Decrypted1: ${decrypted1 != null ? utf8.decode(decrypted1) : "NULL"}',
    );

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 5: ENCRYPT MESSAGE 2');
    print('──────────────────────────────────────────────────────────\n');

    final message2 = 'Hello Bob! Message #2';
    final plaintext2 = Uint8List.fromList(utf8.encode(message2));

    print('Alice encrypting to bob_id: "$message2"');
    final ciphertext2 = await SecurityManager.instance.noiseService!.encrypt(
      plaintext2,
      'bob_id',
    );
    print('Ciphertext2 length: ${ciphertext2?.length}');

    print('\n──────────────────────────────────────────────────────────');
    print('PHASE 6: DECRYPT MESSAGE 2');
    print('──────────────────────────────────────────────────────────\n');

    print('Bob decrypting from alice_id');
    final decrypted2 = await SecurityManager.instance.noiseService!.decrypt(
      ciphertext2!,
      'alice_id',
    );
    print(
      'Decrypted2: ${decrypted2 != null ? utf8.decode(decrypted2) : "NULL"}',
    );

    print('\n══════════════════════════════════════════════════════════');
    print('TEST COMPLETE');
    print('══════════════════════════════════════════════════════════\n');

    expect(decrypted1, isNotNull);
    expect(decrypted2, isNotNull);
  });
}
