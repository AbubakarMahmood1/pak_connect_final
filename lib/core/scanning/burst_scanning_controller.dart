import 'dart:async';
import 'package:logging/logging.dart';
import '../power/adaptive_power_manager.dart';
import '../../data/services/ble_service.dart';

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

  late final AdaptivePowerManager _powerManager;
  BLEService? _bleService;

  // Status tracking
  bool _isBurstActive = false;
  DateTime? _nextScanTime;
  DateTime? _burstEndTime;
  Timer? _statusUpdateTimer;
  Timer? _burstDurationTimer; // Timer to handle burst duration in continuous scan mode

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
    
    // Cancel burst duration timer
    _burstDurationTimer?.cancel();
    _burstDurationTimer = null;
    
    await _powerManager.stopScanning();
    _isBurstActive = false;
    _burstEndTime = null;
    _updateStatus();
  }

  /// Handle burst scan start from power manager
  void _handleBurstScanStart() async {
    // 🔧 DUAL-ROLE FIX: Removed peripheral mode check - scanning and advertising coexist
    // Both central and peripheral roles run simultaneously without interference

    // 🔥 OPTIMIZATION: Check if at max connections before scanning
    final connectionManager = _bleService?.connectionManager;
    if (connectionManager != null && !connectionManager.canAcceptMoreConnections) {
      _logger.info('🔥 BURST: Skipping scan - already at max connections (${connectionManager.activeConnectionCount}/${connectionManager.maxClientConnections})');
      _logger.fine('Connected devices: ${connectionManager.activeConnections.map((p) => p.uuid).join(", ")}');
      return; // Don't scan if we can't accept more connections
    }

    _logger.info('🔥 BURST: Starting burst scan cycle (${connectionManager?.activeConnectionCount ?? 0}/${connectionManager?.maxClientConnections ?? '?'} connections)');
    _isBurstActive = true;
    _burstEndTime = DateTime.now().add(Duration(milliseconds: 20000)); // 20s burst duration

    try {
      await _bleService?.startScanning(source: ScanningSource.burst);
      _logger.info('✅ BURST: Scan started successfully');
      
      // Start our own timer to handle burst duration
      // This is needed because in performance mode (continuous scan), 
      // the power manager won't call onStopScan
      _burstDurationTimer?.cancel();
      _burstDurationTimer = Timer(Duration(milliseconds: 20000), () {
        if (_isBurstActive) {
          _logger.info('🔥 BURST: Duration timer expired - treating as burst end');
          _handleBurstScanStop();
        }
      });
    } catch (e) {
      _logger.severe('❌ BURST: Failed to start scanning: $e');
      _isBurstActive = false;
      _burstEndTime = null;
      _burstDurationTimer?.cancel();
    }

    _updateStatus();
  }

  /// Handle burst scan stop from power manager
  void _handleBurstScanStop() async {
    _logger.info('🔥 BURST: Stopping burst scan cycle');
    
    // Cancel burst duration timer
    _burstDurationTimer?.cancel();
    _burstDurationTimer = null;
    
    _isBurstActive = false;
    _burstEndTime = null;

    try {
      await _bleService?.stopScanning();
      _logger.info('✅ BURST: Scan stopped successfully');
    } catch (e) {
      _logger.warning('❌ BURST: Error stopping scan: $e');
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

  /// Manual override - trigger immediate burst scan
  Future<void> triggerManualScan() async {
    _logger.info('🔥 MANUAL: User requested immediate scan - triggering next burst scan now');

    if (_bleService == null) {
      _logger.warning('BLE service not available');
      return;
    }

    // Simply trigger the power manager to start the next burst scan immediately
    // This reuses all the existing burst scan logic (20s duration, proper source tagging, etc.)
    await _powerManager.triggerImmediateScan();

    _logger.info('✅ MANUAL: Immediate burst scan triggered via power manager');
  }

  /// Get current burst scanning status
  BurstScanningStatus getCurrentStatus() {
    final stats = _powerManager.getCurrentStats();

    int? secondsUntilNextScan;
    int? burstTimeRemaining;

    // Only calculate next scan time if no active scanning
    if (!_isBurstActive) {
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
      
      // Safety check: If burst time expired but still marked as active, force end
      if (remaining <= 0) {
        _logger.warning('🔥 BURST: Timer expired but still active - forcing burst end');
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
    _statusController.add(status);
  }

  /// Dispose of resources
  void dispose() {
    _statusUpdateTimer?.cancel();
    _burstDurationTimer?.cancel();
    _powerManager.dispose();
    _statusController.close();
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
  String toString() => 'BurstStatus(burst: $isBurstActive, next: ${secondsUntilNextScan}s, burstRemaining: ${burstTimeRemaining}s)';
}