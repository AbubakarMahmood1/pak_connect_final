/// Comprehensive test suite for MessageFragmenter and MessageReassembler
///
/// Tests all 15 critical scenarios from RECOMMENDED_FIXES.md FIX-009
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/utils/message_fragmenter.dart';

void main() {
  group('MessageFragmenter', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    late MessageReassembler reassembler;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      reassembler = MessageReassembler();
    });

    tearDown(() {
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

    // TEST 1: Fragment message into chunks with sequence numbers
    test('fragments message into chunks with correct sequence numbers', () {
      final messageId = 'test123';
      final data = Uint8List.fromList(List.generate(250, (i) => i % 256));
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(data, maxSize, messageId);

      expect(chunks.isNotEmpty, isTrue);
      expect(chunks.length, greaterThan(1)); // Should be fragmented

      // Verify sequence numbers
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, equals(i));
        expect(chunks[i].totalChunks, equals(chunks.length));
      }

      // Verify wire-id consistency: all chunks of one message share the same
      // generated wire id (collision-resistant, not derived from the caller id).
      final wireId = chunks.first.messageId;
      for (final chunk in chunks) {
        expect(chunk.messageId, equals(wireId));
      }
    });

    // TEST 2: Reassemble chunks in order
    test('reassembles chunks in order correctly', () {
      final original = Uint8List.fromList(List.generate(250, (i) => i % 256));
      final messageId = 'msg001';
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(
        original,
        maxSize,
        messageId,
      );

      // Send chunks in order
      Uint8List? result;
      for (int i = 0; i < chunks.length; i++) {
        result = reassembler.addChunkBytes(chunks[i]);
        if (i < chunks.length - 1) {
          expect(
            result,
            isNull,
            reason: 'Should not complete before last chunk',
          );
        }
      }

      // Verify reassembly
      expect(result, isNotNull);
      expect(result!.length, equals(original.length));
      expect(result, equals(original));
    });

    test('debug logs do not leak chunk content', () {
      const secret = 'TOP_SECRET_PAYLOAD_123';
      final chunk = MessageChunk(
        messageId: 'secret-msg',
        chunkIndex: 0,
        totalChunks: 1,
        content: secret,
        timestamp: DateTime.now(),
      );

      final bytes = chunk.toBytes();
      final decoded = MessageChunk.fromBytes(bytes);
      final result = reassembler.addChunk(decoded);

      expect(result, equals(secret));
      expect(logRecords.where((log) => log.message.contains(secret)), isEmpty);

      Object? parseError;
      try {
        MessageChunk.fromBytes(Uint8List.fromList(utf8.encode('bad|$secret')));
      } catch (error) {
        parseError = error;
      }
      expect(parseError, isA<FormatException>());
      expect(parseError.toString(), isNot(contains(secret)));
      expect(logRecords.where((log) => log.message.contains(secret)), isEmpty);
    });

    // TEST 3: Handle out-of-order chunks
    test('handles out-of-order chunks correctly', () {
      final original = Uint8List.fromList(List.generate(250, (i) => i % 256));
      final messageId = 'msg002';
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(
        original,
        maxSize,
        messageId,
      );
      expect(
        chunks.length,
        greaterThanOrEqualTo(3),
        reason: 'Need at least 3 chunks for this test',
      );

      // Send chunks in reverse order (last to first)
      Uint8List? result;
      for (int i = chunks.length - 1; i >= 0; i--) {
        result = reassembler.addChunkBytes(chunks[i]);
        if (i > 0) {
          expect(
            result,
            isNull,
            reason: 'Should not complete until all chunks received',
          );
        }
      }

      // After sending all chunks, should complete
      expect(result, isNotNull, reason: 'All chunks received, should complete');

      // Verify reassembly
      expect(result!.length, equals(original.length));
      expect(result, equals(original));
    });

    // TEST 4: Handle duplicate chunks
    test('handles duplicate chunks without corruption', () {
      final original = Uint8List.fromList(List.generate(250, (i) => i % 256));
      final messageId = 'msg003';
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(
        original,
        maxSize,
        messageId,
      );

      // Send chunks with duplicates
      Uint8List? result;
      for (int i = 0; i < chunks.length; i++) {
        result = reassembler.addChunkBytes(chunks[i]);

        // Send duplicate
        if (i == 1) {
          reassembler.addChunkBytes(chunks[i]); // Duplicate chunk 1
        }
      }

      // Verify reassembly despite duplicates
      expect(result, isNotNull);
      expect(result!.length, equals(original.length));
      expect(result, equals(original));
    });

    // TEST 5: Handle missing chunks with timeout
    test('times out missing chunks after specified duration', () {
      final messageId = 'msg004';
      final data = Uint8List.fromList(List.generate(250, (i) => i % 256));
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(data, maxSize, messageId);

      // Send only first chunk
      reassembler.addChunkBytes(chunks[0]);

      // Cleanup with 30-second timeout (simulated)
      reassembler.cleanupOldMessages(timeout: Duration(seconds: 30));

      // Message should still be pending (not timed out yet)
      final result1 = reassembler.addChunkBytes(chunks[1]);
      expect(result1, isNull, reason: 'Still waiting for remaining chunks');

      // Cleanup with 0-second timeout (force expire)
      reassembler.cleanupOldMessages(timeout: Duration.zero);

      // Now send chunk 1 again - should start new session
      final result2 = reassembler.addChunkBytes(chunks[1]);
      expect(
        result2,
        isNull,
        reason: 'Old session expired, new incomplete session started',
      );
    });

    // TEST 6: Handle interleaved messages from different senders
    test('handles interleaved messages from different senders', () {
      final msg1 = Uint8List.fromList(List.generate(250, (i) => i % 256));
      final msg2 = Uint8List.fromList(
        List.generate(250, (i) => (i + 100) % 256),
      );

      final chunks1 = MessageFragmenter.fragmentBytes(msg1, 100, 'sender1');
      final chunks2 = MessageFragmenter.fragmentBytes(msg2, 100, 'sender2');

      // Send chunks in interleaved order: S1[0], S2[0], S1[1], S2[1], ...
      Uint8List? result1;
      Uint8List? result2;

      for (int i = 0; i < chunks1.length; i++) {
        result1 = reassembler.addChunkBytes(chunks1[i]);
        if (i < chunks2.length) {
          result2 = reassembler.addChunkBytes(chunks2[i]);
        }
      }

      // Both should reassemble correctly
      expect(result1, isNotNull);
      expect(result1!.length, equals(msg1.length));
      expect(result1, equals(msg1));

      expect(result2, isNotNull);
      expect(result2!.length, equals(msg2.length));
      expect(result2, equals(msg2));
    });

    // TEST 7: MTU boundary testing (various sizes)
    test('handles various MTU sizes correctly', () {
      final testData = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final mtuSizes = [50, 100, 200, 512]; // Skip MTU 20 (too small)

      for (final mtu in mtuSizes) {
        final messageId = 'mtu_$mtu';

        // Fragment with this MTU
        final chunks = MessageFragmenter.fragmentBytes(
          testData,
          mtu,
          messageId,
        );

        // Verify all chunks fit within MTU
        for (final chunk in chunks) {
          final chunkBytes = chunk.toBytes();
          expect(
            chunkBytes.length,
            lessThanOrEqualTo(mtu),
            reason: 'Chunk size ${chunkBytes.length} exceeds MTU $mtu',
          );
        }

        // Verify reassembly
        Uint8List? result;
        for (final chunk in chunks) {
          result = reassembler.addChunkBytes(chunk);
        }

        expect(result, isNotNull, reason: 'Failed to reassemble for MTU $mtu');
        expect(result, equals(testData), reason: 'Data corrupted for MTU $mtu');

        // Reset reassembler for next iteration
        reassembler.cleanupOldMessages(timeout: Duration.zero);
      }
    });

    // TEST 8: Large message fragmentation (10KB, 100KB)
    test('handles large message fragmentation', () {
      final sizes = [10 * 1024, 100 * 1024]; // 10KB, 100KB

      for (final size in sizes) {
        final largeData = Uint8List.fromList(
          List.generate(size, (i) => i % 256),
        );
        final messageId = 'large_${size ~/ 1024}kb';
        const maxSize = 200;

        final chunks = MessageFragmenter.fragmentBytes(
          largeData,
          maxSize,
          messageId,
        );

        expect(chunks.isNotEmpty, isTrue);
        expect(
          chunks.length,
          greaterThan(10),
          reason: '$size bytes should create many chunks',
        );

        for (final chunk in chunks) {
          expect(chunk.toBytes().length + 5, lessThanOrEqualTo(maxSize));
        }

        // Reassemble (sample every 10th chunk to speed up test)
        Uint8List? result;
        for (final chunk in chunks) {
          result = reassembler.addChunkBytes(chunk);
        }

        expect(result, isNotNull);
        expect(result!.length, equals(largeData.length));
        expect(result, equals(largeData));

        // Cleanup for next iteration
        reassembler.cleanupOldMessages(timeout: Duration.zero);
      }
    });

    // TEST 9: Empty message handling
    test('handles empty message gracefully', () {
      final emptyData = Uint8List(0);
      final messageId = 'empty';
      const maxSize = 100;

      // Fragment should handle empty data
      final chunks = MessageFragmenter.fragmentBytes(
        emptyData,
        maxSize,
        messageId,
      );

      // Empty data creates 0 chunks (no data to send)
      // This is valid behavior - empty messages don't need transmission
      expect(chunks.length, equals(0), reason: 'Empty data creates 0 chunks');

      // No chunks to reassemble, so no test for reassembly
      // In production, sender should check chunks.isEmpty before sending
    });

    // TEST 10: Single-chunk message (no fragmentation needed)
    test('handles single-chunk message without fragmentation', () {
      final smallData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final messageId = 'small';
      const maxSize = 200;

      final chunks = MessageFragmenter.fragmentBytes(
        smallData,
        maxSize,
        messageId,
      );

      // Should create exactly 1 chunk
      expect(chunks.length, equals(1));
      expect(chunks[0].chunkIndex, equals(0));
      expect(chunks[0].totalChunks, equals(1));

      // Reassemble
      final result = reassembler.addChunkBytes(chunks[0]);

      expect(result, isNotNull);
      expect(result, equals(smallData));
    });

    // TEST 11: Chunk header format validation
    test('validates chunk header format', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final messageId = 'header_test';
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(data, maxSize, messageId);
      final chunk = chunks[0];

      // Serialize and deserialize
      final chunkBytes = chunk.toBytes();
      final deserializedChunk = MessageChunk.fromBytes(chunkBytes);

      // Verify header fields preserved
      expect(deserializedChunk.messageId, equals(chunk.messageId));
      expect(deserializedChunk.chunkIndex, equals(chunk.chunkIndex));
      expect(deserializedChunk.totalChunks, equals(chunk.totalChunks));
      expect(deserializedChunk.isBinary, equals(chunk.isBinary));
      expect(deserializedChunk.content, equals(chunk.content));
    });

    // TEST 12: Base64 encoding/decoding correctness
    test('base64 encodes and decodes binary data correctly', () {
      // Create binary data with all byte values
      final binaryData = Uint8List.fromList(List.generate(256, (i) => i));
      final messageId = 'base64_test';
      const maxSize = 150;

      final chunks = MessageFragmenter.fragmentBytes(
        binaryData,
        maxSize,
        messageId,
      );

      // All chunks should be marked as binary
      for (final chunk in chunks) {
        expect(chunk.isBinary, isTrue);
      }

      // Reassemble
      Uint8List? result;
      for (final chunk in chunks) {
        result = reassembler.addChunkBytes(chunk);
      }

      // Verify byte-perfect reconstruction
      expect(result, isNotNull);
      expect(result!.length, equals(binaryData.length));
      for (int i = 0; i < binaryData.length; i++) {
        expect(
          result[i],
          equals(binaryData[i]),
          reason:
              'Byte $i corrupted: expected ${binaryData[i]}, got ${result[i]}',
        );
      }
    });

    // TEST 13: Fragment cleanup on timeout
    test('cleanup removes expired fragments', () {
      final messageId1 = 'expire_test_1';
      final messageId2 = 'expire_test_2';
      final data = Uint8List.fromList(List.generate(250, (i) => i % 256));
      const maxSize = 100;

      final chunks1 = MessageFragmenter.fragmentBytes(
        data,
        maxSize,
        messageId1,
      );
      final chunks2 = MessageFragmenter.fragmentBytes(
        data,
        maxSize,
        messageId2,
      );

      // Send first chunk of message 1
      reassembler.addChunkBytes(chunks1[0]);

      // Send first chunk of message 2
      reassembler.addChunkBytes(chunks2[0]);

      // Cleanup with 0 timeout (expire everything)
      reassembler.cleanupOldMessages(timeout: Duration.zero);

      // Try to complete message 1 (should fail - expired)
      var result1 = reassembler.addChunkBytes(chunks1[1]);
      expect(result1, isNull, reason: 'Message 1 should have expired');

      // Try to complete message 2 (should fail - expired)
      var result2 = reassembler.addChunkBytes(chunks2[1]);
      expect(result2, isNull, reason: 'Message 2 should have expired');
    });

    // TEST 14: Memory bounds
    test('rejects invalid reassembler limits at runtime', () {
      final invalidConstructors = <MessageReassembler Function()>[
        () => MessageReassembler(maxActiveAssemblies: 0),
        () => MessageReassembler(maxMessageBytes: 0),
        () => MessageReassembler(maxRetainedBytes: -1),
        () => MessageReassembler(maxChunksPerMessage: 0),
        () => MessageReassembler(maxRetainedFragments: 0),
      ];

      for (final create in invalidConstructors) {
        expect(create, throwsArgumentError);
      }
    });

    test('enforces memory bounds for pending messages', () {
      reassembler = MessageReassembler(
        maxActiveAssemblies: 2,
        maxMessageBytes: 10,
        maxRetainedBytes: 10,
      );
      MessageChunk partial(String id) => MessageChunk(
        messageId: id,
        chunkIndex: 0,
        totalChunks: 2,
        content: 'a',
        timestamp: DateTime.now(),
      );

      expect(reassembler.addChunkBytes(partial('msg-1')), isNull);
      expect(reassembler.addChunkBytes(partial('msg-2')), isNull);

      expect(
        () => reassembler.addChunkBytes(partial('msg-3')),
        throwsFormatException,
      );
    });

    test('caps retained fragment entries and cleanup frees capacity', () {
      final bounded = MessageReassembler(
        maxActiveAssemblies: 3,
        maxMessageBytes: 20,
        maxRetainedBytes: 20,
        maxRetainedFragments: 2,
      );
      MessageChunk part(String id, int index, String content) => MessageChunk(
        messageId: id,
        chunkIndex: index,
        totalChunks: 2,
        content: content,
        timestamp: DateTime.now(),
      );

      expect(bounded.addChunkBytes(part('one', 0, 'A')), isNull);
      expect(bounded.addChunkBytes(part('two', 0, 'B')), isNull);
      expect(
        () => bounded.addChunkBytes(part('three', 0, 'C')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Fragment buffer contains too many parts',
          ),
        ),
      );

      bounded.cleanupOldMessages(timeout: Duration.zero);
      expect(bounded.addChunkBytes(part('three', 0, 'C')), isNull);
      expect(
        bounded.addChunkBytes(part('three', 1, 'D')),
        Uint8List.fromList(utf8.encode('CD')),
      );
    });

    test('cleanup releases active-assembly and aggregate-byte capacity', () {
      final bounded = MessageReassembler(
        maxActiveAssemblies: 1,
        maxMessageBytes: 10,
        maxRetainedBytes: 2,
        maxRetainedFragments: 2,
      );
      final stale = MessageChunk(
        messageId: 'stale-capacity',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'ab',
        timestamp: DateTime.now(),
      );
      final replacement = MessageChunk(
        messageId: 'replacement',
        chunkIndex: 0,
        totalChunks: 1,
        content: 'cd',
        timestamp: DateTime.now(),
      );

      expect(bounded.addChunkBytes(stale), isNull);
      expect(() => bounded.addChunkBytes(replacement), throwsFormatException);

      bounded.cleanupOldMessages(timeout: Duration.zero);
      expect(
        bounded.addChunkBytes(replacement),
        Uint8List.fromList(utf8.encode('cd')),
      );
    });

    test('rejects forged total downgrade and clears the poisoned assembly', () {
      MessageChunk chunk(int index, int total, String content) => MessageChunk(
        messageId: 'forged-total',
        chunkIndex: index,
        totalChunks: total,
        content: content,
        timestamp: DateTime.now(),
      );

      expect(reassembler.addChunkBytes(chunk(0, 3, 'A')), isNull);
      expect(
        () => reassembler.addChunkBytes(chunk(0, 1, 'A')),
        throwsFormatException,
      );
      expect(reassembler.addChunkBytes(chunk(1, 3, 'B')), isNull);
      expect(reassembler.addChunkBytes(chunk(2, 3, 'C')), isNull);
    });

    test(
      'rejects stale binary-mode metadata and requires a fresh assembly',
      () {
        final textFirst = MessageChunk(
          messageId: 'mode-conflict',
          chunkIndex: 0,
          totalChunks: 2,
          content: 'A',
          timestamp: DateTime.now(),
        );
        final binarySecond = MessageChunk(
          messageId: 'mode-conflict',
          chunkIndex: 1,
          totalChunks: 2,
          content: base64.encode([66]),
          timestamp: DateTime.now(),
          isBinary: true,
        );

        expect(reassembler.addChunkBytes(textFirst), isNull);
        expect(
          () => reassembler.addChunkBytes(binarySecond),
          throwsFormatException,
        );
        final textSecond = MessageChunk(
          messageId: 'mode-conflict',
          chunkIndex: 1,
          totalChunks: 2,
          content: 'B',
          timestamp: DateTime.now(),
        );
        expect(reassembler.addChunkBytes(textSecond), isNull);
        expect(reassembler.addChunk(textFirst), 'AB');
      },
    );

    test('rejects invalid indexes and chunk totals', () {
      final cases = <(int, int)>[(0, 0), (-1, 1), (1, 1), (0, 0x10000)];
      for (var i = 0; i < cases.length; i++) {
        final (index, total) = cases[i];
        final chunk = MessageChunk(
          messageId: 'bad-meta-$i',
          chunkIndex: index,
          totalChunks: total,
          content: 'A',
          timestamp: DateTime.now(),
        );
        expect(() => reassembler.addChunkBytes(chunk), throwsFormatException);
      }
    });

    test('invalid base64 clears previously retained fragments', () {
      MessageChunk binary(int index, String content) => MessageChunk(
        messageId: 'bad-base64',
        chunkIndex: index,
        totalChunks: 2,
        content: content,
        timestamp: DateTime.now(),
        isBinary: true,
      );
      final first = binary(0, base64.encode([1]));
      final second = binary(1, base64.encode([2]));

      expect(reassembler.addChunkBytes(first), isNull);
      expect(
        () => reassembler.addChunkBytes(binary(1, '%%%')),
        throwsFormatException,
      );
      expect(reassembler.addChunkBytes(second), isNull);
      expect(reassembler.addChunkBytes(first), Uint8List.fromList([1, 2]));
    });

    test('prechecks encoded length before decoding oversized base64', () {
      final bounded = MessageReassembler(
        maxMessageBytes: 2,
        maxRetainedBytes: 10,
      );
      MessageChunk binary(int index, String content) => MessageChunk(
        messageId: 'encoded-precheck',
        chunkIndex: index,
        totalChunks: 2,
        content: content,
        timestamp: DateTime.now(),
        isBinary: true,
      );
      final first = binary(0, base64.encode([1]));
      final second = binary(1, base64.encode([2]));

      expect(bounded.addChunkBytes(first), isNull);
      expect(
        () => bounded.addChunkBytes(binary(1, '!' * 100)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Fragment assembly exceeds message limit',
          ),
        ),
      );
      expect(bounded.addChunkBytes(second), isNull);
      expect(bounded.addChunkBytes(first), Uint8List.fromList([1, 2]));
    });

    test('prechecks exact UTF-8 byte length before retaining text', () {
      final bounded = MessageReassembler(
        maxMessageBytes: 3,
        maxRetainedBytes: 3,
      );
      final oversized = MessageChunk(
        messageId: 'utf8-precheck',
        chunkIndex: 0,
        totalChunks: 1,
        content: '😀',
        timestamp: DateTime.now(),
      );

      expect(
        () => bounded.addChunkBytes(oversized),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Fragment assembly exceeds message limit',
          ),
        ),
      );
    });

    test('rejects conflicting duplicate content and clears the assembly', () {
      MessageChunk text(int index, String content) => MessageChunk(
        messageId: 'duplicate-conflict',
        chunkIndex: index,
        totalChunks: 2,
        content: content,
        timestamp: DateTime.now(),
      );
      final first = text(0, 'A');
      final second = text(1, 'B');

      expect(reassembler.addChunkBytes(first), isNull);
      expect(
        () => reassembler.addChunkBytes(text(0, 'X')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Conflicting duplicate fragment',
          ),
        ),
      );
      expect(reassembler.addChunkBytes(second), isNull);
      expect(
        reassembler.addChunkBytes(first),
        Uint8List.fromList(utf8.encode('AB')),
      );
    });

    test('enforces per-message and aggregate retained byte limits', () {
      MessageChunk partial(String id, int index, String content) =>
          MessageChunk(
            messageId: id,
            chunkIndex: index,
            totalChunks: 2,
            content: content,
            timestamp: DateTime.now(),
          );

      final perMessage = MessageReassembler(
        maxMessageBytes: 3,
        maxRetainedBytes: 10,
      );
      expect(perMessage.addChunkBytes(partial('large', 0, 'ab')), isNull);
      expect(
        () => perMessage.addChunkBytes(partial('large', 1, 'cd')),
        throwsFormatException,
      );

      final aggregate = MessageReassembler(
        maxMessageBytes: 10,
        maxRetainedBytes: 3,
      );
      expect(aggregate.addChunkBytes(partial('one', 0, 'ab')), isNull);
      expect(
        () => aggregate.addChunkBytes(partial('two', 0, 'ab')),
        throwsFormatException,
      );
    });

    // TEST 15: CRC32 validation (after adding checksums)
    test('validates CRC32 checksums when implemented', () {
      // Note: Current implementation doesn't use CRC32
      // This test documents expected behavior for future implementation

      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final messageId = 'crc_test';
      const maxSize = 100;

      final chunks = MessageFragmenter.fragmentBytes(data, maxSize, messageId);

      // TODO: Expected behavior when CRC32 is added:
      //   1. Each chunk should contain CRC32 checksum in header
      //   2. Reassembler should validate CRC32 on each chunk
      //   3. Invalid CRC32 should throw FormatException

      // Current behavior: No CRC32 validation
      expect(
        () => reassembler.addChunkBytes(chunks[0]),
        returnsNormally,
        reason: 'Current implementation has no CRC32 validation',
      );

      // Future test (when CRC32 added):
      // final corruptedChunk = _corruptChunk(chunks[0]);
      // expect(
      //   () => reassembler.addChunkBytes(corruptedChunk),
      //   throwsA(isA<FormatException>()),
      //   reason: 'CRC32 mismatch should throw',
      // );
    });
  });

  group('MessageFragmenter - Edge Cases', () {
    test('handles MTU too small error', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final messageId = 'tiny_mtu';

      // MTU of 10 is too small (need at least 15 for header + 5 for BLE overhead)
      expect(
        () => MessageFragmenter.fragmentBytes(data, 10, messageId),
        throwsA(isA<ArgumentError>()),
        reason: 'MTU too small should throw',
      );
    });

    test('handles invalid chunk format', () {
      // Create malformed chunk bytes (invalid format)
      final invalidBytes = Uint8List.fromList(utf8.encode('invalid|format'));

      expect(
        () => MessageChunk.fromBytes(invalidBytes),
        throwsFormatException,
        reason: 'Invalid chunk format should throw',
      );
    });

    test('generates a collision-resistant wire id regardless of caller id', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final shortId = 'ab';

      final chunks = MessageFragmenter.fragmentBytes(data, 100, shortId);

      // The wire id is generated, not the (short, low-entropy) caller id.
      expect(chunks.isNotEmpty, isTrue);
      expect(chunks[0].messageId, isNot(equals(shortId)));
      expect(chunks[0].messageId.length, greaterThanOrEqualTo(8));
    });
  });
}
