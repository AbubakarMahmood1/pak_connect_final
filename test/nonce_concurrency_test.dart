// Nonce Concurrency Test
//
// Tests concurrent encryption operations to validate unique nonce usage.
// This test verifies the race condition described in docs/review/CONFIDENCE_GAPS.md.
//
// **Purpose**: Ensure that concurrent encrypt() calls produce unique nonces
// and do not cause nonce collision (which would break ChaCha20-Poly1305 security).
//
// **Context**: The NoiseSession.encrypt() method has two sequential operations:
// 1. getNonce() - retrieves current nonce
// 2. encryptWithAd() - encrypts data and increments nonce
//
// If two concurrent Future.wait() calls interleave between these steps,
// they could retrieve the SAME nonce, leading to catastrophic crypto failure.
//
// **Test Strategy**:
// - Create a single established Noise session (Alice -> Bob)
// - Encrypt 100 messages concurrently using Future.wait()
// - Extract nonces from ciphertext (first 4 bytes)
// - Verify all 100 nonces are unique
//
// **Expected Result**:
// - PASS: All 100 nonces unique (no race condition, or serialization prevents it)
// - FAIL: < 100 unique nonces (race condition confirmed)

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/bluetooth/handshake_coordinator.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'test_helpers/test_setup.dart';

// Mock secure storage
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
  final logger = Logger('NonceTest');

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
    mockStorage = MockSecureStorage();
    await SecurityManager.initialize(secureStorage: mockStorage);

    // Enable detailed logging for debugging
    Logger.root.level = Level.ALL;
  });

  setUp(() async {
    await TestSetup.fullDatabaseReset();
    TestSetup.resetSharedPreferences();
  });

  tearDown(() async {
    await TestSetup.completeCleanup();
  });

  tearDownAll(() async {
    SecurityManager.shutdown();
    await DatabaseHelper.deleteDatabase();
  });

  group('Nonce Concurrency Tests', () {
    test('concurrent encryption operations use unique nonces', () async {
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logger.info('STARTING NONCE CONCURRENCY TEST');
      logger.info(
        'Testing 100 concurrent encrypt() calls for nonce uniqueness',
      );
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

      // ═══════════════════════════════════════════════════════════
      // PHASE 1: Establish Noise Session
      // ═══════════════════════════════════════════════════════════
      logger.info('PHASE 1: Establishing Noise session between Alice and Bob');

      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();

      late HandshakeCoordinator aliceCoordinator;
      late HandshakeCoordinator bobCoordinator;

      aliceCoordinator = HandshakeCoordinator(
        myEphemeralId: 'alice_ephemeral',
        myPublicKey: 'alice_persistent',
        myDisplayName: 'Alice',
        contactRepo: aliceContactRepo,
        sendMessage: (msg) async {
          logger.fine('Alice → Bob: ${msg.type}');
          await Future.delayed(Duration(milliseconds: 1));
          await bobCoordinator.handleReceivedMessage(msg);
        },
        onHandshakeComplete: (id, name, noiseKey) async {
          logger.info('✅ Alice handshake complete with $id');
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
        myEphemeralId: 'bob_ephemeral',
        myPublicKey: 'bob_persistent',
        myDisplayName: 'Bob',
        contactRepo: bobContactRepo,
        sendMessage: (msg) async {
          logger.fine('Bob → Alice: ${msg.type}');
          await Future.delayed(Duration(milliseconds: 1));
          await aliceCoordinator.handleReceivedMessage(msg);
        },
        onHandshakeComplete: (id, name, noiseKey) async {
          logger.info('✅ Bob handshake complete with $id');
        },
      );

      // Complete XX handshake (3 messages)
      await aliceCoordinator.startHandshake();

      // Verify session is established
      final noiseManager = SecurityManager.noiseService!;
      final hasAliceSession = noiseManager.hasEstablishedSession(
        'bob_ephemeral',
      );

      expect(
        hasAliceSession,
        isTrue,
        reason: 'Alice should have established session to Bob',
      );

      logger.info('✅ Noise session established\n');

      // ═══════════════════════════════════════════════════════════
      // PHASE 2: Concurrent Encryption (100 messages)
      // ═══════════════════════════════════════════════════════════
      logger.info('PHASE 2: Encrypting 100 messages concurrently');
      logger.info('This tests for nonce race condition between:');
      logger.info('  1. getNonce() call');
      logger.info('  2. encryptWithAd() call');
      logger.info(
        'If race exists, same nonce will be used by multiple messages\n',
      );

      const messageCount = 100;
      final stopwatch = Stopwatch()..start();

      // Encrypt 100 messages concurrently
      final encryptFutures = List.generate(messageCount, (i) {
        final message = 'Test message #$i';
        final plaintext = Uint8List.fromList(utf8.encode(message));
        return noiseManager.encrypt(plaintext, 'bob_ephemeral');
      });

      final ciphertexts = await Future.wait(encryptFutures);
      stopwatch.stop();

      logger.info(
        '✅ Encrypted $messageCount messages in ${stopwatch.elapsedMilliseconds}ms',
      );
      logger.info(
        '   Average: ${stopwatch.elapsedMilliseconds / messageCount}ms per message\n',
      );

      // ═══════════════════════════════════════════════════════════
      // PHASE 3: Extract and Verify Nonces
      // ═══════════════════════════════════════════════════════════
      logger.info('PHASE 3: Extracting nonces from ciphertext');
      logger.info('Nonce format: First 4 bytes of ciphertext (big-endian)\n');

      // Extract nonces from ciphertext (first 4 bytes)
      final nonces = <int>[];
      final nonceSet = <int>{};

      for (int i = 0; i < ciphertexts.length; i++) {
        final ciphertext = ciphertexts[i];

        expect(
          ciphertext,
          isNotNull,
          reason: 'Ciphertext $i should not be null',
        );
        expect(
          ciphertext!.length,
          greaterThanOrEqualTo(4),
          reason: 'Ciphertext $i too small (need 4-byte nonce)',
        );

        // Extract 4-byte nonce (big-endian)
        final nonceBytes = ciphertext.sublist(0, 4);
        final nonce = ByteData.view(nonceBytes.buffer).getUint32(0, Endian.big);

        nonces.add(nonce);
        nonceSet.add(nonce);

        // Log first 10 and last 10 nonces for inspection
        if (i < 10 || i >= messageCount - 10) {
          logger.fine(
            'Message $i nonce: $nonce (0x${nonce.toRadixString(16).padLeft(8, '0')})',
          );
        } else if (i == 10) {
          logger.fine('... (${messageCount - 20} more) ...');
        }
      }

      logger.info('\n✅ Extracted $messageCount nonces\n');

      // ═══════════════════════════════════════════════════════════
      // PHASE 4: Analyze Results
      // ═══════════════════════════════════════════════════════════
      logger.info('PHASE 4: Analyzing nonce uniqueness');

      final uniqueNonceCount = nonceSet.length;
      final duplicateCount = messageCount - uniqueNonceCount;

      logger.info('Results:');
      logger.info('  Total messages:  $messageCount');
      logger.info('  Unique nonces:   $uniqueNonceCount');
      logger.info('  Duplicate nonces: $duplicateCount');

      if (duplicateCount > 0) {
        logger.severe(
          '❌ RACE CONDITION CONFIRMED - Duplicate nonces detected!',
        );

        // Find and log duplicate nonces
        final nonceCounts = <int, int>{};
        for (final nonce in nonces) {
          nonceCounts[nonce] = (nonceCounts[nonce] ?? 0) + 1;
        }

        final duplicateNonces =
            nonceCounts.entries.where((e) => e.value > 1).toList()
              ..sort((a, b) => b.value.compareTo(a.value));

        logger.severe('Top duplicate nonces:');
        for (final entry in duplicateNonces.take(5)) {
          final nonce = entry.key;
          final count = entry.value;
          logger.severe(
            '  Nonce $nonce (0x${nonce.toRadixString(16).padLeft(8, '0')}): used $count times',
          );
        }

        // Find which messages share the same nonce
        for (final entry in duplicateNonces.take(3)) {
          final nonce = entry.key;
          final indices = <int>[];
          for (int i = 0; i < nonces.length; i++) {
            if (nonces[i] == nonce) {
              indices.add(i);
            }
          }
          logger.severe('  Messages sharing nonce $nonce: $indices');
        }
      } else {
        logger.info('✅ NO RACE CONDITION - All nonces are unique!');
      }

      // Verify nonces are sequential (or close to it)
      final sortedNonces = List<int>.from(nonces)..sort();
      final minNonce = sortedNonces.first;
      final maxNonce = sortedNonces.last;
      final expectedRange = messageCount - 1;
      final actualRange = maxNonce - minNonce;

      logger.info('\nNonce sequencing:');
      logger.info(
        '  Min nonce: $minNonce (0x${minNonce.toRadixString(16).padLeft(8, '0')})',
      );
      logger.info(
        '  Max nonce: $maxNonce (0x${maxNonce.toRadixString(16).padLeft(8, '0')})',
      );
      logger.info('  Expected range: $expectedRange');
      logger.info('  Actual range:   $actualRange');

      if (actualRange == expectedRange) {
        logger.info('✅ Nonces are perfectly sequential (no gaps)');
      } else {
        logger.warning('⚠️  Nonce range mismatch (gaps detected)');
      }

      logger.info('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logger.info('TEST COMPLETE');
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

      // ═══════════════════════════════════════════════════════════
      // ASSERTIONS
      // ═══════════════════════════════════════════════════════════

      // PRIMARY ASSERTION: All nonces must be unique
      expect(
        uniqueNonceCount,
        equals(messageCount),
        reason:
            'All $messageCount messages must use unique nonces. '
            'Found $duplicateCount duplicates. '
            'This indicates a race condition in NoiseSession.encrypt()',
      );

      // SECONDARY ASSERTION: Nonces should be sequential (no gaps)
      // This is less critical but indicates proper synchronization
      expect(
        actualRange,
        equals(expectedRange),
        reason:
            'Nonces should be sequential without gaps. '
            'Expected range 0-${expectedRange - 1}, got $minNonce-$maxNonce',
      );
    });

    test('sequential encryption operations produce sequential nonces', () async {
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      logger.info('BASELINE TEST: Sequential Encryption');
      logger.info(
        'This test verifies nonces increment correctly WITHOUT concurrency',
      );
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

      // Establish session (same as concurrent test)
      final aliceContactRepo = ContactRepository();
      final bobContactRepo = ContactRepository();

      late HandshakeCoordinator aliceCoordinator;
      late HandshakeCoordinator bobCoordinator;

      aliceCoordinator = HandshakeCoordinator(
        myEphemeralId: 'alice_ephemeral',
        myPublicKey: 'alice_persistent',
        myDisplayName: 'Alice',
        contactRepo: aliceContactRepo,
        sendMessage: (msg) async {
          await Future.delayed(Duration(milliseconds: 1));
          await bobCoordinator.handleReceivedMessage(msg);
        },
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
        myEphemeralId: 'bob_ephemeral',
        myPublicKey: 'bob_persistent',
        myDisplayName: 'Bob',
        contactRepo: bobContactRepo,
        sendMessage: (msg) async {
          await Future.delayed(Duration(milliseconds: 1));
          await aliceCoordinator.handleReceivedMessage(msg);
        },
        onHandshakeComplete: (id, name, noiseKey) async {},
      );

      await aliceCoordinator.startHandshake();

      final noiseManager = SecurityManager.noiseService!;
      expect(noiseManager.hasEstablishedSession('bob_ephemeral'), isTrue);

      logger.info('✅ Noise session established\n');

      // Encrypt 100 messages SEQUENTIALLY
      logger.info('Encrypting 100 messages SEQUENTIALLY (await each)');
      const messageCount = 100;

      final nonces = <int>[];
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < messageCount; i++) {
        final message = 'Test message #$i';
        final plaintext = Uint8List.fromList(utf8.encode(message));
        final ciphertext = await noiseManager.encrypt(
          plaintext,
          'bob_ephemeral',
        );

        expect(ciphertext, isNotNull);
        expect(ciphertext!.length, greaterThanOrEqualTo(4));

        // Extract nonce
        final nonceBytes = ciphertext.sublist(0, 4);
        final nonce = ByteData.view(nonceBytes.buffer).getUint32(0, Endian.big);
        nonces.add(nonce);
      }

      stopwatch.stop();
      logger.info(
        '✅ Encrypted $messageCount messages in ${stopwatch.elapsedMilliseconds}ms',
      );
      logger.info(
        '   Average: ${stopwatch.elapsedMilliseconds / messageCount}ms per message\n',
      );

      // Verify nonces are unique and sequential
      final uniqueNonces = nonces.toSet();
      logger.info('Results:');
      logger.info('  Total messages:  $messageCount');
      logger.info('  Unique nonces:   ${uniqueNonces.length}');
      logger.info('  Duplicate nonces: ${messageCount - uniqueNonces.length}');

      expect(
        uniqueNonces.length,
        equals(messageCount),
        reason: 'Sequential encryption should produce unique nonces',
      );

      // Verify nonces increment by 1 each time
      for (int i = 1; i < nonces.length; i++) {
        final expected = nonces[0] + i;
        final actual = nonces[i];
        expect(
          actual,
          equals(expected),
          reason: 'Nonce at index $i should be $expected, got $actual',
        );
      }

      logger.info('✅ All nonces are sequential (N, N+1, N+2, ...)');
      logger.info('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    });
  });
}
