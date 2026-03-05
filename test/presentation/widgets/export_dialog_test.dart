import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/interfaces/i_export_service.dart';
import 'package:pak_connect/domain/models/export_bundle.dart';
import 'package:pak_connect/presentation/widgets/export_dialog.dart';

class _FakeExportService implements IExportService {
  ExportResult Function({
    required String userPassphrase,
    required ExportType exportType,
    String? customPath,
  })?
  onCreateExport;

  int createExportCalls = 0;
  String? lastPassphrase;
  ExportType? lastExportType;
  String? lastCustomPath;

  @override
  Future<ExportResult> createExport({
    required String userPassphrase,
    String? customPath,
    ExportType exportType = ExportType.full,
  }) async {
    createExportCalls++;
    lastPassphrase = userPassphrase;
    lastExportType = exportType;
    lastCustomPath = customPath;

    final callback = onCreateExport;
    if (callback == null) {
      return ExportResult.failure('Export callback not configured');
    }
    return callback(
      userPassphrase: userPassphrase,
      exportType: exportType,
      customPath: customPath,
    );
  }

  @override
  Future<int> cleanupOldExports({int keepCount = 3}) async => 0;

  @override
  Future<String> getDefaultExportDirectory() async => Directory.systemTemp.path;

  @override
  Future<List<ExportBundle>> listAvailableExports() async => const [];
}

Future<void> _pumpExportDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const ExportDialog(),
                );
              },
              child: const Text('Open Export Dialog'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open Export Dialog'));
  await tester.pumpAndSettle();
}

Future<void> _enterMatchingPassphrases(
  WidgetTester tester, {
  String passphrase = 'StrongPassphrase#123',
}) async {
  final fields = find.byType(TextFormField);
  expect(fields, findsNWidgets(2));

  await tester.enterText(fields.at(0), passphrase);
  await tester.enterText(fields.at(1), passphrase);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final getIt = GetIt.instance;
  late _FakeExportService exportService;
  late Directory tempDir;
  late File bundleFile;

  setUp(() async {
    await getIt.reset();
    exportService = _FakeExportService();
    getIt.registerSingleton<IExportService>(exportService);

    tempDir = await Directory.systemTemp.createTemp('export_dialog_test_');
    bundleFile = File(
      '${tempDir.path}${Platform.pathSeparator}backup.pakconnect',
    )..writeAsStringSync('encrypted-backup');
  });

  tearDown(() async {
    await getIt.reset();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('validates required passphrase fields before exporting', (
    tester,
  ) async {
    exportService.onCreateExport =
        ({required userPassphrase, required exportType, String? customPath}) {
          return ExportResult.success(
            bundlePath: bundleFile.path,
            bundleSize: 128,
            exportType: exportType,
          );
        };

    await _pumpExportDialog(tester);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Create Backup'));
    await tester.pump();

    expect(find.text('Passphrase is required'), findsOneWidget);
    expect(find.text('Please confirm your passphrase'), findsOneWidget);
    expect(exportService.createExportCalls, 0);
  });

  testWidgets(
    'exports successfully with selected export type and copy action',
    (tester) async {
      exportService.onCreateExport =
          ({required userPassphrase, required exportType, String? customPath}) {
            return ExportResult.success(
              bundlePath: bundleFile.path,
              bundleSize: 2048,
              exportType: exportType,
              recordCount: 27,
            );
          };

      await _pumpExportDialog(tester);

      await tester.tap(find.byType(DropdownButtonFormField<ExportType>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contacts Only').last);
      await tester.pumpAndSettle();

      await _enterMatchingPassphrases(tester, passphrase: 'contacts-backup');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Backup'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(exportService.createExportCalls, 1);
      expect(exportService.lastPassphrase, 'contacts-backup');
      expect(exportService.lastExportType, ExportType.contactsOnly);

      expect(find.text('Contacts Only Created!'), findsOneWidget);
      expect(find.text('Successfully exported 27 records'), findsOneWidget);

      await tester.tap(find.text('Copy Path'));
      await tester.pump();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'shows service failure message when export result is unsuccessful',
    (tester) async {
      exportService.onCreateExport =
          ({required userPassphrase, required exportType, String? customPath}) {
            return ExportResult.failure('Disk full');
          };

      await _pumpExportDialog(tester);
      await _enterMatchingPassphrases(tester, passphrase: 'disk-full-case');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Create Backup'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(exportService.createExportCalls, 1);
      expect(find.text('Disk full'), findsOneWidget);
    },
  );
}
