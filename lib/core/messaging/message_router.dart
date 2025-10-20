import 'dart:async';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import '../../data/services/ble_service.dart';
import '../../core/app_core.dart';
import '../../domain/entities/enhanced_message.dart';
import './offline_message_queue.dart';
import '../../data/repositories/user_preferences.dart';

/// Routes messages with offline queue support (based on BitChat's MessageRouter)
///
/// **ARCHITECTURE CHANGE**: This is now a thin wrapper around OfflineMessageQueue
/// to maintain backward compatibility while using the unified queue system.
///
/// Previously maintained its own in-memory queue, now delegates to:
/// - OfflineMessageQueue (persistent SQLite queue with priority/retry/relay)
///
/// Key features (delegated):
/// - Automatic offline queueing when peer not connected
/// - Auto-flush when peer comes online
/// - Persistent storage (SQLite)
/// - Priority-based delivery
/// - Intelligent retry with exponential backoff
///
/// BitChat Android equivalent: MessageRouter.kt (lines 12-214)
class MessageRouter {
  static final _logger = Logger('MessageRouter');

  // Singleton
  static MessageRouter? _instance;
  static MessageRouter get instance {
    if (_instance == null) {
      throw StateError('MessageRouter not initialized. Call initialize() first.');
    }
    return _instance!;
  }

  // Dependencies
  late final BLEService _bleService;
  late final OfflineMessageQueue _offlineQueue;

  // Statistics (delegated to OfflineMessageQueue)
  int get _totalQueued => _offlineQueue.getStatistics().totalQueued;
  int get _totalFlushed => _offlineQueue.getStatistics().totalDelivered;

  MessageRouter._();

  /// Initialize the message router
  static Future<void> initialize(BLEService bleService) async {
    if (_instance != null) {
      _logger.warning('MessageRouter already initialized');
      return;
    }

    _instance = MessageRouter._();
    _instance!._bleService = bleService;

    // Get OfflineMessageQueue singleton from AppCore
    if (!AppCore.instance.isInitialized) {
      _logger.warning('⚠️ AppCore not initialized - MessageRouter will initialize after AppCore');
      // Wait for AppCore to initialize
      await Future.delayed(Duration(milliseconds: 100));
    }

    _instance!._offlineQueue = AppCore.instance.messageQueue;

    _logger.info('✅ MessageRouter initialized (delegating to OfflineMessageQueue)');
  }

  /// Send a message with automatic offline queueing
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Returns MessageRouteResult indicating whether message was:
  /// - Queued (delegated to OfflineMessageQueue - will auto-send when online)
  /// - Failed (critical error)
  Future<MessageRouteResult> sendMessage({
    required String content,
    required String recipientId,
    String? messageId,
    String? recipientName,
  }) async {
    try {
      _logger.info('📨 MessageRouter: Delegating to OfflineMessageQueue for ${recipientId.substring(0, 8)}...');

      // Get sender's public key
      final prefs = UserPreferences();
      final senderKey = await prefs.getPublicKey();

      if (senderKey.isEmpty) {
        _logger.severe('❌ No sender public key available');
        return MessageRouteResult.failed(messageId ?? Uuid().v4(), 'No sender public key');
      }

      // Delegate to OfflineMessageQueue (which handles direct send + queueing + retry)
      final queuedMessageId = await _offlineQueue.queueMessage(
        chatId: 'chat_$recipientId',
        content: content,
        recipientPublicKey: recipientId,
        senderPublicKey: senderKey,
        priority: MessagePriority.normal,
      );

      _logger.info('📮 Message queued via OfflineMessageQueue: ${queuedMessageId.substring(0, 16)}...');

      return MessageRouteResult.queued(queuedMessageId);

    } catch (e) {
      _logger.severe('❌ Message routing failed: $e');
      final fallbackId = messageId ?? Uuid().v4();
      return MessageRouteResult.failed(fallbackId, e.toString());
    }
  }

  /// Flush queued messages for a specific peer
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Called when:
  /// - Session established (handshake complete)
  /// - Connection restored
  /// - Manual retry
  ///
  /// BitChat equivalent: flushOutboxFor() in MessageRouter.kt (lines 127-156)
  Future<void> flushOutboxFor(String peerId) async {
    _logger.info('📤 MessageRouter: Delegating flush to OfflineMessageQueue for ${peerId.substring(0, 8)}...');

    try {
      // Delegate to OfflineMessageQueue which has persistent queue + retry logic
      await _offlineQueue.flushQueueForPeer(peerId);
      _logger.info('✅ Flush delegated to OfflineMessageQueue');
    } catch (e) {
      _logger.warning('⚠️ Flush delegation failed: $e');
    }
  }

  /// Flush all queued messages (for all peers)
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  ///
  /// Useful for:
  /// - Manual retry all
  /// - Network restored event
  ///
  /// BitChat equivalent: flushAllOutbox() in MessageRouter.kt (lines 158-161)
  Future<void> flushAllOutbox() async {
    _logger.info('📤 MessageRouter: Delegating flush all to OfflineMessageQueue...');

    try {
      // Get all pending messages from OfflineMessageQueue
      final pendingMessages = _offlineQueue.getPendingMessages();
      final uniquePeers = pendingMessages
          .map((msg) => msg.recipientPublicKey)
          .toSet();

      if (uniquePeers.isEmpty) {
        _logger.info('No queued messages to flush');
        return;
      }

      _logger.info('📤 Flushing outbox for ${uniquePeers.length} peer(s) via OfflineMessageQueue...');

      for (final peerId in uniquePeers) {
        await _offlineQueue.flushQueueForPeer(peerId);
      }

      _logger.info('✅ Flush all delegated to OfflineMessageQueue');
    } catch (e) {
      _logger.warning('⚠️ Flush all delegation failed: $e');
    }
  }

  /// Get total queued messages across all peers
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  int getTotalQueuedMessages() {
    return _offlineQueue.getPendingMessages().length;
  }

  /// Get statistics
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  Map<String, dynamic> getStatistics() {
    final stats = _offlineQueue.getStatistics();

    return {
      'totalQueued': stats.totalQueued,
      'totalFlushed': stats.totalDelivered,
      'currentQueueSize': stats.pendingMessages,
      'peersWithQueuedMessages': _getPeerCount(),
      'delegatedToOfflineQueue': true, // Mark that this is delegated
    };
  }

  /// Get unique peer count from OfflineMessageQueue
  int _getPeerCount() {
    final pendingMessages = _offlineQueue.getPendingMessages();
    return pendingMessages.map((msg) => msg.recipientPublicKey).toSet().length;
  }

  /// Clear all queued messages (for testing)
  ///
  /// **DELEGATED** to OfflineMessageQueue for unified queue management.
  Future<void> clearAll() async {
    _logger.info('MessageRouter: Delegating clearAll to OfflineMessageQueue...');
    await _offlineQueue.clearQueue();
    _logger.info('Cleared all queued messages via OfflineMessageQueue');
  }

  /// Dispose resources
  void dispose() {
    _logger.info('MessageRouter disposed (queue managed by OfflineMessageQueue)');
  }
}

// NOTE: QueuedMessage is now defined in offline_message_queue.dart
// This wrapper previously had its own QueuedMessage class, but now delegates
// to OfflineMessageQueue which has a more comprehensive QueuedMessage model

/// Result of message routing attempt
class MessageRouteResult {
  final String messageId;
  final MessageRouteStatus status;
  final String? errorMessage;

  MessageRouteResult._({
    required this.messageId,
    required this.status,
    this.errorMessage,
  });

  factory MessageRouteResult.sentDirectly(String messageId) => MessageRouteResult._(
    messageId: messageId,
    status: MessageRouteStatus.sentDirectly,
  );

  factory MessageRouteResult.queued(String messageId) => MessageRouteResult._(
    messageId: messageId,
    status: MessageRouteStatus.queued,
  );

  factory MessageRouteResult.failed(String messageId, String error) => MessageRouteResult._(
    messageId: messageId,
    status: MessageRouteStatus.failed,
    errorMessage: error,
  );

  bool get isSuccess => status != MessageRouteStatus.failed;
  bool get isQueued => status == MessageRouteStatus.queued;
  bool get isSentDirectly => status == MessageRouteStatus.sentDirectly;
}

/// Message routing status
enum MessageRouteStatus {
  /// Message sent directly (peer connected)
  sentDirectly,

  /// Message queued (peer offline - will auto-send when online)
  queued,

  /// Message routing failed (critical error)
  failed,
}
