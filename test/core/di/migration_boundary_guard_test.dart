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
        path.normalize('lib/domain/services/simple_crypto_verification_helper.dart'),
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

    test('presentation code does not import get_it or use GetIt directly', () {
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
            : 'Presentation must not depend on get_it directly:\n${violations.join('\n')}',
      );
    });

    test('presentation imports service_locator only through di_providers.dart', () {
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
    });
  });
}
