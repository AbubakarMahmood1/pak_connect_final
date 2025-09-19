// File: lib/core/security/background_cache_service.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'hint_cache_manager.dart';

class BackgroundCacheService {
  static Timer? _refreshTimer;
  static Timer? _rotationCheckTimer;
  static bool _isInitialized = false;
  static _AppLifecycleObserver? _observer;
  
  static void initialize() {
    if (_isInitialized) return;
    
    // Refresh cache every 4 minutes (for contact changes)
    _refreshTimer = Timer.periodic(Duration(minutes: 4), (timer) {
      _refreshCacheInBackground();
    });
    
    _observer = _AppLifecycleObserver();
    WidgetsBinding.instance.addObserver(_observer!);
    
    _isInitialized = true;
    print('🔄 Background cache service started');
  }
  
  static void _refreshCacheInBackground() async {
    print('🔄 Background cache refresh...');
    
    try {
      await HintCacheManager.updateCache();
      print('✅ Background refresh completed');
    } catch (e) {
      print('❌ Background refresh failed: $e');
    }
  }
  
  static void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    
    _rotationCheckTimer?.cancel();
    _rotationCheckTimer = null;
    
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
    
    _isInitialized = false;
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App resumed - refresh cache but don't force rotation
      HintCacheManager.clearCache();
      HintCacheManager.updateCache();
    }
  }
}