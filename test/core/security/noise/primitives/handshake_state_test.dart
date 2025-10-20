/// Tests for HandshakeState - Noise XX pattern handshake state machine
library;

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/primitives/handshake_state.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';

void main() {
  group('HandshakeState - XX Pattern', () {
    late Uint8List aliceStaticPrivate;
    late Uint8List bobStaticPrivate;
    late Uint8List aliceStaticPublic;
    late Uint8List bobStaticPublic;
    
    setUp(() {
      final aliceDH = DHState();
      aliceDH.generateKeyPair();
      aliceStaticPrivate = Uint8List.fromList(aliceDH.getPrivateKey()!);
      aliceStaticPublic = Uint8List.fromList(aliceDH.getPublicKey()!);
      aliceDH.destroy();
      
      final bobDH = DHState();
      bobDH.generateKeyPair();
      bobStaticPrivate = Uint8List.fromList(bobDH.getPrivateKey()!);
      bobStaticPublic = Uint8List.fromList(bobDH.getPublicKey()!);
      bobDH.destroy();
    });

    test('initiator creates valid HandshakeState', () {
      final alice = HandshakeState(
        localStaticPrivateKey: aliceStaticPrivate,
        isInitiator: true,
      );

      expect(alice.getHandshakeHash().length, equals(32));
      expect(alice.isComplete(), isFalse);
      alice.destroy();
    });

    test('responder creates valid HandshakeState', () {
      final bob = HandshakeState(
        localStaticPrivateKey: bobStaticPrivate,
        isInitiator: false,
      );

      expect(bob.getHandshakeHash().length, equals(32));
      expect(bob.isComplete(), isFalse);
      bob.destroy();
    });

    test('XX handshake message A is 32 bytes', () async {
      final alice = HandshakeState(
        localStaticPrivateKey: aliceStaticPrivate,
        isInitiator: true,
      );

      final messageA = await alice.writeMessageA();
      expect(messageA.length, equals(32));
      expect(alice.isComplete(), isFalse);
      
      alice.destroy();
    });

    test('complete XX handshake with mutual authentication', () async {
      final alice = HandshakeState(
        localStaticPrivateKey: aliceStaticPrivate,
        isInitiator: true,
      );
      final bob = HandshakeState(
        localStaticPrivateKey: bobStaticPrivate,
        isInitiator: false,
      );

      final messageA = await alice.writeMessageA();
      expect(messageA.length, equals(32));
      
      await bob.readMessageA(messageA);

      final messageB = await bob.writeMessageB();
      expect(messageB.length, greaterThan(32));
      
      await alice.readMessageB(messageB);

      final messageC = await alice.writeMessageC();
      expect(messageC.length, equals(48));
      
      await bob.readMessageC(messageC);

      expect(alice.getHandshakeHash(), equals(bob.getHandshakeHash()));
      expect(alice.getRemoteStaticPublicKey(), equals(bobStaticPublic));
      expect(bob.getRemoteStaticPublicKey(), equals(aliceStaticPublic));
      expect(alice.isComplete(), isTrue);
      expect(bob.isComplete(), isTrue);
      
      alice.destroy();
      bob.destroy();
    });

    test('split produces working cipher states', () async {
      final alice = HandshakeState(
        localStaticPrivateKey: aliceStaticPrivate,
        isInitiator: true,
      );
      final bob = HandshakeState(
        localStaticPrivateKey: bobStaticPrivate,
        isInitiator: false,
      );

      final messageA = await alice.writeMessageA();
      await bob.readMessageA(messageA);
      final messageB = await bob.writeMessageB();
      await alice.readMessageB(messageB);
      final messageC = await alice.writeMessageC();
      await bob.readMessageC(messageC);

      final aliceCiphers = alice.split();
      final bobCiphers = bob.split();

      final testMessage = Uint8List.fromList([1, 2, 3, 4, 5]);
      
      // Alice (initiator) sends with $1, Bob (responder) receives with $2
      final encrypted = await aliceCiphers.$1.encryptWithAd(Uint8List(0), testMessage);
      final decrypted = await bobCiphers.$2.decryptWithAd(Uint8List(0), encrypted);
      expect(decrypted, equals(testMessage));

      // Bob (responder) sends with $1, Alice (initiator) receives with $2
      final encrypted2 = await bobCiphers.$1.encryptWithAd(Uint8List(0), testMessage);
      final decrypted2 = await aliceCiphers.$2.decryptWithAd(Uint8List(0), encrypted2);
      expect(decrypted2, equals(testMessage));
      
      aliceCiphers.$1.destroy();
      aliceCiphers.$2.destroy();
      bobCiphers.$1.destroy();
      bobCiphers.$2.destroy();
      alice.destroy();
      bob.destroy();
    });

    test('split fails before handshake complete', () {
      final alice = HandshakeState(
        localStaticPrivateKey: aliceStaticPrivate,
        isInitiator: true,
      );

      expect(() => alice.split(), throwsA(isA<StateError>()));
      alice.destroy();
    });
  });
}
