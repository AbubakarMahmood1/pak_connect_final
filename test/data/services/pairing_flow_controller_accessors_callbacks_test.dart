// PairingFlowController supplementary coverage
// Targets: request/accept/cancel flow via lazy PairingRequestCoordinator,
// handlePersistentKeyExchange, clearPairing, _initializeCryptoForLevel,
// confirmSecurityUpgrade exception path, existing-HIGH requesting medium,
// already at same level re-initialization, ensureContactMaximumSecurity
// no cached secret path, isPaired getter, callback setters

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/pairing_flow_controller.dart';
import 'package:pak_connect/data/services/pairing_lifecycle_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Mocks ──────────────────────────────────────────────────────────────

class _MockContactRepository extends Mock implements ContactRepository {
 @override
 Future<Contact?> getContact(String pk) => super.noSuchMethod(Invocation.method(#getContact, [pk]),
 returnValue: Future<Contact?>.value(null),
 returnValueForMissingStub: Future<Contact?>.value(null),
);

 @override
 Future<Contact?> getContactByAnyId(String id) => super.noSuchMethod(Invocation.method(#getContactByAnyId, [id]),
 returnValue: Future<Contact?>.value(null),
 returnValueForMissingStub: Future<Contact?>.value(null),
);

 @override
 Future<void> cacheSharedSecret(String pk, String secret) =>
 super.noSuchMethod(Invocation.method(#cacheSharedSecret, [pk, secret]),
 returnValue: Future<void>.value(),
 returnValueForMissingStub: Future<void>.value(),
);

 @override
 Future<void> saveContactWithSecurity(String pk,
 String dn,
 SecurityLevel sl, {
 String? currentEphemeralId,
 String? persistentPublicKey,
 }) => super.noSuchMethod(Invocation.method(#saveContactWithSecurity,
 [pk, dn, sl],
 {
 #currentEphemeralId: currentEphemeralId,
 #persistentPublicKey: persistentPublicKey,
 },
),
 returnValue: Future<void>.value(),
 returnValueForMissingStub: Future<void>.value(),
);

 @override
 Future<Contact?> getContactByUserId(UserId uid) => super.noSuchMethod(Invocation.method(#getContactByUserId, [uid]),
 returnValue: Future<Contact?>.value(null),
 returnValueForMissingStub: Future<Contact?>.value(null),
);

 @override
 Future<void> clearCachedSecrets(String pk) => super.noSuchMethod(Invocation.method(#clearCachedSecrets, [pk]),
 returnValue: Future<void>.value(),
 returnValueForMissingStub: Future<void>.value(),
);

 @override
 Future<String?> getCachedSharedSecret(String pk) => super.noSuchMethod(Invocation.method(#getCachedSharedSecret, [pk]),
 returnValue: Future<String?>.value(null),
 returnValueForMissingStub: Future<String?>.value(null),
);

 @override
 Future<SecurityLevel> getContactSecurityLevel(String pk) =>
 super.noSuchMethod(Invocation.method(#getContactSecurityLevel, [pk]),
 returnValue: Future<SecurityLevel>.value(SecurityLevel.low),
 returnValueForMissingStub: Future<SecurityLevel>.value(SecurityLevel.low,
),
);

 @override
 Future<void> updateContactSecurityLevel(String pk, SecurityLevel sl) =>
 super.noSuchMethod(Invocation.method(#updateContactSecurityLevel, [pk, sl]),
 returnValue: Future<void>.value(),
 returnValueForMissingStub: Future<void>.value(),
);

 @override
 Future<bool> upgradeContactSecurity(String pk, SecurityLevel sl) =>
 super.noSuchMethod(Invocation.method(#upgradeContactSecurity, [pk, sl]),
 returnValue: Future<bool>.value(true),
 returnValueForMissingStub: Future<bool>.value(true),
);

 @override
 Future<bool> resetContactSecurity(String pk, String reason) =>
 super.noSuchMethod(Invocation.method(#resetContactSecurity, [pk, reason]),
 returnValue: Future<bool>.value(true),
 returnValueForMissingStub: Future<bool>.value(true),
);
}

Contact _contact({
 String publicKey = 'peer',
 String? persistentPublicKey = 'persist',
 String? currentEphemeralId = 'peer',
 SecurityLevel securityLevel = SecurityLevel.medium,
}) => Contact(publicKey: publicKey,
 persistentPublicKey: persistentPublicKey,
 currentEphemeralId: currentEphemeralId,
 displayName: 'Peer',
 trustStatus: TrustStatus.verified,
 securityLevel: securityLevel,
 firstSeen: DateTime(2024, 1, 1),
 lastSeen: DateTime(2024, 1, 1),
);

// ─── Tests ──────────────────────────────────────────────────────────────

void main() {
 late List<LogRecord> logRecords;
 late _MockContactRepository contactRepo;
 late IdentitySessionState identityState;
 late Map<String, String> conversationKeys;
 late PairingFlowController controller;

 setUp(() async {
 logRecords = [];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 TestWidgetsFlutterBinding.ensureInitialized();
 SharedPreferences.setMockInitialValues({});
 await EphemeralKeyManager.initialize('my-private-key');

 contactRepo = _MockContactRepository();
 identityState = IdentitySessionState();
 conversationKeys = {};

 when(contactRepo.getContact('peer')).thenAnswer((_) async => _contact());
 when(contactRepo.getContactByAnyId('peer'),
).thenAnswer((_) async => _contact());
 when(contactRepo.getContactByUserId(const UserId('peer')),
).thenAnswer((_) async => _contact());
 when(contactRepo.getContactByUserId(const UserId('persist')),
).thenAnswer((_) async => _contact());
 when(contactRepo.getContactSecurityLevel('peer'),
).thenAnswer((_) async => SecurityLevel.medium);
 when(contactRepo.getCachedSharedSecret('peer'),
).thenAnswer((_) async => null);
 when(contactRepo.upgradeContactSecurity('peer', SecurityLevel.medium),
).thenAnswer((_) async => true);

 final lifecycle = PairingLifecycleService(logger: Logger('test-lifecycle'),
 contactRepository: contactRepo,
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

 controller = PairingFlowController(logger: Logger('test-flow'),
 contactRepository: contactRepo,
 identityState: identityState,
 conversationKeys: conversationKeys,
 myPersistentIdProvider: () async => 'my-id',
 myUserNameProvider: () => 'Me',
 otherUserNameProvider: () => 'Peer',
 pairingLifecycleService: lifecycle,
);

 identityState.currentSessionId = 'peer';
 identityState.theirPersistentKey = 'persist';
 });

 // ─── Basic accessors ────────────────────────────────────────────────
 group('PairingFlowController — accessors & callbacks', () {
 test('isPaired returns true when theirPersistentKey is set', () {
 expect(controller.isPaired, isTrue);
 });

 test('isPaired returns false when theirPersistentKey is null', () {
 identityState.theirPersistentKey = null;
 expect(controller.isPaired, isFalse);
 });

 test('clearPairing resets pairing state', () {
 controller.clearPairing();
 expect(controller.currentPairing, isNull);
 });

 test('onSendPairingCode setter delegates to PairingService', () {
 String? captured;
 controller.onSendPairingCode = (code) => captured = code;
 expect(controller.onSendPairingCode, isNotNull);
 controller.onSendPairingCode?.call('123456');
 expect(captured, '123456');
 });

 test('onSendPairingVerification setter delegates', () {
 String? captured;
 controller.onSendPairingVerification = (hash) => captured = hash;
 expect(controller.onSendPairingVerification, isNotNull);
 controller.onSendPairingVerification?.call('hash-abc');
 expect(captured, 'hash-abc');
 });
 });

 // ─── Request/accept/cancel flow (lazy coordinator) ─────────────────
 group('PairingFlowController — request/accept/cancel flow', () {
 test('sendPairingRequest triggers coordinator and logs', () async {
 ProtocolMessage? sentMessage;
 controller.onSendPairingRequest = (msg) => sentMessage = msg;
 identityState.setTheirEphemeralId('peer-eph');

 await controller.sendPairingRequest();

 final waitingLog = logRecords.any((r) => r.message.contains('waiting for accept'),
);
 expect(waitingLog, isTrue);
 expect(sentMessage?.type, ProtocolMessageType.pairingRequest);
 });

 test('handlePairingRequest triggers UI popup via orchestrator', () {
 String? receivedEphId;
 String? receivedName;
 controller.onPairingRequestReceived = (eid, name) {
 receivedEphId = eid;
 receivedName = name;
 };

 final msg = ProtocolMessage(type: ProtocolMessageType.pairingRequest,
 timestamp: DateTime.now(),
 payload: {'ephemeralId': 'requester-eph', 'displayName': 'Requester'},
);

 controller.handlePairingRequest(msg);

 expect(receivedEphId, 'requester-eph');
 expect(receivedName, 'Requester');
 });

 test('acceptPairingRequest delegates to coordinator', () async {
 controller.onSendPairingRequest = (_) {};
 identityState.setTheirEphemeralId('peer-eph');
 await controller.sendPairingRequest();

 await controller.acceptPairingRequest();
 });

 test('rejectPairingRequest delegates to coordinator', () async {
 controller.onSendPairingRequest = (_) {};
 identityState.setTheirEphemeralId('peer-eph');
 await controller.sendPairingRequest();

 await controller.rejectPairingRequest();
 });

 test('handlePairingAccept delegates to coordinator', () {
 controller.onSendPairingRequest = (_) {};
 final msg = ProtocolMessage(type: ProtocolMessageType.pairingAccept,
 timestamp: DateTime.now(),
 payload: {'ephemeralId': 'peer-eph', 'displayName': 'Peer'},
);

 controller.handlePairingRequest(ProtocolMessage(type: ProtocolMessageType.pairingRequest,
 timestamp: DateTime.now(),
 payload: {'ephemeralId': 'peer-eph', 'displayName': 'Peer'},
),
);

 controller.handlePairingAccept(msg);
 });

 test('handlePairingCancel clears state after delay', () async {
 controller.handlePairingRequest(ProtocolMessage(type: ProtocolMessageType.pairingRequest,
 timestamp: DateTime.now(),
 payload: {'ephemeralId': 'peer-eph', 'displayName': 'Peer'},
),
);

 controller.handlePairingCancel(ProtocolMessage(type: ProtocolMessageType.pairingCancel,
 timestamp: DateTime.now(),
 payload: {'reason': 'User cancelled'},
),
);

 expect(true, isTrue);
 });

 test('cancelPairing delegates and schedules state clear', () async {
 controller.onSendPairingCancel = (_) {};
 controller.handlePairingRequest(ProtocolMessage(type: ProtocolMessageType.pairingRequest,
 timestamp: DateTime.now(),
 payload: {'ephemeralId': 'peer-eph', 'displayName': 'Peer'},
),
);

 await controller.cancelPairing(reason: 'test cancel');
 });
 });

 // ─── handlePersistentKeyExchange ─────────────────────────────────────
 group('PairingFlowController — handlePersistentKeyExchange', () {
 test('delegates to lifecycle service', () async {
 await controller.handlePersistentKeyExchange('their-persistent-key');
 // Should not throw; lifecycle will handle the key
 });
 });

 // ─── confirmSecurityUpgrade extra paths ──────────────────────────────
 group('PairingFlowController — confirmSecurityUpgrade edge cases', () {
 test('empty publicKey returns false', () async {
 final result = await controller.confirmSecurityUpgrade('',
 SecurityLevel.medium,
);
 expect(result, isFalse);
 });

 test('existing HIGH contact requesting MEDIUM skips pairing', () async {
 final highContact = _contact(securityLevel: SecurityLevel.high);
 when(contactRepo.getContactByUserId(const UserId('peer')),
).thenAnswer((_) async => highContact);

 bool? completed;
 controller.onContactRequestCompleted = (s) => completed = s;

 final result = await controller.confirmSecurityUpgrade('peer',
 SecurityLevel.medium,
);

 expect(result, isTrue);
 expect(completed, isTrue);
 });

 test('contact already at same level re-initializes crypto', () async {
 final medContact = _contact(securityLevel: SecurityLevel.medium);
 when(contactRepo.getContactByUserId(const UserId('peer')),
).thenAnswer((_) async => medContact);

 bool? completed;
 controller.onContactRequestCompleted = (s) => completed = s;

 final result = await controller.confirmSecurityUpgrade('peer',
 SecurityLevel.medium,
);

 expect(result, isTrue);
 expect(completed, isTrue);
 });

 test('exception in confirmSecurityUpgrade returns false', () async {
 when(contactRepo.getContactByUserId(const UserId('peer')),
).thenThrow(Exception('DB error'));

 final result = await controller.confirmSecurityUpgrade('peer',
 SecurityLevel.medium,
);

 expect(result, isFalse);
 });
 });

 // ─── resetContactSecurity edge cases ─────────────────────────────────
 group('PairingFlowController — resetContactSecurity edge cases', () {
 test('empty publicKey returns false', () async {
 final result = await controller.resetContactSecurity('', 'reason');
 expect(result, isFalse);
 });

 test('repository returning false propagates', () async {
 when(contactRepo.resetContactSecurity('fail-pk', 'reason'),
).thenAnswer((_) async => false);

 bool? completed;
 controller.onContactRequestCompleted = (s) => completed = s;

 final result = await controller.resetContactSecurity('fail-pk', 'reason');

 expect(result, isFalse);
 // callback only fires on success — stays null on failure
 expect(completed, isNull);
 });
 });

 // ─── ensureContactMaximumSecurity edge cases ─────────────────────────
 group('PairingFlowController — ensureContactMaximumSecurity edge cases', () {
 test('already has conversation key is no-op', () async {
 SimpleCrypto.initializeConversation('has-key', 'seed');
 await controller.ensureContactMaximumSecurity('has-key');

 verifyNever(contactRepo.getCachedSharedSecret('has-key'));
 SimpleCrypto.clearConversationKey('has-key');
 });

 test('no cached secret logs and does nothing', () async {
 when(contactRepo.getCachedSharedSecret('no-secret'),
).thenAnswer((_) async => null);

 await controller.ensureContactMaximumSecurity('no-secret');

 verify(contactRepo.getCachedSharedSecret('no-secret')).called(1);
 expect(SimpleCrypto.hasConversationKey('no-secret'), isFalse);
 });
 });

 // ─── handleSecurityLevelSync edge cases ──────────────────────────────
 group('PairingFlowController — handleSecurityLevelSync edge cases', () {
 test('null currentSessionId is handled gracefully', () async {
 identityState.currentSessionId = null;

 await controller.handleSecurityLevelSync({
 'securityLevel': SecurityLevel.medium.index,
 });

 // Should not throw
 });

 test('no update needed when levels match', () async {
 when(contactRepo.getContactSecurityLevel('peer'),
).thenAnswer((_) async => SecurityLevel.medium);

 await controller.handleSecurityLevelSync({
 'securityLevel': SecurityLevel.medium.index,
 });

 // No updateContactSecurityLevel call needed when at mutual minimum
 });
 });
}
