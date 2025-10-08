// Abstract notification handler interface
// Allows different implementations (foreground, background service, etc.)

import '../../domain/entities/message.dart';

/// Notification priority levels
enum NotificationPriority {
  low,      // Silent notifications
  default_, // Normal notifications
  high,     // Important notifications with sound/vibration
  max,      // Urgent notifications with heads-up display
}

/// Notification channel types
enum NotificationChannel {
  messages,        // Chat messages
  contacts,        // Contact requests
  system,          // System notifications
  meshRelay,       // Mesh relay notifications
  archiveStatus,   // Archive operation status
}

/// Abstract notification handler interface
/// Implement this for different notification strategies
abstract class INotificationHandler {
  /// Initialize the notification handler
  Future<void> initialize();
  
  /// Show a notification
  Future<void> showNotification({
    required String id,
    required String title,
    required String body,
    NotificationChannel channel = NotificationChannel.messages,
    NotificationPriority priority = NotificationPriority.default_,
    String? payload,
    Map<String, dynamic>? data,
    bool playSound = true,
    bool vibrate = true,
  });
  
  /// Show notification for a message
  Future<void> showMessageNotification({
    required Message message,
    required String contactName,
    String? contactAvatar,
  });
  
  /// Show notification for contact request
  Future<void> showContactRequestNotification({
    required String contactName,
    required String publicKey,
  });
  
  /// Show notification for system event
  Future<void> showSystemNotification({
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.default_,
  });
  
  /// Cancel a specific notification
  Future<void> cancelNotification(String id);
  
  /// Cancel all notifications
  Future<void> cancelAllNotifications();
  
  /// Cancel notifications for a specific channel
  Future<void> cancelChannelNotifications(NotificationChannel channel);
  
  /// Check if notifications are enabled
  Future<bool> areNotificationsEnabled();
  
  /// Request notification permissions
  Future<bool> requestPermissions();
  
  /// Dispose resources
  void dispose();
}

/// Notification configuration
class NotificationConfig {
  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool notificationsEnabled;
  final Map<NotificationChannel, bool> channelSettings;
  
  const NotificationConfig({
    required this.soundEnabled,
    required this.vibrationEnabled,
    required this.notificationsEnabled,
    this.channelSettings = const {},
  });
  
  /// Default configuration
  factory NotificationConfig.defaults() => const NotificationConfig(
    soundEnabled: true,
    vibrationEnabled: true,
    notificationsEnabled: true,
  );
  
  /// Create config from preferences
  static Future<NotificationConfig> fromPreferences() async {
    // Implementation will load from PreferencesRepository
    return NotificationConfig.defaults();
  }
}
