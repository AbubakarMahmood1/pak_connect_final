// File: lib/core/security/ephemeral_key_manager.dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/services/hint_cache_manager.dart';
import 'package:pak_connect/domain/utils/app_logger.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

class EphemeralKeyManager {
  static final _logger = AppLogger.getLogger(LoggerNames.keyManagement);
  // FIXED: Make ephemeral keys same length as persistent keys (64 chars) to avoid length-dependent bugs
  static const int hintlength = 64;

  static String? _userSalt;
  static String? _myPrivateKey;
  static String? _currentSessionKey;
  static DateTime? _sessionStartTime;
  static String? _ephemeralSigningPrivateKey;
  static String? _ephemeralSigningPublicKey;

  // Initialize with user entropy (one-time setup)
  static Future<void> initialize(String privateKey) async {
    _myPrivateKey = privateKey;
    _userSalt = await _getOrCreateUserSalt();

    // Try to restore previous session, or generate new one
    await _tryRestoreSession();
  }

  // Generate ephemeral key for current session (stays same until rotation)
  static String generateMyEphemeralKey() {
    if (_currentSessionKey == null) {
      throw StateError('EphemeralKeyManager not initialized');
    }

    final preview = _currentSessionKey!.length > 16
        ? '${_currentSessionKey!.shortId()}...'
        : _currentSessionKey!;
    _logger.info(
      '🔧 INVESTIGATION: Returning current session ephemeral key: $preview',
    );
    _logger.info(
      '📋 This key is used in HandshakeCoordinator (NOT BLEStateManager pairing)',
    );

    return _currentSessionKey!;
  }

  // Generate hint that contacts can recognize (based on their relationship + current session)
  static String generateContactHint(
    String contactPublicKey,
    String sharedSecret,
  ) {
    if (_currentSessionKey == null) {
      throw StateError('EphemeralKeyManager not initialized');
    }

    // Use session key + contact relationship for hint generation
    final seed =
        '$_myPrivateKey:$contactPublicKey:$sharedSecret:$_userSalt:$_currentSessionKey';
    return sha256
        .convert(utf8.encode(seed))
        .toString()
        .substring(0, hintlength);
  }

  // Generate ephemeral key for current session (stays same until rotation)
  static Future<void> _generateNewSession() async {
    final random = Random.secure();
    final entropy = List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final seed = '$_myPrivateKey:$_userSalt:$entropy';

    // Generate ephemeral session key (64-char hex)
    _currentSessionKey = sha256
        .convert(utf8.encode(seed))
        .toString()
        .substring(0, hintlength);
    _sessionStartTime = DateTime.now();

    // Generate ephemeral signing keypair
    await _generateEphemeralSigningKeys();

    // 🔒 SECURITY FIX: NEVER persist private key material to disk
    // Private keys are held in memory only - fresh keys generated on app restart
    // Only persist non-sensitive session metadata and public key
    final prefs = await SharedPreferences.getInstance();

    // 🧹 CLEANUP: Remove legacy private key if it exists from previous versions
    // This ensures existing installations scrub old sensitive data on upgrade
    if (prefs.containsKey('ephemeral_signing_private')) {
      await prefs.remove('ephemeral_signing_private');
      _logger.info('🧹 Removed legacy ephemeral private key from storage');
    }

    await prefs.setString('current_ephemeral_session', _currentSessionKey!);
    await prefs.setInt(
      'session_start_time',
      _sessionStartTime!.millisecondsSinceEpoch,
    );
    // Public key is non-sensitive, safe to persist
    await prefs.setString(
      'ephemeral_signing_public',
      _ephemeralSigningPublicKey!,
    );

    _logger.info(
      '✅ Generated new ephemeral session: ${_currentSessionKey!.shortId()}...',
    );
  }

  // Generate ECDSA keypair for signing
  // FIX-003: Uses cryptographically secure random seed
  static Future<void> _generateEphemeralSigningKeys() async {
    try {
      final keyGen = ECKeyGenerator();
      final secureRandom = FortunaRandom();

      // FIX-003: Use Random.secure() instead of timestamp-based seed
      final random = Random.secure();
      final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      secureRandom.seed(KeyParameter(seed));

      final keyParams = ECKeyGeneratorParameters(ECCurve_secp256r1());
      keyGen.init(ParametersWithRandom(keyParams, secureRandom));

      final keyPair = keyGen.generateKeyPair();

      final publicKey = keyPair.publicKey as ECPublicKey;
      final privateKey = keyPair.privateKey as ECPrivateKey;

      _ephemeralSigningPublicKey = publicKey.Q!
          .getEncoded(false)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      _ephemeralSigningPrivateKey = privateKey.d!.toRadixString(16);

      _logger.info('✅ Generated ephemeral signing keys with secure seed');
    } catch (e, stackTrace) {
      _logger.severe(
        '❌ Failed to generate ephemeral signing keys: $e',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  // 🔧 FIXED: Always generate new session (no caching)
  // Removed TTL caching to prevent chat duplication bug
  // Each app session gets fresh ephemeral keys (no persistence)
  static Future<void> _tryRestoreSession() async {
    _logger.info('🔄 Generating new ephemeral session (no cache)...');
    await _generateNewSession();

    // Note: We intentionally don't restore from SharedPreferences anymore
    // Ephemeral keys should be truly ephemeral (per app session)
    // This ensures different sessions create different chats
  }

  static Future<String> _getOrCreateUserSalt() async {
    final prefs = await SharedPreferences.getInstance();
    String? salt = prefs.getString('user_ephemeral_salt');
    if (salt == null) {
      salt = Random.secure().nextInt(0xFFFFFFFF).toRadixString(16);
      await prefs.setString('user_ephemeral_salt', salt);
    }
    return salt;
  }

  static Future<void> rotateSession() async {
    _logger.info('🔄 Rotating ephemeral session with new signing keys...');
    await _generateNewSession();

    // Notify cache manager
    HintCacheManager.onSessionRotated();

    _logger.info(
      '✅ New ephemeral session with fresh signing keys: $_currentSessionKey',
    );
  }

  // Getters for debugging and UI
  static String? get currentSessionKey => _currentSessionKey;
  static DateTime? get sessionStartTime => _sessionStartTime;
  static Duration? get sessionAge => _sessionStartTime != null
      ? DateTime.now().difference(_sessionStartTime!)
      : null;

  // 🔒 SECURITY: Private key access restricted to trusted internal components only
  // This getter is INTERNAL USE ONLY - required by SigningManager for cryptographic operations
  // Should NOT be accessed outside core security components
  static String? get ephemeralSigningPrivateKey => _ephemeralSigningPrivateKey;

  static String? get ephemeralSigningPublicKey => _ephemeralSigningPublicKey;
}
