import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test_helpers/test_service_registry.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart'
    show clearRuntimeAppServicesForTesting;
import 'package:pak_connect/presentation/screens/qr_contact_screen.dart';
import 'package:qr_barcode_dialog_scanner/qr_barcode_dialog_scanner.dart';

class _FakeUserPreferences extends Fake implements IUserPreferences {
  _FakeUserPreferences(this.userName);

  final String userName;

  @override
  Future<String> getUserName() async => userName;

  @override
  Future<void> setUserName(String name) async {}

  @override
  Future<String> getOrCreateDeviceId() async => 'device-1';

  @override
  Future<String?> getDeviceId() async => 'device-1';

  @override
  Future<Map<String, String>> getOrCreateKeyPair() async => {
    'public': 'pub',
    'private': 'priv',
  };

  @override
  Future<String> getPublicKey() async => 'pub';

  @override
  Future<String> getPrivateKey() async => 'priv';

  @override
  Future<bool> getHintBroadcastEnabled() async => true;

  @override
  Future<void> setHintBroadcastEnabled(bool enabled) async {}

  @override
  Future<void> regenerateKeyPair() async {}
}

class _FakeIntroHintRepository extends Fake implements IIntroHintRepository {
  final List<EphemeralDiscoveryHint> savedMyHints = <EphemeralDiscoveryHint>[];
  final Map<String, EphemeralDiscoveryHint> savedScannedHints =
      <String, EphemeralDiscoveryHint>{};
  int cleanupCalls = 0;

  @override
  Future<List<EphemeralDiscoveryHint>> getMyActiveHints() async =>
      List<EphemeralDiscoveryHint>.from(savedMyHints);

  @override
  Future<void> saveMyActiveHint(EphemeralDiscoveryHint hint) async {
    savedMyHints.add(hint);
  }

  @override
  Future<Map<String, EphemeralDiscoveryHint>> getScannedHints() async =>
      Map<String, EphemeralDiscoveryHint>.from(savedScannedHints);

  @override
  Future<void> saveScannedHint(String key, EphemeralDiscoveryHint hint) async {
    savedScannedHints[key] = hint;
  }

  @override
  Future<void> removeScannedHint(String key) async {
    savedScannedHints.remove(key);
  }

  @override
  Future<void> cleanupExpiredHints() async {
    cleanupCalls++;
  }

  @override
  Future<EphemeralDiscoveryHint?> getMostRecentActiveHint() async {
    if (savedMyHints.isEmpty) return null;
    return savedMyHints.last;
  }

  @override
  Future<void> clearAll() async {
    savedMyHints.clear();
    savedScannedHints.clear();
  }
}

Future<void> _pumpQrScreen(
  WidgetTester tester, {
  required _FakeUserPreferences userPreferences,
  required _FakeIntroHintRepository introHintRepository,
  QrScannerLauncher? scannerLauncher,
}) async {
  final locator = getIt;
  await locator.reset();
  clearRuntimeAppServicesForTesting();
  locator.registerSingleton<IUserPreferences>(userPreferences);
  locator.registerSingleton<IIntroHintRepository>(introHintRepository);

  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await locator.reset();
    clearRuntimeAppServicesForTesting();
  });

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            QRContactScreen(scannerLauncher: scannerLauncher),
                      ),
                    );
                  },
                  child: const Text('Open QR'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open QR'));
  await tester.pumpAndSettle();
}

ScannerResult _scannerResult(String code) => ScannerResult.fromJson({
  'code': code,
  'format': 'BarcodeFormat.qrCode',
  'timestamp': DateTime(2026, 1, 1).toIso8601String(),
});

EphemeralDiscoveryHint _hint({
  required String displayName,
  required DateTime expiresAt,
}) {
  return EphemeralDiscoveryHint(
    hintBytes: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
    createdAt: DateTime(2026, 1, 1),
    expiresAt: expiresAt,
    displayName: displayName,
  );
}

void main() {
  group('QRContactScreen', () {
    testWidgets('generates and displays QR data on load', (tester) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
      );

      expect(find.text('Share Your QR'), findsOneWidget);
      expect(find.text('Show this QR to your contact'), findsOneWidget);
      expect(find.text('Scan Their QR'), findsOneWidget);
      expect(introRepo.savedMyHints.length, 1);
      expect(introRepo.savedMyHints.first.displayName, 'Alice');
    });

    testWidgets('regenerate creates a new hint and shows confirmation', (
      tester,
    ) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
      );

      final firstHintId = introRepo.savedMyHints.first.hintId;

      await tester.tap(find.text('Generate New QR'));
      await tester.pumpAndSettle();

      expect(introRepo.savedMyHints.length, 2);
      expect(introRepo.savedMyHints.last.hintId, isNot(firstHintId));
      expect(find.text('New QR code generated'), findsOneWidget);
    });

    testWidgets('copy QR data calls clipboard and shows snackbar', (tester) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();
      var clipboardSet = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardSet = true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
      );

      await tester.tap(find.text('Copy QR Data'));
      await tester.pumpAndSettle();

      expect(clipboardSet, isTrue);
      expect(find.text('QR data copied'), findsOneWidget);
    });

    testWidgets('invalid scanned QR shows error snackbar', (tester) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
        scannerLauncher: (_) async => _scannerResult('invalid-data'),
      );

      await tester.tap(find.text('Scan Their QR'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid QR code format'), findsOneWidget);
    });

    testWidgets('expired scanned QR shows expiry snackbar', (tester) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();
      final expired = _hint(
        displayName: 'Bob',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
        scannerLauncher: (_) async => _scannerResult(expired.toQRString()),
      );

      await tester.tap(find.text('Scan Their QR'));
      await tester.pumpAndSettle();

      expect(find.text('QR code expired - ask for a new one'), findsOneWidget);
    });

    testWidgets('valid scan opens confirmation and cancel returns to share UI', (
      tester,
    ) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();
      final valid = _hint(
        displayName: 'Bob',
        expiresAt: DateTime.now().add(const Duration(days: 7)),
      );

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
        scannerLauncher: (_) async => _scannerResult(valid.toQRString()),
      );

      await tester.tap(find.text('Scan Their QR'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm Contact'), findsOneWidget);
      expect(find.text('Add Contact'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.textContaining('Hint:'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Share Your QR'), findsOneWidget);
      expect(find.text('Add Contact'), findsNothing);
    });

    testWidgets('save hint stores scanned hint and pops the screen', (
      tester,
    ) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();
      final valid = _hint(
        displayName: 'Charlie',
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
        scannerLauncher: (_) async => _scannerResult(valid.toQRString()),
      );

      await tester.tap(find.text('Scan Their QR'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save Hint'));
      await tester.pumpAndSettle();

      expect(introRepo.savedScannedHints.containsKey(valid.hintHex), isTrue);
      expect(find.byType(QRContactScreen), findsNothing);
      expect(find.text('Open QR'), findsOneWidget);
    });

    testWidgets('dispose cleans up expired hints', (tester) async {
      final prefs = _FakeUserPreferences('Alice');
      final introRepo = _FakeIntroHintRepository();

      await _pumpQrScreen(
        tester,
        userPreferences: prefs,
        introHintRepository: introRepo,
      );

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(introRepo.cleanupCalls, 1);
    });
  });
}
