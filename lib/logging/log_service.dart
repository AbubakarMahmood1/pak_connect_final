import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:archive/archive.dart';

/// A comprehensive logging service for Flutter applications
///
/// Provides multiple log levels, file rotation, sensitive data redaction,
/// structured context logging, and log compression.
class LogService {
  static final Logger _logger = Logger(
    level: kReleaseMode ? Level.error : Level.debug,
    filter: ProductionFilter(),
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      // Using dateTimeFormat instead of deprecated printTime
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
      noBoxingByDefault: false,
    ),
    output: MultiOutput([
      ConsoleOutput(),
      FileOutput(),
    ]),
  );

  // Cached context that can be included with every log
  static Map<String, dynamic> _context = {};

  // Initialize file logging
  static Future<void> init({Map<String, dynamic>? initialContext}) async {
    await FileOutput.initialize();

    if (initialContext != null) {
      _context = {...initialContext};
    }

    // Log startup information
    info('LogService initialized', {
      'appMode': kReleaseMode ? 'release' : 'debug',
      'logLevel': kReleaseMode ? 'error' : 'debug',
    });
  }

  /// Set global context for all subsequent logs
  static void setContext(Map<String, dynamic> context) {
    _context = {..._context, ...context};
  }

  /// Clear all context or specific keys
  static void clearContext([List<String>? keys]) {
    if (keys == null) {
      _context = {};
    } else {
      for (final key in keys) {
        _context.remove(key);
      }
    }
  }

  /// Log at debug level
  static void debug(dynamic message, [Map<String, dynamic>? context]) {
    if (!kReleaseMode) {
      _logger.d(_formatMessage(message, context));
    }
  }

  /// Log at info level
  static void info(dynamic message, [Map<String, dynamic>? context]) {
    _logger.i(_formatMessage(message, context));
  }

  /// Log at warning level
  static void warn(dynamic message, [Map<String, dynamic>? context]) {
    _logger.w(_formatMessage(message, context));
  }

  /// Log at error level
  static void error(dynamic message, {dynamic error, StackTrace? stackTrace, Map<String, dynamic>? context}) {
    _logger.e(
      _formatMessage(message, context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Log at fatal level for critical errors
  static void fatal(dynamic message, {dynamic error, StackTrace? stackTrace, Map<String, dynamic>? context}) {
    _logger.f(
      _formatMessage(message, context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Format log message with context
  static dynamic _formatMessage(dynamic message, Map<String, dynamic>? additionalContext) {
    // For simple strings without context, just return the message
    if ((_context.isEmpty || kReleaseMode) && additionalContext == null) {
      return ProductionFilter.redactMessage(message);
    }

    // Create a structured log with context
    final logData = <String, dynamic>{
      'message': ProductionFilter.redactMessage(message.toString()),
      'timestamp': DateTime.now().toIso8601String(),
    };

    // Add persistent context
    if (_context.isNotEmpty) {
      logData['context'] = <String, dynamic>{..._context};
    }

    // Add call-specific context
    if (additionalContext != null) {
      if (logData.containsKey('context')) {
        final contextMap = logData['context'] as Map<String, dynamic>;
        contextMap.addAll(additionalContext);
      } else {
        logData['context'] = <String, dynamic>{...additionalContext};
      }
    }

    return kReleaseMode ? message : jsonEncode(logData);
  }

  /// Manually trigger log file rotation
  static Future<void> rotateLogFile() async {
    await FileOutput.rotateLogFile();
  }

  /// Get the path to the current log file
  static Future<String?> getCurrentLogFilePath() async {
    return FileOutput.getCurrentLogFilePath();
  }

  /// Get all available log files
  static Future<List<File>> getLogFiles() async {
    return FileOutput.getLogFiles();
  }

  /// Compress and archive old log files to save space
  static Future<void> compressOldLogs() async {
    await FileOutput.compressOldLogs();
  }
}

/// Custom LogOutput for writing to files with improved rotation
class FileOutput extends LogOutput {
  static File? _logFile;
  static const int maxFileSize = 5 * 1024 * 1024; // 5 MB
  static const String logsDirName = 'logs';
  static const String archiveDirName = 'archived_logs';
  static Directory? _logsDir;
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');
  static final DateFormat _timeFormat = DateFormat('HH-mm-ss');

  /// Initialize file logging system
  static Future<void> initialize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      _logsDir = Directory('${directory.path}/$logsDirName');
      if (!await _logsDir!.exists()) {
        await _logsDir!.create(recursive: true);
      }

      // Create archive directory if it doesn't exist
      final archiveDir = Directory('${directory.path}/$archiveDirName');
      if (!await archiveDir.exists()) {
        await archiveDir.create(recursive: true);
      }

      // Create or open log file
      await _createOrOpenLogFile();

      // Clean up old logs (keep last 7 days by default)
      await _cleanOldLogs(_logsDir!);
    } catch (e, stackTrace) {
      print('Failed to initialize file logging: $e\n$stackTrace');
    }
  }

  /// Create or open a log file
  static Future<void> _createOrOpenLogFile() async {
    final date = _dateFormat.format(DateTime.now());
    final logFilePath = '${_logsDir!.path}/app_log_$date.txt';

    _logFile = File(logFilePath);

    // Rotate logs if file exceeds max size
    if (await _logFile!.exists() && (await _logFile!.length()) > maxFileSize) {
      await rotateLogFile();
    }
  }

  /// Get the current log file path
  static Future<String?> getCurrentLogFilePath() async {
    if (_logFile != null && await _logFile!.exists()) {
      return _logFile!.path;
    }
    return null;
  }

  /// Get all available log files
  static Future<List<File>> getLogFiles() async {
    if (_logsDir == null || !await _logsDir!.exists()) {
      return [];
    }

    final List<File> logFiles = [];
    final entities = await _logsDir!.list().toList();

    for (final entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        logFiles.add(entity);
      }
    }

    // Sort by modification time (newest first)
    logFiles.sort((a, b) {
      // Using sync version for simplicity
      final aModified = a.lastModifiedSync();
      final bModified = b.lastModifiedSync();
      return bModified.compareTo(aModified);
    });

    return logFiles;
  }

  /// Manually rotate the log file
  static Future<void> rotateLogFile() async {
    if (_logFile == null || _logsDir == null) return;

    try {
      final date = _dateFormat.format(DateTime.now());
      final time = _timeFormat.format(DateTime.now());
      final newFilePath = '${_logsDir!.path}/app_log_${date}_$time.txt';

      // Create new log file
      _logFile = File(newFilePath);

      // Write rotation log entry to the new file
      await _logFile!.writeAsString('Log file rotated at ${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append, flush: true);
    } catch (e, stackTrace) {
      print('Failed to rotate log file: $e\n$stackTrace');
    }
  }

  /// Compress old log files to save space
  static Future<void> compressOldLogs() async {
    if (_logsDir == null) return;

    try {
      final now = DateTime.now();
      final directory = await getApplicationDocumentsDirectory();
      final archiveDir = Directory('${directory.path}/$archiveDirName');

      if (!await archiveDir.exists()) {
        await archiveDir.create(recursive: true);
      }

      final files = await _logsDir!.list().where((entity) =>
      entity is File &&
          entity.path.endsWith('.txt') &&
          !entity.path.contains(_logFile?.path ?? '')
      ).toList();

      for (final entity in files) {
        if (entity is File) {
          final stat = await entity.stat();

          // Compress files older than 2 days
          if (now.difference(stat.modified).inDays >= 2) {
            final fileName = entity.path.split('/').last;
            final gzipPath = '${archiveDir.path}/$fileName.gz';

            // Read the file content
            final content = await entity.readAsBytes();

            // Compress with gzip
            final gzipData = GZipEncoder().encode(content);

            // Write compressed file
            final gzipFile = File(gzipPath);
            await gzipFile.writeAsBytes(gzipData);

            // Delete original file
            await entity.delete();
          }
        }
      }
    } catch (e, stackTrace) {
      print('Failed to compress old logs: $e\n$stackTrace');
    }
  }

  /// Clean up old log files
  static Future<void> _cleanOldLogs(Directory logsDir) async {
    try {
      final now = DateTime.now();
      final directory = await getApplicationDocumentsDirectory();
      final archiveDir = Directory('${directory.path}/$archiveDirName');

      // Process regular log files - keep last 7 days
      if (await logsDir.exists()) {
        final files = logsDir.listSync().whereType<File>();
        for (final file in files) {
          final lastModified = file.lastModifiedSync();
          if (now.difference(lastModified).inDays > 7) {
            // Files older than 7 days should be compressed or deleted
            if (now.difference(lastModified).inDays > 30) {
              // Delete files older than 30 days
              await file.delete();
            } else {
              // Compress files between 7-30 days old
              await compressOldLogs();
            }
          }
        }
      }

      // Process archived files - keep last 90 days
      if (await archiveDir.exists()) {
        final archivedFiles = archiveDir.listSync().whereType<File>();
        for (final file in archivedFiles) {
          final lastModified = file.lastModifiedSync();
          if (now.difference(lastModified).inDays > 90) {
            await file.delete();
          }
        }
      }
    } catch (e, stackTrace) {
      print('Failed to clean old logs: $e\n$stackTrace');
    }
  }

  @override
  void output(OutputEvent event) async {
    if (_logFile != null) {
      try {
        // Add timestamp to log entries
        final timestamp = DateTime.now().toIso8601String();
        final logMessage = event.lines.join('\n');
        await _logFile!.writeAsString('[$timestamp] $logMessage\n',
            mode: FileMode.append, flush: true);

        // Check if rotation needed after write
        if (await _logFile!.length() > maxFileSize) {
          await rotateLogFile();
        }
      } catch (e, stackTrace) {
        print('Failed to write log to file: $e\n$stackTrace');
      }
    }
  }
}

/// Filter for sensitive data redaction with simplified patterns
class ProductionFilter extends LogFilter {
  // EMERGENCY FIX: Completely simplified sensitive patterns to fix compilation errors
  static final Map<RegExp, String> _sensitivePatterns = {
    // Basic email pattern (simplified)
    RegExp(r'\S+@\S+\.\S+'): '[EMAIL]',

    // Basic password pattern (simplified)
    RegExp(r'password.*'): '[PASSWORD]',

    // Basic credit card pattern (simplified)
    RegExp(r'\d{4}[\s-]?\d{4}'): '[CREDIT_CARD]',
  };

  @override
  bool shouldLog(LogEvent event) {
    // Restrict logs to warning and above in production
    if (kReleaseMode && event.level.index < Level.warning.index) {
      return false;
    }
    return true;
  }

  /// Helper to redact sensitive data
  static String redactMessage(dynamic message) {
    String redacted = message.toString();

    // Apply each redaction pattern
    for (final pattern in _sensitivePatterns.entries) {
      redacted = redacted.replaceAll(pattern.key, pattern.value);
    }

    return redacted;
  }
}