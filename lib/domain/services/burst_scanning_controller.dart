import 'dart:async';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    show BluetoothLowEnergyState;
import 'adaptive_power_manager.dart';
import '../interfaces/i_connection_service.dart';
import '../interfaces/i_ble_discovery_service.dart';
import 'bluetooth_state_monitor.dart';
import '../config/kill_switches.dart';

/// Bridge controller that connects AdaptivePowerManager to actual BLE scanning operations
/// This ensures burst scanning reaches the radio hardware with proper source tagging
///
/// OPTIMIZATION: Connection-aware burst scanning
/// - Automatically skips burst scans when at max connection capacity
/// - Current limit: 1 connection (iOS baseline, set via BLEConnectionManager.maxCentralConnections)
/// - Future: Will support up to 7 concurrent connections on Android for 1-to-many mesh networking
/// - Battery savings: Eliminates unnecessary scanning when connections are saturated
class BurstScanningController {
  static final _logger = Logger('BurstScanningController');

  AdaptivePowerManager?
  _powerManager; // ✅ FIX: Made nullable to prevent LateInitializationError on disposal
  IConnectionService? _bleService;
  StreamSubscription<BluetoothStateInfo>? _bluetoothStateSubscription;

  // Status tracking
  bool _isBurstActive = false;
  bool _scanActuallyStarted =
      false; // ✅ FIX: Track if scan actually started (vs skipped due to Bluetooth unavailable)
  DateTime? _nextActionTime;
  DateTime? _burstEndTime;
  DateTime? _lastBurstEndedAt;
  Duration _cooldownDuration = const Duration(minutes: 10);
  final Duration _scanDuration = const Duration(seconds: 20);
  Timer? _statusUpdateTimer;
  Timer?
  _burstDurationTimer; // Timer to handle burst duration in continuous scan mode

  // Status stream
  final Set<void Function(BurstScanningStatus)> _statusListeners = {};

  Stream<BurstScanningStatus> get statusStream =>
      Stream<BurstScanningStatus>.multi((controller) {
        // Start timer on first listener
        _startStatusTimer();
        controller.add(getCurrentStatus());

        void listener(BurstScanningStatus status) {
          controller.add(status);
        }

        _statusListeners.add(listener);
        controller.onCancel = () {
          _statusListeners.remove(listener);
          if (_statusListeners.isEmpty) {
            _stopStatusTimer();
          }
        };
      });

  /// Initialize the burst scanning controller
  Future<void> initialize(IConnectionService bleService) async {
    _bleService = bleService;
    _powerManager = AdaptivePowerManager();

    await _powerManager!.initialize(
      onStartScan: _handleBurstScanStart,
      onStopScan: _handleBurstScanStop,
      onHealthCheck: _handleHealthCheck,
      onStatsUpdate: _handleStatsUpdate,
    );

    final bluetoothMonitor = BluetoothStateMonitor.instance;
    await _powerManager!.updateBluetoothAvailability(
      bluetoothMonitor.isBluetoothReady,
    );
    _bluetoothStateSubscription = bluetoothMonitor.stateStream.listen((
      stateInfo,
    ) {
      final available = stateInfo.state == BluetoothLowEnergyState.poweredOn;
      final future = _powerManager?.updateBluetoothAvailability(available);
      if (future != null) {
        unawaited(future);
      }
    });

    _logger.info('🔧 Burst scanning controller initialized');
  }

  /// Start adaptive burst scanning
  Future<void> startBurstScanning() async {
    if (KillSwitches.disableDiscoveryScheduler) {
      _logger.warning('🔥 BURST: Discovery scheduler disabled via kill switch');
      return;
    }
    if (_bleService == null || _powerManager == null) {
      _logger.warning(
        'BLE service or power manager not available for burst scanning',
      );
      return;
    }

    _logger.info('🔥 Starting adaptive burst scanning');
    await _powerManager!.startAdaptiveScanning();
  }

  /// Stop burst scanning
  Future<void> stopBurstScanning() async {
    if (KillSwitches.disableDiscoveryScheduler) {
      _logger.warning('🔥 BURST: Discovery scheduler disabled via kill switch');
      return;
    }
    _logger.info('🔥 Stopping adaptive burst scanning');

    // Cancel burst duration timer
    _burstDurationTimer?.cancel();
    _burstDurationTimer = null;

    if (_powerManager != null) {
      await _powerManager!.stopScanning();
    }
    _isBurstActive = false;
    _burstEndTime = null;
    _updateStatus();
  }

  /// Handle burst scan start from power manager
  Future<void> _handleBurstScanStart() async {
    // Throttle restart loops: enforce cooldown after a burst ends.
    if (_lastBurstEndedAt != null &&
        DateTime.now().difference(_lastBurstEndedAt!) < _cooldownDuration) {
      final remaining =
          _cooldownDuration - DateTime.now().difference(_lastBurstEndedAt!);
      _logger.fine(
        '🔥 BURST: Skipping start - cooldown active (${remaining.inSeconds}s left)',
      );
      _nextActionTime ??= DateTime.now().add(remaining);
      return;
    }

    // ✅ FIX #2: Check BLE service availability first
    if (_bleService == null) {
      _logger.fine('🔥 BURST: BLE service not available - skipping scan');
      return;
    }

    // ✅ FIX #2: Check Bluetooth state before attempting scan
    // This prevents permission errors when Bluetooth is off/unauthorized/unsupported
    final bluetoothMonitor = BluetoothStateMonitor.instance;
    if (!bluetoothMonitor.isBluetoothReady) {
      _logger.fine(
        '🔥 BURST: Bluetooth not ready (state: ${bluetoothMonitor.currentState}) - skipping scan',
      );
      _scanActuallyStarted = false; // ✅ FIX: Mark that scan didn't start
      return;
    }

    // 🔧 DUAL-ROLE FIX: Removed peripheral mode check - scanning and advertising coexist
    // Both central and peripheral roles run simultaneously without interference

    // 🔥 OPTIMIZATION: Check if at max connections before scanning
    final activeConnections = _bleService!.activeConnectionCount;
    final maxConnections = _bleService!.maxCentralConnections;
    if (!_bleService!.canAcceptMoreConnections) {
      _logger.info(
        '🔥 BURST: Skipping scan - already at max connections ($activeConnections/$maxConnections)',
      );
      _logger.fine(
        'Connected devices: ${_bleService!.activeConnectionDeviceIds.join(", ")}',
      );
      return; // Don't scan if we can't accept more connections
    }

    _logger.info(
      '🔥 BURST: Starting burst scan cycle ($activeConnections/$maxConnections connections)',
    );
    _isBurstActive = true;
    _burstEndTime = DateTime.now().add(_scanDuration);
    _nextActionTime = _burstEndTime;

    try {
      await _bleService!.startScanning(source: ScanningSource.burst);
      _scanActuallyStarted = true; // ✅ FIX: Mark that scan actually started
      _logger.info('✅ BURST: Scan started successfully');

      // Start our own timer to handle burst duration
      // This is needed because in performance mode (continuous scan),
      // the power manager won't call onStopScan
      _burstDurationTimer?.cancel();
      _burstDurationTimer = Timer(_scanDuration, () {
        if (_isBurstActive) {
          _logger.info(
            '🔥 BURST: Duration timer expired - treating as burst end',
          );
          _handleBurstScanStop();
        }
      });
    } catch (e) {
      _logger.severe('❌ BURST: Failed to start scanning: $e');
      _isBurstActive = false;
      _scanActuallyStarted = false; // ✅ FIX: Scan failed, mark as not started
      _burstEndTime = null;
      _burstDurationTimer?.cancel();
    }

    _updateStatus();
  }

  /// Handle burst scan stop from power manager
  void _handleBurstScanStop() async {
    // ✅ FIX: Make idempotent - if already stopped, do nothing
    // This prevents race condition when both timer AND power manager call this
    if (!_isBurstActive) {
      _logger.fine(
        '🔥 BURST: Stop called but burst already inactive - skipping',
      );
      return;
    }

    _logger.info('🔥 BURST: Stopping burst scan cycle');

    // Cancel burst duration timer
    _burstDurationTimer?.cancel();
    _burstDurationTimer = null;

    _isBurstActive = false;
    _burstEndTime = null;
    _lastBurstEndedAt = DateTime.now();
    // Fixed cooldown to reduce churn during manual testing.
    _cooldownDuration = const Duration(minutes: 10);
    _nextActionTime = DateTime.now().add(_cooldownDuration);

    // ✅ FIX: Only try to stop scan if it actually started
    // This prevents "Stopping unknown BLE scan" logs when Bluetooth unavailable
    if (_scanActuallyStarted) {
      try {
        await _bleService?.stopScanning();
        _logger.info('✅ BURST: Scan stopped successfully');
      } catch (e) {
        _logger.warning('❌ BURST: Error stopping scan: $e');
      }
      _scanActuallyStarted = false;
    } else {
      _logger.fine(
        '🔥 BURST: Scan cycle ended (scan never started due to Bluetooth unavailable)',
      );
    }

    _updateStatus();
  }

  /// Handle health check from power manager
  void _handleHealthCheck() {
    _logger.fine('🔥 BURST: Performing connection health check');
    // Health check logic can be added here if needed
  }

  /// Handle power management stats update
  void _handleStatsUpdate(PowerManagementStats stats) {
    _logger.fine(
      '🔥 BURST: Power stats updated - scan interval: ${stats.currentScanInterval}ms',
    );

    // We maintain deterministic scheduling; stats only refresh status.

    _updateStatus();
  }

  /// Report connection success to power manager
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    _powerManager?.reportConnectionSuccess(
      rssi: rssi,
      connectionTime: connectionTime,
      dataTransferSuccess: dataTransferSuccess,
    );
  }

  /// Report connection failure to power manager
  void reportConnectionFailure({
    String? reason,
    int? rssi,
    double? attemptTime,
  }) {
    _powerManager?.reportConnectionFailure(
      reason: reason,
      rssi: rssi,
      attemptTime: attemptTime,
    );
  }

  /// Manual override - trigger immediate burst scan
  Future<void> triggerManualScan({
    Duration delay = const Duration(seconds: 1),
  }) async {
    _logger.info(
      '🔥 MANUAL: User requested immediate scan - overriding timers',
    );

    if (_bleService == null || _powerManager == null) {
      _logger.warning('BLE service or power manager not available');
      return;
    }

    // If already scanning, shorten the active burst to end quickly.
    if (_isBurstActive) {
      _logger.info(
        '🔥 MANUAL: Active burst detected - shortening to ${delay.inSeconds}s',
      );

      _burstEndTime = DateTime.now().add(delay);
      _burstDurationTimer?.cancel();
      _burstDurationTimer = Timer(delay, () {
        if (_isBurstActive) {
          _handleBurstScanStop();
        }
      });

      _powerManager?.shortenActiveBurst(delay);
      _updateStatus();
      return;
    }

    // Override cooldown: pretend the last burst ended long enough ago and
    // schedule the next scan to fire soon.
    _lastBurstEndedAt = DateTime.now().subtract(_cooldownDuration);
    _nextActionTime = DateTime.now().add(delay);

    await _powerManager!.scheduleManualBurstAfter(delay);

    _logger.info('✅ MANUAL: Immediate burst scan triggered via power manager');
    _updateStatus();
  }

  /// Force a burst scan immediately, bypassing the cooldown timer.
  Future<void> forceBurstScanNow() async {
    _logger.info('🔥 MANUAL: Forcing burst scan (cooldown bypass)');
    _lastBurstEndedAt = DateTime.now().subtract(_cooldownDuration);
    _cooldownDuration = Duration.zero;
    _nextActionTime = DateTime.now();

    if (_isBurstActive) {
      _logger.fine(
        '🔥 BURST: Already active - shortening and restarting soon instead',
      );
      await triggerManualScan(delay: Duration(seconds: 1));
      return;
    }

    if (_powerManager == null || _bleService == null) {
      _logger.warning('BLE service or power manager not available');
      return;
    }

    await _powerManager!.scheduleManualBurstAfter(Duration.zero);
    _updateStatus();
  }

  /// Get current burst scanning status
  BurstScanningStatus getCurrentStatus() {
    // ✅ FIX: Return default status if power manager not initialized
    if (_powerManager == null) {
      return BurstScanningStatus(
        isBurstActive: false,
        secondsUntilNextScan: null,
        burstTimeRemaining: null,
        currentScanInterval: 60000, // Default 60s interval
        powerStats: PowerManagementStats(
          currentScanInterval: 60000,
          currentHealthCheckInterval: 30000,
          consecutiveSuccessfulChecks: 0,
          consecutiveFailedChecks: 0,
          connectionQualityScore: 0.0,
          connectionStabilityScore: 0.0,
          timeSinceLastSuccess: Duration.zero,
          qualityMeasurementsCount: 0,
          isBurstMode: false,
          nextScheduledScanTime: null,
          powerMode: PowerMode.balanced,
          isDutyCycleScanning: false,
          batteryLevel: 100,
          isCharging: false,
          isAppInBackground: false,
        ),
      );
    }

    final stats = _powerManager!.getCurrentStats();

    int? secondsUntilNextScan;
    int? burstTimeRemaining;

    // Only calculate next scan time if no active scanning
    if (!_isBurstActive) {
      if (_nextActionTime != null) {
        final remaining = _nextActionTime!.difference(DateTime.now()).inSeconds;
        secondsUntilNextScan = remaining > 0 ? remaining : 0;
      }
    }

    if (_burstEndTime != null && _isBurstActive) {
      final remaining = _burstEndTime!.difference(DateTime.now()).inSeconds;
      burstTimeRemaining = remaining > 0 ? remaining : 0;

      // Safety check: If burst time expired but still marked as active, force end
      if (remaining <= 0) {
        _logger.warning(
          '🔥 BURST: Timer expired but still active - forcing burst end',
        );
        // Don't await here as we're in a getter, just schedule the cleanup
        Future.microtask(() => _handleBurstScanStop());
      }
    }

    return BurstScanningStatus(
      isBurstActive: _isBurstActive,
      secondsUntilNextScan: secondsUntilNextScan,
      burstTimeRemaining: burstTimeRemaining,
      currentScanInterval: stats.currentScanInterval,
      powerStats: stats,
    );
  }

  /// Update and broadcast status
  void _updateStatus() {
    final status = getCurrentStatus();
    for (final listener in List.of(_statusListeners)) {
      try {
        listener(status);
      } catch (e, stackTrace) {
        _logger.warning(
          'Error notifying burst scan listener: $e',
          e,
          stackTrace,
        );
      }
    }
  }

  void _startStatusTimer() {
    _statusUpdateTimer ??= Timer.periodic(
      Duration(seconds: 1),
      (_) => _tickScheduler(),
    );
  }

  void _stopStatusTimer() {
    _statusUpdateTimer?.cancel();
    _statusUpdateTimer = null;
  }

  /// Scheduler tick: enforce deterministic state transitions.
  void _tickScheduler() {
    final now = DateTime.now();

    // If scanning and burst end reached, stop and schedule cooldown.
    if (_isBurstActive &&
        _burstEndTime != null &&
        now.isAfter(_burstEndTime!)) {
      _logger.fine(
        '🔥 BURST: Scan duration elapsed - stopping and entering cooldown',
      );
      _handleBurstScanStop();
    }

    // If not scanning and next action time reached, start scanning.
    if (!_isBurstActive &&
        _nextActionTime != null &&
        now.isAfter(_nextActionTime!)) {
      _logger.fine('🔥 BURST: Cooldown elapsed - starting scan');
      unawaited(_handleBurstScanStart());
    }

    _updateStatus();
  }

  /// Dispose of resources
  void dispose() {
    _stopStatusTimer();
    _burstDurationTimer?.cancel();
    _bluetoothStateSubscription?.cancel();

    // ✅ FIX: Only dispose power manager if it was initialized
    // This prevents LateInitializationError when Bluetooth was never available
    _powerManager?.dispose();

    _statusListeners.clear();
    _logger.info('🔥 Burst scanning controller disposed');
  }
}

/// Burst scanning status information
class BurstScanningStatus {
  final bool isBurstActive;
  final int? secondsUntilNextScan;
  final int? burstTimeRemaining;
  final int currentScanInterval;
  final PowerManagementStats powerStats;

  const BurstScanningStatus({
    required this.isBurstActive,
    this.secondsUntilNextScan,
    this.burstTimeRemaining,
    required this.currentScanInterval,
    required this.powerStats,
  });

  /// Get human-readable status message
  String get statusMessage {
    if (isBurstActive && burstTimeRemaining != null) {
      return 'Burst scanning... ${burstTimeRemaining}s remaining';
    } else if (secondsUntilNextScan != null && secondsUntilNextScan! > 0) {
      return 'Next scan in ${secondsUntilNextScan}s';
    } else if (secondsUntilNextScan == 0) {
      return 'Starting scan...';
    } else {
      return 'Burst scanning ready';
    }
  }

  /// Check if manual override is available
  bool get canOverride => !isBurstActive && (secondsUntilNextScan ?? 0) > 5;

  /// Get scanning efficiency rating
  String get efficiencyRating {
    final rating = powerStats.batteryEfficiencyRating;
    if (rating >= 0.8) return 'Excellent';
    if (rating >= 0.6) return 'Good';
    if (rating >= 0.4) return 'Fair';
    return 'Poor';
  }

  @override
  String toString() =>
      'BurstStatus(burst: $isBurstActive, next: ${secondsUntilNextScan}s, burstRemaining: ${burstTimeRemaining}s)';
}
