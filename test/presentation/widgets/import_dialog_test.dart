import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/interfaces/i_import_service.dart';
import 'package:pak_connect/domain/models/export_bundle.dart';
import 'package:pak_connect/presentation/widgets/import_dialog.dart';

class _FakeImportService implements IImportService {
  Map<String, dynamic> Function({
    required String bundlePath,
    required String userPassphrase,
  })?
  onValidateBundle;

  ImportResult Function({
    required String bundlePath,
    required String userPassphrase,
    required bool clearExistingData,
  })?
  onImportBundle;

  int validateCalls = 0;
  int importCalls = 0;
  String? lastValidateBundlePath;
  String? lastValidatePassphrase;
  String? lastImportBundlePath;
  String? lastImportPassphrase;
  bool? lastClearExistingData;

  @override
  Future<Map<String, dynamic>> validateBundle({
    required String bundlePath,
    required String userPassphrase,
  }) async {
    validateCalls++;
    lastValidateBundlePath = bundlePath;
    lastValidatePassphrase = userPassphrase;

    final callback = onValidateBundle;
    if (callback == null) {
      return {'valid': false, 'error': 'Validation callback not configured'};
    }
    return callback(bundlePath: bundlePath, userPassphrase: userPassphrase);
  }

  @override
  Future<ImportResult> importBundle({
    required String bundlePath,
    required String userPassphrase,
    bool clearExistingData = true,
  }) async {
    importCalls++;
    lastImportBundlePath = bundlePath;
    lastImportPassphrase = userPassphrase;
    lastClearExistingData = clearExistingData;

    final callback = onImportBundle;
    if (callback == null) {
      return ImportResult.failure('Import callback not configured');
    }
    return callback(
      bundlePath: bundlePath,
      userPassphrase: userPassphrase,
      clearExistingData: clearExistingData,
    );
  }
}

class _FakeFilePicker extends FilePicker {
  FilePickerResult? nextResult;
  Object? nextError;
  int pickCalls = 0;
  String? lastDialogTitle;
  List<String>? lastAllowedExtensions;
  FileType? lastType;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus p1)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    pickCalls++;
    lastDialogTitle = dialogTitle;
    lastAllowedExtensions = allowedExtensions;
    lastType = type;
    if (nextError != null) {
      throw nextError!;
    }
    return nextResult;
  }
}

Future<void> _pumpImportDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => const ImportDialog(),
                );
              },
              child: const Text('Open Import Dialog'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open Import Dialog'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final getIt = GetIt.instance;
  late _FakeImportService importService;
  late _FakeFilePicker filePicker;
  late Directory tempDir;
  late File backupFile;

  setUp(() async {
    await getIt.reset();
    importService = _FakeImportService();
    getIt.registerSingleton<IImportService>(importService);

    filePicker = _FakeFilePicker();
    FilePicker.platform = filePicker;

    tempDir = await Directory.systemTemp.createTemp('import_dialog_test_');
    backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}backup_test.pakconnect',
    )..writeAsStringSync('backup-payload');
    filePicker.nextResult = FilePickerResult([
      PlatformFile(
        path: backupFile.path,
        name: backupFile.uri.pathSegments.last,
        size: 128,
      ),
    ]);
  });

  tearDown(() async {
    await getIt.reset();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('picks file, validates bundle, and completes successful import', (
    tester,
  ) async {
    importService.onValidateBundle =
        ({required bundlePath, required userPassphrase}) {
          return {
            'valid': true,
            'username': 'Alice',
            'device_id': 'device-123',
            'timestamp': '2026-03-05T09:20:00Z',
            'total_records': 42,
          };
        };

    importService.onImportBundle =
        ({
          required bundlePath,
          required userPassphrase,
          required clearExistingData,
        }) {
          return ImportResult.success(recordsRestored: 42);
        };

    await _pumpImportDialog(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select Backup File'));
    await tester.pumpAndSettle();

    expect(filePicker.pickCalls, 1);
    expect(filePicker.lastType, FileType.custom);
    expect(filePicker.lastAllowedExtensions, ['pakconnect']);
    expect(find.text('backup_test.pakconnect'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'import-passphrase');
    await tester.pump();

    expect(find.text('Validate Backup'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(importService.validateCalls, 1);
    expect(importService.lastValidateBundlePath, backupFile.path);
    expect(importService.lastValidatePassphrase, 'import-passphrase');
    expect(find.text('Backup Validated'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.text('Import Data'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm Import'), findsOneWidget);

    await tester.tap(find.text('Import Anyway'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(importService.importCalls, 1);
    expect(importService.lastImportBundlePath, backupFile.path);
    expect(importService.lastImportPassphrase, 'import-passphrase');
    expect(importService.lastClearExistingData, isTrue);
    expect(find.text('Import Successful!'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('shows validation error from invalid bundle response', (
    tester,
  ) async {
    importService.onValidateBundle =
        ({required bundlePath, required userPassphrase}) {
          return {'valid': false, 'error': 'Wrong passphrase'};
        };

    await _pumpImportDialog(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select Backup File'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bad-passphrase');
    await tester.pump();

    expect(find.text('Validate Backup'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(importService.validateCalls, 1);
    expect(importService.importCalls, 0);
    expect(find.text('Wrong passphrase'), findsOneWidget);
  });

  testWidgets('shows validation exception message when validate throws', (
    tester,
  ) async {
    importService.onValidateBundle =
        ({required bundlePath, required userPassphrase}) {
          throw StateError('corrupt backup');
        };

    await _pumpImportDialog(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select Backup File'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'exception-pass');
    await tester.pump();

    expect(find.text('Validate Backup'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(importService.validateCalls, 1);
    expect(find.textContaining('Validation failed:'), findsOneWidget);
  });

  testWidgets('respects confirmation cancel and shows import failure message', (
    tester,
  ) async {
    importService.onValidateBundle =
        ({required bundlePath, required userPassphrase}) {
          return {
            'valid': true,
            'username': 'Bob',
            'device_id': 'device-321',
            'timestamp': '2026-03-05T10:10:00Z',
            'total_records': 12,
          };
        };

    importService.onImportBundle =
        ({
          required bundlePath,
          required userPassphrase,
          required clearExistingData,
        }) {
          return ImportResult.failure('Import payload is incompatible');
        };

    await _pumpImportDialog(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select Backup File'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'retry-case');
    await tester.pump();

    expect(find.text('Validate Backup'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    expect(importService.importCalls, 0);

    await tester.tap(find.text('Import Data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import Anyway'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(importService.importCalls, 1);
    expect(find.text('Import payload is incompatible'), findsOneWidget);
  });

  testWidgets('shows picker failure message when file selection throws', (
    tester,
  ) async {
    filePicker.nextError = StateError('picker unavailable');

    await _pumpImportDialog(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Select Backup File'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(filePicker.pickCalls, 1);
    expect(find.textContaining('Failed to select file:'), findsOneWidget);
  });
}
