// Create new file: core/services/security_manager.dart

import 'package:logging/logging.dart';
import '../../data/repositories/contact_repository.dart';
import 'simple_crypto.dart';

enum SecurityLevel {
  low,     // Global encryption only
  medium,  // Pairing key + Global
  high,    // ECDH + Pairing + Global (verified contacts)
}

class SecurityManager {
  static final _logger = Logger('SecurityManager');
  
  /// Get current security level for a contact
  static Future<SecurityLevel> getCurrentLevel(String publicKey, ContactRepository repo) async {
    // 🔧 FIX: Handle empty or invalid public keys safely
    if (publicKey.isEmpty) {
      _logger.info('🔒 LEVEL: Empty public key → LOW (unencrypted)');
      return SecurityLevel.low;
    }
    
    final contact = await repo.getContact(publicKey);
    
    // 🔧 FIX: Safe truncation to prevent RangeError
    final truncatedKey = publicKey.length > 16 ? publicKey.substring(0, 16) : publicKey;
    _logger.fine('🔧 SECURITY DEBUG: getCurrentLevel for $truncatedKey...');
    _logger.fine('🔧 SECURITY DEBUG: Contact exists: ${contact != null}');
    _logger.fine('🔧 SECURITY DEBUG: Contact security level: ${contact?.securityLevel.name}');
  

    if (contact == null) {
      _logger.info('🔒 LEVEL: $publicKey → LOW (no contact)');
      return SecurityLevel.low;
    }
    
    // Check actual capabilities vs stored level
    final hasECDH = await repo.getCachedSharedSecret(publicKey) != null;
    final hasPairing = SimpleCrypto.hasConversationKey(publicKey);
    
    _logger.fine('🔧 SECURITY DEBUG: Has ECDH secret: $hasECDH');
    _logger.fine('🔧 SECURITY DEBUG: Has pairing key: $hasPairing');
  

    SecurityLevel actualLevel;
    
    if (contact.trustStatus == TrustStatus.verified && hasECDH) {
      actualLevel = SecurityLevel.high;
    } else if (hasPairing) {
      actualLevel = SecurityLevel.medium;
    } else {
      actualLevel = SecurityLevel.low;
    }

   _logger.fine('🔧 SECURITY DEBUG: Calculated actual level: ${actualLevel.name}');
  
    
    // Update stored level if different
    if (contact.securityLevel != actualLevel) {
      await repo.updateContactSecurityLevel(publicKey, actualLevel);
      _logger.info('🔒 SYNC: Updated $publicKey from ${contact.securityLevel.name} to ${actualLevel.name}');
    }
    
    _logger.info('🔒 LEVEL: $publicKey → ${actualLevel.name.toUpperCase()} (${_getLevelDescription(actualLevel)})');
    return actualLevel;
  }
  
  /// Get encryption key for current security level
  static Future<EncryptionMethod> getEncryptionMethod(String publicKey, ContactRepository repo) async {
    final level = await getCurrentLevel(publicKey, repo);
    
    switch (level) {
      case SecurityLevel.high:
        if (await _verifyECDHKey(publicKey, repo)) {
          return EncryptionMethod.ecdh(publicKey);
        }
        _logger.warning('🔒 FALLBACK: ECDH failed, falling back to pairing');
        await _downgrade(publicKey, SecurityLevel.medium, repo);
        continue medium;
        
      medium:
      case SecurityLevel.medium:
        if (_verifyPairingKey(publicKey)) {
          return EncryptionMethod.pairing(publicKey);
        }
        _logger.warning('🔒 FALLBACK: Pairing failed, falling back to global');
        await _downgrade(publicKey, SecurityLevel.low, repo);
        continue low;
        
      low:
      case SecurityLevel.low:
        return EncryptionMethod.global();
    }
  }
  
  /// Encrypt message using best available method
  static Future<String> encryptMessage(String message, String publicKey, ContactRepository repo) async {
    final method = await getEncryptionMethod(publicKey, repo);
    
    try {
      switch (method.type) {
        case EncryptionType.ecdh:
          final encrypted = await SimpleCrypto.encryptForContact(message, publicKey, repo);
          if (encrypted != null) {
            _logger.info('🔒 ENCRYPT: ECDH → ${message.length} chars');
            return encrypted;
          }
          throw Exception('ECDH encryption failed');
          
        case EncryptionType.pairing:
          final encrypted = SimpleCrypto.encryptForConversation(message, publicKey);
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
  
  /// Decrypt message trying methods in order
  static Future<String> decryptMessage(String encryptedMessage, String publicKey, ContactRepository repo) async {
  final level = await getCurrentLevel(publicKey, repo);
  
  // Try methods in order of security level
  final methods = _getMethodsForLevel(level);
  
  for (final method in methods) {
    try {
      switch (method) {
        case EncryptionType.ecdh:
          final decrypted = await SimpleCrypto.decryptFromContact(encryptedMessage, publicKey, repo);
          if (decrypted != null) {
            _logger.info('🔒 DECRYPT: ECDH ✅');
            return decrypted;
          }
          break;
          
        case EncryptionType.pairing:
          if (SimpleCrypto.hasConversationKey(publicKey)) {
            final decrypted = SimpleCrypto.decryptFromConversation(encryptedMessage, publicKey);
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
  _logger.severe('🔒 DECRYPT: All methods failed - requesting security resync');
  await _requestSecurityResync(publicKey, repo);
  
  throw Exception('All decryption methods failed - security resync requested');
}

/// Request security level resync instead of immediate downgrade
static Future<void> _requestSecurityResync(String publicKey, ContactRepository repo) async {
  try {
    // Mark that we need to resync with this contact
    final contact = await repo.getContact(publicKey);
    if (contact != null) {
      // Reset security level to low temporarily to force re-negotiation
      await repo.updateContactSecurityLevel(publicKey, SecurityLevel.low);
      
      // Clear potentially corrupted keys using the public method
      await repo.clearCachedSecrets(publicKey);
      
      // Clear conversation keys (add public methods to SimpleCrypto)
      SimpleCrypto.clearConversationKey(publicKey);
      
      _logger.info('🔒 RESYNC: Cleared security state for $publicKey - will re-negotiate on next connection');
    }
  } catch (e) {
    _logger.severe('🔒 RESYNC FAILED: $e');
  }
}
  
  // Helper methods
  static Future<bool> _verifyECDHKey(String publicKey, ContactRepository repo) async {
    return await repo.getCachedSharedSecret(publicKey) != null;
  }
  
  static bool _verifyPairingKey(String publicKey) {
    return SimpleCrypto.hasConversationKey(publicKey);
  }
  
  static Future<void> _downgrade(String publicKey, SecurityLevel newLevel, ContactRepository repo) async {
    await repo.updateContactSecurityLevel(publicKey, newLevel);
    _logger.warning('🔒 DOWNGRADE: $publicKey → ${newLevel.name}');
  }
  
  static String _getLevelDescription(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.low: return 'Global Encryption';
      case SecurityLevel.medium: return 'Pairing + Global';
      case SecurityLevel.high: return 'ECDH + Pairing + Global';
    }
  }
  
  static List<EncryptionType> _getMethodsForLevel(SecurityLevel level) {
    switch (level) {
      case SecurityLevel.high:
        return [EncryptionType.ecdh, EncryptionType.pairing, EncryptionType.global];
      case SecurityLevel.medium:
        return [EncryptionType.pairing, EncryptionType.global];
      case SecurityLevel.low:
        return [EncryptionType.global];
    }
  }
}

enum EncryptionType { ecdh, pairing, global }

class EncryptionMethod {
  final EncryptionType type;
  final String? publicKey;
  
  const EncryptionMethod._(this.type, [this.publicKey]);
  
  factory EncryptionMethod.ecdh(String publicKey) => EncryptionMethod._(EncryptionType.ecdh, publicKey);
  factory EncryptionMethod.pairing(String publicKey) => EncryptionMethod._(EncryptionType.pairing, publicKey);
  factory EncryptionMethod.global() => EncryptionMethod._(EncryptionType.global);
}