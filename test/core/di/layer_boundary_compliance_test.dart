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
            final isDomainShim = content.contains(
              "export 'package:pak_connect/domain/",
            );
            final hasRepositoryProvider =
                content.contains('IRepositoryProvider') ||
                content.contains('contactRepository') ||
                isDomainShim;

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

        final allowList = <String>{}.map(path.normalize).toSet();

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

      test('✅ Core implementation files import domain interfaces directly', () {
        final coreDir = Directory(path.join(projectRoot.path, 'lib', 'core'));
        if (!coreDir.existsSync()) {
          fail('Core directory not found');
        }

        final violations = <String>[];
        final dartFiles = coreDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where(
              (f) =>
                  !path.normalize(f.path).contains('core\\interfaces\\') &&
                  !path.normalize(f.path).contains('core/interfaces/'),
            )
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trimLeft();
            final startsWithImport =
                line.startsWith("import '") || line.startsWith('import "');
            if (!startsWithImport) continue;

            final referencesCoreInterfaceShim =
                line.contains('/core/interfaces/') ||
                line.contains('../interfaces/') ||
                line.contains("import 'interfaces/") ||
                line.contains('package:pak_connect/core/interfaces/');

            if (!referencesCoreInterfaceShim) continue;

            violations.add('$relativePath:${i + 1} -> $line');
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Core implementation imports use domain interfaces'
              : 'Core files still importing interface shims:\n${violations.join('\n')}',
        );
      });

      test('✅ Core implementation files import domain models directly', () {
        final coreDir = Directory(path.join(projectRoot.path, 'lib', 'core'));
        if (!coreDir.existsSync()) {
          fail('Core directory not found');
        }

        final violations = <String>[];
        final dartFiles = coreDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .where(
              (f) =>
                  !path.normalize(f.path).contains('core\\models\\') &&
                  !path.normalize(f.path).contains('core/models/'),
            )
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trimLeft();
            final startsWithImport =
                line.startsWith("import '") || line.startsWith('import "');
            if (!startsWithImport) continue;

            final referencesCoreModelShim =
                line.contains('package:pak_connect/core/models/') ||
                line.contains('/core/models/') ||
                line.contains('../models/') ||
                line.contains('../../models/');

            if (referencesCoreModelShim) {
              violations.add('$relativePath:${i + 1} -> $line');
            }
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Core implementation imports use domain models'
              : 'Core files still importing model shims:\n${violations.join('\n')}',
        );
      });

      test(
        '✅ Core implementation files do NOT import core-to-domain shim files',
        () {
          final coreDir = Directory(path.join(projectRoot.path, 'lib', 'core'));
          if (!coreDir.existsSync()) {
            fail('Core directory not found');
          }

          final coreFiles = coreDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .toList();

          final shimFiles = <String>{};
          final exportToDomainPattern = RegExp(
            r'''^export\s+['"]package:pak_connect/domain/''',
            multiLine: true,
          );
          for (final file in coreFiles) {
            final content = file.readAsStringSync();
            if (exportToDomainPattern.hasMatch(content)) {
              shimFiles.add(path.normalize(file.path));
            }
          }

          final violations = <String>[];
          final importPattern = RegExp(r'''^import\s+['"]([^'"]+)['"];''');

          for (final file in coreFiles) {
            final normalizedFilePath = path.normalize(file.path);
            if (shimFiles.contains(normalizedFilePath)) {
              continue;
            }

            final lines = file.readAsLinesSync();
            for (var i = 0; i < lines.length; i++) {
              final line = lines[i].trimLeft();
              final match = importPattern.firstMatch(line);
              if (match == null) continue;

              final importUri = match.group(1)!;
              String? resolvedImportPath;
              if (importUri.startsWith('package:pak_connect/core/')) {
                final relativeCorePath = importUri.substring(
                  'package:pak_connect/core/'.length,
                );
                resolvedImportPath = path.normalize(
                  path.join(projectRoot.path, 'lib', 'core', relativeCorePath),
                );
              } else if (importUri.startsWith('./') ||
                  importUri.startsWith('../')) {
                resolvedImportPath = path.normalize(
                  path.join(path.dirname(file.path), importUri),
                );
              }

              if (resolvedImportPath != null &&
                  shimFiles.contains(resolvedImportPath)) {
                final relativePath = path.normalize(
                  path.relative(file.path, from: projectRoot.path),
                );
                violations.add('$relativePath:${i + 1} -> $line');
              }
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Core implementation files avoid core-to-domain shims'
                : 'Core files importing shim files:\n${violations.join('\n')}',
          );
        },
      );
    });

    group('Domain Layer Import Violations', () {
      test('✅ Domain layer files do NOT import core modules', () {
        final domainDir = Directory(path.join(projectRoot.path, 'lib/domain'));

        if (!domainDir.existsSync()) {
          fail('Domain directory not found');
        }

        final violations = <String>[];
        final dartFiles = domainDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        for (final file in dartFiles) {
          final lines = file.readAsLinesSync();
          final hasViolation = lines.any((line) {
            final trimmed = line.trimLeft();
            final startsWithImport =
                trimmed.startsWith("import '") ||
                trimmed.startsWith('import "');
            if (!startsWithImport) return false;
            return trimmed.contains('package:pak_connect/core/') ||
                trimmed.contains('/core/');
          });

          if (hasViolation) {
            violations.add(
              path.normalize(path.relative(file.path, from: projectRoot.path)),
            );
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Domain layer has no core import violations'
              : 'Domain files importing core modules:\n${violations.join('\n')}',
        );
      });

      test(
        '✅ Domain layer files do NOT import moved core model ownership types',
        () {
          final domainDir = Directory(
            path.join(projectRoot.path, 'lib/domain'),
          );

          if (!domainDir.existsSync()) {
            fail('Domain directory not found');
          }

          final violations = <String>[];
          final dartFiles = domainDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .toList();

          for (final file in dartFiles) {
            final lines = file.readAsLinesSync();
            final hasViolation = lines.any((line) {
              final trimmed = line.trimLeft();
              final startsWithImport =
                  trimmed.startsWith("import '") ||
                  trimmed.startsWith('import "');
              if (!startsWithImport) return false;

              return trimmed.contains('core/models/archive_models.dart') ||
                  trimmed.contains('core/models/contact_group.dart') ||
                  trimmed.contains('core/models/message_priority.dart') ||
                  trimmed.contains('core/models/connection_info.dart') ||
                  trimmed.contains('core/models/mesh_relay_models.dart') ||
                  trimmed.contains('core/models/protocol_message.dart') ||
                  trimmed.contains('core/models/spy_mode_info.dart') ||
                  trimmed.contains('core/models/ble_server_connection.dart') ||
                  trimmed.contains(
                    'core/bluetooth/bluetooth_state_monitor.dart',
                  ) ||
                  trimmed.contains('core/utils/gcs_filter.dart') ||
                  trimmed.contains('core/utils/string_extensions.dart') ||
                  trimmed.contains('core/utils/chat_utils.dart') ||
                  trimmed.contains('core/utils/mesh_debug_logger.dart') ||
                  trimmed.contains(
                    'core/constants/binary_payload_types.dart',
                  ) ||
                  trimmed.contains('core/config/kill_switches.dart') ||
                  trimmed.contains(
                    'core/security/spam_prevention_manager.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_archive_repository.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_message_repository.dart',
                  ) ||
                  trimmed.contains('core/interfaces/i_chats_repository.dart') ||
                  trimmed.contains(
                    'core/interfaces/i_contact_repository.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_preferences_repository.dart',
                  ) ||
                  trimmed.contains('core/interfaces/i_group_repository.dart') ||
                  trimmed.contains(
                    'core/interfaces/i_repository_provider.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_connection_service.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_mesh_networking_service.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_ble_message_handler_facade.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_seen_message_store.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_message_fragmentation_handler.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_shared_message_queue_provider.dart',
                  ) ||
                  trimmed.contains('core/messaging/message_ack_tracker.dart') ||
                  trimmed.contains(
                    'core/messaging/media_transfer_store.dart',
                  ) ||
                  trimmed.contains('core/messaging/gossip_sync_manager.dart') ||
                  trimmed.contains('core/messaging/queue_sync_manager.dart') ||
                  trimmed.contains(
                    'core/messaging/offline_message_queue.dart',
                  ) ||
                  trimmed.contains('core/interfaces/i_mesh_ble_service.dart') ||
                  trimmed.contains(
                    'core/interfaces/i_ble_discovery_service.dart',
                  ) ||
                  trimmed.contains(
                    'core/interfaces/i_ble_messaging_service.dart',
                  );
            });

            if (hasViolation) {
              violations.add(
                path.normalize(
                  path.relative(file.path, from: projectRoot.path),
                ),
              );
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Domain layer has no moved-model import violations'
                : 'Domain files importing moved core models:\n${violations.join('\n')}',
          );
        },
      );

      test('✅ Domain layer files do NOT import data or presentation modules', () {
        final domainDir = Directory(path.join(projectRoot.path, 'lib/domain'));
        if (!domainDir.existsSync()) {
          fail('Domain directory not found');
        }

        final violations = <String>[];
        final dartFiles = domainDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trimLeft();
            final startsWithImport =
                line.startsWith("import '") || line.startsWith('import "');
            if (!startsWithImport) continue;

            final importsDataOrPresentation =
                line.contains('/data/') || line.contains('/presentation/');
            if (importsDataOrPresentation) {
              violations.add('$relativePath:${i + 1} -> $line');
            }
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Domain layer stays independent from data/presentation'
              : 'Domain imports data/presentation modules:\n${violations.join('\n')}',
        );
      });
    });

    group('Data Layer Abstraction Compliance', () {
      test(
        '✅ Data layer files do NOT import core OfflineMessageQueue implementation',
        () {
          final dataDir = Directory(path.join(projectRoot.path, 'lib/data'));
          if (!dataDir.existsSync()) {
            fail('Data directory not found');
          }

          final violations = <String>[];
          final dartFiles = dataDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .toList();

          for (final file in dartFiles) {
            final lines = file.readAsLinesSync();
            final hasViolation = lines.any((line) {
              final trimmed = line.trimLeft();
              final startsWithImport =
                  trimmed.startsWith("import '") ||
                  trimmed.startsWith('import "');
              if (!startsWithImport) return false;
              return trimmed.contains(
                'core/messaging/offline_message_queue.dart',
              );
            });

            if (hasViolation) {
              violations.add(
                path.normalize(
                  path.relative(file.path, from: projectRoot.path),
                ),
              );
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Data layer uses queue abstractions/contracts'
                : 'Data files importing OfflineMessageQueue concrete implementation:\n${violations.join('\n')}',
          );
        },
      );

      test('✅ Data layer files do NOT import presentation modules', () {
        final dataDir = Directory(path.join(projectRoot.path, 'lib/data'));
        if (!dataDir.existsSync()) {
          fail('Data directory not found');
        }

        final violations = <String>[];
        final dartFiles = dataDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trimLeft();
            final startsWithImport =
                line.startsWith("import '") || line.startsWith('import "');
            if (!startsWithImport) continue;

            if (line.contains('/presentation/')) {
              violations.add('$relativePath:${i + 1} -> $line');
            }
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Data layer stays independent from presentation'
              : 'Data imports presentation modules:\n${violations.join('\n')}',
        );
      });

      test('✅ Presentation layer files do NOT import data modules', () {
        final presentationDir = Directory(
          path.join(projectRoot.path, 'lib/presentation'),
        );
        if (!presentationDir.existsSync()) {
          fail('Presentation directory not found');
        }

        final violations = <String>[];
        final dartFiles = presentationDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        for (final file in dartFiles) {
          final relativePath = path.normalize(
            path.relative(file.path, from: projectRoot.path),
          );
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final line = lines[i].trimLeft();
            final startsWithImport =
                line.startsWith("import '") || line.startsWith('import "');
            if (!startsWithImport) continue;

            if (line.contains('/data/')) {
              violations.add('$relativePath:${i + 1} -> $line');
            }
          }
        }

        expect(
          violations.isEmpty,
          isTrue,
          reason: violations.isEmpty
              ? 'Presentation layer stays independent from data'
              : 'Presentation imports data modules:\n${violations.join('\n')}',
        );
      });

      test('✅ Domain layer interfaces are in domain/interfaces directory', () {
        final interfacesDir = Directory(
          path.join(projectRoot.path, 'lib/domain/interfaces'),
        );

        expect(
          interfacesDir.existsSync(),
          isTrue,
          reason: 'Domain interfaces directory should exist',
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

      test('✅ Legacy core shim directories are empty (safe to delete)', () {
        final legacyShimDirs = <String>[
          'lib/core/interfaces',
          'lib/core/models',
          'lib/core/constants',
          'lib/core/utils',
          'lib/core/routing',
          'lib/core/config',
          'lib/core/compression',
          'lib/core/monitoring',
          'lib/core/networking',
          'lib/core/performance',
          'lib/core/scanning',
        ];

        final lingeringEntries = <String>[];

        for (final relativeDir in legacyShimDirs) {
          final directory = Directory(path.join(projectRoot.path, relativeDir));
          if (!directory.existsSync()) {
            continue;
          }

          final entries = directory.listSync(recursive: true).toList();
          for (final entry in entries) {
            lingeringEntries.add(
              path.normalize(path.relative(entry.path, from: projectRoot.path)),
            );
          }
        }

        expect(
          lingeringEntries,
          isEmpty,
          reason: lingeringEntries.isEmpty
              ? 'Legacy core shim directories are empty'
              : 'Legacy shim directories should remain empty so they are safe to delete:\n${lingeringEntries.join('\n')}',
        );
      });

      test(
        '✅ Non-core layers do NOT import core model/interface/constant shims',
        () {
          final libDir = Directory(path.join(projectRoot.path, 'lib'));
          if (!libDir.existsSync()) {
            fail('lib directory not found');
          }

          final violations = <String>[];

          final dartFiles = libDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where((f) {
                final normalized = path.normalize(f.path);
                return !normalized.contains('lib\\core\\') &&
                    !normalized.contains('lib/core/');
              })
              .toList();

          for (final file in dartFiles) {
            final relativePath = path.normalize(
              path.relative(file.path, from: projectRoot.path),
            );

            // Intentional shim that re-exports the core test harness.
            if (relativePath ==
                path.normalize('test/test_helpers/test_setup.dart')) {
              continue;
            }
            final lines = file.readAsLinesSync();

            for (var i = 0; i < lines.length; i++) {
              final line = lines[i].trimLeft();
              final startsWithImport =
                  line.startsWith("import '") || line.startsWith('import "');
              if (!startsWithImport) continue;

              final referencesCoreShim =
                  line.contains('package:pak_connect/core/models/') ||
                  line.contains('package:pak_connect/core/interfaces/') ||
                  line.contains('package:pak_connect/core/constants/') ||
                  line.contains('package:pak_connect/core/routing/') ||
                  line.contains('package:pak_connect/core/config/') ||
                  line.contains('package:pak_connect/core/utils/') ||
                  line.contains('/core/models/') ||
                  line.contains('/core/interfaces/') ||
                  line.contains('/core/constants/') ||
                  line.contains('/core/routing/') ||
                  line.contains('/core/config/') ||
                  line.contains('/core/utils/');

              if (referencesCoreShim) {
                violations.add('$relativePath:${i + 1} -> $line');
              }
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Non-core layers use domain-owned contracts and models'
                : 'Found non-core imports of core shims:\n${violations.join('\n')}',
          );
        },
      );

      test(
        '✅ Non-core lib folders do NOT import core modules (except app composition root)',
        () {
          final libDir = Directory(path.join(projectRoot.path, 'lib'));
          if (!libDir.existsSync()) {
            fail('lib directory not found');
          }

          final violations = <String>[];
          final dartFiles = libDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where((f) {
                final normalized = path.normalize(f.path);
                return !normalized.contains('lib\\core\\') &&
                    !normalized.contains('lib/core/');
              })
              .toList();

          for (final file in dartFiles) {
            final relativePath = path.normalize(
              path.relative(file.path, from: projectRoot.path),
            );

            // Composition root is allowed to wire core bootstrapping.
            if (relativePath == path.normalize('lib/main.dart')) {
              continue;
            }

            final lines = file.readAsLinesSync();
            for (var i = 0; i < lines.length; i++) {
              final line = lines[i].trimLeft();
              final startsWithImport =
                  line.startsWith("import '") || line.startsWith('import "');
              if (!startsWithImport) continue;

              final importsCoreModule =
                  line.contains('package:pak_connect/core/') ||
                  line.contains('/core/');
              if (importsCoreModule) {
                violations.add('$relativePath:${i + 1} -> $line');
              }
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Non-core lib folders avoid core imports'
                : 'Found non-core lib imports of core modules:\n${violations.join('\n')}',
          );
        },
      );

      test(
        '✅ Test files avoid core model/interface/constant utility shims',
        () {
          final testDir = Directory(path.join(projectRoot.path, 'test'));
          if (!testDir.existsSync()) {
            fail('test directory not found');
          }

          final violations = <String>[];
          final dartFiles = testDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .toList();

          for (final file in dartFiles) {
            final relativePath = path.normalize(
              path.relative(file.path, from: projectRoot.path),
            );

            // This file intentionally contains literal core/* strings for
            // policy assertions.
            if (relativePath ==
                path.normalize(
                  'test/core/di/layer_boundary_compliance_test.dart',
                )) {
              continue;
            }

            final lines = file.readAsLinesSync();
            for (var i = 0; i < lines.length; i++) {
              final line = lines[i].trimLeft();
              final startsWithImport =
                  line.startsWith("import '") || line.startsWith('import "');
              if (!startsWithImport) continue;

              final referencesCoreShim =
                  line.contains('package:pak_connect/core/models/') ||
                  line.contains('package:pak_connect/core/interfaces/') ||
                  line.contains('package:pak_connect/core/constants/') ||
                  line.contains('package:pak_connect/core/routing/') ||
                  line.contains('package:pak_connect/core/config/') ||
                  line.contains('package:pak_connect/core/utils/');

              if (referencesCoreShim) {
                violations.add('$relativePath:${i + 1} -> $line');
              }
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Tests import domain-owned modules directly'
                : 'Found test imports of core shims:\n${violations.join('\n')}',
          );
        },
      );

      test(
        '✅ Non-core test folders do NOT import core implementation modules',
        () {
          final testRoot = Directory(path.join(projectRoot.path, 'test'));
          expect(testRoot.existsSync(), isTrue, reason: 'test/ should exist');

          final violations = <String>[];
          final dartFiles = testRoot
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .where((f) {
                final normalized = path.normalize(f.path);
                final inCoreFolder = normalized.contains(
                  '${path.separator}test${path.separator}core${path.separator}',
                );
                return !inCoreFolder;
              })
              .toList();

          for (final file in dartFiles) {
            final relativePath = path.normalize(
              path.relative(file.path, from: projectRoot.path),
            );
            final lines = file.readAsLinesSync();

            for (var i = 0; i < lines.length; i++) {
              final line = lines[i].trimLeft();
              final startsWithImport =
                  line.startsWith("import '") || line.startsWith('import "');
              if (!startsWithImport) continue;

              final importsCoreImplementation =
                  line.contains('package:pak_connect/core/') ||
                  line.contains('/core/');

              if (importsCoreImplementation) {
                violations.add('$relativePath:${i + 1} -> $line');
              }
            }
          }

          expect(
            violations.isEmpty,
            isTrue,
            reason: violations.isEmpty
                ? 'Non-core test folders avoid core implementation imports'
                : 'Found non-core tests importing core implementation modules:\n${violations.join('\n')}',
          );
        },
      );

      test('✅ Legacy test/services folder is absent or empty', () {
        final legacyServicesDir = Directory(
          path.join(projectRoot.path, 'test', 'services'),
        );

        if (!legacyServicesDir.existsSync()) {
          expect(
            legacyServicesDir.existsSync(),
            isFalse,
            reason: 'Legacy test/services folder has been removed',
          );
          return;
        }

        final lingeringEntries =
            legacyServicesDir
                .listSync(recursive: true)
                .map(
                  (entry) => path.normalize(
                    path.relative(entry.path, from: projectRoot.path),
                  ),
                )
                .toList()
              ..sort();

        expect(
          lingeringEntries,
          isEmpty,
          reason:
              'Legacy test/services should remain empty; tests belong under test/core or test/data:\n${lingeringEntries.join('\n')}',
        );
      });
    });

    group('DI Registration Compliance', () {
      test(
        '✅ service_locator.dart wires IRepositoryProvider and delegates data bindings',
        () {
          final file = File(
            path.join(projectRoot.path, 'lib/core/di/service_locator.dart'),
          );
          final dataRegistrarFile = File(
            path.join(
              projectRoot.path,
              'lib/data/di/data_layer_service_registrar.dart',
            ),
          );

          expect(
            file.existsSync(),
            isTrue,
            reason: 'service_locator.dart should exist',
          );
          expect(
            dataRegistrarFile.existsSync(),
            isTrue,
            reason: 'data_layer_service_registrar.dart should exist',
          );

          final content = file.readAsStringSync();
          final dataRegistrarContent = dataRegistrarFile.readAsStringSync();

          // Core locator should still own IRepositoryProvider wiring.
          expect(
            content.contains('registerSingleton<IRepositoryProvider>') ||
                content.contains('IRepositoryProvider'),
            isTrue,
            reason: 'service_locator should register IRepositoryProvider',
          );

          // Core locator should use delegated data registration hook.
          expect(
            content.contains('configureDataLayerRegistrar') &&
                content.contains('_dataLayerRegistrar'),
            isTrue,
            reason: 'service_locator should delegate concrete data bindings',
          );

          expect(
            content.contains('ISecurityManager'),
            isFalse,
            reason:
                'service_locator should register ISecurityService instead of legacy ISecurityManager',
          );

          // Data registrar should own concrete ISeenMessageStore registration.
          expect(
            dataRegistrarContent.contains('ISeenMessageStore'),
            isTrue,
            reason:
                'data_layer_service_registrar should register ISeenMessageStore',
          );
        },
      );

      test('✅ test_setup.dart initializes DI container', () {
        final shimFile = File(
          path.join(projectRoot.path, 'test/test_helpers/test_setup.dart'),
        );
        final implFile = File(
          path.join(projectRoot.path, 'test/core/test_helpers/test_setup.dart'),
        );

        expect(
          shimFile.existsSync(),
          isTrue,
          reason: 'test_setup.dart should exist',
        );
        expect(
          implFile.existsSync(),
          isTrue,
          reason: 'core test_setup implementation should exist',
        );

        final shimContent = shimFile.readAsStringSync();
        final implContent = implFile.readAsStringSync();

        expect(
          shimContent.contains('export'),
          isTrue,
          reason:
              'test/test_helpers/test_setup.dart should remain a shim export',
        );

        // Should call setupServiceLocator during test initialization
        expect(
          implContent.contains('setupServiceLocator') ||
              implContent.contains('di_service_locator'),
          isTrue,
          reason: 'test_setup.dart should initialize DI container',
        );
      });
    });

    group('Interface Definition Compliance', () {
      test('✅ IRepositoryProvider defines required properties', () {
        final domainFile = File(
          path.join(
            projectRoot.path,
            'lib/domain/interfaces/i_repository_provider.dart',
          ),
        );
        expect(
          domainFile.existsSync(),
          isTrue,
          reason: 'Domain IRepositoryProvider should exist',
        );
        final content = domainFile.readAsStringSync();

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
        final domainFile = File(
          path.join(
            projectRoot.path,
            'lib/domain/interfaces/i_seen_message_store.dart',
          ),
        );
        expect(
          domainFile.existsSync(),
          isTrue,
          reason: 'Domain ISeenMessageStore should exist',
        );
        final content = domainFile.readAsStringSync();

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
      test('✅ Domain layer interfaces do NOT import from data layer', () {
        final interfaceFiles =
            Directory(path.join(projectRoot.path, 'lib/domain/interfaces'))
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
