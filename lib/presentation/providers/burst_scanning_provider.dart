import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/domain/services/burst_scanning_controller.dart';
import 'ble_providers.dart';

/// Provider for BurstScanningController instance
final burstScanningControllerProvider =
    Provider.autoDispose<BurstScanningController>((ref) {
      final controller = BurstScanningController();
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Async provider that initializes BurstScanningController
final burstScanningInitializedProvider =
    FutureProvider.autoDispose<BurstScanningController>((ref) async {
      final controller = ref.watch(burstScanningControllerProvider);
      final bleService = ref.watch(connectionServiceProvider);
      await controller.initialize(bleService);
      return controller;
    });

/// Stream provider for burst scanning status updates
final burstScanningStatusProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final controller = ref.watch(burstScanningControllerProvider);
  await controller.initialize(ref.watch(connectionServiceProvider));
  yield* controller.statusStream;
});
