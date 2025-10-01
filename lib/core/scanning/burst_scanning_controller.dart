import 'dart:async';
import 'package:logging/logging.dart';
import '../power/adaptive_power_manager.dart';
import '../../data/services/ble_service.dart';

/// Bridge controller that connects AdaptivePowerManager to actual BLE scanning operations
/// This ensures burst scanning reaches the radio hardware with proper source tagging
class BurstScanningController {
  static final _logger = Logger('BurstScanningController');

  late final AdaptivePowerManager _powerManager;
  BLEService? _bleService;

  // Status tracking
  bool _isBurstActive = false;
  bool _isManualActive = false;
  DateTime? _nextScanTime;
  DateTime? _burstEndTime;
  DateTime? _manualScanEndTime;
  Timer? _statusUpdateTimer;
  Timer? _manualScanTimer;

  // Status stream
  final StreamController<BurstScanningStatus> _statusController =
      StreamController<BurstScanningStatus>.broadcast();

  Stream<BurstScanningStatus> get statusStream => _statusController.stream;

  /// Initialize the burst scanning controller
  Future<void> initialize(BLEService bleService) async {
    _bleService = bleService;
    _powerManager = AdaptivePowerManager();

    await _powerManager.initialize(
      onStartScan: _handleBurstScanStart,
      onStopScan: _handleBurstScanStop,
      onHealthCheck: _handleHealthCheck,
      onStatsUpdate: _handleStatsUpdate,
    );

    // Start status update timer
    _statusUpdateTimer = Timer.periodic(Duration(seconds: 1), (_) => _updateStatus());

    _logger.info('🔧 Burst scanning controller initialized');
  }

  /// Start adaptive burst scanning
  Future<void> startBurstScanning() async {
    if (_bleService == null) {
      _logger.warning('BLE service not available for burst scanning');
      return;
    }

    _logger.info('🔥 Starting adaptive burst scanning');
    await _powerManager.startAdaptiveScanning();
  }

  /// Stop burst scanning
  Future<void> stopBurstScanning() async {
    _logger.info('🔥 Stopping adaptive burst scanning');
    await _powerManager.stopScanning();
    _isBurstActive = false;
    _burstEndTime = null;
    _updateStatus();
  }

  /// Handle burst scan start from power manager
  void _handleBurstScanStart() async {
    if (_bleService?.isPeripheralMode == true) {
      _logger.fine('🔥 Skipping burst scan - device in peripheral mode');
      return;
    }

    _logger.info('🔥 BURST: Starting burst scan cycle');
    _isBurstActive = true;
    _burstEndTime = DateTime.now().add(Duration(milliseconds: 20000)); // 20s burst duration

    try {
      // 🔧 FIX: Call actual BLE service with burst source
      await _bleService?.startScanning(source: ScanningSource.burst);
      _logger.info('✅ BURST: Radio scanning started successfully');
    } catch (e) {
      _logger.severe('❌ BURST: Failed to start radio scanning: $e');
      _isBurstActive = false;
      _burstEndTime = null;
    }

    _updateStatus();
  }

  /// Handle burst scan stop from power manager
  void _handleBurstScanStop() async {
    _logger.info('🔥 BURST: Stopping burst scan cycle');
    _isBurstActive = false;
    _burstEndTime = null;

    try {
      await _bleService?.stopScanning();
      _logger.info('✅ BURST: Radio scanning stopped successfully');
    } catch (e) {
      _logger.warning('❌ BURST: Error stopping radio scanning: $e');
    }

    // Calculate next scan time
    final stats = _powerManager.getCurrentStats();
    _nextScanTime = DateTime.now().add(Duration(milliseconds: stats.currentScanInterval));

    _updateStatus();
  }

  /// Handle health check from power manager
  void _handleHealthCheck() {
    _logger.fine('🔥 BURST: Performing connection health check');
    // Health check logic can be added here if needed
  }

  /// Handle power management stats update
  void _handleStatsUpdate(PowerManagementStats stats) {
    _logger.fine('🔥 BURST: Power stats updated - scan interval: ${stats.currentScanInterval}ms');

    // Update next scan time if not currently scanning
    if (!_isBurstActive && _nextScanTime == null) {
      _nextScanTime = DateTime.now().add(Duration(milliseconds: stats.currentScanInterval));
    }

    _updateStatus();
  }

  /// Report connection success to power manager
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    _powerManager.reportConnectionSuccess(
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
    _powerManager.reportConnectionFailure(
      reason: reason,
      rssi: rssi,
      attemptTime: attemptTime,
    );
  }

  /// Manual override - trigger immediate scan
  Future<void> triggerManualScan() async {
    if (_bleService == null) {
      _logger.warning('BLE service not available for manual scan');
      return;
    }

    _logger.info('🔥 MANUAL: Triggering immediate scan (override)');

    try {
      // Stop any current burst scanning
      if (_isBurstActive) {
        await _bleService?.stopScanning();
        _isBurstActive = false;
        _burstEndTime = null;
      }

      // Cancel any existing manual scan timer
      _manualScanTimer?.cancel();
      _manualScanTimer = null;

      // Start manual scanning (this will take priority)
      await _bleService?.startScanning(source: ScanningSource.manual);
      _logger.info('✅ MANUAL: Manual scan started successfully');

      // Set manual scan active with 30-second duration
      _isManualActive = true;
      _manualScanEndTime = DateTime.now().add(Duration(seconds: 30));

      // Set timer to automatically stop manual scan after 30 seconds
      _manualScanTimer = Timer(Duration(seconds: 30), () async {
        _logger.info('🔥 MANUAL: 30-second manual scan completed, stopping...');
        await _stopManualScan();
      });

      // Don't update next scan time during manual scan - will be set after manual scan ends
      _nextScanTime = null;

    } catch (e) {
      _logger.severe('❌ MANUAL: Failed to start manual scan: $e');
      _isManualActive = false;
      _manualScanEndTime = null;
    }

    _updateStatus();
  }

  /// Stop manual scan and transition to next scheduled scan
  Future<void> _stopManualScan() async {
    if (!_isManualActive) return;

    _logger.info('🔥 MANUAL: Stopping manual scan');
    _isManualActive = false;
    _manualScanEndTime = null;
    _manualScanTimer?.cancel();
    _manualScanTimer = null;

    try {
      await _bleService?.stopScanning();
      _logger.info('✅ MANUAL: Manual scan stopped successfully');
    } catch (e) {
      _logger.warning('❌ MANUAL: Error stopping manual scan: $e');
    }

    // Set next scan time after manual scan completes
    final stats = _powerManager.getCurrentStats();
    _nextScanTime = DateTime.now().add(Duration(milliseconds: stats.currentScanInterval));

    _updateStatus();
  }

  /// Get current burst scanning status
  BurstScanningStatus getCurrentStatus() {
    final stats = _powerManager.getCurrentStats();

    int? secondsUntilNextScan;
    int? burstTimeRemaining;
    int? manualScanElapsed;
    int? manualScanRemaining;

    // Calculate manual scan timers
    if (_isManualActive && _manualScanEndTime != null) {
      final now = DateTime.now();
      final elapsed = now.difference(_manualScanEndTime!.subtract(Duration(seconds: 30))).inSeconds;
      final remaining = _manualScanEndTime!.difference(now).inSeconds;
      manualScanElapsed = elapsed > 0 ? elapsed : 0;
      manualScanRemaining = remaining > 0 ? remaining : 0;
    }

    // Only calculate next scan time if no active scanning
    if (!_isBurstActive && !_isManualActive) {
      if (stats.nextScheduledScanTime != null) {
        // Use actual scheduled time from power manager (includes randomization)
        final remaining = stats.nextScheduledScanTime!.difference(DateTime.now()).inSeconds;
        secondsUntilNextScan = remaining > 0 ? remaining : 0;
      } else if (_nextScanTime != null) {
        // Fallback to our estimated time
        final remaining = _nextScanTime!.difference(DateTime.now()).inSeconds;
        secondsUntilNextScan = remaining > 0 ? remaining : 0;
      }
    }

    if (_burstEndTime != null && _isBurstActive) {
      final remaining = _burstEndTime!.difference(DateTime.now()).inSeconds;
      burstTimeRemaining = remaining > 0 ? remaining : 0;
    }

    return BurstScanningStatus(
      isBurstActive: _isBurstActive,
      isManualActive: _isManualActive,
      secondsUntilNextScan: secondsUntilNextScan,
      burstTimeRemaining: burstTimeRemaining,
      manualScanElapsed: manualScanElapsed,
      manualScanRemaining: manualScanRemaining,
      currentScanInterval: stats.currentScanInterval,
      powerStats: stats,
    );
  }

  /// Update and broadcast status
  void _updateStatus() {
    final status = getCurrentStatus();
    _statusController.add(status);

    // Sync timers with power manager for accurate countdown
    if (!_isBurstActive && _nextScanTime != null) {
      final remaining = _nextScanTime!.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        // Trigger scan if timer expired but hasn't fired yet
        _powerManager.startAdaptiveScanning();
      }
    }
  }

  /// Dispose of resources
  void dispose() {
    _statusUpdateTimer?.cancel();
    _manualScanTimer?.cancel();
    _powerManager.dispose();
    _statusController.close();
    _logger.info('🔥 Burst scanning controller disposed');
  }
}

/// Burst scanning status information
class BurstScanningStatus {
  final bool isBurstActive;
  final bool isManualActive;
  final int? secondsUntilNextScan;
  final int? burstTimeRemaining;
  final int? manualScanElapsed;
  final int? manualScanRemaining;
  final int currentScanInterval;
  final PowerManagementStats powerStats;

  const BurstScanningStatus({
    required this.isBurstActive,
    required this.isManualActive,
    this.secondsUntilNextScan,
    this.burstTimeRemaining,
    this.manualScanElapsed,
    this.manualScanRemaining,
    required this.currentScanInterval,
    required this.powerStats,
  });

  /// Get human-readable status message
  String get statusMessage {
    if (isManualActive && manualScanElapsed != null) {
      return 'Manual scanning... ${manualScanElapsed}s elapsed';
    } else if (isBurstActive && burstTimeRemaining != null) {
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
  bool get canOverride => !isBurstActive && !isManualActive && (secondsUntilNextScan ?? 0) > 5;

  /// Get scanning efficiency rating
  String get efficiencyRating {
    final rating = powerStats.batteryEfficiencyRating;
    if (rating >= 0.8) return 'Excellent';
    if (rating >= 0.6) return 'Good';
    if (rating >= 0.4) return 'Fair';
    return 'Poor';
  }

  @override
  String toString() => 'BurstStatus(burst: $isBurstActive, manual: $isManualActive, next: ${secondsUntilNextScan}s, burstRemaining: ${burstTimeRemaining}s, manualElapsed: ${manualScanElapsed}s)';
}