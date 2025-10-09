// Notification service for handling all app notifications
// Uses dependency injection to support different notification handlers
// Supports foreground notifications now, background service later

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import '../../data/repositories/preferences_repository.dart';
import '../../domain/entities/message.dart';
import '../../domain/interfaces/i_notification_handler.dart';

/// Foreground notification handler (current implementation)
/// Uses HapticFeedback and SystemSound for immediate feedback
class ForegroundNotificationHandler implements INotificationHandler {
  static final _logger = Logger('ForegroundNotificationHandler');
  bool _isInitialized = false;
  
  @override
  Future<void> initialize() async {
    if (_isInitialized) {
      _logger.fine('Already initialized');
      return;
    }
    
    _logger.info('Initializing foreground notification handler');
    _isInitialized = true;
    _logger.info('✅ Foreground notification handler initialized');
  }
  
  @override
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
  }) async {
    try {
      _logger.info('Showing notification: $title - $body');
      
      if (playSound) await _playSound();
      if (vibrate) await _vibrate();
      
      // In future: Show actual visual notification
      // This is where flutter_local_notifications would be integrated
      
    } catch (e) {
      _logger.warning('Failed to show notification: $e');
    }
  }
  
  @override
  Future<void> showMessageNotification({
    required Message message,
    required String contactName,
    String? contactAvatar,
    String? contactPublicKey,
  }) async {
    await showNotification(
      id: 'msg_${message.id}',
      title: contactName,
      body: message.content,
      channel: NotificationChannel.messages,
      priority: NotificationPriority.high,
      payload: message.chatId,
    );
  }
  
  @override
  Future<void> showContactRequestNotification({
    required String contactName,
    required String publicKey,
  }) async {
    await showNotification(
      id: 'contact_$publicKey',
      title: 'New Contact Request',
      body: '$contactName wants to connect',
      channel: NotificationChannel.contacts,
      priority: NotificationPriority.high,
      payload: publicKey,
    );
  }
  
  @override
  Future<void> showSystemNotification({
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.default_,
  }) async {
    await showNotification(
      id: 'system_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      body: message,
      channel: NotificationChannel.system,
      priority: priority,
    );
  }
  
  @override
  Future<void> cancelNotification(String id) async {
    _logger.fine('Cancel notification: $id');
    // Future implementation
  }
  
  @override
  Future<void> cancelAllNotifications() async {
    _logger.info('Cancelling all notifications');
    // Future implementation
  }
  
  @override
  Future<void> cancelChannelNotifications(NotificationChannel channel) async {
    _logger.fine('Cancel notifications for channel: ${channel.name}');
    // Future implementation
  }
  
  @override
  Future<bool> areNotificationsEnabled() async {
    final prefs = PreferencesRepository();
    return await prefs.getBool(PreferenceKeys.notificationsEnabled);
  }
  
  @override
  Future<bool> requestPermissions() async {
    // For foreground notifications, assume granted
    return true;
  }
  
  @override
  void dispose() {
    _logger.info('Disposing foreground notification handler');
    _isInitialized = false;
  }
  
  // Private helper methods
  Future<void> _playSound() async {
    try {
      final prefs = PreferencesRepository();
      final soundEnabled = await prefs.getBool(PreferenceKeys.soundEnabled);
      
      if (!soundEnabled) return;
      
      await SystemSound.play(SystemSoundType.alert);
      _logger.fine('Sound played');
    } catch (e) {
      _logger.warning('Failed to play sound: $e');
    }
  }
  
  Future<void> _vibrate() async {
    try {
      final prefs = PreferencesRepository();
      final vibrationEnabled = await prefs.getBool(
        PreferenceKeys.vibrationEnabled,
      );
      
      if (!vibrationEnabled) return;
      
      await HapticFeedback.mediumImpact();
      _logger.fine('Vibration triggered');
    } catch (e) {
      _logger.warning('Failed to vibrate: $e');
    }
  }
}

/// Main notification service with dependency injection
/// Singleton pattern with pluggable notification handler
class NotificationService {
  static final _logger = Logger('NotificationService');
  
  // Dependency injection - can swap handlers at runtime
  static INotificationHandler? _handler;
  static bool _isInitialized = false;
  
  /// Initialize with a specific handler (defaults to foreground)
  /// For Android background service: inject BackgroundNotificationHandler
  static Future<void> initialize({
    INotificationHandler? handler,
  }) async {
    if (_isInitialized) {
      _logger.fine('Notification service already initialized');
      return;
    }
    
    try {
      _logger.info('Initializing notification service...');
      
      // Use provided handler or create default foreground handler
      _handler = handler ?? ForegroundNotificationHandler();
      await _handler!.initialize();
      
      _isInitialized = true;
      _logger.info('✅ Notification service initialized with ${_handler.runtimeType}');
    } catch (e) {
      _logger.severe('Failed to initialize notification service: $e');
      rethrow;
    }
  }
  
  /// Get current handler (for testing/debugging)
  static INotificationHandler? get handler => _handler;
  
  /// Check if initialized
  static bool get isInitialized => _isInitialized;
  
  // Convenience methods that delegate to handler
  
  /// Show notification for new message
  static Future<void> showMessageNotification({
    required Message message,
    required String contactName,
    String? contactAvatar,
  }) async {
    if (!_isInitialized || _handler == null) {
      _logger.warning('Service not initialized, cannot show notification');
      return;
    }
    
    try {
      // Check if notifications are enabled
      final enabled = await _handler!.areNotificationsEnabled();
      if (!enabled) {
        _logger.fine('Notifications disabled, skipping');
        return;
      }
      
      await _handler!.showMessageNotification(
        message: message,
        contactName: contactName,
        contactAvatar: contactAvatar,
      );
      
      _logger.info('✅ Notification shown for message from $contactName');
    } catch (e) {
      _logger.warning('Failed to show message notification: $e');
    }
  }
  
  /// Show notification for new chat
  static Future<void> showChatNotification({
    required String contactName,
    required String message,
  }) async {
    if (!_isInitialized || _handler == null) return;
    
    try {
      final enabled = await _handler!.areNotificationsEnabled();
      if (!enabled) return;
      
      await _handler!.showNotification(
        id: 'chat_${DateTime.now().millisecondsSinceEpoch}',
        title: 'New Chat',
        body: '$contactName: $message',
        channel: NotificationChannel.messages,
      );
      
      _logger.info('Chat notification shown for $contactName');
    } catch (e) {
      _logger.warning('Failed to show chat notification: $e');
    }
  }
  
  /// Show notification for contact request
  static Future<void> showContactRequestNotification({
    required String contactName,
    required String publicKey,
  }) async {
    if (!_isInitialized || _handler == null) return;
    
    try {
      final enabled = await _handler!.areNotificationsEnabled();
      if (!enabled) return;
      
      await _handler!.showContactRequestNotification(
        contactName: contactName,
        publicKey: publicKey,
      );
      
      _logger.info('Contact request notification shown for $contactName');
    } catch (e) {
      _logger.warning('Failed to show contact request notification: $e');
    }
  }
  
  /// Show system notification
  static Future<void> showSystemNotification({
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.default_,
  }) async {
    if (!_isInitialized || _handler == null) return;
    
    try {
      await _handler!.showSystemNotification(
        title: title,
        message: message,
        priority: priority,
      );
      
      _logger.info('System notification shown: $title');
    } catch (e) {
      _logger.warning('Failed to show system notification: $e');
    }
  }
  
  /// Test notification (for settings/debugging)
  static Future<void> showTestNotification({
    String title = 'Test Notification',
    String body = 'This is a test notification from PakConnect',
    bool playSound = true,
    bool vibrate = true,
  }) async {
    if (!_isInitialized || _handler == null) {
      _logger.warning('Service not initialized');
      return;
    }
    
    try {
      _logger.info('Showing test notification');
      
      await _handler!.showNotification(
        id: 'test_${DateTime.now().millisecondsSinceEpoch}',
        title: title,
        body: body,
        channel: NotificationChannel.system,
        playSound: playSound,
        vibrate: vibrate,
      );
      
      _logger.info('✅ Test notification shown');
    } catch (e) {
      _logger.warning('Failed to show test notification: $e');
    }
  }
  
  /// Cancel all notifications
  static Future<void> cancelAllNotifications() async {
    if (_handler == null) return;
    
    try {
      await _handler!.cancelAllNotifications();
      _logger.info('All notifications cancelled');
    } catch (e) {
      _logger.warning('Failed to cancel notifications: $e');
    }
  }
  
  /// Cancel notification by ID
  static Future<void> cancelNotification(String id) async {
    if (_handler == null) return;
    await _handler!.cancelNotification(id);
  }
  
  /// Request notification permissions
  static Future<bool> requestPermissions() async {
    if (_handler == null) return false;
    
    try {
      _logger.info('Requesting notification permissions');
      final granted = await _handler!.requestPermissions();
      _logger.info('Permissions ${granted ? 'granted' : 'denied'}');
      return granted;
    } catch (e) {
      _logger.warning('Failed to request permissions: $e');
      return false;
    }
  }
  
  /// Check if notifications are enabled
  static Future<bool> hasPermission() async {
    if (_handler == null) return false;
    return await _handler!.areNotificationsEnabled();
  }
  
  /// Dispose notification service
  static void dispose() {
    _logger.info('Disposing notification service');
    _handler?.dispose();
    _handler = null;
    _isInitialized = false;
  }
  
  /// Swap handler at runtime (for testing or enabling background service)
  /// Example: NotificationService.swapHandler(BackgroundNotificationHandler())
  static Future<void> swapHandler(INotificationHandler newHandler) async {
    _logger.info('Swapping notification handler to ${newHandler.runtimeType}');
    
    // Dispose old handler
    _handler?.dispose();
    
    // Initialize new handler
    _handler = newHandler;
    await _handler!.initialize();
    
    _logger.info('✅ Handler swapped successfully');
  }
}
