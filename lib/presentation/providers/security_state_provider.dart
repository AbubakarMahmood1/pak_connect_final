// ignore_for_file: avoid_print

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/security_state.dart';
import '../../domain/services/security_state_computer.dart';
import 'ble_providers.dart';

/// SINGLE PROVIDER for all security state
/// Routes ALL security queries through SecurityStateComputer
/// Using regular FutureProvider.family (no autoDispose) to persist across navigation
/// Static cache for security states to prevent frequent recreations
final Map<String, SecurityState> _securityStateCache = {};
final Map<String, DateTime> _cacheTimestamps = {};
const Duration _cacheValidityDuration = Duration(seconds: 30);

final securityStateProvider = FutureProvider.family<SecurityState, String?>((ref, otherPublicKey) async {
  print('🐛 NAV DEBUG: securityStateProvider CREATE for key: $otherPublicKey');
  
  // Enhanced disposal tracking with state preservation
  ref.onDispose(() {
    print('🐛 NAV DEBUG: securityStateProvider DISPOSE SCHEDULED for key: $otherPublicKey');
    
    // Keep the provider alive for a short time to handle rapid dispose/create cycles
    Timer(Duration(seconds: 5), () {
      print('🐛 NAV DEBUG: securityStateProvider ACTUALLY DISPOSED for key: $otherPublicKey');
    });
  });
  
  // Check cache first to prevent redundant computations
  if (otherPublicKey != null && _securityStateCache.containsKey(otherPublicKey)) {
    final cacheTime = _cacheTimestamps[otherPublicKey];
    if (cacheTime != null && DateTime.now().difference(cacheTime) < _cacheValidityDuration) {
      print('🐛 NAV DEBUG: Using cached security state for key: $otherPublicKey');
      return _securityStateCache[otherPublicKey]!;
    }
  }
  
  final bleService = ref.watch(bleServiceProvider);
  final connectionInfo = ref.watch(connectionInfoProvider);
  
  print('🐛 NAV DEBUG: - bleService.otherDevicePersistentId: ${bleService.otherDevicePersistentId?.substring(0, 16)}...');
  print('🐛 NAV DEBUG: - connectionInfo: ${connectionInfo.value?.isConnected}/${connectionInfo.value?.isReady}');
  
  final isRepositoryMode = otherPublicKey?.startsWith('repo_') ?? false;
  print('🐛 NAV DEBUG: - isRepositoryMode: $isRepositoryMode');
  
  final result = await SecurityStateComputer.computeState(
    isRepositoryMode: isRepositoryMode,
    connectionInfo: connectionInfo.value,
    bleService: bleService,
    otherPublicKey: otherPublicKey,
  );
  
  // Cache the result
  if (otherPublicKey != null) {
    _securityStateCache[otherPublicKey] = result;
    _cacheTimestamps[otherPublicKey] = DateTime.now();
  }
  
  print('🐛 NAV DEBUG: securityStateProvider RESULT: ${result.status.name} for key: $otherPublicKey');
  return result;
});

/// Clear security state cache
void clearSecurityStateCache() {
  _securityStateCache.clear();
  _cacheTimestamps.clear();
}

/// Invalidate specific cache entry
void invalidateSecurityStateCache(String key) {
  _securityStateCache.remove(key);
  _cacheTimestamps.remove(key);
}

/// Helper provider for quick security checks
final canSendMessagesProvider = Provider.family<bool, String?>((ref, otherPublicKey) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));
  
  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.canSendMessages(state),
    orElse: () => false,
  );
});

/// Helper provider for recommended actions
final recommendedActionProvider = Provider.family<String?, String?>((ref, otherPublicKey) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));
  
  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.getRecommendedAction(state),
    orElse: () => null,
  );
});

/// Helper provider for encryption description
final encryptionDescriptionProvider = Provider.family<String, String?>((ref, otherPublicKey) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));
  
  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.getEncryptionDescription(state),
    orElse: () => 'Unknown',
  );
});
