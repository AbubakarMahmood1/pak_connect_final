# Quick Implementation Guide: Multi-Device Features

## 🎯 Files to Modify/Create

### 1️⃣ Battery Optimization (EASIEST - Start Here!)

#### **Files to Create**:
```
lib/core/power/battery_optimizer.dart
```

#### **Files to Modify**:
```
lib/core/app_core.dart (add battery monitoring initialization)
pubspec.yaml (add battery_plus package)
```

#### **Code Template**:
```dart
// lib/core/power/battery_optimizer.dart
import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:logging/logging.dart';
import 'adaptive_power_manager.dart';

class BatteryOptimizer {
  static final _logger = Logger('BatteryOptimizer');
  final Battery _battery = Battery();
  Timer? _batteryMonitor;
  int _lastBatteryLevel = 100;
  
  /// Start monitoring battery and adjusting power modes
  Future<void> initialize() async {
    final initialLevel = await _battery.batteryLevel;
    _lastBatteryLevel = initialLevel;
    _logger.info('🔋 Battery Optimizer initialized at $initialLevel%');
    
    // Check battery every 5 minutes
    _batteryMonitor = Timer.periodic(Duration(minutes: 5), (_) => _checkBattery());
    
    // Also listen to battery state changes (charging/discharging)
    _battery.onBatteryStateChanged.listen((BatteryState state) {
      _logger.info('🔋 Battery state changed: $state');
      _checkBattery();
    });
    
    // Initial check
    await _checkBattery();
  }
  
  Future<void> _checkBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      
      _logger.fine('🔋 Battery: $level% (${state.toString()})');
      
      // Only adjust if battery level changed significantly
      if ((level - _lastBatteryLevel).abs() < 5) return;
      
      _lastBatteryLevel = level;
      
      // Determine power mode based on battery
      if (state == BatteryState.charging || state == BatteryState.full) {
        // Charging: Use aggressive mode
        AdaptivePowerManager.setMode(PowerMode.aggressive);
        _logger.info('🔋 Charging detected → Aggressive power mode');
        
      } else if (level < 15) {
        // Critical battery: Ultra low power
        AdaptivePowerManager.setMode(PowerMode.ultraLowPower);
        _logger.warning('🔋 Critical battery ($level%) → Ultra low power mode');
        
      } else if (level < 30) {
        // Low battery: Reduce scanning
        AdaptivePowerManager.setMode(PowerMode.lowPower);
        _logger.info('🔋 Low battery ($level%) → Low power mode');
        
      } else if (level < 50) {
        // Medium battery: Balanced
        AdaptivePowerManager.setMode(PowerMode.balanced);
        _logger.info('🔋 Medium battery ($level%) → Balanced power mode');
        
      } else {
        // Good battery: Aggressive scanning
        AdaptivePowerManager.setMode(PowerMode.aggressive);
        _logger.info('🔋 Good battery ($level%) → Aggressive power mode');
      }
      
    } catch (e) {
      _logger.severe('Failed to check battery: $e');
    }
  }
  
  void dispose() {
    _batteryMonitor?.cancel();
    _logger.info('🔋 Battery Optimizer disposed');
  }
  
  /// Get current battery level (for UI)
  Future<int> getCurrentLevel() async {
    return await _battery.batteryLevel;
  }
  
  /// Get current battery state (for UI)
  Future<BatteryState> getCurrentState() async {
    return await _battery.batteryState;
  }
}
```

#### **Integration** (`lib/core/app_core.dart`):
```dart
// Add field:
late final BatteryOptimizer batteryOptimizer;

// In initialize() method, add:
batteryOptimizer = BatteryOptimizer();
await batteryOptimizer.initialize();
_logger.info('Battery optimizer initialized');
```

#### **Package** (`pubspec.yaml`):
```yaml
dependencies:
  battery_plus: ^5.0.0
```

**Test Commands**:
```bash
flutter pub add battery_plus
flutter run
# Watch logs for battery level detection
```

---

### 2️⃣ BLE Range Indicator (MEDIUM - UI Only!)

#### **Files to Modify**:
```
lib/presentation/widgets/discovery_overlay.dart
```

#### **Code to Add**:
```dart
// In discovery_overlay.dart, add helper methods:

/// Calculate signal strength from RSSI
SignalStrength _getSignalStrength(int rssi) {
  if (rssi >= -50) return SignalStrength.excellent;
  if (rssi >= -60) return SignalStrength.good;
  if (rssi >= -70) return SignalStrength.fair;
  if (rssi >= -80) return SignalStrength.poor;
  return SignalStrength.veryPoor;
}

/// Get color for signal strength
Color _getSignalColor(SignalStrength strength) {
  switch (strength) {
    case SignalStrength.excellent:
      return Colors.green;
    case SignalStrength.good:
      return Colors.lightGreen;
    case SignalStrength.fair:
      return Colors.orange;
    case SignalStrength.poor:
      return Colors.deepOrange;
    case SignalStrength.veryPoor:
      return Colors.red;
  }
}

/// Get icon bars count for signal strength
int _getSignalBars(SignalStrength strength) {
  switch (strength) {
    case SignalStrength.excellent: return 4;
    case SignalStrength.good: return 3;
    case SignalStrength.fair: return 2;
    case SignalStrength.poor: return 1;
    case SignalStrength.veryPoor: return 0;
  }
}

/// Build signal strength indicator widget
Widget _buildSignalIndicator(int rssi) {
  final strength = _getSignalStrength(rssi);
  final bars = _getSignalBars(strength);
  final color = _getSignalColor(strength);
  
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // Signal bars
      ...List.generate(4, (index) {
        return Container(
          width: 4,
          height: 4 + (index * 3), // Increasing height
          margin: EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: index < bars ? color : Colors.grey.withOpacity(0.3),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
      SizedBox(width: 4),
      // RSSI value (optional, for debugging)
      if (kDebugMode)
        Text(
          '$rssi dBm',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
    ],
  );
}

// In device list item, add:
trailing: Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    _buildSignalIndicator(discoveryData[device.uuid]?.rssi ?? -100),
    SizedBox(width: 8),
    Icon(Icons.chevron_right),
  ],
)
```

#### **Enum to Add**:
```dart
enum SignalStrength {
  excellent,  // -30 to -50 dBm
  good,       // -50 to -60 dBm
  fair,       // -60 to -70 dBm
  poor,       // -70 to -80 dBm
  veryPoor,   // < -80 dBm
}
```

**RSSI Reference**:
- **-30 to -50 dBm**: Excellent (< 1 meter)
- **-50 to -60 dBm**: Good (1-5 meters)
- **-60 to -70 dBm**: Fair (5-10 meters)
- **-70 to -80 dBm**: Poor (10-15 meters)
- **< -80 dBm**: Very Poor (> 15 meters)

---

### 3️⃣ Background Notifications (HARD - Platform Specific!)

#### **Files to Create**:
```
lib/platform/android/background_notification_handler.dart
lib/platform/android/foreground_service_handler.dart
lib/platform/ios/background_notification_handler.dart
android/app/src/main/AndroidManifest.xml (modify)
ios/Runner/Info.plist (modify)
```

#### **Packages Needed**:
```yaml
dependencies:
  flutter_local_notifications: ^17.0.0
  workmanager: ^0.5.2  # Android background tasks
```

#### **Android Implementation**:

**File**: `lib/platform/android/background_notification_handler.dart`
```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../domain/services/notification_service.dart';

class AndroidBackgroundNotificationHandler implements NotificationHandler {
  static const String CHANNEL_ID = 'pak_connect_messages';
  static const String CHANNEL_NAME = 'Messages';
  
  final FlutterLocalNotificationsPlugin _notifications = 
    FlutterLocalNotificationsPlugin();
  
  Future<void> initialize() async {
    // Android notification channel
    const androidChannel = AndroidNotificationChannel(
      CHANNEL_ID,
      CHANNEL_NAME,
      description: 'New message notifications',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );
    
    // Create channel
    await _notifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);
    
    // Initialize plugin
    const initializationSettingsAndroid = 
      AndroidInitializationSettings('@mipmap/ic_launcher');
    
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    
    await _notifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
  }
  
  void _onNotificationTap(NotificationResponse response) {
    // TODO: Navigate to chat when notification tapped
    final payload = response.payload;
    if (payload != null) {
      // Extract chat ID and navigate
      print('Notification tapped: $payload');
    }
  }
  
  @override
  Future<void> showNotification({
    required String title, 
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      CHANNEL_ID,
      CHANNEL_NAME,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
    );
    
    const details = NotificationDetails(android: androidDetails);
    
    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }
  
  @override
  Future<void> playSound() async {
    // Sound is handled by notification channel
  }
  
  @override
  Future<void> vibrate() async {
    // Vibration is handled by notification channel
  }
}
```

#### **iOS Implementation** (Limited!):
```dart
// lib/platform/ios/background_notification_handler.dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../domain/services/notification_service.dart';

class iOSBackgroundNotificationHandler implements NotificationHandler {
  final FlutterLocalNotificationsPlugin _notifications = 
    FlutterLocalNotificationsPlugin();
  
  Future<void> initialize() async {
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initSettings = InitializationSettings(iOS: iosSettings);
    await _notifications.initialize(initSettings);
    
    // Request permissions
    await _notifications
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
      ?.requestPermissions(alert: true, badge: true, sound: true);
  }
  
  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    const details = NotificationDetails(iOS: iosDetails);
    
    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }
  
  @override
  Future<void> playSound() async {}
  
  @override
  Future<void> vibrate() async {}
}
```

#### **Integration** (`lib/core/app_core.dart`):
```dart
// Replace in _initializeCoreServices():
final NotificationHandler notificationHandler;

if (Platform.isAndroid) {
  notificationHandler = AndroidBackgroundNotificationHandler();
  await (notificationHandler as AndroidBackgroundNotificationHandler).initialize();
} else if (Platform.isIOS) {
  notificationHandler = iOSBackgroundNotificationHandler();
  await (notificationHandler as iOSBackgroundNotificationHandler).initialize();
} else {
  notificationHandler = ForegroundNotificationHandler();
}

await NotificationService.initialize(handler: notificationHandler);
```

---

## 🎯 Testing Checklist

### Battery Optimization:
- [ ] Install on real Android device
- [ ] Check logs for battery level detection
- [ ] Drain battery below 30% → verify low power mode
- [ ] Charge device → verify aggressive mode
- [ ] Settings screen shows battery level (optional UI)

### BLE Range Indicator:
- [ ] Two devices side by side → 4 bars (green)
- [ ] Move 5 meters apart → 3 bars (light green)
- [ ] Move 10 meters apart → 2 bars (orange)
- [ ] Move 15 meters apart → 1 bar (red)

### Background Notifications:
- [ ] Device A sends message
- [ ] Device B app in background
- [ ] Device B receives notification
- [ ] Tap notification → opens chat
- [ ] Notification shows sender name + preview

---

## 📦 Package Installation Commands

```bash
# Battery optimization
flutter pub add battery_plus

# Background notifications
flutter pub add flutter_local_notifications
flutter pub add workmanager  # Android only

# Then install
flutter pub get
```

---

## 🚀 Recommended Order

1. **Week 1**: Battery Optimization (easiest, single-device testable)
2. **Week 2**: BLE Range Indicator (UI only, need 2 devices to test)
3. **Week 3-4**: Background Notifications (hardest, platform-specific)

---

**Ready to implement?** Start with battery optimization - it's the quickest win! 🔋
