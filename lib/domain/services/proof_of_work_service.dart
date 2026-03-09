// Hashcash-style proof-of-work for progressive spam throttling.
// Messages include a PoW solution whose difficulty scales with sender volume.
// Relay nodes verify in O(1) (single SHA-256 check).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

/// Result of a successful proof-of-work computation.
class ProofOfWorkResult {
  /// The nonce that satisfies the difficulty requirement.
  final int nonce;

  /// The number of SHA-256 iterations needed to find the solution.
  final int iterations;

  /// The resulting hash (hex-encoded) for verification.
  final String hash;

  const ProofOfWorkResult({
    required this.nonce,
    required this.iterations,
    required this.hash,
  });

  @override
  String toString() =>
      'PoW(nonce=$nonce, iterations=$iterations, difficulty=${_leadingZeroBits(hash)})';

  static int _leadingZeroBits(String hexHash) {
    final bytes = _hexToBytes(hexHash);
    int bits = 0;
    for (final byte in bytes) {
      if (byte == 0) {
        bits += 8;
      } else {
        // Count leading zero bits in this byte
        for (int mask = 0x80; mask > 0; mask >>= 1) {
          if ((byte & mask) == 0) {
            bits++;
          } else {
            return bits;
          }
        }
      }
    }
    return bits;
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// Hashcash-style proof-of-work service.
///
/// The sender finds a nonce such that `SHA-256(challenge || nonce)` has at
/// least [difficulty] leading zero bits. Verification is a single hash check.
///
/// Difficulty 0 = no work required (free tier).
/// Each additional bit doubles the expected work:
///   - difficulty 8  ≈ 256 hashes   ≈ 1ms
///   - difficulty 12 ≈ 4096 hashes  ≈ 15ms
///   - difficulty 16 ≈ 65536 hashes ≈ 250ms
///   - difficulty 20 ≈ 1M hashes    ≈ 4s
class ProofOfWorkService {
  static final _logger = Logger('ProofOfWorkService');

  /// Maximum difficulty we allow (prevents DoS via absurd difficulty).
  static const int maxDifficulty = 24;

  /// Maximum iterations before giving up (safety valve).
  static const int maxIterations = 1 << 24; // ~16M

  /// Build the challenge string from relay message metadata.
  ///
  /// Challenge = messageHash + ":" + timestamp (deterministic from metadata).
  static String buildChallenge(String messageHash, int timestampMs) {
    return '$messageHash:$timestampMs';
  }

  /// Compute a proof-of-work solution for the given [challenge] at [difficulty].
  ///
  /// Returns null if difficulty is 0 (free tier, no PoW needed).
  /// Throws [StateError] if maxIterations exceeded (should never happen at
  /// reasonable difficulty levels).
  static ProofOfWorkResult? compute({
    required String challenge,
    required int difficulty,
  }) {
    if (difficulty <= 0) return null;
    if (difficulty > maxDifficulty) {
      _logger.warning(
        '⚡ PoW difficulty $difficulty exceeds max $maxDifficulty, capping',
      );
      difficulty = maxDifficulty;
    }

    final challengeBytes = utf8.encode(challenge);

    for (int nonce = 0; nonce < maxIterations; nonce++) {
      final nonceBytes = utf8.encode(':$nonce');
      final input = Uint8List(challengeBytes.length + nonceBytes.length);
      input.setRange(0, challengeBytes.length, challengeBytes);
      input.setRange(challengeBytes.length, input.length, nonceBytes);

      final hash = sha256.convert(input);
      if (_meetsTarget(hash.bytes, difficulty)) {
        return ProofOfWorkResult(
          nonce: nonce,
          iterations: nonce + 1,
          hash: hash.toString(),
        );
      }
    }

    throw StateError(
      'PoW computation exceeded $maxIterations iterations at difficulty $difficulty',
    );
  }

  /// Verify that [nonce] satisfies [difficulty] for the given [challenge].
  ///
  /// O(1): single SHA-256 computation.
  /// Returns true if difficulty <= 0 (free tier) or nonce is null (legacy).
  static bool verify({
    required String challenge,
    required int? nonce,
    required int difficulty,
  }) {
    // Free tier or legacy message: always valid
    if (difficulty <= 0) return true;
    if (nonce == null) return false;
    if (difficulty > maxDifficulty) difficulty = maxDifficulty;

    final challengeBytes = utf8.encode(challenge);
    final nonceBytes = utf8.encode(':$nonce');
    final input = Uint8List(challengeBytes.length + nonceBytes.length);
    input.setRange(0, challengeBytes.length, challengeBytes);
    input.setRange(challengeBytes.length, input.length, nonceBytes);

    final hash = sha256.convert(input);
    return _meetsTarget(hash.bytes, difficulty);
  }

  /// Check if a hash has at least [difficulty] leading zero bits.
  static bool _meetsTarget(List<int> hashBytes, int difficulty) {
    int bitsRemaining = difficulty;

    for (final byte in hashBytes) {
      if (bitsRemaining <= 0) return true;

      if (bitsRemaining >= 8) {
        if (byte != 0) return false;
        bitsRemaining -= 8;
      } else {
        // Check remaining bits in this byte
        final mask = (0xFF << (8 - bitsRemaining)) & 0xFF;
        return (byte & mask) == 0;
      }
    }

    return bitsRemaining <= 0;
  }
}
