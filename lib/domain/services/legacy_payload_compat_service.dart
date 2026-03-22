import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:logging/logging.dart';

/// Legacy/global payload compatibility only.
///
/// This service is intentionally quarantined from active outbound crypto.
class LegacyPayloadCompatService {
  static final _logger = Logger('LegacyPayloadCompatService');

  static Encrypter? _encrypter;
  static IV? _iv;
  static int _deprecatedEncryptWrapperCallCount = 0;
  static int _deprecatedDecryptWrapperCallCount = 0;

  static const String _legacyPassphraseFromDefine = String.fromEnvironment(
    'PAKCONNECT_LEGACY_PASSPHRASE',
    defaultValue: '',
  );

  static void initialize() {
    _encrypter = null;
    _iv = null;

    if (_legacyPassphraseFromDefine.isEmpty) {
      if (kDebugMode) {
        _logger.fine(
          '⚠️ Legacy payload decryptor disabled '
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
    _encrypter = Encrypter(AES(key));

    if (kDebugMode) {
      _logger.fine(
        '⚠️ Legacy payload decryptor initialized (compatibility-only)',
      );
    }
  }

  static bool get isInitialized => _encrypter != null;

  static void clear() {
    _encrypter = null;
    _iv = null;
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

  static void _recordDeprecatedWrapperUse(String wrapperName) {
    if (wrapperName == 'encrypt') {
      _deprecatedEncryptWrapperCallCount++;
    } else if (wrapperName == 'decrypt') {
      _deprecatedDecryptWrapperCallCount++;
    }

    if (kDebugMode) {
      _logger.fine(
        '⚠️ SECURITY WARNING: Deprecated legacy wrapper '
        '$wrapperName invoked. Migrate caller to explicit APIs.',
      );
    }
  }

  /// Marks an intentionally plaintext compatibility payload.
  static String encodeLegacyPlaintext(String plaintext) {
    if (kDebugMode) {
      _logger.fine(
        '⚠️ SECURITY WARNING: encodeLegacyPlaintext() called - '
        'returning plaintext marker (NO ENCRYPTION)',
      );
    }
    return 'PLAINTEXT:$plaintext';
  }

  /// Decrypts historical global payloads or explicit plaintext markers.
  static String decryptLegacyCompatible(String encryptedBase64) {
    if (encryptedBase64.startsWith('PLAINTEXT:')) {
      return encryptedBase64.substring('PLAINTEXT:'.length);
    }

    if (_encrypter == null || _iv == null) {
      initialize();
    }

    if (_encrypter != null && _iv != null) {
      try {
        final encrypted = Encrypted.fromBase64(encryptedBase64);
        return _encrypter!.decrypt(encrypted, iv: _iv!);
      } catch (e) {
        if (kDebugMode) {
          _logger.fine('⚠️ Legacy payload decrypt failed: $e');
        }
        throw Exception('Legacy decryption failed: $e');
      }
    }

    if (kDebugMode) {
      _logger.fine('⚠️ Cannot decrypt: legacy decryptor unavailable');
    }
    throw Exception('Cannot decrypt: legacy decryptor unavailable');
  }

  @Deprecated(
    'Use proper encryption methods (Noise, ECDH, or Pairing). '
    'This method does NOT provide real security.',
  )
  static String encrypt(String plaintext) {
    _recordDeprecatedWrapperUse('encrypt');
    return encodeLegacyPlaintext(plaintext);
  }

  @Deprecated('Use proper decryption methods (Noise, ECDH, or Pairing)')
  static String decrypt(String encryptedBase64) {
    _recordDeprecatedWrapperUse('decrypt');
    return decryptLegacyCompatible(encryptedBase64);
  }
}
