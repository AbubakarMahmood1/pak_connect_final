/// Statistics for a compression operation
///
/// Tracks compression performance metrics including sizes, ratios, and timing.
/// Used for monitoring, debugging, and optimization.
class CompressionStats {
  /// Original uncompressed size in bytes
  final int originalSize;

  /// Compressed size in bytes (0 if compression was not performed)
  final int compressedSize;

  /// Algorithm used for compression (e.g., 'zlib', 'deflate', 'none')
  final String algorithm;

  /// Time taken to compress in milliseconds (0 if not measured)
  final int compressionTimeMs;

  /// Whether compression was actually performed
  ///
  /// False if:
  /// - Data was too small (below threshold)
  /// - Data had high entropy (already compressed)
  /// - Compression failed
  /// - Compressed size >= original size (not beneficial)
  final bool wasCompressed;

  /// Reason compression was skipped (if wasCompressed is false)
  ///
  /// Examples:
  /// - 'below_threshold': Data size < compressionThreshold
  /// - 'high_entropy': Entropy check indicated already compressed data
  /// - 'not_beneficial': Compressed size >= original size
  /// - 'compression_failed': Compression threw an error
  /// - null: Compression was performed (wasCompressed = true)
  final String? skipReason;

  const CompressionStats({
    required this.originalSize,
    required this.compressedSize,
    required this.algorithm,
    this.compressionTimeMs = 0,
    required this.wasCompressed,
    this.skipReason,
  });

  /// Compression ratio (0.0 to 1.0)
  ///
  /// - 0.0: Perfect compression (impossible)
  /// - 0.3: 70% size reduction (excellent)
  /// - 0.5: 50% size reduction (good)
  /// - 0.7: 30% size reduction (okay)
  /// - 1.0: No compression (original size)
  ///
  /// Returns 1.0 if compression was not performed.
  double get compressionRatio {
    if (!wasCompressed || originalSize == 0) return 1.0;
    return compressedSize / originalSize;
  }

  /// Size savings in bytes (positive if compression helped)
  ///
  /// Returns 0 if compression was not performed.
  int get bytesSaved {
    if (!wasCompressed) return 0;
    return originalSize - compressedSize;
  }

  /// Size savings as percentage (0-100)
  ///
  /// - 30.0: 30% reduction
  /// - 50.0: 50% reduction
  /// - 70.0: 70% reduction
  ///
  /// Returns 0 if compression was not performed.
  double get savingsPercent {
    if (!wasCompressed || originalSize == 0) return 0.0;
    return (bytesSaved / originalSize) * 100;
  }

  /// Whether compression was beneficial (saved space)
  bool get wasBeneficial {
    return wasCompressed && compressedSize < originalSize;
  }

  /// Create stats for uncompressed data
  factory CompressionStats.notCompressed({
    required int originalSize,
    required String skipReason,
  }) {
    return CompressionStats(
      originalSize: originalSize,
      compressedSize: originalSize,
      algorithm: 'none',
      wasCompressed: false,
      skipReason: skipReason,
    );
  }

  /// Create stats for successful compression
  factory CompressionStats.compressed({
    required int originalSize,
    required int compressedSize,
    required String algorithm,
    int compressionTimeMs = 0,
  }) {
    return CompressionStats(
      originalSize: originalSize,
      compressedSize: compressedSize,
      algorithm: algorithm,
      compressionTimeMs: compressionTimeMs,
      wasCompressed: true,
      skipReason: null,
    );
  }

  /// Create a copy with modified fields
  CompressionStats copyWith({
    int? originalSize,
    int? compressedSize,
    String? algorithm,
    int? compressionTimeMs,
    bool? wasCompressed,
    String? skipReason,
  }) {
    return CompressionStats(
      originalSize: originalSize ?? this.originalSize,
      compressedSize: compressedSize ?? this.compressedSize,
      algorithm: algorithm ?? this.algorithm,
      compressionTimeMs: compressionTimeMs ?? this.compressionTimeMs,
      wasCompressed: wasCompressed ?? this.wasCompressed,
      skipReason: skipReason ?? this.skipReason,
    );
  }

  @override
  String toString() {
    if (!wasCompressed) {
      return 'CompressionStats(original: $originalSize bytes, '
          'not compressed: $skipReason)';
    }
    return 'CompressionStats(original: $originalSize bytes, '
        'compressed: $compressedSize bytes, '
        'ratio: ${(compressionRatio * 100).toStringAsFixed(1)}%, '
        'saved: $bytesSaved bytes (${savingsPercent.toStringAsFixed(1)}%), '
        'algorithm: $algorithm, '
        'time: ${compressionTimeMs}ms)';
  }

  /// Convert to JSON for storage or transmission
  Map<String, dynamic> toJson() {
    return {
      'originalSize': originalSize,
      'compressedSize': compressedSize,
      'algorithm': algorithm,
      'compressionTimeMs': compressionTimeMs,
      'wasCompressed': wasCompressed,
      'skipReason': skipReason,
      'compressionRatio': compressionRatio,
      'bytesSaved': bytesSaved,
      'savingsPercent': savingsPercent,
    };
  }

  /// Create from JSON
  factory CompressionStats.fromJson(Map<String, dynamic> json) {
    return CompressionStats(
      originalSize: json['originalSize'] as int,
      compressedSize: json['compressedSize'] as int,
      algorithm: json['algorithm'] as String,
      compressionTimeMs: json['compressionTimeMs'] as int? ?? 0,
      wasCompressed: json['wasCompressed'] as bool,
      skipReason: json['skipReason'] as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CompressionStats &&
        other.originalSize == originalSize &&
        other.compressedSize == compressedSize &&
        other.algorithm == algorithm &&
        other.compressionTimeMs == compressionTimeMs &&
        other.wasCompressed == wasCompressed &&
        other.skipReason == skipReason;
  }

  @override
  int get hashCode {
    return Object.hash(
      originalSize,
      compressedSize,
      algorithm,
      compressionTimeMs,
      wasCompressed,
      skipReason,
    );
  }
}
