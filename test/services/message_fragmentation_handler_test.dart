import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/utils/message_fragmenter.dart';
import 'package:pak_connect/data/services/message_fragmentation_handler.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  group('MessageFragmentationHandler', () {
    late MessageFragmentationHandler handler;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      handler = MessageFragmentationHandler();
    });

    tearDown(() {
      handler.dispose();
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

    test('returns reassembled bytes after final chunk arrives', () async {
      final message =
          'Chunked message payload for testing that exceeds the 25 byte minimum MTU and forces multiple fragments to be combined again.';
      final chunks = MessageFragmenter.fragmentBytes(
        Uint8List.fromList(utf8.encode(message)),
        60,
        'message-123456',
      );

      String? completionMarker;
      for (final chunk in chunks) {
        completionMarker = await handler.processReceivedData(
          data: chunk.toBytes(),
          fromDeviceId: 'device1',
          fromNodeId: 'node1',
        );
      }

      expect(completionMarker, isNotNull);
      expect(completionMarker!.startsWith('REASSEMBLY_COMPLETE:'), isTrue);

      final completionId = completionMarker!.substring(
        'REASSEMBLY_COMPLETE:'.length,
      );
      final expectedId = chunks.first.messageId.length >= 6
          ? chunks.first.messageId.substring(chunks.first.messageId.length - 6)
          : chunks.first.messageId;

      expect(
        completionId,
        expectedId,
        reason: 'completionMarker=$completionMarker',
      );

      final bytes = handler.takeReassembledMessageBytes(completionId);

      expect(bytes, isNotNull, reason: 'completionMarker=$completionMarker');
      expect(utf8.decode(bytes!), message);
      expect(handler.takeReassembledMessageBytes(completionId), isNull);
    });
  });
}
