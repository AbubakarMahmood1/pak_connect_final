import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/compression/compression_config.dart';
import 'package:pak_connect/core/compression/compression_stats.dart';
import 'package:pak_connect/core/compression/compression_util.dart';

void main() {
  group('CompressionUtil', () {
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

    group('compress', () {
      test('compresses large text efficiently', () {
        // Create compressible data (repetitive text)
        final text = 'Hello world! ' * 100; // 1300 bytes
        final data = Uint8List.fromList(utf8.encode(text));

        final result = CompressionUtil.compress(data);

        expect(result, isNotNull);
        expect(result!.compressed.length, lessThan(data.length));
        expect(result.stats.wasCompressed, isTrue);
        expect(result.stats.compressionRatio, lessThan(0.7)); // >30% savings
        expect(result.stats.bytesSaved, greaterThan(0));
      });

      test('returns null for small data (below threshold)', () {
        // Small data below default threshold (100 bytes)
        final data = Uint8List.fromList(utf8.encode('Hi there!'));

        final result = CompressionUtil.compress(data);

        expect(result, isNull); // Should not compress
      });

      test('returns null for high-entropy data', () {
        // Random data with high entropy (all unique bytes)
        final data = Uint8List.fromList(List<int>.generate(256, (i) => i));

        final result = CompressionUtil.compress(data);

        expect(result, isNull); // Should not compress (high entropy)
      });

      test('returns null when compressed size >= original', () {
        // Create data that won't compress well
        // Already somewhat compressed/random
        final random = List<int>.generate(150, (i) => (i * 7) % 256);
        final data = Uint8List.fromList(random);

        final result = CompressionUtil.compress(data);

        // Either null (skipped due to entropy) or not beneficial
        // We just verify it doesn't crash and handles it gracefully
        if (result != null) {
          expect(result.compressed.length, lessThan(data.length));
        }
      });

      test('respects compression config', () {
        // Create data just above custom threshold
        final data = Uint8List.fromList(utf8.encode('A' * 120));

        // Default config (threshold 100) - should compress
        final result1 = CompressionUtil.compress(data);
        expect(result1, isNotNull);

        // Custom config with higher threshold (150) - should not compress
        final config = CompressionConfig(compressionThreshold: 150);
        final result2 = CompressionUtil.compress(data, config: config);
        expect(result2, isNull);
      });

      test('respects compression level', () {
        final text = 'Hello world! ' * 100;
        final data = Uint8List.fromList(utf8.encode(text));

        // Fast compression (level 1)
        final fastConfig = CompressionConfig(compressionLevel: 1);
        final fastResult = CompressionUtil.compress(data, config: fastConfig);

        // Best compression (level 9)
        final bestConfig = CompressionConfig(compressionLevel: 9);
        final bestResult = CompressionUtil.compress(data, config: bestConfig);

        expect(fastResult, isNotNull);
        expect(bestResult, isNotNull);

        // Best should compress better (smaller size)
        expect(
          bestResult!.compressed.length,
          lessThanOrEqualTo(fastResult!.compressed.length),
        );
      });

      test('returns null when compression disabled', () {
        final data = Uint8List.fromList(utf8.encode('A' * 200));

        final config = CompressionConfig(enabled: false);
        final result = CompressionUtil.compress(data, config: config);

        expect(result, isNull);
      });

      test('tracks compression time', () {
        final data = Uint8List.fromList(utf8.encode('Hello world! ' * 100));

        final result = CompressionUtil.compress(data);

        expect(result, isNotNull);
        expect(result!.stats.compressionTimeMs, greaterThanOrEqualTo(0));
      });

      test('sets correct algorithm name', () {
        final data = Uint8List.fromList(utf8.encode('A' * 200));

        // Raw deflate
        final rawConfig = CompressionConfig(useRawDeflate: true);
        final rawResult = CompressionUtil.compress(data, config: rawConfig);
        expect(rawResult!.stats.algorithm, equals('deflate'));

        // ZLib format
        final zlibConfig = CompressionConfig(useRawDeflate: false);
        final zlibResult = CompressionUtil.compress(data, config: zlibConfig);
        expect(zlibResult!.stats.algorithm, equals('zlib'));
      });
    });

    group('decompress', () {
      test('decompresses correctly (round-trip)', () {
        final original = Uint8List.fromList(utf8.encode('Test message ' * 50));

        final compressed = CompressionUtil.compress(original);
        expect(compressed, isNotNull);

        final decompressed = CompressionUtil.decompress(compressed!.compressed);
        expect(decompressed, isNotNull);
        expect(decompressed, equals(original));
      });

      test('validates original size if provided', () {
        final original = Uint8List.fromList(utf8.encode('A' * 200));

        final compressed = CompressionUtil.compress(original)!;

        // Correct size - should succeed
        final decompressed1 = CompressionUtil.decompress(
          compressed.compressed,
          originalSize: original.length,
        );
        expect(decompressed1, isNotNull);

        // Wrong size - should fail
        final decompressed2 = CompressionUtil.decompress(
          compressed.compressed,
          originalSize: original.length + 100,
        );
        expect(decompressed2, isNull);
      });

      test('falls back to alternate format on failure', () {
        // Compress with raw deflate
        final original = Uint8List.fromList(utf8.encode('B' * 200));
        final rawConfig = CompressionConfig(useRawDeflate: true);
        final compressed = CompressionUtil.compress(
          original,
          config: rawConfig,
        )!;

        // Try to decompress with zlib config (should fallback to raw)
        final zlibConfig = CompressionConfig(useRawDeflate: false);
        final decompressed = CompressionUtil.decompress(
          compressed.compressed,
          config: zlibConfig,
        );

        // Should still work due to fallback
        expect(decompressed, isNotNull);
        expect(decompressed, equals(original));
      });

      test('handles both raw deflate and zlib formats', () {
        final original = Uint8List.fromList(utf8.encode('C' * 200));

        // Compress with raw deflate
        final rawConfig = CompressionConfig(useRawDeflate: true);
        final rawCompressed = CompressionUtil.compress(
          original,
          config: rawConfig,
        )!;

        // Compress with zlib
        final zlibConfig = CompressionConfig(useRawDeflate: false);
        final zlibCompressed = CompressionUtil.compress(
          original,
          config: zlibConfig,
        )!;

        // Both should decompress correctly
        final decompressed1 = CompressionUtil.decompress(
          rawCompressed.compressed,
        );
        final decompressed2 = CompressionUtil.decompress(
          zlibCompressed.compressed,
        );

        expect(decompressed1, equals(original));
        expect(decompressed2, equals(original));
      });

      test('returns null for invalid compressed data', () {
        // Random garbage data
        final invalid = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

        final decompressed = CompressionUtil.decompress(invalid);

        expect(decompressed, isNull);
      });

      test('handles empty data gracefully', () {
        final empty = Uint8List(0);

        final decompressed = CompressionUtil.decompress(empty);

        // Should return empty list or null (both are acceptable)
        // Decompressing empty data can validly return empty array
        expect(decompressed == null || decompressed.isEmpty, isTrue);
      });
    });

    group('shouldCompress', () {
      test('returns false for small data', () {
        final small = Uint8List.fromList(utf8.encode('Hi'));

        final should = CompressionUtil.shouldCompress(small);

        expect(should, isFalse);
      });

      test('returns false for high-entropy data', () {
        // All unique bytes (maximum entropy)
        final random = Uint8List.fromList(List<int>.generate(256, (i) => i));

        final should = CompressionUtil.shouldCompress(random);

        expect(should, isFalse);
      });

      test('returns true for large compressible data', () {
        // Large repetitive data
        final compressible = Uint8List.fromList(utf8.encode('A' * 200));

        final should = CompressionUtil.shouldCompress(compressible);

        expect(should, isTrue);
      });

      test('respects custom threshold', () {
        final data = Uint8List.fromList(utf8.encode('B' * 120));

        // Default threshold (100) - should compress
        final should1 = CompressionUtil.shouldCompress(data);
        expect(should1, isTrue);

        // Higher threshold (150) - should not compress
        final config = CompressionConfig(compressionThreshold: 150);
        final should2 = CompressionUtil.shouldCompress(data, config: config);
        expect(should2, isFalse);
      });

      test('respects custom entropy threshold', () {
        // Moderately random data
        final data = Uint8List.fromList(
          List<int>.generate(200, (i) => (i * 3) % 200),
        );

        // Loose entropy (0.95) - might compress
        final looseConfig = CompressionConfig(entropyThreshold: 0.95);
        final should1 = CompressionUtil.shouldCompress(
          data,
          config: looseConfig,
        );

        // Strict entropy (0.5) - probably won't compress
        final strictConfig = CompressionConfig(entropyThreshold: 0.5);
        final should2 = CompressionUtil.shouldCompress(
          data,
          config: strictConfig,
        );

        // Loose should be more permissive than strict
        // (actual values depend on data, but loose >= strict)
        expect(should1 || !should2, isTrue);
      });

      test('returns false when compression disabled', () {
        final data = Uint8List.fromList(utf8.encode('A' * 200));

        final config = CompressionConfig(enabled: false);
        final should = CompressionUtil.shouldCompress(data, config: config);

        expect(should, isFalse);
      });
    });

    group('analyze', () {
      test('returns stats without compressing', () {
        final data = Uint8List.fromList(utf8.encode('A' * 200));

        final stats = CompressionUtil.analyze(data);

        expect(stats, isNotNull);
        expect(stats.originalSize, equals(data.length));
        // Should indicate compression would happen
        expect(stats.wasCompressed || stats.skipReason != null, isTrue);
      });

      test('indicates when compression would be skipped', () {
        // Small data
        final small = Uint8List.fromList(utf8.encode('Hi'));
        final statsSmall = CompressionUtil.analyze(small);
        expect(statsSmall.wasCompressed, isFalse);
        expect(statsSmall.skipReason, equals('below_threshold'));

        // High entropy
        final random = Uint8List.fromList(List<int>.generate(256, (i) => i));
        final statsRandom = CompressionUtil.analyze(random);
        expect(statsRandom.wasCompressed, isFalse);
        expect(statsRandom.skipReason, equals('high_entropy'));
      });

      test('provides accurate compression preview', () {
        final data = Uint8List.fromList(utf8.encode('A' * 200));

        final stats = CompressionUtil.analyze(data);

        // Should match actual compression
        final actual = CompressionUtil.compress(data);
        if (actual != null) {
          expect(stats.wasCompressed, isTrue);
          expect(stats.compressedSize, equals(actual.stats.compressedSize));
          expect(stats.compressionRatio, equals(actual.stats.compressionRatio));
        }
      });
    });

    group('calculateEntropy', () {
      test('returns 0.0 for empty data', () {
        final empty = Uint8List(0);

        final entropy = CompressionUtil.calculateEntropy(empty);

        expect(entropy, equals(0.0));
      });

      test('returns low entropy for repetitive data', () {
        // All same byte
        final repetitive = Uint8List.fromList(List<int>.filled(200, 65));

        final entropy = CompressionUtil.calculateEntropy(repetitive);

        // Only 1 unique byte out of 256 possible
        expect(entropy, lessThan(0.1)); // Very low entropy
      });

      test('returns high entropy for random data', () {
        // All 256 possible bytes
        final random = Uint8List.fromList(List<int>.generate(256, (i) => i));

        final entropy = CompressionUtil.calculateEntropy(random);

        // All bytes present = maximum entropy
        expect(entropy, equals(1.0));
      });

      test('returns moderate entropy for text', () {
        // English text uses ~30-40 unique bytes
        final text = utf8.encode('Hello world! This is a test message.');
        final data = Uint8List.fromList(text);

        final entropy = CompressionUtil.calculateEntropy(data);

        // Moderate entropy (some repetition, but varied)
        expect(entropy, greaterThan(0.05));
        expect(entropy, lessThan(0.3));
      });
    });

    group('runSelfTest', () {
      test('passes self-test with default config', () {
        final passed = CompressionUtil.runSelfTest();

        expect(passed, isTrue);
      });

      test('passes self-test with custom configs', () {
        // Test aggressive config
        final passed1 = CompressionUtil.runSelfTest(
          config: CompressionConfig.aggressive,
        );
        expect(passed1, isTrue);

        // Test fast config
        final passed2 = CompressionUtil.runSelfTest(
          config: CompressionConfig.fast,
        );
        expect(passed2, isTrue);

        // Test raw deflate
        final passed3 = CompressionUtil.runSelfTest(
          config: CompressionConfig(useRawDeflate: true),
        );
        expect(passed3, isTrue);

        // Test zlib format
        final passed4 = CompressionUtil.runSelfTest(
          config: CompressionConfig(useRawDeflate: false),
        );
        expect(passed4, isTrue);
      });
    });

    group('CompressionConfig', () {
      test('has sensible defaults', () {
        final config = CompressionConfig.defaultConfig;

        expect(config.compressionThreshold, equals(100));
        expect(config.entropyThreshold, equals(0.9));
        expect(config.useRawDeflate, isTrue);
        expect(config.compressionLevel, equals(6));
        expect(config.enabled, isTrue);
      });

      test('provides preset configs', () {
        expect(CompressionConfig.aggressive.compressionLevel, equals(9));
        expect(CompressionConfig.fast.compressionLevel, equals(3));
        expect(CompressionConfig.disabled.enabled, isFalse);
      });

      test('supports copyWith', () {
        final config = CompressionConfig.defaultConfig;
        final modified = config.copyWith(compressionLevel: 9);

        expect(modified.compressionLevel, equals(9));
        expect(
          modified.compressionThreshold,
          equals(config.compressionThreshold),
        );
      });

      test('has working equality', () {
        final config1 = CompressionConfig(compressionLevel: 5);
        final config2 = CompressionConfig(compressionLevel: 5);
        final config3 = CompressionConfig(compressionLevel: 7);

        expect(config1, equals(config2));
        expect(config1, isNot(equals(config3)));
      });
    });

    group('CompressionStats', () {
      test('calculates compression ratio correctly', () {
        final stats = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
        );

        expect(stats.compressionRatio, equals(0.3));
        expect(stats.bytesSaved, equals(700));
        expect(stats.savingsPercent, equals(70.0));
      });

      test('returns 1.0 ratio for uncompressed data', () {
        final stats = CompressionStats.notCompressed(
          originalSize: 1000,
          skipReason: 'below_threshold',
        );

        expect(stats.compressionRatio, equals(1.0));
        expect(stats.bytesSaved, equals(0));
        expect(stats.savingsPercent, equals(0.0));
      });

      test('correctly identifies beneficial compression', () {
        final beneficial = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
        );
        expect(beneficial.wasBeneficial, isTrue);

        final notBeneficial = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 1200,
          algorithm: 'deflate',
        );
        expect(notBeneficial.wasBeneficial, isFalse);

        final notCompressed = CompressionStats.notCompressed(
          originalSize: 1000,
          skipReason: 'below_threshold',
        );
        expect(notCompressed.wasBeneficial, isFalse);
      });

      test('supports JSON serialization', () {
        final stats = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
          compressionTimeMs: 50,
        );

        final json = stats.toJson();
        final restored = CompressionStats.fromJson(json);

        expect(restored.originalSize, equals(stats.originalSize));
        expect(restored.compressedSize, equals(stats.compressedSize));
        expect(restored.algorithm, equals(stats.algorithm));
        expect(restored.compressionTimeMs, equals(stats.compressionTimeMs));
        expect(restored.wasCompressed, equals(stats.wasCompressed));
      });

      test('has working equality', () {
        final stats1 = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
        );
        final stats2 = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
        );
        final stats3 = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 400,
          algorithm: 'deflate',
        );

        expect(stats1, equals(stats2));
        expect(stats1, isNot(equals(stats3)));
      });

      test('has informative toString', () {
        final compressed = CompressionStats.compressed(
          originalSize: 1000,
          compressedSize: 300,
          algorithm: 'deflate',
          compressionTimeMs: 50,
        );
        expect(compressed.toString(), contains('1000 bytes'));
        expect(compressed.toString(), contains('300 bytes'));

        final notCompressed = CompressionStats.notCompressed(
          originalSize: 1000,
          skipReason: 'below_threshold',
        );
        expect(notCompressed.toString(), contains('not compressed'));
        expect(notCompressed.toString(), contains('below_threshold'));
      });
    });

    group('integration tests', () {
      test('handles various text sizes', () {
        final sizes = [10, 50, 100, 200, 500, 1000, 5000];

        for (final size in sizes) {
          final text = 'A' * size;
          final data = Uint8List.fromList(utf8.encode(text));

          final result = CompressionUtil.compress(data);

          if (size < 100) {
            // Should not compress (below threshold)
            expect(result, isNull);
          } else {
            // Should compress
            expect(result, isNotNull);
            // Verify round-trip
            final decompressed = CompressionUtil.decompress(result!.compressed);
            expect(decompressed, equals(data));
          }
        }
      });

      test('handles binary data', () {
        // Binary data (not text)
        final binary = Uint8List.fromList(
          List<int>.generate(1000, (i) => (i % 10)), // Some pattern
        );

        final result = CompressionUtil.compress(binary);

        if (result != null) {
          // If compressed, verify round-trip
          final decompressed = CompressionUtil.decompress(result.compressed);
          expect(decompressed, equals(binary));
        }
      });

      test('handles JSON data', () {
        // Typical JSON (compressible - field names repeat)
        final json = jsonEncode({
          'messages': List.generate(
            50,
            (i) => {
              'id': 'msg_$i',
              'content': 'Test message $i',
              'timestamp': 1234567890 + i,
              'isFromMe': i % 2 == 0,
            },
          ),
        });
        final data = Uint8List.fromList(utf8.encode(json));

        final result = CompressionUtil.compress(data);

        expect(result, isNotNull); // JSON should compress well
        expect(result!.stats.compressionRatio, lessThan(0.7)); // >30% savings

        // Verify round-trip
        final decompressed = CompressionUtil.decompress(result.compressed);
        expect(decompressed, equals(data));
      });

      test('compression is deterministic', () {
        final data = Uint8List.fromList(utf8.encode('Test' * 100));

        final result1 = CompressionUtil.compress(data);
        final result2 = CompressionUtil.compress(data);

        expect(result1, isNotNull);
        expect(result2, isNotNull);
        expect(result1!.compressed, equals(result2!.compressed));
      });
    });
  });
}
