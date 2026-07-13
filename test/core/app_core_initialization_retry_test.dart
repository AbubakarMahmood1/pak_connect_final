import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/app_core.dart';
import 'package:pak_connect/core/di/service_locator.dart'
    show configureDataLayerRegistrar;
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/data/di/data_layer_service_registrar.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecureStorage extends Fake implements FlutterSecureStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.remove(key);
  }
}

void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;
  StreamSubscription<LogRecord>? logSubscription;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    configureDataLayerRegistrar(registerDataLayerServices);
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logRecords.add);
  });

  tearDown(() {
    logSubscription?.cancel();
    logSubscription = null;
    AppCore.initializationOverride = null;
    SecurityManager.instance.shutdown();
    SecurityServiceLocator.clearServiceResolver();
    EphemeralKeyManager.reset();
    TopologyManager.instance.dispose();
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

  test('failed runtime initialization can rebootstrap a fresh core', () async {
    allowedSevere.add('Failed to initialize app core');
    allowedSevere.add('Stack trace:');

    final secureStorage = _MemorySecureStorage();
    AppCore.initializationOverride = () async {
      await SecurityManager.instance.initialize(secureStorage: secureStorage);
      SecurityServiceLocator.configureServiceResolver(
        () => SecurityManager.instance,
      );
      await EphemeralKeyManager.initialize(List<String>.filled(64, 'a').join());
      TopologyManager.instance.initialize(
        EphemeralKeyManager.generateMyEphemeralKey(),
      );
      throw Exception('Simulated composed-runtime failure');
    };
    final failedCore = AppCore.instance;
    await expectLater(
      failedCore.initialize(),
      throwsA(isA<AppCoreException>()),
    );
    expect(SecurityManager.instance.noiseService, isNotNull);
    expect(
      SecurityServiceLocator.resolveService(),
      same(SecurityManager.instance),
    );
    expect(EphemeralKeyManager.currentSessionKey, isNotNull);
    expect(TopologyManager.instance.getTopology().nodes, isNotEmpty);

    AppCore.initializationOverride = () async {};
    final firstPreparation = AppCore.prepareInitializationRetry();
    final secondPreparation = AppCore.prepareInitializationRetry();
    expect(secondPreparation, same(firstPreparation));
    final retryCore = await firstPreparation;
    expect(await secondPreparation, same(retryCore));

    expect(retryCore, isNot(same(failedCore)));
    expect(AppCore.instance, same(retryCore));
    expect(SecurityManager.instance.noiseService, isNull);
    expect(SecurityServiceLocator.resolveService, throwsA(isA<StateError>()));
    expect(EphemeralKeyManager.currentSessionKey, isNull);
    expect(EphemeralKeyManager.ephemeralSigningPrivateKey, isNull);
    expect(TopologyManager.instance.getTopology().nodes, isEmpty);
    await retryCore.initialize();
    expect(retryCore.isInitialized, isTrue);
  });
}
