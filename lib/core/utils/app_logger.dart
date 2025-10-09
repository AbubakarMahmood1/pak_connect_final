import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Centralized logging utility for PakConnect
/// Provides production-ready logging with automatic level management
///
/// Usage:
/// ```dart
/// final _logger = AppLogger.getLogger('MyClassName');
/// _logger.info('Something happened');
/// _logger.warning('Warning message');
/// _logger.severe('Error: ${error}');
/// ```

/// Centralized logger factory with automatic configuration
class AppLogger {
  static bool _initialized = false;

  /// Initialize the logging system
  /// Call this once at app startup (already done in main.dart)
  static void initialize() {
    if (_initialized) return;

    // Set to INFO level in debug mode to reduce log spam, WARNING in release
    Logger.root.level = kReleaseMode ? Level.WARNING : Level.INFO;
    hierarchicalLoggingEnabled = true;

    Logger.root.onRecord.listen((record) {
      // In debug mode: use emoji-enhanced formatting
      if (kDebugMode) {
        final emoji = _getEmojiForLevel(record.level);
        // ignore: avoid_print
        print('$emoji [${record.loggerName}] ${record.message}');
        if (record.error != null) {
          // ignore: avoid_print
          print('  ↳ Error: ${record.error}');
        }
        if (record.stackTrace != null) {
          // ignore: avoid_print
          print('  ↳ Stack: ${record.stackTrace}');
        }
      } else {
        // In release mode: minimal, structured output
        // (could be sent to Crashlytics/Sentry here)
        if (record.level >= Level.WARNING) {
          // ignore: avoid_print
          print('[${record.level.name}] ${record.loggerName}: ${record.message}');
        }
      }
    });

    _initialized = true;
  }

  /// Get a logger instance for a specific module/class
  ///
  /// Best practice: create one static logger per class
  /// ```dart
  /// class MyService {
  ///   static final _logger = AppLogger.getLogger('MyService');
  /// }
  /// ```
  static Logger getLogger(String name) {
    if (!_initialized) {
      initialize();
    }
    return Logger(name);
  }

  /// Get emoji prefix for log level (debug mode only)
  static String _getEmojiForLevel(Level level) {
    if (level >= Level.SEVERE) return '❌';
    if (level >= Level.WARNING) return '⚠️';
    if (level >= Level.INFO) return 'ℹ️';
    if (level >= Level.CONFIG) return '⚙️';
    return '🔍'; // FINE, FINER, FINEST
  }

  /// Quick logging helpers for one-off logs
  static void debug(String message, {String tag = 'App'}) {
    getLogger(tag).fine(message);
  }

  static void info(String message, {String tag = 'App'}) {
    getLogger(tag).info(message);
  }

  static void warning(String message, {String tag = 'App'}) {
    getLogger(tag).warning(message);
  }

  static void error(String message, {Object? error, StackTrace? stackTrace, String tag = 'App'}) {
    getLogger(tag).severe(message, error, stackTrace);
  }
}

/// Extension for convenient logger creation
///
/// Usage:
/// ```dart
/// class MyClass {
///   final _logger = 'MyClass'.logger;
/// }
/// ```
extension LoggerExtension on String {
  Logger get logger => AppLogger.getLogger(this);
}

/// Common logger names for consistent naming across codebase
class LoggerNames {
  static const app = 'App';
  static const meshRelay = 'MeshRelay';
  static const meshRouter = 'MeshRouter';
  static const offlineQueue = 'OfflineQueue';
  static const security = 'Security';
  static const encryption = 'Security.Encryption';
  static const keyManagement = 'Security.KeyManagement';
  static const spamPrevention = 'Security.SpamPrevention';
  static const ble = 'BLE';
  static const bleService = 'BLE.Service';
  static const bleScanning = 'BLE.Scanning';
  static const bleConnection = 'BLE.Connection';
  static const chat = 'Chat';
  static const chatStorage = 'Chat.Storage';
  static const contact = 'Contact';
  static const ui = 'UI';
  static const power = 'Power';
  static const hintSystem = 'HintSystem';
}
