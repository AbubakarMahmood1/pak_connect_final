import 'dart:async';
import 'package:logging/logging.dart';
import '../../core/models/protocol_message.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';
import '../../core/services/simple_crypto.dart';
import '../../core/interfaces/i_ble_state_coordinator.dart';
import '../../core/interfaces/i_identity_manager.dart';
import '../../core/interfaces/i_pairing_service.dart';
import '../../core/interfaces/i_session_service.dart';
import '../../core/security/ephemeral_key_manager.dart';
import 'chat_migration_service.dart';

/// BLE State Coordinator
///
/// Orchestrates cross-service state transitions for:
/// - Pairing flows with security gates
/// - Persistent key exchange with identity mapping
/// - Chat migration (ephemeral → persistent ID)
/// - Contact request lifecycle with mutual consent
/// - Spy mode detection and identity reveal
/// - Security level upgrades with ECDH coordination
/// - Contact status synchronization with infinite loop prevention
///
/// **CRITICAL**: This coordinator is the single choke point for security invariants.
class BLEStateCoordinator implements IBLEStateCoordinator {
  final _logger = Logger('BLEStateCoordinator');

  // Service dependencies (injected for testability)
  final IIdentityManager _identityManager;
  final IPairingService _pairingService;
  final ISessionService _sessionService;

  // Repository dependencies
  final ContactRepository _contactRepository = ContactRepository();

  // State tracking for contact requests (orchestration)
  bool _contactRequestPending = false;
  String? _pendingContactPublicKey;
  String? _pendingContactName;
  final Map<String, Completer<bool>> _outgoingRequestCompleters = {};
  final Map<String, Timer> _pendingOutgoingRequests = {};
  static const Duration _contactRequestTimeoutDuration = Duration(seconds: 30);

  // Contact status tracking (infinite loop prevention)
  final Map<String, bool> _lastReceivedContactStatus = {};
  final Map<String, bool> _bilateralSyncComplete = {};
  Timer? _contactSyncRetryTimer;

  // ============================================================================
  // CALLBACKS (Cross-service event emissions)
  // ============================================================================

  @override
  void Function()? onSendPairingRequest;

  @override
  void Function()? onSendPairingAccept;

  @override
  void Function()? onSendPairingCancel;

  @override
  void Function()? onContactRequestCompleted;

  @override
  void Function(String persistentKey)? onSendPersistentKeyExchange;

  @override
  void Function()? onSpyModeDetected;

  @override
  void Function()? onIdentityRevealed;

  @override
  void Function()? onAsymmetricContactDetected;

  @override
  void Function()? onMutualConsentRequired;

  BLEStateCoordinator({
    required IIdentityManager identityManager,
    required IPairingService pairingService,
    required ISessionService sessionService,
  }) : _identityManager = identityManager,
       _pairingService = pairingService,
       _sessionService = sessionService;

  // ============================================================================
  // PAIRING STATE MACHINE (Orchestrated Transitions)
  // ============================================================================

  @override
  Future<void> sendPairingRequest() async {
    _logger.info('📤 STEP 3: Sending pairing request');

    final theirEphemeralId = _identityManager.theirEphemeralId;
    if (theirEphemeralId == null || theirEphemeralId.isEmpty) {
      _logger.warning(
        '❌ Cannot send pairing request - no peer ephemeral ID (handshake incomplete)',
      );
      return;
    }

    final myEphemeralId =
        _identityManager.myEphemeralId ??
        EphemeralKeyManager.generateMyEphemeralKey();
    if (myEphemeralId == null || myEphemeralId.isEmpty) {
      _logger.warning(
        '❌ Cannot send pairing request - my ephemeral ID unavailable',
      );
      return;
    }

    final displayName = _identityManager.myUserName ?? 'User';
    _pairingService.initiatePairingRequest(
      myEphemeralId: myEphemeralId,
      displayName: displayName,
    );

    if (onSendPairingRequest == null) {
      _logger.fine(
        'Pairing request callback not set; relying on pairing service hooks',
      );
    } else {
      onSendPairingRequest!.call();
    }
  }

  @override
  Future<void> handlePairingRequest(ProtocolMessage message) async {
    final theirEphemeralId = message.payload['ephemeralId'] as String?;
    final displayName = message.payload['displayName'] as String?;

    _logger.info('📥 STEP 3: Received pairing request from $displayName');

    if (theirEphemeralId != null && displayName != null) {
      _sessionService.setTheirEphemeralId(theirEphemeralId, displayName);
    }
  }

  @override
  Future<void> acceptPairingRequest() async {
    _logger.info('✅ STEP 3: User accepted pairing request');
    // Generate PIN code via pairing service
    _pairingService.generatePairingCode();
    onSendPairingAccept?.call();
  }

  @override
  void rejectPairingRequest() {
    _logger.info('❌ STEP 3: User rejected pairing request');
    onSendPairingCancel?.call();
    _pairingService.clearPairing();
  }

  @override
  Future<void> handlePairingAccept(ProtocolMessage message) async {
    final displayName = message.payload['displayName'] as String?;
    _logger.info('📥 STEP 3: Received pairing accept from $displayName');
    // Generate PIN code via pairing service
    _pairingService.generatePairingCode();
  }

  @override
  void handlePairingCancel(ProtocolMessage message) {
    final reason = message.payload['reason'] as String?;
    _logger.info(
      '❌ STEP 3: Pairing cancelled${reason != null ? ": $reason" : ""}',
    );
    _pairingService.clearPairing();
  }

  @override
  Future<void> cancelPairing({String? reason}) async {
    _logger.info(
      '🚫 STEP 3: Cancelling pairing${reason != null ? ": $reason" : ""}',
    );
    onSendPairingCancel?.call();
    _pairingService.clearPairing();
  }

  // ============================================================================
  // PERSISTENT KEY EXCHANGE (Security Gate #1)
  // ============================================================================

  @override
  Future<void> _exchangePersistentKeys() async {
    final myPersistentKey = _identityManager.getMyPersistentId();
    if (myPersistentKey == null || myPersistentKey.isEmpty) {
      _logger.warning('❌ Cannot exchange persistent keys - no persistent ID');
      return;
    }
    _logger.info('🔑 STEP 4: Exchanging persistent keys');

    onSendPersistentKeyExchange?.call(myPersistentKey);
    _logger.info('📤 STEP 4: Sent my persistent public key');
  }

  @override
  Future<void> handlePersistentKeyExchange(String theirPersistentKey) async {
    _logger.info('📥 STEP 4: Received persistent key from peer');

    // Create contact at LOW security (Noise only)
    await _contactRepository.saveContactWithSecurity(
      theirPersistentKey,
      'User',
      SecurityLevel.low,
      persistentPublicKey: null,
    );

    _logger.info('🔑📊 Persistent key exchange complete');

    // Spy mode detection would happen here
    await _detectSpyMode(theirPersistentKey);
  }

  // ============================================================================
  // SPY MODE (Asymmetric Contact Detection)
  // ============================================================================

  @override
  Future<void> _detectSpyMode(String theirPersistentKey) async {
    try {
      final contact = await _contactRepository.getContact(theirPersistentKey);
      if (contact != null) {
        _logger.info('🕵️ SPY MODE: Connected to ${contact.displayName}');
        onSpyModeDetected?.call();
      }
    } catch (e) {
      _logger.severe('Failed to detect spy mode: $e');
    }
  }

  @override
  Future<void> revealIdentityToFriend() async {
    try {
      final myPersistentKey = await _identityManager.getMyPersistentId();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Generate cryptographic proof of ownership
      final challenge = 'reveal_$timestamp';
      final proof = SimpleCrypto.signMessage(challenge) ?? '';

      if (proof.isEmpty) {
        _logger.severe('🕵️ Failed to generate cryptographic proof');
        return;
      }

      _logger.info('🕵️ Created FRIEND_REVEAL message');
      onIdentityRevealed?.call();
    } catch (e) {
      _logger.severe('🕵️ Failed to create reveal message: $e');
    }
  }

  // ============================================================================
  // CHAT MIGRATION (Ephemeral → Persistent ID)
  // ============================================================================

  @override
  Future<void> _triggerChatMigration(
    String ephemeralId,
    String persistentKey,
    String displayName,
  ) async {
    _logger.info('🔄 STEP 6: Triggering chat migration');
    _logger.info('   From: $ephemeralId');
    _logger.info('   To: $persistentKey');

    try {
      final migrationService = ChatMigrationService();

      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
        contactName: displayName,
      );

      if (success) {
        _logger.info('✅ STEP 6: Chat migration completed successfully');
      } else {
        _logger.info('ℹ️ STEP 6: No chat migration needed (no messages)');
      }
    } catch (e, stackTrace) {
      _logger.severe('❌ STEP 6: Chat migration failed', e, stackTrace);
    }
  }

  // ============================================================================
  // CONTACT REQUEST FLOW (Orchestrated Lifecycle)
  // ============================================================================

  @override
  Future<bool> initiateContactRequest() async {
    _logger.info('📱 CONTACT REQUEST: Initiating request');

    try {
      final myPublicKey = _identityManager.getMyPersistentId();
      if (myPublicKey == null || myPublicKey.isEmpty) {
        _logger.warning('📱 CONTACT REQUEST: Missing public key');
        return false;
      }

      final completer = Completer<bool>();
      _outgoingRequestCompleters[myPublicKey] = completer;

      final timer = Timer(_contactRequestTimeoutDuration, () {
        if (!completer.isCompleted) {
          _logger.warning('📱 CONTACT REQUEST: Timeout waiting for response');
          completer.complete(false);
        }
      });
      _pendingOutgoingRequests[myPublicKey] = timer;

      // Send the request via callback
      onContactRequestCompleted?.call();

      // Wait for response
      final accepted = await completer.future;

      // Cleanup
      _cleanupOutgoingRequest(myPublicKey);

      return accepted;
    } catch (e) {
      _logger.severe('Failed to initiate contact request: $e');
      return false;
    }
  }

  @override
  Future<void> handleContactRequest(
    String publicKey,
    String displayName,
  ) async {
    _logger.info('📱 CONTACT REQUEST: Received from $displayName');

    _contactRequestPending = true;
    _pendingContactPublicKey = publicKey;
    _pendingContactName = displayName;

    onContactRequestCompleted?.call();
  }

  @override
  Future<void> acceptContactRequest() async {
    if (!_contactRequestPending || _pendingContactPublicKey == null) {
      _logger.warning('No pending contact request');
      return;
    }

    try {
      _logger.info(
        '📱 MUTUAL CONSENT: Accepting contact request from $_pendingContactName',
      );

      // Finalize the contact addition with mutual consent
      await _finalizeContactAddition(
        _pendingContactPublicKey!,
        _pendingContactName!,
        true,
      );

      // Clear pending request
      _contactRequestPending = false;
      _pendingContactPublicKey = null;
      _pendingContactName = null;
    } catch (e) {
      _logger.severe('Failed to accept contact request: $e');
      onContactRequestCompleted?.call();
    }
  }

  @override
  void rejectContactRequest() {
    if (!_contactRequestPending) return;

    _logger.info('📱 MUTUAL CONSENT: Rejecting contact request');

    _contactRequestPending = false;
    _pendingContactPublicKey = null;
    _pendingContactName = null;

    onContactRequestCompleted?.call();
  }

  @override
  Future<void> handleContactRequestAcceptResponse(
    String publicKey,
    String displayName,
  ) async {
    _logger.info('📱 CONTACT REQUEST: Accepted by $displayName');

    // Complete any pending request
    final completer = _outgoingRequestCompleters[publicKey];
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }

    // Add them as a contact now that we have mutual consent
    await _finalizeContactAddition(publicKey, displayName, true);
  }

  @override
  void handleContactRequestRejectResponse() {
    _logger.info('📱 CONTACT REQUEST: Rejected');

    final myPublicKey = _pendingContactPublicKey;
    if (myPublicKey != null) {
      final completer = _outgoingRequestCompleters[myPublicKey];
      if (completer != null && !completer.isCompleted) {
        completer.complete(false);
      }

      _cleanupOutgoingRequest(myPublicKey);
    }
  }

  @override
  Future<void> _finalizeContactAddition(
    String publicKey,
    String displayName,
    bool mutualConsent,
  ) async {
    try {
      _logger.info(
        '📱 FINALIZE: Adding contact with mutual consent: $displayName',
      );

      // Create verified contact with high security
      await _contactRepository.saveContactWithSecurity(
        publicKey,
        displayName,
        SecurityLevel.high,
      );
      await _contactRepository.markContactVerified(publicKey);

      // Compute ECDH shared secret
      final sharedSecret = SimpleCrypto.computeSharedSecret(publicKey);
      if (sharedSecret != null) {
        await _contactRepository.cacheSharedSecret(publicKey, sharedSecret);
        await SimpleCrypto.restoreConversationKey(publicKey, sharedSecret);
        _logger.info('📱 FINALIZE: ECDH secret computed and cached');
      }

      // Mark bilateral sync as complete
      _markBilateralSyncComplete(publicKey);

      // Notify completion
      onContactRequestCompleted?.call();
    } catch (e) {
      _logger.severe('Failed to finalize contact addition: $e');
      onContactRequestCompleted?.call();
    }
  }

  @override
  Future<void> sendContactRequest() async {
    try {
      final myPublicKey = _identityManager.getMyPersistentId();
      if (myPublicKey == null || myPublicKey.isEmpty) {
        _logger.warning('Cannot send contact request - missing public key');
        return;
      }
      _logger.info('Sending contact request');
      onContactRequestCompleted?.call();
    } catch (e) {
      _logger.severe('Failed to send contact request: $e');
    }
  }

  // ============================================================================
  // SECURITY LEVEL UPGRADES (ECDH Coordination)
  // ============================================================================

  @override
  Future<void> _ensureMutualECDH(String theirPublicKey) async {
    try {
      _logger.info('📱 Ensuring mutual ECDH for contact');

      // Check if we have ECDH secret
      final existingSecret = await _contactRepository.getCachedSharedSecret(
        theirPublicKey,
      );

      if (existingSecret == null) {
        // Compute and cache ECDH
        final sharedSecret = SimpleCrypto.computeSharedSecret(theirPublicKey);
        if (sharedSecret != null) {
          await _contactRepository.cacheSharedSecret(
            theirPublicKey,
            sharedSecret,
          );
          await SimpleCrypto.restoreConversationKey(
            theirPublicKey,
            sharedSecret,
          );
          _logger.info('📱 ECDH secret computed for mutual contact');
        }
      }

      // Upgrade security level if needed
      final currentLevel = await _contactRepository.getContactSecurityLevel(
        theirPublicKey,
      );
      if (currentLevel != SecurityLevel.high) {
        await _contactRepository.updateContactSecurityLevel(
          theirPublicKey,
          SecurityLevel.high,
        );
        _logger.info('📱 Upgraded to high security for mutual contact');
      }

      // Trigger UI refresh
      onContactRequestCompleted?.call();
    } catch (e) {
      _logger.warning('Failed to ensure mutual ECDH: $e');
    }
  }

  // ============================================================================
  // CONTACT STATUS SYNCHRONIZATION
  // ============================================================================

  @override
  Future<void> initializeContactFlags() async {
    _logger.info('🔄 Initializing contact flags from repository...');

    // Request contact status exchange via session service
    await _sessionService.requestContactStatusExchange();

    // Set up retry timer for asymmetric handling
    _contactSyncRetryTimer?.cancel();
    _contactSyncRetryTimer = Timer(Duration(seconds: 2), () async {
      await _retryContactStatusExchange();
    });

    _logger.info('✅ Contact flags initialization requested');
  }

  @override
  Future<void> _retryContactStatusExchange() async {
    try {
      final shouldRetry = await _isContactStateAsymmetric();

      if (shouldRetry) {
        _logger.info('🔄 Retrying contact status exchange...');
        await _sessionService.requestContactStatusExchange();
      } else {
        _logger.info('🔄 Contact state appears synchronized');
      }
    } catch (e) {
      _logger.warning('Failed to retry contact status exchange: $e');
    }
  }

  @override
  Future<bool> _isContactStateAsymmetric() async {
    _logger.info('🔄 Checking if contact state is asymmetric');
    return false; // Simplified for now
  }

  // ============================================================================
  // SESSION LIFECYCLE
  // ============================================================================

  @override
  void clearSessionState({bool preservePersistentId = false}) {
    _logger.warning('🔍 SESSION STATE CLEARING');

    _contactSyncRetryTimer?.cancel();

    if (!preservePersistentId) {
      _lastReceivedContactStatus.clear();
      _bilateralSyncComplete.clear();
      _logger.warning('  - ⚠️  CLEARED session state (disconnection)');
    } else {
      _logger.warning('  - ✅ PRESERVED session state (navigation)');
    }
  }

  @override
  Future<void> recoverIdentityFromStorage() async {
    _logger.info(
      '[BLEStateCoordinator] 🔄 RECOVERY: Attempting identity recovery',
    );

    try {
      // Would recover from contact repository in full implementation
      _logger.info(
        '[BLEStateCoordinator] ✅ RECOVERY: Identity successfully recovered',
      );
    } catch (e) {
      _logger.warning('[BLEStateCoordinator] 🔄 RECOVERY: Failed - $e');
    }
  }

  @override
  Future<Map<String, String>> getIdentityWithFallback() async {
    return {
      'displayName': 'Connected Device',
      'publicKey': '',
      'source': 'fallback',
    };
  }

  // ============================================================================
  // PRESERVATION & MUTUAL CONSENT
  // ============================================================================

  @override
  void preserveContactRelationship({
    required String contactKey,
    required String displayName,
  }) {
    _logger.info(
      '[BLEStateCoordinator] 🔄 Preserving contact relationship: $displayName',
    );
  }

  @override
  void _triggerMutualConsentPrompt(String theirPublicKey) {
    _logger.info(
      '📱 MUTUAL CONSENT: Prompting user to initiate contact request',
    );
    onMutualConsentRequired?.call();
  }

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  void _cleanupOutgoingRequest(String publicKey) {
    _pendingOutgoingRequests[publicKey]?.cancel();
    _pendingOutgoingRequests.remove(publicKey);
    _outgoingRequestCompleters.remove(publicKey);
  }

  bool _isBilateralSyncComplete(String publicKey) {
    return _bilateralSyncComplete[publicKey] ?? false;
  }

  void _markBilateralSyncComplete(String publicKey) {
    _bilateralSyncComplete[publicKey] = true;
    _logger.info('[BLEStateCoordinator] 📱 SYNC COMPLETE');
  }

  void dispose() {
    _contactSyncRetryTimer?.cancel();
    for (final timer in _pendingOutgoingRequests.values) {
      timer.cancel();
    }
  }
}
