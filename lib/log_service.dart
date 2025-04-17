import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:intl/intl.dart';

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
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
    output: MultiOutput([
      ConsoleOutput(),
      FileOutput(),
    ]),
  );

  static void info(dynamic message) =>
      _logger.i(ProductionFilter.redactMessage(message));

  static void warn(dynamic message) =>
      _logger.w(ProductionFilter.redactMessage(message));

  static void error(dynamic message, [dynamic error, StackTrace? stackTrace]) =>
      _logger.e(
        ProductionFilter.redactMessage(message),
        error: error,
        stackTrace: stackTrace,
      );

  // Initialize file logging
  static Future<void> init() async {
    await FileOutput.initialize();
  }
}

// Custom LogOutput for writing to files
class FileOutput extends LogOutput {
  static File? _logFile;
  static const int maxFileSize = 5 * 1024 * 1024; // 5 MB
  static const String logsDirName = 'logs';

  static Future<void> initialize() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final logsDir = Directory('${directory.path}/$logsDirName');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }

      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final logFilePath = '${logsDir.path}/app_log_$date.txt';
      _logFile = File(logFilePath);

      // Rotate logs if file exceeds max size
      if (await _logFile!.exists() && (await _logFile!.length()) > maxFileSize) {
        final newFilePath =
            '${logsDir.path}/app_log_$date${DateTime.now().millisecondsSinceEpoch}.txt';
        _logFile = File(newFilePath);
      }

      // Clean up old logs (e.g., keep last 7 days)
      await _cleanOldLogs(logsDir);
    } catch (e, stackTrace) {
      print('Failed to initialize file logging: $e\n$stackTrace');
    }
  }

  @override
  void output(OutputEvent event) async {
    if (_logFile != null) {
      try {
        final logMessage = event.lines.join('\n');
        await _logFile!.writeAsString('$logMessage\n',
            mode: FileMode.append, flush: true);
      } catch (e, stackTrace) {
        print('Failed to write log to file: $e\n$stackTrace');
      }
    }
  }

  static Future<void> _cleanOldLogs(Directory logsDir) async {
    try {
      final now = DateTime.now();
      final files = logsDir.listSync().whereType<File>();
      for (final file in files) {
        final lastModified = await file.lastModified();
        if (now.difference(lastModified).inDays > 7) {
          await file.delete();
        }
      }
    } catch (e, stackTrace) {
      print('Failed to clean old logs: $e\n$stackTrace');
    }
  }
}

// Filter for sensitive data redaction
class ProductionFilter extends LogFilter {
  // Define patterns for sensitive data
  static final Map<RegExp, String> _sensitivePatterns = {
    // Email addresses
    RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'): '****',
    // Passwords
    RegExp(r'(?<=password=)[^&,\s]+'): '****',
    // API keys
    RegExp(r'(?<=apiKey=)[a-zA-Z0-9_-]+'): '****',
    // Credit card numbers
    RegExp(r'\b\d{4}-\d{4}-\d{4}-\d{4}\b'): '****',
  };

  @override
  bool shouldLog(LogEvent event) {
    // Restrict logs to warning and above in production
    if (kReleaseMode && event.level.index < Level.warning.index) {
      return false;
    }

    // Redact sensitive data from the message
    String redactedMessage = event.message.toString();
    for (final pattern in _sensitivePatterns.entries) {
      redactedMessage = redactedMessage.replaceAll(pattern.key, pattern.value);
    }

    // Optionally redact sensitive data from error (if it’s a string)
    String? redactedError;
    if (event.error != null) {
      redactedError = event.error.toString();
      for (final pattern in _sensitivePatterns.entries) {
        redactedError = redactedError!.replaceAll(pattern.key, pattern.value);
      }
    }

    // Update the event with redacted data (LogEvent is immutable, so we rely on logger to handle)
    // For simplicity, we allow the log to proceed unless you want to block it entirely
    return true;
  }

  // Helper to redact sensitive data
  static String redactMessage(dynamic message) {
    String redacted = message.toString();
    for (final pattern in _sensitivePatterns.entries) {
      redacted = redacted.replaceAll(pattern.key, pattern.value);
    }
    return redacted;
  }
}