import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
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
  static const bool _strictTdmFlag = bool.fromEnvironment(
    'PAKCONNECT_STRICT_TDM',
    defaultValue: false,
  );
  static bool get _strictTdmEnabled =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _strictTdmFlag;

  AdaptivePowerManager?
  _powerManager; // ✅ FIX: Made nullable to prevent LateInitializationError on disposal
  IConnectionService? _bleService;
  StreamSubscription<BluetoothStateInfo>? _bluetoothStateSubscription;
  bool _lastKnownBluetoothReady = false;

  // Status tracking
  bool _isBurstActive = false;
  bool _scanActuallyStarted =
      false; // ✅ FIX: Track if scan actually started (vs skipped due to Bluetooth unavailable)
  DateTime? _nextActionTime;
  DateTime? _burstEndTime;
  Duration? _scheduledCountdownDuration;
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
    if (_powerManager != null) return; // Already initialized

    _bleService = bleService;
    _powerManager = AdaptivePowerManager();

    await _powerManager!.initialize(
      onStartScan: _handleBurstScanStart,
      onStopScan: _handleBurstScanStop,
      onHealthCheck: _handleHealthCheck,
      onStatsUpdate: _handleStatsUpdate,
    );

    final bluetoothMonitor = BluetoothStateMonitor();
    await _powerManager!.updateBluetoothAvailability(
      bluetoothMonitor.isBluetoothReady,
    );
    _lastKnownBluetoothReady = bluetoothMonitor.isBluetoothReady;
    _bluetoothStateSubscription = bluetoothMonitor.stateStream.listen((
      stateInfo,
    ) {
      unawaited(recoverScannerRuntime());
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
    _syncNextActionTimeFromPowerManager();
    _updateStatus();
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
    _nextActionTime = null;
    _scheduledCountdownDuration = null;
    _updateStatus();
  }

  /// Handle burst scan start from power manager
  Future<void> _handleBurstScanStart() async {
    // ✅ FIX #2: Check BLE service availability first
    if (_bleService == null) {
      _logger.fine('🔥 BURST: BLE service not available - skipping scan');
      return;
    }

    // ✅ FIX #2: Check Bluetooth state before attempting scan
    // This prevents permission errors when Bluetooth is off/unauthorized/unsupported
    final bluetoothMonitor = BluetoothStateMonitor();
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
    _nextActionTime = null;
    _scheduledCountdownDuration = null;

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
    _syncNextActionTimeFromPowerManager();

    // ✅ FIX: Only try to stop scan if it actually started
    // This prevents "Stopping unknown BLE scan" logs when Bluetooth unavailable
    if (_scanActuallyStarted) {
      if (_strictTdmEnabled) {
        _logger.fine(
          '🔥 BURST: Strict TDM active - burst stop leaves scheduler running',
        );
        _scanActuallyStarted = false;
        _updateStatus();
        return;
      }
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

    _syncNextActionTimeFromStats(stats);

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

    // Schedule the next burst soon without waiting for the normal adaptive
    // cadence.
    _nextActionTime = DateTime.now().add(delay);
    _scheduledCountdownDuration = delay;

    await _powerManager!.scheduleManualBurstAfter(delay);

    _logger.info('✅ MANUAL: Immediate burst scan triggered via power manager');
    _updateStatus();
  }

  /// Force a burst scan immediately, bypassing the normal adaptive wait.
  Future<void> forceBurstScanNow() async {
    _logger.info('🔥 MANUAL: Forcing burst scan (adaptive wait bypass)');
    _nextActionTime = DateTime.now();
    _scheduledCountdownDuration = Duration.zero;

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

  /// End the current burst immediately and return to the adaptive cooldown.
  Future<void> endActiveBurstNow() async {
    if (!_isBurstActive || _powerManager == null) {
      _logger.fine(
        '🔥 MANUAL: No active burst to end early - ignoring scanner stop request',
      );
      return;
    }

    _logger.info(
      '🔥 MANUAL: Ending active burst early and returning to adaptive cooldown',
    );
    _burstEndTime = DateTime.now();
    _scheduledCountdownDuration = null;
    _powerManager!.shortenActiveBurst(Duration.zero);
    _updateStatus();
  }

  /// Unified recovery entry point used by both manual retry and automatic
  /// Bluetooth restoration.
  Future<void> recoverScannerRuntime({
    bool forceWakeIfReady = false,
  }) async {
    final bluetoothMonitor = BluetoothStateMonitor();
    final available =
        bluetoothMonitor.availabilityPhase == BluetoothAvailabilityPhase.ready;
    final wasAvailable = _lastKnownBluetoothReady;
    _lastKnownBluetoothReady = available;

    final future = _powerManager?.updateBluetoothAvailability(available);
    if (future != null) {
      await future;
    }

    if (!available || _powerManager == null || _bleService == null) {
      _updateStatus();
      return;
    }

    final burstAlreadyRunning = _isBurstActive || _scanActuallyStarted;

    if (burstAlreadyRunning) {
      _logger.fine(
        '🔄 Scanner runtime recovery skipped extra wake-up because a burst is already active',
      );
      _updateStatus();
      return;
    }

    if (forceWakeIfReady) {
      await forceBurstScanNow();
      return;
    }

    if (!wasAvailable) {
      _logger.info(
        '🔄 Bluetooth restored - forcing an immediate burst scan before normal scheduling resumes',
      );
      await forceBurstScanNow();
    }
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
    final effectiveNextActionTime = _isBurstActive
        ? null
        : (_nextActionTime ?? stats.nextScheduledScanTime);

    int? secondsUntilNextScan;
    int? burstTimeRemaining;
    Duration? scheduledCountdownDuration = _scheduledCountdownDuration;

    // Only calculate next scan time if no active scanning
    if (effectiveNextActionTime != null) {
      final remaining = effectiveNextActionTime.difference(DateTime.now());
      secondsUntilNextScan = remaining.inSeconds > 0 ? remaining.inSeconds : 0;
      scheduledCountdownDuration ??= remaining.isNegative
          ? Duration.zero
          : remaining;
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
      scheduledCountdownDuration: scheduledCountdownDuration,
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

  /// Scheduler tick: keep countdown status fresh and clean up expired bursts.
  void _tickScheduler() {
    final now = DateTime.now();

    // If scanning and burst end reached, stop and let the adaptive scheduler
    // provide the next scan timing.
    if (_isBurstActive &&
        _burstEndTime != null &&
        now.isAfter(_burstEndTime!)) {
      _logger.fine(
        '🔥 BURST: Scan duration elapsed - stopping current burst',
      );
      _handleBurstScanStop();
    }

    _updateStatus();
  }

  void _syncNextActionTimeFromPowerManager() {
    if (_powerManager == null) {
      _nextActionTime = null;
      _scheduledCountdownDuration = null;
      return;
    }
    _syncNextActionTimeFromStats(_powerManager!.getCurrentStats());
  }

  void _syncNextActionTimeFromStats(PowerManagementStats stats) {
    final nextScheduledScanTime = stats.nextScheduledScanTime;

    if (nextScheduledScanTime == null) {
      _nextActionTime = null;
      if (!_isBurstActive) {
        _scheduledCountdownDuration = null;
      }
      return;
    }

    final nextActionChanged =
        _nextActionTime == null ||
        (_nextActionTime!
                .difference(nextScheduledScanTime)
                .inMilliseconds
                .abs() >
            250);

    _nextActionTime = nextScheduledScanTime;

    if (!_isBurstActive &&
        (nextActionChanged || _scheduledCountdownDuration == null)) {
      final remaining = nextScheduledScanTime.difference(DateTime.now());
      _scheduledCountdownDuration = remaining.isNegative
          ? Duration.zero
          : remaining;
    }
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
  final Duration? scheduledCountdownDuration;
  final int currentScanInterval;
  final PowerManagementStats powerStats;

  const BurstScanningStatus({
    required this.isBurstActive,
    this.secondsUntilNextScan,
    this.burstTimeRemaining,
    this.scheduledCountdownDuration,
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
