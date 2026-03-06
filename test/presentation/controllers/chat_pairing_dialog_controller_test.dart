import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_pairing_state_manager.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/presentation/controllers/chat_pairing_dialog_controller.dart';

class _FakePairingStateManager extends Fake implements IPairingStateManager {
  int clearCalls = 0;
  String pairingCode = '1234';
  bool completePairingResult = false;
  bool confirmUpgradeResult = true;
  final List<String> completePairingInputs = <String>[];
  final List<MapEntry<String, SecurityLevel>> upgradeCalls =
      <MapEntry<String, SecurityLevel>>[];

  @override
  void clearPairing() {
    clearCalls++;
  }

  @override
  String generatePairingCode() => pairingCode;

  @override
  Future<bool> completePairing(String theirCode) async {
    completePairingInputs.add(theirCode);
    return completePairingResult;
  }

  @override
  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    upgradeCalls.add(MapEntry<String, SecurityLevel>(publicKey, newLevel));
    return confirmUpgradeResult;
  }
}

class _FakeConnectionService extends Fake implements IConnectionService {
  final List<bool> pairingProgressEvents = <bool>[];

  @override
  void setPairingInProgress(bool isInProgress) {
    pairingProgressEvents.add(isInProgress);
  }
}

class _FakeContactRepository extends Fake implements IContactRepository {
  final List<MapEntry<String, String>> savedContacts =
      <MapEntry<String, String>>[];
  final List<String> verifiedContacts = <String>[];
  final Map<String, String> cachedSecrets = <String, String>{};
  bool throwOnSave = false;

  @override
  Future<void> saveContact(String publicKey, String displayName) async {
    if (throwOnSave) throw StateError('save failed');
    savedContacts.add(MapEntry<String, String>(publicKey, displayName));
  }

  @override
  Future<void> markContactVerified(String publicKey) async {
    verifiedContacts.add(publicKey);
  }

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    cachedSecrets[publicKey] = sharedSecret;
  }
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _publicKeyHexFromPrivateInt(int privateValue) {
  final curve = ECCurve_secp256r1();
  final publicPoint = curve.G * BigInt.from(privateValue);
  return _bytesToHex(publicPoint!.getEncoded(false));
}

void _initializeSigningForTests() {
  final privateKey = BigInt.from(42);
  final privateKeyHex = privateKey.toRadixString(16).padLeft(64, '0');
  final publicKeyHex = _publicKeyHexFromPrivateInt(42);
  SimpleCrypto.initializeSigning(privateKeyHex, publicKeyHex);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SimpleCrypto.clear();
    SimpleCrypto.clearAllConversationKeys();
  });

  tearDown(() {
    SimpleCrypto.clear();
    SimpleCrypto.clearAllConversationKeys();
  });

  group('ChatPairingDialogController', () {
    testWidgets('prevents duplicate pairing request while dialog is active', (
      tester,
    ) async {
      late BuildContext context;
      late NavigatorState navigator;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              navigator = Navigator.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );

      final stateManager = _FakePairingStateManager();
      final connectionService = _FakeConnectionService();
      final contactRepository = _FakeContactRepository();
      final controller = ChatPairingDialogController(
        stateManager: stateManager,
        connectionService: connectionService,
        contactRepository: contactRepository,
        context: context,
        navigator: navigator,
        getTheirPersistentKey: () => null,
      );

      final firstRequest = controller.userRequestedPairing();
      final secondRequest = await controller.userRequestedPairing();

      expect(secondRequest, isFalse);

      await tester.pumpAndSettle();
      expect(find.text('Secure Pairing'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await firstRequest, isTrue);
      expect(stateManager.clearCalls, 2);
      expect(connectionService.pairingProgressEvents, <bool>[true, false]);
    });

    testWidgets('completes successful pairing and runs security upgrade', (
      tester,
    ) async {
      late BuildContext context;
      late NavigatorState navigator;
      bool? pairingCompleted;
      String? pairingSuccessMessage;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              navigator = Navigator.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );

      final stateManager = _FakePairingStateManager()
        ..pairingCode = '4321'
        ..completePairingResult = true;
      final connectionService = _FakeConnectionService();
      final contactRepository = _FakeContactRepository();
      final persistentKey = _publicKeyHexFromPrivateInt(43);

      final controller = ChatPairingDialogController(
        stateManager: stateManager,
        connectionService: connectionService,
        contactRepository: contactRepository,
        context: context,
        navigator: navigator,
        getTheirPersistentKey: () => persistentKey,
        onPairingCompleted: (success) => pairingCompleted = success,
        onPairingSuccess: (message) => pairingSuccessMessage = message,
      );

      final requested = controller.userRequestedPairing();

      await tester.pumpAndSettle();
      expect(find.text('Secure Pairing'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '9999');
      await tester.pumpAndSettle();

      expect(await requested, isTrue);
      expect(stateManager.completePairingInputs, <String>['9999']);
      expect(stateManager.upgradeCalls.length, 1);
      expect(stateManager.upgradeCalls.first.key, persistentKey);
      expect(stateManager.upgradeCalls.first.value, SecurityLevel.medium);
      expect(pairingCompleted, isTrue);
      expect(pairingSuccessMessage, 'Pairing successful');
      expect(connectionService.pairingProgressEvents, <bool>[true, false]);
    });

    testWidgets('adds verified contact and caches shared secret', (
      tester,
    ) async {
      late BuildContext context;
      late NavigatorState navigator;
      String? successMessage;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              navigator = Navigator.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );

      _initializeSigningForTests();
      final peerPublicKey = _publicKeyHexFromPrivateInt(99);
      final stateManager = _FakePairingStateManager();
      final connectionService = _FakeConnectionService();
      final contactRepository = _FakeContactRepository();
      final controller = ChatPairingDialogController(
        stateManager: stateManager,
        connectionService: connectionService,
        contactRepository: contactRepository,
        context: context,
        navigator: navigator,
        getTheirPersistentKey: () => null,
        onPairingSuccess: (message) => successMessage = message,
      );

      await controller.addAsVerifiedContact(peerPublicKey, 'Peer User');

      expect(contactRepository.savedContacts.length, 1);
      expect(contactRepository.savedContacts.first.key, peerPublicKey);
      expect(contactRepository.savedContacts.first.value, 'Peer User');
      expect(contactRepository.verifiedContacts, <String>[peerPublicKey]);
      expect(
        contactRepository.cachedSecrets.containsKey(peerPublicKey),
        isTrue,
      );
      expect(SimpleCrypto.hasConversationKey(peerPublicKey), isTrue);
      expect(successMessage, 'Added Peer User as verified contact');
    });

    testWidgets('handles empty key and repository save failures', (
      tester,
    ) async {
      late BuildContext context;
      late NavigatorState navigator;
      String? errorMessage;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              context = ctx;
              navigator = Navigator.of(ctx);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );

      final stateManager = _FakePairingStateManager();
      final connectionService = _FakeConnectionService();
      final contactRepository = _FakeContactRepository()..throwOnSave = true;
      final controller = ChatPairingDialogController(
        stateManager: stateManager,
        connectionService: connectionService,
        contactRepository: contactRepository,
        context: context,
        navigator: navigator,
        getTheirPersistentKey: () => null,
        onPairingError: (message) => errorMessage = message,
      );

      await controller.addAsVerifiedContact('', 'Nobody');
      expect(contactRepository.savedContacts, isEmpty);

      await controller.addAsVerifiedContact('abc123', 'Broken');
      expect(errorMessage, contains('Failed to add contact'));
    });
  });
}
