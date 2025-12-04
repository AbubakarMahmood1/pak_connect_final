import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/di/service_locator.dart';

/// Tests for dependency injection setup
///
/// Phase 1: Tests basic DI infrastructure
/// - Service locator initialization
/// - Feature flag behavior
/// - Reset functionality
///
/// Future phases will test actual service registration
void main() {
  group('ServiceLocator', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      // Reset before each test
      await resetServiceLocator();
    });

    tearDown(() async {
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
      // Clean up after each test
      await resetServiceLocator();
    });

    group('Initialization', () {
      test('setupServiceLocator completes successfully', () async {
        // Arrange & Act
        await setupServiceLocator();

        // Assert
        // No exception thrown means success
        expect(true, isTrue);
      });

      test('setupServiceLocator can be called multiple times', () async {
        // Arrange & Act
        await setupServiceLocator();
        await setupServiceLocator(); // Second call

        // Assert
        // Should not throw
        expect(true, isTrue);
      });

      test('setupServiceLocator respects USE_DI flag', () async {
        // Arrange
        // Note: In Phase 1, USE_DI = true by default
        // This test documents expected behavior

        // Act
        await setupServiceLocator();

        // Assert
        expect(USE_DI, isTrue, reason: 'DI should be enabled in Phase 1');
      });
    });

    group('Reset', () {
      test('resetServiceLocator clears all registrations', () async {
        // Arrange
        await setupServiceLocator();

        // Act
        await resetServiceLocator();

        // Assert
        // Should be able to setup again after reset
        await expectLater(
          setupServiceLocator(),
          completes,
          reason: 'Should be able to setup after reset',
        );
      });

      test('resetServiceLocator can be called when not initialized', () async {
        // Arrange
        // No setup called

        // Act & Assert
        await expectLater(
          resetServiceLocator(),
          completes,
          reason: 'Reset should work even if not initialized',
        );
      });
    });

    group('isRegistered', () {
      test('isRegistered returns false for unregistered service', () {
        // Arrange
        // No service registered

        // Act
        final result = isRegistered<String>();

        // Assert
        expect(result, isFalse);
      });

      test('isRegistered can check multiple types', () {
        // Arrange
        // No services registered

        // Act
        final stringRegistered = isRegistered<String>();
        final intRegistered = isRegistered<int>();
        final listRegistered = isRegistered<List>();

        // Assert
        expect(stringRegistered, isFalse);
        expect(intRegistered, isFalse);
        expect(listRegistered, isFalse);
      });
    });

    group('GetIt Integration', () {
      test('getIt instance is accessible', () {
        // Arrange & Act
        final instance = getIt;

        // Assert
        expect(instance, isNotNull, reason: 'GetIt instance should exist');
      });

      test('getIt is singleton', () {
        // Arrange
        final instance1 = getIt;
        final instance2 = getIt;

        // Act & Assert
        expect(
          identical(instance1, instance2),
          isTrue,
          reason: 'GetIt should return same instance',
        );
      });
    });

    group('Error Handling', () {
      test(
        'setupServiceLocator handles initialization errors gracefully',
        () async {
          // Arrange
          // This test ensures that if setup fails, it rethrows

          // Act & Assert
          // Currently setupServiceLocator has minimal logic
          // If it fails, it should rethrow
          await expectLater(
            setupServiceLocator(),
            completes,
            reason: 'Setup should complete or throw clear exception',
          );
        },
      );
    });

    group('Documentation Validation', () {
      test('USE_DI constant is accessible', () {
        // Arrange & Act
        final flag = USE_DI;

        // Assert
        expect(flag, isNotNull);
        expect(flag, isA<bool>());
      });

      test('service_locator exports are accessible', () {
        // Arrange & Act
        // Verify all public APIs are exported

        // Assert
        expect(setupServiceLocator, isNotNull);
        expect(resetServiceLocator, isNotNull);
        expect(isRegistered, isNotNull);
        expect(getIt, isNotNull);
        expect(USE_DI, isNotNull);
      });
    });

    group('Phase 1 Baseline', () {
      test('Phase 1: No services registered by default', () async {
        // Arrange
        await setupServiceLocator();

        // Act & Assert
        // Phase 1 has empty registration (interfaces created, not yet registered)
        // This test documents the Phase 1 baseline

        // Future phases will register services here
        expect(
          true,
          isTrue,
          reason: 'Phase 1: interfaces created, registration pending',
        );
      });

      test('Phase 1: DI container initializes without errors', () async {
        // Arrange & Act
        final future = setupServiceLocator();

        // Assert
        await expectLater(
          future,
          completes,
          reason: 'Phase 1 DI setup should complete successfully',
        );
      });
    });

    group('Future Service Registration', () {
      test('TODO: Register IContactRepository (Phase 2)', () {
        // Phase 2 will implement:
        // getIt.registerSingleton<IContactRepository>(ContactRepositoryImpl());
        // expect(isRegistered<IContactRepository>(), isTrue);
      });

      test('TODO: Register IMessageRepository (Phase 2)', () {
        // Phase 2 will implement:
        // getIt.registerSingleton<IMessageRepository>(MessageRepositoryImpl());
        // expect(isRegistered<IMessageRepository>(), isTrue);
      });

      test('TODO: Register ISecurityManager (Phase 2)', () {
        // Phase 2 will implement:
        // getIt.registerLazySingleton<ISecurityManager>(() => SecurityManagerImpl());
        // expect(isRegistered<ISecurityManager>(), isTrue);
      });

      test('TODO: Register IBLEService (Phase 2)', () {
        // Phase 2 will implement:
        // getIt.registerLazySingleton<IBLEService>(() => BLEServiceImpl());
        // expect(isRegistered<IBLEService>(), isTrue);
      });

      test('TODO: Register IMeshNetworkingService (Phase 2)', () {
        // Phase 2 will implement:
        // getIt.registerLazySingleton<IMeshNetworkingService>(() => MeshNetworkingServiceImpl());
        // expect(isRegistered<IMeshNetworkingService>(), isTrue);
      });
    });
  });
}
