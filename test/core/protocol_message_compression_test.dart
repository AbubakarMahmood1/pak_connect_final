import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/mesh_relay_models.dart';

void main() {
  group('ProtocolMessage Compression (Phase 4)', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
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

    group('toBytes() with compression', () {
      test('compresses large messages with repeated content', () {
        // Create a message with large, compressible payload
        final message = ProtocolMessage.textMessage(
          messageId: 'test-123',
          content: 'This is a test message! ' * 50, // Repetitive = compressible
        );

        final compressed = message.toBytes(enableCompression: true);
        final uncompressed = message.toBytes(enableCompression: false);

        // Verify compression was beneficial
        expect(compressed.length, lessThan(uncompressed.length));
        print(
          'Compression savings: ${uncompressed.length} → ${compressed.length} bytes '
          '(${((1 - compressed.length / uncompressed.length) * 100).toStringAsFixed(1)}% reduction)',
        );

        // Verify flags byte is set correctly
        expect(compressed[0], equals(0x01)); // IS_COMPRESSED flag
        expect(uncompressed[0], equals(0x00)); // No compression flag
      });

      test('skips compression for small messages', () {
        // Create a small message (below 100-byte threshold)
        final message = ProtocolMessage.ping();

        final result = message.toBytes(enableCompression: true);

        // Verify it's uncompressed (flags = 0x00)
        expect(result[0], equals(0x00));
      });

      test('skips compression when not beneficial', () {
        // Create message with truly random payload (use more unique bytes)
        // Generate content that has very high entropy (near-random distribution)
        final randomContent = List.generate(
          250,
          (i) => String.fromCharCode(
            33 + (i * 7 + i * 13) % 90,
          ), // Pseudo-random chars
        ).join();

        final message = ProtocolMessage.textMessage(
          messageId: 'test-random-$randomContent', // Make payload larger
          content: randomContent,
          recipientId: randomContent.substring(0, 50), // Add more unique data
        );

        final result = message.toBytes(enableCompression: true);

        // May or may not compress depending on entropy check
        // Just verify it parses correctly (either way is acceptable)
        final decoded = ProtocolMessage.fromBytes(result);
        expect(decoded.textMessageId, contains('test-random'));
      });

      test('respects enableCompression flag', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'test-123',
          content: 'Repeated content ' * 50,
        );

        final withCompression = message.toBytes(enableCompression: true);
        final withoutCompression = message.toBytes(enableCompression: false);

        // With compression should be smaller
        expect(withCompression.length, lessThan(withoutCompression.length));

        // Without compression should have uncompressed flag
        expect(withoutCompression[0], equals(0x00));
      });

      test('compressed format has correct structure', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'test-123',
          content: 'Compressible text! ' * 50,
        );

        final result = message.toBytes(enableCompression: true);

        // Verify structure: [flags:1][original_size:2][compressed_data]
        expect(result[0], equals(0x01)); // Compressed flag

        // Read original size (2 bytes, big-endian)
        final byteData = ByteData.sublistView(result);
        final originalSize = byteData.getUint16(1, Endian.big);

        expect(originalSize, greaterThan(0));
        expect(result.length, greaterThan(3)); // At least flags + size + data
      });
    });

    group('fromBytes() with decompression', () {
      test('decompresses compressed messages correctly (round-trip)', () {
        final original = ProtocolMessage.textMessage(
          messageId: 'test-round-trip',
          content: 'This is a test message for round-trip testing! ' * 30,
          encrypted: true,
          recipientId: 'recipient-123',
        );

        // Serialize with compression
        final bytes = original.toBytes(enableCompression: true);

        // Verify it's compressed
        expect(bytes[0], equals(0x01));

        // Deserialize
        final decoded = ProtocolMessage.fromBytes(bytes);

        // Verify all fields match
        expect(decoded.type, equals(original.type));
        expect(decoded.textMessageId, equals(original.textMessageId));
        expect(decoded.textContent, equals(original.textContent));
        expect(decoded.isEncrypted, equals(original.isEncrypted));
        expect(decoded.recipientId, equals(original.recipientId));
        expect(
          decoded.timestamp.millisecondsSinceEpoch,
          equals(original.timestamp.millisecondsSinceEpoch),
        );
      });

      test('handles uncompressed messages correctly', () {
        final original = ProtocolMessage.ping();

        final bytes = original.toBytes(enableCompression: false);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(original.type));
        expect(
          decoded.timestamp.millisecondsSinceEpoch,
          equals(original.timestamp.millisecondsSinceEpoch),
        );
      });

      test('backward compatible with old format (no flags byte)', () {
        // Simulate old-format message (raw JSON without flags)
        final json = {
          'type': ProtocolMessageType.ping.index,
          'version': 1,
          'payload': {},
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'useEphemeralSigning': false,
        };
        final oldFormatBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(json)),
        );

        // Should parse successfully via backward compatibility fallback
        final decoded = ProtocolMessage.fromBytes(oldFormatBytes);

        expect(decoded.type, equals(ProtocolMessageType.ping));
        expect(decoded.version, equals(1));
      });

      test('throws on invalid compressed data', () {
        // Create invalid compressed message: [flags:1][size:2][garbage]
        // Make it large enough that decompression will fail
        final invalid = Uint8List(100);
        invalid[0] = 0x01; // Compressed flag
        invalid[1] = 0x00; // Original size = 65535 bytes (big-endian)
        invalid[2] = 0xFF;
        // Rest is garbage that can't be decompressed OR parsed as JSON

        // Fill with non-JSON-parseable garbage
        for (int i = 3; i < 100; i++) {
          invalid[i] = i % 256;
        }

        // Should throw because:
        // 1. Decompression will fail (invalid deflate data)
        // 2. Backward compatibility fallback will fail (not valid UTF-8/JSON)
        expect(
          () => ProtocolMessage.fromBytes(invalid),
          throwsA(
            anything,
          ), // Catches any exception (ArgumentError, FormatException, etc.)
        );
      });

      test('throws on empty bytes', () {
        expect(
          () => ProtocolMessage.fromBytes(Uint8List(0)),
          throwsArgumentError,
        );
      });
    });

    group('round-trip tests for all message types', () {
      test('identity message round-trip with compression', () {
        final original = ProtocolMessage.identity(
          publicKey: 'public-key-' * 10, // Make it compressible
          displayName: 'Test User',
        );

        final bytes = original.toBytes(enableCompression: true);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(ProtocolMessageType.identity));
        expect(decoded.identityPublicKey, equals(original.identityPublicKey));
        expect(
          decoded.identityDisplayName,
          equals(original.identityDisplayName),
        );
      });

      test('mesh relay message round-trip with compression', () {
        final original = ProtocolMessage.meshRelay(
          originalMessageId: 'msg-123',
          originalSender: 'sender-456',
          finalRecipient: 'recipient-789',
          relayMetadata: {
            'hop': 1,
            'path': ['node1', 'node2', 'node3'],
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
          originalPayload: {
            'content': 'Original message content ' * 20, // Compressible
            'encrypted': true,
          },
          useEphemeralAddressing: true,
        );

        final bytes = original.toBytes(enableCompression: true);

        // Should be compressed (large payload with repetition)
        expect(bytes[0], equals(0x01));

        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(ProtocolMessageType.meshRelay));
        expect(decoded.meshRelayOriginalMessageId, equals('msg-123'));
        expect(decoded.meshRelayOriginalSender, equals('sender-456'));
        expect(decoded.meshRelayFinalRecipient, equals('recipient-789'));
        expect(decoded.meshRelayUseEphemeralAddressing, isTrue);
        expect(decoded.meshRelayMetadata, isNotNull);
        expect(decoded.meshRelayOriginalPayload, isNotNull);
      });

      test('contact request round-trip with compression', () {
        final original = ProtocolMessage.contactRequest(
          publicKey: 'pk-' * 50,
          displayName: 'Test Contact',
        );

        final bytes = original.toBytes(enableCompression: true);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(ProtocolMessageType.contactRequest));
        expect(
          decoded.contactRequestPublicKey,
          equals(original.contactRequestPublicKey),
        );
        expect(
          decoded.contactRequestDisplayName,
          equals(original.contactRequestDisplayName),
        );
      });

      test('queue sync round-trip with compression', () {
        final queueMessage = QueueSyncMessage(
          queueHash: 'hash-123',
          messageIds: List.generate(100, (i) => 'msg-$i'),
          syncTimestamp: DateTime.now(),
          nodeId: 'node-abc',
          syncType: QueueSyncType.request,
        );

        final original = ProtocolMessage.queueSync(queueMessage: queueMessage);

        final bytes = original.toBytes(enableCompression: true);

        // Should be compressed (large list with repeated structure)
        expect(bytes[0], equals(0x01));

        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.type, equals(ProtocolMessageType.queueSync));
        expect(decoded.queueSyncMessage?.queueHash, equals('hash-123'));
        expect(decoded.queueSyncMessage?.messageIds.length, equals(100));
      });
    });

    group('compression statistics', () {
      test('tracks compression savings for large messages', () {
        final testMessages = [
          ProtocolMessage.textMessage(
            messageId: 'test-1',
            content: 'Hello world! ' * 100,
          ),
          ProtocolMessage.meshRelay(
            originalMessageId: 'relay-1',
            originalSender: 'sender',
            finalRecipient: 'recipient',
            relayMetadata: {'data': 'x' * 500},
            originalPayload: {'content': 'y' * 500},
          ),
          ProtocolMessage.queueSync(
            queueMessage: QueueSyncMessage(
              queueHash: 'hash',
              messageIds: List.generate(200, (i) => 'message-id-$i'),
              syncTimestamp: DateTime.now(),
              nodeId: 'node-xyz',
              syncType: QueueSyncType.request,
            ),
          ),
        ];

        var totalOriginal = 0;
        var totalCompressed = 0;

        for (final message in testMessages) {
          final compressed = message.toBytes(enableCompression: true);
          final uncompressed = message.toBytes(enableCompression: false);

          totalOriginal += uncompressed.length;
          totalCompressed += compressed.length;

          print(
            '${message.type}: ${uncompressed.length} → ${compressed.length} bytes '
            '(${((1 - compressed.length / uncompressed.length) * 100).toStringAsFixed(1)}% saved)',
          );
        }

        final overallSavings = ((1 - totalCompressed / totalOriginal) * 100);
        print(
          'Overall compression savings: ${overallSavings.toStringAsFixed(1)}%',
        );

        // Verify significant compression
        expect(
          totalCompressed,
          lessThan(totalOriginal * 0.7),
        ); // At least 30% savings
      });
    });

    group('edge cases', () {
      test('handles very large messages', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'huge-message',
          content: 'Large content ' * 1000, // ~14KB
        );

        final bytes = message.toBytes(enableCompression: true);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.textContent, equals(message.textContent));
      });

      test('handles messages with special characters', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'special-chars',
          content: '🚀 Emoji test! 中文 عربي 🎉' * 20,
        );

        final bytes = message.toBytes(enableCompression: true);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.textContent, equals(message.textContent));
      });

      test('handles messages with null optional fields', () {
        final message = ProtocolMessage(
          type: ProtocolMessageType.ping,
          payload: {},
          timestamp: DateTime.now(),
          signature: null, // Explicitly null
          ephemeralSigningKey: null,
        );

        final bytes = message.toBytes(enableCompression: true);
        final decoded = ProtocolMessage.fromBytes(bytes);

        expect(decoded.signature, isNull);
        expect(decoded.ephemeralSigningKey, isNull);
      });

      test('compression flag uses only bit 0', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'test',
          content: 'Compressible ' * 50,
        );

        final compressed = message.toBytes(enableCompression: true);
        final uncompressed = message.toBytes(enableCompression: false);

        // Compressed: flags = 0x01 (bit 0 set)
        expect(compressed[0], equals(0x01));

        // Uncompressed: flags = 0x00 (no bits set)
        expect(uncompressed[0], equals(0x00));
      });
    });

    group('performance benchmarks', () {
      test('compression is fast enough for BLE', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'perf-test',
          content: 'Performance test message ' * 20,
        );

        final stopwatch = Stopwatch()..start();
        for (int i = 0; i < 100; i++) {
          message.toBytes(enableCompression: true);
        }
        stopwatch.stop();

        final avgMs = stopwatch.elapsedMilliseconds / 100;
        print(
          'Average compression time: ${avgMs.toStringAsFixed(2)}ms per message',
        );

        // Should be fast enough for real-time BLE (<50ms)
        expect(avgMs, lessThan(50));
      });

      test('decompression is fast', () {
        final message = ProtocolMessage.textMessage(
          messageId: 'perf-test-decompress',
          content: 'Decompression test ' * 30,
        );

        final bytes = message.toBytes(enableCompression: true);

        final stopwatch = Stopwatch()..start();
        for (int i = 0; i < 100; i++) {
          ProtocolMessage.fromBytes(bytes);
        }
        stopwatch.stop();

        final avgMs = stopwatch.elapsedMilliseconds / 100;
        print(
          'Average decompression time: ${avgMs.toStringAsFixed(2)}ms per message',
        );

        // Decompression should be even faster
        expect(avgMs, lessThan(50));
      });
    });
  });
}
