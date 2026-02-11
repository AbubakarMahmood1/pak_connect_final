import 'dart:math' as math;

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
  static const String _logLevelEnv = 'PAKCONNECT_LOG_LEVEL';
  static const String _redacted = '<redacted>';

  static const List<String> _keyContextHints = [
    'public key',
    'private key',
    'persistent',
    'ephemeral',
    'noise key',
    'noise session',
    'noise public key',
    'session key',
    'session id',
    'fingerprint',
    'identity',
    ' peer key',
    ' key ',
    'key=',
    'pubkey',
  ];

  static final List<RegExp> _labeledSecretPatterns = <RegExp>[
    RegExp(
      r'\b(public\s*key|private\s*key|persistent\s*public\s*key|current\s*ephemeral(?:\s*id)?|ephemeral(?:\s*(?:id|key|session(?:\s*key)?|signing(?:\s*key)?))|noise(?:\s*(?:public|static)?\s*key)?|noise\s*session|session\s*id(?:\s*for\s*noise)?|pubkey|identity\s*fingerprint|fingerprint)\b\s*[:=]\s*([^\s|,;]+)',
      caseSensitive: false,
    ),
  ];

  static final RegExp _candidateTokenPattern = RegExp(
    r'[A-Za-z0-9+/_=-]{8,}\.\.\.|[A-Fa-f0-9]{24,}|[A-Za-z0-9+/_=-]{32,}',
  );

  static Level _resolveRootLevel() {
    final configured = _parseLevel(
      const String.fromEnvironment(_logLevelEnv, defaultValue: ''),
    );
    if (configured != null) return configured;

    if (kReleaseMode || kProfileMode) {
      return Level.INFO;
    }
    return Level.INFO;
  }

  static Level? _parseLevel(String raw) {
    final normalized = raw.trim().toUpperCase();
    if (normalized.isEmpty) return null;

    switch (normalized) {
      case 'OFF':
        return Level.OFF;
      case 'SHOUT':
        return Level.SHOUT;
      case 'SEVERE':
        return Level.SEVERE;
      case 'WARNING':
      case 'WARN':
        return Level.WARNING;
      case 'INFO':
        return Level.INFO;
      case 'CONFIG':
        return Level.CONFIG;
      case 'FINE':
        return Level.FINE;
      case 'FINER':
        return Level.FINER;
      case 'FINEST':
      case 'DEBUG':
        return Level.FINEST;
      case 'ALL':
      case 'TRACE':
        return Level.ALL;
      default:
        return null;
    }
  }

  /// Initialize the logging system
  /// Call this once at app startup (already done in main.dart)
  static void initialize() {
    if (_initialized) return;

    Logger.root.level = _resolveRootLevel();
    hierarchicalLoggingEnabled = true;

    Logger.root.onRecord.listen((record) {
      final releaseSafeMode = kReleaseMode || kProfileMode;
      final message = sanitizeForOutput(
        record.message,
        releaseMode: releaseSafeMode,
      );

      // In debug mode: use emoji-enhanced formatting
      if (kDebugMode) {
        final emoji = _getEmojiForLevel(record.level);
        debugPrint(
          '$emoji [${record.loggerName}] ${record.level.name} $message',
        );
        if (record.error != null) {
          debugPrint('  ↳ Error: ${record.error}');
        }
        if (record.stackTrace != null) {
          debugPrint('  ↳ Stack: ${record.stackTrace}');
        }
      } else {
        // In release/profile mode: structured output with sanitized payload.
        final line =
            '[${record.level.name}] ${record.loggerName} ${record.time.toIso8601String()} $message';
        debugPrint(line);
      }
    });

    _initialized = true;
  }

  /// Build structured event log lines with optional message id and duration.
  static String event({
    required String type,
    String? messageId,
    Duration? duration,
    Map<String, Object?> fields = const {},
  }) {
    final out = StringBuffer('event=$type');

    if (messageId != null && messageId.isNotEmpty) {
      out.write(' messageId=${_sanitizeField(messageId)}');
    }
    if (duration != null) {
      out.write(' durationMs=${duration.inMilliseconds}');
    }

    fields.forEach((key, value) {
      if (value == null) return;
      out.write(' ${_sanitizeField(key)}=${_sanitizeField(value.toString())}');
    });

    return out.toString();
  }

  @visibleForTesting
  static String sanitizeForOutput(String message, {required bool releaseMode}) {
    var sanitized = message;

    if (releaseMode) {
      sanitized = _stripNonAscii(sanitized);
      sanitized = _normalizeSensitiveFallbackPhrases(sanitized);
      sanitized = _redactLabeledSecrets(sanitized);
      sanitized = _redactContextualTokens(sanitized);
      sanitized = sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return sanitized;
  }

  static String _sanitizeField(String input) {
    return input.replaceAll(RegExp(r'\s+'), '_');
  }

  static String _stripNonAscii(String input) {
    return input.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  }

  static String _normalizeSensitiveFallbackPhrases(String input) {
    var normalized = input;
    normalized = normalized.replaceAllMapped(
      RegExp(r'encryption skipped \([^)]*\)', caseSensitive: false),
      (_) => 'event=encryption_unavailable',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(
        r'database file is plaintext sqlite \(not encrypted\)',
        caseSensitive: false,
      ),
      (_) => 'event=database_plaintext_detected',
    );
    return normalized;
  }

  static String _redactLabeledSecrets(String input) {
    var redacted = input;
    for (final pattern in _labeledSecretPatterns) {
      redacted = redacted.replaceAllMapped(pattern, (match) {
        final label = match.group(1) ?? 'key';
        return '$label=$_redacted';
      });
    }
    return redacted;
  }

  static String _redactContextualTokens(String input) {
    return input.replaceAllMapped(_candidateTokenPattern, (match) {
      final start = match.start;
      final prefixStart = math.max(0, start - 56);
      final context = input.substring(prefixStart, start).toLowerCase();
      final nearStart = math.max(0, start - 24);
      final nearContext = input.substring(nearStart, start).toLowerCase();
      final keyContext = _keyContextHints.any(context.contains);
      final explicitMessageIdContext =
          nearContext.contains('messageid=') ||
          nearContext.contains('message id=') ||
          nearContext.contains('msgid=');
      final messageContext = explicitMessageIdContext;

      if (keyContext && !messageContext) {
        return _redacted;
      }
      return match.group(0) ?? _redacted;
    });
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

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String tag = 'App',
  }) {
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
