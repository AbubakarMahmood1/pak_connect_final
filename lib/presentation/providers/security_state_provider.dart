import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/security_state.dart';
import '../../domain/services/security_state_computer.dart';
import 'ble_providers.dart';

final securityStateProvider = FutureProvider.family<SecurityState, String?>((ref, otherPublicKey) async {
  final bleService = ref.watch(bleServiceProvider);
  final connectionInfo = ref.watch(connectionInfoProvider);
  
  // For repository mode, we need to pass the chatId differently
  final isRepositoryMode = otherPublicKey?.startsWith('repo_') ?? false;
  
  return await SecurityStateComputer.computeState(
    isRepositoryMode: isRepositoryMode,
    connectionInfo: connectionInfo.value,
    bleService: bleService,
    otherPublicKey: otherPublicKey,
  );
});