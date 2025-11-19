import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:pak_connect/data/services/message_fragmentation_handler.dart';

void main() {
  group('MessageFragmentationHandler', () {
    late MessageFragmentationHandler handler;

    setUp(() {
      handler = MessageFragmentationHandler();
    });

    tearDown(() {
      handler.dispose();
    });

    test('creates instance successfully', () {
      expect(handler, isNotNull);
    });

    test('detects chunk strings correctly', () {
      // Valid chunk format: id|idx|total|isBinary|content
      final validChunk = Uint8List.fromList('msg123|0|3|0|Hello'.codeUnits);
      expect(handler.looksLikeChunkString(validChunk), isTrue);
    });

    test('rejects non-chunk data', () {
      // Plain data without chunk markers
      final plainData = Uint8List.fromList(
        'This is just plain text without chunk markers'.codeUnits,
      );
      expect(handler.looksLikeChunkString(plainData), isFalse);
    });

    test('processes single-byte pings as null', () async {
      final ping = Uint8List.fromList([0x00]);
      final result = await handler.processReceivedData(
        data: ping,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );
      expect(result, isNull);
    });

    test('registers and acknowledges message ACK', () async {
      final messageId = 'test-msg-123';

      // Register ACK with timeout
      final ackFuture = handler.registerMessageAck(
        messageId: messageId,
        timeout: Duration(seconds: 5),
      );

      // Immediately acknowledge
      handler.acknowledgeMessage(messageId);

      // Should complete with true
      final result = await ackFuture;
      expect(result, isTrue);
    });

    test('ACK timeout returns false', () async {
      final messageId = 'timeout-msg';

      // Register ACK with very short timeout
      final ackFuture = handler.registerMessageAck(
        messageId: messageId,
        timeout: Duration(milliseconds: 100),
      );

      // Wait for timeout (don't acknowledge)
      final result = await ackFuture;
      expect(result, isFalse);
    });

    test('cleanupOldMessages completes without error', () {
      expect(() => handler.cleanupOldMessages(), returnsNormally);
    });

    test('getReassemblyState returns map', () {
      final state = handler.getReassemblyState();
      expect(state, isA<Map<String, int>>());
    });

    test('dispose completes without error', () {
      expect(() => handler.dispose(), returnsNormally);
    });

    test('handles direct protocol messages', () async {
      // Direct protocol message (not fragmented)
      // Would be a valid JSON protocol message
      final directMsg = Uint8List.fromList('{"type":"ping"}'.codeUnits);

      // For now, test that it doesn't throw
      final result = await handler.processReceivedData(
        data: directMsg,
        fromDeviceId: 'device1',
        fromNodeId: 'node1',
      );

      // Should return null or DIRECT_PROTOCOL_MESSAGE marker
      expect(result == null || result == 'DIRECT_PROTOCOL_MESSAGE', isTrue);
    });

    test('multiple ACKs can be registered', () async {
      final ack1 = handler.registerMessageAck(
        messageId: 'msg1',
        timeout: Duration(seconds: 5),
      );
      final ack2 = handler.registerMessageAck(
        messageId: 'msg2',
        timeout: Duration(seconds: 5),
      );

      handler.acknowledgeMessage('msg1');
      handler.acknowledgeMessage('msg2');

      expect(await ack1, isTrue);
      expect(await ack2, isTrue);
    });
  });
}
