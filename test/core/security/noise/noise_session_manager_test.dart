import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/security/noise/noise_session_manager.dart';
import 'package:pak_connect/core/security/noise/noise_session.dart';

void main() {
  group('NoiseSessionManager', () {
    // Test keys
    late Uint8List aliceStaticPrivate;
    late Uint8List aliceStaticPublic;
    late Uint8List bobStaticPrivate;
    late Uint8List bobStaticPublic;

    // Log capture for asserting no unexpected SEVERE errors
    late List<LogRecord> logRecords;
    late Set<Pattern> allowedSevere;

    setUp(() {
      // Initialize log capture
      logRecords = [];
      allowedSevere = {};
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      // Alice static key pair
      aliceStaticPrivate = Uint8List.fromList([
        0x77,
        0x07,
        0x6d,
        0x0a,
        0x73,
        0x18,
        0xa5,
        0x7d,
        0x3c,
        0x16,
        0xc1,
        0x72,
        0x51,
        0xb2,
        0x66,
        0x45,
        0xdf,
        0x4c,
        0x2f,
        0x87,
        0xeb,
        0xc0,
        0x99,
        0x2a,
        0xb1,
        0x77,
        0xfb,
        0xa5,
        0x1d,
        0xb9,
        0x2c,
        0x2a,
      ]);
      aliceStaticPublic = Uint8List.fromList([
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

      // Bob static key pair
      bobStaticPrivate = Uint8List.fromList([
        0x5d,
        0xab,
        0x08,
        0x7e,
        0x62,
        0x4a,
        0x8a,
        0x4b,
        0x79,
        0xe1,
        0x7f,
        0x8b,
        0x83,
        0x80,
        0x0e,
        0xe6,
        0x6f,
        0x3b,
        0xb1,
        0x29,
        0x26,
        0x18,
        0xb6,
        0xfd,
        0x1c,
        0x2f,
        0x8b,
        0x27,
        0xff,
        0x88,
        0xe0,
        0xeb,
      ]);
      bobStaticPublic = Uint8List.fromList([
        0xde,
        0x9e,
        0xdb,
        0x7d,
        0x7b,
        0x7d,
        0xc1,
        0xb4,
        0xd3,
        0x5b,
        0x61,
        0xc2,
        0xec,
        0xe4,
        0x35,
        0x37,
        0x3f,
        0x83,
        0x43,
        0xc8,
        0x5b,
        0x78,
        0x67,
        0x4d,
        0xad,
        0xfc,
        0x7e,
        0x14,
        0x6f,
        0x88,
        0x2b,
        0x4f,
      ]);
    });

    void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

    tearDown(() {
      // Find all SEVERE logs
      final severe = logRecords.where((l) => l.level >= Level.SEVERE);

      // Filter out allowed SEVEREs
      final unexpected = severe.where(
        (l) => !allowedSevere.any(
          (p) => p is String
              ? l.message.contains(p)
              : (p as RegExp).hasMatch(l.message),
        ),
      );

      // Assert no unexpected SEVEREs
      expect(
        unexpected,
        isEmpty,
        reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
      );

      // Assert expected SEVEREs are present
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

    test('creates manager with keys', () {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      expect(manager.getActiveSessionCount(), equals(0));

      manager.shutdown();
    });

    test('initiates handshake as initiator', () async {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final message1 = await manager.initiateHandshake('Bob');

      expect(message1.length, equals(32));
      expect(manager.getActiveSessionCount(), equals(1));
      expect(
        manager.getSessionState('Bob'),
        equals(NoiseSessionState.handshaking),
      );

      manager.shutdown();
    });

    test('processes handshake message as responder', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Alice initiates
      final msg1 = await aliceManager.initiateHandshake('Bob');

      // Bob receives and responds
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);

      expect(msg2, isNotNull);
      expect(msg2!.length, equals(80));
      expect(bobManager.getActiveSessionCount(), equals(1));
      expect(
        bobManager.getSessionState('Alice'),
        equals(NoiseSessionState.handshaking),
      );

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('completes full handshake between two managers', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Track callbacks
      String? aliceEstablishedPeer;
      Uint8List? aliceReceivedKey;
      String? bobEstablishedPeer;
      Uint8List? bobReceivedKey;

      aliceManager.onSessionEstablished = (peerID, remoteKey) {
        aliceEstablishedPeer = peerID;
        aliceReceivedKey = remoteKey;
      };

      bobManager.onSessionEstablished = (peerID, remoteKey) {
        bobEstablishedPeer = peerID;
        bobReceivedKey = remoteKey;
      };

      // Complete handshake
      final msg1 = await aliceManager.initiateHandshake('Bob');
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);
      final msg3 = await aliceManager.processHandshakeMessage('Bob', msg2!);
      await bobManager.processHandshakeMessage('Alice', msg3!);

      // Verify both sessions established
      expect(aliceManager.hasEstablishedSession('Bob'), isTrue);
      expect(bobManager.hasEstablishedSession('Alice'), isTrue);

      // Verify callbacks fired
      expect(aliceEstablishedPeer, equals('Bob'));
      expect(bobEstablishedPeer, equals('Alice'));
      expect(aliceReceivedKey, equals(bobStaticPublic));
      expect(bobReceivedKey, equals(aliceStaticPublic));

      // Verify remote keys available
      expect(aliceManager.getRemoteStaticKey('Bob'), equals(bobStaticPublic));
      expect(bobManager.getRemoteStaticKey('Alice'), equals(aliceStaticPublic));

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('encrypts and decrypts messages between managers', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msg1 = await aliceManager.initiateHandshake('Bob');
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);
      final msg3 = await aliceManager.processHandshakeMessage('Bob', msg2!);
      await bobManager.processHandshakeMessage('Alice', msg3!);

      // Alice encrypts to Bob
      final plaintext1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted1 = await aliceManager.encrypt(plaintext1, 'Bob');
      final decrypted1 = await bobManager.decrypt(encrypted1, 'Alice');
      expect(decrypted1, equals(plaintext1));

      // Bob encrypts to Alice
      final plaintext2 = Uint8List.fromList([10, 20, 30]);
      final encrypted2 = await bobManager.encrypt(plaintext2, 'Alice');
      final decrypted2 = await aliceManager.decrypt(encrypted2, 'Bob');
      expect(decrypted2, equals(plaintext2));

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('manages multiple peer sessions', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      // Alice initiates with Bob and Charlie
      await aliceManager.initiateHandshake('Bob');
      await aliceManager.initiateHandshake('Charlie');

      expect(aliceManager.getActiveSessionCount(), equals(2));
      expect(
        aliceManager.getSessionState('Bob'),
        equals(NoiseSessionState.handshaking),
      );
      expect(
        aliceManager.getSessionState('Charlie'),
        equals(NoiseSessionState.handshaking),
      );

      aliceManager.shutdown();
    });

    test('removes session', () async {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      await manager.initiateHandshake('Bob');
      expect(manager.getActiveSessionCount(), equals(1));

      manager.removeSession('Bob');
      expect(manager.getActiveSessionCount(), equals(0));
      expect(manager.getSession('Bob'), isNull);

      manager.shutdown();
    });

    test('replacing session removes old one', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // First handshake
      final msg1a = await aliceManager.initiateHandshake('Bob');
      await bobManager.processHandshakeMessage('Alice', msg1a);

      // Alice initiates again (should remove old session)
      final msg1b = await aliceManager.initiateHandshake('Bob');

      expect(aliceManager.getActiveSessionCount(), equals(1));
      expect(msg1b.length, equals(32));
      expect(
        aliceManager.getSessionState('Bob'),
        equals(NoiseSessionState.handshaking),
      );

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('cannot encrypt without established session', () async {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      await manager.initiateHandshake('Bob');

      // Session exists but not established
      expect(
        () async => await manager.encrypt(Uint8List.fromList([1, 2, 3]), 'Bob'),
        throwsA(isA<StateError>()),
      );

      manager.shutdown();
    });

    test('cannot decrypt without session', () {
      // This test intentionally attempts decryption without a session
      allowSevere('No session found for Bob');

      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      expect(
        () async => await manager.decrypt(Uint8List.fromList([1, 2, 3]), 'Bob'),
        throwsA(isA<StateError>()),
      );

      manager.shutdown();
    });

    test('handshake failure triggers callback', () async {
      // This test intentionally sends invalid handshake messages
      allowSevere('Handshake failed');

      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      String? failedPeer;
      Exception? failedException;

      manager.onSessionFailed = (peerID, error) {
        failedPeer = peerID;
        failedException = error;
      };

      await manager.initiateHandshake('Bob');

      // Send invalid message
      try {
        await manager.processHandshakeMessage(
          'Bob',
          Uint8List(5),
        ); // Invalid size
      } catch (e) {
        // Expected
      }

      expect(failedPeer, equals('Bob'));
      expect(failedException, isNotNull);
      expect(
        manager.getSession('Bob'),
        isNull,
      ); // Session removed after failure

      manager.shutdown();
    });

    test('provides session statistics', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msg1 = await aliceManager.initiateHandshake('Bob');
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);
      final msg3 = await aliceManager.processHandshakeMessage('Bob', msg2!);
      await bobManager.processHandshakeMessage('Alice', msg3!);

      // Send some messages
      await aliceManager.encrypt(Uint8List.fromList([1, 2, 3]), 'Bob');
      await aliceManager.encrypt(Uint8List.fromList([4, 5, 6]), 'Bob');

      final stats = aliceManager.getAllStats();
      expect(stats.containsKey('Bob'), isTrue);
      expect(stats['Bob']!['state'], equals('established'));
      expect(stats['Bob']!['messagesSent'], equals(2));

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('gets handshake hash for channel binding', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msg1 = await aliceManager.initiateHandshake('Bob');
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);
      final msg3 = await aliceManager.processHandshakeMessage('Bob', msg2!);
      await bobManager.processHandshakeMessage('Alice', msg3!);

      final aliceHash = aliceManager.getHandshakeHash('Bob');
      final bobHash = bobManager.getHandshakeHash('Alice');

      expect(aliceHash, isNotNull);
      expect(bobHash, isNotNull);
      expect(aliceHash, equals(bobHash));

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('shutdown destroys all sessions', () async {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      await manager.initiateHandshake('Bob');
      await manager.initiateHandshake('Charlie');
      await manager.initiateHandshake('Dave');

      expect(manager.getActiveSessionCount(), equals(3));

      manager.shutdown();

      expect(manager.getActiveSessionCount(), equals(0));
    });

    test('concurrent handshakes with different peers', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Alice initiates with Bob using two different "identities"
      // (simulating concurrent handshakes)
      final msg1a = await aliceManager.initiateHandshake('Bob_Session1');
      final msg1b = await aliceManager.initiateHandshake('Bob_Session2');

      expect(aliceManager.getActiveSessionCount(), equals(2));
      expect(msg1a, isNot(equals(msg1b))); // Different ephemeral keys

      aliceManager.shutdown();
      bobManager.shutdown();
    });

    test('provides debug information', () async {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      await manager.initiateHandshake('Bob');

      final debugInfo = manager.getDebugInfo();

      expect(debugInfo, contains('Noise Session Manager'));
      expect(debugInfo, contains('Active sessions: 1'));
      expect(debugInfo, contains('Bob'));

      manager.shutdown();
    });

    test('getSession returns null for non-existent peer', () {
      final manager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      expect(manager.getSession('NonExistent'), isNull);

      manager.shutdown();
    });

    test(
      'hasEstablishedSession returns false for handshaking session',
      () async {
        final manager = NoiseSessionManager(
          localStaticPrivateKey: aliceStaticPrivate,
          localStaticPublicKey: aliceStaticPublic,
        );

        await manager.initiateHandshake('Bob');

        expect(manager.hasEstablishedSession('Bob'), isFalse);

        manager.shutdown();
      },
    );

    test('bidirectional message exchange', () async {
      final aliceManager = NoiseSessionManager(
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      final bobManager = NoiseSessionManager(
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msg1 = await aliceManager.initiateHandshake('Bob');
      final msg2 = await bobManager.processHandshakeMessage('Alice', msg1);
      final msg3 = await aliceManager.processHandshakeMessage('Bob', msg2!);
      await bobManager.processHandshakeMessage('Alice', msg3!);

      // Interleaved bidirectional messages
      final msgs = <Uint8List>[];

      msgs.add(
        await aliceManager.encrypt(Uint8List.fromList([1, 1, 1]), 'Bob'),
      );
      msgs.add(
        await bobManager.encrypt(Uint8List.fromList([2, 2, 2]), 'Alice'),
      );
      msgs.add(
        await aliceManager.encrypt(Uint8List.fromList([3, 3, 3]), 'Bob'),
      );
      msgs.add(
        await bobManager.encrypt(Uint8List.fromList([4, 4, 4]), 'Alice'),
      );

      expect(
        await bobManager.decrypt(msgs[0], 'Alice'),
        equals(Uint8List.fromList([1, 1, 1])),
      );
      expect(
        await aliceManager.decrypt(msgs[1], 'Bob'),
        equals(Uint8List.fromList([2, 2, 2])),
      );
      expect(
        await bobManager.decrypt(msgs[2], 'Alice'),
        equals(Uint8List.fromList([3, 3, 3])),
      );
      expect(
        await aliceManager.decrypt(msgs[3], 'Bob'),
        equals(Uint8List.fromList([4, 4, 4])),
      );

      aliceManager.shutdown();
      bobManager.shutdown();
    });
  });
}
