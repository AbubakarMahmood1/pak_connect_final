import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/noise_session.dart';

void main() {
  group('NoiseSession - Session Lifecycle', () {
    // Test keys
    late Uint8List aliceStaticPrivate;
    late Uint8List aliceStaticPublic;
    late Uint8List bobStaticPrivate;
    late Uint8List bobStaticPublic;

    setUp(() {
      // Alice static key pair (hex from previous tests)
      aliceStaticPrivate = Uint8List.fromList([
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
        0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
        0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
      ]);
      aliceStaticPublic = Uint8List.fromList([
        0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54,
        0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a,
        0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4,
        0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a,
      ]);

      // Bob static key pair (hex from previous tests)
      bobStaticPrivate = Uint8List.fromList([
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b,
        0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd,
        0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
      ]);
      bobStaticPublic = Uint8List.fromList([
        0xde, 0x9e, 0xdb, 0x7d, 0x7b, 0x7d, 0xc1, 0xb4,
        0xd3, 0x5b, 0x61, 0xc2, 0xec, 0xe4, 0x35, 0x37,
        0x3f, 0x83, 0x43, 0xc8, 0x5b, 0x78, 0x67, 0x4d,
        0xad, 0xfc, 0x7e, 0x14, 0x6f, 0x88, 0x2b, 0x4f,
      ]);
    });

    test('creates initiator session', () {
      final session = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      expect(session.peerID, equals('Bob'));
      expect(session.state, equals(NoiseSessionState.uninitialized));
      expect(session.isInitiator, isTrue);
      
      session.destroy();
    });

    test('creates responder session', () {
      final session = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      expect(session.peerID, equals('Alice'));
      expect(session.state, equals(NoiseSessionState.uninitialized));
      expect(session.isInitiator, isFalse);
      
      session.destroy();
    });

    test('complete XX handshake initiator and responder', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Message A: Alice -> Bob
      final messageA = await alice.startHandshake();
      expect(messageA.length, equals(32));
      expect(alice.state, equals(NoiseSessionState.handshaking));

      // Message B: Bob -> Alice
      final messageB = await bob.processHandshakeMessage(messageA);
      expect(messageB, isNotNull);
      expect(messageB!.length, equals(80));
      expect(bob.state, equals(NoiseSessionState.handshaking));

      // Message C: Alice -> Bob
      final messageC = await alice.processHandshakeMessage(messageB);
      expect(messageC, isNotNull);
      expect(messageC!.length, equals(48));
      expect(alice.state, equals(NoiseSessionState.established));

      // Complete: Bob processes message C
      final messageD = await bob.processHandshakeMessage(messageC);
      expect(messageD, isNull);
      expect(bob.state, equals(NoiseSessionState.established));

      // Verify remote static keys are exchanged
      expect(alice.remoteStaticPublicKey, equals(bobStaticPublic));
      expect(bob.remoteStaticPublicKey, equals(aliceStaticPublic));
      
      alice.destroy();
      bob.destroy();
    });

    test('encrypt and decrypt messages after handshake', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final messageA = await alice.startHandshake();
      final messageB = await bob.processHandshakeMessage(messageA);
      final messageC = await alice.processHandshakeMessage(messageB!);
      await bob.processHandshakeMessage(messageC!);

      // Test encryption Alice -> Bob
      final plaintext1 = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted1 = await alice.encrypt(plaintext1);
      expect(encrypted1.length, greaterThan(plaintext1.length));
      
      final decrypted1 = await bob.decrypt(encrypted1);
      expect(decrypted1, equals(plaintext1));

      // Test encryption Bob -> Alice
      final plaintext2 = Uint8List.fromList([10, 20, 30, 40, 50]);
      final encrypted2 = await bob.encrypt(plaintext2);
      
      final decrypted2 = await alice.decrypt(encrypted2);
      expect(decrypted2, equals(plaintext2));
      
      alice.destroy();
      bob.destroy();
    });

    test('nonces increment correctly', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Send multiple messages and verify nonces are different
      final msg = Uint8List.fromList([1, 2, 3]);
      
      final enc1 = await alice.encrypt(msg);
      final enc2 = await alice.encrypt(msg);
      final enc3 = await alice.encrypt(msg);
      
      // Encrypted messages should be different (different nonces)
      expect(enc1, isNot(equals(enc2)));
      expect(enc2, isNot(equals(enc3)));
      expect(enc1, isNot(equals(enc3)));
      
      // But all should decrypt correctly
      expect(await bob.decrypt(enc1), equals(msg));
      expect(await bob.decrypt(enc2), equals(msg));
      expect(await bob.decrypt(enc3), equals(msg));
      
      alice.destroy();
      bob.destroy();
    });

    test('replay protection rejects old messages', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      final msg = Uint8List.fromList([1, 2, 3]);
      final encrypted = await alice.encrypt(msg);
      
      // First decryption should work
      expect(await bob.decrypt(encrypted), equals(msg));
      
      // Replay should fail
      expect(
        () async => await bob.decrypt(encrypted),
        throwsA(anything),
      );
      
      alice.destroy();
      bob.destroy();
    });

    test('cannot encrypt before handshake', () {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      expect(
        () async => await alice.encrypt(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<StateError>()),
      );
      
      alice.destroy();
    });

    test('cannot decrypt before handshake', () {
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      expect(
        () async => await bob.decrypt(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<StateError>()),
      );
      
      bob.destroy();
    });

    test('rejects invalid handshake message sizes', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Valid message A
      final messageA = await alice.startHandshake();
      
      // Test: Bob receives truncated message A
      expect(
        () async => await bob.processHandshakeMessage(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );

      // Test: Bob receives oversized message A
      expect(
        () async => await bob.processHandshakeMessage(Uint8List(100)),
        throwsA(anything),
      );

      alice.destroy();
      bob.destroy();
    });

    test('handshake provides channel binding hash', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Both sides should have same handshake hash
      expect(alice.handshakeHash, isNotNull);
      expect(bob.handshakeHash, isNotNull);
      expect(alice.handshakeHash, equals(bob.handshakeHash));
      expect(alice.handshakeHash!.length, equals(32)); // SHA-256

      alice.destroy();
      bob.destroy();
    });

    test('cannot start handshake twice', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      await alice.startHandshake();
      
      // Second call should fail
      expect(
        () async => await alice.startHandshake(),
        throwsA(isA<StateError>()),
      );

      alice.destroy();
    });

    test('responder cannot call startHandshake', () {
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      expect(
        () async => await bob.startHandshake(),
        throwsA(isA<StateError>()),
      );

      bob.destroy();
    });

    test('messages encrypted with different nonces are unique', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Encrypt same plaintext multiple times
      final plaintext = Uint8List.fromList([42, 42, 42, 42, 42]);
      final encrypted1 = await alice.encrypt(plaintext);
      final encrypted2 = await alice.encrypt(plaintext);
      final encrypted3 = await alice.encrypt(plaintext);

      // All ciphertexts must be different (different nonces)
      expect(encrypted1, isNot(equals(encrypted2)));
      expect(encrypted2, isNot(equals(encrypted3)));
      expect(encrypted1, isNot(equals(encrypted3)));

      // Extract nonces (first 4 bytes) and verify they increment
      final nonce1 = encrypted1.sublist(0, 4);
      final nonce2 = encrypted2.sublist(0, 4);
      final nonce3 = encrypted3.sublist(0, 4);

      expect(nonce1, isNot(equals(nonce2)));
      expect(nonce2, isNot(equals(nonce3)));

      alice.destroy();
      bob.destroy();
    });

    test('decryption fails with corrupted ciphertext', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted = await alice.encrypt(plaintext);

      // Corrupt the ciphertext (flip a bit in the middle)
      final corrupted = Uint8List.fromList(encrypted);
      corrupted[encrypted.length ~/ 2] ^= 0xFF;

      // Decryption should fail (MAC verification)
      expect(
        () async => await bob.decrypt(corrupted),
        throwsA(anything),
      );

      alice.destroy();
      bob.destroy();
    });

    test('decryption fails with corrupted nonce', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encrypted = await alice.encrypt(plaintext);

      // Corrupt the nonce (first 4 bytes)
      final corrupted = Uint8List.fromList(encrypted);
      corrupted[0] ^= 0xFF;

      // Decryption should fail (MAC verification with wrong nonce)
      expect(
        () async => await bob.decrypt(corrupted),
        throwsA(anything),
      );

      alice.destroy();
      bob.destroy();
    });

    test('handles empty message encryption', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Encrypt empty message
      final plaintext = Uint8List(0);
      final encrypted = await alice.encrypt(plaintext);
      
      // Should have nonce (4 bytes) + MAC (16 bytes) = 20 bytes minimum
      expect(encrypted.length, greaterThanOrEqualTo(20));

      final decrypted = await bob.decrypt(encrypted);
      expect(decrypted, equals(plaintext));
      expect(decrypted.length, equals(0));

      alice.destroy();
      bob.destroy();
    });

    test('handles large message encryption', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Encrypt large message (10 KB)
      final plaintext = Uint8List(10240);
      for (int i = 0; i < plaintext.length; i++) {
        plaintext[i] = i % 256;
      }

      final encrypted = await alice.encrypt(plaintext);
      expect(encrypted.length, greaterThan(plaintext.length));

      final decrypted = await bob.decrypt(encrypted);
      expect(decrypted, equals(plaintext));

      alice.destroy();
      bob.destroy();
    });

    test('replay window accepts messages within window', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Send 10 messages from Alice to Bob
      final messages = <Uint8List>[];
      for (int i = 0; i < 10; i++) {
        final msg = Uint8List.fromList([i, i, i]);
        messages.add(await alice.encrypt(msg));
      }

      // Decrypt all messages in order
      for (int i = 0; i < 10; i++) {
        final decrypted = await bob.decrypt(messages[i]);
        expect(decrypted, equals(Uint8List.fromList([i, i, i])));
      }

      alice.destroy();
      bob.destroy();
    });

    test('bidirectional communication works', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Interleaved bidirectional messages
      final aliceMsg1 = Uint8List.fromList([1, 1, 1]);
      final bobMsg1 = Uint8List.fromList([2, 2, 2]);
      final aliceMsg2 = Uint8List.fromList([3, 3, 3]);
      final bobMsg2 = Uint8List.fromList([4, 4, 4]);

      final enc1 = await alice.encrypt(aliceMsg1);
      final enc2 = await bob.encrypt(bobMsg1);
      final enc3 = await alice.encrypt(aliceMsg2);
      final enc4 = await bob.encrypt(bobMsg2);

      expect(await bob.decrypt(enc1), equals(aliceMsg1));
      expect(await alice.decrypt(enc2), equals(bobMsg1));
      expect(await bob.decrypt(enc3), equals(aliceMsg2));
      expect(await alice.decrypt(enc4), equals(bobMsg2));

      alice.destroy();
      bob.destroy();
    });

    test('session state transitions correctly', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );

      // Initial state
      expect(alice.state, equals(NoiseSessionState.uninitialized));

      // After starting handshake
      final msgA = await alice.startHandshake();
      expect(alice.state, equals(NoiseSessionState.handshaking));

      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      expect(bob.state, equals(NoiseSessionState.uninitialized));

      // Bob processes message A
      final msgB = await bob.processHandshakeMessage(msgA);
      expect(bob.state, equals(NoiseSessionState.handshaking));

      // Alice processes message B
      final msgC = await alice.processHandshakeMessage(msgB!);
      expect(alice.state, equals(NoiseSessionState.established));

      // Bob processes message C
      await bob.processHandshakeMessage(msgC!);
      expect(bob.state, equals(NoiseSessionState.established));

      alice.destroy();
      bob.destroy();
    });

    test('destroy clears sensitive data', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Verify session is established
      expect(alice.state, equals(NoiseSessionState.established));
      expect(alice.remoteStaticPublicKey, isNotNull);

      // Destroy session
      alice.destroy();

      // After destroy, cannot encrypt
      expect(
        () async => await alice.encrypt(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );

      bob.destroy();
    });

    test('cannot process handshake message after established', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Both sessions established
      expect(alice.state, equals(NoiseSessionState.established));
      expect(bob.state, equals(NoiseSessionState.established));

      // Try to process another handshake message - should fail
      expect(
        () async => await alice.processHandshakeMessage(Uint8List(32)),
        throwsA(anything),
      );

      alice.destroy();
      bob.destroy();
    });

    test('ciphertext includes MAC overhead', () async {
      final alice = NoiseSession(
        peerID: 'Bob',
        isInitiator: true,
        localStaticPrivateKey: aliceStaticPrivate,
        localStaticPublicKey: aliceStaticPublic,
      );
      
      final bob = NoiseSession(
        peerID: 'Alice',
        isInitiator: false,
        localStaticPrivateKey: bobStaticPrivate,
        localStaticPublicKey: bobStaticPublic,
      );

      // Complete handshake
      final msgA = await alice.startHandshake();
      final msgB = await bob.processHandshakeMessage(msgA);
      final msgC = await alice.processHandshakeMessage(msgB!);
      await bob.processHandshakeMessage(msgC!);

      // Test various plaintext sizes
      for (final size in [0, 1, 10, 100, 1000]) {
        final plaintext = Uint8List(size);
        final encrypted = await alice.encrypt(plaintext);
        
        // Ciphertext = nonce (4) + plaintext + MAC (16)
        expect(encrypted.length, equals(4 + size + 16));
        
        final decrypted = await bob.decrypt(encrypted);
        expect(decrypted.length, equals(size));
      }

      alice.destroy();
      bob.destroy();
    });
  });
}
