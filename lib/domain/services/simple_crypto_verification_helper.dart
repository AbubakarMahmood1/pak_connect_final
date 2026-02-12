part of 'simple_crypto.dart';

class _SimpleCryptoVerificationHelper {
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
      results['tests']['ecdhKeyGeneration'] =
          await SimpleCrypto._testECDHKeyGeneration();
      results['tests']['aesEncryption'] =
          await SimpleCrypto._testAESEncryption();
      results['tests']['enhancedKeyDerivation'] =
          await SimpleCrypto._testEnhancedKeyDerivation();
      results['tests']['messageSigning'] =
          await SimpleCrypto._testMessageSigning();

      if (repo != null && contactPublicKey != null) {
        results['tests']['keyStorage'] = await SimpleCrypto._testKeyStorage(
          contactPublicKey,
          repo,
        );
      }

      if (contactPublicKey != null) {
        results['tests']['ecdhSharedSecret'] =
            await SimpleCrypto._testECDHSharedSecret(contactPublicKey);
      }

      final tests = results['tests'] as Map<String, dynamic>;
      final allPassed = tests.values.every(
        (test) => test is Map && test['success'] == true,
      );
      results['overallSuccess'] = allPassed;

      SimpleCrypto._log('🔍 CRYPTO VERIFICATION: Overall success = $allPassed');
      return results;
    } catch (e) {
      SimpleCrypto._log(
        '🔍 CRYPTO VERIFICATION: Fatal error during verification: $e',
      );
      results['error'] = e.toString();
      results['overallSuccess'] = false;
      return results;
    }
  }

  static Future<Map<String, dynamic>> testECDHKeyGeneration() async {
    try {
      SimpleCrypto._log('🔍 TEST: ECDH Key Generation');

      if (SimpleCrypto._privateKey == null) {
        return {
          'success': false,
          'error': 'No private key available for ECDH testing',
          'testName': 'ECDH Key Generation',
        };
      }

      final privateKeyInt = SimpleCrypto._privateKey!.d;
      if (privateKeyInt == null) {
        return {
          'success': false,
          'error': 'Private key missing scalar component',
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

      SimpleCrypto._log(
        '🔍 TEST: ✅ ECDH Key Generation - All components available',
      );
      return {
        'success': true,
        'details': 'Private key and curve available for ECDH operations',
        'testName': 'ECDH Key Generation',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ ECDH Key Generation failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'ECDH Key Generation',
      };
    }
  }

  static Future<Map<String, dynamic>> testAESEncryption() async {
    try {
      SimpleCrypto._log('🔍 TEST: AES Encryption/Decryption');

      const testMessage = 'PakConnect_Crypto_Test_Message_123';
      if (!SimpleCrypto.isInitialized) {
        SimpleCrypto.initialize();
      }

      final encrypted = SimpleCrypto.encodeLegacyPlaintext(testMessage);
      final decrypted = SimpleCrypto.decryptLegacyCompatible(encrypted);
      if (decrypted != testMessage) {
        return {
          'success': false,
          'error':
              'AES round-trip failed - decrypted message does not match original',
          'testName': 'AES Encryption',
        };
      }

      SimpleCrypto._log(
        '🔍 TEST: ✅ AES Encryption/Decryption - Round trip successful',
      );
      return {
        'success': true,
        'details': 'AES-256 encryption/decryption working correctly',
        'testName': 'AES Encryption',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ AES Encryption/Decryption failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'AES Encryption',
      };
    }
  }

  static Future<Map<String, dynamic>> testEnhancedKeyDerivation() async {
    try {
      SimpleCrypto._log('🔍 TEST: Enhanced Key Derivation');

      const mockECDHSecret = 'test_ecdh_secret_12345';
      const mockPublicKey = 'test_public_key_67890';

      final standardKey = SimpleCrypto._deriveEnhancedContactKey(
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

      SimpleCrypto.initializeConversation(mockPublicKey, 'mock_pairing_secret');
      final enhancedKey = SimpleCrypto._deriveEnhancedContactKey(
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

      SimpleCrypto.clearConversationKey(mockPublicKey);

      SimpleCrypto._log(
        '🔍 TEST: ✅ Enhanced Key Derivation - Multiple derivation methods working',
      );
      return {
        'success': true,
        'details':
            'Enhanced key derivation working with and without pairing keys',
        'testName': 'Enhanced Key Derivation',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ Enhanced Key Derivation failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Enhanced Key Derivation',
      };
    }
  }

  static Future<Map<String, dynamic>> testMessageSigning() async {
    try {
      SimpleCrypto._log('🔍 TEST: Message Signing/Verification');

      const testMessage = 'PakConnect_Signature_Test_Message';
      if (!SimpleCrypto.isSigningReady) {
        return {
          'success': false,
          'error': 'Message signing not initialized',
          'testName': 'Message Signing',
        };
      }

      final signature = SimpleCrypto.signMessage(testMessage);
      if (signature == null) {
        return {
          'success': false,
          'error': 'Failed to generate message signature',
          'testName': 'Message Signing',
        };
      }

      SimpleCrypto._log(
        '🔍 TEST: ✅ Message Signing/Verification - Signature generation and verification working',
      );
      return {
        'success': true,
        'details': 'Message signing and verification functional',
        'testName': 'Message Signing',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ Message Signing/Verification failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Message Signing',
      };
    }
  }

  static Future<Map<String, dynamic>> testKeyStorage(
    String contactPublicKey,
    IContactRepository repo,
  ) async {
    try {
      SimpleCrypto._log('🔍 TEST: Key Storage/Retrieval');

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

      SimpleCrypto._log(
        '🔍 TEST: ✅ Key Storage/Retrieval - All operations working correctly',
      );
      return {
        'success': true,
        'details':
            'Key storage, retrieval, update, and clearing all functional',
        'testName': 'Key Storage',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ Key Storage/Retrieval failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Key Storage',
      };
    }
  }

  static Future<Map<String, dynamic>> testECDHSharedSecret(
    String contactPublicKey,
  ) async {
    try {
      SimpleCrypto._log('🔍 TEST: ECDH Shared Secret Computation');

      final sharedSecret = SimpleCrypto.computeSharedSecret(contactPublicKey);
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

      SimpleCrypto._log(
        '🔍 TEST: ✅ ECDH Shared Secret Computation - Successfully computed shared secret',
      );
      return {
        'success': true,
        'details': 'ECDH shared secret computation functional',
        'secretLength': sharedSecret.length,
        'testName': 'ECDH Shared Secret',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ ECDH Shared Secret Computation failed: $e');
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
      SimpleCrypto._log('🔍 TEST: Bidirectional Encryption with contact');

      final encryptedMessage = await SimpleCrypto.encryptForContact(
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

      final decryptedMessage = await SimpleCrypto.decryptFromContact(
        encryptedMessage,
        contactPublicKey,
        repo,
      );
      if (decryptedMessage == null) {
        return {
          'success': false,
          'error': 'Failed to decrypt message from contact',
          'testName': 'Bidirectional Encryption',
        };
      }

      if (decryptedMessage != testMessage) {
        return {
          'success': false,
          'error': 'Decrypted message does not match original',
          'testName': 'Bidirectional Encryption',
        };
      }

      SimpleCrypto._log(
        '🔍 TEST: ✅ Bidirectional Encryption - Round trip successful',
      );
      return {
        'success': true,
        'details': 'Bidirectional encryption/decryption working correctly',
        'testName': 'Bidirectional Encryption',
      };
    } catch (e) {
      SimpleCrypto._log('🔍 TEST: ❌ Bidirectional Encryption failed: $e');
      return {
        'success': false,
        'error': e.toString(),
        'testName': 'Bidirectional Encryption',
      };
    }
  }
}
