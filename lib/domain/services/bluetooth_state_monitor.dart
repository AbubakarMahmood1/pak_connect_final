import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pak_connect/domain/models/bluetooth_state_models.dart';

export 'package:pak_connect/domain/models/bluetooth_state_models.dart'
    show
        BluetoothAvailabilityPhase,
        BluetoothMessageType,
        BluetoothStateInfo,
        BluetoothStatusMessage;

/// Enhanced Bluetooth state monitoring and management system
/// Provides robust handling for Bluetooth state changes with user-friendly messaging
class BluetoothStateMonitor {
  static final _logger = Logger('BluetoothStateMonitor');
  static BluetoothStateMonitor? _instance;

  BluetoothLowEnergyState _currentState = BluetoothLowEnergyState.unknown;
  BluetoothLowEnergyState _centralState = BluetoothLowEnergyState.unknown;
  BluetoothLowEnergyState _peripheralState = BluetoothLowEnergyState.unknown;
  BluetoothAvailabilityPhase _availabilityPhase =
      BluetoothAvailabilityPhase.warmingUp;
  bool _isInitialized = false;
  bool _listenersAttached = false;
  bool _hasReachedReady = false;
  Timer? _retryTimer;
  Timer? _unavailableDebounceTimer;

  CentralManager? _centralManager;
  PeripheralManager? _peripheralManager;
  StreamSubscription<dynamic>? _centralStateSubscription;
  StreamSubscription<dynamic>? _peripheralStateSubscription;

  final Set<void Function(BluetoothStateInfo)> _stateListeners = {};
  final Set<void Function(BluetoothStatusMessage)> _messageListeners = {};

  VoidCallback? _onBluetoothReady;
  VoidCallback? _onBluetoothUnavailable;
  VoidCallback? _onInitializationRetry;

  final Duration _retryInterval = const Duration(seconds: 3);
  final Duration _startupUnavailableDebounce = const Duration(seconds: 2);
  final Duration _runtimeUnavailableDebounce = const Duration(seconds: 1);
  final int _maxRetryAttempts = 10;
  int _retryAttempts = 0;
  int _listenerAttachmentCount = 0;

  BluetoothStateMonitor._();

  /// Get singleton instance
  static BluetoothStateMonitor get instance {
    _instance ??= BluetoothStateMonitor._();
    return _instance!;
  }

  /// Factory constructor for constructor-style singleton access.
  factory BluetoothStateMonitor() => instance;

  /// Stream of Bluetooth state information
  Stream<BluetoothStateInfo> get stateStream =>
      Stream<BluetoothStateInfo>.multi((controller) {
        controller.add(
          BluetoothStateInfo(
            state: _currentState,
            previousState: null,
            isReady: isBluetoothReady,
            availabilityPhase: _availabilityPhase,
            timestamp: DateTime.now(),
          ),
        );

        void listener(BluetoothStateInfo info) {
          controller.add(info);
        }

        _stateListeners.add(listener);
        controller.onCancel = () {
          _stateListeners.remove(listener);
        };
      });

  /// Stream of user-friendly status messages
  Stream<BluetoothStatusMessage> get messageStream =>
      Stream<BluetoothStatusMessage>.multi((controller) {
        void listener(BluetoothStatusMessage message) {
          controller.add(message);
        }

        _messageListeners.add(listener);
        controller.onCancel = () {
          _messageListeners.remove(listener);
        };
      });

  /// Current Bluetooth state
  BluetoothLowEnergyState get currentState => _currentState;

  /// Stabilized Bluetooth availability phase
  BluetoothAvailabilityPhase get availabilityPhase => _availabilityPhase;

  /// Whether Bluetooth is ready for use
  bool get isBluetoothReady =>
      _availabilityPhase == BluetoothAvailabilityPhase.ready &&
      _currentState == BluetoothLowEnergyState.poweredOn;

  /// Whether the system is initialized
  bool get isInitialized => _isInitialized;

  /// Initialize the Bluetooth state monitor
  Future<void> initialize({
    VoidCallback? onBluetoothReady,
    VoidCallback? onBluetoothUnavailable,
    VoidCallback? onInitializationRetry,
  }) async {
    _onBluetoothReady = onBluetoothReady;
    _onBluetoothUnavailable = onBluetoothUnavailable;
    _onInitializationRetry = onInitializationRetry;

    if (_isInitialized) {
      _logger.info('Bluetooth state monitor already initialized');
      return;
    }

    _logger.info('🔵 Initializing Bluetooth state monitor...');

    try {
      _ensureManagersAndListeners();
      await _refreshCurrentBluetoothState(isInitial: true);

      _isInitialized = true;
      _logger.info('✅ Bluetooth state monitor initialized successfully');
    } catch (e) {
      _logger.severe('❌ Failed to initialize Bluetooth state monitor: $e');
      _availabilityPhase = BluetoothAvailabilityPhase.error;
      _emitMessage(
        BluetoothStatusMessage.error(
          'Failed to initialize Bluetooth monitoring: $e',
        ),
      );
      rethrow;
    }
  }

  void _ensureManagersAndListeners() {
    _centralManager ??= CentralManager();
    _peripheralManager ??= PeripheralManager();

    if (_listenersAttached) {
      return;
    }

    final centralManager = _centralManager!;
    final peripheralManager = _peripheralManager!;

    _centralStateSubscription = centralManager.stateChanged.listen((event) {
      _logger.info('Central Bluetooth state changed: ${event.state}');
      _handleStateChange(
        event.state,
        source: 'Central',
        updateCentral: true,
      );
    });

    _peripheralStateSubscription = peripheralManager.stateChanged.listen((
      event,
    ) {
      _logger.info('Peripheral Bluetooth state changed: ${event.state}');
      _handleStateChange(
        event.state,
        source: 'Peripheral',
        updatePeripheral: true,
      );
    });

    _listenersAttached = true;
    _listenerAttachmentCount++;
  }

  Future<void> _refreshCurrentBluetoothState({bool isInitial = false}) async {
    try {
      _ensureManagersAndListeners();

      _centralState = _centralManager!.state;
      _peripheralState = _peripheralManager!.state;

      _logger.info(
        'Bluetooth states - Central: $_centralState, Peripheral: $_peripheralState',
      );

      final previousState = _currentState;
      _currentState = _combineObservedStates(
        previousState: previousState,
        isInitial: isInitial,
      );

      await _processBluetoothState(
        _currentState,
        previousState: previousState,
        isInitial: isInitial,
      );
    } catch (e) {
      _logger.severe('Failed to refresh Bluetooth state: $e');
      _currentState = BluetoothLowEnergyState.unknown;
      _availabilityPhase = BluetoothAvailabilityPhase.error;
      _emitStateSnapshot(previousState: BluetoothLowEnergyState.unknown);
      _emitMessage(
        BluetoothStatusMessage.error('Unable to access Bluetooth system'),
      );
      rethrow;
    }
  }

  /// Handle Bluetooth state changes
  void _handleStateChange(
    BluetoothLowEnergyState newState, {
    required String source,
    bool updateCentral = false,
    bool updatePeripheral = false,
  }) {
    final previousState = _currentState;
    if (updateCentral) {
      _centralState = newState;
    }
    if (updatePeripheral) {
      _peripheralState = newState;
    }

    _currentState = _combineObservedStates(previousState: previousState);

    _logger.info('🔵 Bluetooth state change detected:');
    _logger.info('  - Source: $source');
    _logger.info('  - Previous: $previousState');
    _logger.info('  - Central: $_centralState');
    _logger.info('  - Peripheral: $_peripheralState');
    _logger.info('  - Combined: $_currentState');

    unawaited(
      _processBluetoothState(
        _currentState,
        previousState: previousState,
      ),
    );
  }

  /// Process Bluetooth state and take appropriate actions
  Future<void> _processBluetoothState(
    BluetoothLowEnergyState state, {
    BluetoothLowEnergyState? previousState,
    bool isInitial = false,
  }) async {
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        _cancelUnavailableDebounce();
        _cancelInitializationRetry();
        await _handleBluetoothReady(isInitial: isInitial);
        break;

      case BluetoothLowEnergyState.poweredOff:
        _cancelInitializationRetry();
        await _handleBluetoothOff(isInitial: isInitial);
        break;

      case BluetoothLowEnergyState.unauthorized:
        _cancelUnavailableDebounce();
        _cancelInitializationRetry();
        await _handleBluetoothUnauthorized();
        break;

      case BluetoothLowEnergyState.unsupported:
        _cancelUnavailableDebounce();
        _cancelInitializationRetry();
        await _handleBluetoothUnsupported();
        break;

      case BluetoothLowEnergyState.unknown:
        _cancelUnavailableDebounce();
        await _handleBluetoothUnknown(isInitial: isInitial);
        break;
    }

    _emitStateSnapshot(previousState: previousState);
  }

  /// Handle Bluetooth ready state
  Future<void> _handleBluetoothReady({bool isInitial = false}) async {
    _logger.info('✅ Bluetooth is ready');
    _retryAttempts = 0;
    _hasReachedReady = true;
    _availabilityPhase = BluetoothAvailabilityPhase.ready;

    final message = isInitial
        ? 'Bluetooth ready for mesh networking'
        : 'Bluetooth enabled - mesh networking available';

    _emitMessage(BluetoothStatusMessage.ready(message));
    _onBluetoothReady?.call();
  }

  /// Handle Bluetooth disabled state
  Future<void> _handleBluetoothOff({bool isInitial = false}) async {
    final debounce = _hasReachedReady
        ? _runtimeUnavailableDebounce
        : _startupUnavailableDebounce;

    _logger.warning(
      '⚠️ Bluetooth reported poweredOff - waiting ${debounce.inMilliseconds}ms before marking unavailable',
    );

    _availabilityPhase = BluetoothAvailabilityPhase.warmingUp;
    _emitMessage(
      BluetoothStatusMessage.initializing(
        isInitial || !_hasReachedReady
            ? 'Preparing Bluetooth status...'
            : 'Bluetooth changed. Re-checking mesh availability...',
      ),
    );

    _cancelUnavailableDebounce();
    _unavailableDebounceTimer = Timer(debounce, () {
      if (_currentState != BluetoothLowEnergyState.poweredOff) {
        return;
      }

      _logger.warning('⚠️ Bluetooth is disabled');
      _availabilityPhase = BluetoothAvailabilityPhase.disabled;
      _emitStateSnapshot(previousState: BluetoothLowEnergyState.poweredOff);
      _emitMessage(
        BluetoothStatusMessage.disabled(
          'Bluetooth is disabled. Please enable Bluetooth to use mesh networking.',
        ),
      );
      _onBluetoothUnavailable?.call();
    });
  }

  /// Handle unauthorized Bluetooth state
  Future<void> _handleBluetoothUnauthorized() async {
    _logger.warning('⚠️ Bluetooth permissions not granted');
    _availabilityPhase = BluetoothAvailabilityPhase.permissionsRequired;

    _emitMessage(
      BluetoothStatusMessage.unauthorized(
        'Bluetooth permission required. Please grant permission in app settings.',
      ),
    );

    _onBluetoothUnavailable?.call();
  }

  /// Handle unsupported Bluetooth state
  Future<void> _handleBluetoothUnsupported() async {
    _logger.severe('❌ Bluetooth not supported on this device');
    _availabilityPhase = BluetoothAvailabilityPhase.unsupported;

    _emitMessage(
      BluetoothStatusMessage.unsupported(
        'Bluetooth Low Energy is not supported on this device. Mesh networking is unavailable.',
      ),
    );

    _onBluetoothUnavailable?.call();
  }

  /// Handle unknown Bluetooth state
  Future<void> _handleBluetoothUnknown({bool isInitial = false}) async {
    _logger.warning('⚠️ Bluetooth state unknown');
    _availabilityPhase = BluetoothAvailabilityPhase.warmingUp;

    _emitMessage(
      BluetoothStatusMessage.initializing(
        isInitial
            ? 'Checking Bluetooth status...'
            : 'Bluetooth status is settling. Preparing mesh...',
      ),
    );

    _startInitializationRetry();
  }

  void _startInitializationRetry() {
    if (_retryTimer != null || _retryAttempts >= _maxRetryAttempts) {
      return;
    }

    _retryTimer = Timer(_retryInterval, () async {
      _retryTimer = null;
      _retryAttempts++;
      _logger.info('Retrying Bluetooth initialization...');
      _onInitializationRetry?.call();

      try {
        await _refreshCurrentBluetoothState();
      } catch (e) {
        _logger.warning('Initialization retry failed: $e');
      }

      if (_availabilityPhase == BluetoothAvailabilityPhase.warmingUp &&
          _currentState != BluetoothLowEnergyState.poweredOn) {
        _startInitializationRetry();
      }
    });
  }

  void _cancelInitializationRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _cancelUnavailableDebounce() {
    _unavailableDebounceTimer?.cancel();
    _unavailableDebounceTimer = null;
  }

  /// Get the most restrictive state between central and peripheral
  BluetoothLowEnergyState _getMostRestrictiveState(
    BluetoothLowEnergyState central,
    BluetoothLowEnergyState peripheral,
  ) {
    if (central == BluetoothLowEnergyState.unsupported &&
        peripheral != BluetoothLowEnergyState.unsupported) {
      return peripheral;
    }
    if (peripheral == BluetoothLowEnergyState.unsupported &&
        central != BluetoothLowEnergyState.unsupported) {
      return central;
    }

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

  BluetoothLowEnergyState _combineObservedStates({
    required BluetoothLowEnergyState previousState,
    bool isInitial = false,
  }) {
    final combined = _getMostRestrictiveState(_centralState, _peripheralState);

    if (!isInitial &&
        combined == BluetoothLowEnergyState.unsupported &&
        (previousState == BluetoothLowEnergyState.poweredOff ||
            previousState == BluetoothLowEnergyState.unauthorized)) {
      return previousState;
    }

    return combined;
  }

  void _emitStateSnapshot({BluetoothLowEnergyState? previousState}) {
    _emitStateInfo(
      BluetoothStateInfo(
        state: _currentState,
        previousState: previousState,
        isReady: isBluetoothReady,
        availabilityPhase: _availabilityPhase,
        timestamp: DateTime.now(),
      ),
    );
  }

  @visibleForTesting
  BluetoothLowEnergyState combineStatesForTesting(
    BluetoothLowEnergyState central,
    BluetoothLowEnergyState peripheral,
  ) {
    return _getMostRestrictiveState(central, peripheral);
  }

  @visibleForTesting
  BluetoothLowEnergyState combineObservedStatesForTesting({
    required BluetoothLowEnergyState previousState,
    required BluetoothLowEnergyState central,
    required BluetoothLowEnergyState peripheral,
    bool isInitial = false,
  }) {
    _centralState = central;
    _peripheralState = peripheral;
    return _combineObservedStates(
      previousState: previousState,
      isInitial: isInitial,
    );
  }

  @visibleForTesting
  Future<void> simulateObservedStatesForTesting({
    required BluetoothLowEnergyState central,
    required BluetoothLowEnergyState peripheral,
    BluetoothLowEnergyState? previousState,
    bool isInitial = false,
  }) async {
    _centralState = central;
    _peripheralState = peripheral;
    final oldState = previousState ?? _currentState;
    _currentState = _combineObservedStates(
      previousState: oldState,
      isInitial: isInitial,
    );
    await _processBluetoothState(
      _currentState,
      previousState: oldState,
      isInitial: isInitial,
    );
  }

  @visibleForTesting
  int get debugListenerAttachmentCount => _listenerAttachmentCount;

  /// Emit state information
  void _emitStateInfo(BluetoothStateInfo info) {
    for (final listener in List.of(_stateListeners)) {
      try {
        listener(info);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying Bluetooth state listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  /// Emit status message
  void _emitMessage(BluetoothStatusMessage message) {
    _logger.info('📢 Status message: ${message.message}');
    for (final listener in List.of(_messageListeners)) {
      try {
        listener(message);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying Bluetooth message listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  /// Force refresh of Bluetooth state
  Future<void> refreshState() async {
    _logger.info('🔄 Forcing Bluetooth state refresh...');

    try {
      await _refreshCurrentBluetoothState();
    } catch (e) {
      _logger.warning('Failed to refresh Bluetooth state: $e');
      _availabilityPhase = BluetoothAvailabilityPhase.error;
      _emitStateSnapshot(previousState: _currentState);
      _emitMessage(
        BluetoothStatusMessage.error('Failed to refresh Bluetooth status'),
      );
    }
  }

  /// Dispose of the monitor
  void dispose() {
    _logger.info('Disposing Bluetooth state monitor...');

    _cancelInitializationRetry();
    _cancelUnavailableDebounce();
    _centralStateSubscription?.cancel();
    _peripheralStateSubscription?.cancel();
    _centralStateSubscription = null;
    _peripheralStateSubscription = null;
    _stateListeners.clear();
    _messageListeners.clear();
    _centralManager = null;
    _peripheralManager = null;
    _listenersAttached = false;
    _centralState = BluetoothLowEnergyState.unknown;
    _peripheralState = BluetoothLowEnergyState.unknown;
    _currentState = BluetoothLowEnergyState.unknown;
    _availabilityPhase = BluetoothAvailabilityPhase.warmingUp;
    _hasReachedReady = false;
    _retryAttempts = 0;
    _listenerAttachmentCount = 0;
    _isInitialized = false;
  }

  /// Override the current Bluetooth state for unit testing.
  @visibleForTesting
  static void overrideCurrentState(
    BluetoothLowEnergyState state, {
    BluetoothAvailabilityPhase? availabilityPhase,
  }) {
    instance._currentState = state;
    instance._availabilityPhase =
        availabilityPhase ?? _phaseForState(state);
    instance._hasReachedReady = state == BluetoothLowEnergyState.poweredOn;
  }

  static BluetoothAvailabilityPhase _phaseForState(
    BluetoothLowEnergyState state,
  ) {
    switch (state) {
      case BluetoothLowEnergyState.poweredOn:
        return BluetoothAvailabilityPhase.ready;
      case BluetoothLowEnergyState.poweredOff:
        return BluetoothAvailabilityPhase.disabled;
      case BluetoothLowEnergyState.unauthorized:
        return BluetoothAvailabilityPhase.permissionsRequired;
      case BluetoothLowEnergyState.unsupported:
        return BluetoothAvailabilityPhase.unsupported;
      case BluetoothLowEnergyState.unknown:
        return BluetoothAvailabilityPhase.warmingUp;
    }
  }
}

/// Void callback type
typedef VoidCallback = void Function();
