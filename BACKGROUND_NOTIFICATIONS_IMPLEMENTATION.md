# Background Notifications Implementation Guide

## Overview

PakConnect now supports **cross-platform safe** background notifications with platform-specific handlers that prevent build errors on Windows, iOS, Linux, and macOS.

## Architecture

### Platform Support Matrix

| Platform | Handler | Capabilities | Status |
|----------|---------|--------------|--------|
| **Android** | `BackgroundNotificationHandlerImpl` | Full system notifications, background service | ✅ Implemented |
| **iOS** | `ForegroundNotificationHandler` | In-app notifications | ⚠️ System notifications planned |
| **Windows** | `ForegroundNotificationHandler` | In-app only | ✅ Works (no pitfalls) |
| **Linux** | `ForegroundNotificationHandler` | In-app only | ⚠️ System notifications planned |
| **macOS** | `ForegroundNotificationHandler` | In-app only | ⚠️ System notifications planned |

### Dependency Injection Pattern

```dart
// Factory creates platform-appropriate handler
final handler = NotificationHandlerFactory.createBackgroundHandler();

// Service uses injected handler
await NotificationService.initialize(handler: handler);

// Can swap at runtime
await NotificationService.swapHandler(newHandler);
```

## How It Works

### 1. Notification Handler Factory

**File:** `lib/domain/services/notification_handler_factory.dart`

```dart
class NotificationHandlerFactory {
  // Creates default handler (safe on all platforms)
  static INotificationHandler createDefault();
  
  // Creates best available handler per platform
  static INotificationHandler createBackgroundHandler();
  
  // Check if background notifications supported
  static bool isBackgroundNotificationSupported();
}
```

**Platform Detection:**
- Uses `Platform.isAndroid`, `Platform.isIOS`, etc.
- Conditional imports prevent build errors
- Falls back to safe default on unsupported platforms

### 2. App Initialization

**File:** `lib/core/app_core.dart`

On app startup, the notification handler is selected based on:
1. Current platform (Android, iOS, Windows, etc.)
2. User preference (`background_notifications` setting)

```dart
// Check user preference
final prefs = PreferencesRepository();
final backgroundEnabled = await prefs.getBool(
  PreferenceKeys.backgroundNotifications
);

// Select handler
final handler = (backgroundEnabled && 
                 NotificationHandlerFactory.isBackgroundNotificationSupported())
    ? NotificationHandlerFactory.createBackgroundHandler()
    : NotificationHandlerFactory.createDefault();

await NotificationService.initialize(handler: handler);
```

### 3. Settings Screen Toggle

**File:** `lib/presentation/screens/settings_screen.dart`

**Android Only Toggle:**
```dart
// Only shows on Android
if (NotificationHandlerFactory.isBackgroundNotificationSupported()) {
  SwitchListTile(
    title: Text('System Notifications'),
    subtitle: Text('Show notifications even when app is closed (Android)'),
    value: _backgroundNotifications,
    onChanged: (value) async {
      // Save preference
      await _preferencesRepository.setBool(
        PreferenceKeys.backgroundNotifications, value
      );
      
      // Swap handler immediately
      await _swapNotificationHandler(value);
    },
  )
}
```

**Handler Swapping:**
```dart
Future<void> _swapNotificationHandler(bool enableBackground) async {
  final handler = enableBackground
      ? NotificationHandlerFactory.createBackgroundHandler()
      : NotificationHandlerFactory.createDefault();
  
  await NotificationService.swapHandler(handler);
}
```

## User Experience

### Android

**When "System Notifications" is ON:**
- ✅ Notifications show in system tray
- ✅ Works even when app is closed/killed
- ✅ Supports notification channels
- ✅ Plays sounds and vibration via system
- ✅ Can tap notification to open chat

**When "System Notifications" is OFF:**
- ✅ In-app notifications only
- ✅ Haptic feedback and system sounds
- ❌ No notifications when app is closed

### Windows, iOS, Linux, macOS

**Current State:**
- ✅ In-app notifications (foreground only)
- ✅ Haptic feedback
- ✅ System sounds
- ⚠️ Toggle hidden (not supported yet)
- ✅ **No build errors** - platform-safe code

**Future Enhancements:**
- iOS: UNUserNotificationCenter integration
- macOS: Native notification center
- Linux: libnotify support
- Windows: Toast notifications (Windows 10+)

## Implementation Details

### Background Notification Handler (Android)

**File:** `lib/domain/services/background_notification_handler_impl.dart`

**Features:**
- Uses `flutter_local_notifications` package
- Android notification channels (Messages, Contacts, System, etc.)
- Permission handling (Android 13+)
- Notification tap handling
- Sound and vibration support

**Initialization:**
```dart
final handler = BackgroundNotificationHandlerImpl();
await handler.initialize();
```

**Showing Notifications:**
```dart
await handler.showNotification(
  id: 'msg_123',
  title: 'John Doe',
  body: 'Hello, how are you?',
  channel: NotificationChannel.messages,
  priority: NotificationPriority.high,
);
```

### Foreground Notification Handler (All Platforms)

**File:** `lib/domain/services/notification_service.dart`

**Features:**
- Haptic feedback via `HapticFeedback.mediumImpact()`
- System sounds via `SystemSound.play(SystemSoundType.alert)`
- Respects user preferences for sound/vibration
- Works on all platforms (safe fallback)

## Configuration

### Preferences

**Keys:**
```dart
PreferenceKeys.notificationsEnabled      // Master toggle
PreferenceKeys.backgroundNotifications   // Android system notifications
PreferenceKeys.soundEnabled              // Sound on/off
PreferenceKeys.vibrationEnabled          // Vibration on/off
```

**Defaults:**
```dart
PreferenceDefaults.notificationsEnabled = true
PreferenceDefaults.backgroundNotifications = true  // Android only
PreferenceDefaults.soundEnabled = true
PreferenceDefaults.vibrationEnabled = true
```

### Android Build Configuration

**File:** `android/app/build.gradle.kts`

Required for `flutter_local_notifications`:
```kotlin
android {
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true  // Required!
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

## Testing

### Test on Android

```bash
# Build and run on Android device
flutter run

# Check console for:
# ✅ "Notification service initialized with BackgroundNotificationHandlerImpl"
# or
# ✅ "Notification service initialized with ForegroundNotificationHandler"

# Toggle "System Notifications" in Settings → Notifications
# Should see: "✅ System notifications enabled"
```

### Test on Windows/iOS

```bash
# Build and run on Windows
flutter run -d windows

# Should see:
# ✅ "Notification service initialized with ForegroundNotificationHandler"
# ✅ No "System Notifications" toggle in settings (Android only)
# ✅ No build errors!
```

### Verify Cross-Platform Safety

```bash
# Analyze code
flutter analyze

# Build for all platforms
flutter build apk     # Android
flutter build ios     # iOS (macOS host)
flutter build windows # Windows
flutter build linux   # Linux
flutter build macos   # macOS
```

## Error Handling

### Missing Permissions (Android 13+)

```dart
final granted = await NotificationService.requestPermissions();
if (!granted) {
  // Show explanation dialog
  // Guide user to system settings
}
```

### Handler Initialization Failure

```dart
try {
  await NotificationService.initialize(handler: handler);
} catch (e) {
  // Falls back to default handler
  await NotificationService.initialize();
}
```

## Future Enhancements

### iOS Support (Planned)

```dart
class IOSNotificationHandler implements INotificationHandler {
  // Use UNUserNotificationCenter
  // Support background notifications
  // Handle notification actions
}
```

### Windows Support (Planned)

```dart
class WindowsNotificationHandler implements INotificationHandler {
  // Use Windows Toast Notifications
  // Requires Windows 10+
}
```

### Linux Support (Planned)

```dart
class LinuxNotificationHandler implements INotificationHandler {
  // Use libnotify via FFI
  // System tray notifications
}
```

## Dependencies

### Current

```yaml
dependencies:
  flutter_local_notifications: ^19.4.2  # Cross-platform notifications
  permission_handler: ^12.0.1           # Runtime permissions
```

### Android-Specific

**AndroidManifest.xml** (auto-configured by plugin):
```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.VIBRATE"/>
```

## Best Practices

1. ✅ **Always use factory** - Don't instantiate handlers directly
2. ✅ **Check platform support** - Use `isBackgroundNotificationSupported()`
3. ✅ **Respect user preferences** - Check `notificationsEnabled` before showing
4. ✅ **Handle permission denial** - Guide users to settings
5. ✅ **Test on all platforms** - Ensure no build errors
6. ✅ **Dispose properly** - Call `dispose()` on handler swap

## Troubleshooting

### Build Error on Windows/iOS

**Problem:** Android-specific code breaks build

**Solution:** ✅ Already solved! Factory uses conditional imports
```dart
import 'background_notification_handler_impl.dart'
    if (dart.library.html) 'notification_service.dart';
```

### Notifications Not Showing on Android

**Check:**
1. Is "Enable Notifications" turned ON?
2. Is "System Notifications" turned ON? (Android only)
3. Are app notifications enabled in system settings?
4. Did app request POST_NOTIFICATIONS permission? (Android 13+)

### Toggle Not Visible

**Expected Behavior:**
- Android: "System Notifications" toggle visible
- Other platforms: Toggle hidden (not supported)

**Verification:**
```dart
NotificationHandlerFactory.isBackgroundNotificationSupported()
// Returns: true on Android, false elsewhere
```

## Summary

✅ **Cross-platform safe** - No build errors on any platform  
✅ **Android background notifications** - Full system integration  
✅ **Dependency injection** - Clean, testable architecture  
✅ **User-controlled** - Settings toggle for Android  
✅ **Runtime swapping** - Change handlers without restart  
✅ **Future-proof** - Easy to add iOS/Windows/Linux support  

The implementation follows your requirements perfectly:
- No pitfalls on Windows/iOS/Linux
- Only Android gets background service
- Other platforms use safe foreground handler
- Clean dependency injection pattern
