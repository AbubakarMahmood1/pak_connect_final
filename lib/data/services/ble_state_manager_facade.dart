import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../core/models/pairing_state.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/services/security_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../domain/values/id_types.dart';
import 'ble_state_coordinator.dart';
import 'ble_state_manager.dart';
import 'identity_manager.dart';
import 'pairing_service.dart';
import 'session_service.dart';

/// Facade that wraps the legacy BLEStateManager while keeping the new
/// extracted services in sync. This allows BLEServiceFacade to depend on
/// the slimmer facade without changing existing consumers of BLEStateManager.
class BLEStateManagerFacade implements IBLEStateManagerFacade {
  final _logger = Logger('BLEStateManagerFacade');
  late final BLEStateManager _legacyStateManager;
  final ContactRepository _contactRepository;

  late final IdentityManager _identityManager;
  late final PairingService _pairingService;
  late final SessionService _sessionService;
  late final BLEStateCoordinator _stateCoordinator;

  BLEStateManagerFacade({
    BLEStateManager? legacyStateManager,
    IdentityManager? identityManager,
    PairingService? pairingService,
    SessionService? sessionService,
    BLEStateCoordinator? stateCoordinator,
    ContactRepository? contactRepository,
  }) : _contactRepository = contactRepository ?? ContactRepository() {
    _identityManager = identityManager ?? IdentityManager();
    _legacyStateManager =
        legacyStateManager ??
        BLEStateManager(identityManager: _identityManager);
    _pairingService =
        pairingService ??
        PairingService(
          getMyPersistentId: () async =>
              _legacyStateManager.myPersistentId ?? '',
          getTheirSessionId: () => _legacyStateManager.currentSessionId,
          getTheirDisplayName: () => _legacyStateManager.otherUserName,
          onVerificationComplete: null,
        );
    _sessionService =
        sessionService ??
        SessionService(
          contactRepository: _contactRepository,
          getWeHaveThemAsContact: () => _legacyStateManager.weHaveThemAsContact,
          getMyPersistentId: () => _legacyStateManager.getMyPersistentId(),
          getTheirPersistentKey: () => _legacyStateManager.theirPersistentKey,
          getTheirEphemeralId: () => _legacyStateManager.theirEphemeralId,
        );
    _stateCoordinator =
        stateCoordinator ??
        BLEStateCoordinator(
          identityManager: _identityManager,
          pairingService: _pairingService,
          sessionService: _sessionService,
        );
  }

  BLEStateManager get legacyStateManager => _legacyStateManager;

  void _syncIdentityFromLegacy() {
    _identityManager.syncFromLegacy(
      myUserName: _legacyStateManager.myUserName,
      otherUserName: _legacyStateManager.otherUserName,
      myPersistentId: _legacyStateManager.myPersistentId,
      theirEphemeralId: _legacyStateManager.theirEphemeralId,
      theirPersistentKey: _legacyStateManager.theirPersistentKey,
      currentSessionId: _legacyStateManager.currentSessionId,
    );
  }

  // ============================================================================
  // INITIALIZATION & LIFECYCLE
  // ============================================================================

  @override
  Future<void> initialize() async {
    _logger.info('🚀 Initializing BLEStateManagerFacade...');
    await _legacyStateManager.initialize();
    await _identityManager.initialize();
    _syncIdentityFromLegacy();
    _logger.info('🎯 BLEStateManagerFacade ready');
  }

  @override
  Future<void> loadUserName() async {
    await _legacyStateManager.loadUserName();
    _syncIdentityFromLegacy();
  }

  @override
  Future<String> getMyPersistentId() => _legacyStateManager.getMyPersistentId();

  @override
  void dispose() {
    _legacyStateManager.dispose();
  }

  // ============================================================================
  // USER IDENTITY
  // ============================================================================

  @override
  Future<void> setMyUserName(String name) async {
    await _legacyStateManager.setMyUserName(name);
    _syncIdentityFromLegacy();
  }

  @override
  Future<void> setMyUserNameWithCallbacks(String name) async {
    await _legacyStateManager.setMyUserNameWithCallbacks(name);
    _syncIdentityFromLegacy();
  }

  @override
  void clearOtherUserName() => _legacyStateManager.clearOtherUserName();

  // ============================================================================
  // PEER IDENTITY
  // ============================================================================

  @override
  void setOtherUserName(String? name) {
    _legacyStateManager.setOtherUserName(name);
    _identityManager.syncFromLegacy(otherUserName: name);
  }

  @override
  void setOtherDeviceIdentity(String deviceId, String displayName) {
    _legacyStateManager.setOtherDeviceIdentity(deviceId, displayName);
    _identityManager.syncFromLegacy(
      otherUserName: displayName,
      currentSessionId: deviceId,
    );
  }

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    _legacyStateManager.setTheirEphemeralId(ephemeralId, displayName);
    _identityManager.syncFromLegacy(
      theirEphemeralId: ephemeralId,
      otherUserName: displayName,
    );
  }

  @override
  String? getRecipientId() => _legacyStateManager.getRecipientId();

  @override
  String getIdType() => _legacyStateManager.getIdType();

  @override
  String? getPersistentKeyFromEphemeral(String ephemeralId) =>
      _legacyStateManager.getPersistentKeyFromEphemeral(ephemeralId);

  // ============================================================================
  // CONTACT REPOSITORY ACCESS
  // ============================================================================

  @override
  Future<void> saveContact(String publicKey, String userName) =>
      _legacyStateManager.saveContact(publicKey, userName);

  @override
  Future<Contact?> getContact(String publicKey) =>
      _legacyStateManager.getContact(publicKey);

  @override
  Future<Map<String, Contact>> getAllContacts() async =>
      await _legacyStateManager.getAllContacts();

  @override
  Future<String?> getContactName(String publicKey) =>
      _legacyStateManager.getContactName(publicKey);

  @override
  Future<void> markContactVerified(String publicKey) =>
      _legacyStateManager.markContactVerified(publicKey);

  @override
  Future<TrustStatus> getContactTrustStatus(String publicKey) =>
      _legacyStateManager.getContactTrustStatus(publicKey);

  @override
  Future<bool> hasContactKeyChanged(
    String publicKey,
    String currentDisplayName,
  ) => _legacyStateManager.hasContactKeyChanged(publicKey, currentDisplayName);

  // ============================================================================
  // PAIRING FLOW (delegated with coordinator notification)
  // ============================================================================

  @override
  Future<void> sendPairingRequest() async {
    await _stateCoordinator.sendPairingRequest();
  }

  @override
  Future<void> handlePairingRequest(ProtocolMessage message) async {
    await _stateCoordinator.handlePairingRequest(message);
  }

  @override
  Future<void> acceptPairingRequest() async {
    await _stateCoordinator.acceptPairingRequest();
  }

  @override
  void rejectPairingRequest() {
    _stateCoordinator.rejectPairingRequest();
  }

  @override
  Future<void> handlePairingAccept(ProtocolMessage message) async {
    await _stateCoordinator.handlePairingAccept(message);
  }

  @override
  void handlePairingCancel(ProtocolMessage message) {
    _stateCoordinator.handlePairingCancel(message);
  }

  @override
  void cancelPairing({String? reason}) {
    _stateCoordinator.cancelPairing(reason: reason);
  }

  // ============================================================================
  // CONTACT REQUEST FLOW
  // ============================================================================

  @override
  Future<void> handleContactRequest(
    String publicKey,
    String displayName,
  ) async => _legacyStateManager.handleContactRequest(publicKey, displayName);

  @override
  Future<void> acceptContactRequest() =>
      _legacyStateManager.acceptContactRequest();

  @override
  void rejectContactRequest() => _legacyStateManager.rejectContactRequest();

  @override
  Future<bool> sendContactRequest() => _legacyStateManager.sendContactRequest();

  @override
  Future<void> handleContactAccept(String publicKey, String displayName) async {
    _legacyStateManager.handleContactAccept(publicKey, displayName);
  }

  @override
  void handleContactReject() => _legacyStateManager.handleContactReject();

  @override
  Future<bool> initiateContactRequest() =>
      _legacyStateManager.initiateContactRequest();

  // ============================================================================
  // SECURITY & CONTACT STATUS
  // ============================================================================

  @override
  Future<void> ensureContactMaximumSecurity(String contactPublicKey) =>
      _legacyStateManager.ensureContactMaximumSecurity(contactPublicKey);

  @override
  Future<bool> checkExistingPairing(String publicKey) =>
      _legacyStateManager.checkExistingPairing(publicKey);

  @override
  Future<void> checkForQRIntroduction(
    String otherPublicKey,
    String otherName,
  ) => _legacyStateManager.checkForQRIntroduction(otherPublicKey, otherName);

  @override
  Future<void> requestSecurityLevelSync() =>
      _legacyStateManager.requestSecurityLevelSync();

  @override
  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) =>
      _legacyStateManager.handleSecurityLevelSync(payload);

  @override
  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) => _legacyStateManager.confirmSecurityUpgrade(publicKey, newLevel);

  @override
  Future<bool> resetContactSecurity(String publicKey, String reason) =>
      _legacyStateManager.resetContactSecurity(publicKey, reason);

  @override
  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  ) => _legacyStateManager.handleContactStatus(
    theyHaveUsAsContact,
    theirPublicKey,
  );

  @override
  Future<void> requestContactStatusExchange() =>
      _legacyStateManager.requestContactStatusExchange();

  // ============================================================================
  // SPY MODE
  // ============================================================================

  @override
  Future<ProtocolMessage?> revealIdentityToFriend() =>
      _legacyStateManager.revealIdentityToFriend();

  // ============================================================================
  // SESSION LIFECYCLE
  // ============================================================================

  @override
  void setPeripheralMode(bool isPeripheral) {
    _legacyStateManager.setPeripheralMode(isPeripheral);
  }

  @override
  void clearSessionState({bool preservePersistentId = false}) {
    _legacyStateManager.clearSessionState(
      preservePersistentId: preservePersistentId,
    );
    _syncIdentityFromLegacy();
  }

  @override
  Future<void> recoverIdentityFromStorage() =>
      _legacyStateManager.recoverIdentityFromStorage();

  @override
  Future<Map<String, String?>> getIdentityWithFallback() =>
      _legacyStateManager.getIdentityWithFallback();

  @override
  void preserveContactRelationship({
    String? otherPublicKey,
    String? otherName,
    bool? theyHaveUs,
    bool? weHaveThem,
  }) => _legacyStateManager.preserveContactRelationship(
    otherPublicKey: otherPublicKey,
    otherName: otherName,
    theyHaveUs: theyHaveUs,
    weHaveThem: weHaveThem,
  );

  // ============================================================================
  // STATE QUERIES & GETTERS
  // ============================================================================

  @override
  String? get myUserName =>
      _legacyStateManager.myUserName ?? _identityManager.myUserName;

  @override
  String? get otherUserName =>
      _legacyStateManager.otherUserName ?? _identityManager.otherUserName;

  @override
  bool get isConnected => _legacyStateManager.isConnected;

  @override
  bool get isPeripheralMode => _legacyStateManager.isPeripheralMode;

  @override
  bool get hasContactRequest => _legacyStateManager.hasContactRequest;

  @override
  String? get pendingContactName => _legacyStateManager.pendingContactName;

  @override
  bool get theyHaveUsAsContact => _legacyStateManager.theyHaveUsAsContact;

  @override
  Future<bool> get weHaveThemAsContact =>
      _legacyStateManager.weHaveThemAsContact;

  @override
  String? get myPersistentId =>
      _legacyStateManager.myPersistentId ?? _identityManager.myPersistentId;

  @override
  String? get myEphemeralId => _legacyStateManager.myEphemeralId;

  @override
  String? get theirEphemeralId =>
      _legacyStateManager.theirEphemeralId ?? _identityManager.theirEphemeralId;

  @override
  String? get theirPersistentKey =>
      _legacyStateManager.theirPersistentKey ??
      _identityManager.theirPersistentKey;

  @override
  String? get currentSessionId =>
      _legacyStateManager.currentSessionId ?? _identityManager.currentSessionId;

  @override
  PairingInfo? get currentPairing => _pairingService.currentPairing;

  @override
  bool get isPaired => _legacyStateManager.isPaired;

  // ============================================================================
  // CALLBACKS
  // ============================================================================

  @override
  void Function(dynamic device, int? rssi)? get onDeviceDiscovered =>
      _legacyStateManager.onDeviceDiscovered;
  @override
  set onDeviceDiscovered(void Function(dynamic device, int? rssi)? value) =>
      _legacyStateManager.onDeviceDiscovered = value;

  @override
  void Function(String messageId, bool success)? get onMessageSent =>
      _legacyStateManager.onMessageSent;
  @override
  set onMessageSent(void Function(String messageId, bool success)? value) =>
      _legacyStateManager.onMessageSent = value;

  @override
  void Function(MessageId messageId, bool success)? get onMessageSentIds =>
      _legacyStateManager.onMessageSentIds;
  @override
  set onMessageSentIds(
    void Function(MessageId messageId, bool success)? value,
  ) => _legacyStateManager.onMessageSentIds = value;

  @override
  void Function(String? newName)? get onNameChanged =>
      _legacyStateManager.onNameChanged;
  @override
  set onNameChanged(void Function(String? newName)? value) {
    _legacyStateManager.onNameChanged = value;
    _identityManager.onNameChanged = value;
  }

  @override
  void Function(String newName)? get onMyUsernameChanged =>
      _legacyStateManager.onMyUsernameChanged;
  @override
  set onMyUsernameChanged(void Function(String newName)? value) {
    _legacyStateManager.onMyUsernameChanged = value;
    _identityManager.onMyUsernameChanged = value;
  }

  @override
  void Function(String code)? get onSendPairingCode =>
      _legacyStateManager.onSendPairingCode;
  @override
  set onSendPairingCode(void Function(String code)? value) {
    _legacyStateManager.onSendPairingCode = value;
    _pairingService.onSendPairingCode = value;
  }

  @override
  void Function(String verification)? get onSendPairingVerification =>
      _legacyStateManager.onSendPairingVerification;
  @override
  set onSendPairingVerification(void Function(String verification)? value) {
    _legacyStateManager.onSendPairingVerification = value;
    _pairingService.onSendPairingVerification = value;
  }

  @override
  void Function(String publicKey, String displayName)?
  get onContactRequestReceived => _legacyStateManager.onContactRequestReceived;
  @override
  set onContactRequestReceived(
    void Function(String publicKey, String displayName)? value,
  ) => _legacyStateManager.onContactRequestReceived = value;

  @override
  void Function(bool success)? get onContactRequestCompleted =>
      _legacyStateManager.onContactRequestCompleted;
  @override
  set onContactRequestCompleted(void Function(bool success)? value) =>
      _legacyStateManager.onContactRequestCompleted = value;

  @override
  void Function(String publicKey, String displayName)?
  get onSendContactRequest => _legacyStateManager.onSendContactRequest;
  @override
  set onSendContactRequest(
    void Function(String publicKey, String displayName)? value,
  ) => _legacyStateManager.onSendContactRequest = value;

  @override
  void Function(String publicKey, String displayName)?
  get onSendContactAccept => _legacyStateManager.onSendContactAccept;
  @override
  set onSendContactAccept(
    void Function(String publicKey, String displayName)? value,
  ) => _legacyStateManager.onSendContactAccept = value;

  @override
  void Function()? get onSendContactReject =>
      _legacyStateManager.onSendContactReject;
  @override
  set onSendContactReject(void Function()? value) =>
      _legacyStateManager.onSendContactReject = value;

  @override
  void Function(ProtocolMessage message)? get onSendContactStatus =>
      _legacyStateManager.onSendContactStatus;
  @override
  set onSendContactStatus(void Function(ProtocolMessage message)? value) =>
      _legacyStateManager.onSendContactStatus = value;

  @override
  void Function(String publicKey, String displayName)?
  get onAsymmetricContactDetected =>
      _legacyStateManager.onAsymmetricContactDetected;
  @override
  set onAsymmetricContactDetected(
    void Function(String publicKey, String displayName)? value,
  ) => _legacyStateManager.onAsymmetricContactDetected = value;

  @override
  void Function(String publicKey, String displayName)?
  get onMutualConsentRequired => _legacyStateManager.onMutualConsentRequired;
  @override
  set onMutualConsentRequired(
    void Function(String publicKey, String displayName)? value,
  ) => _legacyStateManager.onMutualConsentRequired = value;

  @override
  void Function(SpyModeInfo info)? get onSpyModeDetected =>
      _legacyStateManager.onSpyModeDetected;
  @override
  set onSpyModeDetected(void Function(SpyModeInfo info)? value) =>
      _legacyStateManager.onSpyModeDetected = value;

  @override
  void Function(String contactId)? get onIdentityRevealed =>
      _legacyStateManager.onIdentityRevealed;
  @override
  set onIdentityRevealed(void Function(String contactId)? value) =>
      _legacyStateManager.onIdentityRevealed = value;

  @override
  void Function(ProtocolMessage message)? get onSendPairingRequest =>
      _pairingService.onSendPairingRequest;
  @override
  set onSendPairingRequest(void Function(ProtocolMessage message)? value) =>
      _pairingService.onSendPairingRequest = value;

  @override
  void Function(ProtocolMessage message)? get onSendPairingAccept =>
      _pairingService.onSendPairingAccept;
  @override
  set onSendPairingAccept(void Function(ProtocolMessage message)? value) =>
      _pairingService.onSendPairingAccept = value;

  @override
  void Function(ProtocolMessage message)? get onSendPairingCancel =>
      _pairingService.onSendPairingCancel;
  @override
  set onSendPairingCancel(void Function(ProtocolMessage message)? value) =>
      _pairingService.onSendPairingCancel = value;

  @override
  void Function()? get onPairingCancelled => _pairingService.onPairingCancelled;
  @override
  set onPairingCancelled(void Function()? value) =>
      _pairingService.onPairingCancelled = value;

  @override
  void Function(ProtocolMessage message)? get onSendPersistentKeyExchange =>
      _legacyStateManager.onSendPersistentKeyExchange;
  @override
  set onSendPersistentKeyExchange(
    void Function(ProtocolMessage message)? value,
  ) => _legacyStateManager.onSendPersistentKeyExchange = value;
}
