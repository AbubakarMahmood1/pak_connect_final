import 'dart:async';
import 'dart:io' show Platform;
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import '../interfaces/i_chat_connection_manager.dart';
import '../../core/models/connection_status.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../interfaces/i_connection_service.dart';

/// Service for managing chat connection status determination
///
/// Owns:
/// - BLE peripheral & discovery listener setup
/// - Connection status heuristics
/// - Online status detection via hash matching
///
/// Pattern:
/// - Exposes connectionStatusStream for consumption by ChatListCoordinator
/// - Pure logic: testable without repository/widget dependencies
/// - Matches existing HomeScreen behavior exactly
class ChatConnectionManager implements IChatConnectionManager {
  final _logger = Logger('ChatConnectionManager');

  final IConnectionService? _bleService;
  final Set<void Function(ConnectionStatus)> _connectionStatusListeners = {};

  StreamSubscription? _peripheralConnectionSubscription;
  StreamSubscription? _discoveryDataSubscription;

  ChatConnectionManager({IConnectionService? bleService})
    : _bleService = bleService;

  @override
  Future<void> initialize() async {
    await setupPeripheralConnectionListener();
    await setupDiscoveryListener();
    _logger.info('✅ ChatConnectionManager initialized');
  }

  @override
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, DiscoveredDevice> discoveryData,
    required DateTime? lastSeenTime,
  }) {
    // Check if this is the currently connected device
    if (currentConnectionInfo != null &&
        currentConnectionInfo.isConnected &&
        currentConnectionInfo.isReady &&
        currentConnectionInfo.otherUserName == contactName) {
      return ConnectionStatus.connected;
    }

    // Check if currently connecting to this device
    if (currentConnectionInfo != null &&
        currentConnectionInfo.isConnected &&
        !currentConnectionInfo.isReady) {
      final bleService = _bleService;
      if (bleService != null &&
          bleService.theirPersistentPublicKey == contactPublicKey) {
        return ConnectionStatus.connecting;
      }
    }

    // Check if device is nearby (discovered via BLE scan)
    if (contactPublicKey != null) {
      // Method 1: Check via manufacturer data hash
      final isOnlineViaHash = isContactOnlineViaHash(
        contactPublicKey: contactPublicKey,
        discoveryData: discoveryData,
      );
      if (isOnlineViaHash) {
        return ConnectionStatus.nearby;
      }

      // Method 2: Check via device UUID mapping (fallback)
      final isNearbyViaUUID = discoveredDevices.any(
        (device) => contactPublicKey.contains(device.uuid.toString()),
      );
      if (isNearbyViaUUID) {
        return ConnectionStatus.nearby;
      }
    }

    // Check if recently seen (within last 5 minutes)
    if (lastSeenTime != null) {
      final timeSinceLastSeen = DateTime.now().difference(lastSeenTime);
      if (timeSinceLastSeen.inMinutes <= 5) {
        return ConnectionStatus.recent;
      }
    }

    return ConnectionStatus.offline;
  }

  @override
  bool isContactOnlineViaHash({
    required String contactPublicKey,
    required Map<String, DiscoveredDevice> discoveryData,
  }) {
    if (discoveryData.isEmpty) return false;

    for (final device in discoveryData.values) {
      if (device.isKnownContact && device.contactInfo != null) {
        final contact = device.contactInfo!.contact;

        // 🔐 PRIVACY FIX: Only match current active session
        // This prevents identity linkage across ephemeral sessions for LOW security contacts

        // Match 1: Current ephemeral ID (active session)
        if (contact.currentEphemeralId == contactPublicKey) {
          _logger.fine(
            '🟢 ONLINE: Current session match for ${contact.displayName} (ephemeral)',
          );
          return true;
        }

        // Match 2: Persistent public key (MEDIUM+ security only)
        if (contact.persistentPublicKey != null &&
            contact.persistentPublicKey == contactPublicKey) {
          _logger.fine(
            '🟢 ONLINE: Persistent identity match for ${contact.displayName} (paired)',
          );
          return true;
        }

        // NO MATCH: Don't match by first publicKey - that would link old sessions
        // This is intentional for privacy - only current session shows online
      }
    }

    return false;
  }

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      Stream<ConnectionStatus>.multi((controller) {
        void listener(ConnectionStatus status) {
          controller.add(status);
        }

        _connectionStatusListeners.add(listener);
        controller.onCancel = () {
          _connectionStatusListeners.remove(listener);
        };
      });

  @override
  Future<void> setupPeripheralConnectionListener() async {
    if (!Platform.isAndroid) return;

    final bleService = _bleService;
    if (bleService == null) return;

    _peripheralConnectionSubscription = bleService.peripheralConnectionChanges
        .distinct(
          (prev, next) =>
              prev.central.uuid == next.central.uuid &&
              prev.state == next.state,
        )
        .where(
          (event) =>
              bleService.isPeripheralMode &&
              event.state == ble.ConnectionState.connected,
        )
        .listen((event) {
          _logger.info(
            '🔌 Peripheral connection from ${event.central.uuid.toString().substring(0, 8)}',
          );
          // Emit connection status change
          _notify(ConnectionStatus.nearby);
        });

    _logger.info('✅ Peripheral connection listener set up');
  }

  @override
  Future<void> setupDiscoveryListener() async {
    final bleService = _bleService;
    if (bleService == null) return;

    _discoveryDataSubscription = bleService.discoveryData.listen((
      discoveryData,
    ) {
      _logger.fine(
        '📡 Discovery data updated: ${discoveryData.length} devices',
      );
      // Emit that discovery changed (list coordinator will refresh)
      _notify(ConnectionStatus.nearby);
    });

    _logger.info('✅ Discovery data listener set up');
  }

  @override
  Map<String, DiscoveredDevice> getKnownContactsFromDiscovery(
    Map<String, DiscoveredDevice> discoveryData,
  ) {
    return Map.fromEntries(
      discoveryData.entries.where((entry) => entry.value.isKnownContact),
    );
  }

  @override
  bool isDeviceDiscovered({
    required String contactPublicKey,
    required List<Peripheral> discoveredDevices,
  }) {
    return discoveredDevices.any(
      (device) => contactPublicKey.contains(device.uuid.toString()),
    );
  }

  @override
  Future<void> dispose() async {
    await _peripheralConnectionSubscription?.cancel();
    await _discoveryDataSubscription?.cancel();
    _connectionStatusListeners.clear();
    _logger.info('♻️ ChatConnectionManager disposed');
  }

  void _notify(ConnectionStatus status) {
    for (final listener in List.of(_connectionStatusListeners)) {
      try {
        listener(status);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying connection status listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }
}
