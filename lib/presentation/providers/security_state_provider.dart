// ignore_for_file: avoid_print

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/security_state.dart';
import '../../data/services/security_state_computer.dart';
import 'ble_providers.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

/// Static cache for security states to prevent frequent recreations
final Map<String, SecurityState> _securityStateCache = {};
final Map<String, DateTime> _cacheTimestamps = {};
const Duration _cacheValidityDuration = Duration(seconds: 30);

SecurityState? _getCached(String? key) {
  if (key == null) return null;
  final cached = _securityStateCache[key];
  final timestamp = _cacheTimestamps[key];
  if (cached == null || timestamp == null) return null;
  if (DateTime.now().difference(timestamp) > _cacheValidityDuration) {
    _securityStateCache.remove(key);
    _cacheTimestamps.remove(key);
    return null;
  }
  return cached;
}

void _cacheResult(String? key, SecurityState result) {
  if (key == null) return;
  _securityStateCache[key] = result;
  _cacheTimestamps[key] = DateTime.now();
}

final securityStateProvider = FutureProvider.family<SecurityState, String?>((
  ref,
  otherPublicKey,
) async {
  final runtime = ref.watch(bleRuntimeProvider);
  final connectionInfo = runtime.asData?.value.connectionInfo;
  final bleService = ref.watch(bleServiceProvider);
  final connectedKeys = <String?>{
    bleService.theirPersistentKey,
    bleService.currentSessionId,
    bleService.theirEphemeralId,
  };
  final isRepositoryMode = otherPublicKey == null
      ? !(connectionInfo?.isReady ?? false)
      : !connectedKeys.contains(otherPublicKey);

  final cached = _getCached(otherPublicKey);
  if (cached != null) {
    print('🐛 NAV DEBUG: Using cached security state for key: $otherPublicKey');
    return cached;
  }

  print(
    '🐛 NAV DEBUG: - bleService.theirPersistentKey: ${bleService.theirPersistentKey != null && bleService.theirPersistentKey!.length > 16 ? '${bleService.theirPersistentKey!.shortId()}...' : bleService.theirPersistentKey ?? 'null'}',
  );
  print(
    '🐛 NAV DEBUG: - connectionInfo: ${connectionInfo?.isConnected}/${connectionInfo?.isReady}',
  );
  print('🐛 NAV DEBUG: - isRepositoryMode: $isRepositoryMode');

  final result = await SecurityStateComputer.computeState(
    isRepositoryMode: isRepositoryMode,
    connectionInfo: connectionInfo,
    bleService: bleService,
    otherPublicKey: otherPublicKey,
  );

  _cacheResult(otherPublicKey, result);

  print(
    '🐛 NAV DEBUG: securityStateProvider RESULT: ${result.status.name} for key: $otherPublicKey',
  );
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
final canSendMessagesProvider = Provider.family<bool, String?>((
  ref,
  otherPublicKey,
) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));

  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.canSendMessages(state),
    orElse: () => false,
  );
});

/// Helper provider for recommended actions
final recommendedActionProvider = Provider.family<String?, String?>((
  ref,
  otherPublicKey,
) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));

  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.getRecommendedAction(state),
    orElse: () => null,
  );
});

/// Helper provider for encryption description
final encryptionDescriptionProvider = Provider.family<String, String?>((
  ref,
  otherPublicKey,
) {
  final securityStateAsync = ref.watch(securityStateProvider(otherPublicKey));

  return securityStateAsync.maybeWhen(
    data: (state) => SecurityStateComputer.getEncryptionDescription(state),
    orElse: () => 'Unknown',
  );
});
