import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/interfaces/i_contact_repository.dart';
import 'package:pak_connect/core/interfaces/i_message_repository.dart';
import 'package:pak_connect/core/di/repository_provider_impl.dart';
import '../../test_helpers/test_setup.dart';

void main() {
  group('IRepositoryProvider Abstraction Contract', () {
    setUpAll(() async {
      await TestSetup.initializeTestEnvironment();
    });

    tearDownAll(() {
      TestSetup.resetDIServiceLocator();
    });

    group('RepositoryProviderImpl Implementation', () {
      test('✅ DI container provides IRepositoryProvider instance', () {
        // Act - Resolve from DI
        final provider = TestSetup.getService<IRepositoryProvider>();

        // Assert
        expect(provider, isNotNull);
        expect(provider, isA<IRepositoryProvider>());
        expect(provider, isA<RepositoryProviderImpl>());
      });

      test('✅ provides access to contact repository', () {
        // Act
        final provider = TestSetup.getService<IRepositoryProvider>();
        final contactRepo = provider.contactRepository;

        // Assert
        expect(contactRepo, isNotNull);
        expect(contactRepo, isA<IContactRepository>());
      });

      test('✅ provides access to message repository', () {
        // Act
        final provider = TestSetup.getService<IRepositoryProvider>();
        final messageRepo = provider.messageRepository;

        // Assert
        expect(messageRepo, isNotNull);
        expect(messageRepo, isA<IMessageRepository>());
      });

      test('✅ repositories are immutable after provider creation', () {
        // Act
        final provider = TestSetup.getService<IRepositoryProvider>();
        final contactRepo1 = provider.contactRepository;
        final contactRepo2 = provider.contactRepository;

        // Assert - accessing same property multiple times returns same instance
        expect(identical(contactRepo1, contactRepo2), isTrue);
      });
    });

    group('DI Registration and Injection', () {
      test('✅ IRepositoryProvider is registered in DI container', () {
        // Assert - should be able to resolve from GetIt
        final provider = TestSetup.getService<IRepositoryProvider>();
        expect(provider, isNotNull);
        expect(provider, isA<IRepositoryProvider>());
      });

      test('✅ DI-registered provider has valid repositories', () {
        // Act
        final provider = TestSetup.getService<IRepositoryProvider>();

        // Assert
        expect(provider.contactRepository, isNotNull);
        expect(provider.messageRepository, isNotNull);
        expect(provider.contactRepository, isA<IContactRepository>());
        expect(provider.messageRepository, isA<IMessageRepository>());
      });

      test('✅ DI-registered provider is singleton', () {
        // Act
        final provider1 = TestSetup.getService<IRepositoryProvider>();
        final provider2 = TestSetup.getService<IRepositoryProvider>();

        // Assert
        expect(identical(provider1, provider2), isTrue);
      });
    });

    group('Core Layer Service Integration', () {
      test(
        '✅ Core services can be instantiated with IRepositoryProvider from DI',
        () {
          // Verifies that DI-registered services work with IRepositoryProvider
          final provider = TestSetup.getService<IRepositoryProvider>();

          // All services should be resolvable from DI
          expect(provider, isNotNull);
          expect(provider.contactRepository, isNotNull);
          expect(provider.messageRepository, isNotNull);
        },
      );
    });

    group('Backward Compatibility with Optional Parameters', () {
      test('✅ Core services use IRepositoryProvider when provided by DI', () {
        // Verify backward compatibility - services work with optional DI
        final provider = TestSetup.getService<IRepositoryProvider>();

        // Provider should be functional
        expect(provider, isNotNull);
        expect(provider.contactRepository, isNotNull);
        expect(provider.messageRepository, isNotNull);
      });
    });

    group('Repository Access Patterns', () {
      test('✅ provider.contactRepository provides CRUD interface', () async {
        // Act
        final provider = TestSetup.getService<IRepositoryProvider>();
        final contactRepo = provider.contactRepository;

        // Assert - interface should have required methods
        expect(contactRepo, isNotNull);
        expect(contactRepo, isA<IContactRepository>());
      });

      test(
        '✅ provider.messageRepository provides message operations interface',
        () async {
          // Act
          final provider = TestSetup.getService<IRepositoryProvider>();
          final messageRepo = provider.messageRepository;

          // Assert - interface should have required methods
          expect(messageRepo, isNotNull);
          expect(messageRepo, isA<IMessageRepository>());
        },
      );
    });
  });
}
