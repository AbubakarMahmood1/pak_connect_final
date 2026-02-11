import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/models/protocol_message.dart';
import '../../domain/services/simple_crypto.dart';
import '../../data/repositories/contact_repository.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import '../../domain/models/security_level.dart';

/// Handles bilateral contact status sync, asymmetric detection, and ECDH upgrades
/// so BLEStateManager can remain lean.
class ContactStatusSyncController {
  ContactStatusSyncController({
    required Logger logger,
    required ContactRepository contactRepository,
    required Future<String> Function() myPersistentIdProvider,
    required Future<bool> Function() weHaveThemAsContactProvider,
    required String? Function() currentSessionIdProvider,
    required void Function(String theirPublicKey) triggerMutualConsentPrompt,
    this.onAsymmetricContactDetected,
    this.onContactRequestCompleted,
    this.onSendContactStatus,
    Duration statusCooldown = const Duration(seconds: 2),
  }) : _logger = logger,
       _contactRepository = contactRepository,
       _getMyPersistentId = myPersistentIdProvider,
       _weHaveThemAsContact = weHaveThemAsContactProvider,
       _currentSessionId = currentSessionIdProvider,
       _triggerMutualConsentPrompt = triggerMutualConsentPrompt,
       _statusCooldownDuration = statusCooldown;

  final Logger _logger;
  final ContactRepository _contactRepository;
  final Future<String> Function() _getMyPersistentId;
  final Future<bool> Function() _weHaveThemAsContact;
  final String? Function() _currentSessionId;
  final void Function(String theirPublicKey) _triggerMutualConsentPrompt;

  Function(String, String)? onAsymmetricContactDetected;
  Function(bool)? onContactRequestCompleted;
  Function(ProtocolMessage)? onSendContactStatus;

  String? _lastSyncedTheirStatus;
  final Map<String, bool> _lastSentContactStatus = {};
  final Map<String, DateTime> _lastStatusSentTime = {};
  final Map<String, bool> _lastReceivedContactStatus = {};
  final Map<String, bool> _bilateralSyncComplete = {};
  final Set<String> _processedContactMessages = {};
  Timer? _contactSyncRetryTimer;
  final Duration _statusCooldownDuration;

  bool get theyHaveUsAsContact => _lastSyncedTheirStatus == 'yes';

  void updateTheirContactClaim(bool theyClaimUs) {
    final previousState = _lastSyncedTheirStatus;
    _lastSyncedTheirStatus = theyClaimUs ? 'yes' : 'no';

    _logger.fine(
      '🔒 SESSION: They ${theyClaimUs ? "claim to have" : "don't have"} us as contact',
    );

    if (previousState != _lastSyncedTheirStatus) {
      onContactRequestCompleted?.call(true);
    }
  }

  Future<void> requestContactStatusExchange() async {
    final sessionId = _currentSessionId();
    if (sessionId == null) return;

    try {
      final weHaveThem = await _weHaveThemAsContact();
      await _sendContactStatusIfChanged(weHaveThem, sessionId);
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  ) async {
    _logger.fine(
      '📱 PROTOCOL: Received contact status - they have us: $theyHaveUsAsContact',
    );

    final previousStatus = _lastReceivedContactStatus[theirPublicKey];
    if (previousStatus == theyHaveUsAsContact) {
      _logger.fine('📱 PROTOCOL: Same status again - ignoring (loop guard)');
      return;
    }

    _lastReceivedContactStatus[theirPublicKey] = theyHaveUsAsContact;

    updateTheirContactClaim(theyHaveUsAsContact);
    await _checkForAsymmetricRelationship(theirPublicKey, theyHaveUsAsContact);

    if (!_isBilateralSyncComplete(theirPublicKey)) {
      _logger.fine('📱 PROTOCOL: Processing new contact status change');
      await _performBilateralContactSync(theirPublicKey, theyHaveUsAsContact);
    } else {
      _logger.fine('📱 PROTOCOL: Bilateral sync already complete');
    }
  }

  Future<void> initializeContactFlags() async {
    final sessionId = _currentSessionId();
    if (sessionId == null) return;

    _logger.info('🔄 Initializing contact flags from repository...');

    await requestContactStatusExchange();

    _contactSyncRetryTimer?.cancel();
    _contactSyncRetryTimer = Timer(Duration(seconds: 2), () async {
      await _retryContactStatusExchange();
    });

    _logger.info('✅ Contact flags initialization requested');
  }

  void markBilateralSyncComplete(String theirPublicKey) {
    _bilateralSyncComplete[theirPublicKey] = true;
    _logger.fine('[ContactSync] SYNC COMPLETE for ${theirPublicKey.shortId()}');
  }

  void resetBilateralSyncStatus(String theirPublicKey) {
    _bilateralSyncComplete[theirPublicKey] = false;
    _lastSentContactStatus.remove(theirPublicKey);
    _lastStatusSentTime.remove(theirPublicKey);
    _lastReceivedContactStatus.remove(theirPublicKey);
    _logger.fine('[ContactSync] SYNC RESET for ${theirPublicKey.shortId()}');
  }

  void reset() {
    _lastSyncedTheirStatus = null;
    _lastSentContactStatus.clear();
    _lastStatusSentTime.clear();
    _lastReceivedContactStatus.clear();
    _bilateralSyncComplete.clear();
    _processedContactMessages.clear();
    _contactSyncRetryTimer?.cancel();
  }

  void dispose() {
    _contactSyncRetryTimer?.cancel();
  }

  bool _isBilateralSyncComplete(String theirPublicKey) {
    return _bilateralSyncComplete[theirPublicKey] ?? false;
  }

  Future<void> _sendContactStatusIfChanged(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    final lastSentStatus = _lastSentContactStatus[theirPublicKey];
    final statusChanged = lastSentStatus != weHaveThem;

    final lastSentTime = _lastStatusSentTime[theirPublicKey];
    final cooldownExpired =
        lastSentTime == null ||
        DateTime.now().difference(lastSentTime) > _statusCooldownDuration;

    if (statusChanged || (lastSentStatus == null && cooldownExpired)) {
      _logger.fine(
        '📱 EXCHANGE: Sending our contact status: $weHaveThem (changed: $statusChanged, cooldown: $cooldownExpired)',
      );

      _lastSentContactStatus[theirPublicKey] = weHaveThem;
      _lastStatusSentTime[theirPublicKey] = DateTime.now();

      await _doSendContactStatus(weHaveThem, theirPublicKey);
    } else {
      _logger.fine(
        '📱 EXCHANGE: Skipping contact status send - no change/cooldown',
      );
    }
  }

  Future<void> _doSendContactStatus(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    try {
      final myPublicKey = await _getMyPersistentId();
      final statusMessage = ProtocolMessage.contactStatus(
        hasAsContact: weHaveThem,
        publicKey: myPublicKey,
      );

      onSendContactStatus?.call(statusMessage);
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

  bool _checkAndMarkSyncComplete(
    String theirPublicKey,
    bool weHaveThem,
    bool theyHaveUs,
  ) {
    if (weHaveThem && theyHaveUs) {
      _logger.fine('🔒 MUTUAL: Both have each other');
      markBilateralSyncComplete(theirPublicKey);
      return true;
    }

    if (!weHaveThem && !theyHaveUs) {
      final receivedStatus = _lastReceivedContactStatus[theirPublicKey];
      final sentStatus = _lastSentContactStatus[theirPublicKey];

      if (receivedStatus == false && sentStatus == false) {
        _logger.fine(
          '📱 NO RELATIONSHIP: Both confirmed no relationship - sync complete',
        );
        markBilateralSyncComplete(theirPublicKey);
        return true;
      }
    }

    return false;
  }

  Future<void> _performBilateralContactSync(
    String theirPublicKey,
    bool theyHaveUs,
  ) async {
    try {
      final weHaveThem = await _weHaveThemAsContact();

      _logger.info(
        '[ContactSync] BILATERAL (${theirPublicKey.shortId()}): theyHaveUs=$theyHaveUs, weHaveThem=$weHaveThem',
      );

      await _sendContactStatusIfChanged(weHaveThem, theirPublicKey);

      if (_checkAndMarkSyncComplete(theirPublicKey, weHaveThem, theyHaveUs)) {
        return;
      }

      if (theyHaveUs && !weHaveThem) {
        _logger.info('📱 ASYMMETRIC: They have us, prompting mutual consent');
        _triggerMutualConsentPrompt(theirPublicKey);
      } else if (weHaveThem && !theyHaveUs) {
        _logger.info('📱 ASYMMETRIC: We have them, waiting for them');
      } else if (weHaveThem && theyHaveUs) {
        _logger.info('📱 MUTUAL: Both have each other - ensuring ECDH');

        await _ensureMutualECDH(theirPublicKey);
        markBilateralSyncComplete(theirPublicKey);
      } else {
        _logger.info('📱 NO RELATIONSHIP: Neither has the other');
      }
    } catch (e) {
      _logger.warning('Bilateral contact sync failed: $e');
    }
  }

  Future<void> _ensureMutualECDH(String theirPublicKey) async {
    try {
      final existingSecret = await _contactRepository.getCachedSharedSecret(
        theirPublicKey,
      );

      if (existingSecret == null) {
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

      onContactRequestCompleted?.call(true);
    } catch (e) {
      _logger.warning('Failed to ensure mutual ECDH: $e');
    }
  }

  Future<void> _checkForAsymmetricRelationship(
    String theirPublicKey,
    bool theyHaveUs,
  ) async {
    final weHaveThem = await _weHaveThemAsContact();

    if (theyHaveUs && !weHaveThem) {
      _logger.fine('🔒 ASYMMETRIC: They have us, we should add them');
      onAsymmetricContactDetected?.call(
        theirPublicKey,
        '', // Caller can enrich with name if needed
      );
    } else if (weHaveThem && !theyHaveUs) {
      _logger.fine('🔒 ASYMMETRIC: We have them, they should add us');
    } else if (weHaveThem && theyHaveUs) {
      _logger.fine('🔒 MUTUAL: Both have each other');
    } else {
      _logger.fine('🔒 NO RELATIONSHIP: Neither has the other');
    }
  }

  Future<void> _retryContactStatusExchange() async {
    try {
      final shouldRetry =
          _lastSyncedTheirStatus == null || await _weHaveThemAsContact();

      if (shouldRetry) {
        _logger.info('🔄 Retrying contact status exchange...');
        await requestContactStatusExchange();
      } else {
        _logger.info('🔄 Contact state synchronized, no retry needed');
      }
    } catch (e) {
      _logger.warning('Failed to retry contact status exchange: $e');
    }
  }
}
