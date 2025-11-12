/// Adaptive encryption strategy that switches between sync and isolate-based encryption
///
/// Based on real-world performance metrics, decides whether to offload encryption
/// to background isolates. Starts with sync (fast path), switches to isolate only
/// if metrics show device is slow.
library;

import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import '../../monitoring/performance_metrics.dart';
import 'encryption_isolate.dart';

/// Strategy for adaptive encryption based on device performance
class AdaptiveEncryptionStrategy {
  static final _logger = Logger('AdaptiveEncryptionStrategy');

  /// Cached decision: should we use isolate?
  bool _useIsolate = false;

  /// Operations counter for periodic re-evaluation
  int _operationsSinceLastCheck = 0;

  /// Re-check metrics every N operations
  static const int _recheckInterval = 100;

  /// Minimum message size to consider isolate (bytes)
  /// Small messages (<1KB) stay on main thread (isolate overhead > encryption time)
  static const int _minMessageSizeForIsolate = 1024;

  /// SharedPreferences key for persisting decision
  static const String _keyUseIsolate = 'adaptive_encryption_use_isolate';

  /// Debug override (null = use metrics, true/false = force mode)
  bool? _debugOverride;

  /// Singleton instance
  static final AdaptiveEncryptionStrategy _instance =
      AdaptiveEncryptionStrategy._internal();
  factory AdaptiveEncryptionStrategy() => _instance;
  AdaptiveEncryptionStrategy._internal();

  /// Initialize strategy
  ///
  /// Loads cached decision from SharedPreferences, then checks metrics.
  /// Call this once at app startup.
  Future<void> initialize() async {
    _logger.info('Initializing adaptive encryption strategy');

    // Load cached decision from previous session
    final prefs = await SharedPreferences.getInstance();
    _useIsolate = prefs.getBool(_keyUseIsolate) ?? false;

    _logger.info('Cached decision: useIsolate = $_useIsolate');

    // Check current metrics
    await _checkMetrics();

    _logger.info(
      'Adaptive encryption strategy initialized: useIsolate = $_useIsolate',
    );
  }

  /// Check performance metrics and update decision
  Future<void> _checkMetrics() async {
    try {
      final metrics = await PerformanceMonitor.getMetrics();

      // Decision logic:
      // 1. If no data yet (<10 samples), stay sync (default)
      // 2. If metrics show jank, switch to isolate
      // 3. If metrics show good performance, switch to sync

      if (metrics.totalEncryptions + metrics.totalDecryptions < 10) {
        _logger.info(
          'Insufficient data (${metrics.totalEncryptions + metrics.totalDecryptions} ops), staying sync',
        );
        _useIsolate = false;
      } else {
        final shouldUse = metrics.shouldUseIsolate;

        if (shouldUse != _useIsolate) {
          _logger.warning(
            '🔄 Switching encryption mode: $_useIsolate -> $shouldUse '
            '(jank: ${metrics.jankPercentage.toStringAsFixed(1)}%, '
            'avg: ${metrics.avgEncryptMs.toStringAsFixed(1)}ms)',
          );
          _useIsolate = shouldUse;

          // Persist decision
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_keyUseIsolate, _useIsolate);
        } else {
          _logger.fine(
            'Metrics check: no change needed (useIsolate = $_useIsolate)',
          );
        }
      }
    } catch (e) {
      _logger.severe('Failed to check metrics: $e');
      // On error, stay with current decision
    }
  }

  /// Encrypt data with adaptive strategy
  ///
  /// Decides whether to use isolate or sync path based on:
  /// 1. Message size (small messages always sync)
  /// 2. Device performance (from metrics)
  /// 3. Debug override (if set)
  ///
  /// [plaintext] Data to encrypt
  /// [key] 32-byte ChaCha20 key
  /// [nonce] Current nonce value
  /// [associatedData] Additional authenticated data (AAD)
  /// [syncEncrypt] Fallback sync encryption function
  Future<Uint8List> encrypt({
    required Uint8List plaintext,
    required Uint8List key,
    required int nonce,
    Uint8List? associatedData,
    required Future<Uint8List> Function() syncEncrypt,
  }) async {
    // Periodic metrics re-check
    _operationsSinceLastCheck++;
    if (_operationsSinceLastCheck >= _recheckInterval) {
      _operationsSinceLastCheck = 0;
      await _checkMetrics();
    }

    // Decision logic
    final shouldUseIsolate = _shouldUseIsolate(plaintext.length);

    if (shouldUseIsolate) {
      _logger.fine(
        '🔄 Using isolate for encryption (${plaintext.length} bytes)',
      );

      final task = EncryptionTask(
        plaintext: plaintext,
        key: key,
        nonce: nonce,
        associatedData: associatedData,
      );

      return await compute(encryptInIsolate, task);
    } else {
      _logger.fine('⚡ Using sync encryption (${plaintext.length} bytes)');
      return await syncEncrypt();
    }
  }

  /// Decrypt data with adaptive strategy
  ///
  /// Same logic as encrypt().
  ///
  /// [ciphertext] Encrypted data with MAC
  /// [key] 32-byte ChaCha20 key
  /// [nonce] Current nonce value
  /// [associatedData] Additional authenticated data (AAD)
  /// [syncDecrypt] Fallback sync decryption function
  Future<Uint8List> decrypt({
    required Uint8List ciphertext,
    required Uint8List key,
    required int nonce,
    Uint8List? associatedData,
    required Future<Uint8List> Function() syncDecrypt,
  }) async {
    // Periodic metrics re-check
    _operationsSinceLastCheck++;
    if (_operationsSinceLastCheck >= _recheckInterval) {
      _operationsSinceLastCheck = 0;
      await _checkMetrics();
    }

    // Decision logic
    final shouldUseIsolate = _shouldUseIsolate(ciphertext.length);

    if (shouldUseIsolate) {
      _logger.fine(
        '🔄 Using isolate for decryption (${ciphertext.length} bytes)',
      );

      final task = DecryptionTask(
        ciphertext: ciphertext,
        key: key,
        nonce: nonce,
        associatedData: associatedData,
      );

      return await compute(decryptInIsolate, task);
    } else {
      _logger.fine('⚡ Using sync decryption (${ciphertext.length} bytes)');
      return await syncDecrypt();
    }
  }

  /// Determine if isolate should be used for this operation
  bool _shouldUseIsolate(int messageSize) {
    // Debug override takes precedence
    if (_debugOverride != null) {
      return _debugOverride!;
    }

    // Small messages: always sync (isolate overhead > encryption time)
    if (messageSize < _minMessageSizeForIsolate) {
      return false;
    }

    // Large messages: use cached decision from metrics
    return _useIsolate;
  }

  /// Set debug override
  ///
  /// For testing both code paths:
  /// - null: use metrics-based decision (default)
  /// - true: force isolate mode
  /// - false: force sync mode
  void setDebugOverride(bool? useIsolate) {
    _debugOverride = useIsolate;
    _logger.warning(
      'Debug override set: ${useIsolate == null
          ? "disabled (using metrics)"
          : useIsolate
          ? "FORCE ISOLATE"
          : "FORCE SYNC"}',
    );
  }

  /// Get current decision
  ///
  /// Returns true if currently using isolate mode.
  bool get isUsingIsolate => _debugOverride ?? _useIsolate;

  /// Force metrics re-check
  ///
  /// Useful for testing or after manual metrics reset.
  Future<void> recheckMetrics() async {
    _logger.info('Manual metrics recheck requested');
    await _checkMetrics();
  }
}
