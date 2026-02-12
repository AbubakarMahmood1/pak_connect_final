part of 'simple_crypto.dart';

class _SimpleCryptoContactHelper {
  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    // Mandatory key state synchronization before encryption.
    await ensureConversationKeySync(contactPublicKey, contactRepo);

    // Get cached or compute shared secret.
    final sharedSecret = await getCachedOrComputeSharedSecret(
      contactPublicKey,
      contactRepo,
    );
    if (sharedSecret == null) return null;

    try {
      final truncatedPublicKey = contactPublicKey.length > 16
          ? contactPublicKey.shortId()
          : contactPublicKey;
      SimpleCrypto._log(
        '🔧 ECDH ENCRYPT DEBUG: Starting encryption for $truncatedPublicKey...',
      );

      final enhancedSecret = deriveEnhancedContactKey(
        sharedSecret,
        contactPublicKey,
      );
      final keyBytes = sha256.convert(utf8.encode(enhancedSecret)).bytes;
      final key = Key(Uint8List.fromList(keyBytes));

      // SECURITY FIX: Use random IV for each message.
      final iv = IV.fromSecureRandom(16);
      final encrypter = Encrypter(AES(key));
      final encrypted = encrypter.encrypt(plaintext, iv: iv);

      // Prepend IV to ciphertext.
      final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
      final result = base64.encode(combined);

      final pairingKey = SimpleCrypto._getPairingKeyForContact(
        contactPublicKey,
      );
      if (pairingKey != null) {
        SimpleCrypto._log(
          '✅ ENHANCED ECDH encryption successful (ECDH + Pairing)',
        );
      } else {
        SimpleCrypto._log('✅ STANDARD ECDH encryption successful (ECDH only)');
      }

      // Add v2 wire format prefix.
      return '${SimpleCrypto._wireFormatV2}$result';
    } catch (e) {
      SimpleCrypto._log('❌ Enhanced ECDH encryption failed: $e');
      return null;
    }
  }

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    // Mandatory key state synchronization before decryption.
    await ensureConversationKeySync(contactPublicKey, contactRepo);

    final sharedSecret = await getCachedOrComputeSharedSecret(
      contactPublicKey,
      contactRepo,
    );
    if (sharedSecret == null) return null;

    try {
      final truncatedPublicKey = contactPublicKey.length > 16
          ? contactPublicKey.shortId()
          : contactPublicKey;
      SimpleCrypto._log(
        '🔧 ECDH DECRYPT DEBUG: Starting decryption for $truncatedPublicKey...',
      );

      final enhancedSecret = deriveEnhancedContactKey(
        sharedSecret,
        contactPublicKey,
      );
      final keyBytes = sha256.convert(utf8.encode(enhancedSecret)).bytes;
      final key = Key(Uint8List.fromList(keyBytes));

      String ciphertext = encryptedBase64;
      var isV2Format = false;
      if (encryptedBase64.startsWith(SimpleCrypto._wireFormatV2)) {
        ciphertext = encryptedBase64.substring(
          SimpleCrypto._wireFormatV2.length,
        );
        isV2Format = true;
      }

      final encrypter = Encrypter(AES(key));
      final decrypted = isV2Format
          ? SimpleCrypto._decryptV2Format(encrypter, ciphertext)
          : SimpleCrypto._decryptLegacyFormat(
              encrypter,
              ciphertext,
              enhancedSecret,
            );

      final pairingKey = SimpleCrypto._getPairingKeyForContact(
        contactPublicKey,
      );
      if (pairingKey != null) {
        SimpleCrypto._log(
          '✅ ENHANCED ECDH decryption successful (ECDH + Pairing)',
        );
      } else {
        SimpleCrypto._log('✅ STANDARD ECDH decryption successful (ECDH only)');
      }

      return decrypted;
    } catch (e) {
      SimpleCrypto._log('❌ Enhanced ECDH decryption failed: $e');
      return null;
    }
  }

  static String decryptV2Format(Encrypter encrypter, String ciphertext) {
    final combined = base64.decode(ciphertext);
    if (combined.length < 16) {
      throw ArgumentError('Invalid v2 ciphertext: too short');
    }
    final iv = IV(Uint8List.fromList(combined.sublist(0, 16)));
    final encryptedBytes = Encrypted(Uint8List.fromList(combined.sublist(16)));
    return encrypter.decrypt(encryptedBytes, iv: iv);
  }

  static String decryptLegacyFormat(
    Encrypter encrypter,
    String ciphertext,
    String enhancedSecret,
  ) {
    // Legacy IV derivation (for backward compatibility).
    final ivSeed = '${enhancedSecret}_IV_DERIVATION';
    final ivBytes = sha256.convert(utf8.encode(ivSeed)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));

    if (kDebugMode) {
      SimpleCrypto._log(
        '⚠️ Decrypting legacy ECDH message with deterministic IV',
      );
    }

    final encrypted = Encrypted.fromBase64(ciphertext);
    return encrypter.decrypt(encrypted, iv: iv);
  }

  static String deriveEnhancedContactKey(
    String ecdhSecret,
    String contactPublicKey,
  ) {
    final pairingKey = SimpleCrypto._getPairingKeyForContact(contactPublicKey);

    if (pairingKey != null) {
      // ENHANCED SECURITY: Combine ECDH + Pairing for dual-layer protection.
      final sortedSecrets = [ecdhSecret, pairingKey]..sort();
      final combinedSecret = sortedSecrets.join('_COMBINED_');

      SimpleCrypto._log(
        '🔧 ENHANCED SECURITY: Using ECDH + Pairing key derivation',
      );
      return '${combinedSecret}_ENHANCED_ECDH_AES_SALT';
    } else {
      // FALLBACK: ECDH only.
      SimpleCrypto._log('🔧 STANDARD ECDH: Using ECDH-only key derivation');
      return '${ecdhSecret}_ECDH_AES_SALT';
    }
  }

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    // Check memory cache first (fastest).
    if (SimpleCrypto._sharedSecretCache.containsKey(contactPublicKey)) {
      return SimpleCrypto._sharedSecretCache[contactPublicKey];
    }

    // Check secure storage cache.
    final cachedSecret = await contactRepo.getCachedSharedSecret(
      contactPublicKey,
    );
    if (cachedSecret != null) {
      SimpleCrypto._log('Loaded shared secret from secure storage');
      SimpleCrypto._sharedSecretCache[contactPublicKey] = cachedSecret;
      return cachedSecret;
    }

    // Compute new shared secret (expensive).
    SimpleCrypto._log(
      'Computing new ECDH shared secret - will cache for future use',
    );
    final newSecret = SimpleCrypto.computeSharedSecret(contactPublicKey);
    if (newSecret != null) {
      SimpleCrypto._sharedSecretCache[contactPublicKey] = newSecret;
      await contactRepo.cacheSharedSecret(contactPublicKey, newSecret);
      SimpleCrypto._log('ECDH shared secret computed and cached');
    }

    return newSecret;
  }

  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) async {
    if (!SimpleCrypto.hasConversationKey(publicKey)) {
      final cachedSecret = await repo.getCachedSharedSecret(publicKey);
      if (cachedSecret != null) {
        await restoreConversationKey(publicKey, cachedSecret);
        SimpleCrypto._log(
          '🔄 SYNC: Restored conversation key for ${_safeTruncate(publicKey, 8)}...',
        );
      }
    }
  }

  static Future<void> restoreConversationKey(
    String publicKey,
    String cachedSecret,
  ) async {
    try {
      final keyBytes = sha256
          .convert(utf8.encode('${cachedSecret}CONVERSATION_KEY'))
          .bytes;
      final key = Key(Uint8List.fromList(keyBytes));

      final ivBytes = sha256
          .convert(utf8.encode('${cachedSecret}CONVERSATION_IV'))
          .bytes
          .sublist(0, 16);
      final iv = IV(Uint8List.fromList(ivBytes));

      SimpleCrypto._conversationEncrypters[publicKey] = Encrypter(AES(key));
      SimpleCrypto._conversationIVs[publicKey] = iv;

      SimpleCrypto._log(
        'Restored conversation key for ${_safeTruncate(publicKey, 8)}...',
      );
    } catch (e) {
      SimpleCrypto._log('Failed to restore conversation key: $e');
    }
  }
}
