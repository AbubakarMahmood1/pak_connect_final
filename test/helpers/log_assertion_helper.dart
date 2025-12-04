import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

/// Reusable helper for capturing and asserting on log messages in tests.
///
/// This helper ensures that tests fail on unexpected SEVERE errors while
/// allowing intentional error-path testing via an allowlist pattern.
///
/// **Usage:**
/// ```dart
/// void main() {
///   group('MyTests', () {
///     late List<LogRecord> logRecords;
///     late Set<Pattern> allowedSevere;
///
///     late LogAssertionHelper helper;
///
///     setUp(() {
///       helper = LogAssertionHelper();
///       logRecords = helper.logRecords;
///       allowedSevere = helper.allowedSevere;
///       helper.setupLogCapture();
///     });
///
///     void allowSevere(Pattern pattern) => allowedSevere.add(pattern);
///
///     tearDown(() async {
///       LogAssertionHelper.assertNoUnexpectedSevere(logRecords, allowedSevere);
///       helper.tearDownLogCapture();
///     });
///
///     test('error path test', () {
///       allowSevere('Expected error message');
///       // Test code that intentionally causes SEVERE log
///     });
///   });
/// }
/// ```
class LogAssertionHelper {
  /// Records all log messages during test execution
  final List<LogRecord> logRecords = [];

  /// Patterns for SEVERE logs that are expected (intentional error paths)
  final Set<Pattern> allowedSevere = {};
  Level? _previousLevel;
  StreamSubscription<LogRecord>? _subscription;

  /// Sets up log capture for the test.
  /// Call this in setUp().
  void setupLogCapture() {
    logRecords.clear();
    allowedSevere.clear();
    _previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    _subscription = Logger.root.onRecord.listen(logRecords.add);
  }

  /// Cleans up log capture and restores prior logger state.
  /// Call this in tearDown().
  void tearDownLogCapture() {
    _subscription?.cancel();
    _subscription = null;
    if (_previousLevel != null) {
      Logger.root.level = _previousLevel!;
    }
  }

  /// Asserts that no unexpected SEVERE logs occurred during the test.
  /// Expected SEVERE logs must be in the allowlist.
  ///
  /// Call this in tearDown():
  /// ```dart
  /// tearDown(() {
  ///   LogAssertionHelper.assertNoUnexpectedSevere(logRecords, allowedSevere);
  /// });
  /// ```
  static void assertNoUnexpectedSevere(
    List<LogRecord> logRecords,
    Set<Pattern> allowedSevere,
  ) {
    // Find all SEVERE logs
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);

    // Filter out allowed SEVEREs
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );

    // Assert no unexpected SEVEREs
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );

    // Assert expected SEVEREs are present (prevents false positives)
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  }
}

/// Extension method for convenient allowlist management
extension LogAssertionExtension on Set<Pattern> {
  /// Adds a pattern to the SEVERE allowlist for error-path testing.
  void allowSevere(Pattern pattern) => add(pattern);
}
