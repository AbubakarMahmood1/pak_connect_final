import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import '../interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

part 'simple_crypto_contact_helper.dart';
part 'simple_crypto_verification_helper.dart';

/// 🔧 UTILITY: Safe string truncation to prevent RangeError
String _safeTruncate(String? input, int maxLength, {String fallback = "NULL"}) {
  if (input == null || input.isEmpty) return fallback;
  if (input.length <= maxLength) return input;
  return input.substring(0, maxLength);
}

class SimpleCrypto {
  static final _logger = Logger('SimpleCrypto');
  static Encrypter? _encrypter;
  static IV? _iv;
  static ECPrivateKey? _privateKey;
  static final Map<String, String> _sharedSecretCache = {};
  static final Map<String, Encrypter> _conversationEncrypters = {};
  static final Map<String, IV> _conversationIVs = {};
  static int _deprecatedEncryptWrapperCallCount = 0;
  static int _deprecatedDecryptWrapperCallCount = 0;

  static void _log(Object? message, {Level level = Level.FINE}) {
    _logger.log(level, message);
  }

  // Wire format version prefix
  static const String _wireFormatV2 = 'v2:';
  static const String _legacyPassphraseFromDefine = String.fromEnvironment(
    'PAKCONNECT_LEGACY_PASSPHRASE',
    defaultValue: '',
  );

  // Initialize (legacy - kept for backward compatibility)
  static void initialize() {
    // Reset legacy decryptor state first.
    _encrypter = null;
    _iv = null;

    // Security hardening: legacy passphrase is not hardcoded.
    // To decrypt old payloads, provide it at build time:
    // --dart-define=PAKCONNECT_LEGACY_PASSPHRASE=...
    if (_legacyPassphraseFromDefine.isEmpty) {
      if (kDebugMode) {
        _log(
          '⚠️ SimpleCrypto legacy decryptor disabled '
          '(PAKCONNECT_LEGACY_PASSPHRASE not set)',
        );
      }
      return;
    }

    final keyBytes = sha256
        .convert(utf8.encode('${_legacyPassphraseFromDefine}BLE_CHAT_SALT'))
        .bytes;
    final key = Key(Uint8List.fromList(keyBytes));

    final ivBytes = sha256
        .convert(utf8.encode('${_legacyPassphraseFromDefine}BLE_CHAT_IV'))
        .bytes
        .sublist(0, 16);
    _iv = IV(Uint8List.fromList(ivBytes));

    // Setup encrypter for legacy decryption only
    _encrypter = Encrypter(AES(key));

    if (kDebugMode) {
      _log('⚠️ SimpleCrypto initialized in LEGACY MODE (decryption-only)');
    }
  }

  // ========== DEPRECATED GLOBAL ENCRYPTION ==========
  // 🚨 SECURITY WARNING: These methods previously used a hardcoded passphrase
  // and are now deprecated. They return plaintext markers to avoid silent insecurity.

  static void _recordDeprecatedWrapperUse(String wrapperName) {
    if (wrapperName == 'encrypt') {
      _deprecatedEncryptWrapperCallCount++;
    } else if (wrapperName == 'decrypt') {
      _deprecatedDecryptWrapperCallCount++;
    }

    if (kDebugMode) {
      _log(
        '⚠️ SECURITY WARNING: Deprecated SimpleCrypto.$wrapperName() wrapper '
        'invoked. Migrate caller to explicit legacy APIs.',
      );
    }
  }

  static Map<String, int> getDeprecatedWrapperUsageCounts() => {
    'encrypt': _deprecatedEncryptWrapperCallCount,
    'decrypt': _deprecatedDecryptWrapperCallCount,
    'total':
        _deprecatedEncryptWrapperCallCount + _deprecatedDecryptWrapperCallCount,
  };

  static void resetDeprecatedWrapperUsageCounts() {
    _deprecatedEncryptWrapperCallCount = 0;
    _deprecatedDecryptWrapperCallCount = 0;
  }

  /// Explicit legacy compatibility encoder.
  ///
  /// This does NOT encrypt. It marks plaintext so old pipelines can distinguish
  /// intentionally unencrypted payloads from encrypted legacy payloads.
  static String encodeLegacyPlaintext(String plaintext) {
    if (kDebugMode) {
      _log(
        '⚠️ SECURITY WARNING: encodeLegacyPlaintext() called - '
        'returning plaintext marker (NO ENCRYPTION)',
      );
    }
    return 'PLAINTEXT:$plaintext';
  }

  /// Explicit legacy/global decryption compatibility path.
  ///
  /// Supports:
  /// - `PLAINTEXT:` marker payloads
  /// - historical global AES payloads (when legacy keys are initialized)
  ///
  /// Throws when decryption is not possible so callers can fail closed.
  static String decryptLegacyCompatible(String encryptedBase64) {
    // Handle plaintext marker
    if (encryptedBase64.startsWith('PLAINTEXT:')) {
      return encryptedBase64.substring('PLAINTEXT:'.length);
    }

    if (_encrypter == null || _iv == null) {
      initialize();
    }

    // Legacy decryption for backward compatibility (old messages)
    if (_encrypter != null && _iv != null) {
      try {
        final encrypted = Encrypted.fromBase64(encryptedBase64);
        return _encrypter!.decrypt(encrypted, iv: _iv!);
      } catch (e) {
        if (kDebugMode) {
          _log('⚠️ Legacy decryption failed: $e');
        }
        // Throw exception instead of returning ciphertext
        // This ensures SecurityManager can trigger resync on failure
        throw Exception('Legacy decryption failed: $e');
      }
    }

    // No decryption possible, throw exception
    if (kDebugMode) {
      _log('⚠️ Cannot decrypt: legacy decryptor unavailable');
    }
    throw Exception('Cannot decrypt: legacy decryptor unavailable');
  }

  /// ⚠️ DEPRECATED: Global encryption with hardcoded key is insecure
  /// Returns plaintext with PLAINTEXT: prefix to make it obvious no encryption is applied
  @Deprecated(
    'Use proper encryption methods (Noise, ECDH, or Pairing). '
    'This method does NOT provide real security.',
  )
  static String encrypt(String plaintext) {
    _recordDeprecatedWrapperUse('encrypt');
    return encodeLegacyPlaintext(plaintext);
  }

  /// ⚠️ DEPRECATED: Global decryption for legacy compatibility
  /// Handles both PLAINTEXT: prefix and legacy encrypted format
  /// Throws exception on decryption failure to ensure proper error handling
  @Deprecated('Use proper decryption methods (Noise, ECDH, or Pairing)')
  static String decrypt(String encryptedBase64) {
    _recordDeprecatedWrapperUse('decrypt');
    return decryptLegacyCompatible(encryptedBase64);
  }

  // Check if crypto is ready
  static bool get isInitialized => _encrypter != null;

  // Clear crypto (for logout/reset)
  static void clear() {
    _encrypter = null;
    _iv = null;
    _privateKey = null;
  }

  static void initializeConversation(String publicKey, String sharedSecret) {
    // Generate conversation-specific key (IV is now random per message)
    final keyBytes = sha256
        .convert(utf8.encode('${sharedSecret}CONVERSATION_KEY'))
        .bytes;
    final key = Key(Uint8List.fromList(keyBytes));

    _conversationEncrypters[publicKey] = Encrypter(AES(key));

    // Store legacy IV for backward compatibility with old messages
    final ivBytes = sha256
        .convert(utf8.encode('${sharedSecret}CONVERSATION_IV'))
        .bytes
        .sublist(0, 16);
    _conversationIVs[publicKey] = IV(Uint8List.fromList(ivBytes));

    if (kDebugMode) {
      _log(
        'Initialized conversation crypto for ${_safeTruncate(publicKey, 8)}...',
      );
    }
  }

  // Add conversation-aware encrypt method
  static String encryptForConversation(String plaintext, String publicKey) {
    final encrypter = _conversationEncrypters[publicKey];

    if (encrypter == null) {
      throw StateError('No conversation key for $publicKey');
    }

    // 🔒 SECURITY FIX: Use random IV for each message
    final iv = IV.fromSecureRandom(16);
    if (plaintext.isEmpty) {
      // Encode empty payload as IV-only v2 frame to keep wire format valid.
      return '$_wireFormatV2${base64.encode(iv.bytes)}';
    }
    final encrypted = encrypter.encrypt(plaintext, iv: iv);

    // Prepend IV to ciphertext and encode the whole thing
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    final result = base64.encode(combined);

    // Add v2 wire format prefix
    return '$_wireFormatV2$result';
  }

  // Add conversation-aware decrypt method
  static String decryptFromConversation(
    String encryptedBase64,
    String publicKey,
  ) {
    final encrypter = _conversationEncrypters[publicKey];

    if (encrypter == null) {
      throw StateError('No conversation key for $publicKey');
    }

    // Check for wire format version
    String ciphertext = encryptedBase64;
    bool isV2Format = false;

    if (encryptedBase64.startsWith(_wireFormatV2)) {
      ciphertext = encryptedBase64.substring(_wireFormatV2.length);
      isV2Format = true;
    }

    if (isV2Format) {
      // 🔒 NEW FORMAT: Extract IV from first 16 bytes
      final combined = base64.decode(ciphertext);
      if (combined.length < 16) {
        throw ArgumentError('Invalid v2 ciphertext: too short');
      }
      if (combined.length == 16) {
        return '';
      }
      final iv = IV(Uint8List.fromList(combined.sublist(0, 16)));
      final encryptedBytes = Encrypted(
        Uint8List.fromList(combined.sublist(16)),
      );
      return encrypter.decrypt(encryptedBytes, iv: iv);
    } else {
      // ⚠️ LEGACY FORMAT: Use deterministic IV (for backward compatibility)
      // This should only be used for old messages
      final legacyIV = _conversationIVs[publicKey];
      if (legacyIV == null) {
        throw StateError(
          'No legacy IV for $publicKey - cannot decrypt old format message',
        );
      }
      if (kDebugMode) {
        _log(
          '⚠️ Decrypting legacy conversation message for ${_safeTruncate(publicKey, 8)}...',
        );
      }
      final encrypted = Encrypted.fromBase64(ciphertext);
      return encrypter.decrypt(encrypted, iv: legacyIV);
    }
  }

  static bool hasConversationKey(String publicKey) {
    return _conversationEncrypters.containsKey(publicKey);
  }

  // === MESSAGE SIGNING (Direct Constructor Approach) ===

  static void initializeSigning(String privateKeyHex, String publicKeyHex) {
    try {
      // Parse private key
      final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);

      _privateKey = ECPrivateKey(privateKeyInt, ECCurve_secp256r1());

      // Parse public key
      final publicKeyBytes = _hexToBytes(publicKeyHex);

      final curve = ECCurve_secp256r1();

      curve.curve.decodePoint(publicKeyBytes);

      _log('🟢 INIT SUCCESS: Message signing initialized completely');
    } catch (e, stackTrace) {
      _log('🔴 INIT FAIL: Exception during initialization');
      _log('🔴 INIT FAIL: Error type: ${e.runtimeType}');
      _log('🔴 INIT FAIL: Error message: $e');
      _log('🔴 INIT FAIL: Stack trace first 3 lines:');
      final stackLines = stackTrace.toString().split('\n');
      for (int i = 0; i < 3 && i < stackLines.length; i++) {
        _log('🔴 INIT STACK $i: ${stackLines[i]}');
      }
      _privateKey = null;
    }
  }

  // Direct constructor approach (NO registry)
  static String? signMessage(String content) {
    if (_privateKey == null) {
      _log('🔴 SIGN FAIL: No private key available');
      return null;
    }

    try {
      // Step 2: Create signer
      final signer = ECDSASigner(SHA256Digest());

      // Step 3: Create our own SecureRandom (bypass registry)
      final secureRandom = FortunaRandom();

      // Seed it properly with cryptographically secure randomness
      final random = Random.secure();
      final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      secureRandom.seed(KeyParameter(seed));

      // Step 4: Initialize with both private key AND SecureRandom
      final privateKeyParam = PrivateKeyParameter(_privateKey!);
      final params = ParametersWithRandom(privateKeyParam, secureRandom);

      signer.init(true, params);

      // Step 5: Prepare message
      final messageBytes = utf8.encode(content);

      // Step 6: Generate signature
      final signature = signer.generateSignature(messageBytes) as ECSignature;

      // Step 7: Encode signature
      final rHex = signature.r.toRadixString(16);
      final sHex = signature.s.toRadixString(16);
      final result = '$rHex:$sHex';

      return result;
    } catch (e, stackTrace) {
      _log('🔴 SIGN FAIL: Exception caught');
      _log('🔴 SIGN FAIL: Error type: ${e.runtimeType}');
      _log('🔴 SIGN FAIL: Error message: $e');
      _log('🔴 SIGN FAIL: Stack trace first 3 lines:');
      final stackLines = stackTrace.toString().split('\n');
      for (int i = 0; i < 3 && i < stackLines.length; i++) {
        _log('🔴 STACK $i: ${stackLines[i]}');
      }
      return null;
    }
  }

  // Direct constructor verification
  static bool verifySignature(
    String content,
    String signatureHex,
    String senderPublicKeyHex,
  ) {
    try {
      // Parse sender's public key
      final publicKeyBytes = _hexToBytes(senderPublicKeyHex);
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(publicKeyBytes);
      final publicKey = ECPublicKey(point, curve);

      // Parse signature
      final sigParts = signatureHex.split(':');
      final r = BigInt.parse(sigParts[0], radix: 16);
      final s = BigInt.parse(sigParts[1], radix: 16);
      final signature = ECSignature(r, s);

      // Direct instantiation - no registry
      final verifier = ECDSASigner(SHA256Digest());
      verifier.init(false, PublicKeyParameter(publicKey));

      final messageBytes = utf8.encode(content);
      return verifier.verifySignature(messageBytes, signature);
    } catch (e) {
      _log('Signature verification failed: $e');
      return false;
    }
  }

  // Helper method
  static Uint8List _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(result);
  }

  // Check if signing is ready
  static bool get isSigningReady => _privateKey != null;

  // === ECDH KEY EXCHANGE ===
  static String? computeSharedSecret(String theirPublicKeyHex) {
    if (_privateKey == null) {
      _log('Cannot compute shared secret - no private key');
      return null;
    }

    try {
      // Parse their public key
      final theirPublicKeyBytes = _hexToBytes(theirPublicKeyHex);
      final curve = ECCurve_secp256r1();
      final theirPoint = curve.curve.decodePoint(theirPublicKeyBytes);
      final theirPublicKey = ECPublicKey(theirPoint, curve);

      // ECDH computation: myPrivateKey * theirPublicKey
      final sharedPoint = theirPublicKey.Q! * _privateKey!.d!;
      final sharedSecret = sharedPoint!.x!.toBigInteger()!.toRadixString(16);

      return sharedSecret;
    } catch (e) {
      _log('🔴 ECDH computation failed: $e');
      return null;
    }
  }

  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => _SimpleCryptoContactHelper.encryptForContact(
    plaintext,
    contactPublicKey,
    contactRepo,
  );

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => _SimpleCryptoContactHelper.decryptFromContact(
    encryptedBase64,
    contactPublicKey,
    contactRepo,
  );

  /// Decrypt v2 format (random IV prepended)
  static String _decryptV2Format(Encrypter encrypter, String ciphertext) =>
      _SimpleCryptoContactHelper.decryptV2Format(encrypter, ciphertext);

  /// Decrypt legacy format (deterministic IV for backward compatibility)
  static String _decryptLegacyFormat(
    Encrypter encrypter,
    String ciphertext,
    String enhancedSecret,
  ) => _SimpleCryptoContactHelper.decryptLegacyFormat(
    encrypter,
    ciphertext,
    enhancedSecret,
  );

  // Get pairing key for a contact if available
  static String? _getPairingKeyForContact(String contactPublicKey) {
    // Use actual conversation secret instead of static key
    final conversationKey = _sharedSecretCache[contactPublicKey];
    if (conversationKey != null &&
        _conversationEncrypters.containsKey(contactPublicKey)) {
      return "PAIRED_$conversationKey";
    }
    return null;
  }

  static void clearConversationKey(String publicKey) {
    _conversationEncrypters.remove(publicKey);
    _conversationIVs.remove(publicKey);
    _log('Cleared conversation key for ${_safeTruncate(publicKey, 8)}...');
  }

  /// Clear all conversation keys (for complete reset)
  static void clearAllConversationKeys() {
    _conversationEncrypters.clear();
    _conversationIVs.clear();
    _log('Cleared all conversation keys');
  }

  /// Enhanced key derivation: ECDH + Pairing Key (when both available)
  /// 🔒 SECURITY FIX: Removed hardcoded string constant
  static String _deriveEnhancedContactKey(
    String ecdhSecret,
    String contactPublicKey,
  ) => _SimpleCryptoContactHelper.deriveEnhancedContactKey(
    ecdhSecret,
    contactPublicKey,
  );

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => _SimpleCryptoContactHelper.getCachedOrComputeSharedSecret(
    contactPublicKey,
    contactRepo,
  );

  /// Ensure conversation key synchronization to prevent race conditions
  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) => _SimpleCryptoContactHelper.ensureConversationKeySync(publicKey, repo);

  static Future<void> restoreConversationKey(
    String publicKey,
    String cachedSecret,
  ) => _SimpleCryptoContactHelper.restoreConversationKey(
    publicKey,
    cachedSecret,
  );

  // === CRYPTO STANDARDS VERIFICATION ===

  /// Comprehensive crypto standards verification
  static Future<Map<String, dynamic>> verifyCryptoStandards(
    String? contactPublicKey,
    IContactRepository? repo,
  ) => _SimpleCryptoVerificationHelper.verifyCryptoStandards(
    contactPublicKey,
    repo,
  );

  /// Test ECDH key generation capability
  static Future<Map<String, dynamic>> _testECDHKeyGeneration() =>
      _SimpleCryptoVerificationHelper.testECDHKeyGeneration();

  /// Test AES encryption/decryption functionality
  static Future<Map<String, dynamic>> _testAESEncryption() =>
      _SimpleCryptoVerificationHelper.testAESEncryption();

  /// Test enhanced key derivation functionality
  static Future<Map<String, dynamic>> _testEnhancedKeyDerivation() =>
      _SimpleCryptoVerificationHelper.testEnhancedKeyDerivation();

  /// Test message signing and verification
  static Future<Map<String, dynamic>> _testMessageSigning() =>
      _SimpleCryptoVerificationHelper.testMessageSigning();

  /// Test key storage and retrieval
  static Future<Map<String, dynamic>> _testKeyStorage(
    String contactPublicKey,
    IContactRepository repo,
  ) => _SimpleCryptoVerificationHelper.testKeyStorage(contactPublicKey, repo);

  /// Test ECDH shared secret computation
  static Future<Map<String, dynamic>> _testECDHSharedSecret(
    String contactPublicKey,
  ) => _SimpleCryptoVerificationHelper.testECDHSharedSecret(contactPublicKey);

  /// Generate a test encrypted message for verification challenge
  static String generateVerificationChallenge() =>
      _SimpleCryptoVerificationHelper.generateVerificationChallenge();

  /// Test bidirectional encryption with a contact
  static Future<Map<String, dynamic>> testBidirectionalEncryption(
    String contactPublicKey,
    IContactRepository repo,
    String testMessage,
  ) => _SimpleCryptoVerificationHelper.testBidirectionalEncryption(
    contactPublicKey,
    repo,
    testMessage,
  );
}
