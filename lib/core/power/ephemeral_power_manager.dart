// File: lib/core/security/ephemeral_key_manager.dart
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../security/hint_cache_manager.dart';

class EphemeralKeyManager {
  static const int hintLength = 8;

  static String? _userSalt;
  static String? _myPrivateKey;
  static String? _currentSessionKey;
  static DateTime? _sessionStartTime;

  // Initialize with user entropy (one-time setup)
  static Future<void> initialize(String privateKey) async {
    _myPrivateKey = privateKey;
    _userSalt = await _getOrCreateUserSalt();

    // ✅ NEW: Generate session key only once per session
    await _generateNewSession();
  }

  // ✅ NEW: Generate ephemeral key for current session (stays same until rotation)
  static String generateMyEphemeralKey() {
    if (_currentSessionKey == null) {
      throw StateError('EphemeralKeyManager not initialized');
    }
    return _currentSessionKey!;
  }

  // ✅ NEW: Generate hint that contacts can recognize (based on their relationship + current session)
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
        .substring(0, hintLength);
  }

  // Manually rotate to new session (user choice or app events)
  static Future<void> rotateSession() async {
    await _generateNewSession();

    // Notify cache manager of session change
    HintCacheManager.onSessionRotated();

    if (kDebugMode) {
      print('✅ New ephemeral session: $_currentSessionKey');
    }
  }

  // Check if current session is "old" (optional auto-rotation)
  static bool shouldConsiderRotation({Duration? maxSessionAge}) {
    if (_sessionStartTime == null) return true;

    maxSessionAge ??= Duration(
      hours: 2,
    ); // Default: suggest rotation after 2 hours
    return DateTime.now().difference(_sessionStartTime!) > maxSessionAge;
  }

  // ✅ PRIVATE: Generate new session key
  static Future<void> _generateNewSession() async {
    final sessionId = Random.secure().nextInt(0xFFFFFFFF).toRadixString(16);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final seed = '$_myPrivateKey:$_userSalt:$sessionId:$timestamp';

    _currentSessionKey = sha256
        .convert(utf8.encode(seed))
        .toString()
        .substring(0, hintLength);
    _sessionStartTime = DateTime.now();

    // ✅ PERSIST: Save session for app restart recovery
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_ephemeral_session', _currentSessionKey!);
    await prefs.setInt(
      'session_start_time',
      _sessionStartTime!.millisecondsSinceEpoch,
    );
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

  // ✅ GETTERS: For debugging and UI
  static String? get currentSessionKey => _currentSessionKey;
  static DateTime? get sessionStartTime => _sessionStartTime;
  static Duration? get sessionAge => _sessionStartTime != null
      ? DateTime.now().difference(_sessionStartTime!)
      : null;
}
