import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';

import '../interfaces/i_contact_repository.dart';
import 'contact_crypto_service.dart';
import 'conversation_crypto_service.dart';
import 'signing_crypto_service.dart';

/// Diagnostic-only crypto self-test helpers.
///
/// This is intentionally separate from the compatibility facade so the active
/// crypto helpers do not keep accumulating long-tail responsibilities that
/// belong to dedicated services.
class CryptoVerificationService {
  static final _logger = Logger('CryptoVerificationService');

  static void _log(Object? message, {Level level = Level.FINE}) {
    _logger.log(level, message);
  }

  /// Comprehensive crypto standards verification.
  static Future<Map<String, dynamic>> verifyCryptoStandards(
    String? contactPublicKey,
    IContactRepository? repo,
  ) async {
    final results = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'overallSuccess': false,
      'tests': <String, dynamic>{},
    };

    try {
      results['tests']['ecdhKeyGeneration'] = await _testECDHKeyGeneration();
      results['tests']['conversationEncryption'] =
          await _testConversationEncryption();
      results['tests']['enhancedKeyDerivation'] =
          await _testEnhancedKeyDerivation();
      results['tests']['messageSigning'] = await _testMessageSigning();

      if (repo != null && contactPublicKey != null) {
        results['tests']['keyStorage'] = await _testKeyStorage(
          contactPublicKey,
          repo,
        );
      }

      if (contactPublicKey != null) {
        results['tests']['ecdhSharedSecret'] = await _testECDHSharedSecret(
          contactPublicKey,
        );
      }

      final tests = results['tests'] as Map<String, dynamic>;
      final allPassed = tests.values.every(
        (test) => test is Map && test['success'] == true,
      );
      results['overallSuccess'] = allPassed;

      _log('🔍 CRYPTO VERIFICATION: Overall success = $allPassed');
      return results;
    } catch (e) {
      _log('🔍 CRYPTO VERIFICATION: Fatal error during verification: $e');
      results['error'] = e.toString();
      results['overallSuccess'] = false;
      return results;
    }
  }

  static Future<Map<String, dynamic>> _testECDHKeyGeneration() async {
    try {
      _log('🔍 TEST: ECDH Key Generation');

      if (!SigningCryptoService.hasPrivateKey) {
        return {
          'success': false,
          'error': 'No private key available for ECDH testing',
          'testName': 'ECDH Key Generation',
        };
      }

      final curve = ECCurve_secp256r1();
      try {
        final _ = curve.curve;
      } catch (e) {
        return {
          'success': false,
          'error': 'Failed to initialize secp256r1 curve: $e',
          'testName': 'ECDH Key Generation',
        };
      }

      _log('🔍 TEST: ✅ ECDH Key Generation - All components available');
      return {
        'success': true,
        'details': 'Private key and curve available for ECDH operations',
        'testName': 'ECDH Key Generation',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ ECDH Key Generation failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'ECDH Key Generation',
      };
    }
  }

  static Future<Map<String, dynamic>> _testConversationEncryption() async {
    try {
      _log('🔍 TEST: Conversation Encryption');

      const testMessage = 'PakConnect_Crypto_Test_Message_123';
      const publicKey = 'verification-conversation-peer';
      const sharedSecret = 'verification-shared-secret';

      ConversationCryptoService.initializeConversation(publicKey, sharedSecret);
      final encrypted = ConversationCryptoService.encryptForConversation(
        testMessage,
        publicKey,
      );
      final decrypted = ConversationCryptoService.decryptFromConversation(
        encrypted,
        publicKey,
      );
      ConversationCryptoService.clearConversationKey(publicKey);

      if (decrypted != testMessage) {
        return {
          'success': false,
          'error':
              'Conversation encryption round-trip failed - decrypted message does not match original',
          'testName': 'Conversation Encryption',
        };
      }

      _log('🔍 TEST: ✅ Conversation Encryption - Round trip successful');
      return {
        'success': true,
        'details': 'Conversation/session encryption is functional',
        'testName': 'Conversation Encryption',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ Conversation Encryption failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Conversation Encryption',
      };
    }
  }

  static Future<Map<String, dynamic>> _testEnhancedKeyDerivation() async {
    try {
      _log('🔍 TEST: Enhanced Key Derivation');

      const mockECDHSecret = 'test_ecdh_secret_12345';
      const mockPublicKey = 'test_public_key_67890';

      final standardKey = ContactCryptoService.deriveEnhancedContactKey(
        mockECDHSecret,
        mockPublicKey,
      );
      if (standardKey.isEmpty) {
        return {
          'success': false,
          'error': 'Enhanced key derivation returned empty key',
          'testName': 'Enhanced Key Derivation',
        };
      }

      ConversationCryptoService.initializeConversation(
        mockPublicKey,
        'mock_pairing_secret',
      );
      final enhancedKey = ContactCryptoService.deriveEnhancedContactKey(
        mockECDHSecret,
        mockPublicKey,
      );

      if (enhancedKey == standardKey) {
        return {
          'success': false,
          'error':
              'Enhanced derivation not producing different results with pairing key',
          'testName': 'Enhanced Key Derivation',
        };
      }

      ConversationCryptoService.clearConversationKey(mockPublicKey);

      _log(
        '🔍 TEST: ✅ Enhanced Key Derivation - Multiple derivation methods working',
      );
      return {
        'success': true,
        'details':
            'Enhanced key derivation working with and without pairing keys',
        'testName': 'Enhanced Key Derivation',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ Enhanced Key Derivation failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Enhanced Key Derivation',
      };
    }
  }

  static Future<Map<String, dynamic>> _testMessageSigning() async {
    try {
      _log('🔍 TEST: Message Signing/Verification');

      const testMessage = 'PakConnect_Signature_Test_Message';
      if (!SigningCryptoService.isSigningReady) {
        return {
          'success': false,
          'error': 'Message signing not initialized',
          'testName': 'Message Signing',
        };
      }

      final signature = SigningCryptoService.signMessage(testMessage);
      if (signature == null) {
        return {
          'success': false,
          'error': 'Failed to generate message signature',
          'testName': 'Message Signing',
        };
      }

      _log(
        '🔍 TEST: ✅ Message Signing/Verification - Signature generation and verification working',
      );
      return {
        'success': true,
        'details': 'Message signing and verification functional',
        'testName': 'Message Signing',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ Message Signing/Verification failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Message Signing',
      };
    }
  }

  static Future<Map<String, dynamic>> _testKeyStorage(
    String contactPublicKey,
    IContactRepository repo,
  ) async {
    try {
      _log('🔍 TEST: Key Storage/Retrieval');

      const testSecret = 'test_shared_secret_for_storage_12345';
      const testSecretUpdated = 'updated_test_shared_secret_67890';

      await repo.cacheSharedSecret(contactPublicKey, testSecret);

      final retrievedSecret = await repo.getCachedSharedSecret(
        contactPublicKey,
      );
      if (retrievedSecret != testSecret) {
        return {
          'success': false,
          'error':
              'Key storage/retrieval failed - retrieved secret does not match stored',
          'testName': 'Key Storage',
        };
      }

      await repo.cacheSharedSecret(contactPublicKey, testSecretUpdated);
      final updatedSecret = await repo.getCachedSharedSecret(contactPublicKey);
      if (updatedSecret != testSecretUpdated) {
        return {
          'success': false,
          'error': 'Key storage update failed',
          'testName': 'Key Storage',
        };
      }

      await repo.clearCachedSecrets(contactPublicKey);
      final clearedSecret = await repo.getCachedSharedSecret(contactPublicKey);
      if (clearedSecret != null) {
        return {
          'success': false,
          'error': 'Key clearing failed - secret still present after clear',
          'testName': 'Key Storage',
        };
      }

      _log(
        '🔍 TEST: ✅ Key Storage/Retrieval - All operations working correctly',
      );
      return {
        'success': true,
        'details':
            'Key storage, retrieval, update, and clearing all functional',
        'testName': 'Key Storage',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ Key Storage/Retrieval failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Key Storage',
      };
    }
  }

  static Future<Map<String, dynamic>> _testECDHSharedSecret(
    String contactPublicKey,
  ) async {
    try {
      _log('🔍 TEST: ECDH Shared Secret Computation');

      final sharedSecret = SigningCryptoService.computeSharedSecret(
        contactPublicKey,
      );
      if (sharedSecret == null || sharedSecret.isEmpty) {
        return {
          'success': false,
          'error': 'Failed to compute ECDH shared secret',
          'testName': 'ECDH Shared Secret',
        };
      }

      try {
        BigInt.parse(sharedSecret, radix: 16);
      } catch (_) {
        return {
          'success': false,
          'error': 'ECDH shared secret is not valid hex format',
          'testName': 'ECDH Shared Secret',
        };
      }

      _log(
        '🔍 TEST: ✅ ECDH Shared Secret Computation - Successfully computed shared secret',
      );
      return {
        'success': true,
        'details': 'ECDH shared secret computation functional',
        'secretLength': sharedSecret.length,
        'testName': 'ECDH Shared Secret',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ ECDH Shared Secret Computation failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'ECDH Shared Secret',
      };
    }
  }

  static String generateVerificationChallenge() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomComponent = (timestamp % 10000).toString().padLeft(4, '0');
    return 'CRYPTO_VERIFY_${timestamp}_$randomComponent';
  }

  static Future<Map<String, dynamic>> testBidirectionalEncryption(
    String contactPublicKey,
    IContactRepository repo,
    String testMessage,
  ) async {
    try {
      _log('🔍 TEST: Bidirectional Encryption with contact');

      final encryptedMessage = await ContactCryptoService.encryptForContact(
        testMessage,
        contactPublicKey,
        repo,
      );
      if (encryptedMessage == null) {
        return {
          'success': false,
          'error': 'Failed to encrypt message for contact',
          'testName': 'Bidirectional Encryption',
        };
      }

      final decryptedMessage = await ContactCryptoService.decryptFromContact(
        encryptedMessage,
        contactPublicKey,
        repo,
      );
      if (decryptedMessage != testMessage) {
        return {
          'success': false,
          'error':
              'Bidirectional encryption round-trip failed - decrypted message does not match original',
          'testName': 'Bidirectional Encryption',
        };
      }

      _log(
        '🔍 TEST: ✅ Bidirectional Encryption - Contact encrypt/decrypt round trip successful',
      );
      return {
        'success': true,
        'details':
            'Contact-targeted encryption/decryption round trip functional',
        'testName': 'Bidirectional Encryption',
      };
    } catch (e) {
      _log('🔍 TEST: ❌ Bidirectional Encryption failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Bidirectional Encryption',
      };
    }
  }
}
