import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/constants/special_recipients.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  group('ProtocolMessage helpers', () {
    test('identity constructor stores public key and display name only', () {
      final message = ProtocolMessage.identity(
        publicKey: 'pub-key',
        displayName: 'Alice',
      );

      expect(message.type, ProtocolMessageType.identity);
      expect(message.identityPublicKey, 'pub-key');
      expect(message.identityDisplayName, 'Alice');
    });

    test('noise handshake constructors expose peer id and decoded payload', () {
      final h1 = ProtocolMessage.noiseHandshake1(
        handshakeData: Uint8List.fromList([1, 2, 3]),
        peerId: 'peer-a',
      );
      final h2 = ProtocolMessage.noiseHandshake2(
        handshakeData: Uint8List.fromList([4, 5]),
        peerId: 'peer-b',
      );
      final h3 = ProtocolMessage.noiseHandshake3(
        handshakeData: Uint8List.fromList([6]),
        peerId: 'peer-c',
      );

      expect(h1.noiseHandshakePeerId, 'peer-a');
      expect(h1.noiseHandshakeData, Uint8List.fromList([1, 2, 3]));
      expect(h2.noiseHandshakePeerId, 'peer-b');
      expect(h2.noiseHandshakeData, Uint8List.fromList([4, 5]));
      expect(h3.noiseHandshakePeerId, 'peer-c');
      expect(h3.noiseHandshakeData, Uint8List.fromList([6]));
    });

    test('noise handshake rejected helper getters map payload values', () {
      final message = ProtocolMessage.noiseHandshakeRejected(
        reason: 'missing_key',
        attemptedPattern: 'kk',
        suggestedPattern: 'xx',
        peerEphemeralId: 'peer-eph',
        contactStatus: {'hasAsContact': false},
      );

      expect(message.type, ProtocolMessageType.noiseHandshakeRejected);
      expect(message.noiseHandshakeRejectReason, 'missing_key');
      expect(message.noiseHandshakeRejectAttemptedPattern, 'kk');
      expect(message.noiseHandshakeRejectSuggestedPattern, 'xx');
      expect(message.noiseHandshakeRejectPeerId, 'peer-eph');
      expect(message.noiseHandshakeRejectContactStatus, {
        'hasAsContact': false,
      });
    });

    test('text and broadcast helpers expose addressing flags and ids', () {
      final text = ProtocolMessage.textMessageWithIds(
        messageId: const MessageId('msg-1'),
        content: 'hello',
        encrypted: true,
        recipientId: const ChatId('chat-1'),
        useEphemeralAddressing: true,
      );
      final broadcast = ProtocolMessage.broadcastMessageWithId(
        messageId: const MessageId('msg-2'),
        content: 'mesh',
      );

      expect(text.type, ProtocolMessageType.textMessage);
      expect(text.textMessageId, 'msg-1');
      expect(text.textContent, 'hello');
      expect(text.isEncrypted, isTrue);
      expect(text.recipientId, 'chat-1');
      expect(text.useEphemeralAddressing, isTrue);
      expect(text.isBroadcast, isFalse);

      expect(broadcast.recipientId, SpecialRecipients.broadcast);
      expect(broadcast.isBroadcast, isTrue);
    });

    test('ack helpers and typed wrapper expose original id', () {
      final ack = ProtocolMessage.ackWithId(
        originalMessageId: const MessageId('orig-1'),
      );

      expect(ack.type, ProtocolMessageType.ack);
      expect(ack.ackOriginalId, 'orig-1');
      expect(ack.ackOriginalMessageIdValue, const MessageId('orig-1'));
    });

    test('pairing/contact helpers expose payload values', () {
      final pairingRequest = ProtocolMessage.pairingRequest(
        ephemeralId: 'eph-1',
        displayName: 'Peer',
      );
      final pairingAccept = ProtocolMessage.pairingAccept(
        ephemeralId: 'eph-2',
        displayName: 'Peer2',
      );
      final pairingCancel = ProtocolMessage.pairingCancel(reason: 'timeout');
      final pairingCode = ProtocolMessage.pairingCode(code: '123456');
      final verify = ProtocolMessage.pairingVerify(secretHash: 'secret-hash');
      final request = ProtocolMessage.contactRequest(
        publicKey: 'pk-1',
        displayName: 'Contact',
      );
      final accept = ProtocolMessage.contactAccept(
        publicKey: 'pk-2',
        displayName: 'Accepted',
      );
      final reject = ProtocolMessage.contactReject();
      final status = ProtocolMessage.contactStatus(
        hasAsContact: true,
        publicKey: 'pk-3',
      );

      expect(pairingRequest.payload['ephemeralId'], 'eph-1');
      expect(pairingAccept.payload['ephemeralId'], 'eph-2');
      expect(pairingCancel.payload['reason'], 'timeout');
      expect(pairingCode.pairingCodeValue, '123456');
      expect(verify.pairingSecretHash, 'secret-hash');
      expect(request.contactRequestPublicKey, 'pk-1');
      expect(request.contactRequestDisplayName, 'Contact');
      expect(accept.contactAcceptPublicKey, 'pk-2');
      expect(accept.contactAcceptDisplayName, 'Accepted');
      expect(reject.type, ProtocolMessageType.contactReject);
      expect(status.payload['hasAsContact'], isTrue);
    });

    test(
      'crypto verification helpers expose challenge, response and results',
      () {
        final verify = ProtocolMessage.cryptoVerification(
          challenge: 'c1',
          testMessage: 'tm',
        );
        final response = ProtocolMessage.cryptoVerificationResponse(
          challenge: 'c1',
          decryptedMessage: 'plain',
          success: true,
          results: {'latencyMs': 12},
        );

        expect(verify.cryptoVerificationChallenge, 'c1');
        expect(verify.cryptoVerificationTestMessage, 'tm');
        expect(verify.cryptoVerificationRequiresResponse, isTrue);
        expect(response.cryptoVerificationResponseChallenge, 'c1');
        expect(response.cryptoVerificationResponseDecrypted, 'plain');
        expect(response.cryptoVerificationSuccess, isTrue);
        expect(response.cryptoVerificationResults?['latencyMs'], 12);
      },
    );

    test('mesh relay, queue sync and relay ack typed getters work', () {
      final metadata = RelayMetadata(
        ttl: 4,
        hopCount: 2,
        routingPath: const ['node-a', 'node-b'],
        messageHash: 'hash',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.fromMillisecondsSinceEpoch(10),
        originalSender: 'sender-a',
        finalRecipient: 'recipient-a',
      );

      final relay = ProtocolMessage.meshRelayWithIds(
        originalMessageId: const MessageId('orig-msg'),
        originalSender: const ChatId('sender-a'),
        finalRecipient: const ChatId('recipient-a'),
        relayMetadata: metadata.toJson(),
        originalPayload: const {'content': 'payload'},
        useEphemeralAddressing: true,
        originalMessageType: ProtocolMessageType.textMessage,
      );

      final sync = QueueSyncMessage.createRequestWithIds(
        messageIds: const [MessageId('m1'), MessageId('m2')],
        nodeId: 'node-x',
        messageHashes: {const MessageId('m1'): 'h1'},
      );
      final syncMsg = ProtocolMessage.queueSync(queueMessage: sync);

      final ack = ProtocolMessage.relayAckWithId(
        originalMessageId: const MessageId('orig-msg'),
        relayNode: 'relay-node',
        delivered: true,
      );

      expect(relay.meshRelayOriginalMessageId, 'orig-msg');
      expect(
        relay.meshRelayOriginalMessageIdValue,
        const MessageId('orig-msg'),
      );
      expect(relay.meshRelayOriginalSenderChatId, const ChatId('sender-a'));
      expect(relay.meshRelayFinalRecipientChatId, const ChatId('recipient-a'));
      expect(relay.meshRelayUseEphemeralAddressing, isTrue);
      expect(
        relay.meshRelayOriginalMessageType,
        ProtocolMessageType.textMessage,
      );

      expect(syncMsg.queueSyncMessageIdValues, const [
        MessageId('m1'),
        MessageId('m2'),
      ]);
      expect(syncMsg.queueSyncMessageHashValues?[const MessageId('m1')], 'h1');

      expect(ack.relayAckOriginalMessageId, 'orig-msg');
      expect(ack.relayAckOriginalMessageIdValue, const MessageId('orig-msg'));
      expect(ack.relayAckRelayNode, 'relay-node');
      expect(ack.relayAckDelivered, isTrue);
    });

    test('connection ready helper getters read device payload fields', () {
      final message = ProtocolMessage.connectionReady(
        deviceId: 'device-1',
        deviceName: 'Pixel',
      );

      expect(message.connectionReadyDeviceId, 'device-1');
      expect(message.connectionReadyDeviceName, 'Pixel');
    });

    test(
      'fromBytes rejects raw json without wire-format flags and validates protocol schema',
      () {
        final oldFormat = utf8.encode(
          jsonEncode({
            'type': ProtocolMessageType.ping.wireType,
            'version': 1,
            'payload': {},
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );

        expect(
          () => ProtocolMessage.fromBytes(Uint8List.fromList(oldFormat)),
          throwsArgumentError,
        );

        expect(
          ProtocolMessage.isProtocolMessage(utf8.decode(oldFormat)),
          isTrue,
        );
        expect(ProtocolMessage.isProtocolMessage('{"foo":1}'), isFalse);
        expect(ProtocolMessage.isProtocolMessage('not-json'), isFalse);
      },
    );
  });
}
