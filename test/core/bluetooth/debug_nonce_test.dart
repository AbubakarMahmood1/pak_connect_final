/// Debug test for nonce tracking issue
//
// Diagnostic output is intentional in this debug-only nonce trace test.

library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:logging/logging.dart';
import '../../test_helpers/test_setup.dart';

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
    debugPrint('\n══════════════════════════════════════════════════════════');
    debugPrint('STARTING DEBUG NONCE TEST');
    debugPrint('══════════════════════════════════════════════════════════\n');

    final aliceContactRepo = ContactRepository();

    late HandshakeCoordinator aliceCoordinator;
    late HandshakeCoordinator bobCoordinator;

    aliceCoordinator = HandshakeCoordinator(
      myEphemeralId: 'alice_id',
      myPublicKey: 'alice_perm',
      myDisplayName: 'Alice',
      sendMessage: (msg) async {
        debugPrint('\n>>> ALICE SENDS MESSAGE');
        await Future.delayed(Duration(milliseconds: 1));
        await bobCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        debugPrint('\n✅ ALICE HANDSHAKE COMPLETE with $id');
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
        debugPrint('\n<<< BOB SENDS MESSAGE');
        await Future.delayed(Duration(milliseconds: 1));
        await aliceCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        debugPrint('\n✅ BOB HANDSHAKE COMPLETE with $id');
      },
    );

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 1: STARTING HANDSHAKE');
    debugPrint('──────────────────────────────────────────────────────────\n');

    await aliceCoordinator.startHandshake();

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 2: HANDSHAKE COMPLETE - STARTING ENCRYPTION');
    debugPrint('──────────────────────────────────────────────────────────\n');

    // Print session info
    final noiseManager = SecurityManager.instance.noiseService!;
    debugPrint('Sessions in manager:');
    debugPrint(
      '  - Looking for bob_id session: ${noiseManager.hasEstablishedSession('bob_id')}',
    );
    debugPrint(
      '  - Looking for alice_id session: ${noiseManager.hasEstablishedSession('alice_id')}',
    );

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 3: ENCRYPT MESSAGE 1');
    debugPrint('──────────────────────────────────────────────────────────\n');

    final message1 = 'Hello Bob! Message #1';
    final plaintext1 = Uint8List.fromList(utf8.encode(message1));

    debugPrint('Alice encrypting to bob_id: "$message1"');
    final ciphertext1 = await SecurityManager.instance.noiseService!.encrypt(
      plaintext1,
      'bob_id',
    );
    debugPrint('Ciphertext1 length: ${ciphertext1?.length}');

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 4: DECRYPT MESSAGE 1');
    debugPrint('──────────────────────────────────────────────────────────\n');

    debugPrint('Bob decrypting from alice_id');
    final decrypted1 = await SecurityManager.instance.noiseService!.decrypt(
      ciphertext1!,
      'alice_id',
    );
    debugPrint(
      'Decrypted1: ${decrypted1 != null ? utf8.decode(decrypted1) : "NULL"}',
    );

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 5: ENCRYPT MESSAGE 2');
    debugPrint('──────────────────────────────────────────────────────────\n');

    final message2 = 'Hello Bob! Message #2';
    final plaintext2 = Uint8List.fromList(utf8.encode(message2));

    debugPrint('Alice encrypting to bob_id: "$message2"');
    final ciphertext2 = await SecurityManager.instance.noiseService!.encrypt(
      plaintext2,
      'bob_id',
    );
    debugPrint('Ciphertext2 length: ${ciphertext2?.length}');

    debugPrint('\n──────────────────────────────────────────────────────────');
    debugPrint('PHASE 6: DECRYPT MESSAGE 2');
    debugPrint('──────────────────────────────────────────────────────────\n');

    debugPrint('Bob decrypting from alice_id');
    final decrypted2 = await SecurityManager.instance.noiseService!.decrypt(
      ciphertext2!,
      'alice_id',
    );
    debugPrint(
      'Decrypted2: ${decrypted2 != null ? utf8.decode(decrypted2) : "NULL"}',
    );

    debugPrint('\n══════════════════════════════════════════════════════════');
    debugPrint('TEST COMPLETE');
    debugPrint('══════════════════════════════════════════════════════════\n');

    expect(decrypted1, isNotNull);
    expect(decrypted2, isNotNull);
  });
}
