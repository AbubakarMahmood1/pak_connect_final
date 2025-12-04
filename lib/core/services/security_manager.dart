import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_repository_provider.dart';
import '../interfaces/i_contact_repository.dart';
import '../interfaces/i_security_manager.dart';
import '../security/security_types.dart';
import '../../domain/entities/contact.dart';
import '../security/noise/noise_encryption_service.dart';
import '../security/noise/models/noise_models.dart';
import 'simple_crypto.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../domain/values/id_types.dart';

export '../security/security_types.dart';

class SecurityManager implements ISecurityManager {
  SecurityManager._internal();
  static final SecurityManager _instance = SecurityManager._internal();
  factory SecurityManager() => _instance;
  static SecurityManager get instance => _instance;

  static final _logger = Logger('SecurityManager');
  NoiseEncryptionService? _noiseService;

  @override
  NoiseEncryptionService? get noiseService => _noiseService;

  /// Initialize the Noise Protocol encryption service
  @override
  Future<void> initialize({FlutterSecureStorage? secureStorage}) async {
    if (_noiseService != null) {
      _logger.info('🔒 SecurityManager already initialized');
      return;
    }

    try {
      _noiseService = NoiseEncryptionService(secureStorage: secureStorage);
      await _noiseService!.initialize();

      final fingerprint = _noiseService!.getIdentityFingerprint();
      _logger.info('🔒 SecurityManager initialized with Noise Protocol');
      _logger.info('🔒 Identity fingerprint: ${fingerprint.shortId()}...');
    } catch (e) {
      _logger.severe('🔒 Failed to initialize SecurityManager: $e');
      rethrow;
    }
  }

  /// Clear all Noise sessions (for testing)
  @override
  void clearAllNoiseSessions() {
    _noiseService?.clearAllSessions();
    _logger.info('🔒 Cleared all Noise sessions');
  }

  /// Shutdown the security manager
  @override
  void shutdown() {
    _noiseService?.shutdown();
    _noiseService = null;
    _logger.info('🔒 SecurityManager shutdown');
  }

  // ========== IDENTITY RESOLUTION ==========

  /// Register persistent → ephemeral mapping for Noise session lookup
  ///
  /// Call this after pairing completes (MEDIUM security upgrade).
  /// Enables transparent encryption/decryption with persistent keys.
  ///
  /// [persistentPublicKey] Long-term identity from pairing
  /// [ephemeralID] Session ID used during handshake
  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {
    if (_noiseService == null) {
      _logger.warning(
        'Cannot register identity mapping - Noise service not initialized',
      );
      return;
    }
    _noiseService!.registerIdentityMapping(persistentPublicKey, ephemeralID);
  }

  /// Unregister persistent → ephemeral mapping
  @override
  void unregisterIdentityMapping(String persistentPublicKey) {
    if (_noiseService == null) {
      return;
    }
    _noiseService!.unregisterIdentityMapping(persistentPublicKey);
  }

  // Typed overloads (UserId adapters)
  void registerIdentityMappingForUser({
    required UserId persistentUserId,
    required String ephemeralID,
  }) => registerIdentityMapping(
    persistentPublicKey: persistentUserId.value,
    ephemeralID: ephemeralID,
  );

  void unregisterIdentityMappingForUser(UserId persistentUserId) =>
      unregisterIdentityMapping(persistentUserId.value);

  /// Get current security level for a contact
  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    // Use provided repo or fallback to DI container
    final contactRepo =
        repo ?? GetIt.instance<IRepositoryProvider>().contactRepository;

    // 🔧 FIX: Handle empty or invalid public keys safely
    if (publicKey.isEmpty) {
      _logger.info('🔒 LEVEL: Empty public key → LOW (unencrypted)');
      return SecurityLevel.low;
    }

    // 🔧 SCHEMA V8: Use dual lookup to find contact by publicKey OR persistentPublicKey
    final contact = await contactRepo.getContactByAnyId(publicKey);

    // 🔧 FIX: Safe truncation to prevent RangeError
    final truncatedKey = publicKey.length > 16
        ? publicKey.shortId()
        : publicKey;
    _logger.fine('🔧 SECURITY DEBUG: getCurrentLevel for $truncatedKey...');
    _logger.fine('🔧 SECURITY DEBUG: Contact exists: ${contact != null}');
    _logger.fine(
      '🔧 SECURITY DEBUG: Contact security level: ${contact?.securityLevel.name}',
    );

    if (contact == null) {
      _logger.info('🔒 LEVEL: $truncatedKey → LOW (no contact)');
      return SecurityLevel.low;
    }

    // Check actual capabilities vs stored level
    final hasECDH = await contactRepo.getCachedSharedSecret(publicKey) != null;
    final hasPairing = SimpleCrypto.hasConversationKey(publicKey);

    // 🔧 FIX: Use contact's sessionIdForNoise (handles both ephemeral and persistent)
    final sessionLookupKey =
        contact.sessionIdForNoise ?? publicKey; // Fallback to publicKey
    final hasNoiseSession =
        _noiseService?.hasEstablishedSession(sessionLookupKey) ?? false;

    _logger.fine('🔧 SECURITY DEBUG: Has ECDH secret: $hasECDH');
    _logger.fine('🔧 SECURITY DEBUG: Has pairing key: $hasPairing');
    _logger.fine(
      '🔧 SECURITY DEBUG: Session lookup key: $sessionLookupKey (persistent: ${contact.persistentPublicKey != null})',
    );
    _logger.fine('🔧 SECURITY DEBUG: Has Noise session: $hasNoiseSession');

    SecurityLevel actualLevel;

    if (contact.trustStatus == TrustStatus.verified && hasECDH) {
      actualLevel = SecurityLevel.high;
    } else if (hasPairing) {
      actualLevel = SecurityLevel.medium;
    } else if (hasNoiseSession) {
      actualLevel = SecurityLevel.low; // Noise session active
    } else {
      actualLevel = SecurityLevel.low; // No encryption (shouldn't happen)
    }
    _logger.fine(
      '🔧 SECURITY DEBUG: Calculated actual level: ${actualLevel.name}',
    );

    // Update stored level if different
    if (contact.securityLevel != actualLevel) {
      await contactRepo.updateContactSecurityLevel(publicKey, actualLevel);
      _logger.info(
        '🔒 SYNC: Updated $publicKey from ${contact.securityLevel.name} to ${actualLevel.name}',
      );
    }

    _logger.info(
      '🔒 LEVEL: $truncatedKey → ${actualLevel.name.toUpperCase()} (${_getLevelDescription(actualLevel)})',
    );
    return actualLevel;
  }

  Future<SecurityLevel> getCurrentLevelForUser(
    UserId userId, [
    IContactRepository? repo,
  ]) => getCurrentLevel(userId.value, repo);

  /// Select appropriate Noise pattern for handshake with contact
  ///
  /// Returns (pattern, remoteStaticPublicKey) tuple.
  ///
  /// - LOW security: Always XX (first-time contact)
  /// - MEDIUM/HIGH security: Try KK if we have their static key, otherwise XX
  @override
  Future<(NoisePattern, Uint8List?)> selectNoisePattern(
    String publicKey, [
    IContactRepository? repo,
  ]) async {
    // Use provided repo or fallback to DI container
    final contactRepo =
        repo ?? GetIt.instance<IRepositoryProvider>().contactRepository;

    // 🔧 SCHEMA V8: Use dual lookup to find contact by publicKey OR persistentPublicKey
    final contact = await contactRepo.getContactByAnyId(publicKey);

    // No contact or LOW security → Always use XX
    final truncatedKey = publicKey.shortId(8);

    if (contact == null || contact.securityLevel == SecurityLevel.low) {
      _logger.info('🔒 PATTERN: $truncatedKey... → XX (first-time contact)');
      return (NoisePattern.xx, null);
    }

    // MEDIUM or HIGH security → Try KK if we have their static key
    final theirStaticKey = contact.noisePublicKey;

    if (theirStaticKey != null && theirStaticKey.isNotEmpty) {
      try {
        final keyBytes = base64.decode(theirStaticKey);
        if (keyBytes.length == 32) {
          _logger.info(
            '🔒 PATTERN: $truncatedKey... → KK (known contact, ${contact.securityLevel.name})',
          );
          return (NoisePattern.kk, Uint8List.fromList(keyBytes));
        }
      } catch (e) {
        _logger.warning(
          '🔒 PATTERN: Invalid static key for $truncatedKey..., falling back to XX: $e',
        );
      }
    }

    // Fallback to XX if no valid static key
    _logger.info('🔒 PATTERN: $truncatedKey... → XX (no static key available)');
    return (NoisePattern.xx, null);
  }

  Future<(NoisePattern, Uint8List?)> selectNoisePatternForUser(
    UserId userId, [
    IContactRepository? repo,
  ]) => selectNoisePattern(userId.value, repo);

  /// Get encryption key for current security level
  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async {
    final level = await getCurrentLevel(publicKey, repo);

    // 🔧 SCHEMA V8: Use dual lookup + get session ID for Noise
    final contact = await repo.getContactByAnyId(publicKey);
    final sessionLookupKey = contact?.sessionIdForNoise ?? publicKey;

    switch (level) {
      case SecurityLevel.high:
        if (await _verifyECDHKey(publicKey, repo)) {
          return EncryptionMethod.ecdh(publicKey);
        }
        _logger.warning('🔒 FALLBACK: ECDH failed, falling back to noise');
        await _downgrade(publicKey, SecurityLevel.medium, repo);
        continue medium;

      medium:
      case SecurityLevel.medium:
        // ✅ CORRECT ORDER: Pairing first (persistent trust)
        if (_verifyPairingKey(publicKey)) {
          return EncryptionMethod.pairing(publicKey);
        }
        // Noise is fallback (for spy mode or when pairing not available)
        if (_noiseService != null &&
            _noiseService!.hasEstablishedSession(sessionLookupKey)) {
          return EncryptionMethod.noise(sessionLookupKey);
        }
        _logger.warning(
          '🔒 FALLBACK: Noise/Pairing unavailable, falling back to global',
        );
        await _downgrade(publicKey, SecurityLevel.low, repo);
        continue low;

      low:
      case SecurityLevel.low:
        // 🔧 FIX: Check for active Noise session using contact's sessionIdForNoise
        if (_noiseService != null &&
            _noiseService!.hasEstablishedSession(sessionLookupKey)) {
          return EncryptionMethod.noise(sessionLookupKey);
        }
        // Only use global if NO Noise session (shouldn't happen after handshake)
        _logger.warning(
          '🔒 FALLBACK: No Noise session at LOW level, using global',
        );
        return EncryptionMethod.global();
    }
  }

  Future<EncryptionMethod> getEncryptionMethodForUser(
    UserId userId,
    IContactRepository repo,
  ) => getEncryptionMethod(userId.value, repo);

  /// Encrypt message using best available method
  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async {
    final method = await getEncryptionMethod(publicKey, repo);

    try {
      switch (method.type) {
        case EncryptionType.ecdh:
          final encrypted = await SimpleCrypto.encryptForContact(
            message,
            publicKey,
            repo,
          );
          if (encrypted != null) {
            _logger.info('🔒 ENCRYPT: ECDH → ${message.length} chars');
            return encrypted;
          }
          throw Exception('ECDH encryption failed');

        case EncryptionType.noise:
          if (_noiseService == null) {
            throw Exception('Noise service not initialized');
          }
          final messageBytes = utf8.encode(message);
          final encrypted = await _noiseService!.encrypt(
            Uint8List.fromList(messageBytes),
            publicKey,
          );
          if (encrypted != null) {
            final encryptedBase64 = base64.encode(encrypted);
            _logger.info('🔒 ENCRYPT: NOISE → ${message.length} chars');
            return encryptedBase64;
          }
          throw Exception('Noise encryption failed');

        case EncryptionType.pairing:
          final encrypted = SimpleCrypto.encryptForConversation(
            message,
            publicKey,
          );
          _logger.info('🔒 ENCRYPT: PAIRING → ${message.length} chars');
          return encrypted;

        case EncryptionType.global:
          final encrypted = SimpleCrypto.encrypt(message);
          _logger.info('🔒 ENCRYPT: GLOBAL → ${message.length} chars');
          return encrypted;
      }
    } catch (e) {
      _logger.severe('🔒 ENCRYPT FAILED: ${method.type.name} → $e');
      // Fallback to global
      if (method.type != EncryptionType.global) {
        _logger.info('🔒 FALLBACK: Using global encryption');
        return SimpleCrypto.encrypt(message);
      }
      rethrow;
    }
  }

  Future<String> encryptMessageForUser(
    String message,
    UserId userId,
    IContactRepository repo,
  ) => encryptMessage(message, userId.value, repo);

  /// Decrypt message trying methods in order
  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async {
    final level = await getCurrentLevel(publicKey, repo);

    // Try methods in order of security level
    final methods = _getMethodsForLevel(level);

    for (final method in methods) {
      try {
        switch (method) {
          case EncryptionType.ecdh:
            final decrypted = await SimpleCrypto.decryptFromContact(
              encryptedMessage,
              publicKey,
              repo,
            );
            if (decrypted != null) {
              _logger.info('🔒 DECRYPT: ECDH ✅');
              return decrypted;
            }
            break;

          case EncryptionType.noise:
            if (_noiseService != null) {
              try {
                final encryptedBytes = base64.decode(encryptedMessage);
                final decryptedBytes = await _noiseService!.decrypt(
                  Uint8List.fromList(encryptedBytes),
                  publicKey,
                );
                if (decryptedBytes != null) {
                  final decrypted = utf8.decode(decryptedBytes);
                  _logger.info('🔒 DECRYPT: NOISE ✅');
                  return decrypted;
                }
              } catch (e) {
                _logger.warning(
                  '🔒 DECRYPT: NOISE ❌ (not base64 or invalid) → $e',
                );
              }
            }
            break;

          case EncryptionType.pairing:
            if (SimpleCrypto.hasConversationKey(publicKey)) {
              final decrypted = SimpleCrypto.decryptFromConversation(
                encryptedMessage,
                publicKey,
              );
              _logger.info('🔒 DECRYPT: PAIRING ✅');
              return decrypted;
            }
            break;

          case EncryptionType.global:
            final decrypted = SimpleCrypto.decrypt(encryptedMessage);
            _logger.info('🔒 DECRYPT: GLOBAL ✅');
            return decrypted;
        }
      } catch (e) {
        _logger.warning('🔒 DECRYPT: ${method.name} ❌ → $e');
        continue;
      }
    }

    // ALL methods failed - trigger security resync, don't downgrade immediately
    _logger.severe(
      '🔒 DECRYPT: All methods failed - requesting security resync',
    );
    await _requestSecurityResync(publicKey, repo);

    throw Exception(
      'All decryption methods failed - security resync requested',
    );
  }

  /// Request security level resync instead of immediate downgrade
  static Future<void> _requestSecurityResync(
    String publicKey,
    IContactRepository repo,
  ) async {
    try {
      // Mark that we need to resync with this contact
      // 🔧 SCHEMA V8: Use dual lookup to find contact by publicKey OR persistentPublicKey
      final contact = await repo.getContactByAnyId(publicKey);
      if (contact != null) {
        // Reset security level to low temporarily to force re-negotiation
        await repo.updateContactSecurityLevel(publicKey, SecurityLevel.low);

        // Clear potentially corrupted keys using the public method
        await repo.clearCachedSecrets(publicKey);

        // Clear conversation keys (add public methods to SimpleCrypto)
        SimpleCrypto.clearConversationKey(publicKey);

        _logger.info(
          '🔒 RESYNC: Cleared security state for $publicKey - will re-negotiate on next connection',
        );
      }
    } catch (e) {
      _logger.severe('🔒 RESYNC FAILED: $e');
    }
  }

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    final method = await getEncryptionMethod(publicKey, repo);

    if (method.type == EncryptionType.noise &&
        _noiseService != null &&
        method.publicKey != null &&
        _noiseService!.hasEstablishedSession(method.publicKey!)) {
      final encrypted = await _noiseService!.encrypt(data, method.publicKey!);
      if (encrypted != null) {
        _logger.fine(
          '🔒 BIN ENCRYPT: NOISE → ${data.length} bytes to ${publicKey.shortId(8)}...',
        );
        return encrypted;
      }
      _logger.warning(
        '🔒 BIN ENCRYPT: Noise encryption returned null for ${publicKey.shortId(8)}...',
      );
    }

    _logger.warning(
      '🔒 BIN ENCRYPT: No Noise session for ${publicKey.shortId(8)}..., sending plaintext bytes',
    );
    return data;
  }

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    final method = await getEncryptionMethod(publicKey, repo);

    if (method.type == EncryptionType.noise &&
        _noiseService != null &&
        method.publicKey != null &&
        _noiseService!.hasEstablishedSession(method.publicKey!)) {
      final decrypted = await _noiseService!.decrypt(data, method.publicKey!);
      if (decrypted != null) {
        _logger.fine(
          '🔒 BIN DECRYPT: NOISE ← ${data.length} bytes from ${publicKey.shortId(8)}...',
        );
        return decrypted;
      }
      _logger.warning(
        '🔒 BIN DECRYPT: Noise decryption returned null for ${publicKey.shortId(8)}...',
      );
    }

    _logger.warning(
      '🔒 BIN DECRYPT: No Noise session for ${publicKey.shortId(8)}..., returning ciphertext bytes',
    );
    return data;
  }

  // Helper methods
  static Future<bool> _verifyECDHKey(
    String publicKey,
    IContactRepository repo,
  ) async {
    return await repo.getCachedSharedSecret(publicKey) != null;
  }

  static bool _verifyPairingKey(String publicKey) {
    return SimpleCrypto.hasConversationKey(publicKey);
  }

  static Future<void> _downgrade(
    String publicKey,
    SecurityLevel newLevel,
    IContactRepository repo,
  ) async {
    await repo.updateContactSecurityLevel(publicKey, newLevel);
    _logger.warning(
      '🔒 DOWNGRADE: ${publicKey.shortId(8)}... → ${newLevel.name}',
    );
  }

  static String _getLevelDescription(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.low:
        return 'Global Encryption';
      case SecurityLevel.medium:
        return 'Noise Protocol + Global';
      case SecurityLevel.high:
        return 'ECDH + Noise + Global';
    }
  }

  static List<EncryptionType> _getMethodsForLevel(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return [
          EncryptionType.ecdh,
          EncryptionType.noise,
          EncryptionType.pairing,
          EncryptionType.global,
        ];
      case SecurityLevel.medium:
        return [
          EncryptionType.noise,
          EncryptionType.pairing,
          EncryptionType.global,
        ];
      case SecurityLevel.low:
        return [EncryptionType.noise, EncryptionType.global];
    }
  }

  Future<String> decryptMessageForUser(
    String encryptedMessage,
    UserId userId,
    IContactRepository repo,
  ) => decryptMessage(encryptedMessage, userId.value, repo);
}
