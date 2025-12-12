import 'dart:async';
import 'dart:io' show Platform;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/models/connection_state.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../../core/bluetooth/connection_tracker.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../models/ble_client_connection.dart';
import '../../core/models/ble_server_connection.dart';
import '../models/connection_limit_config.dart';
import '../exceptions/connection_exceptions.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import '../../core/config/kill_switches.dart';
import 'connection_health_monitor.dart';
import 'connection_limit_enforcer.dart';
import 'ephemeral_contact_cleaner.dart';

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
  bool _isReconnection = false;

  ChatConnectionState _connectionState = ChatConnectionState.disconnected;

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
  ChatConnectionState get connectionState => _connectionState;
  bool get isActivelyReconnecting => _healthMonitor.isActivelyReconnecting;
  bool get isHealthChecking => _healthMonitor.isHealthChecking;
  bool get hasConnection => hasBleConnection;
  bool isCollisionResolving(String address) =>
      _collisionResolutionsInFlight.contains(address);
  bool isServerTeardownDeferred(String address) =>
      _deferredServerTeardown.contains(address);
  bool get hasCollisionResolutionInFlight =>
      _collisionResolutionsInFlight.isNotEmpty;
  bool get _isReady => _connectionState == ChatConnectionState.ready;
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
    if (_connectionState != newState) {
      _connectionState = newState;

      final info = ConnectionInfo(
        state: newState,
        deviceId: _connectedDevice?.uuid.toString(),
        displayName: null, // Will be filled by state manager
        error: error,
      );

      onConnectionInfoChanged?.call(info);
      _logger.info('Connection state: ${newState.name}');
    }
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
  }) async {
    final server = _serverConnections.remove(address);
    _peerHintsByAddress.remove(address);
    _blockedResponderHandshakes.remove(address);
    if (server != null) {
      try {
        await peripheralManager.disconnectCentral(server.central);
        _logger.info('🔌 Force disconnected inbound central: $address');
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to force disconnect central (might be unsupported): $e — retrying once',
        );
        try {
          await Future.delayed(const Duration(milliseconds: 200));
          await peripheralManager.disconnectCentral(server.central);
          _logger.info('🔌 Retry disconnect succeeded for inbound $address');
        } catch (secondError) {
          _logger.warning(
            '⚠️ Second disconnect attempt failed for inbound $address: $secondError',
          );
        }
      }

      _logger.info('🧹 Removed inbound server connection ($reasonLog)');
    }

    // Ensure tracker does not retain stale server-side entries
    _connectionTracker.removeConnection(address);

    _serverConnectionsController.add(serverConnections);
    _healthMonitor.setAwaitingHandshake(false);
    _updateAdvertisingState();
  }

  Future<void> _completeDeferredServerTeardown(
    String address, {
    required String reason,
  }) async {
    _blockedResponderHandshakes.remove(address);
    _deferredServerTeardown.remove(address);
    _deferredServerTeardownTimers.remove(address)?.cancel();
    await _removeServerConnection(address, reasonLog: reason);

    // Tracker should reflect the surviving client link so reconnect suppression stays active.
    _connectionTracker.removeConnection(
      address,
    ); // remove stale server-side entry
    final clientKey = _matchClientAddressByPeer(address);
    if (clientKey != null) {
      final client = _clientConnections[clientKey];
      _connectionTracker.addConnection(
        address: clientKey,
        isClient: true,
        rssi: client?.rssi,
      );
    }
  }

  void _scheduleDeferredServerTeardownCheck(String address) {
    _deferredServerTeardownTimers[address]?.cancel();
    // Short window: allow notify subscription or handshake kick-off to arrive.
    _deferredServerTeardownTimers[address] = Timer(
      const Duration(milliseconds: 1500),
      () async {
        if (!_deferredServerTeardown.contains(address)) return;

        final serverConn = _serverConnections[address];
        final hasSubscription = serverConn?.subscribedCharacteristic != null;
        if (hasSubscription || _healthMonitor.isHandshakeInProgress) {
          await _completeDeferredServerTeardown(
            address,
            reason: hasSubscription
                ? 'notify subscription observed'
                : 'handshake started during deferral',
          );
          return;
        }

        _logger.warning(
          '⚠️ Inbound link never became viable for ${_formatAddress(address)} — closing deferred server side',
        );

        await _completeDeferredServerTeardown(
          address,
          reason: 'non-viable inbound after deferral',
        );
      },
    );
  }

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
  }) async {
    _logger.info(
      '🚀 Starting mesh networking (simultaneous central + peripheral)',
    );

    try {
      // Start advertising FIRST (like BitChat)
      // ✅ NEW: Use callback to BLEService.startAsPeripheral() → AdvertisingManager
      if (onStartAdvertising != null) {
        _logger.info(
          '📡 Calling advertising callback (BLEService.startAsPeripheral)...',
        );
        await onStartAdvertising();
        _isAdvertising = true; // Assume success if no exception
        _logger.info(
          '✅ Peripheral role active (advertising via AdvertisingManager)',
        );
      } else {
        _logger.severe(
          '❌ No advertising callback provided - advertising will NOT start!',
        );
        throw Exception(
          'startMeshNetworking requires onStartAdvertising callback',
        );
      }

      // Central role is always ready (discovery initiated by BurstScanController)
      _logger.info('✅ Central role active (ready to scan)');
      _shouldBeAdvertising = true;

      _logger.info('🎉 Mesh networking started successfully');
      _logger.info('📊 Connection limits: $_limitConfig');
    } catch (e) {
      _logger.severe('❌ Failed to start mesh networking: $e');
      rethrow;
    }
  }

  /// 🛑 Stop mesh networking: Stop both central and peripheral operations
  Future<void> stopMeshNetworking() async {
    _logger.info('🛑 Stopping mesh networking');

    _shouldBeAdvertising = false;

    try {
      await _stopAdvertising();
      _logger.info('✅ Mesh networking stopped');
    } catch (e) {
      _logger.warning('⚠️ Error stopping mesh networking: $e');
    }
  }

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
  Future<void> _updateAdvertisingState() async {
    try {
      final shouldAdvertise = _shouldBeAdvertising && canAcceptServerConnection;

      if (shouldAdvertise && !_isAdvertising) {
        // ⚠️ CANNOT start advertising here - requires BLEService callback
        // Advertising is managed by AdvertisingManager in BLEService
        _logger.info(
          '📡 Should start advertising (server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})',
        );
        _logger.info(
          '⚠️ Advertising start requires BLEService.startAsPeripheral() - skipping',
        );
        // TODO: Consider adding a callback to BLEService for dynamic advertising control
      } else if (!shouldAdvertise && _isAdvertising) {
        // Stop advertising (at limit or user requested stop)
        final reason = !_shouldBeAdvertising
            ? 'user requested'
            : 'reached limit: $serverConnectionCount/${_limitConfig.maxServerConnections}';
        _logger.info('🛑 Stopping advertising ($reason)');
        await _stopAdvertising();
      }
    } catch (e) {
      _logger.warning('⚠️ Advertising state update failed: $e');
    }
  }

  // ❌ REMOVED: _startAdvertising() method
  // Advertising is now exclusively handled by:
  // BLEService.startAsPeripheral() → AdvertisingManager.startAdvertising()
  //
  // This ensures:
  // 1. Settings-aware hint inclusion (spy mode, online status)
  // 2. Single responsibility (one class manages all advertising)
  // 3. Consistent advertisement structure (no hint inconsistency bug)

  /// ⚖️ Resolve collision when a central connects to us while we have a client link
  Future<void> _resolveInboundCollision(String address) async {
    _collisionResolutionsInFlight.add(address);
    final clientAddress = _matchClientAddressByPeer(address);
    try {
      // Use the tie-breaker logic
      final yieldToInbound = await _shouldYieldToInboundLink(address);

      if (yieldToInbound) {
        _logger.info(
          '⚖️ Collision: Yielding to inbound server link. Disconnecting client.',
        );
        final clientKey = clientAddress ?? address;
        final client = _clientConnections[clientKey];
        if (client != null) {
          try {
            await centralManager.disconnect(client.peripheral);
          } catch (e) {
            _logger.warning('⚠️ Failed to disconnect stale client link: $e');
          }
          // Remove client after physical disconnect initiated
          _clientConnections.remove(clientKey);
        }
        // Ensure tracker reflects the surviving inbound link if present
        if (_serverConnections.containsKey(address)) {
          _connectionTracker.addConnection(
            address: address,
            isClient: false,
            rssi: null,
          );
          if (clientKey != null) {
            _connectionTracker.removeConnection(clientKey);
          }
        } else {
          if (clientKey != null) {
            _connectionTracker.removeConnection(clientKey);
          }
          _connectionTracker.removeConnection(address);
        }
      } else {
        _logger.info(
          '⚖️ Collision: Keeping client link. Closing inbound server side.',
        );
        _logger.fine(
          '⏸️ Deferring inbound teardown for ${_formatAddress(address)} until notify/handshake start',
        );
        _deferredServerTeardown.add(address);
        _scheduleDeferredServerTeardownCheck(address);
        _pendingClientConnections.remove(address);
        if (clientAddress != null) {
          _pendingClientConnections.remove(clientAddress);
        }
        _connectionTracker.clearAttempt(address);

        // Tracker should reflect the surviving client link so reconnect suppression stays active.
        final trackedClientKey = clientAddress ?? address;
        final client = _clientConnections[trackedClientKey];
        if (client != null) {
          _connectionTracker.addConnection(
            address: trackedClientKey,
            isClient: true,
            rssi: client.rssi,
          );
        } else {
          _connectionTracker.removeConnection(trackedClientKey);
        }
        // Removing the inbound link may free an advertising slot.
        _healthMonitor.setAwaitingHandshake(false);
        _serverConnectionsController.add(serverConnections);
        _updateAdvertisingState();
      }
    } catch (e) {
      _logger.warning('⚠️ Collision resolution failed: $e');
    } finally {
      _collisionResolutionsInFlight.remove(address);
    }
  }

  /// 🛑 Stop BLE advertising
  Future<void> _stopAdvertising() async {
    if (!_isAdvertising) {
      _logger.fine('🛑 Not advertising, skipping');
      return;
    }

    try {
      await peripheralManager.stopAdvertising();
      _isAdvertising = false;
      _logger.info('✅ Advertising stopped');
    } catch (e) {
      _logger.warning('⚠️ Failed to stop advertising: $e');
      // Non-critical - don't throw
    }
  }

  // 🔌 ========== PHASE 2B: CONNECTION HANDLERS ========== 🔌

  /// 📥 Handle incoming connection (we're peripheral, they're central)
  ///
  /// Called when a remote central connects to our advertising peripheral
  void handleCentralConnected(Central central) async {
    final address = central.uuid.toString();
    _trackPeerHintForAddress(address);
    final peerHint = _peerHintForAddress(address);
    final hasClientForPeer = hasClientLinkForPeer(address);
    final pendingClientForPeer = hasPendingClientForPeer(address);
    final hasServerForPeer = hasServerLinkForPeer(address);
    final hasHintCollision = hasAnyLinkForPeerHint(peerHint);

    // If we already have a client link to this peer, reject inbound duplicates
    // immediately to avoid dual handshakes/glare.
    // 🚀 NEW: Hard reject if we are already READY or have a client link/pending
    // dial to this peer (detected via address or shared discovery hint).
    // This prevents "glare" where we accept an inbound connection while we are already
    // fully connected/ready as a client, preventing dual-role confusion.
    if (_connectionState == ChatConnectionState.ready ||
        hasServerForPeer ||
        hasClientForPeer ||
        pendingClientForPeer ||
        hasHintCollision) {
      if (hasHintCollision || pendingClientForPeer) {
        _cancelPendingClientForPeer(
          address,
          reason: 'inbound duplicate detected',
        );
      }
      _logger.info(
        '🚫 Hard rejecting inbound from ${_formatAddress(address)}: '
        'Already ${_connectionState == ChatConnectionState.ready ? "READY" : "CLIENT_LINK_ACTIVE/PENDING"} '
        '(hintMatch=$hasHintCollision)',
      );
      try {
        _blockedResponderHandshakes.add(address);
        await peripheralManager.disconnectCentral(central);
        // Keep tracker aligned with the surviving client link if present.
        _ensureTrackerForClientPeer(address);
        _notifyInboundRejected(address);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to reject duplicate inbound for ${_formatAddress(address)}: $e',
        );
      }
      return;
    }

    if (_serverConnections.containsKey(address)) {
      _logger.warning(
        '⚠️ Central already connected: ${_formatAddress(address)} — rejecting duplicate inbound',
      );
      try {
        await peripheralManager.disconnectCentral(central);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to disconnect duplicate inbound central: $e',
        );
      }
      return;
    }

    final collisionWithClient = _clientConnections.containsKey(address);

    _logger.info(
      '📥 Central connected: ${_formatAddress(address)} (server connections: ${serverConnectionCount + 1}/${_limitConfig.maxServerConnections})',
    );
    _healthMonitor.setAwaitingHandshake(true);

    final connection = BLEServerConnection(
      address: address,
      central: central,
      connectedAt: DateTime.now(),
    );

    _serverConnections[address] = connection;
    _connectionTracker.addConnection(
      address: address,
      isClient: false,
      rssi: null,
    );
    _logger.info(
      '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
    );

    // Notify UI of server connection change
    _serverConnectionsController.add(serverConnections);

    // Update advertising state (may need to stop if at limit)
    _updateAdvertisingState();

    if (collisionWithClient) {
      _logger.info(
        '🔀 Collision detected with ${_formatAddress(address)} - resolving after server registration',
      );
      await _resolveInboundCollision(address);
      // Refresh stream in case the resolution removed/kept the server entry
      _serverConnectionsController.add(serverConnections);
    }
  }

  /// 📤 Handle incoming disconnection (central disconnected from us)
  ///
  /// Called when a remote central disconnects from our peripheral
  void handleCentralDisconnected(Central central) {
    final address = central.uuid.toString();
    _peerHintsByAddress.remove(address);
    _blockedResponderHandshakes.remove(address);

    final connection = _serverConnections.remove(address);
    if (connection != null) {
      _deferredServerTeardown.remove(address);
      _deferredServerTeardownTimers.remove(address)?.cancel();
      final duration = connection.connectedDuration;
      _logger.info(
        '📤 Central disconnected: ${_formatAddress(address)} (connected for: ${duration.inSeconds}s, server connections: $serverConnectionCount/${_limitConfig.maxServerConnections})',
      );
      _connectionTracker.removeConnection(address);

      // 🧹 REAL-TIME CLEANUP: Trigger immediate cleanup via BLEService
      // This will remove from deduplication manager and notify UI
      onCentralDisconnected?.call(address);
      if (_serverConnections.isEmpty) {
        _healthMonitor.setAwaitingHandshake(false);
        onCharacteristicFound?.call(null);
        onMtuDetected?.call(null);
      }
    } else {
      _logger.warning(
        '⚠️ Unknown central disconnected: ${_formatAddress(address)}',
      );
    }

    _logger.info(
      '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
    );

    // Notify UI of server connection change
    _serverConnectionsController.add(serverConnections);

    // Update advertising state (may need to resume if below limit)
    _updateAdvertisingState();
  }

  /// 📝 Handle characteristic subscription (central subscribed to our notifications)
  ///
  /// Called when a remote central subscribes to our characteristic
  void handleCharacteristicSubscribed(
    Central central,
    GATTCharacteristic characteristic,
  ) {
    final address = central.uuid.toString();
    final peerHint = _peerHintForAddress(address);
    final hasHintCollision = hasAnyLinkForPeerHint(peerHint);

    final connection = _serverConnections[address];
    if (connection != null) {
      if (hasHintCollision &&
          (_connectionState == ChatConnectionState.ready ||
              hasClientLinkForPeer(address) ||
              hasPendingClientForPeer(address))) {
        _logger.warning(
          '🚫 Duplicate inbound notify from ${_formatAddress(address)} (hint match) '
          'while client/ready link exists — dropping before subscription handling',
        );
        _cancelPendingClientForPeer(
          address,
          reason: 'duplicate inbound notify',
        );
        _blockedResponderHandshakes.add(address);
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'duplicate inbound notify (hint match)',
          ),
        );
        _notifyInboundRejected(address);
        return;
      }

      // If we already have a ready client link for this address, treat this as a late/duplicate inbound and drop it.
      if (_connectionTracker.isConnected(address) &&
          _clientConnections.containsKey(address) &&
          _connectionState == ChatConnectionState.ready) {
        _logger.warning(
          '⚠️ Late inbound notify from ${_formatAddress(address)} after client link is ready — disconnecting duplicate inbound',
        );
        _blockedResponderHandshakes.add(address);
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'late inbound after client ready',
          ),
        );
        _notifyInboundRejected(address);
        return;
      }

      _serverConnections[address] = connection.copyWith(
        subscribedCharacteristic: characteristic,
      );
      _logger.info(
        '📝 Central subscribed to notifications: ${_formatAddress(address)}',
      );
      if (_deferredServerTeardown.contains(address)) {
        _logger.fine(
          '⏸️ Deferred inbound teardown resolved by notify for ${_formatAddress(address)}',
        );
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'notify subscription arrived',
          ),
        );
      }
    } else {
      _logger.warning(
        '⚠️ Subscription from unknown central: ${_formatAddress(address)}',
      );
    }
  }

  void updateServerMtu(String address, int mtu) {
    final connection = _serverConnections[address];
    if (connection != null) {
      _serverConnections[address] = connection.copyWith(mtu: mtu);
      _logger.fine(
        '📏 Updated server MTU for ${_formatAddress(address)}: $mtu bytes',
      );
      if (_deferredServerTeardown.contains(address)) {
        _logger.fine(
          '⏸️ Deferred inbound teardown resolved by MTU negotiation for ${_formatAddress(address)}',
        );
        unawaited(
          _completeDeferredServerTeardown(
            address,
            reason: 'mtu observed during deferral',
          ),
        );
      }
    }
  }

  Future<bool> _shouldYieldToInboundLink(String address) async {
    if (_pendingClientConnections.contains(address)) {
      _logger.fine(
        '⏭️ Skipping inbound viability wait for ${_formatAddress(address)} because outbound dial is pending (favoring client link)',
      );
      return false;
    }

    if (_deferredServerTeardown.contains(address)) {
      _logger.fine(
        '⏭️ Skipping inbound viability wait for ${_formatAddress(address)} because deferral is active (keeping client link)',
      );
      return false;
    }

    bool _inboundViable(BLEServerConnection? conn) {
      if (conn == null) return false;
      final hasSubscription = conn.subscribedCharacteristic != null;
      final hasMtu = conn.mtu != null && conn.mtu! > 0;
      return hasSubscription || hasMtu;
    }

    Future<bool> _waitForInboundViable(Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final conn = _serverConnections[address];
        if (_inboundViable(conn)) return true;
        await Future.delayed(Duration(milliseconds: 50));
      }
      return _inboundViable(_serverConnections[address]);
    }

    try {
      final now = DateTime.now();
      final initialServerConn = _serverConnections[address];
      _logger.fine(
        '⏱️ Collision check @${now.toIso8601String()} for ${_formatAddress(address)} '
        '(pendingClient=${_pendingClientConnections.contains(address)}, '
        'handshakeInProgress=${_healthMonitor.isHandshakeInProgress}, '
        'awaitingHandshake=${_healthMonitor.awaitingHandshake})',
      );
      final serverConn = _serverConnections[address];
      final inboundWaitDuration = const Duration(milliseconds: 2500);
      final inboundViable = await _waitForInboundViable(inboundWaitDuration);
      _logger.fine(
        '📡 Inbound viability after $inboundWaitDuration '
        '(hadEntry=${initialServerConn != null}) -> $inboundViable',
      );

      if (inboundViable && serverConn != null) {
        _logger.info(
          '⚖️ Collision tie-breaker: inbound link is viable (subscribed/MTU) — yielding to inbound',
        );
        return true;
      }

      final remoteDevice = DeviceDeduplicationManager.getDevice(address);
      final remoteHint = remoteDevice?.ephemeralHint;
      final localHint = _localHintProvider != null
          ? await _localHintProvider!.call()
          : null;

      final localToken = (localHint != null && localHint.isNotEmpty)
          ? localHint
          : EphemeralKeyManager.generateMyEphemeralKey();
      final remoteToken =
          (remoteHint != null &&
              remoteHint.isNotEmpty &&
              remoteHint != DeviceDeduplicationManager.noHintValue)
          ? remoteHint
          : address;
      final comparison = localToken.compareTo(remoteToken);
      final preferInbound = comparison > 0;

      if (preferInbound && serverConn != null) {
        _logger.info(
          '⚖️ Collision tie-breaker: tokens local=$localToken remote=$remoteToken — inbound preferred by token',
        );
        if (!inboundViable) {
          _logger.info(
            '⚠️ Inbound not viable after wait for ${_formatAddress(address)} — keeping outbound link to preserve symmetry',
          );
          return false;
        }
        _logger.info(
          '⚖️ Collision tie-breaker: inbound viable and token-preferred — yielding to inbound',
        );
        return true;
      }

      _logger.info(
        '⚖️ Collision tie-breaker: tokens local=$localToken remote=$remoteToken — keeping client link',
      );
      return false;
    } catch (e) {
      _logger.warning(
        '⚖️ Collision tie-breaker failed ($address): $e — keeping client link',
      );
      return false;
    }
  }

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
  Future<void> handlePowerModeChange(PowerMode newMode) async {
    _logger.info('⚡ Power mode changed to: ${newMode.name}');

    final oldConfig = _limitConfig;
    final oldRssiThreshold = _rssiThreshold;

    _limitConfig = ConnectionLimitConfig.forPowerMode(newMode);
    _rssiThreshold = _limitEnforcer.rssiThresholdForPowerMode(newMode);

    _logger.info('🎯 Connection limits updated: $oldConfig → $_limitConfig');
    _logger.info(
      '📡 RSSI threshold updated: $oldRssiThreshold dBm → $_rssiThreshold dBm',
    );

    // Enforce new limits
    await _limitEnforcer.enforceConnectionLimits(
      limitConfig: _limitConfig,
      clientConnections: _clientConnections,
      serverConnections: _serverConnections,
      centralManager: centralManager,
      updateAdvertisingState: _updateAdvertisingState,
      formatAddress: _formatAddress,
    );

    // Update advertising based on new limits
    await _updateAdvertisingState();
  }

  void handleBluetoothStateChange(BluetoothLowEnergyState state) {
    if (state == BluetoothLowEnergyState.poweredOn) {
      if (_lastConnectedDevice != null && !hasBleConnection) {
        _logger.info('Bluetooth powered on - starting immediate reconnection');

        stopConnectionMonitoring();

        // Reduce delay for first-time connections
        Timer(Duration(milliseconds: 800), () {
          _isReconnection = true;
          startConnectionMonitoring();
        });
      } else {
        _logger.info(
          'Bluetooth powered on - no previous device, skipping reconnection',
        );
      }
    } else if (state == BluetoothLowEnergyState.poweredOff) {
      if (hasBleConnection) {
        _logger.info(
          'Bluetooth powered off - preserving device for reconnection',
        );
        _lastConnectedDevice = _connectedDevice;
      }
      clearConnectionState(keepMonitoring: false);
    }
  }

  /// Connect to a BLE peripheral device
  ///
  /// Phase 4: RSSI-based connection filtering
  /// - Optional [rssi] parameter allows filtering weak signals in low power modes
  /// - Threshold varies by power mode: -95 (performance) to -65 (ultra low)
  Future<void> connectToDevice(Peripheral device, {int? rssi}) async {
    final address = device.uuid.toString();
    _trackPeerHintForAddress(address);

    // Unified guard: if we already have ANY connection to this address, skip
    if (_connectionTracker.isConnected(address)) {
      _logger.fine(
        '↔️ Unified tracker: already connected to ${_formatAddress(address)} — skipping outbound connect',
      );
      return;
    }
    if (_clientConnections.containsKey(address) ||
        _serverConnections.containsKey(address)) {
      _logger.fine(
        '↔️ Existing link (client/server) to ${_formatAddress(address)} — skipping outbound connect',
      );
      return;
    }

    // Backoff guard: avoid rapid retries
    if (!_connectionTracker.canAttempt(address)) {
      _logger.fine(
        '⏳ Backing off reconnect to ${_formatAddress(address)} (pending attempt window)',
      );
      return;
    }
    _connectionTracker.markAttempt(address);

    if (_pendingClientConnections.contains(address)) {
      _logger.fine(
        '↻ Already connecting to ${_formatAddress(address)} - ignoring duplicate request',
      );
      return;
    }

    try {
      _pendingClientConnections.add(address);

      // Single-link policy: if inbound (server) link already exists to this address, adopt it and skip client connect
      if (_serverConnections.containsKey(address)) {
        _logger.info(
          '↔️ Single-link: inbound link already active for ${_formatAddress(address)} — skipping outbound connect',
        );
        return;
      }

      // Phase 4: RSSI-based connection filtering
      if (rssi != null && rssi < _rssiThreshold) {
        _logger.info(
          '📡 Skipping weak device: RSSI $rssi dBm < threshold $_rssiThreshold dBm '
          '(${_formatAddress(address)})',
        );
        return; // Silently skip weak signals
      }

      // Log RSSI if available
      if (rssi != null) {
        _logger.fine(
          '📡 Device RSSI: $rssi dBm (threshold: $_rssiThreshold dBm)',
        );
      }

      // Check connection limits
      if (!canAcceptClientConnection) {
        _logger.warning(
          '⚠️ Cannot accept client connection (limit: ${_limitConfig.maxClientConnections}, current: $clientConnectionCount, total: $totalConnectionCount)',
        );
        throw ConnectionLimitException(
          'Client connection limit reached',
          currentCount: clientConnectionCount,
          maxCount: _limitConfig.maxClientConnections,
        );
      }

      _logger.info(
        '🔌 Connecting to ${_formatAddress(address)} @${DateTime.now().toIso8601String()}...',
      );
      await Future.delayed(Duration(milliseconds: 500));

      // Robust connect: 20s timeout + one retry for transient errors (e.g., GATT 133/147)
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          _logger.info(
            '🔌 Connecting (attempt $attempt/2) to ${_formatAddress(address)} @${DateTime.now().toIso8601String()}...',
          );
          await centralManager
              .connect(device)
              .timeout(
                Duration(seconds: 20),
                onTimeout: () =>
                    throw Exception('Connection timeout after 20 seconds'),
              );
          break; // success
        } catch (e) {
          _logger.warning('❌ Connect attempt $attempt failed: $e');
          final transient = _limitEnforcer.isTransientConnectError(e);
          if (attempt < 2 && transient) {
            // Best-effort cleanup before retry
            try {
              await centralManager.disconnect(device);
            } catch (_) {}
            await Future.delayed(Duration(milliseconds: 1200));
            continue;
          } else {
            throw Exception(e.toString());
          }
        }
      }

      // Re-check for inbound collisions that may have happened while we were connecting.
      if (_serverConnections.containsKey(address)) {
        final yieldToInbound = await _shouldYieldToInboundLink(address);
        if (yieldToInbound) {
          _logger.info(
            '↔️ Collision policy yielded to inbound link for ${_formatAddress(address)} — abandoning client link',
          );
          // 🔌 CRITICAL FIX: Ensure we disconnect if we managed to connect before yielding
          try {
            await centralManager.disconnect(device);
          } catch (e) {
            _logger.warning('⚠️ Failed to disconnect yielded client link: $e');
          }
          _connectionTracker.clearAttempt(address);
          return;
        } else {
          _logger.info(
            '↔️ Collision policy prefers our client link for ${_formatAddress(address)} — keeping outbound connection',
          );
          // 🔧 FIX: Remove the redundant server connection and actively tear
          // down the inbound central so we avoid dual links.
          await _completeDeferredServerTeardown(
            address,
            reason: 'collision cleanup after outbound connect',
          );
        }
      }

      // Create client connection object
      var connection = BLEClientConnection(
        address: address,
        peripheral: device,
        connectedAt: DateTime.now(),
      );

      _clientConnections[address] = connection;
      _lastConnectedDevice = device;
      _connectionTracker.addConnection(
        address: address,
        isClient: true,
        rssi: rssi,
      );

      _logger.info(
        '✅ Connected to ${_formatAddress(address)} @${DateTime.now().toIso8601String()} (client connections: $clientConnectionCount/${_limitConfig.maxClientConnections})',
      );
      _logger.info(
        '📊 Total connections: $totalConnectionCount (client: $clientConnectionCount, server: $serverConnectionCount)',
      );

      onConnectionChanged?.call(device);

      // Negotiate MTU before service discovery so fragmentation sizing is accurate.
      await _detectOptimalMTU(device, address);

      // Discover GATT services with retry logic
      List<GATTService> services = [];
      GATTService? messagingService;

      for (int retry = 0; retry < 3; retry++) {
        try {
          _logger.info(
            'Discovering services, attempt ${retry + 1}/3 @${DateTime.now().toIso8601String()}',
          );
          services = await centralManager.discoverGATT(device);

          messagingService = services.firstWhere(
            (service) => service.uuid == BLEConstants.serviceUUID,
          );

          _logger.info(
            '✅ Messaging service found on attempt ${retry + 1} @${DateTime.now().toIso8601String()}',
          );
          break;
        } catch (e) {
          _logger.warning(
            '❌ Service discovery failed on attempt ${retry + 1}: $e',
          );

          if (retry < 2) {
            await Future.delayed(Duration(milliseconds: 1000));
          } else {
            throw Exception('Messaging service not found after 3 attempts');
          }
        }
      }

      if (messagingService == null) {
        throw Exception('Messaging service not found after retries');
      }

      // Find the message characteristic
      final messageChar = messagingService.characteristics.firstWhere(
        (char) => char.uuid == BLEConstants.messageCharacteristicUUID,
        orElse: () => throw Exception('Message characteristic not found'),
      );

      // Update connection with discovered characteristic
      connection = _clientConnections[address]!.copyWith(
        messageCharacteristic: messageChar,
      );
      _clientConnections[address] = connection;

      onCharacteristicFound?.call(messageChar);

      // Enable notifications
      if (messageChar.properties.contains(GATTCharacteristicProperty.notify)) {
        try {
          await centralManager.setCharacteristicNotifyState(
            device,
            messageChar,
            state: true,
          );
          _logger.info(
            '✅ Notifications enabled successfully @${DateTime.now().toIso8601String()}',
          );
          await Future.delayed(const Duration(milliseconds: 200));
        } catch (e) {
          final hasInbound =
              _serverConnections.containsKey(address) ||
              _deferredServerTeardown.contains(address);
          _logger.severe('CRITICAL: Failed to enable notifications: $e');
          if (hasInbound) {
            _logger.warning(
              '⏸️ Notify setup failed but inbound/deferral exists for ${_formatAddress(address)} — deferring to responder link instead of redialing',
            );
            _clientConnections.remove(address);
            _connectionTracker.removeConnection(address);
            try {
              await centralManager.disconnect(device);
            } catch (disconnectError) {
              _logger.warning(
                '⚠️ Failed to disconnect client after notify failure: $disconnectError',
              );
            }
            return;
          }
          throw Exception('Cannot enable notifications - connection unusable');
        }
      }

      _logger.info('🔐 BLE Connected - starting protocol setup');
      _updateConnectionState(ChatConnectionState.connecting);

      _logger.info('🔑 Triggering identity exchange');
      onConnectionComplete?.call();

      _isReconnection = false;
    } catch (e) {
      _logger.severe('❌ Connection failed: $e');
      _isReconnection = false;

      // Remove failed connection from map
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);

      clearConnectionState(keepMonitoring: _serverConnections.isNotEmpty);
      rethrow;
    } finally {
      _pendingClientConnections.remove(address);
      // Keep pending attempt entry for backoff unless we succeeded
      if (_connectionTracker.isConnected(address)) {
        _connectionTracker.clearAttempt(address);
      } else {
        _clearPeerHintIfUnused(address);
      }
    }
  }

  Future<void> _detectOptimalMTU(Peripheral device, String address) async {
    try {
      _logger.info('📏 Attempting MTU detection...');

      int negotiatedMTU = 23;

      if (Platform.isAndroid) {
        try {
          negotiatedMTU = await centralManager.requestMTU(device, mtu: 517);
          _logger.info(
            '✅ Successfully negotiated larger MTU: $negotiatedMTU bytes',
          );
        } catch (e) {
          _logger.warning('⚠️ MTU negotiation failed, using default 23: $e');
        }
      }

      final maxWriteLength = await centralManager.getMaximumWriteLength(
        device,
        type: GATTCharacteristicWriteType.withResponse,
      );

      final mtu = maxWriteLength.clamp(20, negotiatedMTU - 3);

      // Update connection with MTU
      final connection = _clientConnections[address];
      if (connection != null) {
        _clientConnections[address] = connection.copyWith(mtu: mtu);
      }

      _logger.info('✅ MTU detection successful: $mtu bytes');

      onMtuDetected?.call(mtu);
    } catch (e) {
      _logger.warning('❌ MTU detection completely failed: $e');
      const fallbackMtu = 20;

      // Update connection with fallback MTU
      final connection = _clientConnections[address];
      if (connection != null) {
        _clientConnections[address] = connection.copyWith(mtu: fallbackMtu);
      }

      _logger.info('⚠️ Using conservative fallback MTU: $fallbackMtu bytes');
      onMtuDetected?.call(fallbackMtu);
    }
  }

  void setMessageOperationInProgress(bool inProgress) {
    _healthMonitor.setMessageOperationInProgress(inProgress);
  }

  Future<Peripheral?> scanForSpecificDevice({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (centralManager.state != BluetoothLowEnergyState.poweredOn) {
      return null;
    }

    _logger.info('🔍 Scanning for service-advertising devices only');

    final completer = Completer<Peripheral?>();
    StreamSubscription? discoverySubscription;
    Timer? timeoutTimer;

    try {
      discoverySubscription = centralManager.discovered.listen((event) {
        _logger.info(
          '✅ Found device advertising our service: ${event.peripheral.uuid}',
        );
        if (!completer.isCompleted) {
          completer.complete(event.peripheral);
        }
      });

      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          _logger.info('⏰ Service scan timeout');
          completer.complete(null);
        }
      });

      await Future.delayed(Duration(milliseconds: 500));

      await centralManager.startDiscovery(
        serviceUUIDs: [BLEConstants.serviceUUID],
      );

      return await completer.future;
    } finally {
      await centralManager.stopDiscovery();
      discoverySubscription?.cancel();
      timeoutTimer?.cancel();
    }
  }

  /// 🔌 Disconnect all client connections
  Future<void> disconnectAll() async {
    _logger.info('🔌 Disconnecting all connections');

    stopConnectionMonitoring();

    // Disconnect all clients
    for (final conn in _clientConnections.values.toList()) {
      try {
        _logger.info(
          '🔌 Disconnecting client: ${_formatAddress(conn.address)}',
        );
        await centralManager.disconnect(conn.peripheral);
      } catch (e) {
        _logger.warning(
          '⚠️ Failed to disconnect ${_formatAddress(conn.address)}: $e',
        );
      }
    }

    // Stop advertising to clear server connections
    await _stopAdvertising();

    clearConnectionState();
  }

  /// 🔌 Disconnect specific client connection by address
  Future<void> disconnectClient(String address) async {
    final connection = _clientConnections[address];
    if (connection == null) {
      _logger.warning(
        '⚠️ Cannot disconnect: client not found ${_formatAddress(address)}',
      );
      return;
    }

    try {
      _logger.info('🔌 Disconnecting client: ${_formatAddress(address)}');
      await centralManager.disconnect(connection.peripheral);
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
      _peerHintsByAddress.remove(address);
      _logger.info('✅ Client disconnected: ${_formatAddress(address)}');
    } catch (e) {
      _logger.warning('⚠️ Failed to disconnect ${_formatAddress(address)}: $e');
      // Remove from map anyway
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
      _peerHintsByAddress.remove(address);
    }
  }

  /// 🔌 Legacy disconnect method (disconnects first client for backward compatibility)
  Future<void> disconnect() async {
    if (_clientConnections.isEmpty) {
      _logger.info('🔌 No connections to disconnect');
      clearConnectionState();
      return;
    }

    final firstConnection = _clientConnections.values.first;
    await disconnectClient(firstConnection.address);
  }

  void triggerReconnection() {
    if (!_healthMonitor.isMonitoring) {
      startConnectionMonitoring();
    } else {
      _healthMonitor.triggerImmediateReconnection();
    }
    _logger.info('Triggering immediate reconnection...');
  }

  void clearConnectionState({bool keepMonitoring = false, String? contactId}) {
    _logger.info('🧹 Clearing connection state');

    for (final timer in _deferredServerTeardownTimers.values) {
      timer.cancel();
    }
    _deferredServerTeardownTimers.clear();
    _deferredServerTeardown.clear();

    // Invalidate characteristic/MTU state eagerly to avoid stale handles on
    // subsequent reconnects or role flips.
    onCharacteristicFound?.call(null);
    onMtuDetected?.call(null);
    _healthMonitor.resetHandshakeFlags();

    // 🧹 CLEANUP: Remove orphaned ephemeral contacts immediately on disconnect
    // No need to wait for app restart - clean as we go!
    if (contactId != null) {
      _cleanupEphemeralContactIfOrphaned(contactId);
    } else {
      // Cleanup all client connections if no specific contactId
      for (final conn in _clientConnections.values) {
        _cleanupEphemeralContactIfOrphaned(conn.address);
      }
    }

    _clientConnections.clear();
    // Preserve server connections if we are still acting as responder.
    if (!keepMonitoring) {
      _serverConnections.clear();
      _connectionTracker.clear();
    } else {
      _connectionTracker.clear();
      for (final entry in _serverConnections.entries) {
        _connectionTracker.addConnection(address: entry.key, isClient: false);
      }
    }
    _peerHintsByAddress.clear();
    _blockedResponderHandshakes.clear();
    _noHintInboundDebounceUntil = null;
    _lastConnectedDevice = null;

    _isReconnection = false;

    _logger.info('📊 Connections cleared (client: 0, server: 0)');
    _updateConnectionState(ChatConnectionState.disconnected);

    if (!keepMonitoring) {
      stopConnectionMonitoring();
    }

    onConnectionChanged?.call(null);
  }

  /// 🧹 Clean up ephemeral contact immediately if they have no chat history
  /// Called on disconnect to keep database clean without waiting for app restart
  void _cleanupEphemeralContactIfOrphaned(String contactId) async {
    await EphemeralContactCleaner.cleanup(
      contactId: contactId,
      logger: _logger,
    );
  }

  /// 🎯 NEW: Check if current connection can serve as relay for pending messages
  bool _hasViableRelayConnection() {
    try {
      // Must have active connection
      if (!hasConnection || _connectedDevice == null) {
        return false;
      }

      if (_clientConnections.isNotEmpty &&
          (_healthMonitor.isHandshakeInProgress ||
              _healthMonitor.awaitingHandshake)) {
        _logger.fine(
          '⏸️ Treating client link as viable while handshake is in flight to avoid reconnection churn',
        );
        return true;
      }

      // Must have message characteristic to relay messages
      if (_messageCharacteristic == null) {
        return false;
      }

      // Connection must be ready (completed identity exchange)
      if (!_isReady) {
        return false;
      }

      _logger.info(
        '🔄 Viable relay connection detected: ${_connectedDevice?.uuid}',
      );
      return true;
    } catch (e) {
      _logger.warning('Error checking relay viability: $e');
      return false;
    }
  }

  void dispose() {
    stopConnectionMonitoring();
    _serverConnectionsController.close();
  }
}
