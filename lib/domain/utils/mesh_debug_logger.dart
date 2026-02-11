import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../../domain/values/id_types.dart';

/// Enhanced debug logging utility for mesh relay operations
/// Provides emoji-based, structured logging for clear debugging
/// Supports filtering and truncation for better readability
///
/// Now uses proper Logger for production-ready logging
class MeshDebugLogger {
  static final _logger = Logger('MeshDebugLogger');
  static const int _defaultTruncateLength = 16;
  static const int _nodeIdTruncateLength = 8;

  // 🔀 RELAY OPERATIONS

  /// Log relay operation start
  static void relayStart(String messageId, String fromNode, String toNode) {
    _logger.fine(
      '🔀 RELAY START: ${_truncate(messageId)}... from ${_truncate(fromNode, _nodeIdTruncateLength)}... to ${_truncate(toNode, _nodeIdTruncateLength)}...',
    );
  }

  static void relayStartId(
    MessageId messageId,
    String fromNode,
    String toNode,
  ) => relayStart(messageId.value, fromNode, toNode);

  /// Log successful relay forwarding
  static void relaySuccess(
    String messageId,
    String nextHop, {
    String? routeScore,
  }) {
    final scoreText = routeScore != null ? ' (score: $routeScore)' : '';
    _logger.info(
      '✅ RELAY SUCCESS: ${_truncate(messageId)}... forwarded to ${_truncate(nextHop, _nodeIdTruncateLength)}...$scoreText',
    );
  }

  static void relaySuccessId(
    MessageId messageId,
    String nextHop, {
    String? routeScore,
  }) => relaySuccess(messageId.value, nextHop, routeScore: routeScore);

  /// Log relay delivered to final recipient
  static void relayDelivered(
    String messageId,
    String originalSender,
    String recipient,
  ) {
    _logger.info(
      '🎯 RELAY DELIVERED: ${_truncate(messageId)}... from ${_truncate(originalSender, _nodeIdTruncateLength)}... to ${_truncate(recipient, _nodeIdTruncateLength)}...',
    );
  }

  static void relayDeliveredId(
    MessageId messageId,
    String originalSender,
    String recipient,
  ) => relayDelivered(messageId.value, originalSender, recipient);

  /// Log relay blocked by spam prevention or TTL
  static void relayBlocked(
    String messageId,
    String reason, {
    double? spamScore,
  }) {
    final scoreText = spamScore != null
        ? ' (spam score: ${spamScore.toStringAsFixed(2)})'
        : '';
    _logger.warning(
      '🚫 RELAY BLOCKED: ${_truncate(messageId)}... reason: $reason$scoreText',
    );
  }

  /// Log relay dropped due to no next hop or TTL exceeded
  static void relayDropped(String messageId, String reason) {
    _logger.warning(
      '⚠️ RELAY DROPPED: ${_truncate(messageId)}... reason: $reason',
    );
  }

  static void relayBlockedId(
    MessageId messageId,
    String reason, {
    double? spamScore,
  }) => relayBlocked(messageId.value, reason, spamScore: spamScore);

  static void relayDroppedId(MessageId messageId, String reason) =>
      relayDropped(messageId.value, reason);

  // 📤 MESSAGE QUEUING

  /// Log message added to queue
  static void messageQueued(
    String messageId,
    String recipient,
    String priority,
  ) {
    _logger.fine(
      '📤 MESSAGE QUEUED: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}... priority: $priority',
    );
  }

  static void messageQueuedId(
    MessageId messageId,
    String recipient,
    String priority,
  ) => messageQueued(messageId.value, recipient, priority);

  /// Log message removed from queue for delivery
  static void messageDequeued(String messageId, String recipient) {
    _logger.fine(
      '📥 MESSAGE DEQUEUED: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}... for delivery',
    );
  }

  static void messageDequeuedId(MessageId messageId, String recipient) =>
      messageDequeued(messageId.value, recipient);

  /// Log message delivery attempt
  static void deliveryAttempt(String messageId, int attempt, int maxRetries) {
    _logger.fine(
      '🚀 DELIVERY ATTEMPT: ${_truncate(messageId)}... attempt $attempt/$maxRetries',
    );
  }

  static void deliveryAttemptId(
    MessageId messageId,
    int attempt,
    int maxRetries,
  ) => deliveryAttempt(messageId.value, attempt, maxRetries);

  /// Log message delivery success
  static void deliverySuccess(String messageId, String recipient) {
    _logger.info(
      '✅ DELIVERY SUCCESS: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}...',
    );
  }

  static void deliverySuccessId(MessageId messageId, String recipient) =>
      deliverySuccess(messageId.value, recipient);

  /// Log message delivery failure
  static void deliveryFailed(
    String messageId,
    String reason,
    int attempt,
    int maxRetries,
  ) {
    _logger.warning(
      '❌ DELIVERY FAILED: ${_truncate(messageId)}... reason: $reason (attempt $attempt/$maxRetries)',
    );
  }

  static void deliveryFailedId(
    MessageId messageId,
    String reason,
    int attempt,
    int maxRetries,
  ) => deliveryFailed(messageId.value, reason, attempt, maxRetries);

  // 🌐 CONNECTION EVENTS

  /// Log device connected event
  static void deviceConnected(String deviceId, {int? queuedMessages}) {
    final queueText = queuedMessages != null
        ? ' - checking $queuedMessages queued messages'
        : ' - checking queued messages';
    _logger.info(
      '🌐 DEVICE CONNECTED: ${_truncate(deviceId, _nodeIdTruncateLength)}...$queueText',
    );
  }

  /// Log device disconnected event
  static void deviceDisconnected(String deviceId) {
    _logger.info(
      '🔌 DEVICE DISCONNECTED: ${_truncate(deviceId, _nodeIdTruncateLength)}... - future messages will queue',
    );
  }

  /// Log automatic queue delivery trigger
  static void queueDeliveryTriggered(String deviceId, int messageCount) {
    _logger.info(
      '📋 QUEUE DELIVERY TRIGGERED: ${_truncate(deviceId, _nodeIdTruncateLength)}... processing $messageCount messages',
    );
  }

  static void queueDeliveryTriggeredId(ChatId deviceId, int messageCount) =>
      queueDeliveryTriggered(deviceId.value, messageCount);

  /// Log queue delivery completion
  static void queueDeliveryComplete(
    String deviceId,
    int processed,
    int successful,
    int failed,
  ) {
    _logger.info(
      '✅ QUEUE DELIVERY COMPLETE: ${_truncate(deviceId, _nodeIdTruncateLength)}... $successful/$processed successful ($failed failed)',
    );
  }

  static void queueDeliveryCompleteId(
    ChatId deviceId,
    int processed,
    int successful,
    int failed,
  ) => queueDeliveryComplete(deviceId.value, processed, successful, failed);

  // 💾 CHAT STORAGE

  /// Log chat message saved
  static void chatMessageSaved(String messageId, String chatId, String sender) {
    _logger.fine(
      '💾 MESSAGE SAVED: ${_truncate(messageId)}... in chat ${_truncate(chatId)}... from ${_truncate(sender, _nodeIdTruncateLength)}...',
    );
  }

  static void chatMessageSavedId(
    MessageId messageId,
    String chatId,
    String sender,
  ) => chatMessageSaved(messageId.value, chatId, sender);

  /// Log chat ID generation
  static void chatIdGenerated(String chatId, String user1, String user2) {
    _logger.fine(
      '🔗 CHAT ID GENERATED: ${_truncate(chatId)}... for ${_truncate(user1, _nodeIdTruncateLength)}... ↔ ${_truncate(user2, _nodeIdTruncateLength)}...',
    );
  }

  // ❌ ERROR HANDLING

  /// Log general errors with operation context
  static void error(String operation, String error, {String? messageId}) {
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    _logger.severe('❌ ERROR in $operation: $error$msgText');
  }

  static void errorId(
    String operation,
    String errorMessage, {
    MessageId? messageId,
  }) => error(operation, errorMessage, messageId: messageId?.value);

  /// Log warning conditions
  static void warning(String operation, String warning, {String? messageId}) {
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    _logger.warning('⚠️ WARNING in $operation: $warning$msgText');
  }

  static void warningId(
    String operation,
    String warningMessage, {
    MessageId? messageId,
  }) => warning(operation, warningMessage, messageId: messageId?.value);

  // 🔧 UTILITY & FORMATTING

  /// Create section separator for major operations
  static void separator(String title) {
    final separator = '=' * 60;
    _logger.fine(separator);
    _logger.fine('🔍 $title');
    _logger.fine(separator);
  }

  /// Create sub-section header
  static void subsection(String title) {
    _logger.fine('--- $title ---');
  }

  /// Log key-value information
  static void info(String key, String value) {
    _logger.fine('ℹ️ $key: $value');
  }

  /// Log operation timing
  static void timing(String operation, Duration duration, {String? messageId}) {
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    _logger.fine('⏱️ TIMING $operation: ${duration.inMilliseconds}ms$msgText');
  }

  // Private utility methods

  /// Safely truncate string to specified length
  static String _truncate(
    String? input, [
    int length = _defaultTruncateLength,
  ]) {
    if (input == null || input.isEmpty) return 'NULL';
    if (input.length <= length) return input;
    return input.substring(0, length);
  }

  /// Check if debug logging is enabled (always true with proper Logger filtering)
  static bool get isDebugEnabled => kDebugMode;
}
