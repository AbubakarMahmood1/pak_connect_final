import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

import 'conversation_crypto_service.dart';
import 'crypto_wire_format.dart';
import 'signing_crypto_service.dart';

class ContactCryptoService {
  static final _logger = Logger('ContactCryptoService');
  static final Map<String, String> _sharedSecretCache = {};

  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    await ensureConversationKeySync(contactPublicKey, contactRepo);

    final sharedSecret = await getCachedOrComputeSharedSecret(
      contactPublicKey,
      contactRepo,
    );
    if (sharedSecret == null) {
      return null;
    }

    try {
      final truncatedPublicKey = contactPublicKey.length > 16
          ? contactPublicKey.shortId()
          : contactPublicKey;
      _logger.fine(
        '🔧 ECDH ENCRYPT DEBUG: Starting encryption for $truncatedPublicKey...',
      );

      final enhancedSecret = deriveEnhancedContactKey(
        sharedSecret,
        contactPublicKey,
      );
      final keyBytes = sha256.convert(utf8.encode(enhancedSecret)).bytes;
      final key = Key(Uint8List.fromList(keyBytes));
      final iv = IV.fromSecureRandom(16);
      final encrypter = Encrypter(AES(key));
      final encrypted = encrypter.encrypt(plaintext, iv: iv);

      final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
      final result = base64.encode(combined);

      final pairingKey = _getPairingKeyForContact(contactPublicKey);
      if (pairingKey != null) {
        _logger.fine('✅ ENHANCED ECDH encryption successful (ECDH + Pairing)');
      } else {
        _logger.fine('✅ STANDARD ECDH encryption successful (ECDH only)');
      }

      return '$cryptoWireFormatV2$result';
    } catch (e) {
      _logger.fine('❌ Enhanced ECDH encryption failed: $e');
      return null;
    }
  }

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    await ensureConversationKeySync(contactPublicKey, contactRepo);

    final sharedSecret = await getCachedOrComputeSharedSecret(
      contactPublicKey,
      contactRepo,
    );
    if (sharedSecret == null) {
      return null;
    }

    try {
      final truncatedPublicKey = contactPublicKey.length > 16
          ? contactPublicKey.shortId()
          : contactPublicKey;
      _logger.fine(
        '🔧 ECDH DECRYPT DEBUG: Starting decryption for $truncatedPublicKey...',
      );

      final enhancedSecret = deriveEnhancedContactKey(
        sharedSecret,
        contactPublicKey,
      );
      final keyBytes = sha256.convert(utf8.encode(enhancedSecret)).bytes;
      final key = Key(Uint8List.fromList(keyBytes));

      var ciphertext = encryptedBase64;
      var isV2Format = false;
      if (encryptedBase64.startsWith(cryptoWireFormatV2)) {
        ciphertext = encryptedBase64.substring(cryptoWireFormatV2.length);
        isV2Format = true;
      }

      final encrypter = Encrypter(AES(key));
      final decrypted = isV2Format
          ? decryptV2Format(encrypter, ciphertext)
          : decryptLegacyFormat(encrypter, ciphertext, enhancedSecret);

      final pairingKey = _getPairingKeyForContact(contactPublicKey);
      if (pairingKey != null) {
        _logger.fine('✅ ENHANCED ECDH decryption successful (ECDH + Pairing)');
      } else {
        _logger.fine('✅ STANDARD ECDH decryption successful (ECDH only)');
      }

      return decrypted;
    } catch (e) {
      _logger.fine('❌ Enhanced ECDH decryption failed: $e');
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
    final ivSeed = '${enhancedSecret}_IV_DERIVATION';
    final ivBytes = sha256.convert(utf8.encode(ivSeed)).bytes.sublist(0, 16);
    final iv = IV(Uint8List.fromList(ivBytes));

    if (kDebugMode) {
      _logger.fine('⚠️ Decrypting legacy ECDH message with deterministic IV');
    }

    final encrypted = Encrypted.fromBase64(ciphertext);
    return encrypter.decrypt(encrypted, iv: iv);
  }

  static String deriveEnhancedContactKey(
    String ecdhSecret,
    String contactPublicKey,
  ) {
    final pairingKey = _getPairingKeyForContact(contactPublicKey);

    if (pairingKey != null) {
      final sortedSecrets = [ecdhSecret, pairingKey]..sort();
      final combinedSecret = sortedSecrets.join('_COMBINED_');

      _logger.fine(
        '🔧 ENHANCED SECURITY: Using ECDH + Pairing key derivation',
      );
      return '${combinedSecret}_ENHANCED_ECDH_AES_SALT';
    }

    _logger.fine('🔧 STANDARD ECDH: Using ECDH-only key derivation');
    return '${ecdhSecret}_ECDH_AES_SALT';
  }

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) async {
    if (_sharedSecretCache.containsKey(contactPublicKey)) {
      return _sharedSecretCache[contactPublicKey];
    }

    final cachedSecret = await contactRepo.getCachedSharedSecret(
      contactPublicKey,
    );
    if (cachedSecret != null) {
      _logger.fine('Loaded shared secret from secure storage');
      _sharedSecretCache[contactPublicKey] = cachedSecret;
      return cachedSecret;
    }

    _logger.fine('Computing new ECDH shared secret - will cache for future use');
    final newSecret = SigningCryptoService.computeSharedSecret(contactPublicKey);
    if (newSecret != null) {
      _sharedSecretCache[contactPublicKey] = newSecret;
      await contactRepo.cacheSharedSecret(contactPublicKey, newSecret);
      _logger.fine('ECDH shared secret computed and cached');
    }

    return newSecret;
  }

  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) async {
    if (!ConversationCryptoService.hasConversationKey(publicKey)) {
      final cachedSecret = await repo.getCachedSharedSecret(publicKey);
      if (cachedSecret != null) {
        await ConversationCryptoService.restoreConversationKey(
          publicKey,
          cachedSecret,
        );
        _logger.fine('🔄 SYNC: Restored conversation key for $publicKey');
      }
    }
  }

  static void clearSharedSecretCache({String? publicKey}) {
    if (publicKey == null) {
      _sharedSecretCache.clear();
      return;
    }
    _sharedSecretCache.remove(publicKey);
  }

  static String? _getPairingKeyForContact(String contactPublicKey) {
    final conversationKey = _sharedSecretCache[contactPublicKey];
    if (conversationKey != null &&
        ConversationCryptoService.hasConversationKey(contactPublicKey)) {
      return 'PAIRED_$conversationKey';
    }
    return null;
  }
}
