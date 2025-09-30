import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

/// Enhanced Bluetooth state monitoring and management system
/// Provides robust handling for Bluetooth state changes with user-friendly messaging
class BluetoothStateMonitor {
  static final _logger = Logger('BluetoothStateMonitor');
  static BluetoothStateMonitor? _instance;

  // State tracking
  BluetoothLowEnergyState _currentState = BluetoothLowEnergyState.unknown;
  bool _isInitialized = false;
  Timer? _retryTimer;
  Timer? _permissionTimer;

  // Stream controllers
  final StreamController<BluetoothStateInfo> _stateController =
      StreamController<BluetoothStateInfo>.broadcast();
  final StreamController<BluetoothStatusMessage> _messageController =
      StreamController<BluetoothStatusMessage>.broadcast();

  // Callbacks
  VoidCallback? _onBluetoothReady;
  VoidCallback? _onBluetoothUnavailable;
  VoidCallback? _onInitializationRetry;

  // Configuration
  final Duration _retryInterval = const Duration(seconds: 3);
  final Duration _permissionCheckInterval = const Duration(seconds: 1);
  final int _maxRetryAttempts = 10;
  int _retryAttempts = 0;

  BluetoothStateMonitor._();

  /// Get singleton instance
  static BluetoothStateMonitor get instance {
    _instance ??= BluetoothStateMonitor._();
    return _instance!;
  }

  /// Stream of Bluetooth state information
  Stream<BluetoothStateInfo> get stateStream => _stateController.stream;

  /// Stream of user-friendly status messages
  Stream<BluetoothStatusMessage> get messageStream => _messageController.stream;

  /// Current Bluetooth state
  BluetoothLowEnergyState get currentState => _currentState;

  /// Whether Bluetooth is ready for use
  bool get isBluetoothReady => _currentState == BluetoothLowEnergyState.poweredOn;

  /// Whether the system is initialized
  bool get isInitialized => _isInitialized;

  /// Initialize the Bluetooth state monitor
  Future<void> initialize({
    VoidCallback? onBluetoothReady,
    VoidCallback? onBluetoothUnavailable,
    VoidCallback? onInitializationRetry,
  }) async {
    if (_isInitialized) {
      _logger.info('Bluetooth state monitor already initialized');
      return;
    }

    _onBluetoothReady = onBluetoothReady;
    _onBluetoothUnavailable = onBluetoothUnavailable;
    _onInitializationRetry = onInitializationRetry;

    _logger.info('🔵 Initializing Bluetooth state monitor...');

    try {
      // Check initial state
      await _checkInitialBluetoothState();

      _isInitialized = true;
      _logger.info('✅ Bluetooth state monitor initialized successfully');

    } catch (e) {
      _logger.severe('❌ Failed to initialize Bluetooth state monitor: $e');
      _emitMessage(BluetoothStatusMessage.error(
        'Failed to initialize Bluetooth monitoring: $e'
      ));
      rethrow;
    }
  }

  /// Check initial Bluetooth state and setup monitoring
  Future<void> _checkInitialBluetoothState() async {
    try {
      final centralManager = CentralManager();
      final peripheralManager = PeripheralManager();

      // Get initial states
      final centralState = centralManager.state;
      final peripheralState = peripheralManager.state;

      _logger.info('Initial Bluetooth states - Central: $centralState, Peripheral: $peripheralState');

      // Use the more restrictive state
      _currentState = _getMostRestrictiveState(centralState, peripheralState);

      // Setup state change listeners
      _setupStateChangeListeners(centralManager, peripheralManager);

      // Process initial state
      await _processBluetoothState(_currentState, isInitial: true);

    } catch (e) {
      _logger.severe('Failed to check initial Bluetooth state: $e');
      _currentState = BluetoothLowEnergyState.unknown;
      _emitMessage(BluetoothStatusMessage.error(
        'Unable to access Bluetooth system'
      ));
      rethrow;
    }
  }

  /// Setup listeners for Bluetooth state changes
  void _setupStateChangeListeners(CentralManager centralManager, PeripheralManager peripheralManager) {
    // Central manager state changes
    centralManager.stateChanged.listen((event) {
      _logger.info('Central Bluetooth state changed: ${event.state}');
      _handleStateChange(event.state, 'Central');
    });

    // Peripheral manager state changes
    peripheralManager.stateChanged.listen((event) {
      _logger.info('Peripheral Bluetooth state changed: ${event.state}');
      _handleStateChange(event.state, 'Peripheral');
    });
  }

  /// Handle Bluetooth state changes
  void _handleStateChange(BluetoothLowEnergyState newState, String source) {
    final previousState = _currentState;
    _currentState = newState;

    _logger.info('🔵 Bluetooth state change detected:');
    _logger.info('  - Source: $source');
    _logger.info('  - Previous: $previousState');
    _logger.info('  - Current: $newState');

    // Process the state change
    _processBluetoothState(newState, previousState: previousState);
  }

  /// Process Bluetooth state and take appropriate actions
  Future<void> _processBluetoothState(
    BluetoothLowEnergyState state, {
    BluetoothLowEnergyState? previousState,
    bool isInitial = false,
  }) async {
    // Clear any existing timers
    _cancelTimers();

    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        await _handleBluetoothReady(isInitial: isInitial);
        break;

      case BluetoothLowEnergyState.poweredOff:
        await _handleBluetoothOff();
        break;

      case BluetoothLowEnergyState.unauthorized:
        await _handleBluetoothUnauthorized();
        break;

      case BluetoothLowEnergyState.unsupported:
        await _handleBluetoothUnsupported();
        break;

      case BluetoothLowEnergyState.unknown:
        await _handleBluetoothUnknown(isInitial: isInitial);
        break;

      // Note: BluetoothLowEnergyState.resetting doesn't exist in this version
      // case BluetoothLowEnergyState.resetting:
      //   await _handleBluetoothResetting();
      //   break;
    }

    // Emit state information
    _emitStateInfo(BluetoothStateInfo(
      state: state,
      previousState: previousState,
      isReady: state == BluetoothLowEnergyState.poweredOn,
      timestamp: DateTime.now(),
    ));
  }

  /// Handle Bluetooth ready state
  Future<void> _handleBluetoothReady({bool isInitial = false}) async {
    _logger.info('✅ Bluetooth is ready');
    _retryAttempts = 0; // Reset retry counter

    final message = isInitial
        ? 'Bluetooth ready for mesh networking'
        : 'Bluetooth enabled - mesh networking available';

    _emitMessage(BluetoothStatusMessage.ready(message));

    // Notify callback
    _onBluetoothReady?.call();
  }

  /// Handle Bluetooth disabled state
  Future<void> _handleBluetoothOff() async {
    _logger.warning('⚠️ Bluetooth is disabled');

    _emitMessage(BluetoothStatusMessage.disabled(
      'Bluetooth is disabled. Please enable Bluetooth to use mesh networking.'
    ));

    // Start retry monitoring
    _startBluetoothRetryMonitoring();

    // Notify callback
    _onBluetoothUnavailable?.call();
  }

  /// Handle unauthorized Bluetooth state
  Future<void> _handleBluetoothUnauthorized() async {
    _logger.warning('⚠️ Bluetooth permissions not granted');

    _emitMessage(BluetoothStatusMessage.unauthorized(
      'Bluetooth permission required. Please grant permission in app settings.'
    ));

    // Start permission monitoring
    _startPermissionMonitoring();

    _onBluetoothUnavailable?.call();
  }

  /// Handle unsupported Bluetooth state
  Future<void> _handleBluetoothUnsupported() async {
    _logger.severe('❌ Bluetooth not supported on this device');

    _emitMessage(BluetoothStatusMessage.unsupported(
      'Bluetooth Low Energy is not supported on this device. Mesh networking is unavailable.'
    ));

    _onBluetoothUnavailable?.call();
  }

  /// Handle unknown Bluetooth state
  Future<void> _handleBluetoothUnknown({bool isInitial = false}) async {
    _logger.warning('⚠️ Bluetooth state unknown');

    if (isInitial) {
      _emitMessage(BluetoothStatusMessage.initializing(
        'Checking Bluetooth status...'
      ));

      // Start initialization retry
      _startInitializationRetry();
    } else {
      _emitMessage(BluetoothStatusMessage.unknown(
        'Bluetooth status unknown. Checking...'
      ));
    }
  }

  // Note: Bluetooth resetting state is not available in this version

  /// Start monitoring for Bluetooth to be enabled
  void _startBluetoothRetryMonitoring() {
    if (_retryAttempts >= _maxRetryAttempts) {
      _logger.warning('Max retry attempts reached for Bluetooth monitoring');
      _emitMessage(BluetoothStatusMessage.error(
        'Bluetooth has been disabled for an extended period. Please enable it manually.'
      ));
      return;
    }

    _retryTimer = Timer(_retryInterval, () async {
      _retryAttempts++;
      _logger.info('Retry attempt $_retryAttempts/$_maxRetryAttempts - checking Bluetooth state');

      try {
        final centralManager = CentralManager();
        final newState = centralManager.state;

        if (newState != _currentState) {
          _handleStateChange(newState, 'RetryCheck');
        } else if (newState == BluetoothLowEnergyState.poweredOff) {
          // Continue monitoring
          _startBluetoothRetryMonitoring();
        }
      } catch (e) {
        _logger.warning('Error during Bluetooth retry check: $e');
        _startBluetoothRetryMonitoring(); // Continue monitoring
      }
    });
  }

  /// Start monitoring for permission changes
  void _startPermissionMonitoring() {
    _permissionTimer = Timer(_permissionCheckInterval, () async {
      try {
        final centralManager = CentralManager();
        final newState = centralManager.state;

        if (newState != BluetoothLowEnergyState.unauthorized) {
          _handleStateChange(newState, 'PermissionCheck');
        } else {
          // Continue monitoring
          _startPermissionMonitoring();
        }
      } catch (e) {
        _logger.warning('Error during permission check: $e');
        _startPermissionMonitoring(); // Continue monitoring
      }
    });
  }

  /// Start initialization retry for unknown state
  void _startInitializationRetry() {
    _retryTimer = Timer(_retryInterval, () async {
      _logger.info('Retrying Bluetooth initialization...');

      _onInitializationRetry?.call();

      try {
        await _checkInitialBluetoothState();
      } catch (e) {
        _logger.warning('Initialization retry failed: $e');
        // Continue retrying
        if (_retryAttempts < _maxRetryAttempts) {
          _startInitializationRetry();
        }
      }
    });
  }

  /// Get the most restrictive state between central and peripheral
  BluetoothLowEnergyState _getMostRestrictiveState(
    BluetoothLowEnergyState central,
    BluetoothLowEnergyState peripheral,
  ) {
    // Priority order (most restrictive first)
    final restrictiveness = {
      BluetoothLowEnergyState.unsupported: 0,
      BluetoothLowEnergyState.unauthorized: 1,
      BluetoothLowEnergyState.poweredOff: 2,
      BluetoothLowEnergyState.unknown: 3,
      BluetoothLowEnergyState.poweredOn: 4,
    };

    final centralLevel = restrictiveness[central] ?? 3;
    final peripheralLevel = restrictiveness[peripheral] ?? 3;

    return centralLevel <= peripheralLevel ? central : peripheral;
  }

  /// Emit state information
  void _emitStateInfo(BluetoothStateInfo info) {
    if (!_stateController.isClosed) {
      _stateController.add(info);
    }
  }

  /// Emit status message
  void _emitMessage(BluetoothStatusMessage message) {
    _logger.info('📢 Status message: ${message.message}');
    if (!_messageController.isClosed) {
      _messageController.add(message);
    }
  }

  /// Cancel all active timers
  void _cancelTimers() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _permissionTimer?.cancel();
    _permissionTimer = null;
  }

  /// Force refresh of Bluetooth state
  Future<void> refreshState() async {
    _logger.info('🔄 Forcing Bluetooth state refresh...');

    try {
      await _checkInitialBluetoothState();
    } catch (e) {
      _logger.warning('Failed to refresh Bluetooth state: $e');
      _emitMessage(BluetoothStatusMessage.error(
        'Failed to refresh Bluetooth status'
      ));
    }
  }

  /// Dispose of the monitor
  void dispose() {
    _logger.info('Disposing Bluetooth state monitor...');

    _cancelTimers();
    _stateController.close();
    _messageController.close();
    _isInitialized = false;
  }
}

/// Information about current Bluetooth state
class BluetoothStateInfo {
  final BluetoothLowEnergyState state;
  final BluetoothLowEnergyState? previousState;
  final bool isReady;
  final DateTime timestamp;

  const BluetoothStateInfo({
    required this.state,
    this.previousState,
    required this.isReady,
    required this.timestamp,
  });

  @override
  String toString() => 'BluetoothStateInfo(state: $state, ready: $isReady)';
}

/// User-friendly Bluetooth status messages
class BluetoothStatusMessage {
  final BluetoothMessageType type;
  final String message;
  final String? actionHint;
  final DateTime timestamp;

  const BluetoothStatusMessage({
    required this.type,
    required this.message,
    this.actionHint,
    required this.timestamp,
  });

  factory BluetoothStatusMessage.ready(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.ready,
    message: message,
    timestamp: DateTime.now(),
  );

  factory BluetoothStatusMessage.disabled(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.disabled,
    message: message,
    actionHint: 'Enable Bluetooth in device settings',
    timestamp: DateTime.now(),
  );

  factory BluetoothStatusMessage.unauthorized(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.unauthorized,
    message: message,
    actionHint: 'Grant Bluetooth permission in app settings',
    timestamp: DateTime.now(),
  );

  factory BluetoothStatusMessage.unsupported(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.unsupported,
    message: message,
    timestamp: DateTime.now(),
  );

  factory BluetoothStatusMessage.unknown(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.unknown,
    message: message,
    timestamp: DateTime.now(),
  );

  // Note: resetting factory method removed as state not available

  factory BluetoothStatusMessage.initializing(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.initializing,
    message: message,
    timestamp: DateTime.now(),
  );

  factory BluetoothStatusMessage.error(String message) => BluetoothStatusMessage(
    type: BluetoothMessageType.error,
    message: message,
    timestamp: DateTime.now(),
  );

  @override
  String toString() => 'BluetoothStatusMessage(${type.name}: $message)';
}

/// Types of Bluetooth status messages
enum BluetoothMessageType {
  ready,
  disabled,
  unauthorized,
  unsupported,
  unknown,
  initializing,
  error,
}

/// Void callback type
typedef VoidCallback = void Function();