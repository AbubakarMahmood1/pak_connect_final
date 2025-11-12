import 'package:pak_connect/domain/services/mesh_networking_service.dart';

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
  Future<void> initialize();

  /// Dispose resources
  void dispose();

  // =========================
  // STATE STREAMS
  // =========================

  /// Mesh network status stream
  Stream<MeshNetworkStatus> get meshStatus;

  /// Relay statistics stream
  Stream<dynamic> get relayStats;

  /// Queue statistics stream
  Stream<dynamic> get queueStats;

  /// Demo events stream
  Stream<DemoEvent> get demoEvents;

  /// Message delivery stream
  Stream<Map<String, dynamic>> get messageDeliveryStream;

  // =========================
  // MESSAGING OPERATIONS
  // =========================

  /// Send message through mesh network
  Future<MeshSendResult> sendMeshMessage({
    required String recipientId,
    required String message,
    required String messageId,
  });

  // =========================
  // QUEUE MANAGEMENT
  // =========================

  /// Sync queues with peers
  Future<void> syncQueuesWithPeers();

  /// Retry a specific message
  Future<void> retryMessage(String messageId);

  /// Remove message from queue
  Future<void> removeMessage(String messageId);

  /// Set message priority
  Future<void> setPriority(String messageId, int priority);

  /// Retry all queued messages
  Future<void> retryAllMessages();

  /// Get queued messages for a specific chat
  Future<List<dynamic>> getQueuedMessagesForChat(String chatId);

  // =========================
  // NETWORK STATISTICS
  // =========================

  /// Get network statistics
  Future<MeshNetworkStatistics> getNetworkStatistics();

  /// Refresh mesh status
  Future<void> refreshMeshStatus();

  // =========================
  // DEMO MODE OPERATIONS
  // =========================

  /// Initialize demo scenario
  Future<DemoScenarioResult> initializeDemoScenario(DemoScenarioType scenario);

  /// Get demo steps
  List<dynamic> getDemoSteps();

  /// Clear demo data
  Future<void> clearDemoData();
}
