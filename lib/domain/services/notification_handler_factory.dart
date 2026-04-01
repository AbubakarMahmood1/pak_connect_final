// Platform-specific notification handler factory
// Safely creates the appropriate notification handler based on platform
// Avoids build issues on Windows/iOS by conditionally importing Android-only code

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../../domain/interfaces/i_notification_handler.dart';
import '../../domain/interfaces/i_preferences_repository.dart';
import 'notification_service.dart'; // For ForegroundNotificationHandler

import 'background_notification_handler_factory_stub.dart'
    if (dart.library.io) 'background_notification_handler_factory_native.dart'
    as background_handler;

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
/// final handler = NotificationHandlerFactory.createDefault(
///   preferencesRepository: prefsRepo,
/// );
/// await handler.initialize();
///
/// // Or explicitly request background handler (Android only)
/// final bgHandler = NotificationHandlerFactory.createBackgroundHandler(
///   preferencesRepository: prefsRepo,
/// );
/// await bgHandler.initialize();
/// ```
class NotificationHandlerFactory {
  static final _logger = Logger('NotificationHandlerFactory');

  /// Create the default notification handler for current platform
  ///
  /// Returns:
  /// - Android: ForegroundNotificationHandler (safe default)
  /// - Other platforms: ForegroundNotificationHandler
  static INotificationHandler createDefault({
    required IPreferencesRepository preferencesRepository,
  }) {
    _logger.info(
      'Creating default notification handler for platform: ${_getPlatformName()}',
    );

    // All platforms use foreground handler by default for safety
    return ForegroundNotificationHandler(
      preferencesRepository: preferencesRepository,
    );
  }

  /// Create background notification handler if available on platform
  ///
  /// Returns:
  /// - Android: BackgroundNotificationHandlerImpl (if enabled in settings)
  /// - Other platforms: ForegroundNotificationHandler (fallback)
  ///
  /// This method is safe to call on all platforms - it won't cause build errors.
  static INotificationHandler createBackgroundHandler({
    required IPreferencesRepository preferencesRepository,
  }) {
    _logger.info(
      'Creating background notification handler for platform: ${_getPlatformName()}',
    );

    if (kIsWeb) {
      _logger.info('ℹ️ Web uses foreground notifications only');
      return ForegroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // Only Android has full background notification support
    if (defaultTargetPlatform == TargetPlatform.android) {
      _logger.info('✅ Using BackgroundNotificationHandlerImpl for Android');
      return background_handler.createPlatformBackgroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // iOS future implementation
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _logger.info(
        '⚠️ iOS background notifications not yet implemented, using foreground handler',
      );
      // Future: return IOSNotificationHandler();
      return ForegroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // Windows - no background service support
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _logger.info('ℹ️ Windows uses foreground notifications only');
      return ForegroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // Linux - could support libnotify in future
    if (defaultTargetPlatform == TargetPlatform.linux) {
      _logger.info(
        '⚠️ Linux system notifications not yet implemented, using foreground handler',
      );
      // Future: return LinuxNotificationHandler();
      return ForegroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // macOS - could use UNUserNotificationCenter
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _logger.info(
        '⚠️ macOS notifications not yet implemented, using foreground handler',
      );
      // Future: return MacOSNotificationHandler();
      return ForegroundNotificationHandler(
        preferencesRepository: preferencesRepository,
      );
    }

    // Fallback for unknown platforms
    _logger.warning('Unknown platform, using foreground notification handler');
    return ForegroundNotificationHandler(
      preferencesRepository: preferencesRepository,
    );
  }

  /// Check if background notifications are supported on current platform
  static bool isBackgroundNotificationSupported() {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  }

  /// Get human-readable platform name
  static String _getPlatformName() {
    if (kIsWeb) return 'Web';
    if (defaultTargetPlatform == TargetPlatform.android) return 'Android';
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'iOS';
    if (defaultTargetPlatform == TargetPlatform.windows) return 'Windows';
    if (defaultTargetPlatform == TargetPlatform.linux) return 'Linux';
    if (defaultTargetPlatform == TargetPlatform.macOS) return 'macOS';
    return 'Unknown';
  }

  /// Get platform capabilities description
  static String getPlatformCapabilities() {
    if (kIsWeb) {
      return 'Browser/in-app notifications only';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'Full background notifications with system tray, sounds, and vibration';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return 'In-app notifications (system notifications coming soon)';
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return 'In-app notifications only';
    }
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return 'In-app notifications (system notifications coming soon)';
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return 'In-app notifications (system notifications coming soon)';
    }
    return 'In-app notifications only';
  }
}
