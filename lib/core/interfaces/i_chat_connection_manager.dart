import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;
import '../../core/models/connection_status.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';

/// Interface for managing chat connection status determination
///
/// Owns:
/// - BLE peripheral & discovery listener setup
/// - Connection status heuristics (active session, persistent key, nearby, last-seen)
/// - Online status detection via hash matching
///
/// Exposes:
/// - connectionStatusStream: Real-time status updates
/// - Ready for consumption by ChatListCoordinator
abstract class IChatConnectionManager {
  /// Initialize listeners for BLE peripheral connections and discovery data
  Future<void> initialize();

  /// Determine connection status for a chat contact
  ///
  /// Checks in order:
  /// 1. Currently connected (active Noise session)
  /// 2. Currently connecting
  /// 3. Nearby via BLE discovery
  /// 4. Recently seen (within 5 min)
  /// 5. Offline
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, DiscoveredDevice> discoveryData,
    required DateTime? lastSeenTime,
  });

  /// Check if contact is online via hash matching of manufacturer data
  ///
  /// Matches:
  /// - Current ephemeral ID (active session, privacy-first)
  /// - Persistent public key (MEDIUM+ security, paired contact)
  /// - Does NOT match initial publicKey (prevents session linkage)
  bool isContactOnlineViaHash({
    required String contactPublicKey,
    required Map<String, DiscoveredDevice> discoveryData,
  });

  /// Get stream of connection status changes
  /// Emits whenever connection state changes (connected → nearby → offline, etc.)
  Stream<ConnectionStatus> get connectionStatusStream;

  /// Setup peripheral connection listener (Android only)
  /// Listens to incoming connections when this device is in peripheral mode
  Future<void> setupPeripheralConnectionListener();

  /// Setup discovery data listener
  /// Listens to BLE discovery changes and triggers immediate status updates
  Future<void> setupDiscoveryListener();

  /// Get current known contacts from discovery data
  /// Returns map of contact public key → DiscoveredDevice
  Map<String, DiscoveredDevice> getKnownContactsFromDiscovery(
    Map<String, DiscoveredDevice> discoveryData,
  );

  /// Check if a specific device is discovered
  bool isDeviceDiscovered({
    required String contactPublicKey,
    required List<Peripheral> discoveredDevices,
  });

  /// Cleanup listeners on disposal
  Future<void> dispose();
}
