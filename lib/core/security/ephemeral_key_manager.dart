// File: lib/core/security/ephemeral_key_manager.dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hint_cache_manager.dart';
import '../utils/app_logger.dart';

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
    return _currentSessionKey!;
  }
  
  // Generate hint that contacts can recognize (based on their relationship + current session)
  static String generateContactHint(String contactPublicKey, String sharedSecret) {
    if (_currentSessionKey == null) {
      throw StateError('EphemeralKeyManager not initialized');
    }
    
    // Use session key + contact relationship for hint generation
    final seed = '$_myPrivateKey:$contactPublicKey:$sharedSecret:$_userSalt:$_currentSessionKey';
    return sha256.convert(utf8.encode(seed)).toString().substring(0, hintlength);
  }
  
  // Manually rotate to new session (user choice or app events)
  static Future<void> _generateNewSession() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomComponent = Random.secure().nextInt(0xFFFFFFFF);
    final seed = '$_myPrivateKey:$_userSalt:$timestamp:$randomComponent';

    // Existing ephemeral ID generation...
    _currentSessionKey = sha256.convert(utf8.encode(seed)).toString().substring(0, hintlength);
    _sessionStartTime = DateTime.now();
    
    // NEW: Generate ephemeral signing keypair
    await _generateEphemeralSigningKeys();
    
    // Existing persistence...
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_ephemeral_session', _currentSessionKey!);
    await prefs.setInt('session_start_time', _sessionStartTime!.millisecondsSinceEpoch);
    
    // NEW: Persist signing keys
    await prefs.setString('ephemeral_signing_private', _ephemeralSigningPrivateKey!);
    await prefs.setString('ephemeral_signing_public', _ephemeralSigningPublicKey!);
  }
  
  // NEW: Generate ECDSA keypair for signing
  static Future<void> _generateEphemeralSigningKeys() async {
    try {
      final keyGen = ECKeyGenerator();
      final secureRandom = FortunaRandom();
      
      final seed = List<int>.generate(32, (i) =>
        DateTime.now().millisecondsSinceEpoch ~/ (i + 1));
      secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));
      
      final keyParams = ECKeyGeneratorParameters(ECCurve_secp256r1());
      keyGen.init(ParametersWithRandom(keyParams, secureRandom));
      
      final keyPair = keyGen.generateKeyPair();
      
      final publicKey = keyPair.publicKey as ECPublicKey;
      final privateKey = keyPair.privateKey as ECPrivateKey;
      
      _ephemeralSigningPublicKey = publicKey.Q!.getEncoded(false)
          .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _ephemeralSigningPrivateKey = privateKey.d!.toRadixString(16);

      _logger.info('✅ Generated ephemeral signing keys');
    } catch (e) {
      _logger.severe('❌ Failed to generate ephemeral signing keys: $e');
      rethrow;
    }
  }

  static Future<void> _tryRestoreSigningKeys() async {
    final prefs = await SharedPreferences.getInstance();
    _ephemeralSigningPrivateKey = prefs.getString('ephemeral_signing_private');
    _ephemeralSigningPublicKey = prefs.getString('ephemeral_signing_public');
    
    if (_ephemeralSigningPrivateKey == null || _ephemeralSigningPublicKey == null) {
      await _generateEphemeralSigningKeys();
    }
  }
  
  // Try to restore previous session on app restart
  static Future<void> _tryRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSession = prefs.getString('current_ephemeral_session');
    final savedTime = prefs.getInt('session_start_time');
    
    if (savedSession != null && savedTime != null) {
      _currentSessionKey = savedSession;
      _sessionStartTime = DateTime.fromMillisecondsSinceEpoch(savedTime);

      final sessionAge = DateTime.now().difference(_sessionStartTime!);
      if (sessionAge > Duration(hours: 6)) {
        _logger.info('🔄 Saved session too old, generating new one...');
        await _generateNewSession();
      } else {
        _logger.info('✅ Restored ephemeral session: $_currentSessionKey');
        // NEW: Restore signing keys
        await _tryRestoreSigningKeys();
      }
    } else {
      await _generateNewSession();
    }
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

    _logger.info('✅ New ephemeral session with fresh signing keys: $_currentSessionKey');
  }
  
  // Getters for debugging and UI
  static String? get currentSessionKey => _currentSessionKey;
  static DateTime? get sessionStartTime => _sessionStartTime;
  static Duration? get sessionAge => _sessionStartTime != null 
      ? DateTime.now().difference(_sessionStartTime!) 
      : null;
  static String? get ephemeralSigningPrivateKey => _ephemeralSigningPrivateKey;
  static String? get ephemeralSigningPublicKey => _ephemeralSigningPublicKey;
}