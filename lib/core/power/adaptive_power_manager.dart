// Battery-efficient scanning system with burst-mode and adaptive power management

import 'dart:async';
import 'dart:math';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Adaptive power management for BLE operations with battery optimization
class AdaptivePowerManager {
  static final _logger = Logger('AdaptivePowerManager');
  static const String _settingsPrefix = 'power_mgmt_';
  
  // Configuration ranges
  static const int _minScanInterval = 20000; // 2 seconds
  static const int _maxScanInterval = 120000; // 120 seconds
  static const int _burstDuration = 20000; // 20 seconds active scanning
  static const int _minHealthCheckInterval = 30000; // 30 seconds
  static const int _maxHealthCheckInterval = 60000; // 60 seconds
  
  // Current state
  int _currentScanInterval = 60000;
  int _currentHealthCheckInterval = 30000;
  bool _isBurstMode = false;
  Timer? _scanTimer;
  Timer? _healthCheckTimer;
  Timer? _burstTimer;
  DateTime? _nextScheduledScanTime; // Track actual scheduled time with randomization
  
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
  
  // Randomization for network desynchronization
  final Random _random = Random();
  
  /// Initialize power management with adaptive algorithms
  Future<void> initialize({
    Function()? onStartScan,
    Function()? onStopScan,
    Function()? onHealthCheck,
    Function(PowerManagementStats)? onStatsUpdate,
  }) async {
    this.onStartScan = onStartScan;
    this.onStopScan = onStopScan;
    this.onHealthCheck = onHealthCheck;
    this.onStatsUpdate = onStatsUpdate;
    
    await _loadSettings();
    _logger.info('Adaptive power management initialized - scan interval: ${_currentScanInterval}ms, health check: ${_currentHealthCheckInterval}ms');
  }
  
  /// Start adaptive scanning with burst-mode optimization
  Future<void> startAdaptiveScanning() async {
    await _stopAllTimers();

    _logger.info('Starting adaptive scanning with burst-mode optimization');

    // Start with immediate first scan for better UX
    _logger.info('🔥 IMMEDIATE: Starting initial burst scan for first-time experience');
    _startBurstScan();

    _scheduleNextScan();
    _scheduleHealthCheck();
  }
  
  /// Stop all power management operations
  Future<void> stopScanning() async {
    await _stopAllTimers();
    _logger.info('Stopped adaptive scanning');
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
  
  /// Schedule next scan with randomized interval to prevent network synchronization
  void _scheduleNextScan() {
    // Add randomization (±20%) to prevent network-wide synchronization
    final randomOffset = (_currentScanInterval * 0.4 * _random.nextDouble()) - (_currentScanInterval * 0.2);
    final actualInterval = (_currentScanInterval + randomOffset).round().clamp(_minScanInterval, _maxScanInterval);

    // Track the actual scheduled time for accurate UI countdown
    _nextScheduledScanTime = DateTime.now().add(Duration(milliseconds: actualInterval));

    _scanTimer = Timer(Duration(milliseconds: actualInterval), () {
      if (!_isBurstMode) {
        _startBurstScan();
      }
      _scheduleNextScan();
    });

    _logger.fine('Next scan scheduled in ${actualInterval}ms (base: ${_currentScanInterval}ms) at $_nextScheduledScanTime');
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
    
    if (_isBurstMode) {
      onStopScan?.call();
      _isBurstMode = false;
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
  });
  
  /// Get battery efficiency rating (0.0 - 1.0)
  double get batteryEfficiencyRating {
    const maxScanInterval = 15000; // Match AdaptivePowerManager._maxScanInterval
    const minScanInterval = 2000;  // Match AdaptivePowerManager._minScanInterval
    
    final intervalScore = 1.0 - ((maxScanInterval - currentScanInterval) / (maxScanInterval - minScanInterval));
    final qualityScore = connectionQualityScore;
    
    // Balance between battery savings and connection quality
    return (intervalScore * 0.6 + qualityScore * 0.4).clamp(0.0, 1.0);
  }
  
  @override
  String toString() => 'PowerStats(scan: ${currentScanInterval}ms, quality: ${(connectionQualityScore * 100).toStringAsFixed(1)}%, efficiency: ${(batteryEfficiencyRating * 100).toStringAsFixed(1)}%)';
}

extension _ListExtensions<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (length <= count) return this;
    return skip(length - count);
  }
}