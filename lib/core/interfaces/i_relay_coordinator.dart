import '../../core/models/protocol_message.dart';
import '../../core/models/mesh_relay_models.dart';
import '../../core/messaging/mesh_relay_engine.dart';
import '../../core/messaging/queue_sync_manager.dart';
import '../../domain/values/id_types.dart';

/// Interface for relay coordination between BLE and mesh networking
///
/// This is the BRIDGE LAYER between:
/// - BLE message handling (protocol messages, fragmentation)
/// - Mesh relay engine (routing decisions, hop tracking)
///
/// Responsibilities:
/// - Determining if a message should be relayed to other devices
/// - Creating outgoing relay messages with proper formatting
/// - Handling relay ACKs (delivery confirmation from next hops)
/// - Translating between BLE ProtocolMessage and MeshRelayMessage formats
/// - Sending ACK messages back to senders
/// - Managing relay statistics and hop limiting
abstract interface class IRelayCoordinator {
  /// Initialize relay system with dependencies
  ///
  /// Called once at startup to set up:
  /// - MeshRelayEngine reference
  /// - SpamPreventionManager for flood protection
  /// - OfflineMessageQueue for message persistence
  Future<void> initializeRelaySystem({required String currentNodeId});

  /// Processes an incoming message through relay decision engine
  ///
  /// Handles:
  /// - Duplicate detection (via SeenMessageStore)
  /// - Relay eligibility check (relay enabled, not too many hops)
  /// - Local delivery (if message is for us)
  /// - Forward decision (relay to next hops)
  ///
  /// Returns:
  /// - true if message was relayed
  /// - false if relay not applicable or failed
  Future<bool> handleMeshRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required Map<String, dynamic>? messageData,
    required int? currentHopCount,
  });

  /// Creates an outgoing relay message
  ///
  /// Converts a complete message into relay format:
  /// - Wraps with relay header (hop count, timestamps, etc.)
  /// - Determines next hops via SmartMeshRouter
  /// - Maintains message ID for deduplication
  ///
  /// Returns:
  /// - MeshRelayMessage ready to send
  /// - null if relay creation failed
  Future<MeshRelayMessage?> createOutgoingRelay({
    required String originalMessageId,
    required String content,
    required String originalSender,
    required String? intendedRecipient,
    required int currentHopCount,
  });

  /// Sends relay message to next hop
  ///
  /// Handles:
  /// - Finding available next hop devices
  /// - Formatting message for BLE transmission
  /// - Starting ACK timeout timer
  /// - Updating relay statistics
  Future<void> handleRelayToNextHop({
    required MeshRelayMessage relayMessage,
    required String nextHopDeviceId,
  });

  /// Delivers relay message to self (local device)
  ///
  /// When relay is intended for us:
  /// 1. Decrypt if encrypted
  /// 2. Call callback to forward to message handler
  /// 3. Send ACK back to relay sender
  void handleRelayDeliveryToSelf({
    required String originalMessageId,
    required String content,
    required String originalSender,
  });

  /// Determines if message should be relayed
  ///
  /// Checks:
  /// - Relay enabled flag
  /// - Message not already seen (deduplication)
  /// - Hop count not exceeded
  /// - Not spam/flood detected
  ///
  /// Returns: true if relay should be attempted
  bool shouldAttemptRelay({
    required String messageId,
    required int currentHopCount,
  });

  /// Attempts decryption of relay message
  ///
  /// Some relay scenarios allow decryption during relay:
  /// - ECDH encryption (per-peer keys)
  /// - Conversation keys (multi-hop)
  ///
  /// Returns: true if decryption was successful or not needed
  Future<bool> shouldAttemptDecryption({
    required String messageId,
    required String senderKey,
  });

  /// Sends ACK (acknowledgment) message
  ///
  /// Called after:
  /// - Receiving relay message
  /// - Delivering to recipient
  /// - Processing without error
  ///
  /// ACK includes:
  /// - Original message ID
  /// - Timestamp
  /// - Status (success/failure)
  Future<void> sendRelayAck({
    required String originalMessageId,
    required String toDeviceId,
    required String relayAckContent,
  });

  /// Handles incoming relay ACK (acknowledgment)
  ///
  /// Confirms:
  /// - Message reached next hop
  /// - Delivery in progress
  /// - Cancels retry timeout
  Future<void> handleRelayAck({
    required String originalMessageId,
    required String fromDeviceId,
    required Map<String, dynamic>? ackData,
  });

  /// Gets current relay statistics
  ///
  /// Returns:
  /// - Messages relayed count
  /// - Messages delivered count
  /// - Average hop count
  /// - Duplicate drops
  /// - Failed relays
  Future<RelayStatistics> getRelayStatistics();

  /// Sends queue sync message (offline message persistence sync)
  ///
  /// Periodically syncs with devices:
  /// - Which messages are in our queue
  /// - Which messages they have
  /// - Coordinates retries for missing messages
  Future<bool> sendQueueSyncMessage({
    required String toNodeId,
    required List<String> messageIds,
  });

  /// Sets current node ID for routing
  ///
  /// Used to identify this device in mesh routing
  void setCurrentNodeId(String nodeId);

  /// Gets available next hop devices
  ///
  /// Returns list of device IDs that can relay messages
  List<String> getAvailableNextHops();

  /// Registers callback for relay statistics updates
  void onRelayStatsUpdated(Function(RelayStatistics stats) callback);

  /// Registers callback for relay messages received
  void onRelayMessageReceived(
    Function(String originalMessageId, String content, String originalSender)
    callback,
  );
  void onRelayMessageReceivedIds(
    Function(MessageId originalMessageId, String content, String originalSender)
    callback,
  );

  /// Registers callback for relay decisions
  void onRelayDecisionMade(Function(RelayDecision decision) callback);

  /// Registers callback for sending relay messages
  void onSendRelayMessage(
    Function(ProtocolMessage message, String nextHopId) callback,
  );

  /// Registers callback for sending ACK messages
  void onSendAckMessage(Function(ProtocolMessage message) callback);

  /// Registers callback for queue sync received
  void onQueueSyncReceived(
    Function(QueueSyncMessage syncMessage, String fromNodeId) callback,
  );

  /// Registers callback for queue sync completion
  void onQueueSyncCompleted(
    Function(String nodeId, QueueSyncResult result) callback,
  );

  /// Cleans up relay resources
  void dispose();
}
