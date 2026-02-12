import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/models/connection_info.dart';
import '../../domain/models/spy_mode_info.dart';

final _logger = Logger('BLEServiceFacadeProvider');

/// ✅ Phase 6D: Riverpod provider for BLEServiceFacade
/// Accesses the service locator singleton.
/// Note: BLEServiceFacade manages multiple internal streams
/// Pass 2: lifecycle ownership stays in AppCore/DI, not provider disposal.
final bleServiceFacadeProvider = Provider<IConnectionService>((ref) {
  final facade = resolveFromAppServicesOrServiceLocator<IConnectionService>(
    fromServices: (services) => services.connectionService,
    dependencyName: 'IConnectionService',
  );
  _logger.fine('✅ BLEServiceFacade provider accessed');
  return facade;
});

/// ✅ Phase 6D: StreamProvider for connection info events
/// Primary BLE connection state changes
final bleConnectionInfoStreamProvider =
    StreamProvider.autoDispose<ConnectionInfo>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      // Return the stream directly (no initial yield needed for this case)
      return facade.connectionInfo;
    });

/// ✅ Phase 6D: StreamProvider for discovered devices events
/// BLE device discovery changes
final bleDiscoveredDevicesStreamProvider =
    StreamProvider.autoDispose<List<Peripheral>>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.discoveredDevices;
    });

/// ✅ Phase 6D: StreamProvider for discovery data (hash-based contact detection)
/// Raw discovery data with contact information
final bleDiscoveryDataStreamProvider =
    StreamProvider.autoDispose<Map<String, DiscoveredEventArgs>>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.discoveryData;
    });

/// ✅ Phase 6D: StreamProvider for spy mode detection
/// Alerts when device attempting to spoof identity
final bleSpyModeDetectedStreamProvider =
    StreamProvider.autoDispose<SpyModeInfo>((ref) {
      final facade = ref.watch(bleServiceFacadeProvider);
      return facade.spyModeDetected;
    });

/// ✅ Phase 6D: StreamProvider for identity reveal events
/// Alerts when identity is revealed during handshake
final bleIdentityRevealedStreamProvider = StreamProvider.autoDispose<String>((
  ref,
) {
  final facade = ref.watch(bleServiceFacadeProvider);
  return facade.identityRevealed;
});
