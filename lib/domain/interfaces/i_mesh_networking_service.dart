import 'dart:typed_data';

import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    show RelayStatistics;
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/services/mesh_networking_service.dart'
    show PendingBinaryTransfer, ReceivedBinaryEvent;
import 'package:pak_connect/domain/values/id_types.dart';

/// Interface for mesh networking service operations
abstract class IMeshNetworkingService {
  // =========================
  // INITIALIZATION & LIFECYCLE
  // =========================

  /// Initialize mesh networking service
  Future<void> initialize({String? nodeId});

  /// Dispose resources
  void dispose();

  // =========================
  // STATE STREAMS
  // =========================

  /// Mesh network status stream
  Stream<MeshNetworkStatus> get meshStatus;

  /// Relay statistics stream
  Stream<RelayStatistics> get relayStats;

  /// Queue statistics stream
  Stream<QueueSyncManagerStats> get queueStats;

  /// Message delivery stream
  Stream<String> get messageDeliveryStream;

  /// Stream of received binary/media payloads.
  Stream<ReceivedBinaryEvent> get binaryPayloadStream;

  // =========================
  // MESSAGING OPERATIONS
  // =========================

  /// Send message through mesh network
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
  });

  /// Send a binary/media payload and return transferId for retry tracking.
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = BinaryPayloadType.media,
    Map<String, dynamic>? metadata,
  });

  /// Retry a previously persisted binary/media payload.
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  });

  // =========================
  // QUEUE MANAGEMENT
  // =========================

  /// Sync queues with peers
  Future<Map<String, QueueSyncResult>> syncQueuesWithPeers();

  /// Retry a specific message
  Future<bool> retryMessage(String messageId);

  /// Remove message from queue
  Future<bool> removeMessage(String messageId);

  /// Set message priority
  Future<bool> setPriority(String messageId, MessagePriority priority);

  /// Retry all queued messages
  Future<int> retryAllMessages();

  /// Get queued messages for a specific chat
  List<QueuedMessage> getQueuedMessagesForChat(String chatId);

  /// Pending binary transfers awaiting a send attempt.
  List<PendingBinaryTransfer> getPendingBinaryTransfers();

  // =========================
  // NETWORK STATISTICS
  // =========================

  /// Get network statistics
  MeshNetworkStatistics getNetworkStatistics();

  /// Refresh mesh status
  void refreshMeshStatus();
}

/// Typed helpers to keep MessageId usage in UI/service layers while
/// maintaining string-based mesh/queue interfaces.
extension MeshNetworkingServiceIds on IMeshNetworkingService {
  Future<bool> retryMessageById(MessageId messageId) =>
      retryMessage(messageId.value);

  Future<bool> removeMessageById(MessageId messageId) =>
      removeMessage(messageId.value);

  Future<bool> setPriorityById(MessageId messageId, MessagePriority priority) =>
      setPriority(messageId.value, priority);

  List<QueuedMessage> getQueuedMessagesForChatId(ChatId chatId) =>
      getQueuedMessagesForChat(chatId.value);

  Stream<MessageId> get messageDeliveryStreamIds =>
      messageDeliveryStream.map(MessageId.new);
}
