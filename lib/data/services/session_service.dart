import 'dart:async';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_session_service.dart';
import '../repositories/contact_repository.dart';

/// Session Service
///
/// Manages active session state:
/// - Ephemeral and session IDs for current contact
/// - Contact status synchronization (bilateral sync)
/// - Message addressing (which ID to use: persistent vs ephemeral)
/// - Asymmetric contact detection and handling
class SessionService implements ISessionService {
  final _logger = Logger('SessionService');

  // ============================================================================
  // DEPENDENCIES (Injected)
  // ============================================================================

  /// Callback to check if we have peer as contact
  /// Returns: `Future<bool>` - true if we have them in our contact list
  final Future<bool> Function() getWeHaveThemAsContact;

  /// Callback to get our persistent ID
  final Future<String> Function() getMyPersistentId;

  /// Callback to get their persistent key (if paired)
  final String? Function() getTheirPersistentKey;

  /// Callback to get their ephemeral ID
  final String? Function() getTheirEphemeralId;

  // ============================================================================
  // SESSION STATE
  // ============================================================================

  /// Conversation keys cached per contact
  final Map<String, String> _conversationKeys = {};

  /// Track last sent contact status per contact (for debouncing)
  final Map<String, bool> _lastSentContactStatus = {};

  /// Track last time we sent contact status (for cooldown)
  final Map<String, DateTime> _lastStatusSentTime = {};

  /// Track last received contact status per contact
  final Map<String, bool> _lastReceivedContactStatus = {};

  /// Track if bilateral sync is complete per contact
  final Map<String, bool> _bilateralSyncComplete = {};

  /// Minimum time between consecutive status sends (prevents flooding)
  static const Duration _statusCooldownDuration = Duration(seconds: 2);

  // ============================================================================
  // CALLBACKS (Events to Coordinator)
  // ============================================================================

  @override
  void Function(bool weHaveThem, String theirPublicKey)? onSendContactStatus;

  @override
  void Function()? onContactRequestCompleted;

  @override
  void Function()? onAsymmetricContactDetected;

  @override
  void Function()? onMutualConsentRequired;

  @override
  void Function(String content)? onSendMessage;

  // ============================================================================
  // CONSTRUCTOR
  // ============================================================================

  SessionService({
    ContactRepository? contactRepository,
    required this.getWeHaveThemAsContact,
    required this.getMyPersistentId,
    required this.getTheirPersistentKey,
    required this.getTheirEphemeralId,
  });

  // ============================================================================
  // SESSION ID MANAGEMENT
  // ============================================================================

  @override
  void setTheirEphemeralId(String ephemeralId, String displayName) {
    try {
      _logger.fine('Storing their ephemeral ID: $ephemeralId ($displayName)');
      // Note: This method mainly documents the receipt of ephemeral ID
      // Actual storage is handled by IdentityManager
    } catch (e) {
      _logger.warning('Failed to set their ephemeral ID: $e');
    }
  }

  @override
  String? getRecipientId() {
    // IDENTITY RESOLUTION: Return persistent key if paired, else ephemeral ID
    final persistentKey = getTheirPersistentKey();
    if (persistentKey != null) {
      // Paired: Use persistent key
      _logger.fine(
        'Recipient ID: persistent (${persistentKey.substring(0, 8)}...)',
      );
      return persistentKey;
    }

    // Not paired: Use ephemeral ID
    final ephemeralId = getTheirEphemeralId();
    if (ephemeralId != null) {
      _logger.fine(
        'Recipient ID: ephemeral (${ephemeralId.substring(0, 8)}...)',
      );
    }
    return ephemeralId;
  }

  @override
  String getIdType() {
    final persistentKey = getTheirPersistentKey();
    return persistentKey != null ? 'persistent' : 'ephemeral';
  }

  @override
  String? getConversationKey(String publicKey) {
    final key = _conversationKeys[publicKey];
    if (key != null) {
      _logger.fine(
        'Retrieved conversation key for ${publicKey.substring(0, 8)}...',
      );
    }
    return key;
  }

  // ============================================================================
  // CONTACT STATUS SYNCHRONIZATION
  // ============================================================================

  @override
  Future<void> requestContactStatusExchange() async {
    try {
      _logger.info('🔔 Initiating contact status exchange...');
      final theirId = getRecipientId();

      if (theirId == null) {
        _logger.warning('❌ Cannot request contact status - no recipient ID');
        return;
      }

      // Send our contact status
      final weHaveThem = await getWeHaveThemAsContact();
      _logger.info(
        '📤 Requesting contact status exchange - we have them: $weHaveThem',
      );

      await _sendContactStatusIfChanged(weHaveThem, theirId);
    } catch (e) {
      _logger.warning('Failed to request contact status exchange: $e');
    }
  }

  @override
  Future<void> handleContactStatus(
    bool theyHaveUsAsContact,
    String theirPublicKey,
  ) async {
    try {
      _logger.info(
        '📥 Received contact status: they have us = $theyHaveUsAsContact',
      );

      // INFINITE LOOP FIX: Ignore duplicate statuses
      final previousStatus = _lastReceivedContactStatus[theirPublicKey];
      if (previousStatus == theyHaveUsAsContact) {
        _logger.fine('ℹ️ Same status received again - ignoring');
        return;
      }

      // Track the received status
      _lastReceivedContactStatus[theirPublicKey] = theyHaveUsAsContact;

      // Update our view of their claim
      updateTheirContactClaim(theyHaveUsAsContact);

      // Check for asymmetric relationship
      _checkForAsymmetricRelationship(theirPublicKey, theyHaveUsAsContact);

      // INFINITE LOOP FIX: Only process if sync isn't complete
      if (!_isBilateralSyncComplete(theirPublicKey)) {
        await _performBilateralContactSync(theirPublicKey, theyHaveUsAsContact);
      } else {
        _logger.fine('ℹ️ Bilateral sync already complete - no action needed');
      }
    } catch (e) {
      _logger.warning('Failed to handle contact status: $e');
    }
  }

  @override
  void updateTheirContactStatus(bool theyHaveUs) {
    try {
      _logger.fine('Updating their contact status: $theyHaveUs');
      // This updates the local session's understanding of what they claim
    } catch (e) {
      _logger.warning('Failed to update their contact status: $e');
    }
  }

  @override
  void updateTheirContactClaim(bool theyClaimUs) {
    try {
      _logger.fine('Updating their contact claim: $theyClaimUs');
      // Track their claim for bilateral sync determination
    } catch (e) {
      _logger.warning('Failed to update their contact claim: $e');
    }
  }

  // ============================================================================
  // BILATERAL SYNC STATE TRACKING
  // ============================================================================

  bool _isBilateralSyncComplete(String theirPublicKey) {
    return _bilateralSyncComplete[theirPublicKey] ?? false;
  }

  void _markBilateralSyncComplete(String theirPublicKey) {
    try {
      _bilateralSyncComplete[theirPublicKey] = true;
      _logger.info(
        '✅ BILATERAL SYNC COMPLETE: ${theirPublicKey.substring(0, 8)}...',
      );
    } catch (e) {
      _logger.warning('Failed to mark bilateral sync complete: $e');
    }
  }

  Future<void> _performBilateralContactSync(
    String theirPublicKey,
    bool theyHaveUs,
  ) async {
    try {
      // Check our repository state (source of truth)
      final weHaveThem = await getWeHaveThemAsContact();

      _logger.info('📱 BILATERAL SYNC (${theirPublicKey.substring(0, 8)}...):');
      _logger.info('  - They have us: $theyHaveUs');
      _logger.info('  - We have them: $weHaveThem');

      // Send our status if changed or hasn't been sent
      await _sendContactStatusIfChanged(weHaveThem, theirPublicKey);

      // Check if sync is now complete
      await _checkAndMarkSyncComplete(theirPublicKey, weHaveThem, theyHaveUs);

      if (_isBilateralSyncComplete(theirPublicKey)) {
        _logger.fine('✅ Sync complete, no further action needed');
        return;
      }

      // Handle asymmetric relationships with consent prompts
      if (theyHaveUs && !weHaveThem) {
        _logger.info('📱 ASYMMETRIC: They have us, requiring mutual consent');
        onMutualConsentRequired?.call();
      } else if (weHaveThem && !theyHaveUs) {
        _logger.info('📱 ASYMMETRIC: We have them, waiting for acceptance');
      } else if (weHaveThem && theyHaveUs) {
        _logger.info('📱 MUTUAL: Both have each other!');
        _markBilateralSyncComplete(theirPublicKey);
      } else {
        _logger.fine('📱 NO RELATIONSHIP: Neither has the other');
      }
    } catch (e) {
      _logger.warning('Bilateral contact sync failed: $e');
    }
  }

  Future<void> _checkAndMarkSyncComplete(
    String theirPublicKey,
    bool weHaveThem,
    bool theyHaveUs,
  ) async {
    try {
      // Sync is complete when both are in mutual contact
      if (weHaveThem && theyHaveUs) {
        _logger.fine('🔒 MUTUAL: Both have each other');
        _markBilateralSyncComplete(theirPublicKey);
        return;
      }

      // Also complete if neither has the other (stable state)
      if (!weHaveThem && !theyHaveUs) {
        final receivedStatus = _lastReceivedContactStatus[theirPublicKey];
        final sentStatus = _lastSentContactStatus[theirPublicKey];

        if (receivedStatus == false && sentStatus == false) {
          _logger.fine('📱 NO RELATIONSHIP: Both confirmed no relationship');
          _markBilateralSyncComplete(theirPublicKey);
          return;
        }
      }

      _logger.fine('⏳ Sync not yet complete, waiting for confirmation');
    } catch (e) {
      _logger.warning('Failed to check sync completion: $e');
    }
  }

  void _checkForAsymmetricRelationship(String theirPublicKey, bool theyHaveUs) {
    try {
      // Async operation, so we'll just log and call callback
      _logger.fine(
        'Checking for asymmetric relationship: they have us = $theyHaveUs',
      );

      // If they have us but we don't (or vice versa), it's asymmetric
      // This is handled in _performBilateralContactSync
      if (theyHaveUs) {
        onAsymmetricContactDetected?.call();
      }
    } catch (e) {
      _logger.warning('Failed to check for asymmetric relationship: $e');
    }
  }

  // ============================================================================
  // INTERNAL HELPERS
  // ============================================================================

  Future<void> _sendContactStatusIfChanged(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    try {
      // Check if status changed
      final lastSentStatus = _lastSentContactStatus[theirPublicKey];
      final statusChanged = lastSentStatus != weHaveThem;

      // Check cooldown period (prevent flooding)
      final lastSentTime = _lastStatusSentTime[theirPublicKey];
      final cooldownExpired =
          lastSentTime == null ||
          DateTime.now().difference(lastSentTime) > _statusCooldownDuration;

      if (statusChanged || (lastSentStatus == null && cooldownExpired)) {
        _logger.fine(
          '📤 Sending contact status: $weHaveThem (changed: $statusChanged, cooldown: $cooldownExpired)',
        );

        // Update tracking
        _lastSentContactStatus[theirPublicKey] = weHaveThem;
        _lastStatusSentTime[theirPublicKey] = DateTime.now();

        // Send the actual status
        await _doSendContactStatus(weHaveThem, theirPublicKey);
      } else {
        _logger.fine(
          '⏭️ Skipping contact status - no change and still in cooldown',
        );
      }
    } catch (e) {
      _logger.warning('Failed to send contact status if changed: $e');
    }
  }

  Future<void> _doSendContactStatus(
    bool weHaveThem,
    String theirPublicKey,
  ) async {
    try {
      onSendContactStatus?.call(weHaveThem, theirPublicKey);
      _logger.fine('✅ Contact status sent: $weHaveThem');
    } catch (e) {
      _logger.warning('Failed to send contact status: $e');
    }
  }

  // ============================================================================
  // STATE QUERIES
  // ============================================================================

  @override
  bool get isPaired => getTheirPersistentKey() != null;

  // ============================================================================
  // HELPER METHODS
  // ============================================================================

  // ============================================================================
  // CLEANUP (Dispose)
  // ============================================================================

  void dispose() {
    _logger.fine('Disposing SessionService');
    // No timers or resources to clean up
  }
}
