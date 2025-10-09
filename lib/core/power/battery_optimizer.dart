// Battery-aware power optimization for BLE operations
// Dynamically adjusts scanning and advertising based on device battery level

import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Power modes based on battery level and charging state
enum BatteryPowerMode {
  /// Device charging or full battery (> 80%)
  /// - Aggressive BLE scanning
  /// - Frequent advertising
  /// - Maximum discovery performance
  charging,
  
  /// Good battery level (50-80%)
  /// - Normal BLE operations
  /// - Standard scanning intervals
  /// - Balanced performance/efficiency
  normal,
  
  /// Medium battery level (30-50%)
  /// - Reduced scanning frequency
  /// - Longer scan intervals
  /// - Moderate power saving
  moderate,
  
  /// Low battery level (15-30%)
  /// - Minimal scanning
  /// - Extended intervals
  /// - Significant power saving
  lowPower,
  
  /// Critical battery level (< 15%)
  /// - Emergency mode
  /// - Rare scanning bursts
  /// - Maximum power conservation
  critical,
}

/// Battery state information for UI display
class BatteryInfo {
  final int level; // 0-100%
  final BatteryState state;
  final BatteryPowerMode powerMode;
  final DateTime lastUpdate;
  
  const BatteryInfo({
    required this.level,
    required this.state,
    required this.powerMode,
    required this.lastUpdate,
  });
  
  bool get isCharging => 
    state == BatteryState.charging || 
    state == BatteryState.full;
  
  String get modeDescription {
    switch (powerMode) {
      case BatteryPowerMode.charging:
        return 'Charging - Maximum Performance';
      case BatteryPowerMode.normal:
        return 'Normal - Balanced Mode';
      case BatteryPowerMode.moderate:
        return 'Medium - Power Saving';
      case BatteryPowerMode.lowPower:
        return 'Low - Reduced Scanning';
      case BatteryPowerMode.critical:
        return 'Critical - Emergency Mode';
    }
  }
}

/// Battery-aware power optimization service
/// 
/// Monitors device battery and dynamically adjusts BLE power consumption:
/// - Scanning frequency
/// - Advertising intervals
/// - Connection retry behavior
/// 
/// Works as a coordinator that sends battery state updates to interested parties
/// rather than directly controlling AdaptivePowerManager.
class BatteryOptimizer {
  static final _logger = Logger('BatteryOptimizer');
  static const String _prefsKey = 'battery_optimizer_enabled';
  static const String _lastModeKey = 'battery_last_power_mode';
  
  final Battery _battery = Battery();
  Timer? _batteryMonitor;
  StreamSubscription<BatteryState>? _stateSubscription;
  Timer? _debounceTimer;
  
  // Current state
  int _currentLevel = 100;
  BatteryState _currentState = BatteryState.full;
  BatteryPowerMode _currentPowerMode = BatteryPowerMode.normal;
  DateTime _lastUpdate = DateTime.now();
  DateTime _lastStateEventTime = DateTime.now();
  bool _isEnabled = true;
  
  // Callbacks for external coordination
  Function(BatteryInfo)? onBatteryUpdate;
  Function(BatteryPowerMode)? onPowerModeChanged;
  
  // Singleton pattern for global battery awareness
  static BatteryOptimizer? _instance;
  
  factory BatteryOptimizer() {
    _instance ??= BatteryOptimizer._internal();
    return _instance!;
  }
  
  BatteryOptimizer._internal();
  
  /// Initialize battery monitoring and optimization
  Future<void> initialize({
    Function(BatteryInfo)? onBatteryUpdate,
    Function(BatteryPowerMode)? onPowerModeChanged,
  }) async {
    this.onBatteryUpdate = onBatteryUpdate;
    this.onPowerModeChanged = onPowerModeChanged;
    
    // Load saved preferences
    await _loadPreferences();
    
    if (!_isEnabled) {
      _logger.info('🔋 Battery Optimizer disabled by user preference');
      return;
    }
    
    try {
      // Get initial battery state
      _currentLevel = await _battery.batteryLevel;
      _currentState = await _battery.batteryState;
      _lastUpdate = DateTime.now();
      
      _logger.info('🔋 Battery Optimizer initialized - Level: $_currentLevel%, State: $_currentState');
      
      // Determine initial power mode
      _updatePowerMode();
      
      // Start periodic battery checks (every 2 minutes)
      _batteryMonitor = Timer.periodic(
        Duration(minutes: 2), 
        (_) => _checkBattery(),
      );
      
      // Listen to battery state changes (charging/discharging)
      // NOTE: This stream can fire VERY frequently (multiple times per second)
      // even when the state hasn't truly changed. We debounce to avoid spam.
      _stateSubscription = _battery.onBatteryStateChanged.listen((state) {
        final now = DateTime.now();
        final timeSinceLastEvent = now.difference(_lastStateEventTime);
        
        // Debounce: Ignore events less than 2 seconds apart
        if (timeSinceLastEvent.inSeconds < 2) {
          return; // Too soon, ignore this event
        }
        
        // Only process if state actually changed
        if (_currentState != state) {
          _logger.info('🔋 Battery state changed: $_currentState → $state');
          _lastStateEventTime = now;
          _checkBattery();
        }
      });
      
      // Initial check
      await _checkBattery();
      
      _logger.info('✅ Battery Optimizer running in ${_currentPowerMode.name} mode');
      
    } catch (e) {
      _logger.severe('❌ Failed to initialize Battery Optimizer: $e');
      // Continue without battery optimization
      _isEnabled = false;
    }
  }
  
  /// Check battery and adjust power mode if needed
  Future<void> _checkBattery() async {
    if (!_isEnabled) return;
    
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      
      // Only update if level changed significantly (±5%)
      final levelChanged = (level - _currentLevel).abs() >= 5;
      final stateChanged = state != _currentState;
      
      if (!levelChanged && !stateChanged) {
        _logger.fine('🔋 Battery check: $level% (no significant change)');
        return;
      }
      
      _currentLevel = level;
      _currentState = state;
      _lastUpdate = DateTime.now();
      
      _logger.info('🔋 Battery update: $level% (${state.toString()})');
      
      // Determine new power mode
      _updatePowerMode();
      
      // Notify listeners
      final info = BatteryInfo(
        level: _currentLevel,
        state: _currentState,
        powerMode: _currentPowerMode,
        lastUpdate: _lastUpdate,
      );
      
      onBatteryUpdate?.call(info);
      
    } catch (e) {
      _logger.warning('⚠️ Failed to check battery: $e');
    }
  }
  
  /// Update power mode based on battery level and state
  void _updatePowerMode() {
    final previousMode = _currentPowerMode;
    
    // Determine new mode
    final newMode = _determinePowerMode(_currentLevel, _currentState);
    
    if (newMode == previousMode) {
      return; // No change needed
    }
    
    _currentPowerMode = newMode;
    _logger.info('🔋 Power mode changed: ${previousMode.name} → ${newMode.name}');
    
    // Apply new power mode to BLE operations
    _applyPowerMode(newMode);
    
    // Save to preferences
    _saveCurrentMode();
    
    // Notify listeners
    onPowerModeChanged?.call(newMode);
  }
  
  /// Determine appropriate power mode based on battery
  BatteryPowerMode _determinePowerMode(int level, BatteryState state) {
    // Charging or full battery: use maximum performance
    if (state == BatteryState.charging || state == BatteryState.full) {
      return BatteryPowerMode.charging;
    }
    
    // Battery level thresholds
    if (level < 15) {
      return BatteryPowerMode.critical;
    } else if (level < 30) {
      return BatteryPowerMode.lowPower;
    } else if (level < 50) {
      return BatteryPowerMode.moderate;
    } else {
      return BatteryPowerMode.normal;
    }
  }
  
  /// Apply power mode to BLE operations
  /// 
  /// Note: This sends notifications to listeners. Actual BLE power adjustments
  /// are handled by the BLE service layer which listens to battery updates.
  void _applyPowerMode(BatteryPowerMode mode) {
    switch (mode) {
      case BatteryPowerMode.charging:
        _logger.info('🔋 ⚡ Charging mode: Maximum performance recommended');
        break;
        
      case BatteryPowerMode.normal:
        _logger.info('🔋 ⚖️ Normal mode: Balanced operations');
        break;
        
      case BatteryPowerMode.moderate:
        _logger.info('🔋 🔽 Moderate mode: Reduced scanning recommended');
        break;
        
      case BatteryPowerMode.lowPower:
        _logger.warning('🔋 ⚠️ Low battery mode: Minimal scanning recommended');
        break;
        
      case BatteryPowerMode.critical:
        _logger.severe('🔋 🚨 Critical battery: Emergency power saving recommended');
        break;
    }
  }
  
  /// Load saved preferences
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool(_prefsKey) ?? true;
      
      final savedMode = prefs.getString(_lastModeKey);
      if (savedMode != null) {
        _currentPowerMode = BatteryPowerMode.values.firstWhere(
          (mode) => mode.name == savedMode,
          orElse: () => BatteryPowerMode.normal,
        );
      }
    } catch (e) {
      _logger.warning('Failed to load battery preferences: $e');
    }
  }
  
  /// Save current power mode
  Future<void> _saveCurrentMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastModeKey, _currentPowerMode.name);
    } catch (e) {
      _logger.warning('Failed to save battery mode: $e');
    }
  }
  
  /// Enable or disable battery optimization
  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;
    
    _isEnabled = enabled;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, enabled);
      
      if (enabled) {
        _logger.info('🔋 Battery Optimizer enabled');
        await _checkBattery();
      } else {
        _logger.info('🔋 Battery Optimizer disabled');
      }
    } catch (e) {
      _logger.warning('Failed to save battery optimizer preference: $e');
    }
  }
  
  /// Get current battery information
  BatteryInfo getCurrentInfo() {
    return BatteryInfo(
      level: _currentLevel,
      state: _currentState,
      powerMode: _currentPowerMode,
      lastUpdate: _lastUpdate,
    );
  }
  
  /// Force immediate battery check (for testing/debugging)
  Future<void> forceCheck() async {
    await _checkBattery();
  }
  
  /// Dispose resources
  void dispose() {
    _batteryMonitor?.cancel();
    _stateSubscription?.cancel();
    _debounceTimer?.cancel();
    _logger.info('🔋 Battery Optimizer disposed');
  }
  
  // Getters for UI
  int get currentLevel => _currentLevel;
  BatteryState get currentState => _currentState;
  BatteryPowerMode get currentPowerMode => _currentPowerMode;
  bool get isEnabled => _isEnabled;
  bool get isCharging => _currentState == BatteryState.charging || _currentState == BatteryState.full;
}
