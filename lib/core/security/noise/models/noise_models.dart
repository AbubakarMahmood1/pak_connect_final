/// Data models for Noise Protocol implementation
/// 
/// Additional models can be added here as needed.
library;

import 'dart:typed_data';

/// Noise Protocol handshake patterns
/// 
/// Each pattern defines different security properties and message flows.
enum NoisePattern {
  /// XX pattern: 3-message mutual authentication
  /// → e, ← e ee s es, → s se
  /// Use for: First-time contacts (SecurityLevel.low)
  xx,
  
  /// KK pattern: 2-message mutual authentication with pre-shared keys
  /// → e es ss, ← e ee se
  /// Use for: Known contacts (SecurityLevel.medium, SecurityLevel.high)
  kk,
}

/// Noise session information
class NoiseSessionInfo {
  final String peerID;
  final String fingerprint;
  final Uint8List publicKey;
  final DateTime establishedAt;
  
  NoiseSessionInfo({
    required this.peerID,
    required this.fingerprint,
    required this.publicKey,
    required this.establishedAt,
  });
  
  Map<String, dynamic> toJson() => {
    'peerID': peerID,
    'fingerprint': fingerprint,
    'establishedAt': establishedAt.toIso8601String(),
  };
}

/// Handshake message wrapper
class NoiseHandshakeMessage {
  final Uint8List data;
  final int messageIndex;
  final String peerID;
  
  NoiseHandshakeMessage({
    required this.data,
    required this.messageIndex,
    required this.peerID,
  });
}
