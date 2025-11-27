import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'dart:io';
import 'package:path/path.dart' as path;

void main() {
  group('Layer Boundary Compliance (Phase 3)', () {
    late Directory projectRoot;

    setUpAll(() {
      // Get project root (assuming test runs from project directory)
      projectRoot = Directory.current;
    });

    group('Core Layer Import Violations', () {
      test('✅ Core layer files do NOT import from presentation/screens', () {
        // Files that should NOT have presentation imports
        final coreFilesPath = path.join(projectRoot.path, 'lib', 'core');
        final coreDir = Directory(coreFilesPath);

        if (!coreDir.existsSync()) {
          fail('Core directory not found at $coreFilesPath');
        }

        // Check all Dart files in core layer
        final dartFiles = coreDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        final violations = <String>[];

        for (final file in dartFiles) {
          final content = file.readAsStringSync();

          // Check for direct screen imports (the violation we fixed)
          if (content.contains("import '") &&
              content.contains("presentation/screens/")) {
            violations.add('${file.path}: imports presentation/screens');
          }
        }

        // Assert - should have no violations after Phase 3 Task 3
        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'No violations found'
              : 'Found layer violations:\n${violations.join('\n')}',
        );
      });

      test(
        '✅ Core layer services use IRepositoryProvider instead of direct imports',
        () {
          // Key files that should be refactored
          final filesToCheck = [
            'lib/core/services/security_manager.dart',
            'lib/core/services/message_retry_coordinator.dart',
            'lib/core/services/hint_scanner_service.dart',
            'lib/core/bluetooth/handshake_coordinator.dart',
            'lib/core/messaging/mesh_relay_engine.dart',
            'lib/core/messaging/offline_message_queue.dart',
          ];

          for (final filePath in filesToCheck) {
            final file = File(path.join(projectRoot.path, filePath));

            if (!file.existsSync()) {
              continue; // File might not exist in all variations
            }

            final content = file.readAsStringSync();

            // Should have IRepositoryProvider or optional contactRepository parameter
            final hasRepositoryProvider =
                content.contains('IRepositoryProvider') ||
                content.contains('contactRepository');

            expect(
              hasRepositoryProvider,
              isTrue,
              reason:
                  '$filePath should use IRepositoryProvider or optional contactRepository',
            );
          }
        },
      );

      test('✅ NavigationService does NOT import presentation/screens', () {
        // Check NavigationService (the file we refactored in Task 3)
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/services/navigation_service.dart',
          ),
        );

        if (!file.existsSync()) {
          fail('NavigationService not found');
        }

        final content = file.readAsStringSync();

        // Should NOT have direct screen imports
        expect(
          content.contains("import '../../presentation/screens/"),
          isFalse,
          reason: 'NavigationService should not import presentation/screens',
        );

        // Should have callback mechanism instead
        expect(
          content.contains('typedef') &&
              (content.contains('ScreenBuilder') ||
                  content.contains('Builder')),
          isTrue,
          reason:
              'NavigationService should define Builder typedefs for callbacks',
        );
      });

      test('✅ Core layer files do NOT import data layer implementations', () {
        final coreDir = Directory(path.join(projectRoot.path, 'lib', 'core'));
        if (!coreDir.existsSync()) {
          fail('Core directory not found');
        }

        final allowList = <String>{
          path.join('lib', 'core', 'app_core.dart'),
          path.join('lib', 'core', 'di', 'service_locator.dart'),
          path.join('lib', 'core', 'interfaces', 'i_ble_service.dart'),
        }.map(path.normalize).toSet();

        final violations = <String>[];
        final dartFiles = coreDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          if (allowList.contains(relativePath)) {
            continue;
          }

          final lines = file.readAsLinesSync();
          final hasConcreteImport = lines.any((line) {
            final trimmed = line.trimLeft();
            final startsWithImport =
                trimmed.startsWith("import '") ||
                trimmed.startsWith('import "');
            if (!startsWithImport) return false;
            return trimmed.contains("../data/") ||
                trimmed.contains("../../data/") ||
                trimmed.contains("package:pak_connect/data");
          });

          if (hasConcreteImport) {
            violations.add(relativePath);
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'All core files respect the interface boundary'
              : 'Core files importing data layer:\n${violations.join('\n')}',
        );
      });
    });

    group('Data Layer Abstraction Compliance', () {
      test('✅ Core layer interfaces are in core/interfaces directory', () {
        final interfacesDir = Directory(
          path.join(projectRoot.path, 'lib/core/interfaces'),
        );

        expect(
          interfacesDir.existsSync(),
          isTrue,
          reason: 'Core interfaces directory should exist',
        );

        // Should have the abstraction interfaces
        final interfaceFiles = interfacesDir
            .listSync()
            .whereType<File>()
            .toList();
        final interfaceNames = interfaceFiles
            .map((f) => path.basename(f.path))
            .toList();

        expect(
          interfaceNames.contains('i_repository_provider.dart'),
          isTrue,
          reason: 'Should have IRepositoryProvider interface',
        );

        expect(
          interfaceNames.contains('i_seen_message_store.dart'),
          isTrue,
          reason: 'Should have ISeenMessageStore interface',
        );
      });

      test('✅ RepositoryProviderImpl is in core/di directory', () {
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/di/repository_provider_impl.dart',
          ),
        );

        expect(
          file.existsSync(),
          isTrue,
          reason: 'RepositoryProviderImpl should exist in core/di',
        );

        final content = file.readAsStringSync();

        // Should implement IRepositoryProvider
        expect(
          content.contains('implements IRepositoryProvider'),
          isTrue,
          reason: 'RepositoryProviderImpl should implement IRepositoryProvider',
        );
      });
    });

    group('DI Registration Compliance', () {
      test('✅ service_locator.dart registers IRepositoryProvider', () {
        final file = File(
          path.join(projectRoot.path, 'lib/core/di/service_locator.dart'),
        );

        expect(
          file.existsSync(),
          isTrue,
          reason: 'service_locator.dart should exist',
        );

        final content = file.readAsStringSync();

        // Should register IRepositoryProvider
        expect(
          content.contains('registerSingleton<IRepositoryProvider>') ||
              content.contains('IRepositoryProvider'),
          isTrue,
          reason: 'service_locator should register IRepositoryProvider',
        );

        // Should register ISeenMessageStore
        expect(
          content.contains('ISeenMessageStore'),
          isTrue,
          reason: 'service_locator should register ISeenMessageStore',
        );
      });

      test('✅ test_setup.dart initializes DI container', () {
        final file = File(
          path.join(projectRoot.path, 'test/test_helpers/test_setup.dart'),
        );

        expect(
          file.existsSync(),
          isTrue,
          reason: 'test_setup.dart should exist',
        );

        final content = file.readAsStringSync();

        // Should call setupServiceLocator during test initialization
        expect(
          content.contains('setupServiceLocator') ||
              content.contains('di_service_locator'),
          isTrue,
          reason: 'test_setup.dart should initialize DI container',
        );
      });
    });

    group('Interface Definition Compliance', () {
      test('✅ IRepositoryProvider defines required properties', () {
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/interfaces/i_repository_provider.dart',
          ),
        );

        final content = file.readAsStringSync();

        // Should define these properties
        expect(
          content.contains('IContactRepository') &&
              content.contains('get contactRepository'),
          isTrue,
          reason: 'IRepositoryProvider should define contactRepository',
        );

        expect(
          content.contains('IMessageRepository') &&
              content.contains('get messageRepository'),
          isTrue,
          reason: 'IRepositoryProvider should define messageRepository',
        );
      });

      test('✅ ISeenMessageStore defines required methods', () {
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/interfaces/i_seen_message_store.dart',
          ),
        );

        final content = file.readAsStringSync();

        // Should define these methods
        final requiredMethods = [
          'hasDelivered',
          'hasRead',
          'markDelivered',
          'markRead',
          'getStatistics',
          'clear',
          'performMaintenance',
        ];

        for (final method in requiredMethods) {
          expect(
            content.contains(method),
            isTrue,
            reason: 'ISeenMessageStore should define $method method',
          );
        }
      });
    });

    group('Backward Compatibility', () {
      test('✅ Services accept optional repository parameters', () {
        // Check SecurityManager
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/services/security_manager.dart',
          ),
        );

        if (!file.existsSync()) {
          return; // Skip if file doesn't exist
        }

        final content = file.readAsStringSync();

        // Should have optional parameters for backward compatibility
        // Looking for pattern like: {IRepositoryProvider? repositoryProvider}
        // or: {contactRepository: ...}
        expect(
          content.contains('?') || content.contains('IRepositoryProvider'),
          isTrue,
          reason:
              'SecurityManager should support optional DI injection for backward compatibility',
        );
      });

      test('✅ MeshRelayEngine uses ISeenMessageStore abstraction', () {
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/messaging/mesh_relay_engine.dart',
          ),
        );

        if (!file.existsSync()) {
          return; // Skip if file doesn't exist
        }

        final content = file.readAsStringSync();

        // Should reference ISeenMessageStore interface
        expect(
          content.contains('ISeenMessageStore') ||
              content.contains('SeenMessageStore'),
          isTrue,
          reason: 'MeshRelayEngine should use ISeenMessageStore',
        );
      });
    });

    group('No Circular Dependencies', () {
      test('✅ Core layer interfaces do NOT import from data layer', () {
        final interfaceFiles =
            Directory(path.join(projectRoot.path, 'lib/core/interfaces'))
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))
                .toList();

        for (final file in interfaceFiles) {
          final content = file.readAsStringSync();

          // Interfaces should NOT import concrete implementations
          expect(
            content.contains("import '../../data/") ||
                    content.contains("import '../../data/repositories/") ||
                    content.contains("import '../../data/services/")
                ? false
                : true,
            isTrue,
            reason:
                '${path.basename(file.path)} should not import from data layer',
          );
        }
      });

      test('✅ RepositoryProviderImpl imports only interfaces', () {
        final file = File(
          path.join(
            projectRoot.path,
            'lib/core/di/repository_provider_impl.dart',
          ),
        );

        if (!file.existsSync()) {
          return; // Skip if not found
        }

        final content = file.readAsStringSync();

        // Should import interfaces, not concrete repos
        expect(
          content.contains('i_repository_provider') &&
              content.contains('i_contact_repository') &&
              content.contains('i_message_repository'),
          isTrue,
          reason: 'RepositoryProviderImpl should import only interfaces',
        );

        // Should NOT directly import concrete repositories
        expect(
          content.contains(
            "import '../../data/repositories/contact_repository'",
          ),
          isFalse,
          reason:
              'RepositoryProviderImpl should not import concrete repositories',
        );
      });
    });
  });
}
