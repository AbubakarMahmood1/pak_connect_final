import 'package:flutter_test/flutter_test.dart';

import 'package:pak_connect/data/services/ble_state_coordinator.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager_facade.dart';
import 'package:pak_connect/data/services/identity_manager.dart';
import 'package:pak_connect/data/services/pairing_service.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_pairing_service.dart';
import 'package:pak_connect/domain/interfaces/i_session_service.dart';
import 'package:pak_connect/domain/models/pairing_state.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/protocol_message.dart'
    as domain_models;

class _FakeIdentityManager implements IIdentityManager {
  int initializeCalls = 0;
  int loadUserNameCalls = 0;

  @override
  String? myUserName;
  @override
  String? otherUserName;
  @override
  String? myPersistentId;
  @override
  String? myEphemeralId;
  @override
  String? theirEphemeralId;
  @override
  String? theirPersistentKey;
  @override
  String? currentSessionId;

  final Map<String, String> _ephemeralToPersistent = <String, String>{};

  @override
  void Function(String newName)? onMyUsernameChanged;

  @override
  void Function(String newName)? onNameChanged;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<void> loadUserName() async {
    loadUserNameCalls++;
  }

  @override
  String? getMyPersistentId() => myPersistentId;

  @override
  String? getPersistentKeyFromEphemeral(String ephemeralId) =>
      _ephemeralToPersistent[ephemeralId];

  @override
  Future<void> setMyUserName(String name) async {
    myUserName = name;
  }

  @override
  Future<void> setMyUserNameWithCallbacks(String name) async {
    myUserName = name;
    onMyUsernameChanged?.call(name);
  }

  @override
  void setOtherDeviceIdentity(String deviceId, String displayName) {
    currentSessionId = deviceId;
    otherUserName = displayName;
  }

  @override
  void setOtherUserName(String? name) {
    otherUserName = name;
  }

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    theirEphemeralId = ephemeralId;
    otherUserName = displayName;
  }

  @override
  void setTheirPersistentKey(String persistentKey, {String? ephemeralId}) {
    theirPersistentKey = persistentKey;
    if (ephemeralId != null && ephemeralId.isNotEmpty) {
      _ephemeralToPersistent[ephemeralId] = persistentKey;
    }
  }

  @override
  void setCurrentSessionId(String? sessionId) {
    currentSessionId = sessionId;
  }
}

class _FakePairingService implements IPairingService {
  int generatePairingCodeCalls = 0;
  int clearPairingCalls = 0;
  int initiatePairingRequestCalls = 0;

  String? lastInitiateEphemeralId;
  String? lastInitiateDisplayName;

  @override
  PairingInfo? currentPairing;

  @override
  void Function()? onPairingCancelled;

  @override
  void Function()? onPairingRequestReceived;

  @override
  void Function(String code)? onSendPairingCode;

  @override
  void Function(String verificationHash)? onSendPairingVerification;

  @override
  String? theirReceivedCode;

  @override
  bool weEnteredCode = false;

  @override
  void acceptIncomingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {}

  @override
  void clearPairing() {
    clearPairingCalls++;
  }

  @override
  Future<void> completePairing(String theirCode) async {}

  @override
  String generatePairingCode() {
    generatePairingCodeCalls++;
    return '1234';
  }

  @override
  void handleReceivedPairingCode(String theirCode) {}

  @override
  Future<void> handlePairingVerification(String theirSecretHash) async {}

  @override
  void initiatePairingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {
    initiatePairingRequestCalls++;
    lastInitiateEphemeralId = myEphemeralId;
    lastInitiateDisplayName = displayName;
  }

  @override
  void receivePairingAccept({
    required String theirEphemeralId,
    required String displayName,
  }) {}

  @override
  void receivePairingCancel({String? reason}) {}

  @override
  void receivePairingRequest({
    required String theirEphemeralId,
    required String displayName,
  }) {}

  @override
  void rejectIncomingRequest() {}
}

class _FakeSessionService implements ISessionService {
  int setTheirEphemeralIdCalls = 0;
  int requestContactStatusExchangeCalls = 0;

  String? lastEphemeralId;
  String? lastDisplayName;

  @override
  bool isPaired = false;

  @override
  void Function()? onAsymmetricContactDetected;

  @override
  void Function()? onContactRequestCompleted;

  @override
  void Function()? onMutualConsentRequired;

  @override
  void Function(String content)? onSendMessage;

  @override
  void Function(bool weHaveThem, String theirPublicKey)? onSendContactStatus;

  @override
  String? getConversationKey(String publicKey) => null;

  @override
  String getIdType() => 'ephemeral';

  @override
  String? getRecipientId() => lastEphemeralId;

  @override
  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  ) async {}

  @override
  Future<void> requestContactStatusExchange() async {
    requestContactStatusExchangeCalls++;
  }

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    setTheirEphemeralIdCalls++;
    lastEphemeralId = ephemeralId;
    lastDisplayName = displayName;
  }

  @override
  void updateTheirContactClaim(bool theyClaimUs) {}

  @override
  void updateTheirContactStatus(bool theyHaveUs) {}
}

class _FakeStateCoordinator extends BLEStateCoordinator {
  _FakeStateCoordinator({
    required super.identityManager,
    required super.pairingService,
    required super.sessionService,
  });

  int sendPairingRequestCalls = 0;
  int acceptPairingRequestCalls = 0;
  int rejectPairingRequestCalls = 0;
  int cancelPairingCalls = 0;

  @override
  Future<void> sendPairingRequest() async {
    sendPairingRequestCalls++;
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
  Future<void> cancelPairing({String? reason}) async {
    cancelPairingCalls++;
  }
}

class _SpyIdentityManager extends IdentityManager {
  int initializeCalls = 0;
  Map<String, Object?>? lastSync;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  void syncFromLegacy({
    String? myUserName,
    String? otherUserName,
    String? myPersistentId,
    String? theirEphemeralId,
    String? theirPersistentKey,
    String? currentSessionId,
  }) {
    lastSync = <String, Object?>{
      'myUserName': myUserName,
      'otherUserName': otherUserName,
      'myPersistentId': myPersistentId,
      'theirEphemeralId': theirEphemeralId,
      'theirPersistentKey': theirPersistentKey,
      'currentSessionId': currentSessionId,
    };
    super.syncFromLegacy(
      myUserName: myUserName,
      otherUserName: otherUserName,
      myPersistentId: myPersistentId,
      theirEphemeralId: theirEphemeralId,
      theirPersistentKey: theirPersistentKey,
      currentSessionId: currentSessionId,
    );
  }
}

class _FakeBLEStateManager extends BLEStateManager {
  _FakeBLEStateManager();

  bool initializeCalled = false;
  bool loadUserNameCalled = false;
  bool clearSessionCalled = false;
  bool? clearSessionPreserveArg;
  String? setOtherUserNameValue;

  String? fakeMyUserName = 'LegacyUser';
  String? fakeOtherUserName = 'LegacyPeer';
  String? fakeMyPersistentId = 'legacy-persistent';
  String? fakeTheirEphemeralId = 'legacy-ephemeral';
  String? fakeTheirPersistentKey = 'legacy-peer-persistent';
  String? fakeCurrentSessionId = 'legacy-session';

  Function(domain_models.ProtocolMessage message)? _contactStatusCallback;

  @override
  Future<void> initialize() async {
    initializeCalled = true;
  }

  @override
  Future<void> loadUserName() async {
    loadUserNameCalled = true;
  }

  @override
  String? get myUserName => fakeMyUserName;

  @override
  String? get otherUserName => fakeOtherUserName;

  @override
  String? get myPersistentId => fakeMyPersistentId;

  @override
  String? get theirEphemeralId => fakeTheirEphemeralId;

  @override
  String? get theirPersistentKey => fakeTheirPersistentKey;

  @override
  String? get currentSessionId => fakeCurrentSessionId;

  @override
  void setOtherUserName(String? name) {
    setOtherUserNameValue = name;
    fakeOtherUserName = name;
  }

  @override
  void clearSessionState({bool preservePersistentId = false}) {
    clearSessionCalled = true;
    clearSessionPreserveArg = preservePersistentId;
  }

  @override
  Function(domain_models.ProtocolMessage)? get onSendContactStatus =>
      _contactStatusCallback;

  @override
  set onSendContactStatus(Function(domain_models.ProtocolMessage)? callback) {
    _contactStatusCallback = callback;
  }
}

void main() {
  group('BLEStateCoordinator', () {
    late _FakeIdentityManager identity;
    late _FakePairingService pairing;
    late _FakeSessionService session;
    late BLEStateCoordinator coordinator;

    setUp(() {
      identity = _FakeIdentityManager();
      pairing = _FakePairingService();
      session = _FakeSessionService();
      coordinator = BLEStateCoordinator(
        identityManager: identity,
        pairingService: pairing,
        sessionService: session,
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    test(
      'sendPairingRequest exits when peer ephemeral id is missing',
      () async {
        identity.theirEphemeralId = null;
        await coordinator.sendPairingRequest();
        expect(pairing.initiatePairingRequestCalls, 0);
      },
    );

    test('sendPairingRequest initiates pairing and emits callback', () async {
      identity.theirEphemeralId = 'peer-ephemeral';
      identity.myEphemeralId = 'my-ephemeral';
      identity.myUserName = 'Alice';

      int callbackCalls = 0;
      coordinator.onSendPairingRequest = () {
        callbackCalls++;
      };

      await coordinator.sendPairingRequest();

      expect(pairing.initiatePairingRequestCalls, 1);
      expect(pairing.lastInitiateEphemeralId, 'my-ephemeral');
      expect(pairing.lastInitiateDisplayName, 'Alice');
      expect(callbackCalls, 1);
    });

    test(
      'pairing handlers route state transitions through pairing service',
      () async {
        await coordinator.acceptPairingRequest();
        await coordinator.handlePairingAccept(
          ProtocolMessage.pairingAccept(
            ephemeralId: 'peer-eph',
            displayName: 'Peer',
          ),
        );
        coordinator.handlePairingCancel(ProtocolMessage.pairingCancel());
        coordinator.rejectPairingRequest();
        await coordinator.cancelPairing(reason: 'user-cancel');

        expect(pairing.generatePairingCodeCalls, 2);
        expect(pairing.clearPairingCalls, 3);
      },
    );

    test(
      'handlePairingRequest updates session identity when payload is valid',
      () async {
        await coordinator.handlePairingRequest(
          ProtocolMessage.pairingRequest(
            ephemeralId: 'peer-eph',
            displayName: 'Peer Name',
          ),
        );

        expect(session.setTheirEphemeralIdCalls, 1);
        expect(session.lastEphemeralId, 'peer-eph');
        expect(session.lastDisplayName, 'Peer Name');
      },
    );

    test('initiateContactRequest fails fast without persistent id', () async {
      identity.myPersistentId = '';
      final bool result = await coordinator.initiateContactRequest();
      expect(result, isFalse);
    });

    test(
      'sendContactRequest emits completion callback when identity exists',
      () async {
        identity.myPersistentId = 'my-public-key';
        int completedCalls = 0;
        coordinator.onContactRequestCompleted = () {
          completedCalls++;
        };

        await coordinator.sendContactRequest();
        expect(completedCalls, 1);
      },
    );

    test(
      'initializeContactFlags requests status exchange via session service',
      () async {
        await coordinator.initializeContactFlags();
        expect(session.requestContactStatusExchangeCalls, 1);
      },
    );

    test('identity fallback returns default shape', () async {
      final Map<String, String> fallback = await coordinator
          .getIdentityWithFallback();

      expect(fallback['displayName'], 'Connected Device');
      expect(fallback['publicKey'], '');
      expect(fallback['source'], 'fallback');
    });
  });

  group('BLEStateManagerFacade', () {
    test(
      'initialize and clearSessionState sync identity from legacy state',
      () async {
        final _FakeBLEStateManager legacy = _FakeBLEStateManager();
        final _SpyIdentityManager identity = _SpyIdentityManager();
        final _FakeStateCoordinator coordinator = _FakeStateCoordinator(
          identityManager: _FakeIdentityManager(),
          pairingService: _FakePairingService(),
          sessionService: _FakeSessionService(),
        );

        final BLEStateManagerFacade facade = BLEStateManagerFacade(
          legacyStateManager: legacy,
          identityManager: identity,
          stateCoordinator: coordinator,
        );

        await facade.initialize();
        expect(legacy.initializeCalled, isTrue);
        expect(identity.initializeCalls, 1);
        expect(identity.lastSync?['myUserName'], 'LegacyUser');
        expect(identity.lastSync?['currentSessionId'], 'legacy-session');

        facade.clearSessionState(preservePersistentId: true);
        expect(legacy.clearSessionCalled, isTrue);
        expect(legacy.clearSessionPreserveArg, isTrue);
        expect(
          identity.lastSync?['theirPersistentKey'],
          'legacy-peer-persistent',
        );
      },
    );

    test('setOtherUserName syncs both legacy and identity manager', () {
      final _FakeBLEStateManager legacy = _FakeBLEStateManager();
      final _SpyIdentityManager identity = _SpyIdentityManager();
      final _FakeStateCoordinator coordinator = _FakeStateCoordinator(
        identityManager: _FakeIdentityManager(),
        pairingService: _FakePairingService(),
        sessionService: _FakeSessionService(),
      );

      final BLEStateManagerFacade facade = BLEStateManagerFacade(
        legacyStateManager: legacy,
        identityManager: identity,
        stateCoordinator: coordinator,
      );

      facade.setOtherUserName('Peer Name');

      expect(legacy.setOtherUserNameValue, 'Peer Name');
      expect(identity.lastSync?['otherUserName'], 'Peer Name');
    });

    test('pairing orchestration delegates to coordinator', () async {
      final _FakeStateCoordinator coordinator = _FakeStateCoordinator(
        identityManager: _FakeIdentityManager(),
        pairingService: _FakePairingService(),
        sessionService: _FakeSessionService(),
      );

      final BLEStateManagerFacade facade = BLEStateManagerFacade(
        stateCoordinator: coordinator,
      );

      await facade.sendPairingRequest();
      await facade.acceptPairingRequest();
      facade.rejectPairingRequest();
      facade.cancelPairing(reason: 'manual');

      expect(coordinator.sendPairingRequestCalls, 1);
      expect(coordinator.acceptPairingRequestCalls, 1);
      expect(coordinator.rejectPairingRequestCalls, 1);
      expect(coordinator.cancelPairingCalls, 1);
    });

    test(
      'callback setters bridge pairing and contact-status message callbacks',
      () {
        final _FakeBLEStateManager legacy = _FakeBLEStateManager();
        final PairingService pairingService = PairingService(
          getMyPersistentId: () async => 'my-persistent',
          getTheirSessionId: () => 'their-session',
          getTheirDisplayName: () => 'Peer',
        );
        final _FakeStateCoordinator coordinator = _FakeStateCoordinator(
          identityManager: _FakeIdentityManager(),
          pairingService: _FakePairingService(),
          sessionService: _FakeSessionService(),
        );

        final BLEStateManagerFacade facade = BLEStateManagerFacade(
          legacyStateManager: legacy,
          pairingService: pairingService,
          stateCoordinator: coordinator,
        );

        int pairingForwardCalls = 0;
        int contactStatusForwardCalls = 0;

        facade.onSendPairingRequest = (_) {
          pairingForwardCalls++;
        };
        facade.onSendContactStatus = (_) {
          contactStatusForwardCalls++;
        };

        pairingService.onSendPairingRequest?.call(
          ProtocolMessage.pairingRequest(
            ephemeralId: 'eph',
            displayName: 'Alice',
          ),
        );
        legacy.onSendContactStatus?.call(
          ProtocolMessage.contactStatus(
            hasAsContact: true,
            publicKey: 'pub-key',
          ),
        );

        expect(pairingForwardCalls, 1);
        expect(contactStatusForwardCalls, 1);
      },
    );
  });
}
