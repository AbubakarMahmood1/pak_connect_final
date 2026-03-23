import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('Migration boundary guardrails', () {
    late Directory projectRoot;

    setUpAll(() {
      projectRoot = Directory.current;
    });

    Iterable<File> dartFilesUnder(String relativeDirectory) sync* {
      final dir = Directory(path.join(projectRoot.path, relativeDirectory));
      if (!dir.existsSync()) {
        return;
      }

      yield* dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
    }

    String relativePathFor(File file) =>
        path.normalize(path.relative(file.path, from: projectRoot.path));

    test('SimpleCrypto direct runtime usage is quarantined', () {
      final allowedFiles = <String>{
        path.normalize('lib/domain/services/simple_crypto.dart'),
      };

      final violations = <String>[];

      for (final file in dartFilesUnder('lib')) {
        final relativePath = relativePathFor(file);
        final lines = file.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('SimpleCrypto.')) {
            continue;
          }
          if (allowedFiles.contains(relativePath)) {
            continue;
          }
          violations.add('$relativePath:${i + 1} -> ${lines[i].trim()}');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? 'Direct SimpleCrypto usage is quarantined to the transitional facade.'
            : 'Unexpected direct SimpleCrypto usage found:\n${violations.join('\n')}',
      );
    });

    test('legacy compatibility service usage is quarantined', () {
      final allowedFiles = <String>{
        path.normalize(
          'lib/domain/services/legacy_crypto_migration_policy.dart',
        ),
      };
      final violations = <String>[];

      for (final file in dartFilesUnder('lib')) {
        final relativePath = relativePathFor(file);
        final lines = file.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('LegacyPayloadCompatService.')) {
            continue;
          }
          if (allowedFiles.contains(relativePath)) {
            continue;
          }
          violations.add('$relativePath:${i + 1} -> ${lines[i].trim()}');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? 'Legacy payload compatibility is boxed behind the migration policy seam.'
            : 'Unexpected direct LegacyPayloadCompatService usage found:\n${violations.join('\n')}',
      );
    });

    test('presentation code does not import get_it or use locator globals directly', () {
      final violations = <String>[];

      for (final file in dartFilesUnder('lib/presentation')) {
        final relativePath = relativePathFor(file);
        final lines = file.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final trimmed = line.trim();
          final usesGetIt =
              trimmed.contains("package:get_it/get_it.dart") ||
              trimmed.contains('GetIt.') ||
              trimmed.contains('getIt.');
          if (!usesGetIt) {
            continue;
          }
          violations.add('$relativePath:${i + 1} -> $trimmed');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? 'Presentation code stays behind AppServices/DI helper boundaries.'
            : 'Presentation must not depend on locator globals directly:\n${violations.join('\n')}',
      );
    });

    test('runtime locator usage is centralized to service_locator.dart', () {
      final allowedFiles = <String>{
        path.normalize('lib/core/di/service_locator.dart'),
      };
      final violations = <String>[];

      for (final file in dartFilesUnder('lib')) {
        final relativePath = relativePathFor(file);
        final lines = file.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trim();
          if (trimmed.startsWith('//') || trimmed.startsWith('///')) {
            continue;
          }

          final usesRuntimeLocator =
              trimmed.contains("package:get_it/get_it.dart") ||
              trimmed.contains('GetIt.') ||
              trimmed.contains('getIt.');
          if (!usesRuntimeLocator) {
            continue;
          }
          if (allowedFiles.contains(relativePath)) {
            continue;
          }
          violations.add('$relativePath:${i + 1} -> $trimmed');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? 'Runtime locator usage is boxed into the service-locator boundary.'
            : 'Unexpected runtime locator usage found:\n${violations.join('\n')}',
      );
    });

    test('service_locator does not publish runtime services into the bootstrap registry', () {
      final file = File(
        path.join(projectRoot.path, 'lib', 'core', 'di', 'service_locator.dart'),
      );
      final forbiddenSnippets = <String>{
        'registerSingleton<AppServices>(',
        'unregister<AppServices>(',
        'registerSingleton<ISecurityService>(',
        'registerSingleton<IMeshBleService>(',
        'registerSingleton<IConnectionService>(',
        'registerSingleton<IBLEServiceFacade>(',
        'registerSingleton<MeshNetworkingService>(',
        'registerSingleton<IMeshNetworkingService>(',
        'registerSingleton<MeshRelayCoordinator>(',
        'registerSingleton<MeshQueueSyncCoordinator>(',
        'registerSingleton<MeshNetworkHealthMonitor>(',
      };
      final violations = <String>[];
      final lines = file.readAsLinesSync();

      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) {
          continue;
        }

        if (forbiddenSnippets.any(trimmed.contains)) {
          violations.add('service_locator.dart:${i + 1} -> $trimmed');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: violations.isEmpty
            ? 'Runtime services are published through AppRuntimeServicesRegistry, not the bootstrap registry.'
            : 'service_locator.dart still registers runtime services in the bootstrap registry:\n${violations.join('\n')}',
      );
    });

    test('repo no longer depends on package:get_it', () {
      final pubspec = File(path.join(projectRoot.path, 'pubspec.yaml'));
      final content = pubspec.readAsStringSync();

      expect(
        content.contains(RegExp(r'^\s*get_it\s*:', multiLine: true)),
        isFalse,
        reason: 'pubspec.yaml should not declare get_it after checkpoint 7.',
      );
    });

    test(
      'presentation imports service_locator only through di_providers.dart',
      () {
        final allowedFile = path.normalize(
          'lib/presentation/providers/di_providers.dart',
        );
        final violations = <String>[];

        for (final file in dartFilesUnder('lib/presentation')) {
          final relativePath = relativePathFor(file);
          final lines = file.readAsLinesSync();

          for (var i = 0; i < lines.length; i++) {
            final trimmed = lines[i].trim();
            final importsServiceLocator =
                trimmed.startsWith('import ') &&
                trimmed.contains('core/di/service_locator.dart');
            if (!importsServiceLocator) {
              continue;
            }
            if (relativePath == allowedFile) {
              continue;
            }
            violations.add('$relativePath:${i + 1} -> $trimmed');
          }
        }

        expect(
          violations,
          isEmpty,
          reason: violations.isEmpty
              ? 'Only di_providers.dart bridges presentation to the locator.'
              : 'Unexpected presentation service-locator imports found:\n${violations.join('\n')}',
        );
      },
    );

    test(
      'pairing lifecycle code does not reach into low-level crypto primitives directly',
      () {
        final pairingFiles = <String>{
          path.normalize('lib/data/services/ble_state_coordinator.dart'),
          path.normalize('lib/data/services/ble_state_manager.dart'),
          path.normalize(
            'lib/data/services/contact_status_sync_controller.dart',
          ),
          path.normalize('lib/data/services/pairing_failure_handler.dart'),
          path.normalize('lib/data/services/pairing_flow_controller.dart'),
          path.normalize('lib/data/services/pairing_lifecycle_service.dart'),
          path.normalize(
            'lib/presentation/controllers/chat_pairing_dialog_controller.dart',
          ),
        };

        final violations = <String>[];

        for (final file in dartFilesUnder('lib')) {
          final relativePath = relativePathFor(file);
          if (!pairingFiles.contains(relativePath)) {
            continue;
          }

          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            final trimmed = lines[i].trim();
            final reachesIntoLowLevelCrypto =
                trimmed.contains('ConversationCryptoService.') ||
                trimmed.contains('SigningCryptoService.computeSharedSecret') ||
                trimmed.contains("conversation_crypto_service.dart");
            if (!reachesIntoLowLevelCrypto) {
              continue;
            }
            violations.add('$relativePath:${i + 1} -> $trimmed');
          }
        }

        expect(
          violations,
          isEmpty,
          reason: violations.isEmpty
              ? 'Pairing/shared-secret lifecycle code stays behind PairingCryptoService.'
              : 'Pairing lifecycle must not call low-level crypto primitives directly:\n${violations.join('\n')}',
        );
      },
    );
  });
}
