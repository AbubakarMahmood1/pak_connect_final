import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'test_helpers/test_setup.dart';

// Mock secure storage for testing
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value != null) {
      _storage[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MockSecureStorage mockStorage;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
    mockStorage = MockSecureStorage();
    await SecurityManager.initialize(secureStorage: mockStorage);
  });

  setUp(() async {
    // Clean database before each test
    await TestSetup.fullDatabaseReset();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    await TestSetup.completeCleanup();
  });

  tearDownAll(() {
    SecurityManager.shutdown();
  });

  test('DEBUG: Trace handshake coordinator flow step by step', () async {
    print('\n========== TEST START ==========\n');

    final aliceContactRepo = ContactRepository();
    final bobContactRepo = ContactRepository();

    bool aliceCompleted = false;
    bool bobCompleted = false;

    // Declare coordinators
    late HandshakeCoordinator aliceCoordinator;
    late HandshakeCoordinator bobCoordinator;

    print('Creating Alice coordinator...');
    aliceCoordinator = HandshakeCoordinator(
      myEphemeralId: 'alice_id',
      myPublicKey: 'alice_perm',
      myDisplayName: 'Alice',
      sendMessage: (msg) async {
        print('>>> ALICE SENDING: ${msg.type}');
        // Simulate async network delay
        await Future.delayed(Duration(milliseconds: 1));
        await bobCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        print('✅ ALICE HANDSHAKE COMPLETE');
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

    print('Creating Bob coordinator...');
    bobCoordinator = HandshakeCoordinator(
      myEphemeralId: 'bob_id',
      myPublicKey: 'bob_perm',
      myDisplayName: 'Bob',
      sendMessage: (msg) async {
        print('<<< BOB SENDING: ${msg.type}');
        // Simulate async network delay
        await Future.delayed(Duration(milliseconds: 1));
        await aliceCoordinator.handleReceivedMessage(msg);
      },
      onHandshakeComplete: (id, name, noiseKey) async {
        print('✅ BOB HANDSHAKE COMPLETE');
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

    print('\n--- Starting handshake ---\n');
    print('Alice phase before start: ${aliceCoordinator.currentPhase}');
    print('Bob phase before start: ${bobCoordinator.currentPhase}');

    await aliceCoordinator.startHandshake();

    print('\n--- After startHandshake() ---\n');
    print('Alice phase: ${aliceCoordinator.currentPhase}');
    print('Bob phase: ${bobCoordinator.currentPhase}');
    print('Alice completed: $aliceCompleted');
    print('Bob completed: $bobCompleted');

    print('\n========== TEST END ==========\n');

    expect(aliceCompleted, true, reason: 'Alice should complete');
    expect(bobCompleted, true, reason: 'Bob should complete');
  });
}
