import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../domain/constants/ble_constants.dart';
import '../../domain/services/device_deduplication_manager.dart';
import '../../domain/models/connection_state.dart';
import '../../domain/services/adaptive_power_manager.dart';
import '../../domain/services/ble_connection_tracker.dart';
import '../../domain/services/ephemeral_key_manager.dart';
import '../models/ble_client_connection.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import '../models/connection_limit_config.dart';
import '../exceptions/connection_exceptions.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'package:pak_connect/domain/config/kill_switches.dart';
import 'connection_health_monitor.dart';
import 'connection_limit_enforcer.dart';
import 'ephemeral_contact_cleaner.dart';
import 'ble_connection_state_machine.dart';
import 'ble_connection_gatt_controller.dart';
import 'ble_connection_reconnect_policy.dart';

part 'ble_connection_manager_runtime_helper.dart';

class BLEConnectionManager {
  final _logger = Logger('BLEConnectionManager');
  final CentralManager centralManager;
  final PeripheralManager peripheralManager;

  // 🎯 Phase 2b: Multi-connection tracking
  // Client connections: We act as central, connecting TO peripherals
  final Map<String, BLEClientConnection> _clientConnections = {};

  // Server connections: We act as peripheral, others connect TO us
  final Map<String, BLEServerConnection> _serverConnections = {};

  // Track stable discovery hints per address so hint-based matching works even
  // after OS MAC rotations or dedup merges.
  final Map<String, String?> _peerHintsByAddress = {};

  // Unified tracker (client + server) to prevent reverse-connection races
  final BleConnectionTracker _connectionTracker = BleConnectionTracker();

  // Track devices we are actively trying to connect to so we can detect races
  final Set<String> _pendingClientConnections = {};

  // Callback to abort responder handshake when an inbound is rejected as duplicate.
  Function(String address)? onInboundDuplicateRejected;

  // Debounce window for inbound-first behavior when no hint is available.
  DateTime? _noHintInboundDebounceUntil;

  // Connection limits (platform + power mode aware)
  late ConnectionLimitConfig _limitConfig;
  late final ConnectionLimitEnforcer _limitEnforcer;

  // RSSI filtering (Phase 4: Adaptive Sync Frequency - RSSI-based connection filtering)
  int _rssiThreshold = -85; // Default: Balanced mode threshold

  // Collision-resolution hint provider (supplied by BLEService)
  Future<String?> Function()? _localHintProvider;

  // For backward compatibility with existing health check logic
  // Returns first client connection's peripheral
  Peripheral? get _connectedDevice =>
      _clientConnections.values.firstOrNull?.peripheral;
  Peripheral? _lastConnectedDevice;
  final Set<String> _collisionResolutionsInFlight = {};
  final Set<String> _deferredServerTeardown = {};
  final Map<String, Timer> _deferredServerTeardownTimers = {};
  // Block responder handshakes for addresses we plan to drop (duplicate inbound).
  final Set<String> _blockedResponderHandshakes = {};
  GATTCharacteristic? get _messageCharacteristic =>
      _clientConnections.values.firstOrNull?.messageCharacteristic;
  int? get _mtuSize => _clientConnections.values.firstOrNull?.mtu;

  // Advertising control (Phase 2b: Hybrid advertising strategy)
  bool _isAdvertising = false;
  bool _shouldBeAdvertising = true; // Whether we WANT to advertise

  // Simplified monitoring system
  late final ConnectionHealthMonitor _healthMonitor;
  late final BleConnectionStateMachine _stateMachine;
  late final BleConnectionGattController _gattController;
  late final BleConnectionReconnectPolicy _reconnectPolicy;
  bool _isReconnection = false;

  // Constants
  static const int maxReconnectAttempts = 5;
  static const int minInterval = 3000;
  static const int maxInterval = 30000;
  static const int healthCheckInterval = 5000;

  // Callbacks for parent service
  Function(Peripheral?)? onConnectionChanged;
  Function(GATTCharacteristic?)? onCharacteristicFound;
  Function(int?)? onMtuDetected;
  Function()? onConnectionComplete;
  Function(bool)? onMonitoringChanged;
  Function(ConnectionInfo)? onConnectionInfoChanged;

  // 🧹 REAL-TIME CLEANUP: Callback for central disconnect events
  Function(String deviceAddress)? onCentralDisconnected;

  // 📡 Real-time stream for server connections (Discovery Overlay)
  final _serverConnectionsController =
      StreamController<List<BLEServerConnection>>.broadcast();
  Stream<List<BLEServerConnection>> get serverConnectionsStream =>
      _serverConnectionsController.stream;

  BLEConnectionManager({
    required this.centralManager,
    required this.peripheralManager,
    PowerMode initialPowerMode = PowerMode.balanced,
  }) {
    _reconnectPolicy = BleConnectionReconnectPolicy(logger: _logger);
    _limitEnforcer = ConnectionLimitEnforcer(logger: _logger);
    _limitConfig = ConnectionLimitConfig.forPowerMode(initialPowerMode);
    _rssiThreshold = _limitEnforcer.rssiThresholdForPowerMode(initialPowerMode);
    _logger.info('🎯 Connection limits initialized: $_limitConfig');
    _logger.info(
      '📡 RSSI threshold: $_rssiThreshold dBm (${initialPowerMode.name} mode)',
    );

    _healthMonitor = ConnectionHealthMonitor(
      logger: _logger,
      centralManager: centralManager,
      minInterval: minInterval,
      maxInterval: maxInterval,
      maxReconnectAttempts: maxReconnectAttempts,
      healthCheckInterval: healthCheckInterval,
      getConnectedDevice: () => _connectedDevice,
      getMessageCharacteristic: () => _messageCharacteristic,
      hasBleConnection: () => hasBleConnection,
      clearConnectionState: ({bool keepMonitoring = false}) async =>
          clearConnectionState(keepMonitoring: keepMonitoring),
      scanForSpecificDevice:
          ({Duration timeout = const Duration(seconds: 8)}) =>
              scanForSpecificDevice(timeout: timeout),
      connectToDevice: (device) => connectToDevice(device),
      hasViableRelayConnection: _hasViableRelayConnection,
      onMonitoringChanged: onMonitoringChanged,
      onReconnectionFlagChanged: (value) => _isReconnection = value,
      // Treat any active link (client or server) as connected so reconnection
      // suppression works during inbound-only sessions.
      hasActiveClientLink: () =>
          _clientConnections.isNotEmpty || _serverConnections.isNotEmpty,
      isCollisionResolving: () => hasCollisionResolutionInFlight,
      hasPendingClientConnection: () => _pendingClientConnections.isNotEmpty,
    );

    _stateMachine = BleConnectionStateMachine(
      logger: _logger,
      connectedDeviceProvider: () => _connectedDevice,
      onStateChanged: (info) => onConnectionInfoChanged?.call(info),
    );

    _gattController = BleConnectionGattController(
      logger: _logger,
      centralManager: centralManager,
      isTransientConnectError: _limitEnforcer.isTransientConnectError,
    );
  }

  void setLocalHintProvider(Future<String?> Function()? provider) {
    _localHintProvider = provider;
  }

  // Getters - Backward compatibility
  Peripheral? get connectedDevice => _connectedDevice;
  Peripheral? get lastConnectedDevice => _lastConnectedDevice;
  GATTCharacteristic? get messageCharacteristic => _messageCharacteristic;
  int? get mtuSize => _mtuSize;
  // Count either role as "connected" so health/reconnect logic does not redial
  // when an inbound/server link is already up.
  bool get hasBleConnection =>
      _clientConnections.isNotEmpty || _serverConnections.isNotEmpty;
  bool get isReconnection => _isReconnection;
  bool get isMonitoring => _healthMonitor.isMonitoring;
  ChatConnectionState get connectionState => _stateMachine.state;
  bool get isActivelyReconnecting => _healthMonitor.isActivelyReconnecting;
  bool get isHealthChecking => _healthMonitor.isHealthChecking;
  bool get hasConnection => hasBleConnection;
  bool isCollisionResolving(String address) =>
      _collisionResolutionsInFlight.contains(address);
  bool isServerTeardownDeferred(String address) =>
      _deferredServerTeardown.contains(address);
  bool get hasCollisionResolutionInFlight =>
      _collisionResolutionsInFlight.isNotEmpty;
  bool get _isReady => _stateMachine.isReady;
  bool get isHandshakeInProgress => _healthMonitor.isHandshakeInProgress;
  bool get awaitingHandshake => _healthMonitor.awaitingHandshake;

  // 🎯 Phase 2b: Multi-connection getters
  int get clientConnectionCount => _clientConnections.length;
  int get serverConnectionCount => _serverConnections.length;
  int get totalConnectionCount => clientConnectionCount + serverConnectionCount;

  bool get canAcceptClientConnection => _limitConfig.canAcceptClientConnection(
    clientConnectionCount,
    totalConnectionCount,
  );

  bool get canAcceptServerConnection => _limitConfig.canAcceptServerConnection(
    serverConnectionCount,
    totalConnectionCount,
  );

  bool get isAdvertising => _isAdvertising;
  List<BLEClientConnection> get clientConnections =>
      _clientConnections.values.toList();
  List<BLEServerConnection> get serverConnections =>
      _serverConnections.values.toList();
  List<String> get connectedAddresses {
    final set = <String>{};
    set.addAll(_clientConnections.keys);
    set.addAll(_serverConnections.keys);
    return set.toList();
  }

  bool _isMeaningfulHint(String? hint) =>
      hint != null &&
      hint.isNotEmpty &&
      hint != DeviceDeduplicationManager.noHintValue;

  String? _peerHintForAddress(String address) {
    final stored = _peerHintsByAddress[address];
    if (_isMeaningfulHint(stored)) return stored;

    final dedupHint = DeviceDeduplicationManager.getDevice(
      address,
    )?.ephemeralHint;
    if (_isMeaningfulHint(dedupHint)) {
      _peerHintsByAddress[address] = dedupHint;
      return dedupHint;
    }

    return stored ?? dedupHint;
  }

  void _trackPeerHintForAddress(String address) {
    final hint = DeviceDeduplicationManager.getDevice(address)?.ephemeralHint;
    if (hint != null) {
      _peerHintsByAddress[address] = hint;
    }
    // If no hint, start a short inbound-first debounce to let the server side settle
    // before any outbound dial with missing hint could collide.
    if (!_isMeaningfulHint(hint)) {
      _noHintInboundDebounceUntil = DateTime.now().add(
        const Duration(seconds: 3),
      );
    }
  }

  /// Keep in-memory hint cache aligned with dedup map so rotated MACs still map
  /// to the same peer.
  void refreshPeerHintsFromDedup() {
    for (final address in _clientConnections.keys) {
      _peerHintForAddress(address);
    }
    for (final address in _serverConnections.keys) {
      _peerHintForAddress(address);
    }
    for (final address in _pendingClientConnections) {
      _peerHintForAddress(address);
    }
  }

  /// Seed a hint for a soon-to-be-connected address so veto logic can match
  /// against existing peers even before the OS link stabilizes.
  void cachePeerHintForAddress(String address, String? hint) {
    if (_isMeaningfulHint(hint)) {
      _peerHintsByAddress[address] = hint;
    }
  }

  bool isResponderHandshakeBlocked(String address) =>
      _blockedResponderHandshakes.contains(address);

  void _clearPeerHintIfUnused(String address) {
    if (_clientConnections.containsKey(address) ||
        _serverConnections.containsKey(address) ||
        _pendingClientConnections.contains(address)) {
      return;
    }
    _peerHintsByAddress.remove(address);
  }

  bool hasAnyLinkForPeerHint(String? peerHint) {
    if (!_isMeaningfulHint(peerHint)) return false;
    bool matchesAddress(String address) {
      final hint = _peerHintForAddress(address);
      return _isMeaningfulHint(hint) && hint == peerHint;
    }

    return _clientConnections.keys.any(matchesAddress) ||
        _serverConnections.keys.any(matchesAddress) ||
        _pendingClientConnections.any(matchesAddress);
  }

  /// Identify if an inbound/server address maps to an existing client link
  /// (by direct address match or shared discovery hint).
  String? _matchClientAddressByPeer(String peerAddress) {
    if (_clientConnections.containsKey(peerAddress)) return peerAddress;

    final peerHint = _peerHintForAddress(peerAddress);
    if (!_isMeaningfulHint(peerHint)) return null;

    for (final entry in _clientConnections.entries) {
      final clientHint = _peerHintForAddress(entry.key);
      if (_isMeaningfulHint(clientHint) && clientHint == peerHint) {
        return entry.key;
      }
    }
    return null;
  }

  /// Identify if an inbound/server address maps to an existing server link
  /// (by direct address match or shared discovery hint).
  String? _matchServerAddressByPeer(String peerAddress) {
    if (_serverConnections.containsKey(peerAddress)) return peerAddress;

    final peerHint = _peerHintForAddress(peerAddress);
    if (!_isMeaningfulHint(peerHint)) return null;

    for (final entry in _serverConnections.entries) {
      final serverHint = _peerHintForAddress(entry.key);
      if (_isMeaningfulHint(serverHint) && serverHint == peerHint) {
        return entry.key;
      }
    }
    return null;
  }

  /// Identify if an inbound/server address maps to a pending outbound dial
  /// (by direct address match or shared discovery hint).
  String? _matchPendingClientAddressByPeer(String peerAddress) {
    if (_pendingClientConnections.contains(peerAddress)) return peerAddress;

    final peerHint = _peerHintForAddress(peerAddress);
    if (!_isMeaningfulHint(peerHint)) return null;

    for (final pending in _pendingClientConnections) {
      final pendingHint = _peerHintForAddress(pending);
      if (_isMeaningfulHint(pendingHint) && pendingHint == peerHint) {
        return pending;
      }
    }
    return null;
  }

  bool hasClientLinkForPeer(String peerAddress) =>
      _matchClientAddressByPeer(peerAddress) != null;

  bool hasServerLinkForPeer(String peerAddress) =>
      _matchServerAddressByPeer(peerAddress) != null;

  bool hasPendingClientForPeer(String peerAddress) =>
      _matchPendingClientAddressByPeer(peerAddress) != null;

  void _notifyInboundRejected(String address) {
    _healthMonitor.setAwaitingHandshake(false);
    _healthMonitor.setHandshakeInProgress(false);
    onInboundDuplicateRejected?.call(address);
  }

  bool _isNoHintInboundDebounceActive() {
    if (_noHintInboundDebounceUntil == null) return false;
    final now = DateTime.now();
    if (now.isAfter(_noHintInboundDebounceUntil!)) {
      _noHintInboundDebounceUntil = null;
      return false;
    }
    return true;
  }

  bool get isNoHintDebounceActive => _isNoHintInboundDebounceActive();

  void _cancelPendingClientForPeer(String peerAddress, {String reason = ''}) {
    final pendingAddress = _matchPendingClientAddressByPeer(peerAddress);
    if (pendingAddress == null) return;

    _logger.fine(
      '⏹️ Cancelling pending outbound dial for ${_formatAddress(pendingAddress)}'
      '${reason.isNotEmpty ? ' ($reason)' : ''}',
    );
    _pendingClientConnections.remove(pendingAddress);
    _connectionTracker.clearAttempt(pendingAddress);
    _connectionTracker.removeConnection(pendingAddress);
    _clearPeerHintIfUnused(pendingAddress);
  }

  void _ensureTrackerForClientPeer(String peerAddress) {
    final clientAddress = _matchClientAddressByPeer(peerAddress);
    if (clientAddress == null) return;
    final client = _clientConnections[clientAddress];
    _connectionTracker.addConnection(
      address: clientAddress,
      isClient: true,
      rssi: client?.rssi,
    );
  }

  // Legacy getter for burst scan optimization (now uses new connection tracking)
  int get activeConnectionCount => clientConnectionCount;
  bool get canAcceptMoreConnections => canAcceptClientConnection;
  List<Peripheral> get activeConnections =>
      _clientConnections.values.map((c) => c.peripheral).toList();

  // Expose connection limits for logging
  int get maxClientConnections => _limitConfig.maxClientConnections;

  void _updateConnectionState(ChatConnectionState newState, {String? error}) {
    _stateMachine.update(newState, error: error);
  }

  void startConnectionMonitoring() {
    if (KillSwitches.disableAutoConnect || KillSwitches.disableHealthChecks) {
      _logger.warning(
        '⚠️ Connection monitoring disabled via kill switch (autoConnect=${KillSwitches.disableAutoConnect}, healthChecks=${KillSwitches.disableHealthChecks})',
      );
      return;
    }
    _lastConnectedDevice = _connectedDevice;
    _healthMonitor.start();
  }

  void stopConnectionMonitoring() => _healthMonitor.stop();

  void setPairingInProgress(bool inProgress) =>
      _healthMonitor.setPairingInProgress(inProgress);

  void setHandshakeInProgress(bool inProgress) {
    _healthMonitor.setHandshakeInProgress(inProgress);
    if (inProgress) {
      final address = _connectedDevice?.uuid.toString();
      if (address != null && _deferredServerTeardown.contains(address)) {
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'client handshake started',
          ),
        );
      }
    }
  }

  void markHandshakeComplete() {
    _healthMonitor.markHandshakeComplete();
    _updateConnectionState(ChatConnectionState.ready);
  }

  void startHealthChecks() => _healthMonitor.startHealthChecks();

  Future<void> _removeServerConnection(
    String address, {
    String reasonLog = 'client wins',
  }) => _runtimeRemoveServerConnection(address, reasonLog: reasonLog);

  Future<void> _completeDeferredServerTeardown(
    String address, {
    required String reason,
  }) => _runtimeCompleteDeferredServerTeardown(address, reason: reason);

  void _scheduleDeferredServerTeardownCheck(String address) =>
      _runtimeScheduleDeferredServerTeardownCheck(address);

  // 🚀 ========== PHASE 2B: SIMULTANEOUS OPERATION ========== 🚀

  /// 🚀 Start mesh networking: Simultaneous central + peripheral operation
  ///
  /// This starts both roles in parallel:
  /// - Peripheral role: Start advertising our mesh service
  /// - Central role: Ready to scan and connect to other peripherals
  ///
  /// Following BitChat model: Advertising runs continuously, scanning is duty-cycled
  ///
  /// ✅ NEW: Advertising is now handled by AdvertisingManager via callback
  Future<void> startMeshNetworking({
    Future<void> Function()? onStartAdvertising,
  }) => _runtimeStartMeshNetworking(onStartAdvertising: onStartAdvertising);

  /// 🛑 Stop mesh networking: Stop both central and peripheral operations
  Future<void> stopMeshNetworking() => _runtimeStopMeshNetworking();

  /// 🎛️ Hybrid advertising control: Stop at connection limit, resume when below
  ///
  /// This implements the hybrid strategy:
  /// - Advertise when: Below server connection limit
  /// - Stop when: At or above server connection limit
  /// - Resume when: Server connection drops below limit
  ///
  /// ⚠️ NOTE: This method only handles STOPPING advertising.
  /// Starting advertising is handled by BLEService.startAsPeripheral() → AdvertisingManager.
  /// This is because advertising requires business logic (settings, hints) that belongs in BLEService.
  Future<void> _updateAdvertisingState() => _runtimeUpdateAdvertisingState();

  // ❌ REMOVED: _startAdvertising() method
  // Advertising is now exclusively handled by:
  // BLEService.startAsPeripheral() → AdvertisingManager.startAdvertising()
  //
  // This ensures:
  // 1. Settings-aware hint inclusion (spy mode, online status)
  // 2. Single responsibility (one class manages all advertising)
  // 3. Consistent advertisement structure (no hint inconsistency bug)

  /// ⚖️ Resolve collision when a central connects to us while we have a client link
  Future<void> _resolveInboundCollision(String address) =>
      _runtimeResolveInboundCollision(address);

  /// 🛑 Stop BLE advertising
  Future<void> _stopAdvertising() => _runtimeStopAdvertising();

  // 🔌 ========== PHASE 2B: CONNECTION HANDLERS ========== 🔌

  /// 📥 Handle incoming connection (we're peripheral, they're central)
  ///
  /// Called when a remote central connects to our advertising peripheral
  void handleCentralConnected(Central central) async {
    await _runtimeHandleCentralConnected(central);
  }

  /// 📤 Handle incoming disconnection (central disconnected from us)
  ///
  /// Called when a remote central disconnects from our peripheral
  void handleCentralDisconnected(Central central) =>
      _runtimeHandleCentralDisconnected(central);

  /// 📝 Handle characteristic subscription (central subscribed to our notifications)
  ///
  /// Called when a remote central subscribes to our characteristic
  void handleCharacteristicSubscribed(
    Central central,
    GATTCharacteristic characteristic,
  ) => _runtimeHandleCharacteristicSubscribed(central, characteristic);

  void updateServerMtu(String address, int mtu) =>
      _runtimeUpdateServerMtu(address, mtu);

  Future<bool> _shouldYieldToInboundLink(String address) =>
      _runtimeShouldYieldToInboundLink(address);

  /// Allow responder to continue if client disconnects after yielding.
  bool hasServerConnection(String address) =>
      _serverConnections[address] != null;

  /// 🔍 Format address for logging (first 8 chars)
  String _formatAddress(String address) {
    return address.length > 8 ? '${address.shortId(8)}...' : address;
  }

  // ⚡ ========== PHASE 2B: POWER MODE MANAGEMENT ========== ⚡

  /// ⚡ Handle power mode changes: Adjust connection limits and RSSI threshold
  ///
  /// Called when user changes power mode or battery level triggers auto-change
  /// Enforces new connection limits by disconnecting oldest connections
  Future<void> handlePowerModeChange(PowerMode newMode) =>
      _runtimeHandlePowerModeChange(newMode);

  void handleBluetoothStateChange(BluetoothLowEnergyState state) =>
      _runtimeHandleBluetoothStateChange(state);

  /// Connect to a BLE peripheral device
  ///
  /// Phase 4: RSSI-based connection filtering
  /// - Optional [rssi] parameter allows filtering weak signals in low power modes
  /// - Threshold varies by power mode: -95 (performance) to -65 (ultra low)
  Future<void> connectToDevice(Peripheral device, {int? rssi}) =>
      _runtimeConnectToDevice(device, rssi: rssi);

  void setMessageOperationInProgress(bool inProgress) {
    _healthMonitor.setMessageOperationInProgress(inProgress);
  }

  Future<Peripheral?> scanForSpecificDevice({
    Duration timeout = const Duration(seconds: 10),
  }) => _runtimeScanForSpecificDevice(timeout: timeout);

  /// 🔌 Disconnect all client connections
  Future<void> disconnectAll() => _runtimeDisconnectAll();

  /// 🔌 Disconnect specific client connection by address
  Future<void> disconnectClient(String address) =>
      _runtimeDisconnectClient(address);

  /// 🔌 Legacy disconnect method (disconnects first client for backward compatibility)
  Future<void> disconnect() => _runtimeDisconnect();

  void triggerReconnection() => _runtimeTriggerReconnection();

  void clearConnectionState({bool keepMonitoring = false, String? contactId}) =>
      _runtimeClearConnectionState(
        keepMonitoring: keepMonitoring,
        contactId: contactId,
      );

  /// 🧹 Clean up ephemeral contact immediately if they have no chat history
  /// Called on disconnect to keep database clean without waiting for app restart
  void _cleanupEphemeralContactIfOrphaned(String contactId) =>
      _runtimeCleanupEphemeralContactIfOrphaned(contactId);

  /// 🎯 NEW: Check if current connection can serve as relay for pending messages
  bool _hasViableRelayConnection() => _runtimeHasViableRelayConnection();

  void dispose() => _runtimeDispose();
}
