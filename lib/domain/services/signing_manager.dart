import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/models/security_level.dart';

class SigningManager {
  static final _logger = Logger('SigningManager');

  /// Sign message with appropriate key based on trust level
  static String? signMessage(String content, SecurityLevel trustLevel) {
    switch (trustLevel) {
      case SecurityLevel.low:
        return _signWithEphemeralKey(content);
      case SecurityLevel.medium:
      case SecurityLevel.high:
        return SimpleCrypto.signMessage(content); // Real key
    }
  }

  /// Sign with ephemeral private key
  static String? _signWithEphemeralKey(String content) {
    final ephemeralPrivateKey = EphemeralKeyManager.ephemeralSigningPrivateKey;
    if (ephemeralPrivateKey == null) {
      if (kDebugMode) {
        _logger.warning(
          '🔴 EPHEMERAL SIGN FAIL: No ephemeral private key available',
        );
      }
      return null;
    }

    try {
      // Parse ephemeral private key
      final privateKeyInt = BigInt.parse(ephemeralPrivateKey, radix: 16);
      final ecPrivateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());

      // Create signer
      final signer = ECDSASigner(SHA256Digest());
      final secureRandom = FortunaRandom();

      // Seed random with cryptographically secure randomness
      final random = Random.secure();
      final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      secureRandom.seed(KeyParameter(seed));

      // Initialize signer
      final privateKeyParam = PrivateKeyParameter(ecPrivateKey);
      final params = ParametersWithRandom(privateKeyParam, secureRandom);
      signer.init(true, params);

      // Sign message
      final messageBytes = utf8.encode(content);
      final signature = signer.generateSignature(messageBytes) as ECSignature;

      // Encode signature
      final rHex = signature.r.toRadixString(16);
      final sHex = signature.s.toRadixString(16);

      return '$rHex:$sHex';
    } catch (e) {
      if (kDebugMode) {
        _logger.warning('🔴 EPHEMERAL SIGN FAIL: $e');
      }
      return null;
    }
  }

  /// Verify signature with appropriate key
  static bool verifySignature(
    String content,
    String signatureHex,
    String verifyingKey,
    bool isEphemeralSigning,
  ) {
    if (isEphemeralSigning) {
      return _verifyEphemeralSignature(content, signatureHex, verifyingKey);
    } else {
      return SimpleCrypto.verifySignature(content, signatureHex, verifyingKey);
    }
  }

  /// Verify ephemeral signature
  static bool _verifyEphemeralSignature(
    String content,
    String signatureHex,
    String ephemeralPublicKey,
  ) {
    try {
      // Parse ephemeral public key
      final publicKeyBytes = _hexToBytes(ephemeralPublicKey);
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(publicKeyBytes);
      final publicKey = ECPublicKey(point, curve);

      // Parse signature
      final sigParts = signatureHex.split(':');
      final r = BigInt.parse(sigParts[0], radix: 16);
      final s = BigInt.parse(sigParts[1], radix: 16);
      final signature = ECSignature(r, s);

      // Create verifier
      final verifier = ECDSASigner(SHA256Digest());
      verifier.init(false, PublicKeyParameter(publicKey));

      final messageBytes = utf8.encode(content);
      return verifier.verifySignature(messageBytes, signature);
    } catch (e) {
      if (kDebugMode) {
        _logger.warning('Ephemeral signature verification failed: $e');
      }
      return false;
    }
  }

  static Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(result);
  }

  /// Produces the exact bytestring that should be signed/verified for a message.
  ///
  /// v2+ binds envelope metadata and payload content using a canonical JSON form.
  /// v1 preserves legacy behavior by signing just plaintext content.
  static String signaturePayloadForMessage(
    ProtocolMessage message, {
    String? fallbackContent,
  }) {
    if (message.version >= 2 &&
        message.type == ProtocolMessageType.textMessage) {
      final payload = message.payload;
      final signingEnvelope = <String, dynamic>{
        'version': message.version,
        'type': message.type.name,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
        'messageId': payload['messageId'],
        'senderId': payload['senderId'],
        'originalSender': payload['originalSender'],
        'recipientId': payload['recipientId'],
        'intendedRecipient': payload['intendedRecipient'],
        'encrypted': payload['encrypted'],
        'useEphemeralAddressing': payload['useEphemeralAddressing'],
        'content': payload['content'],
        'crypto': payload['crypto'],
      };
      return _canonicalJsonEncode(signingEnvelope);
    }
    return fallbackContent ?? message.textContent ?? '';
  }

  static String _canonicalJsonEncode(Object? value) {
    return jsonEncode(_canonicalize(value));
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keyed = <String, Object?>{};
      for (final entry in value.entries) {
        keyed[entry.key.toString()] = _canonicalize(entry.value);
      }
      final keys = keyed.keys.toList()..sort();
      final sorted = <String, Object?>{};
      for (final key in keys) {
        sorted[key] = keyed[key];
      }
      return sorted;
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    if (value is num || value is bool || value is String || value == null) {
      return value;
    }
    return value.toString();
  }

  /// Get signing info for message
  static MessageSigningInfo getSigningInfo(SecurityLevel trustLevel) {
    final useEphemeral = trustLevel == SecurityLevel.low;

    return MessageSigningInfo(
      useEphemeralSigning: useEphemeral,
      signingKey: useEphemeral
          ? EphemeralKeyManager.ephemeralSigningPublicKey
          : null, // Real key comes from identity exchange
    );
  }
}

class MessageSigningInfo {
  final bool useEphemeralSigning;
  final String? signingKey; // Only set for ephemeral

  MessageSigningInfo({required this.useEphemeralSigning, this.signingKey});
}
