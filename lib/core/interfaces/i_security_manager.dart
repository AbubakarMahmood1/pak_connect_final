import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pak_connect/core/security/noise/noise_encryption_service.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/services/security_manager.dart';

/// Interface for security manager operations
///
/// Abstracts encryption, decryption, and security level management to enable:
/// - Dependency injection
/// - Test mocking
/// - Alternative security implementations
///
/// **Phase 1 Note**: Interface defines all public methods from SecurityManager
abstract class ISecurityManager {
  /// Initialize the Noise Protocol encryption service
  Future<void> initialize({FlutterSecureStorage? secureStorage});

  /// Get the Noise service (for testing or advanced usage)
  NoiseEncryptionService? get noiseService;

  /// Clear all Noise sessions (for testing)
  void clearAllNoiseSessions();

  /// Shutdown the security manager
  void shutdown();

  // =========================
  // IDENTITY RESOLUTION
  // =========================

  /// Register persistent → ephemeral mapping for Noise session lookup
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  });

  /// Unregister persistent → ephemeral mapping
  void unregisterIdentityMapping(String persistentPublicKey);

  // =========================
  // SECURITY LEVEL MANAGEMENT
  // =========================

  /// Get current security level for a contact
  Future<SecurityLevel> getCurrentLevel(
    String publicKey,
    ContactRepository repo,
  );

  /// Select appropriate Noise pattern for handshake with contact
  Future<(NoisePattern, Uint8List?)> selectNoisePattern(
    String publicKey,
    ContactRepository repo,
  );

  /// Get encryption method for current security level
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    ContactRepository repo,
  );

  // =========================
  // ENCRYPTION/DECRYPTION
  // =========================

  /// Encrypt message using best available method
  Future<String> encryptMessage(
    String message,
    String publicKey,
    ContactRepository repo,
  );

  /// Decrypt message trying methods in order
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    ContactRepository repo,
  );
}
