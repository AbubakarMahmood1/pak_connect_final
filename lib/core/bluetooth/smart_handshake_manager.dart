/// Smart handshake manager with KK pattern and conservative fallback
///
/// Handles reconnections with known contacts using KK pattern,
/// with secure fallback to XX only on explicit cryptographic failures.
///
/// Security principle: Never downgrade on timeout/network errors.
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_repository_provider.dart';
import '../services/security_manager.dart';
import '../security/noise/noise.dart';

/// Result of handshake initiation
class HandshakeInitiationResult {
  final Uint8List message;
  final NoisePattern patternUsed;
  final bool isRetry;

  HandshakeInitiationResult({
    required this.message,
    required this.patternUsed,
    this.isRetry = false,
  });
}

/// Smart handshake manager with pattern selection and fallback
class SmartHandshakeManager {
  static final _logger = Logger('SmartHandshakeManager');

  final IRepositoryProvider _repositoryProvider;
  final NoiseEncryptionService _noiseService;

  /// Track KK failures for each peer (don't retry KK immediately)
  final Map<String, int> _kkFailureCount = {};

  /// Track last KK attempt time (rate limit retries)
  final Map<String, DateTime> _lastKKAttempt = {};

  /// Maximum KK failures before giving up and using XX
  static const int _maxKKFailures = 3;

  /// Minimum time between KK retry attempts
  static const Duration _kkRetryDelay = Duration(hours: 1);

  SmartHandshakeManager({
    IRepositoryProvider? repositoryProvider,
    required NoiseEncryptionService noiseService,
  }) : _repositoryProvider =
           repositoryProvider ?? GetIt.instance<IRepositoryProvider>(),
       _noiseService = noiseService;

  /// Initiate handshake with peer (smart pattern selection)
  ///
  /// Returns handshake message and pattern used.
  ///
  /// Pattern selection:
  /// - Always XX for first-time contacts (LOW security)
  /// - Try KK for known contacts (MEDIUM/HIGH) if:
  ///   - Have their static key
  ///   - Haven't failed KK too many times
  ///   - Enough time since last failure
  /// - Fallback to XX if KK not suitable
  Future<HandshakeInitiationResult> initiateHandshake(String peerID) async {
    _logger.info('🤝 Initiating handshake with $peerID');

    // Get pattern selection from SecurityManager
    final (pattern, remoteStaticKey) = await SecurityManager.selectNoisePattern(
      peerID,
    );

    // Check if we should skip KK due to previous failures
    if (pattern == NoisePattern.kk && _shouldSkipKK(peerID)) {
      _logger.warning(
        '⚠️ Skipping KK for $peerID due to previous failures, using XX',
      );
      return await _initiateWithPattern(peerID, NoisePattern.xx, null);
    }

    // Attempt handshake with selected pattern
    return await _initiateWithPattern(peerID, pattern, remoteStaticKey);
  }

  /// Initiate handshake with specific pattern
  Future<HandshakeInitiationResult> _initiateWithPattern(
    String peerID,
    NoisePattern pattern,
    Uint8List? remoteStaticKey,
  ) async {
    try {
      final message = await _noiseService.initiateHandshake(
        peerID,
        pattern: pattern,
        remoteStaticPublicKey: remoteStaticKey,
      );

      if (message == null) {
        throw Exception('Failed to generate handshake message');
      }

      // Track KK attempt
      if (pattern == NoisePattern.kk) {
        _lastKKAttempt[peerID] = DateTime.now();
      }

      _logger.info(
        '✅ Initiated ${pattern.name.toUpperCase()} handshake with $peerID',
      );

      return HandshakeInitiationResult(message: message, patternUsed: pattern);
    } catch (e) {
      _logger.severe(
        '❌ Failed to initiate ${pattern.name.toUpperCase()} handshake: $e',
      );
      rethrow;
    }
  }

  /// Handle handshake failure and determine if fallback needed
  ///
  /// Returns true if should retry with XX, false otherwise.
  ///
  /// CRITICAL: Only returns true for EXPLICIT cryptographic failures.
  /// Timeouts/network errors return false (do NOT fallback).
  Future<bool> handleHandshakeFailure(
    String peerID,
    NoisePattern attemptedPattern,
    Exception error,
  ) async {
    _logger.warning('⚠️ Handshake failure with $peerID: $error');

    // Only handle KK failures (XX failures are fatal)
    if (attemptedPattern != NoisePattern.kk) {
      _logger.severe('❌ XX handshake failed - no fallback available');
      return false;
    }

    // Check if this is a NoiseHandshakeException with detailed reason
    if (error is NoiseHandshakeException) {
      _logger.info('🔍 Handshake failure reason: ${error.reason.name}');
      _logger.info('🔍 Safe to downgrade: ${error.safeToDowngrade}');
      _logger.info('🔍 Should fallback to XX: ${error.shouldFallbackToXX}');

      if (error.shouldFallbackToXX) {
        // EXPLICIT crypto failure - safe to fallback
        _logger.warning('🔄 KK handshake crypto failure - will retry with XX');
        _kkFailureCount[peerID] = (_kkFailureCount[peerID] ?? 0) + 1;

        // If too many failures, consider downgrading security level
        if (_kkFailureCount[peerID]! >= _maxKKFailures) {
          _logger.warning(
            '⬇️ Too many KK failures (${_kkFailureCount[peerID]}) - contact may have reset device',
          );
          await _considerDowngrade(peerID);
        }

        return true; // Retry with XX
      } else {
        // Timeout or network error - DO NOT fallback
        _logger.info(
          '⏸️ KK handshake failed due to timeout/network - will retry KK later',
        );
        return false; // Do NOT retry with XX
      }
    }

    // Unknown error type - assume transient (DO NOT fallback)
    _logger.warning(
      '⚠️ Unknown handshake error type - assuming transient, no fallback',
    );
    return false;
  }

  /// Check if we should skip KK pattern for this peer
  bool _shouldSkipKK(String peerID) {
    final failureCount = _kkFailureCount[peerID] ?? 0;

    // Too many failures - skip KK permanently
    if (failureCount >= _maxKKFailures) {
      return true;
    }

    // Recent failure - wait for retry delay
    final lastAttempt = _lastKKAttempt[peerID];
    if (lastAttempt != null) {
      final timeSinceAttempt = DateTime.now().difference(lastAttempt);
      if (timeSinceAttempt < _kkRetryDelay) {
        return true;
      }
    }

    return false;
  }

  /// Consider downgrading contact security level after repeated KK failures
  Future<void> _considerDowngrade(String peerID) async {
    final contact = await _repositoryProvider.contactRepository.getContact(
      peerID,
    );
    if (contact == null) return;

    // Only downgrade MEDIUM/HIGH to LOW (they may have reset device)
    if (contact.securityLevel != SecurityLevel.low) {
      _logger.warning(
        '⬇️ Downgrading $peerID from ${contact.securityLevel.name} to LOW',
      );
      _logger.warning(
        '   Reason: Repeated KK handshake failures suggest peer reset device',
      );

      await _repositoryProvider.contactRepository.updateContactSecurityLevel(
        peerID,
        SecurityLevel.low,
      );

      // Clear their static key (it's invalid)
      // Note: This would require a method in ContactRepository
      // await _repositoryProvider.contactRepository.clearNoiseStaticKey(peerID);
    }
  }

  /// Reset failure tracking for peer (call after successful handshake)
  void markHandshakeSuccess(String peerID, NoisePattern pattern) {
    _kkFailureCount.remove(peerID);
    _lastKKAttempt.remove(peerID);
    _logger.info(
      '✅ Handshake success with $peerID using ${pattern.name.toUpperCase()}',
    );
  }

  /// Clear all failure tracking (for testing or reset)
  void clearFailureTracking() {
    _kkFailureCount.clear();
    _lastKKAttempt.clear();
  }
}
