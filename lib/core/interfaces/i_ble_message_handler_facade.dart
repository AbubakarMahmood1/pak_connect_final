import 'dart:typed_data';
import '../../core/interfaces/i_seen_message_store.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/offline_message_queue.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../core/security/spam_prevention_manager.dart';
import '../../domain/values/id_types.dart';
import 'i_message_fragmentation_handler.dart';

/// Public API interface for BLE message handling
///
/// This facade maintains 100% backward compatibility with BLEMessageHandler
/// while delegating to three internal handlers:
/// - MessageFragmentationHandler (fragment reassembly)
/// - ProtocolMessageHandler (protocol message parsing)
/// - RelayCoordinator (mesh relay decisions)
///
/// All consumers of BLEMessageHandler should use this interface
abstract interface class IBLEMessageHandlerFacade {
  /// Sets current node ID for this device in mesh routing
  void setCurrentNodeId(String nodeId);

  /// Initializes relay system with dependencies and callback wiring.
  ///
  /// Called once at app startup after all services are initialized.
  /// Automatically injects ISeenMessageStore for duplicate detection.
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
    List<String> Function()? nextHopsProvider,
  });

  /// Sets the SeenMessageStore for relay deduplication
  ///
  /// **Note**: Normally called automatically by initializeRelaySystem() during production startup.
  /// Provided as public method for test overrides.
  void setSeenMessageStore(ISeenMessageStore seenMessageStore);

  /// Inject the offline message queue (useful for tests/explicit wiring).
  void setMessageQueue(OfflineMessageQueue queue);

  /// Inject spam prevention manager.
  void setSpamPreventionManager(SpamPreventionManager manager);

  /// Provide available next hops from the BLE layer.
  void setNextHopsProvider(List<String> Function() provider);

  /// Gets available next hop devices for relay
  List<String> getAvailableNextHops();

  /// Sends message from central role (initiating device)
  ///
  /// Handles:
  /// - Message fragmentation (splits into chunks if needed)
  /// - Encryption (via SecurityManager)
  /// - ACK waiting for delivery confirmation
  /// - Retry on timeout
  ///
  /// Returns: true if message was sent successfully
  Future<bool> sendMessage({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  });

  /// Sends message from peripheral role (advertising device)
  ///
  /// Used when this device is in peripheral mode
  /// and a central device connects to send us a message
  Future<bool> sendPeripheralMessage({
    required String senderKey,
    required String content,
    String? messageId,
  });

  /// Main entry point for processing received BLE data
  ///
  /// Orchestrates:
  /// 1. Fragment detection and reassembly
  /// 2. Protocol message parsing
  /// 3. Message decryption (if encrypted)
  /// 4. Relay decision (if enabled)
  /// 5. Callback dispatch
  ///
  /// Returns:
  /// - Complete message content if successfully processed
  /// - null if message is still partial or processing failed
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  });

  /// Handles QR code introduction claim
  ///
  /// When devices exchange QR code identity information:
  /// - Stores the claim temporarily
  /// - Later verified with checkQRIntroductionMatch
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  });

  /// Verifies QR code introduction match
  ///
  /// Both devices must have scanned the same QR data
  /// Returns: true if hashes match, false otherwise
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  });

  /// Sends queue synchronization message
  ///
  /// Periodic sync of offline message queues:
  /// - Exchange list of queued messages
  /// - Identify missing messages
  /// - Trigger retries
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  });

  /// Gets relay statistics from underlying RelayCoordinator
  ///
  /// Returns complete RelayStatistics with 10 fields:
  /// - totalRelayed, totalDropped, totalDeliveredToSelf, totalBlocked, totalProbabilisticSkip
  /// - spamScore, relayEfficiency, activeRelayMessages, networkSize, currentRelayProbability
  Future<RelayStatistics> getRelayStatistics();

  /// Called when a binary payload (reassembled fragments) is available for the local node.
  set onBinaryPayloadReceived(
    Function(
      Uint8List data,
      int originalType,
      String fragmentId,
      int ttl,
      String? recipient,
      String? senderNodeId,
    )?
    callback,
  );

  /// Called when a binary fragment should be forwarded hop-by-hop.
  set onForwardBinaryFragment(
    Function(
      Uint8List data,
      String fragmentId,
      int index,
      String fromDeviceId,
      String fromNodeId,
    )?
    callback,
  );

  /// Retrieve fully reassembled binary payload for forwarding when downstream MTU is smaller.
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId);

  // ==================== CALLBACKS ====================
  // All callbacks are optionally settable by consumers

  /// Called when contact request received
  set onContactRequestReceived(
    Function(String contactKey, String displayName)? callback,
  );

  /// Called when contact accept received
  set onContactAcceptReceived(
    Function(String contactKey, String displayName)? callback,
  );

  /// Called when contact reject received
  set onContactRejectReceived(Function()? callback);

  /// Called when crypto verification requested
  set onCryptoVerificationReceived(
    Function(String verificationId, String contactKey)? callback,
  );

  /// Called when crypto verification response received
  set onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )?
    callback,
  );

  /// Called when queue sync message received
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  );

  /// Called when we need to send queued messages
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  );

  /// Called when queue sync completes
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  );

  /// Called when relay message received
  set onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)?
    callback,
  );
  set onRelayMessageReceivedIds(
    Function(
      MessageId originalMessageId,
      String content,
      String originalSender,
    )?
    callback,
  );

  /// Called when relay decision made
  set onRelayDecisionMade(Function(RelayDecision decision)? callback);

  /// Called when relay statistics updated
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback);

  /// Called when we need to send ACK message
  set onSendAckMessage(Function(ProtocolMessage message)? callback);

  /// Called when we need to send relay message
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  );

  /// Called when a text message has been decrypted and verified.
  /// Provides plaintext content, transport/message ID (if present), and the
  /// sender node identifier used during decryption.
  set onTextMessageReceived(
    Future<void> Function(
      String content,
      String? messageId,
      String? senderNodeId,
    )?
    callback,
  );

  /// Called when identity is revealed (spy mode)
  set onIdentityRevealed(Function(String contactName)? callback);

  /// Cleanup: dispose all resources
  void dispose();
}

/// Typed helpers to keep wire payloads string-based while allowing callers to use value objects.
extension BleMessageHandlerFacadeIds on IBLEMessageHandlerFacade {
  Future<bool> sendMessageWithIds({
    required ChatId recipientId,
    required String content,
    required Duration timeout,
    MessageId? messageId,
    ChatId? originalIntendedRecipient,
  }) => sendMessage(
    recipientKey: recipientId.value,
    content: content,
    timeout: timeout,
    messageId: messageId?.value,
    originalIntendedRecipient: originalIntendedRecipient?.value,
  );

  Future<bool> sendPeripheralMessageWithId({
    required ChatId senderId,
    required String content,
    MessageId? messageId,
  }) => sendPeripheralMessage(
    senderKey: senderId.value,
    content: content,
    messageId: messageId?.value,
  );

  Future<bool> sendQueueSyncMessageWithIds({
    required ChatId toNodeId,
    required List<MessageId> messageIds,
  }) => sendQueueSyncMessage(
    toNodeId: toNodeId.value,
    messageIds: messageIds.map((id) => id.value).toList(),
  );
}
