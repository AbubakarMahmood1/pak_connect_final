import 'dart:typed_data';
import 'package:logging/logging.dart';

/// Secure wrapper for cryptographic key material
///
/// **Security Properties**:
/// - Zeros original key immediately upon construction (prevents memory leak)
/// - Provides controlled access via getter
/// - Prevents access after destruction
/// - Tracks destruction state
///
/// **Usage**:
/// ```dart
/// final originalKey = Uint8List.fromList([1, 2, 3, 4]);
/// final secureKey = SecureKey(originalKey);
/// // originalKey is now [0, 0, 0, 0]
///
/// // Access key data
/// final data = secureKey.data; // throws if destroyed
///
/// // Destroy when done
/// secureKey.destroy();
/// ```
///
/// **Design Pattern**: Resource Acquisition Is Initialization (RAII)
/// - Construction = acquisition + original zeroing
/// - Destruction = cleanup + zeroing
///
/// **Rationale**: Prevents private key memory leaks where copies are zeroed
/// but originals remain in heap, breaking forward secrecy.
class SecureKey {
  final Uint8List _data;
  bool _destroyed = false;
  final _logger = Logger('SecureKey');

  /// Creates a SecureKey and ZEROS the original immediately
  ///
  /// **CRITICAL**: This constructor modifies the input parameter!
  ///
  /// ```dart
  /// final original = Uint8List.fromList([1, 2, 3]);
  /// final secure = SecureKey(original);
  /// // original is now [0, 0, 0]
  /// // secure.data is [1, 2, 3]
  /// ```
  ///
  /// **Why zero the original?**
  /// - Prevents memory leak if caller forgets to zero
  /// - Enforces single source of truth for key material
  /// - Makes it impossible to have multiple untracked copies
  SecureKey(Uint8List original) : _data = Uint8List.fromList(original) {
    // ✅ Zero original IMMEDIATELY to prevent memory leak
    original.fillRange(0, original.length, 0);
  }

  /// Access the key data
  ///
  /// Throws [StateError] if key has been destroyed.
  ///
  /// **Usage**:
  /// ```dart
  /// final key = secureKey.data; // Use for crypto operations
  /// ```
  Uint8List get data {
    if (_destroyed) {
      throw StateError('Cannot access key: SecureKey has been destroyed');
    }
    return _data;
  }

  /// Check if key is destroyed
  bool get isDestroyed => _destroyed;

  /// Length of key data (safe to access after destruction)
  int get length => _data.length;

  /// Destroy the key material
  ///
  /// Zeros the internal key data and marks as destroyed.
  /// Idempotent - safe to call multiple times.
  ///
  /// **Best Practice**: Call in finally block or dispose method
  /// ```dart
  /// try {
  ///   // Use secureKey
  /// } finally {
  ///   secureKey.destroy();
  /// }
  /// ```
  void destroy() {
    if (!_destroyed) {
      _data.fillRange(0, _data.length, 0);
      _destroyed = true;
      _logger.fine('🔐 SecureKey destroyed (${_data.length} bytes zeroed)');
    }
  }

  @override
  String toString() {
    if (_destroyed) {
      return 'SecureKey(destroyed, ${_data.length} bytes)';
    }
    return 'SecureKey(active, ${_data.length} bytes)';
  }

  /// Create a new SecureKey from hex string
  ///
  /// Zeros the intermediate byte array.
  factory SecureKey.fromHex(String hex) {
    if (hex.length % 2 != 0) {
      throw ArgumentError('Hex string must have even length');
    }

    final bytes = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      bytes[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }

    // SecureKey constructor will zero the bytes array
    return SecureKey(bytes);
  }

  /// Convert key to hex string
  ///
  /// **WARNING**: The returned string is NOT secure! Only use for:
  /// - Secure storage (encrypted)
  /// - Logging (fingerprints only, not full key)
  ///
  /// DO NOT use for transmission or display.
  String toHex() {
    if (_destroyed) {
      throw StateError('Cannot convert destroyed key to hex');
    }
    return _data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
