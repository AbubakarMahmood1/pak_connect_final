import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/app_core.dart';

void main() {
  tearDown(() {
    AppCore.initializationOverride = null;
    AppCore.resetForTesting();
  });

  test('initialize retries cleanly after transient failure', () async {
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
