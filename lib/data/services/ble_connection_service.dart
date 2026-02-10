import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_connection_service.dart';
import '../../core/models/connection_info.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../data/services/ble_connection_manager.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../core/security/security_types.dart';
import '../../core/utils/string_extensions.dart';
import '../../core/models/connection_state.dart' show ChatConnectionState;
import '../../core/config/kill_switches.dart';

/// Manages BLE connection lifecycle including connection state and monitoring.
///
/// Extracted from BLEService in Phase 2A.2.2c as part of refactoring.
///
/// Responsibility: Handle all connection-related operations
/// - Central role connection initiation and termination
/// - Connection state monitoring and health checks
/// - Connection info broadcasting and deduplication
/// - Identity recovery and auto-connect callbacks
class BLEConnectionService implements IBLEConnectionService {
  final _logger = Logger('BLEConnectionService');

  // Dependencies injected at initialization
  final IBLEStateManagerFacade stateManager;
  final BLEConnectionManager connectionManager;
  final CentralManager centralManager;
  final BluetoothStateMonitor bluetoothStateMonitor;

  // Callback to update connection info in facade
  final Function({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  })
  onUpdateConnectionInfo;

  // Listener set for connection info updates (replaces manual controller)
  final Set<void Function(ConnectionInfo)> _connectionInfoListeners = {};

  // Connection state
  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Disconnected',
  );
  ConnectionInfo? _lastEmittedConnectionInfo;

  // Peripheral mode connection tracking (shared with advertising service)
  @override
  Central? connectedCentral;
  GATTCharacteristic? connectedCharacteristic;
  bool peripheralHandshakeStarted = false;
  bool meshNetworkingStarted = false;

  // Callbacks for lifecycle events
  Future<void> Function()? onStartAdvertising;

  BLEConnectionService({
    required this.stateManager,
    required this.connectionManager,
    required this.centralManager,
    required this.bluetoothStateMonitor,
    required this.onUpdateConnectionInfo,
  });

  // ============================================================================
  // SETUP: Initialize connection monitoring (called by facade)
  // ============================================================================

  void setupConnectionInitialization() {
    _logger.info('🔗 Setting up connection initialization...');
    _setupAutoConnectCallback();
    _setupEventListeners();
    _setupConnectionChangeHandler();
    _logger.info('✅ Connection initialization setup complete');
  }

  void _setupConnectionChangeHandler() {
    connectionManager.onConnectionChanged = (peripheral) {
      if (peripheral != null) {
        unawaited(_resolveConnectionContact(peripheral));
      }
    };
  }

  Future<void> _resolveConnectionContact(Peripheral peripheral) async {
    try {
      final persistentKey =
          stateManager.theirPersistentKey ?? stateManager.currentSessionId;
      if (persistentKey == null || persistentKey.isEmpty) return;

      final contactRepo = ContactRepository();
      final contact = await contactRepo.getContactByAnyId(persistentKey);
      final displayName =
          contact?.displayName ??
          stateManager.otherUserName ??
          'User ${persistentKey.shortId(8)}';

      final enhanced = EnhancedContact(
        contact:
            contact ??
            Contact(
              publicKey: persistentKey,
              persistentPublicKey: persistentKey,
              currentEphemeralId: null,
              displayName: displayName,
              trustStatus: TrustStatus.newContact,
              securityLevel: SecurityLevel.low,
              firstSeen: DateTime.now(),
              lastSeen: DateTime.now(),
              lastSecuritySync: null,
              noisePublicKey: null,
              noiseSessionState: null,
              lastHandshakeTime: null,
              isFavorite: false,
            ),
        lastSeenAgo: contact != null
            ? DateTime.now().difference(contact.lastSeen)
            : Duration.zero,
        isRecentlyActive: contact != null
            ? DateTime.now().difference(contact.lastSeen).inHours < 24
            : true,
        interactionCount: 0,
        averageResponseTime: const Duration(minutes: 5),
        groupMemberships: const [],
      );

      DeviceDeduplicationManager.updateResolvedContact(
        peripheral.uuid.toString(),
        enhanced,
      );
    } catch (e, stackTrace) {
      _logger.fine('Failed to resolve connection contact: $e');
      _logger.finer(stackTrace.toString());
    }
  }

  @override
  void disposeConnection() {
    stopConnectionMonitoring();
    _connectionInfoListeners.clear();
  }

  // ============================================================================
  // IMPLEMENTATION: Extracted from BLEService (lines 2286-3312)
  // ============================================================================

  @override
  Future<void> connectToDevice(Peripheral device) async {
    try {
      // Single-link policy: if we already have an inbound (server) link to this peer, adopt it
      try {
        final inboundId = connectedCentral?.uuid.toString();
        if (inboundId != null && inboundId == device.uuid.toString()) {
          _logger.info(
            '🔀 Single-link: inbound link exists to ${device.uuid} — adopting inbound, skipping outbound connect',
          );
          _updateConnectionInfo(statusMessage: 'Connected via inbound link');
          return;
        }
      } catch (_) {}

      // Stop any active discovery first
      try {
        await centralManager.stopDiscovery();
      } catch (e) {
        // Ignore
      }

      _updateConnectionInfo(isConnected: false, statusMessage: 'Connecting...');
      await connectionManager.connectToDevice(device);

      if (connectionManager.hasBleConnection) {
        connectionManager.startHealthChecks();

        if (connectionManager.isReconnection) {
          _logger.info('Reconnection completed - monitoring already active');
        } else {
          _logger.info(
            'Manual connection - health checks started, no reconnection monitoring',
          );
          _updateConnectionInfo(isReconnecting: false);
        }
      } else if (connectionManager.serverConnectionCount > 0) {
        _logger.info(
          '↔️ Adopted inbound link - skipping outbound health checks',
        );
        _updateConnectionInfo(
          isReconnecting: false,
          statusMessage: 'Connected via inbound link',
        );
      } else {
        _logger.warning(
          '⚠️ Connect attempt returned without an active BLE link',
        );
        _updateConnectionInfo(isReconnecting: false);
      }
    } catch (e) {
      _updateConnectionInfo(
        isConnected: false,
        isReady: false,
        statusMessage: 'Connection failed',
      );
      rethrow;
    }
  }

  @override
  Future<void> disconnect() => connectionManager.disconnect();

  @override
  void startConnectionMonitoring() {
    if (KillSwitches.disableAutoConnect || KillSwitches.disableHealthChecks) {
      _logger.warning(
        '⚠️ Connection monitoring disabled via kill switch (autoConnect=${KillSwitches.disableAutoConnect}, healthChecks=${KillSwitches.disableHealthChecks})',
      );
      return;
    }
    connectionManager.startConnectionMonitoring();
  }

  @override
  void stopConnectionMonitoring() =>
      connectionManager.stopConnectionMonitoring();

  @override
  void setHandshakeInProgress(bool isInProgress) =>
      connectionManager.setHandshakeInProgress(isInProgress);

  @override
  void setPairingInProgress(bool isInProgress) =>
      connectionManager.setPairingInProgress(isInProgress);

  @override
  Future<ConnectionInfo?> getConnectionInfoWithFallback() async {
    if (!isConnected) return null;

    try {
      // Get identity with fallback mechanism
      final identityInfo = await stateManager.getIdentityWithFallback();
      final displayName = identityInfo['displayName'] ?? 'Connected Device';
      final publicKey = identityInfo['publicKey'] ?? '';
      final source = identityInfo['source'] ?? 'unknown';

      _logger.info('🔄 CONNECTION INFO: Retrieved with fallback');
      _logger.info('  - Display name: $displayName');
      _logger.info(
        '  - Public key: ${publicKey.isNotEmpty
            ? publicKey.length > 16
                  ? '${publicKey.substring(0, 16)}...'
                  : publicKey
            : "none"}',
      );
      _logger.info('  - Source: $source');

      return ConnectionInfo(
        isConnected: true,
        isReady: true,
        otherUserName: displayName,
        statusMessage: source == 'repository'
            ? 'Connected (restored)'
            : 'Ready to chat',
      );
    } catch (e) {
      _logger.warning('Failed to get connection info with fallback: $e');
      return null;
    }
  }

  @override
  Future<bool> attemptIdentityRecovery() async {
    if (!isConnected) {
      _logger.info('🔄 RECOVERY: No BLE connection - cannot recover identity');
      return false;
    }

    if (stateManager.otherUserName != null &&
        stateManager.otherUserName!.isNotEmpty) {
      _logger.info(
        '🔄 RECOVERY: Session identity already available - no recovery needed',
      );
      return true;
    }

    _logger.info(
      '🔄 RECOVERY: Attempting identity recovery from persistent storage...',
    );

    try {
      await stateManager.recoverIdentityFromStorage();

      // Check if recovery was successful
      final recovered =
          stateManager.otherUserName != null &&
          stateManager.otherUserName!.isNotEmpty;

      if (recovered) {
        _logger.info('✅ RECOVERY: Identity successfully recovered');
        _logger.info('  - Name: ${stateManager.otherUserName}');
        final sessionIdDisplay = stateManager.currentSessionId != null
            ? (stateManager.currentSessionId!.length > 16
                  ? '${stateManager.currentSessionId!.substring(0, 8)}...'
                  : stateManager.currentSessionId!)
            : 'null';
        _logger.info('  - Session ID: $sessionIdDisplay');
        _logger.info(
          '  - Type: ${stateManager.isPaired ? "PAIRED" : "UNPAIRED"}',
        );

        // Update connection info to reflect recovered state
        _updateConnectionInfo(
          isConnected: true,
          isReady: true,
          otherUserName: stateManager.otherUserName,
          statusMessage: 'Connected (restored)',
        );
      } else {
        _logger.warning('❌ RECOVERY: Failed to recover identity from storage');
      }

      return recovered;
    } catch (e) {
      _logger.severe('❌ RECOVERY: Identity recovery failed: $e');
      return false;
    }
  }

  // Connection state management
  void _updateConnectionInfo({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
  }) {
    final newInfo = _currentConnectionInfo.copyWith(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );

    // Check if this is a meaningful change
    if (_shouldEmitConnectionInfo(newInfo)) {
      _currentConnectionInfo = newInfo;
      _lastEmittedConnectionInfo = newInfo;
      for (final listener in List.of(_connectionInfoListeners)) {
        try {
          listener(_currentConnectionInfo);
        } catch (e, stackTrace) {
          _logger.warning(
            'Error notifying connection info listener: $e',
            e,
            stackTrace,
          );
        }
      }
      _logger.fine('✅ Connection info emitted: ${newInfo.statusMessage}');
    }

    // Always call facade callback for cross-service coordination
    onUpdateConnectionInfo(
      isConnected: isConnected,
      isReady: isReady,
      otherUserName: otherUserName,
      statusMessage: statusMessage,
      isScanning: isScanning,
      isAdvertising: isAdvertising,
      isReconnecting: isReconnecting,
    );
  }

  bool _shouldEmitConnectionInfo(ConnectionInfo newInfo) {
    if (_lastEmittedConnectionInfo == null) return true;

    final last = _lastEmittedConnectionInfo!;

    // Only emit if there's a meaningful change
    return last.isConnected != newInfo.isConnected ||
        last.isReady != newInfo.isReady ||
        last.otherUserName != newInfo.otherUserName ||
        last.isScanning != newInfo.isScanning ||
        last.isAdvertising != newInfo.isAdvertising ||
        last.isReconnecting != newInfo.isReconnecting ||
        last.statusMessage != newInfo.statusMessage;
  }

  // Setup callbacks and listeners
  void _setupAutoConnectCallback() {
    _logger.info('🔗 Setting up auto-connect callback for known contacts...');

    DeviceDeduplicationManager.shouldAutoConnect = (device) {
      final deviceId = device.deviceId;
      // Seed the hint cache so rotated MACs map correctly and refresh existing
      // links before evaluating the veto.
      connectionManager.cachePeerHintForAddress(deviceId, device.ephemeralHint);
      connectionManager.refreshPeerHintsFromDedup();

      // Debounce when a no-hint inbound is in progress.
      if (connectionManager.serverConnectionCount > 0 &&
          connectionManager.hasAnyLinkForPeerHint(device.ephemeralHint)) {
        _logger.info(
          '🛑 AUTO-CONNECT: Suppressing for ${deviceId.shortId(8)} '
          '(server link present for hint ${device.ephemeralHint})',
        );
        return false;
      }

      if (connectionManager.serverConnectionCount > 0 &&
          !connectionManager.hasAnyLinkForPeerHint(device.ephemeralHint) &&
          connectionManager.isNoHintDebounceActive) {
        _logger.info(
          '🛑 AUTO-CONNECT: Suppressing for ${deviceId.shortId(8)} '
          '(no-hint inbound debounce active)',
        );
        return false;
      }

      // Debounce when any server link exists for the same hint to avoid
      // simultaneous outbound + inbound on role glare.
      // If we are already in a non-disconnected state, avoid layering another dial.
      if (connectionManager.connectionState !=
          ChatConnectionState.disconnected) {
        _logger.info(
          '🛑 AUTO-CONNECT: Suppressing for ${deviceId.shortId(8)} '
          '(state=${connectionManager.connectionState.name})',
        );
        return false;
      }

      final hasClientForPeer = connectionManager.hasClientLinkForPeer(deviceId);
      final hasServerForPeer = connectionManager.hasServerLinkForPeer(deviceId);
      final hasPendingClientForPeer = connectionManager.hasPendingClientForPeer(
        deviceId,
      );
      final hasHintCollision = connectionManager.hasAnyLinkForPeerHint(
        device.ephemeralHint,
      );
      final ChatConnectionState connectionState =
          connectionManager.connectionState;

      if (hasClientForPeer ||
          hasServerForPeer ||
          hasPendingClientForPeer ||
          hasHintCollision) {
        _logger.info(
          '🛑 AUTO-CONNECT: Suppressing for ${deviceId.shortId(8)} '
          '(clientLink=$hasClientForPeer, serverLink=$hasServerForPeer, '
          'pendingDial=$hasPendingClientForPeer, '
          'hintMatch=$hasHintCollision, state=${connectionState.name})',
        );
        return false;
      }

      return true;
    };

    DeviceDeduplicationManager
        .onKnownContactDiscovered = (device, contactName) async {
      final deviceId = device.uuid.toString();
      _logger.info('👤 KNOWN CONTACT DISCOVERED: $contactName');

      try {
        // Check connection slot availability
        final currentSlots = connectionManager.clientConnectionCount;
        final maxSlots = connectionManager.maxClientConnections;

        if (!connectionManager.canAcceptClientConnection) {
          _logger.warning(
            '⚠️ AUTO-CONNECT: Cannot connect to $contactName - slots full ($currentSlots/$maxSlots)',
          );
          return;
        }

        // Check if already connected (either direction)
        final alreadyConnected = connectionManager.connectedAddresses.contains(
          deviceId,
        );

        if (alreadyConnected) {
          _logger.info(
            '🔗 AUTO-CONNECT: Already connected to $contactName - skipping',
          );
          return;
        }

        _logger.info(
          '✅ AUTO-CONNECT: Initiating connection to $contactName...',
        );
        await connectToDevice(device);
        _logger.info('✅ AUTO-CONNECT: Successfully connected to $contactName!');
      } catch (e, stackTrace) {
        _logger.warning(
          '❌ AUTO-CONNECT: Failed to connect to $contactName: $e',
        );
        _logger.fine('Stack trace: $stackTrace');
      }
    };

    _logger.info('✅ Auto-connect callback registered successfully');
  }

  void _setupEventListeners() {
    // Central manager state changes
    centralManager.stateChanged.listen((event) async {
      _logger.info('Central BLE State changed: ${event.state}');

      if (event.state == BluetoothLowEnergyState.poweredOff) {
        _updateConnectionInfo(
          isConnected: false,
          isReady: false,
          statusMessage: 'Bluetooth off',
        );

        // Only clear session state if there's actually a connection to clear
        final hasActiveSession =
            stateManager.otherUserName != null ||
            connectedCentral != null ||
            connectionManager.connectedDevice != null;

        if (hasActiveSession) {
          _logger.fine('🔌 Active session detected - clearing session state');
          stateManager.clearSessionState();
        }
      } else if (event.state == BluetoothLowEnergyState.poweredOn) {
        if (stateManager.isPeripheralMode) {
          _updateConnectionInfo(
            isAdvertising: true,
            statusMessage: 'Discoverable',
          );
        } else {
          _updateConnectionInfo(statusMessage: 'Ready to scan');
        }
      }

      // Handle state changes for reconnection
      connectionManager.handleBluetoothStateChange(event.state);

      if (event.state == BluetoothLowEnergyState.unauthorized) {
        try {
          _logger.info('Requesting BLE permissions...');
          final granted = await centralManager.authorize();
          _logger.info('Permission granted: $granted');
        } catch (e) {
          _logger.warning('Permission request failed: $e');
        }
      }
    });
  }

  // ============================================================================
  // PUBLIC API: Getters and streams
  // ============================================================================

  @override
  Stream<ConnectionInfo> get connectionInfoStream =>
      Stream<ConnectionInfo>.multi((controller) {
        controller.add(_currentConnectionInfo);

        void listener(ConnectionInfo info) {
          controller.add(info);
        }

        _connectionInfoListeners.add(listener);
        controller.onCancel = () {
          _connectionInfoListeners.remove(listener);
        };
      });

  @override
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;

  @override
  bool get isConnected {
    final bleConnected = !stateManager.isPeripheralMode
        ? connectionManager.connectedDevice != null
        : connectedCentral != null;

    final hasSessionIdentity =
        stateManager.otherUserName != null &&
        stateManager.otherUserName!.isNotEmpty;
    final hasSessionId =
        stateManager.currentSessionId != null &&
        stateManager.currentSessionId!.isNotEmpty;

    final hasIdentity = hasSessionIdentity || hasSessionId;
    return bleConnected && hasIdentity;
  }

  @override
  bool get isMonitoring => connectionManager.isMonitoring;

  @override
  Peripheral? get connectedDevice => connectionManager.connectedDevice;

  @override
  String? get otherUserName => stateManager.otherUserName;

  @override
  String? get currentSessionId => stateManager.currentSessionId;

  @override
  String? get theirEphemeralId => stateManager.theirEphemeralId;

  @override
  String? get theirPersistentKey => stateManager.theirPersistentKey;

  @override
  String? get myPersistentId => stateManager.myPersistentId;

  @override
  bool get isActivelyReconnecting =>
      !stateManager.isPeripheralMode &&
      connectionManager.isActivelyReconnecting;

  @override
  bool get hasPeripheralConnection =>
      connectedCentral != null && connectedCharacteristic != null;

  @override
  bool get hasCentralConnection =>
      connectionManager.hasBleConnection &&
      connectionManager.messageCharacteristic != null;

  @override
  bool get canSendMessages => hasPeripheralConnection || hasCentralConnection;

  @override
  ConnectionInfo? getConnectionInfo() => currentConnectionInfo;
}
