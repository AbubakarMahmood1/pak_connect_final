import 'dart:async';
import 'dart:io' show Platform;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import '../../core/constants/ble_constants.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/models/connection_state.dart';
import '../../core/power/adaptive_power_manager.dart';
import '../../core/bluetooth/connection_tracker.dart';
import '../models/ble_client_connection.dart';
import '../../core/models/ble_server_connection.dart';
import '../models/connection_limit_config.dart';
import '../exceptions/connection_exceptions.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
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

  // Unified tracker (client + server) to prevent reverse-connection races
  final BleConnectionTracker _connectionTracker = BleConnectionTracker();

  // Track devices we are actively trying to connect to so we can detect races
  final Set<String> _pendingClientConnections = {};

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
  bool get hasBleConnection => _connectedDevice != null;
  bool get isReconnection => _isReconnection;
  bool get isMonitoring => _healthMonitor.isMonitoring;
  ChatConnectionState get connectionState => _connectionState;
  bool get isActivelyReconnecting => _healthMonitor.isActivelyReconnecting;
  bool get isHealthChecking => _healthMonitor.isHealthChecking;
  bool get hasConnection => hasBleConnection;
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
    _lastConnectedDevice = _connectedDevice;
    _healthMonitor.start();
  }

  void stopConnectionMonitoring() => _healthMonitor.stop();

  void setPairingInProgress(bool inProgress) =>
      _healthMonitor.setPairingInProgress(inProgress);

  void setHandshakeInProgress(bool inProgress) =>
      _healthMonitor.setHandshakeInProgress(inProgress);

  void markHandshakeComplete() {
    _healthMonitor.markHandshakeComplete();
    _updateConnectionState(ChatConnectionState.ready);
  }

  void startHealthChecks() => _healthMonitor.startHealthChecks();

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
  void handleCentralConnected(Central central) {
    final address = central.uuid.toString();

    if (_serverConnections.containsKey(address)) {
      _logger.warning(
        '⚠️ Central already connected: ${_formatAddress(address)}',
      );
      return;
    }

    // Collision handling: if we already have an outbound (client) link to this peer, drop it and prefer inbound
    final existingClient = _clientConnections[address];
    if (existingClient != null) {
      _logger.info(
        '🔀 Collision detected with ${_formatAddress(address)} → preferring inbound (server) link, dropping outbound (client)',
      );
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
    }

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

    // Update advertising state (may need to stop if at limit)
    _updateAdvertisingState();
  }

  /// 📤 Handle incoming disconnection (central disconnected from us)
  ///
  /// Called when a remote central disconnects from our peripheral
  void handleCentralDisconnected(Central central) {
    final address = central.uuid.toString();

    final connection = _serverConnections.remove(address);
    if (connection != null) {
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

    final connection = _serverConnections[address];
    if (connection != null) {
      _serverConnections[address] = connection.copyWith(
        subscribedCharacteristic: characteristic,
      );
      _logger.info(
        '📝 Central subscribed to notifications: ${_formatAddress(address)}',
      );
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
    }
  }

  Future<bool> _shouldYieldToInboundLink(String address) async {
    try {
      final now = DateTime.now();
      _logger.fine(
        '⏱️ Collision check @${now.toIso8601String()} for ${_formatAddress(address)} '
        '(pendingClient=${_pendingClientConnections.contains(address)}, '
        'handshakeInProgress=${_healthMonitor.isHandshakeInProgress}, '
        'awaitingHandshake=${_healthMonitor.awaitingHandshake})',
      );
      final serverConn = _serverConnections[address];
      final inboundReady =
          serverConn?.subscribedCharacteristic != null ||
          (serverConn?.mtu != null && serverConn!.mtu! > 0);
      final handshakeActive =
          _healthMonitor.isHandshakeInProgress ||
          _healthMonitor.awaitingHandshake;

      final clientConn = _clientConnections[address];
      if (clientConn != null &&
          now.difference(clientConn.connectedAt) < const Duration(seconds: 2)) {
        _logger.fine(
          '⚖️ Collision tie-breaker: within post-connect grace for ${_formatAddress(address)} — keeping client link',
        );
        return false;
      }

      final inboundViable = inboundReady;
      if (serverConn != null && !inboundViable) {
        _logger.fine(
          '⚖️ Collision tie-breaker: inbound not viable yet for ${_formatAddress(address)} — keeping client link',
        );
        return false;
      }

      final remoteDevice = DeviceDeduplicationManager.getDevice(address);
      final remoteHint = remoteDevice?.ephemeralHint;
      final localHint = _localHintProvider != null
          ? await _localHintProvider!.call()
          : null;

      final hasComparableHints =
          localHint != null &&
          localHint.isNotEmpty &&
          remoteHint != null &&
          remoteHint.isNotEmpty &&
          remoteHint != DeviceDeduplicationManager.noHintValue;

      if (hasComparableHints) {
        final comparison = localHint.compareTo(remoteHint);
        // Use deterministic hint ordering: higher hint yields to inbound.
        if (comparison > 0) {
          _logger.info(
            '⚖️ Collision tie-breaker: our hint ($localHint) > remote ($remoteHint) — yielding to inbound link',
          );
          return true;
        }
        if (comparison < 0) {
          _logger.info(
            '⚖️ Collision tie-breaker: our hint ($localHint) < remote ($remoteHint) — keeping client link',
          );
          return false;
        }
        _logger.info(
          '⚖️ Collision tie-breaker: hints identical ($localHint) — keeping client link to avoid double-drop',
        );
        return false;
      }

      if (handshakeActive) {
        _logger.fine(
          '⚖️ Collision tie-breaker: handshake active, insufficient hint data — keeping client link to ensure an initiator',
        );
        return false;
      }

      if (_pendingClientConnections.contains(address)) {
        _logger.fine(
          '⚖️ Collision tie-breaker: outbound connect pending for ${_formatAddress(address)} — keeping client link (no deterministic hint)',
        );
        return false;
      }

      _logger.info(
        '⚖️ Collision tie-breaker: insufficient hint data (local=$localHint, remote=$remoteHint) — yielding to inbound link (first link wins)',
      );
      return true;
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

    // Unified guard: if we already have ANY connection to this address, skip
    if (_connectionTracker.isConnected(address)) {
      _logger.fine(
        '↔️ Unified tracker: already connected to ${_formatAddress(address)} — skipping outbound connect',
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
          _connectionTracker.clearAttempt(address);
          return;
        } else {
          _logger.info(
            '↔️ Collision policy prefers our client link for ${_formatAddress(address)} — keeping outbound connection',
          );
          // 🔧 FIX: Remove the redundant server connection to prevent phantom entries in UI
          final removedConnection = _serverConnections.remove(address);
          if (removedConnection != null) {
            _logger.fine(
              '🧹 Cleaned up redundant server connection for ${_formatAddress(address)}',
            );
          }
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

          await Future.delayed(Duration(milliseconds: 500));
        } catch (e) {
          _logger.severe('CRITICAL: Failed to enable notifications: $e');
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

      clearConnectionState();
      rethrow;
    } finally {
      _pendingClientConnections.remove(address);
      // Keep pending attempt entry for backoff unless we succeeded
      if (_connectionTracker.isConnected(address)) {
        _connectionTracker.clearAttempt(address);
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
      _logger.info('✅ Client disconnected: ${_formatAddress(address)}');
    } catch (e) {
      _logger.warning('⚠️ Failed to disconnect ${_formatAddress(address)}: $e');
      // Remove from map anyway
      _clientConnections.remove(address);
      _connectionTracker.removeConnection(address);
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
  }
}
