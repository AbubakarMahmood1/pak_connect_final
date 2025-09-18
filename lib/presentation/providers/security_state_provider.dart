// ignore_for_file: avoid_print

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/security_state.dart';
import '../../domain/services/security_state_computer.dart';
import 'ble_providers.dart';

/// SINGLE PROVIDER for all security state
/// Routes ALL security queries through SecurityStateComputer
/// Using regular FutureProvider.family (no autoDispose) to persist across navigation
final securityStateProvider = FutureProvider.family<SecurityState, String?>((ref, otherPublicKey) async {
  print('🐛 NAV DEBUG: securityStateProvider CREATE for key: $otherPublicKey');
  
  // Track provider disposal
  ref.onDispose(() {
    print('🐛 NAV DEBUG: securityStateProvider DISPOSED for key: $otherPublicKey');
  });
  
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
  
  print('🐛 NAV DEBUG: securityStateProvider RESULT: ${result.status.name} for key: $otherPublicKey');
  return result;
});

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
