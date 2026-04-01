import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_experiment_metrics_recorder.dart';
import '../../domain/constants/ble_constants.dart';
import '../../domain/services/device_deduplication_manager.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import '../../domain/services/hint_scanner_service.dart';

/// Manages BLE device discovery and deduplication.
///
/// Extracted from BLEService in Phase 2A.2.2b as part of refactoring.
///
/// Responsibility: Handle all discovery-related operations
/// - Central role scanning for devices
/// - Device list deduplication and filtering
/// - Hint-based device matching for collision detection
/// - Auto-connect to known contacts
class BLEDiscoveryService implements IBLEDiscoveryService {
  final _logger = Logger('BLEDiscoveryService');

  // Dependencies injected at initialization
  final CentralManager centralManager;
  final IBLEStateManagerFacade stateManager;
  final HintScannerService hintScanner;
  final IBleExperimentMetricsRecorder? metricsRecorder;

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

  // Listener sets for discovery/hint events
  final Set<void Function(List<Peripheral>)> _deviceListeners = {};
  final Set<void Function(String)> _hintListeners = {};
  final Set<void Function(Map<String, DiscoveredEventArgs>)>
  _discoveryDataListeners = {};

  // Discovery state
  List<Peripheral> _discoveredDevices = [];
  bool _isDiscoveryActive = false;
  ScanningSource? _currentScanningSource;
  Timer? _staleDeviceTimer;
  StreamSubscription<Map<String, dynamic>>? _deduplicationSubscription;
  StreamSubscription<DiscoveredEventArgs>? _centralDiscoverySubscription;
  final Map<String, DiscoveredEventArgs> _discoveryData = {};

  // Authoritativestate getters (from facade)
  final bool Function() isAdvertising;
  final bool Function() isConnected;

  BLEDiscoveryService({
    required this.centralManager,
    required this.stateManager,
    required this.hintScanner,
    required this.onUpdateConnectionInfo,
    required this.isAdvertising,
    required this.isConnected,
    this.metricsRecorder,
  });

  // ============================================================================
  // SETUP: Initialize deduplication listener (called by facade)
  // ============================================================================

  void setupDeduplicationListener() {
    _logger.info('🔗 Setting up deduplicated device stream listener...');

    // ✅ Listen to deduplicated device stream and update UI
    _deduplicationSubscription = DeviceDeduplicationManager.uniqueDevicesStream
        .listen((uniqueDevices) {
          _discoveredDevices = uniqueDevices.values
              .map((d) => d.peripheral)
              .toList();
          _notifyDevices(List.from(_discoveredDevices));

          _logger.fine(
            '📡 Deduplicated devices updated: ${uniqueDevices.length} unique devices',
          );
        });

    // ✅ Cleanup stale devices periodically
    _staleDeviceTimer?.cancel();
    _staleDeviceTimer = Timer.periodic(Duration(minutes: 1), (_) {
      DeviceDeduplicationManager.removeStaleDevices();
    });

    _logger.info('✅ Deduplicated device stream listener registered');
  }

  void disposeDeduplicationListener() {
    _deduplicationSubscription?.cancel();
    _staleDeviceTimer?.cancel();
  }

  @override
  Future<void> initialize() async {
    _logger.info('🔧 Initializing BLEDiscoveryService');
    setupDeduplicationListener();

    _centralDiscoverySubscription?.cancel();
    _centralDiscoverySubscription = centralManager.discovered.listen((event) {
      try {
        final deviceId = event.peripheral.uuid.toString();
        _discoveryData[deviceId] = event;
        _notifyDiscoveryData(Map.from(_discoveryData));
        DeviceDeduplicationManager.processDiscoveredDevice(event);
        metricsRecorder?.recordPeerDiscovered(deviceId);
      } catch (e, stackTrace) {
        _logger.warning(
          '⚠️ Error processing discovered device: $e',
          e,
          stackTrace,
        );
      }
    });
  }

  @override
  Future<void> dispose() async {
    _logger.info('🧹 Disposing BLEDiscoveryService');
    await stopScanning();
    disposeDeduplicationListener();
    await _centralDiscoverySubscription?.cancel();
    _centralDiscoverySubscription = null;
    _deviceListeners.clear();
    _hintListeners.clear();
    _discoveryDataListeners.clear();
  }

  // ============================================================================
  // IMPLEMENTATION: Extracted from BLEService (lines 2160-2284)
  // ============================================================================

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.manual,
  }) async {
    // 🔧 ENHANCED: Check for scanning conflicts with better logging
    if (_isDiscoveryActive) {
      final currentSource = _currentScanningSource?.name ?? 'unknown';
      final newSource = source.name;

      if (_currentScanningSource != source) {
        _logger.warning(
          '🔍 Scanning conflict detected: $newSource scanning requested while $currentSource scanning is active',
        );
        _logger.info(
          '🔍 Coordination: Allowing $newSource to take over from $currentSource',
        );

        // Allow manual scanning to interrupt burst scanning for better UX
        if (source == ScanningSource.manual &&
            _currentScanningSource == ScanningSource.burst) {
          _logger.info(
            '🔍 Manual scanning takes priority over burst scanning - stopping current scan',
          );
          await stopScanning();
        } else {
          _logger.info(
            '🔍 Discovery already active from $currentSource - skipping $newSource request',
          );
          return;
        }
      } else {
        _logger.info(
          '🔍 Discovery already active from same source ($currentSource) - skipping request',
        );
        return;
      }
    }

    _currentScanningSource = source;

    _logger.info('🔍 Starting ${source.name} BLE scan...');
    onUpdateConnectionInfo(
      isScanning: true,
      statusMessage: isConnected()
          ? 'Ready to chat'
          : 'Scanning for devices...',
    );

    _logger.info('🔍 [SCAN-DEBUG] ========================================');
    _logger.info('🔍 [SCAN-DEBUG] About to start discovery');
    _logger.info('🔍 [SCAN-DEBUG] Source: ${source.name}');
    _logger.info('🔍 [SCAN-DEBUG] _isDiscoveryActive: $_isDiscoveryActive');
    _logger.info(
      '🔍 [SCAN-DEBUG] isPeripheralMode: ${stateManager.isPeripheralMode}',
    );
    _logger.info(
      '🔍 [SCAN-DEBUG] Service UUID filter: ${BLEConstants.serviceUUID}',
    );
    _logger.info('🔍 [SCAN-DEBUG] ========================================');

    try {
      _logger.info('🔍 [SCAN-DEBUG] Setting _isDiscoveryActive = true');
      _isDiscoveryActive = true;

      _logger.info(
        '🔍 [SCAN-DEBUG] Calling centralManager.startDiscovery()...',
      );
      await centralManager.startDiscovery(
        serviceUUIDs: [BLEConstants.serviceUUID],
      );

      _logger.info('✅✅✅ [SCAN-DEBUG] DISCOVERY STARTED! ✅✅✅');
      _logger.info(
        '🔍 [SCAN-DEBUG] Now scanning for service UUID: ${BLEConstants.serviceUUID}',
      );
      _logger.info(
        '🔍 ${source.name.toUpperCase()} discovery started successfully',
      );
      metricsRecorder?.recordScanStarted();

      // 🔧 FIX P2: Confirm dual-role operation (advertising + scanning simultaneously)
      if (isAdvertising() && stateManager.isPeripheralMode) {
        _logger.info(
          '🔧 DUAL-ROLE: ✅ Both advertising AND scanning active simultaneously',
        );
        _logger.info(
          '🔧 DUAL-ROLE: Advertising state: ${isAdvertising()}, Scanning state: $_isDiscoveryActive',
        );
        onUpdateConnectionInfo(
          isAdvertising: true,
          isScanning: true,
          statusMessage: 'Dual-role: Advertising + Scanning',
        );
      }
    } catch (e) {
      _isDiscoveryActive = false;
      _currentScanningSource = null;
      onUpdateConnectionInfo(isScanning: false);
      rethrow;
    }
  }

  @override
  Future<void> stopScanning() async {
    final currentSource = _currentScanningSource?.name ?? 'unknown';
    _logger.info('🔍 Stopping $currentSource BLE scan...');
    final wasDiscoveryActive = _isDiscoveryActive;

    if (_isDiscoveryActive) {
      try {
        await centralManager.stopDiscovery();
        _logger.info(
          '🔍 ${currentSource.toUpperCase()} discovery stopped successfully',
        );
      } catch (e) {
        _logger.warning('🔍 Error stopping $currentSource discovery: $e');
      } finally {
        _isDiscoveryActive = false;
        _currentScanningSource = null;
      }
    }

    if (wasDiscoveryActive) {
      metricsRecorder?.recordScanStopped();
    }

    onUpdateConnectionInfo(
      isScanning: false,
      statusMessage: isConnected() ? 'Ready to chat' : 'Ready to scan',
    );
  }

  @override
  Future<void> startScanningWithValidation({
    ScanningSource source = ScanningSource.manual,
  }) async {
    _logger.info('🔍 startScanningWithValidation()');
    // Delegate to main method; Bluetooth state validation is handled by facade
    await startScanning(source: source);
  }

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async {
    _logger.info('🔍 Scanning for specific device...');
    // TODO(phase2a): Extract from BLEConnectionManager.scanForSpecificDevice()
    // For now, returning null - connection service will delegate to connection manager
    return null;
  }

  @override
  Stream<List<Peripheral>> get discoveredDevices {
    return Stream<List<Peripheral>>.multi((controller) {
      controller.add(List.from(_discoveredDevices));

      void listener(List<Peripheral> devices) {
        controller.add(devices);
      }

      _deviceListeners.add(listener);
      controller.onCancel = () {
        _deviceListeners.remove(listener);
      };
    });
  }

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData {
    // TODO(phase2a): Extract raw discovery event stream from CentralManager
    return Stream<Map<String, DiscoveredEventArgs>>.multi((controller) {
      controller.add(Map.from(_discoveryData));

      void listener(Map<String, DiscoveredEventArgs> data) {
        controller.add(data);
      }

      _discoveryDataListeners.add(listener);
      controller.onCancel = () {
        _discoveryDataListeners.remove(listener);
      };
    });
  }

  @override
  Stream<List<Peripheral>> get discoveredDevicesStream {
    return discoveredDevices;
  }

  @override
  List<Peripheral> get currentDiscoveredDevices =>
      List.from(_discoveredDevices);

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryDataStream {
    return discoveryData;
  }

  @override
  bool get isDiscoveryActive => _isDiscoveryActive;

  @override
  ScanningSource? get currentScanningSource => _currentScanningSource;

  @override
  Stream<String> get hintMatchesStream {
    return Stream<String>.multi((controller) {
      void listener(String hint) {
        controller.add(hint);
      }

      _hintListeners.add(listener);
      controller.onCancel = () {
        _hintListeners.remove(listener);
      };
    });
  }

  void _notifyDevices(List<Peripheral> devices) {
    for (final listener in List.of(_deviceListeners)) {
      try {
        listener(devices);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying devices listener: $e', e, stackTrace);
      }
    }
  }

  void _notifyDiscoveryData(Map<String, DiscoveredEventArgs> data) {
    for (final listener in List.of(_discoveryDataListeners)) {
      try {
        listener(data);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying discovery data listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  @override
  Future<String?> buildLocalCollisionHint() async {
    _logger.info('🔍 Building local collision hint...');
    // TODO(phase2a): Extract from BLEStateManager or HintScannerService
    return null;
  }
}
