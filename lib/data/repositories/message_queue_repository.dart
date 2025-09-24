import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/messaging/offline_message_queue.dart';
import '../../domain/entities/enhanced_message.dart';

/// Repository wrapper for unified OfflineMessageQueue
/// This provides a clean interface for message queue operations
class MessageQueueRepository {
  late final OfflineMessageQueue _queue;
  
  MessageQueueRepository() {
    _queue = OfflineMessageQueue();
  }
  
  /// Initialize the unified message queue
  Future<void> initialize() async {
    await _queue.initialize();
  }
  
  /// Queue a message using the unified queue system
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
  }) async {
    return await _queue.queueMessage(
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
    );
  }
  
  /// Get messages for a specific recipient
  Future<List<QueuedMessage>> getMessagesForTarget(String targetPublicKey) async {
    final allMessages = _queue.getMessagesByStatus(QueuedMessageStatus.pending);
    return allMessages.where((m) => m.recipientPublicKey == targetPublicKey).toList();
  }
  
  /// Remove a specific message from the queue
  Future<void> removeMessage(String messageId) async {
    await _queue.removeMessage(messageId);
  }
  
  /// Get queue statistics
  QueueStatistics getQueueStatistics() {
    return _queue.getStatistics();
  }
  
  /// Set queue online/offline status
  Future<void> setOnline() async {
    await _queue.setOnline();
  }
  
  void setOffline() {
    _queue.setOffline();
  }
  
  /// Dispose queue resources
  void dispose() {
    _queue.dispose();
  }
}