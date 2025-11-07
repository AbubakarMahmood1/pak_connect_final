// Battery-efficient scanning system with burst-mode and adaptive power management
// Phase 1 Enhancement: BitChat-style duty cycle scanning + quality-based adaptation

import 'dart:async';
import 'dart:math';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'battery_optimizer.dart';

/// Power modes for BLE scanning (based on BitChat battle-tested implementation)
enum PowerMode {
  /// Full power - continuous scanning (charging, good battery, foreground)
  performance,

  /// Balanced mode - 80% duty cycle: 8s ON / 2s OFF (normal battery, foreground)
  balanced,

  /// Power saver - 20% duty cycle: 2s ON / 8s OFF (low battery or background)
  powerSaver,

  /// Ultra low power - 9% duty cycle: 1s ON / 10s OFF (critical battery < 10%)
  ultraLowPower,
}

/// Adaptive power management for BLE operations with battery optimization
///
/// Phase 1 Enhancement: Combines BitChat's duty cycle scanning with quality-based adaptation
/// - Duty cycle scanning: Varies ON/OFF periods based on battery/background state
/// - Quality adaptation: Fine-tunes intervals based on connection metrics
/// - Hybrid approach: More sophisticated than BitChat's battery-only logic
class AdaptivePowerManager {
  static final _logger = Logger('AdaptivePowerManager');
  static const String _settingsPrefix = 'power_mgmt_';

  // Configuration ranges (quality-based adaptation)
  static const int _minScanInterval = 20000; // 20 seconds
  static const int _maxScanInterval = 120000; // 120 seconds
  static const int _burstDuration = 20000; // 20 seconds active scanning
  static const int _minHealthCheckInterval = 30000; // 30 seconds
  static const int _maxHealthCheckInterval = 60000; // 60 seconds

  // BitChat-inspired constants (Phase 1: Duty Cycle Scanning)
  static const int _criticalBatteryPercent = 10;
  static const int _lowBatteryPercent = 20;
  static const int _mediumBatteryPercent = 50;

  // Duty cycle periods (BitChat pattern)
  static const int _scanOnDurationNormal = 8000; // 8s ON
  static const int _scanOffDurationNormal = 2000; // 2s OFF (80% duty cycle)
  static const int _scanOnDurationPowerSave = 2000; // 2s ON
  static const int _scanOffDurationPowerSave = 8000; // 8s OFF (20% duty cycle)
  static const int _scanOnDurationUltraLow = 1000; // 1s ON
  static const int _scanOffDurationUltraLow = 10000; // 10s OFF (9% duty cycle)

  // RSSI thresholds per power mode (BitChat pattern)
  static const int _rssiThresholdPerformance = -95; // dBm
  static const int _rssiThresholdBalanced = -85; // dBm
  static const int _rssiThresholdPowerSaver = -75; // dBm
  static const int _rssiThresholdUltraLow = -65; // dBm

  // Connection limits per power mode
  static const int _maxConnectionsNormal = 8;
  static const int _maxConnectionsPowerSave = 4;
  static const int _maxConnectionsUltraLow = 2;
  
  // Current state (quality-based adaptation)
  int _currentScanInterval = 60000;
  int _currentHealthCheckInterval = 30000;
  bool _isBurstMode = false;
  Timer? _scanTimer;
  Timer? _healthCheckTimer;
  Timer? _burstTimer;
  DateTime? _nextScheduledScanTime; // Track actual scheduled time with randomization

  // Phase 1: Duty cycle state (BitChat pattern)
  PowerMode _currentPowerMode = PowerMode.balanced;
  bool _isAppInBackground = false;
  int _batteryLevel = 100;
  bool _isCharging = false;
  Timer? _dutyCycleTimer;
  bool _isDutyCycleScanning = false; // true during ON period

  // Connection quality tracking
  final List<ConnectionQualityMeasurement> _qualityHistory = [];
  int _consecutiveSuccessfulChecks = 0;
  int _consecutiveFailedChecks = 0;
  DateTime _lastSuccessfulConnection = DateTime.now();

  // Callbacks
  Function()? onStartScan;
  Function()? onStopScan;
  Function()? onHealthCheck;
  Function(PowerManagementStats)? onStatsUpdate;
  Function(PowerMode)? onPowerModeChanged; // Phase 1: Power mode notifications
  
  // Randomization for network desynchronization
  final Random _random = Random();
  
  /// Initialize power management with adaptive algorithms
  ///
  /// Phase 1: Now supports duty cycle scanning and battery awareness
  Future<void> initialize({
    Function()? onStartScan,
    Function()? onStopScan,
    Function()? onHealthCheck,
    Function(PowerManagementStats)? onStatsUpdate,
    Function(PowerMode)? onPowerModeChanged,
  }) async {
    this.onStartScan = onStartScan;
    this.onStopScan = onStopScan;
    this.onHealthCheck = onHealthCheck;
    this.onStatsUpdate = onStatsUpdate;
    this.onPowerModeChanged = onPowerModeChanged;

    await _loadSettings();

    // Phase 1: Initialize battery monitoring
    final batteryOptimizer = BatteryOptimizer();
    batteryOptimizer.onPowerModeChanged = (batteryMode) {
      _onBatteryModeChanged(batteryMode);
    };

    // Get initial battery state
    final batteryInfo = batteryOptimizer.getCurrentInfo();
    _batteryLevel = batteryInfo.level;
    _isCharging = batteryInfo.isCharging;
    _updatePowerMode();

    _logger.info(
      'Adaptive power management initialized - '
      'scan: ${_currentScanInterval}ms, health: ${_currentHealthCheckInterval}ms, '
      'power mode: ${_currentPowerMode.name}, battery: $_batteryLevel%',
    );
  }
  
  /// Start adaptive scanning with burst-mode optimization
  ///
  /// Phase 2a: ALL modes use burst scanning with variable wait times
  Future<void> startAdaptiveScanning() async {
    await _stopAllTimers();

    _logger.info(
      '🔍 Starting burst scanning - power mode: ${_currentPowerMode.name}, '
      'battery: $_batteryLevel%, background: $_isAppInBackground',
    );

    // ALL modes use burst scanning, just with different wait times
    _startBurstScan();
    _scheduleNextScan();

    // Keep quality-based health checks for connection monitoring
    _scheduleHealthCheck();
  }
  
  /// Stop all power management operations
  Future<void> stopScanning() async {
    await _stopAllTimers();
    _logger.info('Stopped adaptive scanning');
  }

  // ============================================================================
  // Phase 1: Duty Cycle Scanning (BitChat Pattern)
  // ============================================================================

  /// [DEPRECATED] Old duty cycle check
  @Deprecated('Phase 2a: Use burst scanning for all modes')
  bool _shouldUseDutyCycle() {
    return false; // Always use burst scanning now
  }

  /// [DEPRECATED] Old duty cycle scanning - replaced by burst scanning with variable waits
  @Deprecated('Phase 2a: Use burst scanning with _getBaseIntervalForPowerMode() instead')
  // ignore: unused_element
  void _startDutyCycleScanning() {
    _stopDutyCycleScanning();

    final (onDuration, offDuration) = switch (_currentPowerMode) {
      PowerMode.balanced => (_scanOnDurationNormal, _scanOffDurationNormal),
      PowerMode.powerSaver => (_scanOnDurationPowerSave, _scanOffDurationPowerSave),
      PowerMode.ultraLowPower => (_scanOnDurationUltraLow, _scanOffDurationUltraLow),
      PowerMode.performance => (0, 0), // No duty cycle
    };

    if (onDuration == 0) {
      // Performance mode - no duty cycle
      return;
    }

    _logger.info(
      'Starting duty cycle: ${onDuration}ms ON / ${offDuration}ms OFF '
      '(${((onDuration / (onDuration + offDuration)) * 100).toStringAsFixed(1)}% duty cycle)',
    );

    // Start with ON period immediately
    _isDutyCycleScanning = true;
    onStartScan?.call();

    // Schedule duty cycle loop
    _dutyCycleTimer = Timer.periodic(
      Duration(milliseconds: onDuration + offDuration),
      (_) {
        if (_isDutyCycleScanning) {
          // End ON period, start OFF period
          _logger.fine('Duty cycle: Scan OFF for ${offDuration}ms');
          _isDutyCycleScanning = false;
          onStopScan?.call();

          // Schedule next ON period
          Timer(Duration(milliseconds: offDuration), () {
            if (_shouldUseDutyCycle()) {
              _logger.fine('Duty cycle: Scan ON for ${onDuration}ms');
              _isDutyCycleScanning = true;
              onStartScan?.call();
            }
          });
        }
      },
    );
  }

  /// Stop duty cycle scanning
  void _stopDutyCycleScanning() {
    _dutyCycleTimer?.cancel();
    _dutyCycleTimer = null;

    if (_isDutyCycleScanning) {
      _isDutyCycleScanning = false;
      onStopScan?.call();
    }
  }

  /// Update power mode based on battery and background state (BitChat logic)
  void _updatePowerMode() {
    final previousMode = _currentPowerMode;

    final newMode = switch ((_isCharging, _isAppInBackground, _batteryLevel)) {
      // Charging and foreground → Performance
      (true, false, _) => PowerMode.performance,

      // Critical battery → Ultra Low Power
      (_, _, <= _criticalBatteryPercent) => PowerMode.ultraLowPower,

      // Low battery → Power Saver
      (_, _, <= _lowBatteryPercent) => PowerMode.powerSaver,

      // Background with medium battery → Power Saver
      (_, true, <= _mediumBatteryPercent) => PowerMode.powerSaver,

      // Background with good battery → Balanced
      (_, true, _) => PowerMode.balanced,

      // Foreground with good battery → Balanced
      _ => PowerMode.balanced,
    };

    if (newMode == previousMode) {
      return; // No change
    }

    _currentPowerMode = newMode;
    _logger.info(
      '🔋 Power mode changed: ${previousMode.name} → ${newMode.name} '
      '(battery: $_batteryLevel%, charging: $_isCharging, background: $_isAppInBackground)',
    );

    // Notify listeners
    onPowerModeChanged?.call(newMode);

    // Restart burst scanning with new power mode wait times (Phase 2a)
    _scanTimer?.cancel();
    _scheduleNextScan(); // Will use new power mode's wait time

    _logger.info(
      '⚡ Restarted scanning with new power mode: ${_currentPowerMode.name} '
      '(wait time: ${_getBaseIntervalForPowerMode()}ms)'
    );
  }

  /// Handle battery mode changes from BatteryOptimizer
  void _onBatteryModeChanged(BatteryPowerMode batteryMode) {
    // Update battery state from battery optimizer
    final batteryOptimizer = BatteryOptimizer();
    final info = batteryOptimizer.getCurrentInfo();
    _batteryLevel = info.level;
    _isCharging = info.isCharging;

    _logger.fine('Battery mode changed: ${batteryMode.name} (level: $_batteryLevel%)');
    _updatePowerMode();
  }

  /// Set app background state (call from AppLifecycleObserver)
  void setAppBackgroundState(bool inBackground) {
    if (_isAppInBackground == inBackground) return;

    _isAppInBackground = inBackground;
    _logger.info('App state changed: ${inBackground ? 'background' : 'foreground'}');
    _updatePowerMode();
  }

  /// Get current power mode
  PowerMode get currentPowerMode => _currentPowerMode;

  /// Get RSSI threshold for current power mode (BitChat pattern)
  int get rssiThreshold {
    return switch (_currentPowerMode) {
      PowerMode.performance => _rssiThresholdPerformance,
      PowerMode.balanced => _rssiThresholdBalanced,
      PowerMode.powerSaver => _rssiThresholdPowerSaver,
      PowerMode.ultraLowPower => _rssiThresholdUltraLow,
    };
  }

  /// Get max connections for current power mode (BitChat pattern)
  int get maxConnections {
    return switch (_currentPowerMode) {
      PowerMode.performance => _maxConnectionsNormal,
      PowerMode.balanced => _maxConnectionsNormal,
      PowerMode.powerSaver => _maxConnectionsPowerSave,
      PowerMode.ultraLowPower => _maxConnectionsUltraLow,
    };
  }

  // ============================================================================
  // End Phase 1: Duty Cycle Scanning
  // ============================================================================

  /// Trigger an immediate burst scan (manual override)
  Future<void> triggerImmediateScan() async {
    if (_isBurstMode) {
      _logger.info('Already in burst mode, ignoring manual trigger');
      return;
    }

    _logger.info('🔥 MANUAL: Triggering immediate burst scan');

    // Cancel current scan timer
    _scanTimer?.cancel();

    // Start burst scan immediately
    _startBurstScan();

    // Reschedule next scan
    _scheduleNextScan();
  }
  
  /// Report connection success for adaptive adjustment
  void reportConnectionSuccess({
    int? rssi,
    double? connectionTime,
    bool? dataTransferSuccess,
  }) {
    _consecutiveSuccessfulChecks++;
    _consecutiveFailedChecks = 0;
    _lastSuccessfulConnection = DateTime.now();
    
    final quality = ConnectionQualityMeasurement(
      timestamp: DateTime.now(),
      success: true,
      rssi: rssi,
      connectionTime: connectionTime,
      dataTransferSuccess: dataTransferSuccess ?? true,
    );
    
    _addQualityMeasurement(quality);
    _adaptToConnectionQuality();
    
    _logger.fine('Connection success reported - consecutive: $_consecutiveSuccessfulChecks');
  }
  
  /// Report connection failure for adaptive adjustment  
  void reportConnectionFailure({
    String? reason,
    int? rssi,
    double? attemptTime,
  }) {
    _consecutiveFailedChecks++;
    _consecutiveSuccessfulChecks = 0;
    
    final quality = ConnectionQualityMeasurement(
      timestamp: DateTime.now(),
      success: false,
      rssi: rssi,
      connectionTime: attemptTime,
      failureReason: reason,
    );
    
    _addQualityMeasurement(quality);
    _adaptToConnectionQuality();
    
    _logger.warning('Connection failure reported - consecutive: $_consecutiveFailedChecks, reason: $reason');
  }
  
  /// Get base wait interval for current power mode (Phase 2a: burst wait times)
  int _getBaseIntervalForPowerMode() {
    return switch (_currentPowerMode) {
      PowerMode.performance => _currentScanInterval, // Quality-adapted (20-120s)
      PowerMode.balanced => 5000,       // 5s wait (80% duty with 20s burst)
      PowerMode.powerSaver => 80000,    // 80s wait (20% duty with 20s burst)
      PowerMode.ultraLowPower => 202000, // 202s wait (9% duty with 20s burst)
    };
  }

  /// Schedule next scan with randomized interval to prevent network synchronization
  ///
  /// Phase 2a: Uses power-mode-based wait times instead of duty cycling
  void _scheduleNextScan() {
    // Get base interval from power mode
    int baseInterval = _getBaseIntervalForPowerMode();

    // Add randomization (±20%) to prevent network-wide synchronization
    final randomOffset = (baseInterval * 0.4 * _random.nextDouble()) - (baseInterval * 0.2);
    final actualInterval = (baseInterval + randomOffset).round().clamp(_minScanInterval, _maxScanInterval);

    // Track the actual scheduled time for accurate UI countdown
    _nextScheduledScanTime = DateTime.now().add(Duration(milliseconds: actualInterval));

    _scanTimer = Timer(Duration(milliseconds: actualInterval), () {
      if (!_isBurstMode) {
        _startBurstScan();
      }
      _scheduleNextScan();
    });

    _logger.fine(
      'Next scan scheduled in ${actualInterval}ms (base: ${baseInterval}ms, mode: ${_currentPowerMode.name}) at $_nextScheduledScanTime'
    );
  }
  
  /// Execute burst-mode scanning for battery efficiency
  void _startBurstScan() {
    _isBurstMode = true;
    
    _logger.fine('Starting burst scan (${_burstDuration}ms)');
    onStartScan?.call();
    
    _burstTimer = Timer(Duration(milliseconds: _burstDuration), () {
      _stopBurstScan();
    });
  }
  
  /// Stop burst scanning and return to idle
  void _stopBurstScan() {
    _isBurstMode = false;
    _burstTimer?.cancel();
    
    _logger.fine('Stopping burst scan');
    onStopScan?.call();
  }
  
  /// Schedule adaptive health checks
  void _scheduleHealthCheck() {
    // Add slight randomization to health checks too
    final randomOffset = (_currentHealthCheckInterval * 0.1 * _random.nextDouble()) - (_currentHealthCheckInterval * 0.05);
    final actualInterval = (_currentHealthCheckInterval + randomOffset).round();
    
    _healthCheckTimer = Timer(Duration(milliseconds: actualInterval), () {
      _performHealthCheck();
      _scheduleHealthCheck();
    });
    
    _logger.fine('Next health check scheduled in ${actualInterval}ms');
  }
  
  /// Perform connection health check
  void _performHealthCheck() {
    _logger.fine('Performing connection health check');
    onHealthCheck?.call();
    
    // Update statistics
    final stats = getCurrentStats();
    onStatsUpdate?.call(stats);
  }
  
  /// Adapt scanning behavior based on connection quality
  void _adaptToConnectionQuality() {
    final recentQuality = _calculateRecentQualityScore();
    final stabilityScore = _calculateConnectionStability();
    
    // Adaptive scan interval adjustment
    if (recentQuality > 0.8 && stabilityScore > 0.9) {
      // High quality and stable - increase intervals to save battery
      _increaseScanInterval();
      _increaseHealthCheckInterval();
      
    } else if (recentQuality < 0.5 || stabilityScore < 0.6) {
      // Poor quality or unstable - decrease intervals for better responsiveness
      _decreaseScanInterval();
      _decreaseHealthCheckInterval();
      
    } else if (_consecutiveSuccessfulChecks > 10) {
      // Long period of success - gradually increase intervals
      _graduallyIncreaseScanInterval();
      
    } else if (_consecutiveFailedChecks > 3) {
      // Multiple failures - be more aggressive with scanning
      _decreaseScanInterval();
    }
    
    _saveSettings();
    _logger.info('Adapted to quality: $recentQuality, stability: $stabilityScore - scan: ${_currentScanInterval}ms, health: ${_currentHealthCheckInterval}ms');
  }
  
  /// Calculate recent connection quality score (0.0 - 1.0)
  double _calculateRecentQualityScore() {
    if (_qualityHistory.isEmpty) return 0.5;
    
    final recentMeasurements = _qualityHistory
        .where((m) => DateTime.now().difference(m.timestamp).inMinutes < 5)
        .toList();
    
    if (recentMeasurements.isEmpty) return 0.5;
    
    final successRate = recentMeasurements.where((m) => m.success).length / recentMeasurements.length;
    final avgRssi = recentMeasurements
        .where((m) => m.rssi != null)
        .map((m) => m.rssi!)
        .fold<double>(0, (sum, rssi) => sum + rssi) / 
        recentMeasurements.where((m) => m.rssi != null).length.clamp(1, double.infinity);
    
    final avgConnectionTime = recentMeasurements
        .where((m) => m.connectionTime != null && m.success)
        .map((m) => m.connectionTime!)
        .fold<double>(0, (sum, time) => sum + time) /
        recentMeasurements.where((m) => m.connectionTime != null && m.success).length.clamp(1, double.infinity);
    
    // Combine factors: success rate (50%), RSSI strength (30%), connection speed (20%)
    double qualityScore = successRate * 0.5;
    
    if (!avgRssi.isNaN && avgRssi.isFinite) {
      final rssiScore = ((avgRssi + 100) / 50).clamp(0, 1); // -100 to -50 dBm range
      qualityScore += rssiScore * 0.3;
    }
    
    if (!avgConnectionTime.isNaN && avgConnectionTime.isFinite) {
      final speedScore = (1.0 / (avgConnectionTime / 1000 + 1)).clamp(0, 1);
      qualityScore += speedScore * 0.2;
    }
    
    return qualityScore.clamp(0.0, 1.0);
  }
  
  /// Calculate connection stability score
  double _calculateConnectionStability() {
    if (_qualityHistory.length < 3) return 0.5;
    
    final recent = _qualityHistory.takeLast(10).toList();
    final successPattern = recent.map((m) => m.success ? 1 : 0).toList();
    
    // Calculate variance in success pattern (lower variance = more stable)
    final mean = successPattern.fold(0, (sum, val) => sum + val) / successPattern.length;
    final variance = successPattern.map((val) => pow(val - mean, 2)).fold<double>(0, (sum, val) => sum + val) / successPattern.length;
    
    // Stability score is inverse of variance
    final stabilityScore = 1.0 - variance.clamp(0.0, 1.0);
    
    return stabilityScore;
  }
  
  /// Increase scan interval for battery saving
  void _increaseScanInterval() {
    _currentScanInterval = (_currentScanInterval * 1.2).round().clamp(_minScanInterval, _maxScanInterval);
  }
  
  /// Decrease scan interval for better responsiveness
  void _decreaseScanInterval() {
    _currentScanInterval = (_currentScanInterval * 0.8).round().clamp(_minScanInterval, _maxScanInterval);
  }
  
  /// Gradually increase scan interval
  void _graduallyIncreaseScanInterval() {
    _currentScanInterval = (_currentScanInterval * 1.05).round().clamp(_minScanInterval, _maxScanInterval);
  }
  
  /// Increase health check interval
  void _increaseHealthCheckInterval() {
    _currentHealthCheckInterval = (_currentHealthCheckInterval * 1.3).round().clamp(_minHealthCheckInterval, _maxHealthCheckInterval);
  }
  
  /// Decrease health check interval
  void _decreaseHealthCheckInterval() {
    _currentHealthCheckInterval = (_currentHealthCheckInterval * 0.7).round().clamp(_minHealthCheckInterval, _maxHealthCheckInterval);
  }
  
  /// Add quality measurement and manage history size
  void _addQualityMeasurement(ConnectionQualityMeasurement measurement) {
    _qualityHistory.add(measurement);
    
    // Keep only recent measurements (last 100 or last hour)
    final cutoff = DateTime.now().subtract(Duration(hours: 1));
    _qualityHistory.removeWhere((m) => m.timestamp.isBefore(cutoff));
    
    if (_qualityHistory.length > 100) {
      _qualityHistory.removeRange(0, _qualityHistory.length - 100);
    }
  }
  
  /// Stop all running timers
  Future<void> _stopAllTimers() async {
    _scanTimer?.cancel();
    _healthCheckTimer?.cancel();
    _burstTimer?.cancel();
    _dutyCycleTimer?.cancel(); // Phase 1: Stop duty cycle timer

    if (_isBurstMode) {
      onStopScan?.call();
      _isBurstMode = false;
    }

    // Phase 1: Stop duty cycle scanning
    if (_isDutyCycleScanning) {
      onStopScan?.call();
      _isDutyCycleScanning = false;
    }
  }
  
  /// Load settings from persistent storage
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _currentScanInterval = prefs.getInt('${_settingsPrefix}scan_interval') ?? 60000;
      _currentHealthCheckInterval = prefs.getInt('${_settingsPrefix}health_interval') ?? 30000;
      
      // Ensure values are within valid ranges
      _currentScanInterval = _currentScanInterval.clamp(_minScanInterval, _maxScanInterval);
      _currentHealthCheckInterval = _currentHealthCheckInterval.clamp(_minHealthCheckInterval, _maxHealthCheckInterval);
    } catch (e) {
      _logger.warning('Failed to load power management settings: $e');
    }
  }
  
  /// Save settings to persistent storage
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_settingsPrefix}scan_interval', _currentScanInterval);
      await prefs.setInt('${_settingsPrefix}health_interval', _currentHealthCheckInterval);
    } catch (e) {
      _logger.warning('Failed to save power management settings: $e');
    }
  }
  
  /// Get current power management statistics
  PowerManagementStats getCurrentStats() {
    final recentQuality = _calculateRecentQualityScore();
    final stability = _calculateConnectionStability();
    final timeSinceLastSuccess = DateTime.now().difference(_lastSuccessfulConnection);

    return PowerManagementStats(
      currentScanInterval: _currentScanInterval,
      currentHealthCheckInterval: _currentHealthCheckInterval,
      consecutiveSuccessfulChecks: _consecutiveSuccessfulChecks,
      consecutiveFailedChecks: _consecutiveFailedChecks,
      connectionQualityScore: recentQuality,
      connectionStabilityScore: stability,
      timeSinceLastSuccess: timeSinceLastSuccess,
      qualityMeasurementsCount: _qualityHistory.length,
      isBurstMode: _isBurstMode,
      nextScheduledScanTime: _nextScheduledScanTime,
      // Phase 1: Duty cycle stats
      powerMode: _currentPowerMode,
      isDutyCycleScanning: _isDutyCycleScanning,
      batteryLevel: _batteryLevel,
      isCharging: _isCharging,
      isAppInBackground: _isAppInBackground,
    );
  }

  /// Get the actual next scheduled scan time (with randomization)
  DateTime? get nextScheduledScanTime => _nextScheduledScanTime;
  
  /// Manual override for scan interval (temporary)
  void overrideScanInterval(int milliseconds) {
    _currentScanInterval = milliseconds.clamp(_minScanInterval, _maxScanInterval);
    _logger.info('Manual override: scan interval set to ${_currentScanInterval}ms');
  }
  
  /// Reset adaptive algorithms to defaults
  Future<void> resetToDefaults() async {
    _currentScanInterval = 60000;
    _currentHealthCheckInterval = 30000;
    _consecutiveSuccessfulChecks = 0;
    _consecutiveFailedChecks = 0;
    _qualityHistory.clear();
    await _saveSettings();
    _logger.info('Reset power management to default settings');
  }
  
  /// Dispose of resources
  void dispose() {
    _stopAllTimers();
    _logger.info('Adaptive power manager disposed');
  }
}

/// Connection quality measurement for adaptive algorithms
class ConnectionQualityMeasurement {
  final DateTime timestamp;
  final bool success;
  final int? rssi;
  final double? connectionTime;
  final bool? dataTransferSuccess;
  final String? failureReason;
  
  const ConnectionQualityMeasurement({
    required this.timestamp,
    required this.success,
    this.rssi,
    this.connectionTime,
    this.dataTransferSuccess,
    this.failureReason,
  });
}

/// Power management statistics
///
/// Phase 1 Enhancement: Added duty cycle and battery awareness stats
class PowerManagementStats {
  final int currentScanInterval;
  final int currentHealthCheckInterval;
  final int consecutiveSuccessfulChecks;
  final int consecutiveFailedChecks;
  final double connectionQualityScore;
  final double connectionStabilityScore;
  final Duration timeSinceLastSuccess;
  final int qualityMeasurementsCount;
  final bool isBurstMode;
  final DateTime? nextScheduledScanTime;

  // Phase 1: Duty cycle stats
  final PowerMode powerMode;
  final bool isDutyCycleScanning;
  final int batteryLevel;
  final bool isCharging;
  final bool isAppInBackground;

  const PowerManagementStats({
    required this.currentScanInterval,
    required this.currentHealthCheckInterval,
    required this.consecutiveSuccessfulChecks,
    required this.consecutiveFailedChecks,
    required this.connectionQualityScore,
    required this.connectionStabilityScore,
    required this.timeSinceLastSuccess,
    required this.qualityMeasurementsCount,
    required this.isBurstMode,
    this.nextScheduledScanTime,
    // Phase 1: Duty cycle stats
    required this.powerMode,
    required this.isDutyCycleScanning,
    required this.batteryLevel,
    required this.isCharging,
    required this.isAppInBackground,
  });

  /// Get battery efficiency rating (0.0 - 1.0)
  ///
  /// Phase 1: Now considers duty cycle mode for more accurate efficiency calculation
  double get batteryEfficiencyRating {
    // Duty cycle efficiency contribution
    final dutyCycleScore = switch (powerMode) {
      PowerMode.performance => 0.0, // Continuous scanning - lowest efficiency
      PowerMode.balanced => 0.6, // 80% duty cycle
      PowerMode.powerSaver => 0.85, // 20% duty cycle
      PowerMode.ultraLowPower => 0.95, // 9% duty cycle - highest efficiency
    };

    // Quality score contribution (maintain connection quality)
    final qualityScore = connectionQualityScore;

    // Balance duty cycle efficiency (70%) with connection quality (30%)
    return (dutyCycleScore * 0.7 + qualityScore * 0.3).clamp(0.0, 1.0);
  }

  /// Get estimated duty cycle percentage (Phase 2a: based on burst + wait times)
  double get dutyCyclePercentage {
    return switch (powerMode) {
      PowerMode.performance => 100.0, // Quality-adapted, varies
      PowerMode.balanced => 80.0,     // 20s burst / 25s total
      PowerMode.powerSaver => 20.0,   // 20s burst / 100s total
      PowerMode.ultraLowPower => 9.0, // 20s burst / 222s total
    };
  }

  @override
  String toString() =>
    'PowerStats('
    'mode: ${powerMode.name}, '
    'battery: $batteryLevel%, '
    'duty: ${dutyCyclePercentage.toStringAsFixed(1)}%, '
    'quality: ${(connectionQualityScore * 100).toStringAsFixed(1)}%, '
    'efficiency: ${(batteryEfficiencyRating * 100).toStringAsFixed(1)}%'
    ')';
}

extension _ListExtensions<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (length <= count) return this;
    return skip(length - count);
  }
}
