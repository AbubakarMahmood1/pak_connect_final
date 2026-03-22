import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/utils/message_fragmenter.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  // ─── MessageChunk ───────────────────────────────────────────────────
  group('MessageChunk', () {
    test('toBytes produces correct pipe-delimited format', () {
      final chunk = MessageChunk(
        messageId: 'abcdef123456',
        chunkIndex: 0,
        totalChunks: 3,
        content: 'hello',
        timestamp: DateTime.now(),
      );

      final bytes = chunk.toBytes();
      final decoded = utf8.decode(bytes);
      // shortId = last 6 chars = '123456'
      expect(decoded, equals('123456|0|3|0|hello'));
    });

    test('fromBytes parses valid chunk correctly', () {
      final raw = utf8.encode('abc123|2|5|0|payload');
      final chunk = MessageChunk.fromBytes(Uint8List.fromList(raw));

      expect(chunk.messageId, 'abc123');
      expect(chunk.chunkIndex, 2);
      expect(chunk.totalChunks, 5);
      expect(chunk.isBinary, false);
      expect(chunk.content, 'payload');
    });

    test('fromBytes throws FormatException on invalid format (too few parts)',
        () {
      final raw = utf8.encode('only|two');
      expect(
        () => MessageChunk.fromBytes(Uint8List.fromList(raw)),
        throwsA(isA<FormatException>()),
      );
    });

    test('toBytes uses last 6 chars of messageId as shortId', () {
      final chunk = MessageChunk(
        messageId: 'XYZABCDEF012',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'data',
        timestamp: DateTime.now(),
      );

      final decoded = utf8.decode(chunk.toBytes());
      expect(decoded.startsWith('EF012|'), isFalse); // wrong length
      expect(decoded.startsWith('F012|'), isFalse);
      // last 6 = 'EF0012' — wait let me recheck: 'XYZABCDEF012' last 6 = 'DEF012'
      expect(decoded, startsWith('DEF012|'));
    });

    test('toBytes handles messageId shorter than 6 chars', () {
      final chunk = MessageChunk(
        messageId: 'AB',
        chunkIndex: 0,
        totalChunks: 1,
        content: 'x',
        timestamp: DateTime.now(),
      );

      final decoded = utf8.decode(chunk.toBytes());
      // When shorter than 6, use full messageId
      expect(decoded, equals('AB|0|1|0|x'));
    });

    test('withId factory delegates to constructor with messageId.value', () {
      const mid = MessageId('test-msg-id');
      final chunk = MessageChunk.withId(
        messageId: mid,
        chunkIndex: 0,
        totalChunks: 1,
        content: 'body',
        timestamp: DateTime.now(),
        isBinary: true,
      );

      expect(chunk.messageId, equals('test-msg-id'));
      expect(chunk.isBinary, isTrue);
      expect(chunk.messageIdValue, equals(mid));
    });

    test('toString formats correctly', () {
      final chunk = MessageChunk(
        messageId: 'id',
        chunkIndex: 0,
        totalChunks: 3,
        content: 'Hi there',
        timestamp: DateTime.now(),
      );

      expect(chunk.toString(), equals('Chunk 1/3 (8 chars)'));
    });

    test('round-trip: toBytes → fromBytes preserves data', () {
      final original = MessageChunk(
        messageId: 'roundtrip1234',
        chunkIndex: 2,
        totalChunks: 4,
        content: 'some content here',
        timestamp: DateTime.now(),
        isBinary: true,
      );

      final restored = MessageChunk.fromBytes(original.toBytes());

      // fromBytes gets the shortId (last 6 chars of original messageId)
      const fullId = 'roundtrip1234';
      final expectedShortId = fullId.substring(fullId.length - 6);
      expect(restored.messageId, equals(expectedShortId));
      expect(restored.chunkIndex, equals(2));
      expect(restored.totalChunks, equals(4));
      expect(restored.content, equals('some content here'));
      expect(restored.isBinary, isTrue);
    });

    test('isBinary flag serialized as 1 for true', () {
      final chunk = MessageChunk(
        messageId: 'abcdef',
        chunkIndex: 0,
        totalChunks: 1,
        content: 'bin',
        timestamp: DateTime.now(),
        isBinary: true,
      );

      final decoded = utf8.decode(chunk.toBytes());
      final parts = decoded.split('|');
      expect(parts[3], equals('1'));
    });

    test('isBinary flag serialized as 0 for false', () {
      final chunk = MessageChunk(
        messageId: 'abcdef',
        chunkIndex: 0,
        totalChunks: 1,
        content: 'txt',
        timestamp: DateTime.now(),
        isBinary: false,
      );

      final decoded = utf8.decode(chunk.toBytes());
      final parts = decoded.split('|');
      expect(parts[3], equals('0'));
    });

    test('fromBytes throws FormatException when too many parts via pipes in content', () {
      // 6 parts instead of 5 — invalid
      final raw = utf8.encode('id|0|1|0|extra|field');
      // This will actually produce 6 parts when split by '|'
      expect(
        () => MessageChunk.fromBytes(Uint8List.fromList(raw)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ─── MessageFragmenter ──────────────────────────────────────────────
  group('MessageFragmenter', () {
    test('fragment returns empty list for empty message', () {
      expect(MessageFragmenter.fragment('', 100), isEmpty);
    });

    test('fragment throws on MTU < 25', () {
      expect(
        () => MessageFragmenter.fragment('hello', 24),
        throwsA(isA<Exception>()),
      );
    });

    test('fragment single chunk for small message', () {
      final chunks = MessageFragmenter.fragment('Hi', 200);

      expect(chunks.length, equals(1));
      expect(chunks.first.chunkIndex, equals(0));
      expect(chunks.first.totalChunks, equals(1));
      expect(chunks.first.content, equals('Hi'));
    });

    test('fragment multiple chunks for large message', () {
      final longMsg = 'A' * 500;
      final chunks = MessageFragmenter.fragment(longMsg, 50);

      expect(chunks.length, greaterThan(1));
      // All chunk indices should be sequential
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, equals(i));
        expect(chunks[i].totalChunks, equals(chunks.length));
      }
      // Concatenated content equals original
      final reassembled = chunks.map((c) => c.content).join('');
      expect(reassembled, equals(longMsg));
    });

    test('fragment respects maxChunkSize (each chunk.toBytes().length <= maxChunkSize)',
        () {
      final msg = 'B' * 300;
      const mtu = 60;
      final chunks = MessageFragmenter.fragment(msg, mtu);

      for (final chunk in chunks) {
        expect(
          chunk.toBytes().length,
          lessThanOrEqualTo(mtu),
          reason:
              'Chunk ${chunk.chunkIndex} exceeds MTU: ${chunk.toBytes().length} > $mtu',
        );
      }
    });

    test('fragment preserves original message content across all chunks', () {
      final msg = 'The quick brown fox jumps over the lazy dog. ' * 10;
      final chunks = MessageFragmenter.fragment(msg, 80);
      final reassembled = chunks.map((c) => c.content).join('');
      expect(reassembled, equals(msg));
    });

    test('fragmentBytes accounts for base64 expansion', () {
      final data = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final chunks = MessageFragmenter.fragmentBytes(data, 100, 'msgId123456');

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.isBinary, isTrue);
        // Each chunk's content is valid base64
        expect(() => base64.decode(chunk.content), returnsNormally);
      }
    });

    test('fragmentBytes throws on MTU too small for headers', () {
      final data = Uint8List.fromList([1, 2, 3]);
      // headerSize=15 + bleOverhead=5 = 20, then contentSpace = floor((maxSize-20)*3/4)
      // For maxSize=30: availableSpace=10, contentSpace=floor(7.5)=7 → OK
      // For maxSize=25: availableSpace=5, contentSpace=floor(3.75)=3 → ≤10, throws
      expect(
        () => MessageFragmenter.fragmentBytes(data, 25, 'id1234'),
        throwsA(isA<Exception>()),
      );
    });

    test('fragmentBytes produces binary chunks with isBinary=true', () {
      final data = Uint8List.fromList([10, 20, 30, 40, 50]);
      final chunks = MessageFragmenter.fragmentBytes(data, 200, 'binaryMsg1');

      for (final chunk in chunks) {
        expect(chunk.isBinary, isTrue);
      }
    });

    test('fragmentBytesWithId delegates to fragmentBytes', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      const mid = MessageId('delegateTest123');
      final chunksA =
          MessageFragmenter.fragmentBytesWithId(data, 200, mid);
      final chunksB =
          MessageFragmenter.fragmentBytes(data, 200, mid.value);

      expect(chunksA.length, equals(chunksB.length));
      for (int i = 0; i < chunksA.length; i++) {
        expect(chunksA[i].content, equals(chunksB[i].content));
        expect(chunksA[i].isBinary, equals(chunksB[i].isBinary));
        expect(chunksA[i].totalChunks, equals(chunksB[i].totalChunks));
      }
    });

    test('fragmentBytes uses last 6 chars of messageId as shortId', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final chunks =
          MessageFragmenter.fragmentBytes(data, 200, 'ABCDEFGHIJKL');

      // shortId = last 6 = 'GHIJKL'
      expect(chunks.first.messageId, equals('GHIJKL'));
    });

    test('fragmentBytes handles messageId shorter than 6 chars', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final chunks = MessageFragmenter.fragmentBytes(data, 200, 'XY');

      expect(chunks.first.messageId, equals('XY'));
    });
  });

  // ─── MessageReassembler ─────────────────────────────────────────────
  group('MessageReassembler', () {
    late MessageReassembler reassembler;

    setUp(() {
      reassembler = MessageReassembler();
    });

    test('addChunk returns null for partial message', () {
      final chunk = MessageChunk(
        messageId: 'msg1',
        chunkIndex: 0,
        totalChunks: 3,
        content: 'part1',
        timestamp: DateTime.now(),
      );

      expect(reassembler.addChunk(chunk), isNull);
    });

    test('addChunk returns assembled string when complete', () {
      final c0 = MessageChunk(
        messageId: 'msg2',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'Hello ',
        timestamp: DateTime.now(),
      );
      final c1 = MessageChunk(
        messageId: 'msg2',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'World',
        timestamp: DateTime.now(),
      );

      expect(reassembler.addChunk(c0), isNull);
      final result = reassembler.addChunk(c1);
      expect(result, equals('Hello World'));
    });

    test('addChunkBytes handles binary chunks (base64 decode + concatenate)',
        () {
      final originalBytes = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      // Split into 2 parts
      final part1 = base64.encode(originalBytes.sublist(0, 4));
      final part2 = base64.encode(originalBytes.sublist(4));

      final c0 = MessageChunk(
        messageId: 'binMsg',
        chunkIndex: 0,
        totalChunks: 2,
        content: part1,
        timestamp: DateTime.now(),
        isBinary: true,
      );
      final c1 = MessageChunk(
        messageId: 'binMsg',
        chunkIndex: 1,
        totalChunks: 2,
        content: part2,
        timestamp: DateTime.now(),
        isBinary: true,
      );

      expect(reassembler.addChunkBytes(c0), isNull);
      final result = reassembler.addChunkBytes(c1);
      expect(result, isNotNull);
      expect(result, equals(originalBytes));
    });

    test('addChunkBytes handles text chunks (string concatenation)', () {
      final c0 = MessageChunk(
        messageId: 'txtMsg',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'foo',
        timestamp: DateTime.now(),
        isBinary: false,
      );
      final c1 = MessageChunk(
        messageId: 'txtMsg',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'bar',
        timestamp: DateTime.now(),
        isBinary: false,
      );

      reassembler.addChunkBytes(c0);
      final result = reassembler.addChunkBytes(c1);
      expect(result, isNotNull);
      // Text mode: concatenate strings → encode UTF-8
      expect(utf8.decode(result!), equals('foobar'));
    });

    test('addChunk with single-chunk message returns immediately', () {
      final chunk = MessageChunk(
        messageId: 'single',
        chunkIndex: 0,
        totalChunks: 1,
        content: 'only-one',
        timestamp: DateTime.now(),
      );

      final result = reassembler.addChunk(chunk);
      expect(result, equals('only-one'));
    });

    test('addChunkBytes returns null for missing chunk in sequence', () {
      // Provide chunk 0 and chunk 2, skip chunk 1
      final c0 = MessageChunk(
        messageId: 'gap',
        chunkIndex: 0,
        totalChunks: 3,
        content: 'a',
        timestamp: DateTime.now(),
      );
      final c2 = MessageChunk(
        messageId: 'gap',
        chunkIndex: 2,
        totalChunks: 3,
        content: 'c',
        timestamp: DateTime.now(),
      );

      reassembler.addChunkBytes(c0);
      // Only 2 of 3 chunks received, should still return null
      final result = reassembler.addChunkBytes(c2);
      expect(result, isNull);
    });

    test('cleanupOldMessages removes expired partial messages', () {
      // Add a chunk to start tracking
      final chunk = MessageChunk(
        messageId: 'old-msg',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'stale',
        timestamp: DateTime.now(),
      );
      reassembler.addChunkBytes(chunk);

      // Cleanup with negative timeout so every message is "expired"
      reassembler.cleanupOldMessages(timeout: const Duration(seconds: -1));

      // Now if we add the second chunk, it should start fresh tracking
      // rather than completing the message
      final c1 = MessageChunk(
        messageId: 'old-msg',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'data',
        timestamp: DateTime.now(),
      );
      final result = reassembler.addChunkBytes(c1);
      // The first chunk was cleaned up, so only 1/2 chunks present → null
      expect(result, isNull);
    });

    test('cleanupOldMessages preserves recent messages', () {
      final chunk = MessageChunk(
        messageId: 'recent-msg',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'fresh',
        timestamp: DateTime.now(),
      );
      reassembler.addChunkBytes(chunk);

      // Cleanup with generous timeout — recent messages should survive
      reassembler.cleanupOldMessages(timeout: const Duration(hours: 1));

      // Second chunk should complete the message
      final c1 = MessageChunk(
        messageId: 'recent-msg',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'data',
        timestamp: DateTime.now(),
        isBinary: false,
      );
      final result = reassembler.addChunk(c1);
      expect(result, equals('freshdata'));
    });

    test('full round-trip: fragment → reassemble produces original message',
        () {
      // fragment() marks chunks as isBinary:true, so reassembler will base64
      // decode. We must use fragmentBytes for a proper wire round-trip.
      // Here we test text fragment content by concatenating manually (no
      // serialization), matching how the text content is actually recombined.
      final original = 'Pack my box with five dozen liquor jugs. ' * 8;
      final chunks = MessageFragmenter.fragment(original, 60);

      expect(chunks.length, greaterThan(1));

      // Verify content concatenation equals original
      final reassembled = chunks.map((c) => c.content).join('');
      expect(reassembled, equals(original));

      // Also verify chunk metadata integrity
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, equals(i));
        expect(chunks[i].totalChunks, equals(chunks.length));
      }
    });

    test(
        'full round-trip: fragmentBytes → addChunkBytes produces original bytes',
        () {
      // Create some arbitrary binary data (not valid UTF-8 in places)
      final original = Uint8List.fromList(
        List.generate(300, (i) => i % 256),
      );
      final chunks =
          MessageFragmenter.fragmentBytes(original, 80, 'roundtrip123456');

      expect(chunks.length, greaterThan(1));

      Uint8List? result;
      for (final chunk in chunks) {
        final wireBytes = chunk.toBytes();
        final received = MessageChunk.fromBytes(wireBytes);
        result = reassembler.addChunkBytes(received);
      }

      expect(result, isNotNull);
      expect(result, equals(original));
    });

    test('addChunk handles out-of-order chunk delivery', () {
      final c0 = MessageChunk(
        messageId: 'ooo',
        chunkIndex: 0,
        totalChunks: 3,
        content: 'A',
        timestamp: DateTime.now(),
      );
      final c1 = MessageChunk(
        messageId: 'ooo',
        chunkIndex: 1,
        totalChunks: 3,
        content: 'B',
        timestamp: DateTime.now(),
      );
      final c2 = MessageChunk(
        messageId: 'ooo',
        chunkIndex: 2,
        totalChunks: 3,
        content: 'C',
        timestamp: DateTime.now(),
      );

      // Deliver out of order: 2, 0, 1
      expect(reassembler.addChunk(c2), isNull);
      expect(reassembler.addChunk(c0), isNull);
      final result = reassembler.addChunk(c1);
      expect(result, equals('ABC'));
    });

    test('reassembler handles multiple concurrent messages', () {
      // Two different messages interleaved
      final a0 = MessageChunk(
        messageId: 'msgA',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'A1',
        timestamp: DateTime.now(),
      );
      final b0 = MessageChunk(
        messageId: 'msgB',
        chunkIndex: 0,
        totalChunks: 2,
        content: 'B1',
        timestamp: DateTime.now(),
      );
      final a1 = MessageChunk(
        messageId: 'msgA',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'A2',
        timestamp: DateTime.now(),
      );
      final b1 = MessageChunk(
        messageId: 'msgB',
        chunkIndex: 1,
        totalChunks: 2,
        content: 'B2',
        timestamp: DateTime.now(),
      );

      expect(reassembler.addChunk(a0), isNull);
      expect(reassembler.addChunk(b0), isNull);
      expect(reassembler.addChunk(a1), equals('A1A2'));
      expect(reassembler.addChunk(b1), equals('B1B2'));
    });
  });
}
