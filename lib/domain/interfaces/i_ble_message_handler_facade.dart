import 'dart:typed_data';

import '../messaging/offline_message_queue_contract.dart';
import '../messaging/queue_sync_manager.dart';
import '../models/mesh_relay_models.dart';
import '../models/protocol_message.dart';
import '../services/spam_prevention_manager.dart';
import '../values/id_types.dart';
import 'i_message_fragmentation_handler.dart';
import 'i_seen_message_store.dart';

/// Public API interface for BLE message handling
abstract interface class IBLEMessageHandlerFacade {
  /// Sets current node ID for this device in mesh routing
  void setCurrentNodeId(String nodeId);

  /// Initializes relay system with dependencies and callback wiring.
  Future<void> initializeRelaySystem({
    required String currentNodeId,
    Function(String originalMessageId, String content, String originalSender)?
    onRelayMessageReceived,
    Function(RelayDecision decision)? onRelayDecisionMade,
    Function(RelayStatistics stats)? onRelayStatsUpdated,
    List<String> Function()? nextHopsProvider,
  });

  /// Sets the SeenMessageStore for relay deduplication.
  void setSeenMessageStore(ISeenMessageStore seenMessageStore);

  /// Inject the offline message queue (useful for tests/explicit wiring).
  void setMessageQueue(OfflineMessageQueueContract queue);

  /// Inject spam prevention manager.
  void setSpamPreventionManager(SpamPreventionManager manager);

  /// Provide available next hops from the BLE layer.
  void setNextHopsProvider(List<String> Function() provider);

  /// Gets available next hop devices for relay.
  List<String> getAvailableNextHops();

  /// Sends message from central role (initiating device).
  Future<bool> sendMessage({
    required String recipientKey,
    required String content,
    required Duration timeout,
    String? messageId,
    String? originalIntendedRecipient,
  });

  /// Sends message from peripheral role (advertising device).
  Future<bool> sendPeripheralMessage({
    required String senderKey,
    required String content,
    String? messageId,
  });

  /// Main entry point for processing received BLE data.
  Future<String?> processReceivedData({
    required Uint8List data,
    required String fromDeviceId,
    required String fromNodeId,
  });

  /// Handles QR code introduction claim.
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  });

  /// Verifies QR code introduction match.
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  });

  /// Sends queue synchronization message.
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  });

  /// Gets relay statistics from underlying RelayCoordinator.
  Future<RelayStatistics> getRelayStatistics();

  /// Called when a binary payload (reassembled fragments) is available.
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

  /// Retrieve fully reassembled binary payload for forwarding.
  ForwardReassembledPayload? takeForwardReassembledPayload(String fragmentId);

  // ==================== CALLBACKS ====================

  /// Called when contact request received.
  set onContactRequestReceived(
    Function(String contactKey, String displayName)? callback,
  );

  /// Called when contact accept received.
  set onContactAcceptReceived(
    Function(String contactKey, String displayName)? callback,
  );

  /// Called when contact reject received.
  set onContactRejectReceived(Function()? callback);

  /// Called when crypto verification requested.
  set onCryptoVerificationReceived(
    Function(String verificationId, String contactKey)? callback,
  );

  /// Called when crypto verification response received.
  set onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )?
    callback,
  );

  /// Called when queue sync message received.
  set onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
  );

  /// Called when we need to send queued messages.
  set onSendQueueMessages(
    Function(List<QueuedMessage> messages, String toNodeId)? callback,
  );

  /// Called when queue sync completes.
  set onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result)? callback,
  );

  /// Called when relay message received.
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

  /// Called when relay decision made.
  set onRelayDecisionMade(Function(RelayDecision decision)? callback);

  /// Called when relay statistics updated.
  set onRelayStatsUpdated(Function(RelayStatistics stats)? callback);

  /// Called when we need to send ACK message.
  set onSendAckMessage(Function(ProtocolMessage message)? callback);

  /// Called when we need to send relay message.
  set onSendRelayMessage(
    Function(ProtocolMessage relayMessage, String nextHopId)? callback,
  );

  /// Called when a text message has been decrypted and verified.
  set onTextMessageReceived(
    Future<void> Function(
      String content,
      String? messageId,
      String? senderNodeId,
    )?
    callback,
  );

  /// Called when identity is revealed (spy mode).
  set onIdentityRevealed(Function(String contactName)? callback);

  /// Cleanup: dispose all resources.
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
