import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/signing_manager.dart';

void main() {
  group('SigningManager.signaturePayloadForMessage', () {
    test('v2 payload changes when crypto envelope changes', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
      final messageA = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'm1',
          'content': 'ciphertext-a',
          'encrypted': true,
          'senderId': 'sender-persistent',
          'recipientId': 'recipient-persistent',
          'intendedRecipient': 'recipient-persistent',
          'crypto': {
            'mode': 'noise_v1',
            'modeVersion': 1,
            'sessionId': 'session-a',
          },
        },
        timestamp: now,
      );
      final messageB = ProtocolMessage(
        type: ProtocolMessageType.textMessage,
        version: 2,
        payload: {
          'messageId': 'm1',
          'content': 'ciphertext-a',
          'encrypted': true,
          'senderId': 'sender-persistent',
          'recipientId': 'recipient-persistent',
          'intendedRecipient': 'recipient-persistent',
          'crypto': {
            'mode': 'sealed_v1',
            'modeVersion': 1,
            'kid': 'kid-a',
          },
        },
        timestamp: now,
      );

      final payloadA = SigningManager.signaturePayloadForMessage(
        messageA,
        fallbackContent: 'plaintext',
      );
      final payloadB = SigningManager.signaturePayloadForMessage(
        messageB,
        fallbackContent: 'plaintext',
      );

      expect(payloadA, isNot(equals(payloadB)));
    });

    test(
      'v2 canonical payload is stable regardless of map insertion order',
      () {
        final now = DateTime.fromMillisecondsSinceEpoch(1739325600000);
        final orderedA = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'messageId': 'm2',
            'content': 'ciphertext-b',
            'encrypted': true,
            'senderId': 'sender',
            'recipientId': 'recipient',
            'intendedRecipient': 'recipient',
            'crypto': {'mode': 'sealed_v1', 'modeVersion': 1, 'kid': 'kid-1'},
          },
          timestamp: now,
        );
        final orderedB = ProtocolMessage(
          type: ProtocolMessageType.textMessage,
          version: 2,
          payload: {
            'crypto': {'kid': 'kid-1', 'modeVersion': 1, 'mode': 'sealed_v1'},
            'intendedRecipient': 'recipient',
            'recipientId': 'recipient',
            'senderId': 'sender',
            'encrypted': true,
            'content': 'ciphertext-b',
            'messageId': 'm2',
          },
          timestamp: now,
        );

        final payloadA = SigningManager.signaturePayloadForMessage(
          orderedA,
          fallbackContent: 'plaintext',
        );
        final payloadB = SigningManager.signaturePayloadForMessage(
          orderedB,
          fallbackContent: 'plaintext',
        );

        expect(payloadA, equals(payloadB));
      },
    );
  });
}
