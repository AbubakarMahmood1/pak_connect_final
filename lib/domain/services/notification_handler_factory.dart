// Platform-specific notification handler factory
// Safely creates the appropriate notification handler based on platform
// Avoids build issues on Windows/iOS by conditionally importing Android-only code

import 'dart:io' show Platform;
import 'package:logging/logging.dart';
import '../../domain/interfaces/i_notification_handler.dart';
import 'notification_service.dart'; // For ForegroundNotificationHandler

// Conditional import - only imports on Android, doesn't break build on other platforms
import 'background_notification_handler_impl.dart'
    if (dart.library.html) 'notification_service.dart'; // Web fallback

/// Factory for creating platform-appropriate notification handlers
/// 
/// PLATFORM SUPPORT:
/// - Android: BackgroundNotificationHandlerImpl (full system notifications)
/// - iOS: ForegroundNotificationHandler (future: UNUserNotificationCenter)
/// - Windows: ForegroundNotificationHandler (in-app only)
/// - Linux: ForegroundNotificationHandler (future: system notifications)
/// - macOS: ForegroundNotificationHandler (future: UNUserNotificationCenter)
/// - Web: ForegroundNotificationHandler (browser notifications)
/// 
/// USAGE:
/// ```dart
/// // Automatically selects best handler for platform
/// final handler = NotificationHandlerFactory.createDefault();
/// await handler.initialize();
/// 
/// // Or explicitly request background handler (Android only)
/// final bgHandler = NotificationHandlerFactory.createBackgroundHandler();
/// await bgHandler.initialize();
/// ```
class NotificationHandlerFactory {
  static final _logger = Logger('NotificationHandlerFactory');
  
  /// Create the default notification handler for current platform
  /// 
  /// Returns:
  /// - Android: ForegroundNotificationHandler (safe default)
  /// - Other platforms: ForegroundNotificationHandler
  static INotificationHandler createDefault() {
    _logger.info('Creating default notification handler for platform: ${_getPlatformName()}');
    
    // All platforms use foreground handler by default for safety
    return ForegroundNotificationHandler();
  }
  
  /// Create background notification handler if available on platform
  /// 
  /// Returns:
  /// - Android: BackgroundNotificationHandlerImpl (if enabled in settings)
  /// - Other platforms: ForegroundNotificationHandler (fallback)
  /// 
  /// This method is safe to call on all platforms - it won't cause build errors.
  static INotificationHandler createBackgroundHandler() {
    _logger.info('Creating background notification handler for platform: ${_getPlatformName()}');
    
    // Only Android has full background notification support
    if (Platform.isAndroid) {
      _logger.info('✅ Using BackgroundNotificationHandlerImpl for Android');
      return BackgroundNotificationHandlerImpl();
    }
    
    // iOS future implementation
    if (Platform.isIOS) {
      _logger.info('⚠️ iOS background notifications not yet implemented, using foreground handler');
      // Future: return IOSNotificationHandler();
      return ForegroundNotificationHandler();
    }
    
    // Windows - no background service support
    if (Platform.isWindows) {
      _logger.info('ℹ️ Windows uses foreground notifications only');
      return ForegroundNotificationHandler();
    }
    
    // Linux - could support libnotify in future
    if (Platform.isLinux) {
      _logger.info('⚠️ Linux system notifications not yet implemented, using foreground handler');
      // Future: return LinuxNotificationHandler();
      return ForegroundNotificationHandler();
    }
    
    // macOS - could use UNUserNotificationCenter
    if (Platform.isMacOS) {
      _logger.info('⚠️ macOS notifications not yet implemented, using foreground handler');
      // Future: return MacOSNotificationHandler();
      return ForegroundNotificationHandler();
    }
    
    // Fallback for unknown platforms
    _logger.warning('Unknown platform, using foreground notification handler');
    return ForegroundNotificationHandler();
  }
  
  /// Check if background notifications are supported on current platform
  static bool isBackgroundNotificationSupported() {
    return Platform.isAndroid; // Only Android for now
  }
  
  /// Get human-readable platform name
  static String _getPlatformName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isMacOS) return 'macOS';
    return 'Unknown';
  }
  
  /// Get platform capabilities description
  static String getPlatformCapabilities() {
    if (Platform.isAndroid) {
      return 'Full background notifications with system tray, sounds, and vibration';
    }
    if (Platform.isIOS) {
      return 'In-app notifications (system notifications coming soon)';
    }
    if (Platform.isWindows) {
      return 'In-app notifications only';
    }
    if (Platform.isLinux) {
      return 'In-app notifications (system notifications coming soon)';
    }
    if (Platform.isMacOS) {
      return 'In-app notifications (system notifications coming soon)';
    }
    return 'In-app notifications only';
  }
}
