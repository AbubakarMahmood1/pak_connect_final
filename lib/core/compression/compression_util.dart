import 'dart:io';
import 'dart:typed_data';

import 'compression_config.dart';
import 'compression_stats.dart';

/// Result of a compression operation
class CompressionResult {
  final Uint8List compressed;
  final CompressionStats stats;

  const CompressionResult({required this.compressed, required this.stats});
}

/// Compression utility for data compression and decompression
///
/// Uses Dart's built-in ZLibCodec (deflate algorithm) for compression.
/// Based on bitchat's proven compression approach with:
/// - Size threshold check (skip small data)
/// - Entropy check (skip already compressed data)
/// - Benefit check (only use if compressed < original)
/// - Graceful fallback (handle both raw and zlib formats)
///
/// Example usage:
/// ```dart
/// final data = Uint8List.fromList(utf8.encode('Hello world! ' * 100));
///
/// // Compress
/// final result = CompressionUtil.compress(data);
/// if (result != null) {
///   print('Compressed: ${data.length} -> ${result.compressed.length} bytes');
/// }
///
/// // Decompress
/// if (result != null) {
///   final decompressed = CompressionUtil.decompress(result.compressed);
///   print('Decompressed: ${decompressed?.length} bytes');
/// }
/// ```
class CompressionUtil {
  /// Prevent instantiation (utility class with static methods only)
  CompressionUtil._();

  /// Check if data should be compressed based on size and entropy
  ///
  /// Returns false if:
  /// - Data is smaller than threshold (compression overhead not worth it)
  /// - Data has high entropy (likely already compressed)
  ///
  /// This matches bitchat's approach to avoid wasting CPU on incompressible data.
  static bool shouldCompress(
    Uint8List data, {
    CompressionConfig config = CompressionConfig.defaultConfig,
  }) {
    // Check if compression is enabled globally
    if (!config.enabled) return false;

    // Check size threshold
    if (data.length < config.compressionThreshold) {
      return false;
    }

    // Check entropy (bitchat's approach)
    // Count unique bytes in the data
    final byteFrequency = <int, int>{};
    for (final byte in data) {
      byteFrequency[byte] = (byteFrequency[byte] ?? 0) + 1;
    }

    // Calculate unique byte ratio
    // High ratio (e.g., 0.9+) means data is random/already compressed
    final uniqueByteRatio = byteFrequency.length / 256.0;

    // If too many unique bytes, data likely won't compress well
    return uniqueByteRatio < config.entropyThreshold;
  }

  /// Compress data using ZLib deflate algorithm
  ///
  /// Returns CompressionResult with compressed data and stats if compression
  /// was successful and beneficial. Returns null if:
  /// - Data is below size threshold
  /// - Data has high entropy (already compressed)
  /// - Compression failed
  /// - Compressed size >= original size (not beneficial)
  ///
  /// This follows bitchat's pattern of transparent failure handling.
  static CompressionResult? compress(
    Uint8List data, {
    CompressionConfig config = CompressionConfig.defaultConfig,
  }) {
    try {
      // Check if compression is enabled
      if (!config.enabled) {
        return null;
      }

      // Check if we should compress
      if (!shouldCompress(data, config: config)) {
        return null;
      }

      // Start timing
      final stopwatch = Stopwatch()..start();

      // Create codec (raw deflate or with zlib headers)
      final codec = ZLibCodec(
        level: config.compressionLevel,
        raw: config.useRawDeflate,
      );

      // Compress
      final compressed = codec.encode(data);
      final compressedBytes = Uint8List.fromList(compressed);

      stopwatch.stop();

      // Benefit check: only use if compressed is smaller
      if (compressedBytes.length >= data.length) {
        return null; // Not beneficial
      }

      // Create stats
      final stats = CompressionStats.compressed(
        originalSize: data.length,
        compressedSize: compressedBytes.length,
        algorithm: config.useRawDeflate ? 'deflate' : 'zlib',
        compressionTimeMs: stopwatch.elapsedMilliseconds,
      );

      return CompressionResult(compressed: compressedBytes, stats: stats);
    } catch (e) {
      // Compression failed - return null (transparent failure)
      return null;
    }
  }

  /// Decompress data using ZLib inflate algorithm
  ///
  /// Attempts to decompress using raw deflate first (matching compress()).
  /// If that fails, falls back to zlib format (with headers) for robustness.
  ///
  /// Returns decompressed data or null if decompression failed.
  ///
  /// Parameters:
  /// - compressed: The compressed data to decompress
  /// - originalSize: Optional original size for validation (if known)
  /// - config: Compression configuration (mainly for raw/zlib format)
  static Uint8List? decompress(
    Uint8List compressed, {
    int? originalSize,
    CompressionConfig config = CompressionConfig.defaultConfig,
  }) {
    try {
      // Try primary format (raw deflate or zlib, based on config)
      try {
        final codec = ZLibCodec(raw: config.useRawDeflate);
        final decompressed = codec.decode(compressed);
        final decompressedBytes = Uint8List.fromList(decompressed);

        // Validate size if provided
        if (originalSize != null && decompressedBytes.length != originalSize) {
          throw Exception(
            'Decompressed size mismatch: expected $originalSize, got ${decompressedBytes.length}',
          );
        }

        return decompressedBytes;
      } catch (primaryError) {
        // Primary format failed, try fallback
        // If we tried raw deflate, try zlib (with headers)
        // If we tried zlib, try raw deflate
        final fallbackCodec = ZLibCodec(raw: !config.useRawDeflate);
        final decompressed = fallbackCodec.decode(compressed);
        final decompressedBytes = Uint8List.fromList(decompressed);

        // Validate size if provided
        if (originalSize != null && decompressedBytes.length != originalSize) {
          throw Exception(
            'Decompressed size mismatch: expected $originalSize, got ${decompressedBytes.length}',
          );
        }

        return decompressedBytes;
      }
    } catch (e) {
      // Both attempts failed
      return null;
    }
  }

  /// Analyze data without compressing (preview)
  ///
  /// Returns stats about what would happen if data were compressed.
  /// Useful for:
  /// - Previewing compression benefits
  /// - Monitoring compression candidates
  /// - Debugging compression decisions
  ///
  /// This does NOT actually compress the data, just analyzes it.
  static CompressionStats analyze(
    Uint8List data, {
    CompressionConfig config = CompressionConfig.defaultConfig,
  }) {
    // Check if compression would be attempted
    if (!config.enabled) {
      return CompressionStats.notCompressed(
        originalSize: data.length,
        skipReason: 'compression_disabled',
      );
    }

    if (data.length < config.compressionThreshold) {
      return CompressionStats.notCompressed(
        originalSize: data.length,
        skipReason: 'below_threshold',
      );
    }

    // Check entropy
    final byteFrequency = <int, int>{};
    for (final byte in data) {
      byteFrequency[byte] = (byteFrequency[byte] ?? 0) + 1;
    }
    final uniqueByteRatio = byteFrequency.length / 256.0;

    if (uniqueByteRatio >= config.entropyThreshold) {
      return CompressionStats.notCompressed(
        originalSize: data.length,
        skipReason: 'high_entropy',
      );
    }

    // Compression would be attempted
    // Actually compress to get accurate stats
    final result = compress(data, config: config);
    if (result != null) {
      return result.stats;
    }

    // Compression would fail or not be beneficial
    return CompressionStats.notCompressed(
      originalSize: data.length,
      skipReason: 'not_beneficial',
    );
  }

  /// Calculate entropy of data (0.0 to 1.0)
  ///
  /// Entropy measures randomness/uniqueness of data:
  /// - 0.0: All bytes are the same (highly compressible)
  /// - 0.5: Moderate repetition (compressible)
  /// - 0.9+: High randomness (likely already compressed)
  /// - 1.0: All 256 possible bytes present (maximum entropy)
  ///
  /// This is the same calculation used in shouldCompress().
  static double calculateEntropy(Uint8List data) {
    if (data.isEmpty) return 0.0;

    final byteFrequency = <int, int>{};
    for (final byte in data) {
      byteFrequency[byte] = (byteFrequency[byte] ?? 0) + 1;
    }

    return byteFrequency.length / 256.0;
  }

  /// Test compression on sample data (for debugging)
  ///
  /// Compresses and decompresses sample data to verify the compression
  /// system is working correctly.
  ///
  /// Returns true if test passed, false otherwise.
  static bool runSelfTest({CompressionConfig? config}) {
    config ??= CompressionConfig.defaultConfig;

    try {
      // Test 1: Compress highly compressible data
      final testData1 = Uint8List.fromList(
        List<int>.filled(500, 65), // 'AAAAA...' (500 bytes)
      );

      final result1 = compress(testData1, config: config);
      if (result1 == null) return false; // Should compress

      final decompressed1 = decompress(result1.compressed, config: config);
      if (decompressed1 == null) return false; // Should decompress
      if (decompressed1.length != testData1.length) return false;

      // Test 2: Skip compression for small data
      final testData2 = Uint8List.fromList([1, 2, 3, 4, 5]); // 5 bytes
      final result2 = compress(testData2, config: config);
      if (result2 != null) return false; // Should NOT compress (too small)

      // Test 3: Skip compression for high-entropy data
      final testData3 = Uint8List.fromList(
        List<int>.generate(256, (i) => i), // 0-255
      );
      final result3 = compress(testData3, config: config);
      if (result3 != null) return false; // Should NOT compress (high entropy)

      // All tests passed
      return true;
    } catch (e) {
      return false;
    }
  }
}
