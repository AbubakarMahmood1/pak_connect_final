import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/pairing_request_coordinator.dart';
import 'package:pak_connect/data/services/pairing_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/crypto_header.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/pairing_state.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/ephemeral_key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SpyPairingService extends PairingService {
  _SpyPairingService()
    : super(
        getMyPersistentId: () async => 'me',
        getTheirSessionId: () => 'peer',
        getTheirDisplayName: () => 'Peer',
      );

  int initiateRequestCalls = 0;
  String? lastInitiateEphemeralId;
  String? lastInitiateDisplayName;

  int receiveRequestCalls = 0;
  String? lastReceivedRequestEphemeralId;
  String? lastReceivedRequestDisplayName;

  int acceptIncomingCalls = 0;
  String? lastAcceptEphemeralId;
  String? lastAcceptDisplayName;

  int rejectIncomingCalls = 0;

  int receiveAcceptCalls = 0;
  String? lastReceivedAcceptEphemeralId;
  String? lastReceivedAcceptDisplayName;

  int receiveCancelCalls = 0;
  String? lastCancelReason;

  @override
  void initiatePairingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {
    initiateRequestCalls++;
    lastInitiateEphemeralId = myEphemeralId;
    lastInitiateDisplayName = displayName;
  }

  @override
  void receivePairingRequest({
    required String theirEphemeralId,
    required String displayName,
  }) {
    receiveRequestCalls++;
    lastReceivedRequestEphemeralId = theirEphemeralId;
    lastReceivedRequestDisplayName = displayName;
  }

  @override
  void acceptIncomingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {
    acceptIncomingCalls++;
    lastAcceptEphemeralId = myEphemeralId;
    lastAcceptDisplayName = displayName;
  }

  @override
  void rejectIncomingRequest() {
    rejectIncomingCalls++;
  }

  @override
  void receivePairingAccept({
    required String theirEphemeralId,
    required String displayName,
  }) {
    receiveAcceptCalls++;
    lastReceivedAcceptEphemeralId = theirEphemeralId;
    lastReceivedAcceptDisplayName = displayName;
  }

  @override
  void receivePairingCancel({String? reason}) {
    receiveCancelCalls++;
    lastCancelReason = reason;
  }
}

class _SpySecurityService implements ISecurityService {
  final List<String> unregisteredMappings = <String>[];

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {}

  @override
  void unregisterIdentityMapping(String persistentPublicKey) {
    unregisteredMappings.add(persistentPublicKey);
  }

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async => SecurityLevel.low;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async => EncryptionMethod.global();

  @override
  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  ) async => message;

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async => message;

  @override
  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  ) async => encryptedMessage;

  @override
  Future<String> decryptMessageByType(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async => encryptedMessage;

  @override
  Future<String> decryptSealedMessage({
    required String encryptedMessage,
    required CryptoHeader cryptoHeader,
    required String messageId,
    required String senderId,
    required String recipientId,
  }) async => encryptedMessage;

  @override
  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async => data;

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;
}

void main() {
  group('PairingRequestCoordinator', () {
    late _SpyPairingService pairingService;
    late _SpySecurityService securityService;
    late IdentitySessionState identityState;
    late PairingInfo? pairingState;
    late List<ProtocolMessage> sentRequests;
    late List<ProtocolMessage> sentAccepts;
    late List<ProtocolMessage> sentCancels;
    late List<String> requestPopups;
    late List<bool> cancelledSignals;
    late List<String> unregisteredMappings;
    late PairingRequestCoordinator coordinator;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await EphemeralKeyManager.initialize('coordinator-test-private-key');

      pairingService = _SpyPairingService();
      securityService = _SpySecurityService();
      identityState = IdentitySessionState();
      pairingState = null;

      sentRequests = <ProtocolMessage>[];
      sentAccepts = <ProtocolMessage>[];
      sentCancels = <ProtocolMessage>[];
      requestPopups = <String>[];
      cancelledSignals = <bool>[];
      unregisteredMappings = <String>[];

      coordinator = PairingRequestCoordinator(
        logger: Logger('PairingRequestCoordinatorTest'),
        pairingService: pairingService,
        identityState: identityState,
        myUserName: () => 'Me',
        otherUserName: () => 'Peer',
        getPairingState: () => pairingState,
        setPairingState: (value) => pairingState = value,
        onRequestReceived: (ephemeralId, displayName) {
          requestPopups.add('$ephemeralId|$displayName');
        },
        onSendPairingRequest: sentRequests.add,
        onSendPairingAccept: sentAccepts.add,
        onSendPairingCancel: sentCancels.add,
        onPairingCancelled: () => cancelledSignals.add(true),
        unregisterIdentityMapping: unregisteredMappings.add,
        securityService: securityService,
      );
    });

    test('sendPairingRequest ignores empty ephemeral target', () async {
      await coordinator.sendPairingRequest(theirEphemeralId: '');

      expect(pairingService.initiateRequestCalls, 0);
      expect(sentRequests, isEmpty);
    });

    test('sendPairingRequest emits pairing request protocol message', () async {
      pairingState = const PairingInfo(
        myCode: '1111',
        state: PairingState.pairingRequested,
      );

      await coordinator.sendPairingRequest(theirEphemeralId: 'peer-ephemeral');

      expect(pairingService.initiateRequestCalls, 1);
      expect(pairingService.lastInitiateEphemeralId, isNotEmpty);
      expect(pairingService.lastInitiateDisplayName, 'Me');

      expect(sentRequests, hasLength(1));
      expect(sentRequests.single.type, ProtocolMessageType.pairingRequest);
      expect(sentRequests.single.payload['displayName'], 'Me');
    });

    test('sendPairingRequest timeout marks request as failed', () {
      fakeAsync((async) {
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.pairingRequested,
        );

        unawaited(
          coordinator.sendPairingRequest(theirEphemeralId: 'peer-ephemeral'),
        );
        async.flushMicrotasks();

        expect(cancelledSignals, isEmpty);
        async.elapse(const Duration(seconds: 31));

        expect(pairingState?.state, PairingState.failed);
        expect(cancelledSignals, hasLength(1));
      });
    });

    test('handlePairingRequest updates identity and notifies UI', () {
      identityState.theirEphemeralId = 'stale-eph';
      final message = ProtocolMessage.pairingRequest(
        ephemeralId: 'fresh-eph',
        displayName: 'Alice',
      );

      coordinator.handlePairingRequest(message);

      expect(pairingService.receiveRequestCalls, 1);
      expect(pairingService.lastReceivedRequestEphemeralId, 'fresh-eph');
      expect(pairingService.lastReceivedRequestDisplayName, 'Alice');
      expect(identityState.theirEphemeralId, 'fresh-eph');
      expect(requestPopups, ['fresh-eph|Alice']);
    });

    test(
      'acceptPairingRequest no-ops when state is not requestReceived',
      () async {
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.none,
        );

        await coordinator.acceptPairingRequest();

        expect(pairingService.acceptIncomingCalls, 0);
        expect(sentAccepts, isEmpty);
      },
    );

    test(
      'acceptPairingRequest sends pairing accept for pending request',
      () async {
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.requestReceived,
        );

        await coordinator.acceptPairingRequest();

        expect(pairingService.acceptIncomingCalls, 1);
        expect(pairingService.lastAcceptEphemeralId, isNotEmpty);
        expect(pairingService.lastAcceptDisplayName, 'Me');
        expect(sentAccepts, hasLength(1));
        expect(sentAccepts.single.type, ProtocolMessageType.pairingAccept);
      },
    );

    test(
      'rejectPairingRequest sends cancel and clears pairing state',
      () async {
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.requestReceived,
        );

        await coordinator.rejectPairingRequest();

        expect(pairingService.rejectIncomingCalls, 1);
        expect(sentCancels, hasLength(1));
        expect(sentCancels.single.type, ProtocolMessageType.pairingCancel);
        expect(pairingState, isNull);
      },
    );

    test(
      'handlePairingAccept forwards to service and updates dialog state',
      () {
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.pairingRequested,
        );

        coordinator.handlePairingAccept(
          ProtocolMessage.pairingAccept(
            ephemeralId: 'peer-eph',
            displayName: 'PeerName',
          ),
        );

        expect(pairingService.receiveAcceptCalls, 1);
        expect(pairingService.lastReceivedAcceptEphemeralId, 'peer-eph');
        expect(pairingService.lastReceivedAcceptDisplayName, 'PeerName');
        expect(pairingState?.state, PairingState.displaying);
        expect(pairingState?.theirEphemeralId, 'peer-eph');
        expect(pairingState?.theirDisplayName, 'PeerName');
      },
    );

    test(
      'handlePairingCancel unregisters mapping and clears state after delay',
      () {
        identityState.theirPersistentKey = 'persist-peer';
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.waiting,
        );

        fakeAsync((async) {
          coordinator.handlePairingCancel(
            ProtocolMessage.pairingCancel(reason: 'Remote cancelled'),
          );

          expect(pairingService.receiveCancelCalls, 1);
          expect(pairingService.lastCancelReason, 'Remote cancelled');
          expect(securityService.unregisteredMappings, ['persist-peer']);
          expect(unregisteredMappings, ['persist-peer']);
          expect(pairingState?.state, PairingState.cancelled);
          expect(cancelledSignals, hasLength(1));

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(pairingState, isNull);
        });
      },
    );

    test('cancelPairing returns early when no active pairing exists', () async {
      await coordinator.cancelPairing();

      expect(sentCancels, isEmpty);
      expect(securityService.unregisteredMappings, isEmpty);
    });

    test(
      'cancelPairing sends cancel, unregisters identity, and clears state',
      () {
        identityState.theirPersistentKey = 'persist-peer';
        pairingState = const PairingInfo(
          myCode: '1111',
          state: PairingState.waiting,
        );

        fakeAsync((async) {
          unawaited(coordinator.cancelPairing(reason: 'User stopped'));
          async.flushMicrotasks();

          expect(securityService.unregisteredMappings, ['persist-peer']);
          expect(unregisteredMappings, ['persist-peer']);
          expect(sentCancels, hasLength(1));
          expect(sentCancels.single.payload['reason'], 'User stopped');
          expect(pairingState?.state, PairingState.cancelled);

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(pairingState, isNull);
        });
      },
    );

    test('dispose is safe to call', () {
      coordinator.dispose();
      coordinator.dispose();
    });
  });
}
