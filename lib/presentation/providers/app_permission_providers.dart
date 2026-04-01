import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/app_permission_service.dart';
import 'ble_providers.dart';

final appPermissionServiceProvider = Provider<AppPermissionService>((ref) {
  return const AppPermissionService();
});

final blePermissionsGrantedProvider = FutureProvider.autoDispose<bool>((ref)
async {
  final permissionService = ref.watch(appPermissionServiceProvider);
  return permissionService.hasRequiredBlePermissions();
});

final appBleReadyForHomeProvider = Provider.autoDispose<AsyncValue<bool>>((ref) {
  final bleStateAsync = ref.watch(bleStateProvider);
  final blePermissionsAsync = ref.watch(blePermissionsGrantedProvider);

  return bleStateAsync.when(
    data: (state) => blePermissionsAsync.whenData(
      (granted) => state == BluetoothLowEnergyState.poweredOn && granted,
    ),
    loading: () => const AsyncValue<bool>.loading(),
    error: (error, stack) => AsyncValue<bool>.error(error, stack),
  );
});
