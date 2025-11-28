import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/bluetooth/identity_session_state.dart';
import 'package:pak_connect/core/models/pairing_state.dart';
import 'package:pak_connect/core/security/ephemeral_key_manager.dart';
import 'package:pak_connect/core/security/security_types.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/pairing_flow_controller.dart';
import 'package:pak_connect/data/services/pairing_lifecycle_service.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockContactRepository extends Mock implements ContactRepository {
  @override
  Future<Contact?> getContact(String publicKey) => super.noSuchMethod(
    Invocation.method(#getContact, [publicKey]),
    returnValue: Future<Contact?>.value(null),
    returnValueForMissingStub: Future<Contact?>.value(null),
  );

  @override
  Future<Contact?> getContactByAnyId(String identifier) => super.noSuchMethod(
    Invocation.method(#getContactByAnyId, [identifier]),
    returnValue: Future<Contact?>.value(null),
    returnValueForMissingStub: Future<Contact?>.value(null),
  );

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) =>
      super.noSuchMethod(
        Invocation.method(#cacheSharedSecret, [publicKey, sharedSecret]),
        returnValue: Future<void>.value(),
        returnValueForMissingStub: Future<void>.value(),
      );

  @override
  Future<void> saveContactWithSecurity(
    String publicKey,
    String displayName,
    SecurityLevel securityLevel, {
    String? currentEphemeralId,
    String? persistentPublicKey,
  }) => super.noSuchMethod(
    Invocation.method(
      #saveContactWithSecurity,
      [publicKey, displayName, securityLevel],
      {
        #currentEphemeralId: currentEphemeralId,
        #persistentPublicKey: persistentPublicKey,
      },
    ),
    returnValue: Future<void>.value(),
    returnValueForMissingStub: Future<void>.value(),
  );

  @override
  Future<void> clearCachedSecrets(String publicKey) => super.noSuchMethod(
    Invocation.method(#clearCachedSecrets, [publicKey]),
    returnValue: Future<void>.value(),
    returnValueForMissingStub: Future<void>.value(),
  );
}

void main() {
  group('PairingFlowController verification', () {
    final List<LogRecord> logRecords = [];
    final Set<String> allowedSevere = {};

    late PairingFlowController controller;
    late _MockContactRepository contactRepository;
    late IdentitySessionState identityState;
    late Map<String, String> conversationKeys;
    late bool cancelledCalled;
    late Contact contact;

    setUp(() async {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await EphemeralKeyManager.initialize('my-private-key');

      contactRepository = _MockContactRepository();
      conversationKeys = {};
      cancelledCalled = false;

      contact = Contact(
        publicKey: 'peer',
        persistentPublicKey: 'persist',
        currentEphemeralId: 'peer',
        displayName: 'Peer',
        trustStatus: TrustStatus.verified,
        securityLevel: SecurityLevel.medium,
        firstSeen: DateTime(2024, 1, 1),
        lastSeen: DateTime(2024, 1, 1),
      );

      when(
        contactRepository.getContact('peer'),
      ).thenAnswer((_) async => contact);
      when(
        contactRepository.getContactByAnyId('peer'),
      ).thenAnswer((_) async => contact);

      identityState = IdentitySessionState();
      final pairingLifecycleService = PairingLifecycleService(
        logger: Logger('test-lifecycle'),
        contactRepository: contactRepository,
        identityState: identityState,
        conversationKeys: conversationKeys,
        myPersistentIdProvider: () async => 'my-id',
        triggerChatMigration:
            ({
              required String ephemeralId,
              required String persistentKey,
              String? contactName,
            }) async {},
      );

      controller = PairingFlowController(
        logger: Logger('test'),
        contactRepository: contactRepository,
        identityState: identityState,
        conversationKeys: conversationKeys,
        myPersistentIdProvider: () async => 'my-id',
        myUserNameProvider: () => 'Me',
        otherUserNameProvider: () => 'Peer',
        pairingLifecycleService: pairingLifecycleService,
      );

      identityState.currentSessionId = 'peer';
      identityState.theirPersistentKey = 'persist';
      controller.onPairingCancelled = () => cancelledCalled = true;
    });

    tearDown(() {
      // Allow SEVERE logs from intentional error-handling tests
      allowedSevere.addAll(['Hash mismatch', 'verification failed']);
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

    test('mismatch revokes secrets and marks pairing failed', () async {
      final code = controller.generatePairingCode();

      controller.handleReceivedPairingCode(code);
      final success = await controller.completePairing(code);
      expect(success, isTrue);
      expect(controller.currentPairing?.sharedSecret, isNotNull);
      expect(conversationKeys.containsKey('peer'), isTrue);

      final secret = controller.currentPairing!.sharedSecret!;
      final expectedHash = sha256
          .convert(utf8.encode(secret))
          .toString()
          .shortId(8);
      final badHash = expectedHash == 'deadbeef' ? 'feedface' : 'deadbeef';

      await controller.handlePairingVerification(badHash);

      expect(controller.currentPairing?.state, PairingState.failed);
      expect(controller.currentPairing?.sharedSecret, isNull);
      expect(conversationKeys.containsKey('peer'), isFalse);
      expect(conversationKeys.containsKey('persist'), isFalse);
      expect(cancelledCalled, isTrue);
      expect(identityState.theirPersistentKey, isNull);

      verify(contactRepository.clearCachedSecrets('peer')).called(1);
      verify(contactRepository.clearCachedSecrets('persist')).called(1);
      verify(
        contactRepository.saveContactWithSecurity(
          'peer',
          'Peer',
          SecurityLevel.low,
          currentEphemeralId: contact.currentEphemeralId!,
          persistentPublicKey: null,
        ),
      ).called(1);
    });

    test('uses persistent IDs for shared secret when available', () async {
      identityState.setTheirEphemeralId('peer-eph');
      identityState.theirPersistentKey = 'persist';
      identityState.currentSessionId = 'peer-eph';

      final code = controller.generatePairingCode();

      controller.handleReceivedPairingCode(code);
      final success = await controller.completePairing(code);
      expect(success, isTrue);

      final sortedCodes = [code, code]..sort();
      final sortedKeys = ['my-id', 'persist']..sort();
      final expectedCombined =
          '${sortedCodes[0]}:${sortedCodes[1]}:${sortedKeys[0]}:${sortedKeys[1]}';
      final expectedSecret = sha256
          .convert(utf8.encode(expectedCombined))
          .toString();

      expect(controller.currentPairing?.sharedSecret, expectedSecret);
      expect(conversationKeys.containsKey('persist'), isTrue);
      verify(
        contactRepository.cacheSharedSecret('persist', expectedSecret),
      ).called(1);
    });
  });
}
