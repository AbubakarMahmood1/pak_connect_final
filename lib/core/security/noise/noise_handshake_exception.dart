/// Noise handshake exception with detailed error information
/// 
/// Helps distinguish between different failure modes:
/// - Cryptographic failures (downgrade safe)
/// - Network/timeout failures (retry with same pattern)
/// - Protocol errors (downgrade safe)
library;

/// Handshake failure reason
enum HandshakeFailureReason {
  /// Timeout - network/device issue (DO NOT DOWNGRADE)
  timeout,
  
  /// Peer doesn't have our static key (SAFE TO DOWNGRADE)
  peerMissingKey,
  
  /// Cryptographic verification failed (SAFE TO DOWNGRADE)
  cryptoFailure,
  
  /// Peer explicitly rejected pattern (SAFE TO DOWNGRADE)
  patternRejected,
  
  /// Network disconnection (DO NOT DOWNGRADE)
  networkError,
  
  /// Unknown error (DO NOT DOWNGRADE)
  unknown,
}

/// Exception thrown during Noise handshake
class NoiseHandshakeException implements Exception {
  final String message;
  final HandshakeFailureReason reason;
  final Exception? cause;
  
  /// Whether it's safe to downgrade security level
  /// 
  /// Only true for explicit cryptographic/protocol failures.
  /// False for timeouts/network issues (could be attacker jamming).
  bool get safeToDowngrade {
    switch (reason) {
      case HandshakeFailureReason.peerMissingKey:
      case HandshakeFailureReason.cryptoFailure:
      case HandshakeFailureReason.patternRejected:
        return true;
        
      case HandshakeFailureReason.timeout:
      case HandshakeFailureReason.networkError:
      case HandshakeFailureReason.unknown:
        return false;
    }
  }
  
  /// Whether handshake should be retried with fallback pattern
  /// 
  /// True if peer explicitly can't do KK (missing key, crypto failure).
  /// False for transient errors (timeout, network).
  bool get shouldFallbackToXX {
    return safeToDowngrade;
  }
  
  NoiseHandshakeException(
    this.message, {
    this.reason = HandshakeFailureReason.unknown,
    this.cause,
  });
  
  @override
  String toString() {
    final causeStr = cause != null ? ' (cause: $cause)' : '';
    return 'NoiseHandshakeException: $message [reason: ${reason.name}, safeToDowngrade: $safeToDowngrade]$causeStr';
  }
}
