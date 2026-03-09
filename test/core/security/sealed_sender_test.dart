import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/sealed_sender_payload.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';

void main() {
  group('SealedSenderPayload', () {
    test('pack produces valid JSON with sender and content', () {
      final packed = SealedSenderPayload.pack(
        senderPublicKey: 'abc123',
        content: 'Hello from sealed sender',
      );
      final data = SealedSenderPayload.unpack(packed);
      expect(data, isNotNull);
      expect(data!.senderPublicKey, 'abc123');
      expect(data.content, 'Hello from sealed sender');
    });

    test('unpack returns null for non-sealed format', () {
      expect(SealedSenderPayload.unpack('plain text'), isNull);
      expect(SealedSenderPayload.unpack('{"foo": "bar"}'), isNull);
      expect(SealedSenderPayload.unpack(''), isNull);
    });

    test('pack handles unicode content', () {
      final packed = SealedSenderPayload.pack(
        senderPublicKey: 'key-🔐',
        content: '你好世界 🌍',
      );
      final data = SealedSenderPayload.unpack(packed)!;
      expect(data.senderPublicKey, 'key-🔐');
      expect(data.content, '你好世界 🌍');
    });
  });

  group('RelayMetadata sealed sender', () {
    test('sealedSender flag defaults to false', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-A'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: 'sender-key',
        finalRecipient: 'recipient-key',
      );
      expect(meta.sealedSender, isFalse);
    });

    test('sealedSender preserved through JSON round-trip', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-A'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: RelayMetadata.sealedSenderPlaceholder,
        finalRecipient: 'recipient-key',
        sealedSender: true,
      );
      final json = meta.toJson();
      final restored = RelayMetadata.fromJson(json);
      expect(restored.sealedSender, isTrue);
      expect(restored.originalSender, 'sealed');
    });

    test('sealedSender preserved through nextHop', () {
      final meta = RelayMetadata(
        ttl: 5,
        hopCount: 1,
        routingPath: ['node-A'],
        messageHash: 'hash123',
        priority: MessagePriority.normal,
        relayTimestamp: DateTime.now(),
        originalSender: 'sealed',
        finalRecipient: 'recipient-key',
        sealedSender: true,
      );
      final next = meta.nextHop('node-B');
      expect(next.sealedSender, isTrue);
      expect(next.originalSender, 'sealed');
      expect(next.hopCount, 2);
    });

    test('sealedSender false when not in JSON', () {
      final json = {
        'ttl': 5,
        'hopCount': 1,
        'routingPath': ['node-A'],
        'messageHash': 'hash123',
        'priority': 0,
        'relayTimestamp': DateTime.now().millisecondsSinceEpoch,
        'originalSender': 'sender-key',
        'finalRecipient': 'recipient-key',
      };
      final meta = RelayMetadata.fromJson(json);
      expect(meta.sealedSender, isFalse);
    });
  });
}
