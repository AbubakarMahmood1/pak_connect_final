// File: lib/core/security/hint_cache_manager.dart
import 'package:flutter/foundation.dart';

import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/enhanced_contact.dart';
import 'ephemeral_key_manager.dart';

class HintCacheManager {
  static final Map<String, ContactHint> _hintCache = {};
  static DateTime? _lastCacheUpdate;
  static String? _cacheSessionKey; // ✅ NEW: Track which session cache was built for
  static int _cacheValidityMinutes = 30; // ✅ INCREASED: Much longer since hints are session-stable
  
  static int get cacheSize => _hintCache.length;
  
  static Future<void> updateCache() async {
    final now = DateTime.now();
    final currentSessionKey = EphemeralKeyManager.currentSessionKey;
    
    // ✅ NEW: Check if session changed (most important check)
    final sessionChanged = _cacheSessionKey != currentSessionKey;
    
    // ✅ MODIFIED: Check time-based expiry (for contact changes only)
    final timeExpired = _lastCacheUpdate != null && 
        now.difference(_lastCacheUpdate!).inMinutes >= _cacheValidityMinutes;
    
    // Only rebuild cache if session changed OR time expired OR never built
    if (!sessionChanged && !timeExpired && _lastCacheUpdate != null) {
      return; // Cache still valid
    }
    
    if (sessionChanged) {
      if (kDebugMode) {
        print('🔄 Session changed - rebuilding hint cache...');
      }
    } else if (timeExpired) {
      if (kDebugMode) {
        print('🔄 Cache expired - checking for contact changes...');
      }
    } else {
      if (kDebugMode) {
        print('🔄 Initial cache build...');
      }
    }
    
    _hintCache.clear();

    final contactRepo = ContactRepository();
    final contacts = await contactRepo.getAllContacts();

    for (final contact in contacts.values) {
      final sharedSecret = await contactRepo.getCachedSharedSecret(contact.publicKey);
      if (sharedSecret != null) {
        final hint = EphemeralKeyManager.generateContactHint(
          contact.publicKey,
          sharedSecret
        );
        // Convert Contact to EnhancedContact for ContactHint
        final enhancedContact = EnhancedContact(
          contact: contact,
          lastSeenAgo: DateTime.now().difference(contact.lastSeen),
          isRecentlyActive: DateTime.now().difference(contact.lastSeen).inHours < 24,
          interactionCount: 0,
          averageResponseTime: const Duration(minutes: 5),
          groupMemberships: const [],
        );
        _hintCache[hint] = ContactHint(enhancedContact, sharedSecret);
      }
    }
    
    // ✅ NEW: Track session this cache was built for
    _cacheSessionKey = currentSessionKey;
    _lastCacheUpdate = now;
    if (kDebugMode) {
      print('✅ Hint cache updated: ${_hintCache.length} entries (session: ${_cacheSessionKey?.substring(0, 4)}...)');
    }
  }
  
  static ContactHint? getContactFromCache(String ephemeralHint) {
    _ensureCacheUpToDate();
    return _hintCache[ephemeralHint];
  }
  
  static void _ensureCacheUpToDate() {
    updateCache(); // Will return early if cache is valid
  }
  
  static void clearCache() {
    _hintCache.clear();
    _lastCacheUpdate = null;
    _cacheSessionKey = null; // ✅ NEW: Clear session tracking
  }
  
  static void dispose() {
    clearCache();
  }
  
  // ✅ MODIFIED: Set cache validity (now for contact changes, not session changes)
  static void setCacheValidity(int minutes) {
    _cacheValidityMinutes = minutes;
    if (kDebugMode) {
      print('🔋 Contact change check interval updated to $_cacheValidityMinutes minutes');
    }
    
    // If new validity is shorter than current cache age, force refresh
    if (_lastCacheUpdate != null) {
      final cacheAge = DateTime.now().difference(_lastCacheUpdate!).inMinutes;
      if (cacheAge >= _cacheValidityMinutes) {
        if (kDebugMode) {
          print('🔄 Cache interval reduced - forcing immediate refresh');
        }
        clearCache();
      }
    }
  }
  
  // ✅ NEW: Force cache refresh on session rotation
  static void onSessionRotated() {
    if (kDebugMode) {
      print('🔄 Session rotated - invalidating hint cache');
    }
    clearCache();
  }
  
  // ✅ NEW: Check if cache is for current session
  static bool get isCacheForCurrentSession {
    return _cacheSessionKey == EphemeralKeyManager.currentSessionKey;
  }
  
  static int get cacheValidityMinutes => _cacheValidityMinutes;
  
  static bool get isCacheExpired {
    if (_lastCacheUpdate == null) return true;
    
    // ✅ MODIFIED: Expired if session changed OR time expired
    final sessionChanged = !isCacheForCurrentSession;
    final timeExpired = DateTime.now().difference(_lastCacheUpdate!).inMinutes >= _cacheValidityMinutes;
    
    return sessionChanged || timeExpired;
  }
}

class ContactHint {
  final EnhancedContact contact;
  final String sharedSecret;
  
  ContactHint(this.contact, this.sharedSecret);
}
