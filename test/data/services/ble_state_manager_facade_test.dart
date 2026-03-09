import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/ble_state_coordinator.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager_facade.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_pairing_service.dart';
import 'package:pak_connect/domain/interfaces/i_session_service.dart';
import 'package:pak_connect/domain/models/protocol_message.dart'
    as domain_models;
import 'package:pak_connect/domain/models/protocol_message_type.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/values/id_types.dart';

class _StubIdentityManager implements IIdentityManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubPairingService implements IPairingService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSessionService implements ISessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBleStateCoordinator extends BLEStateCoordinator {
  _FakeBleStateCoordinator()
    : super(
        identityManager: _StubIdentityManager(),
        pairingService: _StubPairingService(),
        sessionService: _StubSessionService(),
      );

  int sendPairingRequestCalls = 0;
  int handlePairingRequestCalls = 0;
  int acceptPairingRequestCalls = 0;
  int rejectPairingRequestCalls = 0;
  int handlePairingAcceptCalls = 0;
  int handlePairingCancelCalls = 0;
  int cancelPairingCalls = 0;
  String? lastCancelReason;
  domain_models.ProtocolMessage? lastMessage;

  @override
  Future<void> sendPairingRequest() async {
    sendPairingRequestCalls++;
  }

  @override
  Future<void> handlePairingRequest(domain_models.ProtocolMessage message) async {
    handlePairingRequestCalls++;
    lastMessage = message;
  }

  @override
  Future<void> acceptPairingRequest() async {
    acceptPairingRequestCalls++;
  }

  @override
  void rejectPairingRequest() {
    rejectPairingRequestCalls++;
  }

  @override
  Future<void> handlePairingAccept(domain_models.ProtocolMessage message) async {
    handlePairingAcceptCalls++;
    lastMessage = message;
  }

  @override
  void handlePairingCancel(domain_models.ProtocolMessage message) {
    handlePairingCancelCalls++;
    lastMessage = message;
  }

  @override
  Future<void> cancelPairing({String? reason}) async {
    cancelPairingCalls++;
    lastCancelReason = reason;
  }
}

domain_models.ProtocolMessage _protocolMessage({
  ProtocolMessageType type = ProtocolMessageType.textMessage,
  Map<String, dynamic>? payload,
}) {
  return domain_models.ProtocolMessage(
    type: type,
    payload: payload ?? <String, dynamic>{'sample': true},
    timestamp: DateTime(2026, 1, 1),
  );
}

void main() {
  group('BLEStateManagerFacade', () {
    late BLEStateManager legacy;
    late _FakeBleStateCoordinator coordinator;
    late BLEStateManagerFacade facade;

    setUp(() {
      legacy = BLEStateManager();
      coordinator = _FakeBleStateCoordinator();
      facade = BLEStateManagerFacade(
        legacyStateManager: legacy,
        stateCoordinator: coordinator,
      );
    });

    tearDown(() {
      facade.dispose();
    });

    test('delegates pairing state-machine operations to state coordinator', () async {
      final message = _protocolMessage(type: ProtocolMessageType.pairingRequest);

      await facade.sendPairingRequest();
      await facade.handlePairingRequest(message);
      await facade.acceptPairingRequest();
      facade.rejectPairingRequest();
      await facade.handlePairingAccept(message);
      facade.handlePairingCancel(message);
      facade.cancelPairing(reason: 'user_cancelled');

      expect(coordinator.sendPairingRequestCalls, 1);
      expect(coordinator.handlePairingRequestCalls, 1);
      expect(coordinator.acceptPairingRequestCalls, 1);
      expect(coordinator.rejectPairingRequestCalls, 1);
      expect(coordinator.handlePairingAcceptCalls, 1);
      expect(coordinator.handlePairingCancelCalls, 1);
      expect(coordinator.cancelPairingCalls, 1);
      expect(coordinator.lastCancelReason, 'user_cancelled');
      expect(coordinator.lastMessage, same(message));
    });

    test('mirrors identity/session writes to legacy manager and exposes getters', () {
      facade.setOtherUserName('Alice');
      expect(facade.otherUserName, 'Alice');

      facade.setOtherDeviceIdentity('session-123', 'Bob');
      expect(facade.currentSessionId, 'session-123');
      expect(facade.otherUserName, 'Bob');

      facade.setTheirEphemeralId('eph-456', 'Carol');
      expect(facade.theirEphemeralId, 'eph-456');
      expect(facade.getRecipientId(), isNotNull);
      expect(facade.getIdType(), isNotEmpty);

      facade.setPeripheralMode(true);
      expect(facade.isPeripheralMode, isTrue);

      facade.clearOtherUserName();
      expect(facade.otherUserName, 'Bob');

      facade.clearSessionState(preservePersistentId: true);
      expect(facade.isConnected, isTrue);
      expect(facade.hasContactRequest, isFalse);
      expect(facade.pendingContactName, isNull);
      expect(facade.theyHaveUsAsContact, isFalse);
      expect(facade.isPaired, isFalse);
    });

    test('forwards callback properties and protocol-message bridges', () {
      final protocol = _protocolMessage();
      final relayMessage = _protocolMessage(type: ProtocolMessageType.meshRelay);

      var deviceDiscovered = 0;
      var messageSent = 0;
      var messageSentIds = 0;
      var nameChanged = 0;
      var usernameChanged = 0;
      var pairingCodeSent = 0;
      var pairingVerificationSent = 0;
      var requestReceived = 0;
      var requestCompleted = 0;
      var sendContactRequest = 0;
      var sendContactAccept = 0;
      var sendContactReject = 0;
      var sendContactStatus = 0;
      var asymmetricDetected = 0;
      var mutualConsentRequired = 0;
      var spyDetected = 0;
      var identityRevealed = 0;
      var sendPairingRequest = 0;
      var sendPairingAccept = 0;
      var sendPairingCancel = 0;
      var pairingCancelled = 0;
      var persistentKeyExchange = 0;

      facade.onDeviceDiscovered = (_, _) => deviceDiscovered++;
      facade.onMessageSent = (_, _) => messageSent++;
      facade.onMessageSentIds = (_, _) => messageSentIds++;
      facade.onNameChanged = (_) => nameChanged++;
      facade.onMyUsernameChanged = (_) => usernameChanged++;
      facade.onSendPairingCode = (_) => pairingCodeSent++;
      facade.onSendPairingVerification = (_) => pairingVerificationSent++;
      facade.onContactRequestReceived = (_, _) => requestReceived++;
      facade.onContactRequestCompleted = (_) => requestCompleted++;
      facade.onSendContactRequest = (_, _) => sendContactRequest++;
      facade.onSendContactAccept = (_, _) => sendContactAccept++;
      facade.onSendContactReject = () => sendContactReject++;
      facade.onSendContactStatus = (_) => sendContactStatus++;
      facade.onAsymmetricContactDetected = (_, _) => asymmetricDetected++;
      facade.onMutualConsentRequired = (_, _) => mutualConsentRequired++;
      facade.onSpyModeDetected = (_) => spyDetected++;
      facade.onIdentityRevealed = (_) => identityRevealed++;
      facade.onSendPairingRequest = (_) => sendPairingRequest++;
      facade.onSendPairingAccept = (_) => sendPairingAccept++;
      facade.onSendPairingCancel = (_) => sendPairingCancel++;
      facade.onPairingCancelled = () => pairingCancelled++;
      facade.onSendPersistentKeyExchange = (_) => persistentKeyExchange++;

      expect(facade.onDeviceDiscovered, isNotNull);
      expect(facade.onMessageSent, isNotNull);
      expect(facade.onMessageSentIds, isNotNull);
      expect(facade.onNameChanged, isNotNull);
      expect(facade.onMyUsernameChanged, isNotNull);
      expect(facade.onSendPairingCode, isNotNull);
      expect(facade.onSendPairingVerification, isNotNull);
      expect(facade.onContactRequestReceived, isNotNull);
      expect(facade.onContactRequestCompleted, isNotNull);
      expect(facade.onSendContactRequest, isNotNull);
      expect(facade.onSendContactAccept, isNotNull);
      expect(facade.onSendContactReject, isNotNull);
      expect(facade.onSendContactStatus, isNotNull);
      expect(facade.onAsymmetricContactDetected, isNotNull);
      expect(facade.onMutualConsentRequired, isNotNull);
      expect(facade.onSpyModeDetected, isNotNull);
      expect(facade.onIdentityRevealed, isNotNull);
      expect(facade.onSendPairingRequest, isNotNull);
      expect(facade.onSendPairingAccept, isNotNull);
      expect(facade.onSendPairingCancel, isNotNull);
      expect(facade.onPairingCancelled, isNotNull);
      expect(facade.onSendPersistentKeyExchange, isNotNull);

      legacy.onDeviceDiscovered?.call('dev-1', -52);
      legacy.onMessageSent?.call('mid-1', true);
      legacy.onMessageSentIds?.call(MessageId('mid-typed'), true);
      legacy.onNameChanged?.call('Name');
      legacy.onMyUsernameChanged?.call('Me');
      legacy.onSendPairingCode?.call('1234');
      legacy.onSendPairingVerification?.call('hash');
      legacy.onContactRequestReceived?.call('pk-a', 'Alice');
      legacy.onContactRequestCompleted?.call(true);
      legacy.onSendContactRequest?.call('pk-b', 'Bob');
      legacy.onSendContactAccept?.call('pk-c', 'Carol');
      legacy.onSendContactReject?.call();
      legacy.onSendContactStatus?.call(protocol);
      legacy.onAsymmetricContactDetected?.call('pk-d', 'Dave');
      legacy.onMutualConsentRequired?.call('pk-e', 'Eve');
      legacy.onSpyModeDetected?.call(
        SpyModeInfo(contactName: 'Spy', ephemeralID: 'eph-spy'),
      );
      legacy.onIdentityRevealed?.call('friend-id');
      legacy.onSendPersistentKeyExchange?.call(relayMessage);

      expect(deviceDiscovered, 1);
      expect(messageSent, 1);
      expect(messageSentIds, 1);
      expect(nameChanged, 1);
      expect(usernameChanged, 1);
      expect(pairingCodeSent, 1);
      expect(pairingVerificationSent, 1);
      expect(requestReceived, 1);
      expect(requestCompleted, 1);
      expect(sendContactRequest, 1);
      expect(sendContactAccept, 1);
      expect(sendContactReject, 1);
      expect(sendContactStatus, 1);
      expect(asymmetricDetected, 1);
      expect(mutualConsentRequired, 1);
      expect(spyDetected, 1);
      expect(identityRevealed, 1);
      expect(persistentKeyExchange, 1);
      expect(sendPairingRequest, 0);
      expect(sendPairingAccept, 0);
      expect(sendPairingCancel, 0);
      expect(pairingCancelled, 0);

      // Null assignment path for wrapper callbacks.
      facade.onSendContactStatus = null;
      facade.onSendPairingRequest = null;
      facade.onSendPairingAccept = null;
      facade.onSendPairingCancel = null;
      facade.onSendPersistentKeyExchange = null;

      expect(facade.onSendContactStatus, isNull);
      expect(facade.onSendPairingRequest, isNull);
      expect(facade.onSendPairingAccept, isNull);
      expect(facade.onSendPairingCancel, isNull);
      expect(facade.onSendPersistentKeyExchange, isNull);
    });

    test('returns myPersistentId from identity manager fallback when legacy is empty', () {
      expect(facade.myPersistentId, isNull);
      expect(facade.currentPairing, isNull);
      expect(facade.theirPersistentKey, isNull);
      expect(() => facade.myEphemeralId, throwsStateError);
      expect(facade.weHaveThemAsContact, completion(isFalse));
    });

    test('contact and security methods delegate without throwing for nominal input', () async {
      await facade.saveContact('pk-1', 'Alice');
      expect(await facade.getContact('pk-1'), isNotNull);
      expect(await facade.getContactName('pk-1'), 'Alice');
      expect(await facade.getContactTrustStatus('pk-1'), TrustStatus.newContact);
      expect(await facade.checkExistingPairing('pk-1'), isFalse);
      expect(await facade.confirmSecurityUpgrade('pk-1', SecurityLevel.low), isTrue);
      expect(await facade.resetContactSecurity('pk-1', 'test-reset'), isTrue);
    });
  });
}
