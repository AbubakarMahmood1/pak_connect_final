/// Tests for HandshakeStateKK - Noise KK pattern handshake state machine
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/security/noise/noise_handshake_exception.dart';
import 'package:pak_connect/core/security/noise/primitives/dh_state.dart';
import 'package:pak_connect/core/security/noise/primitives/handshake_state_kk.dart';

void main() {
  group('HandshakeStateKK - KK Pattern', () {
    late Uint8List aliceStaticPrivate;
    late Uint8List bobStaticPrivate;
    late Uint8List eveStaticPrivate;
    late Uint8List aliceStaticPublic;
    late Uint8List bobStaticPublic;
    late Uint8List eveStaticPublic;

    setUp(() {
      final aliceDH = DHState()..generateKeyPair();
      aliceStaticPrivate = Uint8List.fromList(aliceDH.getPrivateKey()!);
      aliceStaticPublic = Uint8List.fromList(aliceDH.getPublicKey()!);
      aliceDH.destroy();

      final bobDH = DHState()..generateKeyPair();
      bobStaticPrivate = Uint8List.fromList(bobDH.getPrivateKey()!);
      bobStaticPublic = Uint8List.fromList(bobDH.getPublicKey()!);
      bobDH.destroy();

      final eveDH = DHState()..generateKeyPair();
      eveStaticPrivate = Uint8List.fromList(eveDH.getPrivateKey()!);
      eveStaticPublic = Uint8List.fromList(eveDH.getPublicKey()!);
      eveDH.destroy();
    });

    test('constructor validates remote static key length', () {
      expect(
        () => HandshakeStateKK(
          localStaticPrivateKey: aliceStaticPrivate,
          remoteStaticPublicKey: Uint8List(31),
          isInitiator: true,
        ),
        throwsArgumentError,
      );
    });

    test(
      'initiator cannot read message A and responder cannot write message A',
      () async {
        final initiator = HandshakeStateKK(
          localStaticPrivateKey: aliceStaticPrivate,
          remoteStaticPublicKey: bobStaticPublic,
          isInitiator: true,
        );
        final responder = HandshakeStateKK(
          localStaticPrivateKey: bobStaticPrivate,
          remoteStaticPublicKey: aliceStaticPublic,
          isInitiator: false,
        );

        expect(() => initiator.readMessageA(Uint8List(32)), throwsStateError);
        expect(() => responder.writeMessageA(), throwsStateError);

        initiator.destroy();
        responder.destroy();
      },
    );

    test(
      'write/read state guards reject out-of-order and short messages',
      () async {
        final initiator = HandshakeStateKK(
          localStaticPrivateKey: aliceStaticPrivate,
          remoteStaticPublicKey: bobStaticPublic,
          isInitiator: true,
        );
        final responder = HandshakeStateKK(
          localStaticPrivateKey: bobStaticPrivate,
          remoteStaticPublicKey: aliceStaticPublic,
          isInitiator: false,
        );

        expect(initiator.getMessageIndex(), 0);
        final messageA = await initiator.writeMessageA();
        expect(messageA.length, greaterThanOrEqualTo(32));
        expect(initiator.getMessageIndex(), 1);

        expect(() => initiator.writeMessageA(), throwsStateError);
        expect(
          () => responder.readMessageA(Uint8List(10)),
          throwsArgumentError,
        );
        expect(() => responder.writeMessageB(), throwsStateError);
        expect(
          () => initiator.readMessageB(Uint8List(10)),
          throwsArgumentError,
        );

        expect(
          () => responder.readMessageA(messageA),
          throwsA(isA<NoiseHandshakeException>()),
        );
        expect(responder.getMessageIndex(), 0);

        initiator.destroy();
        responder.destroy();
      },
    );

    test(
      'readMessageB surfaces NoiseHandshakeException on crypto failure',
      () async {
        final initiator = HandshakeStateKK(
          localStaticPrivateKey: aliceStaticPrivate,
          remoteStaticPublicKey: bobStaticPublic,
          isInitiator: true,
        );
        await initiator.writeMessageA(); // move initiator to message index 1

        final malformedMessageB = Uint8List.fromList(
          List<int>.filled(
            48,
            0,
          ), // 32 bytes ephemeral + 16 bytes bogus payload
        );
        expect(
          () => initiator.readMessageB(malformedMessageB),
          throwsA(isA<NoiseHandshakeException>()),
        );
        expect(initiator.isComplete(), isFalse);
        expect(initiator.getMessageIndex(), 1);

        initiator.destroy();
      },
    );

    test('split fails before handshake completion', () {
      final initiator = HandshakeStateKK(
        localStaticPrivateKey: aliceStaticPrivate,
        remoteStaticPublicKey: bobStaticPublic,
        isInitiator: true,
      );

      expect(() => initiator.split(), throwsStateError);
      initiator.destroy();
    });

    test(
      'readMessageA throws NoiseHandshakeException when static keys mismatch',
      () async {
        final alice = HandshakeStateKK(
          localStaticPrivateKey: aliceStaticPrivate,
          remoteStaticPublicKey: bobStaticPublic,
          isInitiator: true,
        );

        // Bob is configured with the wrong remote static key (Eve instead of Alice).
        final bobWithWrongRemote = HandshakeStateKK(
          localStaticPrivateKey: bobStaticPrivate,
          remoteStaticPublicKey: eveStaticPublic,
          isInitiator: false,
        );

        final messageA = await alice.writeMessageA();

        expect(
          () => bobWithWrongRemote.readMessageA(messageA),
          throwsA(isA<NoiseHandshakeException>()),
        );

        alice.destroy();
        bobWithWrongRemote.destroy();

        // Touch Eve private key to avoid unused warning in coverage builds.
        expect(eveStaticPrivate.length, 32);
      },
    );
  });
}
