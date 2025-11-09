/// Configuration for compression module
///
/// Based on bitchat's proven compression approach using deflate algorithm.
/// Configuration values are derived from real-world testing and optimization.
class CompressionConfig {
  /// Minimum size in bytes for data to be considered for compression
  ///
  /// Data smaller than this threshold will NOT be compressed because:
  /// - Compression overhead (headers, CPU) exceeds potential savings
  /// - Deflate header alone is ~10-20 bytes
  ///
  /// Default: 100 bytes (from bitchat's production testing)
  final int compressionThreshold;

  /// Entropy threshold for determining if data is already compressed
  ///
  /// Entropy is measured as the ratio of unique bytes to total possible bytes (256).
  /// High entropy (e.g., 0.9 = 90% unique bytes) indicates random or already
  /// compressed data that won't benefit from further compression.
  ///
  /// If uniqueByteRatio >= entropyThreshold, compression is skipped.
  ///
  /// Default: 0.9 (from bitchat - skip if >90% unique bytes)
  final double entropyThreshold;

  /// Whether to use raw deflate format (no zlib headers)
  ///
  /// Raw deflate is slightly more efficient (no headers) and matches bitchat's
  /// implementation. The decompressor will fall back to zlib format if needed.
  ///
  /// Default: true (raw deflate, compatible with bitchat)
  final bool useRawDeflate;

  /// Compression level (0-9)
  ///
  /// - 0: No compression (fastest)
  /// - 1-3: Fast compression, lower ratio
  /// - 4-6: Balanced (recommended)
  /// - 7-9: Best compression, slower
  ///
  /// Default: 6 (balanced - good compression with acceptable speed)
  final int compressionLevel;

  /// Whether to enable compression globally
  ///
  /// This is a master switch. If false, all compression operations will be skipped.
  /// Useful for debugging or feature flagging.
  ///
  /// Default: true
  final bool enabled;

  const CompressionConfig({
    this.compressionThreshold = 100,
    this.entropyThreshold = 0.9,
    this.useRawDeflate = true,
    this.compressionLevel = 6,
    this.enabled = true,
  });

  /// Default configuration (optimized for general use)
  static const CompressionConfig defaultConfig = CompressionConfig();

  /// Aggressive compression (prioritizes ratio over speed)
  ///
  /// Use for archives and large data where storage is more important than speed.
  static const CompressionConfig aggressive = CompressionConfig(
    compressionThreshold: 80,
    entropyThreshold: 0.95,
    compressionLevel: 9,
  );

  /// Fast compression (prioritizes speed over ratio)
  ///
  /// Use for real-time operations like BLE transmission where latency matters.
  static const CompressionConfig fast = CompressionConfig(
    compressionThreshold: 120,
    entropyThreshold: 0.85,
    compressionLevel: 3,
  );

  /// Disabled configuration (no compression)
  ///
  /// Use for debugging or when compression is not desired.
  static const CompressionConfig disabled = CompressionConfig(enabled: false);

  /// Create a copy with modified fields
  CompressionConfig copyWith({
    int? compressionThreshold,
    double? entropyThreshold,
    bool? useRawDeflate,
    int? compressionLevel,
    bool? enabled,
  }) {
    return CompressionConfig(
      compressionThreshold: compressionThreshold ?? this.compressionThreshold,
      entropyThreshold: entropyThreshold ?? this.entropyThreshold,
      useRawDeflate: useRawDeflate ?? this.useRawDeflate,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  String toString() {
    return 'CompressionConfig('
        'threshold: $compressionThreshold bytes, '
        'entropyThreshold: $entropyThreshold, '
        'level: $compressionLevel, '
        'rawDeflate: $useRawDeflate, '
        'enabled: $enabled'
        ')';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CompressionConfig &&
        other.compressionThreshold == compressionThreshold &&
        other.entropyThreshold == entropyThreshold &&
        other.useRawDeflate == useRawDeflate &&
        other.compressionLevel == compressionLevel &&
        other.enabled == enabled;
  }

  @override
  int get hashCode {
    return Object.hash(
      compressionThreshold,
      entropyThreshold,
      useRawDeflate,
      compressionLevel,
      enabled,
    );
  }
}
