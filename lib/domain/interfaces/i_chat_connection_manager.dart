import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;

import '../models/connection_info.dart';
import '../models/connection_status.dart';

/// Interface for managing chat connection status determination.
abstract class IChatConnectionManager {
  /// Initialize listeners for BLE peripheral connections and discovery data.
  Future<void> initialize();

  /// Determine connection status for a chat contact.
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  });

  /// Check if contact is online via discovery hash matching.
  bool isContactOnlineViaHash({
    required String contactPublicKey,
    required Map<String, dynamic> discoveryData,
  });

  /// Stream of connection status changes.
  Stream<ConnectionStatus> get connectionStatusStream;

  /// Setup peripheral connection listener (Android only).
  Future<void> setupPeripheralConnectionListener();

  /// Setup discovery data listener.
  Future<void> setupDiscoveryListener();

  /// Get known contacts from discovery data.
  Map<String, dynamic> getKnownContactsFromDiscovery(
    Map<String, dynamic> discoveryData,
  );

  /// Check if a specific device is discovered.
  bool isDeviceDiscovered({
    required String contactPublicKey,
    required List<Peripheral> discoveredDevices,
  });

  /// Cleanup listeners on disposal.
  Future<void> dispose();
}
