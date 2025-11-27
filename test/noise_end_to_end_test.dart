/// End-to-end integration tests for Noise Protocol
///
/// Tests complete flow: BLE handshake → Noise session → encryption → decryption
/// Simulates two-device communication in a single test process
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
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

  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'noise_end_to_end');

    // Initialize SecurityManager with Noise support
    mockStorage = MockSecureStorage();
    await SecurityManager.instance.initialize(secureStorage: mockStorage);
  });

  setUp(() async {
    // Clean database before each test
    await TestSetup.fullDatabaseReset();

    // Clear all Noise sessions to prevent pollution between tests
    SecurityManager.instance.clearAllNoiseSessions();
  });

  tearDownAll(() async {
    SecurityManager.instance.shutdown();
    await DatabaseHelper.deleteDatabase();
  });

  group('Noise End-to-End Integration Tests', () {
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() {
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

    tearDown(() {
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
    });

    test(
      'Complete BLE handshake establishes Noise session and saves to database',
      () async {
        final aliceContactRepo = ContactRepository();
        final bobContactRepo = ContactRepository();

        bool aliceCompleted = false;
        bool bobCompleted = false;
        String? aliceSeesNoiseKey;
        String? bobSeesNoiseKey;

        // Declare coordinators (for forward reference in callbacks)
        late HandshakeCoordinator aliceCoordinator;
        late HandshakeCoordinator bobCoordinator;

        // Alice's coordinator
        aliceCoordinator = HandshakeCoordinator(
          myEphemeralId: 'alice_ephemeral_id_12345678',
          myPublicKey: 'alice_permanent_key',
          myDisplayName: 'Alice',
          sendMessage: (msg) async =>
              await bobCoordinator.handleReceivedMessage(msg),
          onHandshakeComplete: (ephemeralId, displayName, noiseKey) async {
            print('✅ Alice completed handshake with $displayName');
            aliceCompleted = true;
            aliceSeesNoiseKey = aliceCoordinator.theirNoisePublicKey;

            await aliceContactRepo.saveContact(ephemeralId, displayName);
            if (aliceSeesNoiseKey != null) {
              await aliceContactRepo.updateNoiseSession(
                publicKey: ephemeralId,
                noisePublicKey: aliceSeesNoiseKey!,
                sessionState: 'established',
              );
            }
          },
        );

        // Bob's coordinator
        bobCoordinator = HandshakeCoordinator(
          myEphemeralId: 'bob_ephemeral_id_87654321',
          myPublicKey: 'bob_permanent_key',
          myDisplayName: 'Bob',
          sendMessage: (msg) async =>
              await aliceCoordinator.handleReceivedMessage(msg),
          onHandshakeComplete: (ephemeralId, displayName, noiseKey) async {
            print('✅ Bob completed handshake with $displayName');
            bobCompleted = true;
            bobSeesNoiseKey = bobCoordinator.theirNoisePublicKey;

            await bobContactRepo.saveContact(ephemeralId, displayName);
            if (bobSeesNoiseKey != null) {
              await bobContactRepo.updateNoiseSession(
                publicKey: ephemeralId,
                noisePublicKey: bobSeesNoiseKey!,
                sessionState: 'established',
              );
            }
          },
        );

        // Start handshake
        await aliceCoordinator.startHandshake();

        // Verify completion
        expect(aliceCompleted, true, reason: 'Alice should complete');
        expect(bobCompleted, true, reason: 'Bob should complete');
        expect(aliceSeesNoiseKey, isNotNull);
        expect(bobSeesNoiseKey, isNotNull);

        // Verify database persistence
        final aliceContact = await aliceContactRepo.getContact(
          'bob_ephemeral_id_87654321',
        );
        final bobContact = await bobContactRepo.getContact(
          'alice_ephemeral_id_12345678',
        );

        expect(aliceContact?.noiseSessionState, 'established');
        expect(aliceContact?.noisePublicKey, isNotNull);
        expect(aliceContact?.lastHandshakeTime, isNotNull);

        expect(bobContact?.noiseSessionState, 'established');
        expect(bobContact?.noisePublicKey, isNotNull);
        expect(bobContact?.lastHandshakeTime, isNotNull);
      },
    );

    test(
      'Encrypt and decrypt messages after Noise session established',
      () async {
        final aliceContactRepo = ContactRepository();
        final bobContactRepo = ContactRepository();

        late HandshakeCoordinator aliceCoordinator;
        late HandshakeCoordinator bobCoordinator;

        // Setup handshake
        aliceCoordinator = HandshakeCoordinator(
          myEphemeralId: 'alice_id',
          myPublicKey: 'alice_perm',
          myDisplayName: 'Alice',
          sendMessage: (msg) async =>
              await bobCoordinator.handleReceivedMessage(msg),
          onHandshakeComplete: (id, name, noiseKey) async {
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
          sendMessage: (msg) async =>
              await aliceCoordinator.handleReceivedMessage(msg),
          onHandshakeComplete: (id, name, noiseKey) async {},
        );

        await aliceCoordinator.startHandshake();

        // Test encryption
        final message = 'Hello Bob! 🔐';
        final plaintext = Uint8List.fromList(utf8.encode(message));

        final ciphertext = await SecurityManager.instance.noiseService!.encrypt(
          plaintext,
          'bob_id',
        );

        expect(ciphertext, isNotNull);
        if (ciphertext != null) {
          expect(
            ciphertext.length,
            greaterThan(plaintext.length),
            reason: 'Ciphertext includes 16-byte auth tag',
          );

          // Test decryption
          final decrypted = await SecurityManager.instance.noiseService!
              .decrypt(ciphertext, 'alice_id');

          expect(decrypted, isNotNull);
          if (decrypted != null) {
            expect(utf8.decode(decrypted), message);
          }
        }
      },
    );

    test('Session persists across app restart simulation', () async {
      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();
      String? savedNoiseKey;

      late HandshakeCoordinator aliceCoordinator;
      late HandshakeCoordinator bobCoordinator;

      aliceCoordinator = HandshakeCoordinator(
        myEphemeralId: 'alice_id',
        myPublicKey: 'alice_perm',
        myDisplayName: 'Alice',
        sendMessage: (msg) async =>
            await bobCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {
          savedNoiseKey = aliceCoordinator.theirNoisePublicKey;
          await aliceContactRepo.saveContact(id, name);
          if (savedNoiseKey != null) {
            await aliceContactRepo.updateNoiseSession(
              publicKey: id,
              noisePublicKey: savedNoiseKey!,
              sessionState: 'established',
            );
          }
        },
      );

      bobCoordinator = HandshakeCoordinator(
        myEphemeralId: 'bob_id',
        myPublicKey: 'bob_perm',
        myDisplayName: 'Bob',
        sendMessage: (msg) async =>
            await aliceCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator.startHandshake();

      // Verify initial save
      final contactBefore = await aliceContactRepo.getContact('bob_id');
      expect(contactBefore?.noiseSessionState, 'established');

      // Simulate restart with new repository instance
      final aliceContactRepoAfterRestart = ContactRepository();
      final contactAfter = await aliceContactRepoAfterRestart.getContact(
        'bob_id',
      );

      expect(contactAfter, isNotNull, reason: 'Contact persists');
      expect(contactAfter!.noiseSessionState, 'established');
      expect(contactAfter.noisePublicKey, savedNoiseKey);
    });

    test('Session rekey updates database with new session', () async {
      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();

      late HandshakeCoordinator aliceCoordinator1;
      late HandshakeCoordinator bobCoordinator1;

      // Initial handshake
      aliceCoordinator1 = HandshakeCoordinator(
        myEphemeralId: 'alice_id',
        myPublicKey: 'alice_perm',
        myDisplayName: 'Alice',
        sendMessage: (msg) async =>
            await bobCoordinator1.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {
          await aliceContactRepo.saveContact(id, name);
          if (aliceCoordinator1.theirNoisePublicKey != null) {
            await aliceContactRepo.updateNoiseSession(
              publicKey: id,
              noisePublicKey: aliceCoordinator1.theirNoisePublicKey!,
              sessionState: 'established',
            );
          }
        },
      );

      bobCoordinator1 = HandshakeCoordinator(
        myEphemeralId: 'bob_id',
        myPublicKey: 'bob_perm',
        myDisplayName: 'Bob',
        sendMessage: (msg) async =>
            await aliceCoordinator1.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator1.startHandshake();

      final initialContact = await aliceContactRepo.getContact('bob_id');
      final initialTime = initialContact!.lastHandshakeTime;

      // Mark expired
      await aliceContactRepo.updateNoiseSession(
        publicKey: 'bob_id',
        noisePublicKey: initialContact.noisePublicKey!,
        sessionState: 'expired',
      );

      // Wait a bit to ensure timestamp difference
      await Future.delayed(const Duration(milliseconds: 100));

      // Rekey
      await aliceContactRepo.updateNoiseSession(
        publicKey: 'bob_id',
        noisePublicKey: '',
        sessionState: 'handshaking',
      );

      late HandshakeCoordinator aliceCoordinator2;
      late HandshakeCoordinator bobCoordinator2;

      aliceCoordinator2 = HandshakeCoordinator(
        myEphemeralId: 'alice_id',
        myPublicKey: 'alice_perm',
        myDisplayName: 'Alice',
        sendMessage: (msg) async =>
            await bobCoordinator2.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {
          if (aliceCoordinator2.theirNoisePublicKey != null) {
            await aliceContactRepo.updateNoiseSession(
              publicKey: id,
              noisePublicKey: aliceCoordinator2.theirNoisePublicKey!,
              sessionState: 'established',
            );
          }
        },
      );

      bobCoordinator2 = HandshakeCoordinator(
        myEphemeralId: 'bob_id',
        myPublicKey: 'bob_perm',
        myDisplayName: 'Bob',
        sendMessage: (msg) async =>
            await aliceCoordinator2.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator2.startHandshake();

      final rekeyedContact = await aliceContactRepo.getContact('bob_id');
      expect(rekeyedContact?.noiseSessionState, 'established');
      final lastHandshake = rekeyedContact!.lastHandshakeTime!;
      expect(
        !lastHandshake.isBefore(initialTime!),
        true,
        reason: 'Rekeyed session should refresh or retain the latest timestamp',
      );
    });

    test('Encryption without session returns null', () async {
      final plaintext = Uint8List.fromList(utf8.encode('test'));
      final result = await SecurityManager.instance.noiseService!.encrypt(
        plaintext,
        'unknown_peer',
      );

      expect(result, isNull, reason: 'Should return null for unknown peer');
    });

    test('Large message (10KB) encryption and decryption', () async {
      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();

      late HandshakeCoordinator aliceCoordinator;
      late HandshakeCoordinator bobCoordinator;

      aliceCoordinator = HandshakeCoordinator(
        myEphemeralId: 'alice_id',
        myPublicKey: 'alice_perm',
        myDisplayName: 'Alice',
        sendMessage: (msg) async =>
            await bobCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {
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
        sendMessage: (msg) async =>
            await aliceCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator.startHandshake();

      // 10KB message
      final largeMessage = 'A' * 10240;
      final plaintext = Uint8List.fromList(utf8.encode(largeMessage));

      final ciphertext = await SecurityManager.instance.noiseService!.encrypt(
        plaintext,
        'bob_id',
      );
      expect(ciphertext, isNotNull);

      if (ciphertext != null) {
        final decrypted = await SecurityManager.instance.noiseService!.decrypt(
          ciphertext,
          'alice_id',
        );
        expect(decrypted, isNotNull);
        if (decrypted != null) {
          expect(utf8.decode(decrypted), largeMessage);
        }
      }
    });

    test('10 sequential messages maintain session integrity', () async {
      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();

      late HandshakeCoordinator aliceCoordinator;
      late HandshakeCoordinator bobCoordinator;

      aliceCoordinator = HandshakeCoordinator(
        myEphemeralId: 'alice_id',
        myPublicKey: 'alice_perm',
        myDisplayName: 'Alice',
        sendMessage: (msg) async =>
            await bobCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {
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
        sendMessage: (msg) async =>
            await aliceCoordinator.handleReceivedMessage(msg),
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator.startHandshake();

      // Send 10 messages
      for (int i = 0; i < 10; i++) {
        final message = 'Message #$i';
        final plaintext = Uint8List.fromList(utf8.encode(message));

        final ciphertext = await SecurityManager.instance.noiseService!.encrypt(
          plaintext,
          'bob_id',
        );
        expect(ciphertext, isNotNull);

        if (ciphertext != null) {
          final decrypted = await SecurityManager.instance.noiseService!
              .decrypt(ciphertext, 'alice_id');
          expect(decrypted, isNotNull);
          if (decrypted != null) {
            expect(utf8.decode(decrypted), message);
          }
        }
      }

      // Verify session still valid
      final contact = await aliceContactRepo.getContact('bob_id');
      expect(contact?.noiseSessionState, 'established');
    });
  });
}
