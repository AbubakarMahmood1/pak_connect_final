import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/models/security_state.dart';
import '../../domain/services/security_state_computer.dart';
import 'ble_providers.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

/// Static cache for security states to prevent frequent recreations
final Map<String, SecurityState> _securityStateCache = {};
final Map<String, DateTime> _cacheTimestamps = {};
const Duration _cacheValidityDuration = Duration(seconds: 30);
final _logger = Logger('SecurityStateProvider');

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
  final connectionService = ref.watch(connectionServiceProvider);
  final contactRepository = _resolveContactRepository();
  final connectedKeys = <String?>{
    connectionService.theirPersistentKey,
    connectionService.currentSessionId,
    connectionService.theirEphemeralId,
  };
  final isRepositoryMode = otherPublicKey == null
      ? !(connectionInfo?.isReady ?? false)
      : !connectedKeys.contains(otherPublicKey);
  final theyHaveUsAsContact = _resolveTheyHaveUsAsContact(connectionService);

  final cached = _getCached(otherPublicKey);
  if (cached != null) {
    _logger.fine(
      '🐛 NAV DEBUG: Using cached security state for key: $otherPublicKey',
    );
    return cached;
  }

  _logger.fine(
    '🐛 NAV DEBUG: - connectionService.theirPersistentKey: ${connectionService.theirPersistentKey != null && connectionService.theirPersistentKey!.length > 16 ? '${connectionService.theirPersistentKey!.shortId()}...' : connectionService.theirPersistentKey ?? 'null'}',
  );
  _logger.fine(
    '🐛 NAV DEBUG: - connectionInfo: ${connectionInfo?.isConnected}/${connectionInfo?.isReady}',
  );
  _logger.fine('🐛 NAV DEBUG: - isRepositoryMode: $isRepositoryMode');

  final result = await SecurityStateComputer.computeState(
    isRepositoryMode: isRepositoryMode,
    connectionInfo: connectionInfo,
    connectionService: connectionService,
    contactRepository: contactRepository,
    theyHaveUsAsContact: theyHaveUsAsContact,
    otherPublicKey: otherPublicKey,
  );

  _cacheResult(otherPublicKey, result);

  _logger.fine(
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

IContactRepository _resolveContactRepository() {
  final serviceLocator = GetIt.instance;
  if (serviceLocator.isRegistered<IContactRepository>()) {
    return serviceLocator<IContactRepository>();
  }
  throw StateError(
    'IContactRepository is not registered. '
    'Call setupServiceLocator() before using security state providers.',
  );
}

bool _resolveTheyHaveUsAsContact(IConnectionService connectionService) {
  try {
    final dynamic maybeWithManager = connectionService;
    final dynamic stateManager = maybeWithManager.stateManager;
    final dynamic value = stateManager.theyHaveUsAsContact;
    if (value is bool) {
      return value;
    }
  } catch (_) {}
  return false;
}
