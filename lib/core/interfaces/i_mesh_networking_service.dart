import 'package:pak_connect/core/messaging/mesh_relay_engine.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/messaging/queue_sync_manager.dart'
    show QueueSyncManagerStats, QueueSyncResult;
import 'package:pak_connect/domain/models/mesh_network_models.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'package:pak_connect/domain/values/id_types.dart';

/// Interface for mesh networking service operations
///
/// Abstracts mesh relay, routing, queue sync, and network topology to enable:
/// - Dependency injection
/// - Test mocking (important for testing mesh relay logic)
/// - Alternative implementations (e.g., in-memory for tests)
///
/// **Phase 1 Note**: Interface defines core public API from MeshNetworkingService
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

  // =========================
  // MESSAGING OPERATIONS
  // =========================

  /// Send message through mesh network
  Future<MeshSendResult> sendMeshMessage({
    required String content,
    required String recipientPublicKey,
    MessagePriority priority = MessagePriority.normal,
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
