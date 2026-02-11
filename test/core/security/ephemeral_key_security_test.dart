//
// Diagnostic output is intentional in this security verification test.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';

/// 🔒 SECURITY TEST: Ephemeral Key Private Key Protection
///
/// This test verifies the critical security fix for issue #62:
/// Ephemeral signing private keys should NEVER be persisted to disk.
///
/// Security Requirements:
/// 1. Private keys are ONLY held in memory (never written to SharedPreferences)
/// 2. On app restart, fresh ephemeral key pairs are generated (not restored)
/// 3. Public keys and session metadata CAN be persisted (non-sensitive)
/// 4. Private key getter is restricted with @visibleForTesting annotation
///
/// Attack Vector Prevented:
/// - Session impersonation from compromised device or backup extraction
/// - Private key exposure through insecure SharedPreferences storage
///
/// Related Issue: https://github.com/AbubakarMahmood1/pak_connect_final/issues/62
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('🔒 Ephemeral Private Key Security', () {
    final List<LogRecord> logRecords = [];

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      // Clear SharedPreferences before each test
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance().then((prefs) => prefs.clear());
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('CRITICAL: Private key NEVER written to SharedPreferences', () async {
      // GIVEN: Initialize EphemeralKeyManager
      await EphemeralKeyManager.initialize('test-private-key-123');

      // Force session generation
      final sessionKey = EphemeralKeyManager.generateMyEphemeralKey();
      expect(sessionKey, isNotNull);

      // WHEN: Check SharedPreferences contents
      final prefs = await SharedPreferences.getInstance();
      final allKeys = prefs.getKeys();

      debugPrint('📋 SharedPreferences keys after initialization:');
      for (final key in allKeys) {
        final value = prefs.get(key).toString();
        final preview = value.length > 20 ? value.substring(0, 20) : value;
        debugPrint('  - $key: $preview${value.length > 20 ? "..." : ""}');
      }

      // THEN: Private key should NOT be in SharedPreferences
      expect(
        prefs.getString('ephemeral_signing_private'),
        isNull,
        reason:
            '🚨 SECURITY VULNERABILITY: Private key found in SharedPreferences! '
            'Private keys must NEVER be persisted to disk. '
            'This defeats the purpose of ephemeral keys and enables session impersonation.',
      );

      debugPrint('✅ PASS: No private key in SharedPreferences (secure)');
    });

    test(
      'Public key and session metadata CAN be persisted (non-sensitive)',
      () async {
        // GIVEN: Initialize EphemeralKeyManager
        await EphemeralKeyManager.initialize('test-private-key-456');
        EphemeralKeyManager.generateMyEphemeralKey();

        // WHEN: Check SharedPreferences for non-sensitive data
        final prefs = await SharedPreferences.getInstance();

        // THEN: Session metadata should be present (non-sensitive)
        expect(
          prefs.getString('current_ephemeral_session'),
          isNotNull,
          reason: 'Session key should be persisted (non-sensitive)',
        );

        expect(
          prefs.getInt('session_start_time'),
          isNotNull,
          reason: 'Session timestamp should be persisted (non-sensitive)',
        );

        // THEN: Public key should be present (non-sensitive)
        expect(
          prefs.getString('ephemeral_signing_public'),
          isNotNull,
          reason: 'Public key should be persisted (non-sensitive)',
        );

        debugPrint('✅ PASS: Non-sensitive data properly persisted');
      },
    );

    test('Fresh key pair generated on app restart (not restored from disk)', () async {
      // GIVEN: First app session
      await EphemeralKeyManager.initialize('test-private-key-789');
      EphemeralKeyManager.generateMyEphemeralKey();

      // Capture first session's keys (using @visibleForTesting getter)
      final firstPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;
      final firstPublicKey = EphemeralKeyManager.ephemeralSigningPublicKey;

      expect(firstPrivateKey, isNotNull);
      expect(firstPublicKey, isNotNull);

      debugPrint(
        '🔑 First session private key (first 16 chars): ${firstPrivateKey!.substring(0, 16)}...',
      );
      debugPrint(
        '🔑 First session public key (first 16 chars): ${firstPublicKey!.substring(0, 16)}...',
      );

      // WHEN: Simulate app restart by re-initializing
      // (In real app, this would be a full app restart clearing memory)
      await EphemeralKeyManager.initialize('test-private-key-789');
      EphemeralKeyManager.generateMyEphemeralKey();

      // Capture second session's keys
      final secondPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;
      final secondPublicKey = EphemeralKeyManager.ephemeralSigningPublicKey;

      expect(secondPrivateKey, isNotNull);
      expect(secondPublicKey, isNotNull);

      debugPrint(
        '🔑 Second session private key (first 16 chars): ${secondPrivateKey!.substring(0, 16)}...',
      );
      debugPrint(
        '🔑 Second session public key (first 16 chars): ${secondPublicKey!.substring(0, 16)}...',
      );

      // THEN: Keys should be DIFFERENT (fresh generation, not restoration)
      expect(
        secondPrivateKey,
        isNot(equals(firstPrivateKey)),
        reason:
            '🚨 SECURITY VULNERABILITY: Private key was restored from disk! '
            'Fresh keys must be generated on app restart, not restored from SharedPreferences. '
            'This is critical for ephemeral key security.',
      );

      expect(
        secondPublicKey,
        isNot(equals(firstPublicKey)),
        reason: 'Public key should also be fresh (paired with new private key)',
      );

      debugPrint(
        '✅ PASS: Fresh key pair generated on app restart (not restored)',
      );
    });

    test('Multiple restarts generate unique key pairs', () async {
      // GIVEN: Multiple app restart simulations
      final privateKeys = <String>[];
      final publicKeys = <String>[];

      for (int i = 0; i < 5; i++) {
        await EphemeralKeyManager.initialize('test-private-key-multi');
        EphemeralKeyManager.generateMyEphemeralKey();

        final privateKey = EphemeralKeyManager.ephemeralSigningPrivateKey!;
        final publicKey = EphemeralKeyManager.ephemeralSigningPublicKey!;

        privateKeys.add(privateKey);
        publicKeys.add(publicKey);

        debugPrint(
          '🔑 Restart $i - Private: ${privateKey.substring(0, 16)}..., Public: ${publicKey.substring(0, 16)}...',
        );

        // Small delay to ensure different timestamps
        await Future.delayed(Duration(milliseconds: 10));
      }

      // THEN: All private keys should be unique
      final uniquePrivateKeys = privateKeys.toSet();
      expect(
        uniquePrivateKeys.length,
        equals(privateKeys.length),
        reason:
            '🚨 SECURITY VULNERABILITY: Some private keys were reused! '
            'Expected ${privateKeys.length} unique private keys, got ${uniquePrivateKeys.length}. '
            'Each app restart must generate fresh keys.',
      );

      // THEN: All public keys should be unique
      final uniquePublicKeys = publicKeys.toSet();
      expect(
        uniquePublicKeys.length,
        equals(publicKeys.length),
        reason: 'Each restart should generate unique public keys',
      );

      debugPrint(
        '✅ PASS: All ${privateKeys.length} restarts generated unique key pairs',
      );
    });

    test('Private key exists in memory but not in SharedPreferences', () async {
      // GIVEN: Initialize EphemeralKeyManager
      await EphemeralKeyManager.initialize('test-private-key-memory');
      EphemeralKeyManager.generateMyEphemeralKey();

      // WHEN: Access private key from memory (via @visibleForTesting getter)
      final privateKeyInMemory = EphemeralKeyManager.ephemeralSigningPrivateKey;

      // THEN: Private key should exist in memory
      expect(
        privateKeyInMemory,
        isNotNull,
        reason: 'Private key should exist in memory for signing operations',
      );

      // THEN: But NOT in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final privateKeyInStorage = prefs.getString('ephemeral_signing_private');

      expect(
        privateKeyInStorage,
        isNull,
        reason:
            '🚨 SECURITY VULNERABILITY: Private key found in persistent storage! '
            'Private keys must only exist in memory, never persisted to disk.',
      );

      debugPrint(
        '✅ PASS: Private key exists in memory only (${privateKeyInMemory!.substring(0, 16)}...), not in storage',
      );
    });

    test('Session rotation generates new private key (not persisted)', () async {
      // GIVEN: Initial session
      await EphemeralKeyManager.initialize('test-private-key-rotate');
      EphemeralKeyManager.generateMyEphemeralKey();

      final initialPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;
      expect(initialPrivateKey, isNotNull);

      debugPrint(
        '🔑 Initial private key: ${initialPrivateKey!.substring(0, 16)}...',
      );

      // WHEN: Rotate session
      await EphemeralKeyManager.rotateSession();

      final rotatedPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;
      expect(rotatedPrivateKey, isNotNull);

      debugPrint(
        '🔑 Rotated private key: ${rotatedPrivateKey!.substring(0, 16)}...',
      );

      // THEN: Private key should be different after rotation
      expect(
        rotatedPrivateKey,
        isNot(equals(initialPrivateKey)),
        reason: 'Session rotation should generate new private key',
      );

      // THEN: New private key should NOT be in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('ephemeral_signing_private'),
        isNull,
        reason:
            '🚨 SECURITY VULNERABILITY: Rotated private key found in SharedPreferences!',
      );

      debugPrint(
        '✅ PASS: Session rotation generates new private key (not persisted)',
      );
    });

    test(
      'Manual SharedPreferences corruption does not affect key generation',
      () async {
        // GIVEN: Initialize and manually corrupt SharedPreferences
        await EphemeralKeyManager.initialize('test-private-key-corrupt');
        EphemeralKeyManager.generateMyEphemeralKey();

        final prefs = await SharedPreferences.getInstance();

        // Manually inject a "leaked" private key (simulating vulnerability)
        await prefs.setString(
          'ephemeral_signing_private',
          'fake-leaked-private-key-from-backup',
        );

        debugPrint(
          '💣 Manually injected fake private key into SharedPreferences',
        );

        // WHEN: Re-initialize (simulate app restart)
        await EphemeralKeyManager.initialize('test-private-key-corrupt');
        EphemeralKeyManager.generateMyEphemeralKey();

        final newPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey!;

        // THEN: New private key should NOT match the fake one
        expect(
          newPrivateKey,
          isNot(equals('fake-leaked-private-key-from-backup')),
          reason:
              '🚨 SECURITY VULNERABILITY: EphemeralKeyManager used corrupted/injected private key! '
              'It should ALWAYS generate fresh keys on initialization, ignoring any persisted value.',
        );

        // THEN: Fake private key should still exist (we don't delete it on read)
        // But it should be ignored and overwritten eventually
        debugPrint(
          '✅ PASS: Corrupted private key ignored, fresh key generated: ${newPrivateKey.substring(0, 16)}...',
        );
      },
    );

    test('No private key leakage after multiple operations', () async {
      // GIVEN: Multiple operations that could potentially leak private key
      await EphemeralKeyManager.initialize('test-private-key-ops');

      // Perform various operations
      for (int i = 0; i < 3; i++) {
        EphemeralKeyManager.generateMyEphemeralKey();
        await Future.delayed(Duration(milliseconds: 5));
      }

      // Rotate session
      await EphemeralKeyManager.rotateSession();

      // Generate more keys
      for (int i = 0; i < 3; i++) {
        EphemeralKeyManager.generateMyEphemeralKey();
        await Future.delayed(Duration(milliseconds: 5));
      }

      // WHEN: Check SharedPreferences after all operations
      final prefs = await SharedPreferences.getInstance();
      final allKeys = prefs.getKeys();

      debugPrint('📋 SharedPreferences after multiple operations:');
      for (final key in allKeys) {
        debugPrint('  - $key');
      }

      // THEN: Private key should NEVER appear in SharedPreferences
      expect(
        allKeys.contains('ephemeral_signing_private'),
        isFalse,
        reason:
            '🚨 SECURITY VULNERABILITY: Private key found in SharedPreferences after operations! '
            'No operation should ever persist private keys.',
      );

      debugPrint('✅ PASS: No private key leakage after multiple operations');
    });
  });

  group('🔒 Private Key Getter Access Control', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferences.getInstance().then((prefs) => prefs.clear());
    });

    test('Legacy private keys are removed on initialization', () async {
      // GIVEN: A legacy installation with persisted private key
      final prefs = await SharedPreferences.getInstance();

      // Simulate legacy installation by manually writing private key
      await prefs.setString(
        'ephemeral_signing_private',
        'legacy-private-key-from-old-version',
      );

      debugPrint('💾 Simulated legacy private key persisted to disk');

      // Verify it exists before initialization
      expect(
        prefs.getString('ephemeral_signing_private'),
        isNotNull,
        reason: 'Legacy private key should exist before cleanup',
      );

      // WHEN: Initialize EphemeralKeyManager (triggers cleanup)
      await EphemeralKeyManager.initialize('test-cleanup');
      EphemeralKeyManager.generateMyEphemeralKey();

      // THEN: Legacy private key should be removed
      expect(
        prefs.getString('ephemeral_signing_private'),
        isNull,
        reason:
            '🚨 SECURITY VULNERABILITY: Legacy private key not cleaned up! '
            'Existing installations will retain sensitive data after upgrade. '
            'Must explicitly remove old private keys on initialization.',
      );

      debugPrint('✅ PASS: Legacy private key cleaned up on initialization');
    });

    test('Private key getter accessible for internal components', () async {
      // This test verifies that the private key getter works for
      // trusted internal components like SigningManager
      // The @visibleForTesting annotation was removed to allow production use

      // GIVEN: Initialize EphemeralKeyManager
      await EphemeralKeyManager.initialize('test-internal-access');
      EphemeralKeyManager.generateMyEphemeralKey();

      // WHEN: Access private key (as SigningManager does)
      final privateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;

      // THEN: Should be accessible for internal use
      expect(
        privateKey,
        isNotNull,
        reason: 'Private key should be accessible for internal components',
      );

      debugPrint(
        '✅ PASS: Private key getter accessible for internal components (SigningManager)',
      );
    });
  });
}
