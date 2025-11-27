import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/app_core.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
  });

  tearDown(() {
    AppCore.initializationOverride = null;
    AppCore.resetForTesting();
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );
  });

  test('initialize retries cleanly after transient failure', () async {
    allowedSevere.add('Failed to initialize app core');
    allowedSevere.add('Stack trace:');

    var attempts = 0;
    AppCore.initializationOverride = () async {
      attempts++;
      if (attempts == 1) {
        throw Exception('Simulated transient failure');
      }
    };

    final appCore = AppCore.instance;

    await expectLater(appCore.initialize(), throwsA(isA<AppCoreException>()));
    expect(attempts, 1);

    await appCore.initialize();
    expect(appCore.isInitialized, isTrue);
    expect(attempts, 2);
  });
}
