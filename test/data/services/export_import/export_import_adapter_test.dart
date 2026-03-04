import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' hide equals;
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/services/export_import/export_bundle.dart';
import 'package:pak_connect/data/services/export_import/export_service_adapter.dart';
import 'package:pak_connect/data/services/export_import/import_service_adapter.dart';

import '../../../test_helpers/test_setup.dart';

void main() {
  const exportAdapter = ExportServiceAdapter();
  const importAdapter = ImportServiceAdapter();

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'phase3_export_import_adapters',
    );
  });

  setUp(() async {
    await TestSetup.configureTestDatabase(
      label: 'phase3_export_import_adapters',
    );
    await DatabaseHelper.database;
  });

  tearDown(() async {
    await DatabaseHelper.close();
  });

  group('ExportServiceAdapter', () {
    test(
      'createExport forwards to service and returns validation failure',
      () async {
        final result = await exportAdapter.createExport(
          userPassphrase: 'short',
          exportType: ExportType.contactsOnly,
        );

        expect(result.success, isFalse);
        expect(result.errorMessage, contains('Weak passphrase'));
      },
    );

    test(
      'getDefaultExportDirectory/listAvailableExports/cleanupOldExports forward correctly',
      () async {
        final dbPath = await DatabaseHelper.getDatabasePath();
        final expectedExportDir = join(dirname(dbPath), 'exports');

        final exportDir = await exportAdapter.getDefaultExportDirectory();
        expect(exportDir, equals(expectedExportDir));

        final exports = await exportAdapter.listAvailableExports();
        expect(exports, isEmpty);

        final deleted = await exportAdapter.cleanupOldExports(keepCount: 1);
        expect(deleted, equals(0));
      },
    );
  });

  group('ImportServiceAdapter', () {
    test('validateBundle forwards to service', () async {
      final result = await importAdapter.validateBundle(
        bundlePath: join('missing', 'bundle.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result['valid'], isFalse);
      expect(result['error'], contains('not found'));
    });

    test('importBundle forwards to service', () async {
      final result = await importAdapter.importBundle(
        bundlePath: join('missing', 'bundle.pakconnect'),
        userPassphrase: 'StrongPassphrase123!',
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Bundle file not found'));
    });
  });
}
