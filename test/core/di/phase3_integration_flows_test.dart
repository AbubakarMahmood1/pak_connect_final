import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  group('Phase 3: End-to-End Integration Flows', () {
    setUpAll(() async {
      await TestSetup.initializeTestEnvironment(
        dbLabel: 'phase3_integration_flows',
      );
      await TestSetup.configureTestDI();
    });

    tearDownAll(() {
      TestSetup.resetDIServiceLocator();
    });

    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
    });

    tearDown(() {
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

    group('DI-Injected Component Initialization', () {
      test('✅ DI container properly initializes all abstractions', () async {
        // Act - Verify critical abstractions are registered
        final provider = TestSetup.getService<IRepositoryProvider>();
        final seenStore = TestSetup.getService<ISeenMessageStore>();

        // Assert
        expect(provider, isNotNull);
        expect(seenStore, isNotNull);
      });

      test(
        '✅ All services can access repositories through IRepositoryProvider',
        () async {
          // Act - Services use IRepositoryProvider for repository access
          final provider = TestSetup.getService<IRepositoryProvider>();

          // Provider should give access to both repositories
          expect(provider.contactRepository, isNotNull);
          expect(provider.messageRepository, isNotNull);

          // Assert
          expect(provider, isNotNull);
        },
      );
    });

    group('Relay Flow with Abstracted Dependencies', () {
      test(
        '✅ Relay components use IRepositoryProvider and ISeenMessageStore abstractions',
        () async {
          // Arrange - Get abstractions that relay components depend on
          final provider = TestSetup.getService<IRepositoryProvider>();
          final seenMessageStore = TestSetup.getService<ISeenMessageStore>();

          // Clear store for clean test
          await seenMessageStore.clear();

          // Act - Verify relay abstractions work correctly
          const messageId = 'relay-test-msg-1';
          final shouldRelayFirst = !seenMessageStore.hasDelivered(messageId);

          if (shouldRelayFirst) {
            await seenMessageStore.markDelivered(messageId);
          }

          // Check if same message should be relayed again
          final shouldRelaySecond = !seenMessageStore.hasDelivered(messageId);

          // Assert - Demonstrates relay logic works with abstracted dependencies
          expect(shouldRelayFirst, isTrue); // First relay should happen
          expect(shouldRelaySecond, isFalse); // Second relay should be blocked
          expect(
            provider,
            isNotNull,
          ); // Provider is available for relay components
        },
      );

      test(
        '✅ SeenMessageStore prevents duplicate message processing in relay flow',
        () async {
          // Arrange
          final seenStore = TestSetup.getService<ISeenMessageStore>();
          await seenStore.clear();

          // Act - Simulate relay processing with duplicate detection
          const messageId = 'dup-check-msg';

          // First processing
          bool isNew = !seenStore.hasDelivered(messageId);
          if (isNew) {
            await seenStore.markDelivered(messageId);
          }

          // Duplicate arrival (network fluke)
          bool isDuplicate = seenStore.hasDelivered(messageId);

          // Assert
          expect(isNew, isTrue);
          expect(isDuplicate, isTrue); // Correctly identified as duplicate
        },
      );
    });

    group('Repository Access Through Abstraction', () {
      test(
        '✅ Services access ContactRepository through IRepositoryProvider',
        () async {
          // Arrange
          final provider = TestSetup.getService<IRepositoryProvider>();

          // Act
          final contactRepository = provider.contactRepository;

          // Assert
          expect(contactRepository, isNotNull);
          expect(contactRepository, isA<IContactRepository>());
        },
      );

      test(
        '✅ Services access MessageRepository through IRepositoryProvider',
        () async {
          // Arrange
          final provider = TestSetup.getService<IRepositoryProvider>();

          // Act
          final messageRepository = provider.messageRepository;

          // Assert
          expect(messageRepository, isNotNull);
          expect(messageRepository, isA<IMessageRepository>());
        },
      );

      test(
        '✅ Multiple services can access same IRepositoryProvider instance',
        () async {
          // This verifies singleton pattern and proper DI usage
          final provider1 = TestSetup.getService<IRepositoryProvider>();
          final provider2 = TestSetup.getService<IRepositoryProvider>();
          final provider3 = TestSetup.getService<IRepositoryProvider>();

          // All references should be same singleton
          expect(identical(provider1, provider2), isTrue);
          expect(identical(provider2, provider3), isTrue);
        },
      );
    });

    group('Navigation Service Callback System', () {
      test(
        '✅ NavigationService uses callback system instead of direct imports',
        () {
          // This verifies the refactoring in Task 3
          final navigationServiceFile = TestSetup.readProjectFile(
            'lib/core/services/navigation_service.dart',
          );

          // Assert - Should NOT have direct screen imports
          expect(
            navigationServiceFile.contains(
              "import '../../presentation/screens/",
            ),
            isFalse,
            reason: 'NavigationService should not import presentation/screens',
          );

          // Should have callback mechanism
          expect(
            navigationServiceFile.contains('typedef'),
            isTrue,
            reason: 'NavigationService should use callback typedefs',
          );
        },
      );
    });

    group('Layer Boundary Enforcement', () {
      test('✅ Core layer services are properly abstracted through DI', () {
        // Verify that all abstractions are available for Core layer services
        final provider = TestSetup.getService<IRepositoryProvider>();
        final seenStore = TestSetup.getService<ISeenMessageStore>();

        // Services should have access to abstractions through DI
        expect(provider, isNotNull);
        expect(seenStore, isNotNull);
        expect(provider.contactRepository, isNotNull);
        expect(provider.messageRepository, isNotNull);
      });

      test(
        '✅ Domain layer abstractions (interfaces) do NOT import Data layer implementations',
        () {
          // Verify true dependency inversion
          final repositoryProviderInterfaceFile = TestSetup.readProjectFile(
            'lib/domain/interfaces/i_repository_provider.dart',
          );

          expect(
            repositoryProviderInterfaceFile.contains(
              "import '../../data/repositories/",
            ),
            isFalse,
            reason:
                'Domain interfaces should not import Data layer implementations',
          );
        },
      );
    });

    group('Backward Compatibility Verification', () {
      test(
        '✅ IRepositoryProvider is available for services that need injection',
        () async {
          // Verify that DI provides what services need

          // Services can access provider from DI
          final provider = TestSetup.getService<IRepositoryProvider>();

          expect(provider, isNotNull);
          expect(provider.contactRepository, isNotNull);
          expect(provider.messageRepository, isNotNull);
        },
      );

      test('✅ ISeenMessageStore is available for relay components', () async {
        // Verify new DI pattern works
        final store = TestSetup.getService<ISeenMessageStore>();

        expect(store, isNotNull);
      });
    });

    group('Multiple Services Coordination', () {
      test(
        '✅ Services coordinate through shared IRepositoryProvider instance',
        () async {
          // Arrange - Get provider for multiple service scenarios
          final provider1 = TestSetup.getService<IRepositoryProvider>();
          final provider2 = TestSetup.getService<IRepositoryProvider>();

          // Assert - Both references should be same singleton
          expect(identical(provider1, provider2), isTrue);
        },
      );

      test(
        '✅ Services coordinate through shared ISeenMessageStore instance',
        () async {
          // Arrange
          final store1 = TestSetup.getService<ISeenMessageStore>();
          final store2 = TestSetup.getService<ISeenMessageStore>();

          // Assert - Both references should be same singleton
          expect(identical(store1, store2), isTrue);
        },
      );
    });

    group('DI Container State', () {
      test(
        '✅ IRepositoryProvider is singleton across multiple resolutions',
        () async {
          // Act - Get provider multiple times
          final provider1 = TestSetup.getService<IRepositoryProvider>();
          final provider2 = TestSetup.getService<IRepositoryProvider>();
          final provider3 = TestSetup.getService<IRepositoryProvider>();

          // Assert - All references should be same instance (singleton)
          expect(identical(provider1, provider2), isTrue);
          expect(identical(provider2, provider3), isTrue);
        },
      );

      test(
        '✅ ISeenMessageStore is singleton across multiple resolutions',
        () async {
          // Act - Get store multiple times
          final store1 = TestSetup.getService<ISeenMessageStore>();
          final store2 = TestSetup.getService<ISeenMessageStore>();
          final store3 = TestSetup.getService<ISeenMessageStore>();

          // Assert - All references should be same instance (singleton)
          expect(identical(store1, store2), isTrue);
          expect(identical(store2, store3), isTrue);
        },
      );
    });
  });
}
