# Quick Start Guide - Background Notifications

This guide shows you how to use the newly implemented background notification system.

## 🚀 Quick Integration

### 1. Import the Handler

```dart
import 'package:pak_connect/domain/services/background_notification_handler_impl.dart';
import 'package:pak_connect/domain/interfaces/i_notification_handler.dart';
```

### 2. Initialize in Your App

Add this to your app initialization (e.g., `lib/core/app_core.dart` or `lib/main.dart`):

```dart
// Create and initialize the notification handler
final INotificationHandler notificationHandler = BackgroundNotificationHandlerImpl();
await notificationHandler.initialize();

// Request permissions (important for Android 13+ and iOS)
final permissionsGranted = await notificationHandler.requestPermissions();

if (!permissionsGranted) {
  // Show user a dialog explaining why notifications are needed
  print('⚠️ Notification permissions denied');
} else {
  print('✅ Notification permissions granted');
}
```

### 3. Show Notifications

#### Message Notification (Most Common):
```dart
import 'package:pak_connect/domain/entities/message.dart';

// When you receive a new message
await notificationHandler.showMessageNotification(
  message: receivedMessage,  // Your Message entity
  contactName: 'Ali Arshad',
  contactAvatar: null,  // Optional: path to contact's avatar
);
```

#### Contact Request Notification:
```dart
// When someone wants to connect
await notificationHandler.showContactRequestNotification(
  contactName: 'New Contact',
  publicKey: contactPublicKey,
);
```

#### System Notification:
```dart
// For app updates, warnings, etc.
await notificationHandler.showSystemNotification(
  title: 'App Update',
  message: 'PakConnect has been updated to version 2.0',
  priority: NotificationPriority.default_,
);
```

#### Generic Notification:
```dart
// For custom notifications
await notificationHandler.showNotification(
  id: 'unique_id',
  title: 'Title',
  body: 'Message body',
  channel: NotificationChannel.messages,
  priority: NotificationPriority.high,
  payload: 'optional_data_for_navigation',
  playSound: true,
  vibrate: true,
);
```

### 4. Manage Notifications

#### Cancel a Specific Notification:
```dart
await notificationHandler.cancelNotification('notification_id');
```

#### Cancel All Notifications:
```dart
await notificationHandler.cancelAllNotifications();
```

#### Check if Notifications Are Enabled:
```dart
final enabled = await notificationHandler.areNotificationsEnabled();
if (!enabled) {
  // Guide user to enable notifications in settings
}
```

---

## 🔔 Notification Channels

The system uses 5 different channels (Android 8.0+):

| Channel | ID | When to Use | Priority | Sound | Vibrate |
|---------|----|----|----------|-------|---------|
| **Messages** | `messages` | New chat messages | High | ✅ | ✅ |
| **Contacts** | `contacts` | Contact requests | High | ✅ | ✅ |
| **System** | `system` | App updates, warnings | Default | ✅ | ❌ |
| **Mesh Relay** | `mesh_relay` | Message relay status | Low | ❌ | ❌ |
| **Archive Status** | `archive_status` | Export/import progress | Low | ❌ | ❌ |

Users can customize each channel's behavior in Android system settings.

---

## 🎨 Priority Levels

```dart
enum NotificationPriority {
  low,      // Silent, minimal interruption
  default_, // Normal priority
  high,     // Important, with sound/vibration
  max,      // Urgent, heads-up display
}
```

**Use `high` or `max` for:**
- New messages from contacts
- Contact requests
- Critical system alerts

**Use `default_` for:**
- System information
- Non-urgent updates

**Use `low` for:**
- Background operations
- Status updates

---

## 🛠️ Integration Examples

### Example 1: In BLE Message Receiver

```dart
// lib/domain/services/ble_service.dart

class BLEService {
  final INotificationHandler _notificationHandler;
  
  BLEService({required INotificationHandler notificationHandler})
    : _notificationHandler = notificationHandler;
  
  void _onMessageReceived(Message message, Contact sender) async {
    // Save message to database
    await _messageRepository.insert(message);
    
    // Show notification
    await _notificationHandler.showMessageNotification(
      message: message,
      contactName: sender.name,
    );
  }
}
```

### Example 2: In Settings Screen

```dart
// lib/presentation/screens/settings_screen.dart

class SettingsScreen extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          SwitchListTile(
            title: Text('Enable Notifications'),
            subtitle: Text('Receive message notifications'),
            value: _notificationsEnabled,
            onChanged: (value) async {
              if (value) {
                final granted = await notificationHandler.requestPermissions();
                setState(() => _notificationsEnabled = granted);
              } else {
                setState(() => _notificationsEnabled = false);
              }
            },
          ),
          
          ListTile(
            title: Text('Test Notification'),
            subtitle: Text('Send a test notification'),
            trailing: Icon(Icons.notification_add),
            onTap: () async {
              await notificationHandler.showNotification(
                id: 'test',
                title: 'Test Notification',
                body: 'This is a test',
                channel: NotificationChannel.system,
                priority: NotificationPriority.high,
              );
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Test notification sent!')),
              );
            },
          ),
        ],
      ),
    );
  }
}
```

### Example 3: With Dependency Injection

```dart
// lib/core/app_core.dart

class AppCore {
  static INotificationHandler? _notificationHandler;
  
  static Future<void> initialize() async {
    // Create handler
    _notificationHandler = BackgroundNotificationHandlerImpl();
    await _notificationHandler!.initialize();
    
    // Request permissions
    await _notificationHandler!.requestPermissions();
  }
  
  static INotificationHandler get notifications {
    if (_notificationHandler == null) {
      throw StateError('AppCore not initialized. Call AppCore.initialize() first.');
    }
    return _notificationHandler!;
  }
}

// In main.dart:
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppCore.initialize();
  runApp(MyApp());
}

// Anywhere in your app:
await AppCore.notifications.showMessageNotification(...);
```

---

## ⚙️ Android-Specific Notes

### Permissions (Android 13+)

On Android 13 (API 33) and higher, you **must** request notification permission at runtime:

```dart
final granted = await notificationHandler.requestPermissions();
```

The system will show this dialog:
```
"PakConnect wants to send you notifications"
[Don't allow]  [Allow]
```

### Notification Channels

Users can customize channels in:
**Settings → Apps → PakConnect → Notifications**

They can control:
- Sound
- Vibration
- Badge
- Importance level
- Do Not Disturb override

### Testing on Android

1. Run app: `flutter run`
2. Trigger a notification
3. Check notification tray
4. Tap notification (should open app)
5. Long-press notification to see channel
6. Go to Settings → check channel configuration

---

## 🍎 iOS-Specific Notes

### Permissions

iOS requires explicit permission before showing ANY notifications:

```dart
await notificationHandler.requestPermissions();
```

The system shows:
```
"PakConnect" Would Like to Send You Notifications
Notifications may include alerts, sounds, and icon badges.

[Don't Allow]  [Allow]
```

### Notification Center

Notifications appear in iOS Notification Center even when app is closed.

### Testing on iOS

1. Run on iOS device/simulator: `flutter run`
2. Grant notification permission
3. Trigger notification
4. Swipe down to see Notification Center
5. Tap notification

---

## 🔍 Troubleshooting

### Notifications Not Showing?

1. **Check permissions:**
   ```dart
   final enabled = await notificationHandler.areNotificationsEnabled();
   print('Notifications enabled: $enabled');
   ```

2. **Check initialization:**
   ```dart
   // Make sure you called initialize()
   await notificationHandler.initialize();
   ```

3. **Android: Check channel settings**
   - Go to Settings → Apps → PakConnect → Notifications
   - Ensure channel is not blocked

4. **iOS: Check system settings**
   - Settings → PakConnect → Notifications
   - Ensure "Allow Notifications" is ON

### Notifications Delayed?

- This is normal for background mode
- Android may batch notifications to save battery
- iOS controls notification delivery timing

### No Sound/Vibration?

- Check device is not in silent/DND mode
- Verify priority is `high` or `max`
- Check channel settings (Android)

---

## 📊 Best Practices

### 1. Request Permissions at Right Time

**❌ Bad:**
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await notificationHandler.requestPermissions(); // Too early!
  runApp(MyApp());
}
```

**✅ Good:**
```dart
// Request when user enables notifications in settings
// Or when they receive their first message
// Or after onboarding/tutorial
```

### 2. Use Appropriate Priority

**❌ Bad:**
```dart
// Archive export finished
await notificationHandler.showNotification(
  priority: NotificationPriority.max, // Too high for background operation!
  ...
);
```

**✅ Good:**
```dart
// Archive export finished
await notificationHandler.showNotification(
  priority: NotificationPriority.low, // Appropriate
  channel: NotificationChannel.archiveStatus,
  ...
);
```

### 3. Provide Context in Notifications

**❌ Bad:**
```dart
await notificationHandler.showNotification(
  title: 'New Message',
  body: 'You have a new message',  // Not helpful!
);
```

**✅ Good:**
```dart
await notificationHandler.showMessageNotification(
  message: message,
  contactName: 'Ali Arshad',  // User knows who sent it!
);
```

### 4. Clean Up Notifications

```dart
// When user opens chat, cancel notification for that chat
await notificationHandler.cancelNotification('msg_${chatId}');

// When user logs out, cancel all
await notificationHandler.cancelAllNotifications();
```

---

## 🎯 Testing Checklist

- [ ] App receives notifications when in foreground
- [ ] App receives notifications when in background
- [ ] App receives notifications when killed
- [ ] Tapping notification opens app
- [ ] Sound plays correctly
- [ ] Vibration works
- [ ] Different channels show different styles
- [ ] Permissions can be granted/denied
- [ ] Notifications can be cancelled
- [ ] Works on Android 8.0+
- [ ] Works on Android 13+ (runtime permission)
- [ ] Works on iOS 14+
- [ ] Channel settings work in Android system settings

---

## 📱 Platform Support Matrix

| Feature | Android 8+ | Android 13+ | iOS 14+ | Linux | macOS |
|---------|-----------|-------------|---------|-------|-------|
| Basic Notifications | ✅ | ✅ | ✅ | ✅ | ✅ |
| Notification Channels | ✅ | ✅ | ❌ | ❌ | ❌ |
| Messaging Style | ✅ | ✅ | ❌ | ❌ | ❌ |
| Runtime Permission | ❌ | ✅ | ✅ | ❌ | ✅ |
| Sound | ✅ | ✅ | ✅ | ✅ | ✅ |
| Vibration | ✅ | ✅ | ✅ | ❌ | ❌ |
| Badge Count | ✅ | ✅ | ✅ | ❌ | ✅ |

---

## 📚 Additional Resources

- **Implementation Details**: See `IMPLEMENTATION_COMPLETE_SUMMARY.md`
- **Original Requirements**: See `MULTI_DEVICE_FEATURES_EXPLAINED.md`
- **flutter_local_notifications Docs**: https://pub.dev/packages/flutter_local_notifications
- **Android Notification Guide**: https://developer.android.com/develop/ui/views/notifications
- **iOS Notification Guide**: https://developer.apple.com/documentation/usernotifications

---

**Happy Coding! 🚀**
