import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../core/interfaces/i_ble_service_facade.dart';
import '../../core/models/connection_info.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/di/service_locator.dart';

final _logger = Logger('BLEServiceFacadeProvider');

/// ✅ Phase 6D: Riverpod provider for BLEServiceFacade
/// Accesses the service locator singleton and exposes lifecycle management
/// Note: BLEServiceFacade manages multiple internal streams
/// This provider provides Riverpod-managed access to the singleton
final bleServiceFacadeProvider = Provider.autoDispose<IBLEServiceFacade>((ref) {
  final facade = getIt<IBLEServiceFacade>();
  _logger.fine('✅ BLEServiceFacade provider accessed');
  ref.onDispose(() {
    // Dispose facade when provider is torn down to avoid leaked controllers.
    unawaited(facade.dispose());
  });
  return facade;
});

/// ✅ Phase 6D: StreamProvider for connection info events
/// Primary BLE connection state changes
final bleConnectionInfoStreamProvider =
    StreamProvider.autoDispose<ConnectionInfo>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      // Return the stream directly (no initial yield needed for this case)
      return facade.connectionInfoStream;
    });

/// ✅ Phase 6D: StreamProvider for discovered devices events
/// BLE device discovery changes
final bleDiscoveredDevicesStreamProvider =
    StreamProvider.autoDispose<List<Peripheral>>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.discoveredDevicesStream;
    });

/// ✅ Phase 6D: StreamProvider for discovery data (hash-based contact detection)
/// Raw discovery data with contact information
final bleDiscoveryDataStreamProvider =
    StreamProvider.autoDispose<Map<String, DiscoveredEventArgs>>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.discoveryDataStream;
    });

/// ✅ Phase 6D: StreamProvider for spy mode detection
/// Alerts when device attempting to spoof identity
final bleSpyModeDetectedStreamProvider =
    StreamProvider.autoDispose<SpyModeInfo>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.spyModeDetectedStream;
    });

/// ✅ Phase 6D: StreamProvider for identity reveal events
/// Alerts when identity is revealed during handshake
final bleIdentityRevealedStreamProvider = StreamProvider.autoDispose<String>((
  ref,
) {
  final facade = ref.watch(bleServiceFacadeProvider);
  return facade.identityRevealedStream;
});
