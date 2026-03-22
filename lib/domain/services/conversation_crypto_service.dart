import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';

import 'crypto_wire_format.dart';

class ConversationCryptoService {
  static final _logger = Logger('ConversationCryptoService');

  static final Map<String, Encrypter> _conversationEncrypters = {};
  static final Map<String, IV> _conversationIVs = {};

  static void initializeConversation(String publicKey, String sharedSecret) {
    final keyBytes = sha256
        .convert(utf8.encode('${sharedSecret}CONVERSATION_KEY'))
        .bytes;
    final key = Key(Uint8List.fromList(keyBytes));

    _conversationEncrypters[publicKey] = Encrypter(AES(key));

    final ivBytes = sha256
        .convert(utf8.encode('${sharedSecret}CONVERSATION_IV'))
        .bytes
        .sublist(0, 16);
    _conversationIVs[publicKey] = IV(Uint8List.fromList(ivBytes));

    if (kDebugMode) {
      _logger.fine('Initialized conversation crypto for $publicKey');
    }
  }

  static String encryptForConversation(String plaintext, String publicKey) {
    final encrypter = _conversationEncrypters[publicKey];
    if (encrypter == null) {
      throw StateError('No conversation key for $publicKey');
    }

    final iv = IV.fromSecureRandom(16);
    if (plaintext.isEmpty) {
      return '$cryptoWireFormatV2${base64.encode(iv.bytes)}';
    }

    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return '$cryptoWireFormatV2${base64.encode(combined)}';
  }

  static String decryptFromConversation(
    String encryptedBase64,
    String publicKey,
  ) {
    final encrypter = _conversationEncrypters[publicKey];
    if (encrypter == null) {
      throw StateError('No conversation key for $publicKey');
    }

    var ciphertext = encryptedBase64;
    var isV2Format = false;
    if (encryptedBase64.startsWith(cryptoWireFormatV2)) {
      ciphertext = encryptedBase64.substring(cryptoWireFormatV2.length);
      isV2Format = true;
    }

    if (isV2Format) {
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
    }

    final legacyIV = _conversationIVs[publicKey];
    if (legacyIV == null) {
      throw StateError(
        'No legacy IV for $publicKey - cannot decrypt old format message',
      );
    }
    if (kDebugMode) {
      _logger.fine(
        '⚠️ Decrypting legacy conversation message for $publicKey',
      );
    }
    final encrypted = Encrypted.fromBase64(ciphertext);
    return encrypter.decrypt(encrypted, iv: legacyIV);
  }

  static bool hasConversationKey(String publicKey) {
    return _conversationEncrypters.containsKey(publicKey);
  }

  static void clearConversationKey(String publicKey) {
    _conversationEncrypters.remove(publicKey);
    _conversationIVs.remove(publicKey);
    _logger.fine('Cleared conversation key for $publicKey');
  }

  static void clearAllConversationKeys() {
    _conversationEncrypters.clear();
    _conversationIVs.clear();
    _logger.fine('Cleared all conversation keys');
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

      _conversationEncrypters[publicKey] = Encrypter(AES(key));
      _conversationIVs[publicKey] = iv;
      _logger.fine('Restored conversation key for $publicKey');
    } catch (e) {
      _logger.fine('Failed to restore conversation key: $e');
    }
  }
}
