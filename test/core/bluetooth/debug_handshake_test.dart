//
// Diagnostic output is intentional in this debug-only handshake trace test.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import '../../test_helpers/test_setup.dart';

// Mock secure storage for testing
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
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;
  late MockSecureStorage mockStorage;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'debug_handshake');
    mockStorage = MockSecureStorage();
    await SecurityManager.instance.initialize(secureStorage: mockStorage);
  });

  setUp(() async {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    SimpleCrypto.resetDeprecatedWrapperUsageCounts();
    // Clean database before each test
    await TestSetup.fullDatabaseReset();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }

    final wrapperUsage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
    expect(
      wrapperUsage['total'],
      equals(0),
      reason:
          'Deprecated SimpleCrypto wrappers were used unexpectedly: $wrapperUsage',
    );
    await TestSetup.completeCleanup();
  });

  tearDownAll(() {
    SecurityManager.instance.shutdown();
  });

  test('DEBUG: Trace handshake coordinator flow step by step', () async {
    debugPrint('\n========== TEST START ==========\n');

    final aliceContactRepo = ContactRepository();
    final bobContactRepo = ContactRepository();

    bool aliceCompleted = false;
    bool bobCompleted = false;

    // Declare coordinators
    late HandshakeCoordinator aliceCoordinator;
    late HandshakeCoordinator bobCoordinator;

    debugPrint('Creating Alice coordinator...');
    aliceCoordinator = HandshakeCoordinator(
      myEphemeralId: 'alice_id',
      myPublicKey: 'alice_perm',
      myDisplayName: 'Alice',
      sendMessage: (msg) async {
        debugPrint('>>> ALICE SENDING: ${msg.type}');
        // Simulate async network delay
        await Future.delayed(Duration(milliseconds: 1));
        await bobCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        debugPrint('✅ ALICE HANDSHAKE COMPLETE');
        aliceCompleted = true;
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

    debugPrint('Creating Bob coordinator...');
    bobCoordinator = HandshakeCoordinator(
      myEphemeralId: 'bob_id',
      myPublicKey: 'bob_perm',
      myDisplayName: 'Bob',
      sendMessage: (msg) async {
        debugPrint('<<< BOB SENDING: ${msg.type}');
        // Simulate async network delay
        await Future.delayed(Duration(milliseconds: 1));
        await aliceCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        debugPrint('✅ BOB HANDSHAKE COMPLETE');
        bobCompleted = true;
        await bobContactRepo.saveContact(id, name);
        if (bobCoordinator.theirNoisePublicKey != null) {
          await bobContactRepo.updateNoiseSession(
            publicKey: id,
            noisePublicKey: bobCoordinator.theirNoisePublicKey!,
            sessionState: 'established',
          );
        }
      },
    );

    debugPrint('\n--- Starting handshake ---\n');
    debugPrint('Alice phase before start: ${aliceCoordinator.currentPhase}');
    debugPrint('Bob phase before start: ${bobCoordinator.currentPhase}');

    await aliceCoordinator.startHandshake();

    debugPrint('\n--- After startHandshake() ---\n');
    debugPrint('Alice phase: ${aliceCoordinator.currentPhase}');
    debugPrint('Bob phase: ${bobCoordinator.currentPhase}');
    debugPrint('Alice completed: $aliceCompleted');
    debugPrint('Bob completed: $bobCompleted');

    debugPrint('\n========== TEST END ==========\n');

    expect(aliceCompleted, true, reason: 'Alice should complete');
    expect(bobCompleted, true, reason: 'Bob should complete');
  });
}
