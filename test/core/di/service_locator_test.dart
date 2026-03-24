import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/di/app_services.dart';
import 'package:pak_connect/core/di/service_locator.dart';
import 'package:pak_connect/data/di/data_layer_service_registrar.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/archive_search_service.dart';
import 'package:pak_connect/domain/services/chat_management_service.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/services/mesh/mesh_network_health_monitor.dart';

/// Tests for the internal service registry bootstrap boundary.
void main() {
  group('ServiceLocator', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      configureDataLayerRegistrar(registerDataLayerServices);
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

      test('setupServiceLocator respects useDi flag', () async {
        await setupServiceLocator();

        expect(useDi, isTrue, reason: 'DI should remain enabled.');
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

    group('Service Registry Integration', () {
      test('service registry instance is accessible', () {
        final instance = serviceRegistry;

        expect(
          instance,
          isNotNull,
          reason: 'Service registry instance should exist',
        );
      });

      test('service registry is singleton', () {
        final instance1 = serviceRegistry;
        final instance2 = serviceRegistry;

        expect(
          identical(instance1, instance2),
          isTrue,
          reason: 'Service registry should return same instance',
        );
      });
    });

    group('Error Handling', () {
      test(
        'setupServiceLocator handles initialization errors gracefully',
        () async {
          await expectLater(
            setupServiceLocator(),
            completes,
            reason: 'Setup should complete or throw clear exception',
          );
        },
      );
    });

    group('Documentation Validation', () {
      test('useDi constant is accessible', () {
        final flag = useDi;

        expect(flag, isNotNull);
        expect(flag, isA<bool>());
      });

      test('service_locator exports are accessible', () {
        expect(setupServiceLocator, isNotNull);
        expect(resetServiceLocator, isNotNull);
        expect(isRegistered, isNotNull);
        expect(serviceRegistry, isNotNull);
        expect(useDi, isNotNull);
        expect(resolveAppBootstrapServices, isNotNull);
        expect(publishAppServices, isNotNull);
        expect(clearPublishedAppServices, isNotNull);
      });
    });

    group('Typed Composition Snapshots', () {
      test(
        'resolveAppBootstrapServices returns required bootstrap bundle',
        () async {
          await setupServiceLocator();

          final bootstrap = resolveAppBootstrapServices();

          expect(
            bootstrap.contactRepository,
            same(resolveRegistered<IContactRepository>()),
          );
          expect(
            bootstrap.messageRepository,
            same(resolveRegistered<IMessageRepository>()),
          );
          expect(
            bootstrap.archiveRepository,
            same(resolveRegistered<IArchiveRepository>()),
          );
          expect(
            bootstrap.chatsRepository,
            same(resolveRegistered<IChatsRepository>()),
          );
          expect(
            bootstrap.preferencesRepository,
            same(resolveRegistered<IPreferencesRepository>()),
          );
          expect(
            bootstrap.sharedMessageQueueProvider,
            same(resolveRegistered<ISharedMessageQueueProvider>()),
          );
          expect(
            bootstrap.seenMessageStore,
            same(resolveRegistered<ISeenMessageStore>()),
          );
          expect(
            bootstrap.bleServiceFacadeFactory,
            same(resolveRegistered<IBLEServiceFacadeFactory>()),
          );
          expect(
            bootstrap.meshRelayEngineFactory,
            same(resolveRegistered<IMeshRelayEngineFactory>()),
          );
          expect(bootstrap.homeScreenFacadeFactory, isNotNull);
          expect(bootstrap.chatConnectionManagerFactory, isNotNull);
          expect(bootstrap.chatListCoordinatorFactory, isNotNull);
        },
      );

      test(
        'publishAppServices publishes runtime snapshot outside bootstrap registry',
        () async {
          await setupServiceLocator();
          final bootstrap = resolveAppBootstrapServices();

          final archiveManagementService =
              ArchiveManagementService.withDependencies(
                archiveRepository: bootstrap.archiveRepository,
              );
          final archiveSearchService = ArchiveSearchService.withDependencies(
            archiveRepository: bootstrap.archiveRepository,
          );
          final contactManagementService =
              ContactManagementService.withDependencies(
                contactRepository: bootstrap.contactRepository,
                messageRepository: bootstrap.messageRepository,
              );
          final chatManagementService = ChatManagementService.withDependencies(
            chatsRepository: bootstrap.chatsRepository,
            messageRepository: bootstrap.messageRepository,
            archiveRepository: bootstrap.archiveRepository,
            archiveManagementService: archiveManagementService,
            archiveSearchService: archiveSearchService,
          );

          final snapshot = bootstrap.buildRuntimeSnapshot(
            connectionService: _FakeConnectionService(),
            meshNetworkingService: _FakeMeshNetworkingService(),
            meshNetworkHealthMonitor: MeshNetworkHealthMonitor(),
            securityService: _FakeSecurityService(),
            contactManagementService: contactManagementService,
            chatManagementService: chatManagementService,
            archiveManagementService: archiveManagementService,
            archiveSearchService: archiveSearchService,
          );

          publishAppServices(snapshot);
          expect(resolveRegistered<AppServices>(), same(snapshot));
          expect(serviceRegistry.isRegistered<AppServices>(), isFalse);

          clearPublishedAppServices();
          expect(maybeResolveRegistered<AppServices>(), isNull);
          expect(serviceRegistry.isRegistered<AppServices>(), isFalse);
        },
      );
    });
  });
}

class _FakeConnectionService implements IConnectionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeMeshNetworkingService implements IMeshNetworkingService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeSecurityService implements ISecurityService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
