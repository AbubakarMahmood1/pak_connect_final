import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/pairing_state.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/pairing_flow_controller.dart';
import 'package:pak_connect/data/services/pairing_lifecycle_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
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
  Future<Contact?> getContactByUserId(UserId userId) => super.noSuchMethod(
    Invocation.method(#getContactByUserId, [userId]),
    returnValue: Future<Contact?>.value(null),
    returnValueForMissingStub: Future<Contact?>.value(null),
  );

  @override
  Future<void> clearCachedSecrets(String publicKey) => super.noSuchMethod(
    Invocation.method(#clearCachedSecrets, [publicKey]),
    returnValue: Future<void>.value(),
    returnValueForMissingStub: Future<void>.value(),
  );

  @override
  Future<String?> getCachedSharedSecret(String publicKey) => super.noSuchMethod(
    Invocation.method(#getCachedSharedSecret, [publicKey]),
    returnValue: Future<String?>.value(null),
    returnValueForMissingStub: Future<String?>.value(null),
  );

  @override
  Future<SecurityLevel> getContactSecurityLevel(String publicKey) =>
      super.noSuchMethod(
        Invocation.method(#getContactSecurityLevel, [publicKey]),
        returnValue: Future<SecurityLevel>.value(SecurityLevel.low),
        returnValueForMissingStub: Future<SecurityLevel>.value(
          SecurityLevel.low,
        ),
      );

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel newLevel,
  ) => super.noSuchMethod(
    Invocation.method(#updateContactSecurityLevel, [publicKey, newLevel]),
    returnValue: Future<void>.value(),
    returnValueForMissingStub: Future<void>.value(),
  );

  @override
  Future<bool> upgradeContactSecurity(
    String publicKey,
    SecurityLevel newLevel,
  ) => super.noSuchMethod(
    Invocation.method(#upgradeContactSecurity, [publicKey, newLevel]),
    returnValue: Future<bool>.value(true),
    returnValueForMissingStub: Future<bool>.value(true),
  );

  @override
  Future<bool> resetContactSecurity(String publicKey, String reason) =>
      super.noSuchMethod(
        Invocation.method(#resetContactSecurity, [publicKey, reason]),
        returnValue: Future<bool>.value(true),
        returnValueForMissingStub: Future<bool>.value(true),
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
      when(
        contactRepository.getContactByUserId(const UserId('peer')),
      ).thenAnswer((_) async => contact);
      when(
        contactRepository.getContactByUserId(const UserId('persist')),
      ).thenAnswer((_) async => contact);
      when(
        contactRepository.getContactSecurityLevel('peer'),
      ).thenAnswer((_) async => SecurityLevel.medium);
      when(
        contactRepository.getCachedSharedSecret('peer'),
      ).thenAnswer((_) async => null);
      when(
        contactRepository.upgradeContactSecurity('peer', SecurityLevel.medium),
      ).thenAnswer((_) async => true);
      when(
        contactRepository.resetContactSecurity('peer', 'test-reset'),
      ).thenAnswer((_) async => true);

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

    test('setTheirEphemeralId updates identity session state', () {
      controller.setTheirEphemeralId('peer-new-eph', 'Peer New');

      expect(identityState.theirEphemeralId, 'peer-new-eph');
    });

    test('ensureContactMaximumSecurity initializes conversation from cached secret', () async {
      const contactKey = 'peer-max-security';
      const sharedSecret = 'cached-secret';
      when(
        contactRepository.getCachedSharedSecret(contactKey),
      ).thenAnswer((_) async => sharedSecret);

      await controller.ensureContactMaximumSecurity(contactKey);

      expect(SimpleCrypto.hasConversationKey(contactKey), isTrue);
      SimpleCrypto.clearConversationKey(contactKey);
    });

    test('ensureContactMaximumSecurity no-ops for empty key', () async {
      await controller.ensureContactMaximumSecurity('');

      verifyNever(contactRepository.getCachedSharedSecret(''));
    });

    test('confirmSecurityUpgrade creates missing contact and notifies completion', () async {
      when(
        contactRepository.getContactByUserId(const UserId('new-contact')),
      ).thenAnswer((_) async => null);
      var completed = false;
      controller.onContactRequestCompleted = (success) => completed = success;

      final result = await controller.confirmSecurityUpgrade(
        'new-contact',
        SecurityLevel.medium,
      );

      expect(result, isTrue);
      expect(completed, isTrue);
      verify(
        contactRepository.saveContactWithSecurity(
          'new-contact',
          'Unknown',
          SecurityLevel.medium,
        ),
      ).called(1);
    });

    test('confirmSecurityUpgrade upgrades when target level is higher', () async {
      final lowContact = Contact(
        publicKey: contact.publicKey,
        persistentPublicKey: contact.persistentPublicKey,
        currentEphemeralId: contact.currentEphemeralId,
        displayName: contact.displayName,
        trustStatus: contact.trustStatus,
        securityLevel: SecurityLevel.low,
        firstSeen: contact.firstSeen,
        lastSeen: contact.lastSeen,
      );
      when(
        contactRepository.getContactByUserId(const UserId('peer')),
      ).thenAnswer((_) async => lowContact);

      var completed = false;
      controller.onContactRequestCompleted = (success) => completed = success;

      final result = await controller.confirmSecurityUpgrade(
        'peer',
        SecurityLevel.medium,
      );

      expect(result, isTrue);
      expect(completed, isTrue);
      verify(
        contactRepository.upgradeContactSecurity('peer', SecurityLevel.medium),
      ).called(1);
    });

    test('confirmSecurityUpgrade blocks downgrade attempts', () async {
      final highContact = Contact(
        publicKey: contact.publicKey,
        persistentPublicKey: contact.persistentPublicKey,
        currentEphemeralId: contact.currentEphemeralId,
        displayName: contact.displayName,
        trustStatus: contact.trustStatus,
        securityLevel: SecurityLevel.high,
        firstSeen: contact.firstSeen,
        lastSeen: contact.lastSeen,
      );
      when(
        contactRepository.getContactByUserId(const UserId('peer')),
      ).thenAnswer((_) async => highContact);

      bool? completed;
      controller.onContactRequestCompleted = (success) => completed = success;

      final result = await controller.confirmSecurityUpgrade(
        'peer',
        SecurityLevel.low,
      );

      expect(result, isFalse);
      expect(completed, isTrue);
      verifyNever(
        contactRepository.upgradeContactSecurity('peer', SecurityLevel.low),
      );
    });

    test('resetContactSecurity clears crypto state and reports completion', () async {
      const key = 'peer-reset';
      SimpleCrypto.initializeConversation(key, 'seed');
      when(
        contactRepository.resetContactSecurity(key, 'test-reset'),
      ).thenAnswer((_) async => true);

      var completed = false;
      controller.onContactRequestCompleted = (success) => completed = success;

      final result = await controller.resetContactSecurity(key, 'test-reset');

      expect(result, isTrue);
      expect(completed, isTrue);
      expect(SimpleCrypto.hasConversationKey(key), isFalse);
    });

    test('handleSecurityLevelSync reconciles to mutual minimum level', () async {
      when(
        contactRepository.getContactSecurityLevel('peer'),
      ).thenAnswer((_) async => SecurityLevel.high);

      bool? completed;
      controller.onContactRequestCompleted = (success) => completed = success;

      await controller.handleSecurityLevelSync({
        'securityLevel': SecurityLevel.medium.index,
      });

      verify(
        contactRepository.updateContactSecurityLevel('peer', SecurityLevel.medium),
      ).called(1);
      expect(completed, isTrue);
    });
  });
}
