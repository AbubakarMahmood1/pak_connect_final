// Create new file: core/services/security_manager.dart

import 'package:logging/logging.dart';
import '../../data/repositories/contact_repository.dart';
import '../models/protocol_message.dart';
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
    final contact = await repo.getContact(publicKey);
    
    _logger.fine('🔧 SECURITY DEBUG: getCurrentLevel for ${publicKey.substring(0, 16)}...');
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

// === CRYPTO VERIFICATION SYSTEM ===

enum VerificationStatus {
  pending,
  inProgress,
  completed,
  failed,
}

class VerificationResult {
  final bool success;
  final String challengeId;
  final Map<String, dynamic> testResults;
  final DateTime timestamp;
  final String? errorMessage;

  const VerificationResult({
    required this.success,
    required this.challengeId,
    required this.testResults,
    required this.timestamp,
    this.errorMessage,
  });

  factory VerificationResult.success(String challengeId, Map<String, dynamic> results) {
    return VerificationResult(
      success: true,
      challengeId: challengeId,
      testResults: results,
      timestamp: DateTime.now(),
    );
  }

  factory VerificationResult.failure(String challengeId, String error, [Map<String, dynamic>? partialResults]) {
    return VerificationResult(
      success: false,
      challengeId: challengeId,
      testResults: partialResults ?? {},
      timestamp: DateTime.now(),
      errorMessage: error,
    );
  }
}

class CryptoVerificationManager {
  static final _logger = Logger('CryptoVerificationManager');
  
  // Track ongoing verifications
  static final Map<String, VerificationStatus> _verificationStatus = {};
  static final Map<String, DateTime> _verificationTimestamps = {};
  static final Map<String, VerificationResult> _verificationResults = {};
  
  /// Initiate crypto verification process for a new connection
  static Future<String> initiateVerification(String contactPublicKey, ContactRepository repo) async {
    final challengeId = _generateChallengeId();
    
    try {
      _logger.info('🔍 VERIFICATION: Initiating for ${contactPublicKey.substring(0, 16)}...');
      
      // Mark verification as in progress
      _verificationStatus[challengeId] = VerificationStatus.inProgress;
      _verificationTimestamps[challengeId] = DateTime.now();
      
      // Run comprehensive crypto standards test
      final cryptoResults = await SimpleCrypto.verifyCryptoStandards(contactPublicKey, repo);
      
      if (!cryptoResults['overallSuccess']) {
        _logger.severe('🔍 VERIFICATION: Local crypto standards check failed');
        final result = VerificationResult.failure(challengeId, 'Local crypto standards verification failed', cryptoResults);
        _verificationResults[challengeId] = result;
        _verificationStatus[challengeId] = VerificationStatus.failed;
        return challengeId;
      }
      
      _logger.info('🔍 VERIFICATION: Local crypto standards verified - generating challenge');
      
      // Generate verification challenge
      final challenge = SimpleCrypto.generateVerificationChallenge();
      
      // Test bidirectional encryption
      final bidirectionalTest = await SimpleCrypto.testBidirectionalEncryption(
        contactPublicKey,
        repo,
        challenge
      );
      
      if (!bidirectionalTest['success']) {
        _logger.severe('🔍 VERIFICATION: Bidirectional encryption test failed');
        final result = VerificationResult.failure(challengeId, 'Bidirectional encryption failed', bidirectionalTest);
        _verificationResults[challengeId] = result;
        _verificationStatus[challengeId] = VerificationStatus.failed;
        return challengeId;
      }
      
      // All local tests passed - mark as completed
      final combinedResults = {
        'cryptoStandards': cryptoResults,
        'bidirectionalEncryption': bidirectionalTest,
        'verificationLevel': 'comprehensive',
        'contactPublicKey': contactPublicKey,
      };
      
      final result = VerificationResult.success(challengeId, combinedResults);
      _verificationResults[challengeId] = result;
      _verificationStatus[challengeId] = VerificationStatus.completed;
      
      _logger.info('🔍 VERIFICATION: ✅ Local verification completed successfully');
      return challengeId;
      
    } catch (e) {
      _logger.severe('🔍 VERIFICATION: Failed with exception: $e');
      final result = VerificationResult.failure(challengeId, 'Verification exception: $e');
      _verificationResults[challengeId] = result;
      _verificationStatus[challengeId] = VerificationStatus.failed;
      return challengeId;
    }
  }
  
  /// Generate a verification challenge message for remote device
  static Future<ProtocolMessage?> generateVerificationChallenge(String contactPublicKey, ContactRepository repo) async {
    try {
      _logger.info('🔍 CHALLENGE: Generating verification challenge');
      
      // Create a test message to encrypt
      final challenge = SimpleCrypto.generateVerificationChallenge();
      final testMessage = 'VERIFY_CRYPTO_${DateTime.now().millisecondsSinceEpoch}';
      
      // Encrypt the test message using current security method
      final encryptedMessage = await SecurityManager.encryptMessage(testMessage, contactPublicKey, repo);
      
      _logger.info('🔍 CHALLENGE: Generated encrypted challenge');
      
      return ProtocolMessage.cryptoVerification(
        challenge: challenge,
        testMessage: encryptedMessage,
        requiresResponse: true,
      );
      
    } catch (e) {
      _logger.severe('🔍 CHALLENGE: Failed to generate verification challenge: $e');
      return null;
    }
  }
  
  /// Handle received verification challenge
  static Future<ProtocolMessage?> handleVerificationChallenge(
    String challenge,
    String encryptedTestMessage,
    String senderPublicKey,
    ContactRepository repo
  ) async {
    try {
      _logger.info('🔍 RESPONSE: Handling verification challenge from ${senderPublicKey.substring(0, 16)}...');
      
      // First verify our own crypto standards
      final localVerification = await SimpleCrypto.verifyCryptoStandards(senderPublicKey, repo);
      
      if (!localVerification['overallSuccess']) {
        _logger.severe('🔍 RESPONSE: Local crypto verification failed');
        return ProtocolMessage.cryptoVerificationResponse(
          challenge: challenge,
          decryptedMessage: '',
          success: false,
          results: {'error': 'Local crypto standards check failed', 'details': localVerification},
        );
      }
      
      // Attempt to decrypt the challenge message
      String decryptedMessage;
      try {
        decryptedMessage = await SecurityManager.decryptMessage(encryptedTestMessage, senderPublicKey, repo);
        _logger.info('🔍 RESPONSE: ✅ Successfully decrypted challenge message');
      } catch (e) {
        _logger.severe('🔍 RESPONSE: ❌ Failed to decrypt challenge message: $e');
        return ProtocolMessage.cryptoVerificationResponse(
          challenge: challenge,
          decryptedMessage: '',
          success: false,
          results: {'error': 'Decryption failed', 'details': e.toString()},
        );
      }
      
      // Test our encryption back to them
      String responseTestMessage;
      try {
        const testResponse = 'VERIFY_RESPONSE_SUCCESS';
        responseTestMessage = await SecurityManager.encryptMessage(testResponse, senderPublicKey, repo);
        _logger.info('🔍 RESPONSE: ✅ Successfully encrypted response message');
      } catch (e) {
        _logger.severe('🔍 RESPONSE: ❌ Failed to encrypt response message: $e');
        return ProtocolMessage.cryptoVerificationResponse(
          challenge: challenge,
          decryptedMessage: decryptedMessage,
          success: false,
          results: {'error': 'Response encryption failed', 'details': e.toString()},
        );
      }
      
      // All tests passed - send successful response
      final responseResults = {
        'decryptionSuccess': true,
        'encryptionSuccess': true,
        'localCryptoVerification': localVerification,
        'responseTest': responseTestMessage,
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      _logger.info('🔍 RESPONSE: ✅ Verification challenge handled successfully');
      
      return ProtocolMessage.cryptoVerificationResponse(
        challenge: challenge,
        decryptedMessage: decryptedMessage,
        success: true,
        results: responseResults,
      );
      
    } catch (e) {
      _logger.severe('🔍 RESPONSE: Exception handling verification challenge: $e');
      return ProtocolMessage.cryptoVerificationResponse(
        challenge: challenge,
        decryptedMessage: '',
        success: false,
        results: {'error': 'Exception during verification', 'details': e.toString()},
      );
    }
  }
  
  /// Process verification response from remote device
  static Future<bool> processVerificationResponse(
    String challenge,
    String decryptedMessage,
    bool success,
    Map<String, dynamic>? results,
    String senderPublicKey,
    ContactRepository repo
  ) async {
    try {
      _logger.info('🔍 PROCESS: Processing verification response from ${senderPublicKey.substring(0, 16)}...');
      
      if (!success) {
        _logger.severe('🔍 PROCESS: Remote device reported verification failure');
        await _markDeviceAsUnverified(senderPublicKey, repo, 'Remote verification failed');
        return false;
      }
      
      // Verify they correctly decrypted our challenge
      final expectedPattern = 'VERIFY_CRYPTO_';
      if (!decryptedMessage.contains(expectedPattern)) {
        _logger.severe('🔍 PROCESS: Remote device failed to decrypt challenge correctly');
        await _markDeviceAsUnverified(senderPublicKey, repo, 'Challenge decryption failed');
        return false;
      }
      
      // If they included a response test, try to decrypt it
      if (results != null && results.containsKey('responseTest')) {
        try {
          final responseTest = results['responseTest'] as String;
          final decryptedResponse = await SecurityManager.decryptMessage(responseTest, senderPublicKey, repo);
          
          if (decryptedResponse != 'VERIFY_RESPONSE_SUCCESS') {
            _logger.severe('🔍 PROCESS: Failed to decrypt or validate response test');
            await _markDeviceAsUnverified(senderPublicKey, repo, 'Response test failed');
            return false;
          }
          
          _logger.info('🔍 PROCESS: ✅ Response test decryption successful');
        } catch (e) {
          _logger.severe('🔍 PROCESS: Exception processing response test: $e');
          await _markDeviceAsUnverified(senderPublicKey, repo, 'Response test exception');
          return false;
        }
      }
      
      // All verification steps passed - mark device as crypto-verified
      await _markDeviceAsVerified(senderPublicKey, repo);
      _logger.info('🔍 PROCESS: ✅ Complete crypto verification successful');
      
      return true;
      
    } catch (e) {
      _logger.severe('🔍 PROCESS: Exception processing verification response: $e');
      await _markDeviceAsUnverified(senderPublicKey, repo, 'Processing exception');
      return false;
    }
  }
  
  /// Mark device as crypto-verified and upgrade security level
  static Future<void> _markDeviceAsVerified(String publicKey, ContactRepository repo) async {
    try {
      // Ensure contact exists
      final contact = await repo.getContact(publicKey);
      if (contact == null) {
        _logger.warning('🔍 VERIFY: No contact found - creating new verified contact');
        await repo.saveContactWithSecurity(publicKey, 'Verified Device', SecurityLevel.high);
      }
      
      // Mark as verified and upgrade to high security
      await repo.markContactVerified(publicKey);
      await repo.updateContactSecurityLevel(publicKey, SecurityLevel.high);
      
      _logger.info('🔍 VERIFY: ✅ Device marked as crypto-verified with high security');
      
    } catch (e) {
      _logger.severe('🔍 VERIFY: Failed to mark device as verified: $e');
    }
  }
  
  /// Mark device as unverified due to crypto failure
  static Future<void> _markDeviceAsUnverified(String publicKey, ContactRepository repo, String reason) async {
    try {
      // Downgrade security level due to verification failure
      await repo.updateContactSecurityLevel(publicKey, SecurityLevel.low);
      
      _logger.warning('🔍 UNVERIFY: Device marked as unverified - $reason');
      
    } catch (e) {
      _logger.severe('🔍 UNVERIFY: Failed to mark device as unverified: $e');
    }
  }
  
  /// Get verification status for a device
  static VerificationStatus? getVerificationStatus(String challengeId) {
    return _verificationStatus[challengeId];
  }
  
  /// Get verification result for a device
  static VerificationResult? getVerificationResult(String challengeId) {
    return _verificationResults[challengeId];
  }
  
  /// Check if verification is required for connection
  static Future<bool> isVerificationRequired(String publicKey, ContactRepository repo) async {
    final contact = await repo.getContact(publicKey);
    
    // Verification required if:
    // 1. No contact exists (new device)
    // 2. Contact exists but is not verified
    // 3. Contact has low security level
    
    if (contact == null) {
      return true;
    }
    
    if (contact.trustStatus != TrustStatus.verified) {
      return true;
    }
    
    if (contact.securityLevel == SecurityLevel.low) {
      return true;
    }
    
    return false;
  }
  
  /// Clean up old verification data
  static void cleanupVerificationData() {
    final cutoff = DateTime.now().subtract(Duration(hours: 1));
    
    _verificationTimestamps.removeWhere((challengeId, timestamp) {
      final isOld = timestamp.isBefore(cutoff);
      if (isOld) {
        _verificationStatus.remove(challengeId);
        _verificationResults.remove(challengeId);
      }
      return isOld;
    });
  }
  
  /// Generate unique challenge ID
  static String _generateChallengeId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = (timestamp % 10000).toString().padLeft(4, '0');
    return 'CHALLENGE_${timestamp}_$random';
  }
}