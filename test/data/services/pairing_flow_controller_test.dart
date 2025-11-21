import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/bluetooth/identity_session_state.dart';
import 'package:pak_connect/core/models/pairing_state.dart';
import 'package:pak_connect/core/security/security_types.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/pairing_flow_controller.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

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
  group('PairingFlowController verification failure', () {
    late PairingFlowController controller;
    late _MockContactRepository contactRepository;
    late IdentitySessionState identityState;
    late Map<String, String> conversationKeys;
    late bool cancelledCalled;
    late Contact contact;

    setUp(() {
      Logger.root.level = Level.OFF;
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

      controller = PairingFlowController(
        logger: Logger('test'),
        contactRepository: contactRepository,
        identityState: identityState,
        conversationKeys: conversationKeys,
        myPersistentIdProvider: () async => 'my-id',
        myUserNameProvider: () => 'Me',
        otherUserNameProvider: () => 'Peer',
        triggerChatMigration:
            ({
              required String ephemeralId,
              required String persistentKey,
              String? contactName,
            }) async {},
      );

      identityState.currentSessionId = 'peer';
      identityState.theirPersistentKey = 'persist';
      controller.onPairingCancelled = () => cancelledCalled = true;
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
      expect(cancelledCalled, isTrue);
      expect(identityState.theirPersistentKey, isNull);

      verify(contactRepository.clearCachedSecrets('peer')).called(1);
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
  });
}
