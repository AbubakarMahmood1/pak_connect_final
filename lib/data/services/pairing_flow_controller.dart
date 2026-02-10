import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/bluetooth/identity_session_state.dart';
import '../../core/models/pairing_state.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/services/security_manager.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../data/repositories/contact_repository.dart';
import 'pairing_lifecycle_service.dart';
import 'pairing_service.dart';
import 'pairing_failure_handler.dart';
import 'pairing_request_coordinator.dart';
import 'pairing_ui_orchestrator.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Handles pairing flows, persistent key exchange, and security upgrades
/// so BLEStateManager can delegate.
class PairingFlowController {
  PairingFlowController({
    required Logger logger,
    required ContactRepository contactRepository,
    required IdentitySessionState identityState,
    required Map<String, String> conversationKeys,
    required Future<String> Function() myPersistentIdProvider,
    required String? Function() myUserNameProvider,
    required String? Function() otherUserNameProvider,
    required PairingLifecycleService pairingLifecycleService,
    PairingService? pairingService,
    PairingFailureHandler? pairingFailureHandler,
    PairingRequestCoordinator? pairingRequestCoordinator,
    PairingUiOrchestrator? pairingUiOrchestrator,
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _identityState = identityState,
       _conversationKeys = conversationKeys,
       _getMyPersistentId = myPersistentIdProvider,
       _myUserName = myUserNameProvider,
       _otherUserName = otherUserNameProvider,
       _pairingLifecycle = pairingLifecycleService,
       _pairingFailureHandler =
           pairingFailureHandler ??
           PairingFailureHandler(
             logger: logger,
             contactRepository: contactRepository,
             conversationKeys: conversationKeys,
           ),
       _pairingRequestCoordinator = pairingRequestCoordinator,
       _pairingUiOrchestrator =
           pairingUiOrchestrator ?? PairingUiOrchestrator(logger: logger) {
    _pairingService =
        pairingService ??
        PairingService(
          getMyPersistentId: _getMyPersistentId,
          getTheirSessionId: () => _theirPersistentKey ?? _currentSessionId,
          getTheirDisplayName: _otherUserName,
          onVerificationComplete: (theirId, sharedSecret, displayName) =>
              _handleVerificationSuccess(
                theirId: theirId,
                sharedSecret: sharedSecret,
                displayName: displayName,
              ),
          onVerificationFailure: (reason) => _handleVerificationFailure(reason),
        );
  }

  final Logger _logger;
  final ContactRepository _contactRepository;
  final IdentitySessionState _identityState;
  final Map<String, String> _conversationKeys;
  final Future<String> Function() _getMyPersistentId;
  final String? Function() _myUserName;
  final String? Function() _otherUserName;
  final PairingLifecycleService _pairingLifecycle;
  final PairingFailureHandler _pairingFailureHandler;
  PairingRequestCoordinator? _pairingRequestCoordinator;
  final PairingUiOrchestrator _pairingUiOrchestrator;

  // Pairing lifecycle state
  late final PairingService _pairingService;

  PairingInfo? get _pairingState => _pairingService.currentPairing;
  void _setPairingState(PairingInfo? info) =>
      _pairingService.setCurrentPairing(info);

  // Callbacks
  Function(String)? get onSendPairingCode => _pairingService.onSendPairingCode;
  set onSendPairingCode(Function(String)? callback) =>
      _pairingService.onSendPairingCode = callback;

  Function(String)? get onSendPairingVerification =>
      _pairingService.onSendPairingVerification;
  set onSendPairingVerification(Function(String)? callback) =>
      _pairingService.onSendPairingVerification = callback;

  Function(String ephemeralId, String displayName)? onPairingRequestReceived;
  Function()? onPairingCancelled;
  Function(ProtocolMessage)? onSendPairingRequest;
  Function(ProtocolMessage)? onSendPairingAccept;
  Function(ProtocolMessage)? onSendPairingCancel;
  Function(ProtocolMessage)? onSendPersistentKeyExchange;
  Function(bool)? onContactRequestCompleted;
  Function(SpyModeInfo info)? onSpyModeDetected;

  // Accessors to identity state
  String? get _currentSessionId => _identityState.currentSessionId;
  String? get _theirEphemeralId => _identityState.theirEphemeralId;
  String? get _theirPersistentKey => _identityState.theirPersistentKey;
  set _theirPersistentKey(String? value) =>
      _identityState.theirPersistentKey = value;

  PairingInfo? get currentPairing => _pairingService.currentPairing;
  bool get isPaired => _theirPersistentKey != null;

  String generatePairingCode() => _pairingService.generatePairingCode();
  Future<bool> completePairing(String theirCode) async {
    await _pairingService.completePairing(theirCode);
    return _pairingState?.state == PairingState.completed &&
        _pairingState?.sharedSecret != null;
  }

  void handleReceivedPairingCode(String theirCode) =>
      _pairingService.handleReceivedPairingCode(theirCode);
  Future<void> handlePairingVerification(String theirSecretHash) async {
    await _pairingService.handlePairingVerification(theirSecretHash);
  }

  /// Store the ephemeral ID received during handshake
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    _logger.info('Storing their ephemeral ID: $ephemeralId ($displayName)');
    _identityState.setTheirEphemeralId(ephemeralId);
  }

  Future<void> _handleVerificationFailure(String reason) async {
    await _pairingFailureHandler.handleVerificationFailure(
      previousPairing: _pairingState,
      currentSessionId: _currentSessionId,
      theirPersistentKey: _theirPersistentKey,
      setPairingState: _setPairingState,
      setTheirPersistentKey: (value) => _theirPersistentKey = value,
      onPairingCancelled: onPairingCancelled,
      identityState: _identityState,
      pairingService: _pairingService,
      reason: reason,
    );
  }

  Future<void> sendPairingRequest() async {
    _ensureRequestCoordinator();
    await _pairingRequestCoordinator!.sendPairingRequest(
      theirEphemeralId: _theirEphemeralId ?? '',
    );
    _logger.info('✅ Pairing request sent, waiting for accept...');
  }

  void handlePairingRequest(ProtocolMessage message) {
    _ensureRequestCoordinator();
    _pairingRequestCoordinator!.handlePairingRequest(message);
    _pairingUiOrchestrator.triggerPairingPopup(
      message.payload['ephemeralId'] as String,
      message.payload['displayName'] as String,
      onPairingRequestReceived,
    );
  }

  Future<void> acceptPairingRequest() async {
    _ensureRequestCoordinator();
    await _pairingRequestCoordinator!.acceptPairingRequest();
  }

  Future<void> rejectPairingRequest() async {
    _ensureRequestCoordinator();
    await _pairingRequestCoordinator!.rejectPairingRequest();
  }

  void handlePairingAccept(ProtocolMessage message) {
    _ensureRequestCoordinator();
    _pairingRequestCoordinator!.handlePairingAccept(message);
  }

  void handlePairingCancel(ProtocolMessage message) {
    _ensureRequestCoordinator();
    _pairingRequestCoordinator!.handlePairingCancel(message);
    _pairingUiOrchestrator.scheduleStateClear(
      Duration(seconds: 1),
      () => _setPairingState(null),
    );
  }

  Future<void> cancelPairing({String? reason}) async {
    _ensureRequestCoordinator();
    await _pairingRequestCoordinator!.cancelPairing(reason: reason);
    _pairingUiOrchestrator.scheduleStateClear(
      Duration(seconds: 1),
      () => _setPairingState(null),
    );
  }

  Future<void> ensureContactMaximumSecurity(String contactPublicKey) async {
    final userId = _toUserId(contactPublicKey);
    if (userId == null) {
      _logger.warning('ensureContactMaximumSecurity called with empty key');
      return;
    }

    if (SimpleCrypto.hasConversationKey(userId.value)) {
      _logger.info('✅ Contact already has maximum security (ECDH + Pairing)');
      return;
    }

    _logger.info(
      '🔐 Creating pairing key for contact to enable enhanced security',
    );

    final cachedSecret = await _contactRepository.getCachedSharedSecret(
      userId.value,
    );
    if (cachedSecret != null) {
      final myId = await _getMyPersistentId();
      final conversationSeed = cachedSecret + myId + userId.value;

      SimpleCrypto.initializeConversation(userId.value, conversationSeed);
      _conversationKeys[userId.value] = conversationSeed;

      _logger.info('✅ Enhanced security initialized for contact');
    }
  }

  Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
    await _pairingLifecycle.handlePersistentKeyExchange(
      theirPersistentKey: theirPersistentKey,
      displayName: _otherUserName(),
      onSpyModeDetected: onSpyModeDetected,
    );
  }

  Future<bool> confirmSecurityUpgrade(
    String publicKey,
    SecurityLevel newLevel,
  ) async {
    final userId = _toUserId(publicKey);
    if (userId == null) {
      _logger.warning('confirmSecurityUpgrade called with empty key');
      return false;
    }

    _logger.fine(
      '[BLEStateManager] 🔧 DEBUG: confirmSecurityUpgrade called for ${_truncateId(userId.value)} to ${newLevel.name}',
    );

    try {
      final existingContact = await _contactRepository.getContactByUserId(
        userId,
      );

      if (existingContact == null) {
        _logger.fine(
          '[BLEStateManager] 🔧 DEBUG: No existing contact - creating new with ${newLevel.name} level',
        );
        await _contactRepository.saveContactWithSecurity(
          userId.value,
          'Unknown',
          newLevel,
        );
        onContactRequestCompleted?.call(true);
        return true;
      }

      _logger.fine(
        '🔧 DEBUG: Current level: ${existingContact.securityLevel.name}, Target: ${newLevel.name}',
      );

      if (existingContact.securityLevel == SecurityLevel.high) {
        if (newLevel == SecurityLevel.medium) {
          _logger.fine(
            '🔧 DEBUG: Contact already has ECDH (high security) - pairing unnecessary',
          );

          await _initializeCryptoForLevel(userId.value, SecurityLevel.high);

          onContactRequestCompleted?.call(true);
          return true;
        }
      }

      if (existingContact.securityLevel == newLevel) {
        _logger.fine(
          '🔧 DEBUG: Already at ${newLevel.name} level - re-initializing crypto',
        );
        await _initializeCryptoForLevel(userId.value, newLevel);
        onContactRequestCompleted?.call(true);
        return true;
      }

      if (newLevel.index > existingContact.securityLevel.index) {
        _logger.fine(
          '🔧 DEBUG: Valid upgrade from ${existingContact.securityLevel.name} to ${newLevel.name}',
        );
        final success = await _contactRepository.upgradeContactSecurity(
          userId.value,
          newLevel,
        );
        if (success) {
          await _initializeCryptoForLevel(userId.value, newLevel);
          onContactRequestCompleted?.call(true);
        }
        return success;
      } else {
        _logger.warning('🔧 DEBUG: Invalid downgrade attempt blocked');
        onContactRequestCompleted?.call(true);
        return false;
      }
    } catch (e) {
      _logger.severe('🔧 DEBUG: confirmSecurityUpgrade failed: $e');
      return false;
    }
  }

  Future<bool> resetContactSecurity(String publicKey, String reason) async {
    final userId = _toUserId(publicKey);
    if (userId == null) {
      _logger.warning('resetContactSecurity called with empty key');
      return false;
    }

    _logger.warning('🔧 SECURITY RESET: Resetting $publicKey due to: $reason');

    try {
      final success = await _contactRepository.resetContactSecurity(
        userId.value,
        reason,
      );

      if (success) {
        SimpleCrypto.clearConversationKey(userId.value);
        onContactRequestCompleted?.call(true);
      }

      return success;
    } catch (e) {
      _logger.severe('🔧 SECURITY RESET FAILED: $e');
      return false;
    }
  }

  Future<void> handleSecurityLevelSync(Map<String, dynamic> payload) async {
    final theirSecurityLevel =
        SecurityLevel.values[payload['securityLevel'] as int];

    _logger.fine(
      '🔒 SECURITY SYNC: They have us at ${theirSecurityLevel.name} level',
    );

    if (_currentSessionId != null) {
      final ourSecurityLevel = await _contactRepository.getContactSecurityLevel(
        _currentSessionId!,
      );

      _logger.fine(
        '🔒 SECURITY SYNC: We have them at ${ourSecurityLevel.name} level',
      );

      final mutualLevel = ourSecurityLevel.index < theirSecurityLevel.index
          ? ourSecurityLevel
          : theirSecurityLevel;

      _logger.fine(
        '🔒 SECURITY SYNC: Mutual level determined: ${mutualLevel.name}',
      );

      if (ourSecurityLevel != mutualLevel) {
        await _contactRepository.updateContactSecurityLevel(
          _currentSessionId!,
          mutualLevel,
        );
        _logger.fine(
          '🔒 SECURITY SYNC: Updated our level to match mutual: ${mutualLevel.name}',
        );

        onContactRequestCompleted?.call(true);
      }
    }
  }

  void clearPairing() {
    _pairingService.clearPairing();
    _logger.info('Pairing state cleared');
  }

  void _ensureRequestCoordinator() {
    _pairingRequestCoordinator ??= PairingRequestCoordinator(
      logger: _logger,
      pairingService: _pairingService,
      identityState: _identityState,
      myUserName: _myUserName,
      otherUserName: _otherUserName,
      getPairingState: () => _pairingState,
      setPairingState: _setPairingState,
      onRequestReceived: onPairingRequestReceived,
      onSendPairingRequest: onSendPairingRequest,
      onSendPairingAccept: onSendPairingAccept,
      onSendPairingCancel: onSendPairingCancel,
      onPairingCancelled: onPairingCancelled,
      unregisterIdentityMapping: (key) {
        _theirPersistentKey = null;
      },
    );
  }

  Future<void> _handleVerificationSuccess({
    required String theirId,
    required String sharedSecret,
    required String? displayName,
  }) async {
    try {
      await _pairingLifecycle.ensureContactExistsAfterHandshake(
        _currentSessionId ?? theirId,
        displayName ?? _otherUserName() ?? 'User',
        ephemeralId: _theirEphemeralId,
      );

      await _pairingLifecycle.cacheSharedSecret(
        contactId: theirId,
        alternateSessionId:
            _currentSessionId != null && _currentSessionId != theirId
            ? _currentSessionId
            : null,
        sharedSecret: sharedSecret,
      );

      if (_theirEphemeralId != null && _theirPersistentKey != null) {
        await _pairingLifecycle.upgradeContactToMediumSecurity(
          theirEphemeralId: _theirEphemeralId,
          theirPersistentKey: _theirPersistentKey!,
          displayName: displayName ?? _otherUserName(),
        );
      }

      await _exchangePersistentKeys();
    } catch (e) {
      _logger.severe('Verification success handling failed: $e');
    }
  }

  Future<void> _exchangePersistentKeys() async {
    final myPersistentKey = await _getMyPersistentId();

    if (_theirEphemeralId == null) {
      _logger.warning('❌ Cannot exchange persistent keys - no ephemeral ID');
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    _logger.info(
      '🔑 STEP 4: Exchanging persistent keys (my ephemeral: $myEphId)',
    );

    final message = ProtocolMessage.persistentKeyExchange(
      persistentPublicKey: myPersistentKey,
    );

    onSendPersistentKeyExchange?.call(message);
    _logger.info('📤 STEP 4: Sent my persistent public key');
  }

  Future<void> _initializeCryptoForLevel(
    String publicKey,
    SecurityLevel level,
  ) async {
    switch (level) {
      case SecurityLevel.medium:
        if (!SimpleCrypto.hasConversationKey(publicKey)) {
          final secret = _conversationKeys[publicKey];
          if (secret != null) {
            SimpleCrypto.initializeConversation(publicKey, secret);
          }
        }
        break;

      case SecurityLevel.high:
        final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
          await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        }
        break;

      case SecurityLevel.low:
        break;
    }
  }

  String _truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }

  UserId? _toUserId(String publicKey) {
    if (publicKey.isEmpty) return null;
    return UserId(publicKey);
  }
}
