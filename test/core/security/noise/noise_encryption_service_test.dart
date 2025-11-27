import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/security/noise/noise_encryption_service.dart';
import 'package:pak_connect/core/security/noise/noise_session.dart';

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

  // Unused FlutterSecureStorage methods
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NoiseEncryptionService', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
      // Allow SEVERE logs from intentional error-handling tests
      allowedSevere.addAll([
        'Handshake failed',
        'Session failed',
        'Failed to decrypt',
        'Failed to process handshake',
        'MAC verification error',
      ]);
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
    });

    test('initializes and generates new keys', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      final publicKey = service.getStaticPublicKeyData();
      expect(publicKey.length, equals(32));

      final fingerprint = service.getIdentityFingerprint();
      expect(fingerprint.length, equals(64)); // SHA-256 hex = 64 chars

      service.shutdown();
    });

    test('throws StateError if not initialized', () {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      expect(
        () => service.getStaticPublicKeyData(),
        throwsA(isA<StateError>()),
      );
    });

    test('fingerprint is deterministic', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      final fingerprint1 = service.getIdentityFingerprint();
      final fingerprint2 = service.getIdentityFingerprint();

      expect(fingerprint1, equals(fingerprint2));

      service.shutdown();
    });

    test('calculateFingerprint static method works', () {
      final publicKey = Uint8List.fromList([
        0x85,
        0x20,
        0xf0,
        0x09,
        0x89,
        0x30,
        0xa7,
        0x54,
        0x74,
        0x8b,
        0x7d,
        0xdc,
        0xb4,
        0x3e,
        0xf7,
        0x5a,
        0x0d,
        0xbf,
        0x3a,
        0x0d,
        0x26,
        0x38,
        0x1a,
        0xf4,
        0xeb,
        0xa4,
        0xa9,
        0x8e,
        0xaa,
        0x9b,
        0x4e,
        0x6a,
      ]);

      final fingerprint = NoiseEncryptionService.calculateFingerprint(
        publicKey,
      );

      expect(fingerprint.length, equals(64));
      expect(fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('completes handshake between two services', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Track callbacks
      String? aliceAuthPeer;
      String? aliceAuthFingerprint;
      String? bobAuthPeer;
      String? bobAuthFingerprint;

      aliceService.onPeerAuthenticated = (peerID, fingerprint) {
        aliceAuthPeer = peerID;
        aliceAuthFingerprint = fingerprint;
      };

      bobService.onPeerAuthenticated = (peerID, fingerprint) {
        bobAuthPeer = peerID;
        bobAuthFingerprint = fingerprint;
      };

      // Complete handshake
      final msg1 = await aliceService.initiateHandshake('Bob');
      expect(msg1, isNotNull);
      expect(msg1!.length, equals(32));

      final msg2 = await bobService.processHandshakeMessage(msg1, 'Alice');
      expect(msg2, isNotNull);
      expect(msg2!.length, equals(80));

      final msg3 = await aliceService.processHandshakeMessage(msg2, 'Bob');
      expect(msg3, isNotNull);
      expect(msg3!.length, equals(48));

      final msg4 = await bobService.processHandshakeMessage(msg3, 'Alice');
      expect(msg4, isNull); // Handshake complete

      // Verify sessions established
      expect(aliceService.hasEstablishedSession('Bob'), isTrue);
      expect(bobService.hasEstablishedSession('Alice'), isTrue);

      // Verify callbacks fired
      expect(aliceAuthPeer, equals('Bob'));
      expect(bobAuthPeer, equals('Alice'));
      expect(aliceAuthFingerprint, isNotNull);
      expect(bobAuthFingerprint, isNotNull);

      // Verify fingerprints match expected values
      final bobFingerprint = bobService.getIdentityFingerprint();
      final aliceFingerprint = aliceService.getIdentityFingerprint();
      expect(aliceAuthFingerprint, equals(bobFingerprint));
      expect(bobAuthFingerprint, equals(aliceFingerprint));

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('encrypts and decrypts messages', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Complete handshake
      final msg1 = await aliceService.initiateHandshake('Bob');
      final msg2 = await bobService.processHandshakeMessage(msg1!, 'Alice');
      final msg3 = await aliceService.processHandshakeMessage(msg2!, 'Bob');
      await bobService.processHandshakeMessage(msg3!, 'Alice');

      // Alice encrypts to Bob
      final plaintext1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted1 = await aliceService.encrypt(plaintext1, 'Bob');
      expect(encrypted1, isNotNull);

      final decrypted1 = await bobService.decrypt(encrypted1!, 'Alice');
      expect(decrypted1, isNotNull);
      expect(decrypted1, equals(plaintext1));

      // Bob encrypts to Alice
      final plaintext2 = Uint8List.fromList([10, 20, 30]);
      final encrypted2 = await bobService.encrypt(plaintext2, 'Alice');
      expect(encrypted2, isNotNull);

      final decrypted2 = await aliceService.decrypt(encrypted2!, 'Bob');
      expect(decrypted2, isNotNull);
      expect(decrypted2, equals(plaintext2));

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('encrypt returns null without established session', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      bool handshakeRequiredCalled = false;
      service.onHandshakeRequired = (peerID) {
        handshakeRequiredCalled = true;
      };

      final result = await service.encrypt(
        Uint8List.fromList([1, 2, 3]),
        'Bob',
      );

      expect(result, isNull);
      expect(handshakeRequiredCalled, isTrue);

      service.shutdown();
    });

    test('decrypt returns null without established session', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      final result = await service.decrypt(
        Uint8List.fromList([1, 2, 3]),
        'Bob',
      );

      expect(result, isNull);

      service.shutdown();
    });

    test('getPeerPublicKeyData returns peer key after handshake', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Before handshake
      expect(aliceService.getPeerPublicKeyData('Bob'), isNull);

      // Complete handshake
      final msg1 = await aliceService.initiateHandshake('Bob');
      final msg2 = await bobService.processHandshakeMessage(msg1!, 'Alice');
      final msg3 = await aliceService.processHandshakeMessage(msg2!, 'Bob');
      await bobService.processHandshakeMessage(msg3!, 'Alice');

      // After handshake
      final bobPubKey = aliceService.getPeerPublicKeyData('Bob');
      expect(bobPubKey, isNotNull);
      expect(bobPubKey!.length, equals(32));
      expect(bobPubKey, equals(bobService.getStaticPublicKeyData()));

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('getSessionState returns correct state', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Uninitialized
      expect(
        aliceService.getSessionState('Bob'),
        equals(NoiseSessionState.uninitialized),
      );

      // Handshaking
      final msg1 = await aliceService.initiateHandshake('Bob');
      expect(
        aliceService.getSessionState('Bob'),
        equals(NoiseSessionState.handshaking),
      );

      // Still handshaking
      final msg2 = await bobService.processHandshakeMessage(msg1!, 'Alice');
      expect(
        bobService.getSessionState('Alice'),
        equals(NoiseSessionState.handshaking),
      );

      // Established
      final msg3 = await aliceService.processHandshakeMessage(msg2!, 'Bob');
      expect(
        aliceService.getSessionState('Bob'),
        equals(NoiseSessionState.established),
      );

      await bobService.processHandshakeMessage(msg3!, 'Alice');
      expect(
        bobService.getSessionState('Alice'),
        equals(NoiseSessionState.established),
      );

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('removeSession clears session', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Complete handshake
      final msg1 = await aliceService.initiateHandshake('Bob');
      final msg2 = await bobService.processHandshakeMessage(msg1!, 'Alice');
      final msg3 = await aliceService.processHandshakeMessage(msg2!, 'Bob');
      await bobService.processHandshakeMessage(msg3!, 'Alice');

      expect(aliceService.hasEstablishedSession('Bob'), isTrue);

      // Remove session
      aliceService.removeSession('Bob');

      expect(aliceService.hasEstablishedSession('Bob'), isFalse);
      expect(
        aliceService.getSessionState('Bob'),
        equals(NoiseSessionState.uninitialized),
      );

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('getAllSessionStats returns statistics', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Complete handshake
      final msg1 = await aliceService.initiateHandshake('Bob');
      final msg2 = await bobService.processHandshakeMessage(msg1!, 'Alice');
      final msg3 = await aliceService.processHandshakeMessage(msg2!, 'Bob');
      await bobService.processHandshakeMessage(msg3!, 'Alice');

      // Send some messages
      await aliceService.encrypt(Uint8List.fromList([1, 2, 3]), 'Bob');
      await aliceService.encrypt(Uint8List.fromList([4, 5, 6]), 'Bob');

      final stats = aliceService.getAllSessionStats();

      expect(stats.containsKey('Bob'), isTrue);
      expect(stats['Bob']!['state'], equals('established'));
      expect(stats['Bob']!['messagesSent'], equals(2));

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('shutdown clears all sessions', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      await service.initiateHandshake('Bob');
      await service.initiateHandshake('Charlie');

      final stats = service.getAllSessionStats();
      expect(stats.length, equals(2));

      service.shutdown();

      // After shutdown, service should not work
      expect(
        () => service.getStaticPublicKeyData(),
        throwsA(isA<StateError>()),
      );
    });

    test('can initialize twice (idempotent)', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await service.initialize();
      final fingerprint1 = service.getIdentityFingerprint();

      await service.initialize(); // Second init should be no-op
      final fingerprint2 = service.getIdentityFingerprint();

      expect(fingerprint1, equals(fingerprint2));

      service.shutdown();
    });

    test('handles handshake failure gracefully', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      await service.initiateHandshake('Bob');

      // Send invalid message
      final result = await service.processHandshakeMessage(
        Uint8List(5), // Invalid size
        'Bob',
      );

      expect(result, isNull); // Failed, returns null

      service.shutdown();
    });

    test('multiple peers independently', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final charlieService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();
      await charlieService.initialize();

      // Alice -> Bob handshake
      var msg = await aliceService.initiateHandshake('Bob');
      msg = await bobService.processHandshakeMessage(msg!, 'Alice');
      msg = await aliceService.processHandshakeMessage(msg!, 'Bob');
      await bobService.processHandshakeMessage(msg!, 'Alice');

      // Alice -> Charlie handshake
      msg = await aliceService.initiateHandshake('Charlie');
      msg = await charlieService.processHandshakeMessage(msg!, 'Alice');
      msg = await aliceService.processHandshakeMessage(msg!, 'Charlie');
      await charlieService.processHandshakeMessage(msg!, 'Alice');

      // Verify both sessions work
      expect(aliceService.hasEstablishedSession('Bob'), isTrue);
      expect(aliceService.hasEstablishedSession('Charlie'), isTrue);

      // Alice can encrypt to both
      final toBob = await aliceService.encrypt(Uint8List.fromList([1]), 'Bob');
      final toCharlie = await aliceService.encrypt(
        Uint8List.fromList([2]),
        'Charlie',
      );

      expect(toBob, isNotNull);
      expect(toCharlie, isNotNull);

      final fromAlice1 = await bobService.decrypt(toBob!, 'Alice');
      final fromAlice2 = await charlieService.decrypt(toCharlie!, 'Alice');

      expect(fromAlice1, equals(Uint8List.fromList([1])));
      expect(fromAlice2, equals(Uint8List.fromList([2])));

      aliceService.shutdown();
      bobService.shutdown();
      charlieService.shutdown();
    });

    test('bidirectional message exchange', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Complete handshake
      var msg = await aliceService.initiateHandshake('Bob');
      msg = await bobService.processHandshakeMessage(msg!, 'Alice');
      msg = await aliceService.processHandshakeMessage(msg!, 'Bob');
      await bobService.processHandshakeMessage(msg!, 'Alice');

      // Interleaved messages
      final msgs = <Uint8List?>[];
      msgs.add(
        await aliceService.encrypt(Uint8List.fromList([1, 1, 1]), 'Bob'),
      );
      msgs.add(
        await bobService.encrypt(Uint8List.fromList([2, 2, 2]), 'Alice'),
      );
      msgs.add(
        await aliceService.encrypt(Uint8List.fromList([3, 3, 3]), 'Bob'),
      );
      msgs.add(
        await bobService.encrypt(Uint8List.fromList([4, 4, 4]), 'Alice'),
      );

      expect(
        await bobService.decrypt(msgs[0]!, 'Alice'),
        equals(Uint8List.fromList([1, 1, 1])),
      );
      expect(
        await aliceService.decrypt(msgs[1]!, 'Bob'),
        equals(Uint8List.fromList([2, 2, 2])),
      );
      expect(
        await bobService.decrypt(msgs[2]!, 'Alice'),
        equals(Uint8List.fromList([3, 3, 3])),
      );
      expect(
        await aliceService.decrypt(msgs[3]!, 'Bob'),
        equals(Uint8List.fromList([4, 4, 4])),
      );

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('checkForRekeyNeeded returns empty list initially', () async {
      final service = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      await service.initialize();

      final needsRekey = service.checkForRekeyNeeded();
      expect(needsRekey, isEmpty);

      service.shutdown();
    });

    test('decrypt returns null on corrupted data', () async {
      final aliceService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );
      final bobService = NoiseEncryptionService(
        secureStorage: MockSecureStorage(),
      );

      await aliceService.initialize();
      await bobService.initialize();

      // Complete handshake
      var msg = await aliceService.initiateHandshake('Bob');
      msg = await bobService.processHandshakeMessage(msg!, 'Alice');
      msg = await aliceService.processHandshakeMessage(msg!, 'Bob');
      await bobService.processHandshakeMessage(msg!, 'Alice');

      // Encrypt valid message
      final encrypted = await aliceService.encrypt(
        Uint8List.fromList([1, 2, 3]),
        'Bob',
      );

      // Corrupt it
      final corrupted = Uint8List.fromList(encrypted!);
      corrupted[corrupted.length ~/ 2] ^= 0xFF;

      // Decryption should fail (returns null)
      final result = await bobService.decrypt(corrupted, 'Alice');
      expect(result, isNull);

      aliceService.shutdown();
      bobService.shutdown();
    });

    test('persists and loads keys from storage', () async {
      final storage = MockSecureStorage();

      // First service generates keys
      final service1 = NoiseEncryptionService(secureStorage: storage);
      await service1.initialize();
      final fingerprint1 = service1.getIdentityFingerprint();
      service1.shutdown();

      // Second service loads same keys
      final service2 = NoiseEncryptionService(secureStorage: storage);
      await service2.initialize();
      final fingerprint2 = service2.getIdentityFingerprint();

      expect(fingerprint1, equals(fingerprint2));
      service2.shutdown();
    });
  });
}
