// Relay configuration manager for mesh networking
// Provides simple enable/disable control for relay functionality
// Inspired by BitChat's relay control approach

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages relay configuration and policies
///
/// This provides a simple enable/disable flag for relay functionality,
/// similar to BitChat's relay control. This allows devices to opt-out
/// of relay operations if desired (e.g., for battery saving).
class RelayConfigManager {
  static final _logger = Logger('RelayConfigManager');

  // Singleton instance
  static RelayConfigManager? _instance;
  static RelayConfigManager get instance =>
      _instance ??= RelayConfigManager._();

  // Private constructor for singleton
  RelayConfigManager._();

  // Configuration keys
  static const String _keyRelayEnabled = 'mesh_relay_enabled';
  static const String _keyMaxRelayHops = 'mesh_relay_max_hops';
  static const String _keyRelayBatteryThreshold =
      'mesh_relay_battery_threshold';

  // Default values
  static const bool _defaultRelayEnabled = true;
  static const int _defaultMaxRelayHops = 3;
  static const int _maxAllowedRelayHops = 5;
  static const int _defaultBatteryThreshold = 20; // percent

  // Cached values
  bool? _cachedRelayEnabled;
  int? _cachedMaxRelayHops;
  int? _cachedBatteryThreshold;

  /// Initialize the relay config manager
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load cached values
      _cachedRelayEnabled =
          prefs.getBool(_keyRelayEnabled) ?? _defaultRelayEnabled;
      final storedHops = prefs.getInt(_keyMaxRelayHops);
      _cachedMaxRelayHops = _sanitizeMaxRelayHops(
        storedHops ?? _defaultMaxRelayHops,
      );
      _cachedBatteryThreshold =
          prefs.getInt(_keyRelayBatteryThreshold) ?? _defaultBatteryThreshold;

      _logger.info('📡 RelayConfigManager initialized:');
      _logger.info('   - Relay enabled: $_cachedRelayEnabled');
      _logger.info('   - Max relay hops: $_cachedMaxRelayHops');
      _logger.info('   - Battery threshold: $_cachedBatteryThreshold%');
    } catch (e) {
      _logger.severe('Failed to initialize RelayConfigManager: $e');
      // Use defaults on error
      _cachedRelayEnabled = _defaultRelayEnabled;
      _cachedMaxRelayHops = _defaultMaxRelayHops;
      _cachedBatteryThreshold = _defaultBatteryThreshold;
    }
  }

  /// Check if relay is currently enabled
  ///
  /// This is the primary method for checking if device should relay messages.
  /// Similar to BitChat's isRelayEnabled() check.
  bool isRelayEnabled() {
    // Return cached value if available, otherwise default
    return _cachedRelayEnabled ?? _defaultRelayEnabled;
  }

  /// Enable relay functionality
  Future<void> enableRelay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyRelayEnabled, true);
      _cachedRelayEnabled = true;
      _logger.info('✅ Relay ENABLED');
    } catch (e) {
      _logger.severe('Failed to enable relay: $e');
    }
  }

  /// Disable relay functionality
  Future<void> disableRelay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyRelayEnabled, false);
      _cachedRelayEnabled = false;
      _logger.info('❌ Relay DISABLED');
    } catch (e) {
      _logger.severe('Failed to disable relay: $e');
    }
  }

  /// Get maximum relay hops allowed
  int getMaxRelayHops() {
    return _cachedMaxRelayHops ?? _defaultMaxRelayHops;
  }

  /// Set maximum relay hops
  Future<void> setMaxRelayHops(int hops) async {
    if (hops < 1) {
      _logger.warning('Invalid max relay hops: $hops (must be >=1)');
      return;
    }

    final sanitized = _sanitizeMaxRelayHops(hops);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyMaxRelayHops, sanitized);
      _cachedMaxRelayHops = sanitized;
      _logger.info('📡 Max relay hops set to: $sanitized');
    } catch (e) {
      _logger.severe('Failed to set max relay hops: $e');
    }
  }

  /// Get battery threshold for relay operations
  int getBatteryThreshold() {
    return _cachedBatteryThreshold ?? _defaultBatteryThreshold;
  }

  /// Set battery threshold for relay operations (percentage)
  /// Device will not relay if battery is below this threshold
  Future<void> setBatteryThreshold(int threshold) async {
    if (threshold < 0 || threshold > 100) {
      _logger.warning('Invalid battery threshold: $threshold (must be 0-100)');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyRelayBatteryThreshold, threshold);
      _cachedBatteryThreshold = threshold;
      _logger.info('🔋 Battery threshold set to: $threshold%');
    } catch (e) {
      _logger.severe('Failed to set battery threshold: $e');
    }
  }

  /// Check if device should relay based on battery level
  /// Returns true if battery level is above threshold
  bool shouldRelayWithBatteryLevel(int currentBatteryPercent) {
    final threshold = getBatteryThreshold();
    final shouldRelay = currentBatteryPercent >= threshold;

    if (!shouldRelay) {
      _logger.info(
        '🔋 Relay blocked: Battery $currentBatteryPercent% < $threshold%',
      );
    }

    return shouldRelay;
  }

  /// Get relay configuration summary for debugging
  Map<String, dynamic> getConfigSummary() {
    return {
      'relayEnabled': isRelayEnabled(),
      'maxRelayHops': getMaxRelayHops(),
      'batteryThreshold': getBatteryThreshold(),
    };
  }

  /// Reset to default configuration
  Future<void> resetToDefaults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyRelayEnabled);
      await prefs.remove(_keyMaxRelayHops);
      await prefs.remove(_keyRelayBatteryThreshold);

      _cachedRelayEnabled = _defaultRelayEnabled;
      _cachedMaxRelayHops = _defaultMaxRelayHops;
      _cachedBatteryThreshold = _defaultBatteryThreshold;

      _logger.info('🔄 Relay config reset to defaults');
    } catch (e) {
      _logger.severe('Failed to reset relay config: $e');
    }
  }

  int _sanitizeMaxRelayHops(int hops) {
    if (hops > _maxAllowedRelayHops) {
      _logger.warning(
        'Max relay hops $hops exceeds allowed limit ($_maxAllowedRelayHops); capping',
      );
      return _maxAllowedRelayHops;
    }
    if (hops < 1) return 1;
    return hops;
  }
}
