/// In-app performance monitoring for encryption operations
///
/// Tracks encryption/decryption times to help make data-driven decisions
/// about FIX-013 (encryption isolate). Displays metrics in settings screen.
///
/// Metrics tracked:
/// - Encryption time (avg, min, max)
/// - Decryption time (avg, min, max)
/// - Message sizes
/// - Sample count
/// - Device info
library;

import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

/// Performance metrics for encryption operations
class EncryptionMetrics {
  final int totalEncryptions;
  final int totalDecryptions;

  // Encryption stats (milliseconds)
  final double avgEncryptMs;
  final int minEncryptMs;
  final int maxEncryptMs;

  // Decryption stats (milliseconds)
  final double avgDecryptMs;
  final int minDecryptMs;
  final int maxDecryptMs;

  // Message size stats (bytes)
  final double avgMessageSize;
  final int minMessageSize;
  final int maxMessageSize;

  // UI jank detection
  final int jankyEncryptions; // Count of operations >16ms
  final double jankPercentage; // % of operations that caused jank

  // Device info
  final String devicePlatform;
  final String deviceModel;

  // Recommendation
  final bool shouldUseIsolate; // true if >5% operations are janky

  EncryptionMetrics({
    required this.totalEncryptions,
    required this.totalDecryptions,
    required this.avgEncryptMs,
    required this.minEncryptMs,
    required this.maxEncryptMs,
    required this.avgDecryptMs,
    required this.minDecryptMs,
    required this.maxDecryptMs,
    required this.avgMessageSize,
    required this.minMessageSize,
    required this.maxMessageSize,
    required this.jankyEncryptions,
    required this.jankPercentage,
    required this.devicePlatform,
    required this.deviceModel,
    required this.shouldUseIsolate,
  });

  /// Create empty metrics
  factory EncryptionMetrics.empty() {
    return EncryptionMetrics(
      totalEncryptions: 0,
      totalDecryptions: 0,
      avgEncryptMs: 0,
      minEncryptMs: 0,
      maxEncryptMs: 0,
      avgDecryptMs: 0,
      minDecryptMs: 0,
      maxDecryptMs: 0,
      avgMessageSize: 0,
      minMessageSize: 0,
      maxMessageSize: 0,
      jankyEncryptions: 0,
      jankPercentage: 0,
      devicePlatform: Platform.operatingSystem,
      deviceModel: 'Unknown',
      shouldUseIsolate: false,
    );
  }

  @override
  String toString() {
    return 'EncryptionMetrics('
        'encryptions: $totalEncryptions, '
        'decryptions: $totalDecryptions, '
        'avgEncrypt: ${avgEncryptMs.toStringAsFixed(2)}ms, '
        'maxEncrypt: ${maxEncryptMs}ms, '
        'jank: ${jankPercentage.toStringAsFixed(1)}%, '
        'useIsolate: $shouldUseIsolate)';
  }
}

/// Collects and stores encryption performance metrics
class PerformanceMonitor {
  static final _logger = Logger('PerformanceMonitor');
  static const String _keyPrefix = 'perf_metrics_';

  // SharedPreferences keys
  static const String _keyTotalEncryptions = '${_keyPrefix}total_encryptions';
  static const String _keyTotalDecryptions = '${_keyPrefix}total_decryptions';
  static const String _keyEncryptTimes = '${_keyPrefix}encrypt_times';
  static const String _keyDecryptTimes = '${_keyPrefix}decrypt_times';
  static const String _keyMessageSizes = '${_keyPrefix}message_sizes';
  static const String _keyJankyCount = '${_keyPrefix}janky_count';

  // Performance thresholds
  static const int _jankThresholdMs = 16; // One frame @ 60fps
  static const double _isolateThresholdPercent = 5.0; // 5% jank = use isolate
  static const int _maxSamplesStored = 1000; // Keep last 1000 samples

  /// Record an encryption operation
  static Future<void> recordEncryption({
    required int durationMs,
    required int messageSize,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Increment total count
      final total = (prefs.getInt(_keyTotalEncryptions) ?? 0) + 1;
      await prefs.setInt(_keyTotalEncryptions, total);

      // Append to times list (keep last N samples)
      final times = prefs.getStringList(_keyEncryptTimes) ?? [];
      times.add(durationMs.toString());
      if (times.length > _maxSamplesStored) {
        times.removeAt(0); // Remove oldest
      }
      await prefs.setStringList(_keyEncryptTimes, times);

      // Append to sizes list
      final sizes = prefs.getStringList(_keyMessageSizes) ?? [];
      sizes.add(messageSize.toString());
      if (sizes.length > _maxSamplesStored) {
        sizes.removeAt(0);
      }
      await prefs.setStringList(_keyMessageSizes, sizes);

      // Track jank
      if (durationMs > _jankThresholdMs) {
        final janky = (prefs.getInt(_keyJankyCount) ?? 0) + 1;
        await prefs.setInt(_keyJankyCount, janky);

        _logger.fine(
          'Janky encryption detected: ${durationMs}ms (size: ${messageSize}B)',
        );
      }

      _logger.fine('Recorded encryption: ${durationMs}ms, ${messageSize}B');
    } catch (e) {
      _logger.severe('Failed to record encryption metrics: $e');
    }
  }

  /// Record a decryption operation
  static Future<void> recordDecryption({
    required int durationMs,
    required int messageSize,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Increment total count
      final total = (prefs.getInt(_keyTotalDecryptions) ?? 0) + 1;
      await prefs.setInt(_keyTotalDecryptions, total);

      // Append to times list
      final times = prefs.getStringList(_keyDecryptTimes) ?? [];
      times.add(durationMs.toString());
      if (times.length > _maxSamplesStored) {
        times.removeAt(0);
      }
      await prefs.setStringList(_keyDecryptTimes, times);

      // Track jank (decryption also blocks UI)
      if (durationMs > _jankThresholdMs) {
        final janky = (prefs.getInt(_keyJankyCount) ?? 0) + 1;
        await prefs.setInt(_keyJankyCount, janky);

        _logger.fine(
          'Janky decryption detected: ${durationMs}ms (size: ${messageSize}B)',
        );
      }

      _logger.fine('Recorded decryption: ${durationMs}ms, ${messageSize}B');
    } catch (e) {
      _logger.severe('Failed to record decryption metrics: $e');
    }
  }

  /// Get aggregated metrics
  static Future<EncryptionMetrics> getMetrics() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final totalEncryptions = prefs.getInt(_keyTotalEncryptions) ?? 0;
      final totalDecryptions = prefs.getInt(_keyTotalDecryptions) ?? 0;

      if (totalEncryptions == 0 && totalDecryptions == 0) {
        return EncryptionMetrics.empty();
      }

      // Parse encryption times
      final encryptTimes = (prefs.getStringList(_keyEncryptTimes) ?? [])
          .map((s) => int.tryParse(s) ?? 0)
          .where((v) => v > 0)
          .toList();

      // Parse decryption times
      final decryptTimes = (prefs.getStringList(_keyDecryptTimes) ?? [])
          .map((s) => int.tryParse(s) ?? 0)
          .where((v) => v > 0)
          .toList();

      // Parse message sizes
      final messageSizes = (prefs.getStringList(_keyMessageSizes) ?? [])
          .map((s) => int.tryParse(s) ?? 0)
          .where((v) => v > 0)
          .toList();

      final jankyCount = prefs.getInt(_keyJankyCount) ?? 0;

      // Calculate encryption stats
      final avgEncryptMs = encryptTimes.isEmpty
          ? 0.0
          : encryptTimes.reduce((a, b) => a + b) / encryptTimes.length;
      final minEncryptMs = encryptTimes.isEmpty
          ? 0
          : encryptTimes.reduce((a, b) => a < b ? a : b);
      final maxEncryptMs = encryptTimes.isEmpty
          ? 0
          : encryptTimes.reduce((a, b) => a > b ? a : b);

      // Calculate decryption stats
      final avgDecryptMs = decryptTimes.isEmpty
          ? 0.0
          : decryptTimes.reduce((a, b) => a + b) / decryptTimes.length;
      final minDecryptMs = decryptTimes.isEmpty
          ? 0
          : decryptTimes.reduce((a, b) => a < b ? a : b);
      final maxDecryptMs = decryptTimes.isEmpty
          ? 0
          : decryptTimes.reduce((a, b) => a > b ? a : b);

      // Calculate message size stats
      final avgMessageSize = messageSizes.isEmpty
          ? 0.0
          : messageSizes.reduce((a, b) => a + b) / messageSizes.length;
      final minMessageSize = messageSizes.isEmpty
          ? 0
          : messageSizes.reduce((a, b) => a < b ? a : b);
      final maxMessageSize = messageSizes.isEmpty
          ? 0
          : messageSizes.reduce((a, b) => a > b ? a : b);

      // Calculate jank percentage
      final totalOps = totalEncryptions + totalDecryptions;
      final jankPercentage = totalOps > 0 ? (jankyCount / totalOps) * 100 : 0.0;

      // Recommendation: use isolate if >5% operations are janky
      final shouldUseIsolate = jankPercentage > _isolateThresholdPercent;

      return EncryptionMetrics(
        totalEncryptions: totalEncryptions,
        totalDecryptions: totalDecryptions,
        avgEncryptMs: avgEncryptMs,
        minEncryptMs: minEncryptMs,
        maxEncryptMs: maxEncryptMs,
        avgDecryptMs: avgDecryptMs,
        minDecryptMs: minDecryptMs,
        maxDecryptMs: maxDecryptMs,
        avgMessageSize: avgMessageSize,
        minMessageSize: minMessageSize,
        maxMessageSize: maxMessageSize,
        jankyEncryptions: jankyCount,
        jankPercentage: jankPercentage,
        devicePlatform: Platform.operatingSystem,
        deviceModel: _getDeviceModel(),
        shouldUseIsolate: shouldUseIsolate,
      );
    } catch (e) {
      _logger.severe('Failed to get metrics: $e');
      return EncryptionMetrics.empty();
    }
  }

  /// Reset all metrics
  static Future<void> reset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyTotalEncryptions);
      await prefs.remove(_keyTotalDecryptions);
      await prefs.remove(_keyEncryptTimes);
      await prefs.remove(_keyDecryptTimes);
      await prefs.remove(_keyMessageSizes);
      await prefs.remove(_keyJankyCount);

      _logger.info('Performance metrics reset');
    } catch (e) {
      _logger.severe('Failed to reset metrics: $e');
    }
  }

  /// Export metrics as text (for sharing/debugging)
  static Future<String> exportMetrics() async {
    final metrics = await getMetrics();

    final buffer = StringBuffer();
    buffer.writeln('=== PakConnect Performance Metrics ===');
    buffer.writeln('');
    buffer.writeln(
      'Device: ${metrics.devicePlatform} (${metrics.deviceModel})',
    );
    buffer.writeln('');
    buffer.writeln('--- Operations ---');
    buffer.writeln('Total Encryptions: ${metrics.totalEncryptions}');
    buffer.writeln('Total Decryptions: ${metrics.totalDecryptions}');
    buffer.writeln('');
    buffer.writeln('--- Encryption Performance ---');
    buffer.writeln('Average: ${metrics.avgEncryptMs.toStringAsFixed(2)}ms');
    buffer.writeln('Min: ${metrics.minEncryptMs}ms');
    buffer.writeln('Max: ${metrics.maxEncryptMs}ms');
    buffer.writeln('');
    buffer.writeln('--- Decryption Performance ---');
    buffer.writeln('Average: ${metrics.avgDecryptMs.toStringAsFixed(2)}ms');
    buffer.writeln('Min: ${metrics.minDecryptMs}ms');
    buffer.writeln('Max: ${metrics.maxDecryptMs}ms');
    buffer.writeln('');
    buffer.writeln('--- Message Sizes ---');
    buffer.writeln(
      'Average: ${(metrics.avgMessageSize / 1024).toStringAsFixed(2)} KB',
    );
    buffer.writeln('Min: ${metrics.minMessageSize} bytes');
    buffer.writeln(
      'Max: ${(metrics.maxMessageSize / 1024).toStringAsFixed(2)} KB',
    );
    buffer.writeln('');
    buffer.writeln('--- UI Performance ---');
    buffer.writeln(
      'Janky Operations: ${metrics.jankyEncryptions} (>${_jankThresholdMs}ms)',
    );
    buffer.writeln(
      'Jank Percentage: ${metrics.jankPercentage.toStringAsFixed(2)}%',
    );
    buffer.writeln('');
    buffer.writeln('--- Recommendation ---');
    if (metrics.shouldUseIsolate) {
      buffer.writeln(
        '⚠️ USE ISOLATE: ${metrics.jankPercentage.toStringAsFixed(1)}% jank rate exceeds ${_isolateThresholdPercent}% threshold',
      );
      buffer.writeln(
        '   This device would benefit from background encryption (FIX-013)',
      );
    } else {
      buffer.writeln(
        '✅ NO ISOLATE NEEDED: ${metrics.jankPercentage.toStringAsFixed(1)}% jank rate is acceptable',
      );
      buffer.writeln('   Current implementation is fast enough on this device');
    }
    buffer.writeln('');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');

    return buffer.toString();
  }

  /// Get device model (best effort)
  static String _getDeviceModel() {
    // This is a simplified version - would need device_info_plus package for real implementation
    if (Platform.isAndroid) {
      return 'Android Device';
    } else if (Platform.isIOS) {
      return 'iOS Device';
    } else if (Platform.isLinux) {
      return 'Linux';
    } else if (Platform.isWindows) {
      return 'Windows';
    } else if (Platform.isMacOS) {
      return 'macOS';
    }
    return 'Unknown';
  }
}
