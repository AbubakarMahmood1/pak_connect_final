/// Enhanced debug logging utility for mesh relay operations
/// Provides emoji-based, structured logging for clear debugging
/// Supports filtering and truncation for better readability
class MeshDebugLogger {
  static const bool _debugEnabled = true;
  static const int _defaultTruncateLength = 16;
  static const int _nodeIdTruncateLength = 8;
  
  // 🔀 RELAY OPERATIONS
  
  /// Log relay operation start
  static void relayStart(String messageId, String fromNode, String toNode) {
    if (!_debugEnabled) return;
    print('🔀 RELAY START: ${_truncate(messageId)}... from ${_truncate(fromNode, _nodeIdTruncateLength)}... to ${_truncate(toNode, _nodeIdTruncateLength)}...');
  }
  
  /// Log successful relay forwarding
  static void relaySuccess(String messageId, String nextHop, {String? routeScore}) {
    if (!_debugEnabled) return;
    final scoreText = routeScore != null ? ' (score: $routeScore)' : '';
    print('✅ RELAY SUCCESS: ${_truncate(messageId)}... forwarded to ${_truncate(nextHop, _nodeIdTruncateLength)}...$scoreText');
  }
  
  /// Log relay delivered to final recipient
  static void relayDelivered(String messageId, String originalSender, String recipient) {
    if (!_debugEnabled) return;
    print('🎯 RELAY DELIVERED: ${_truncate(messageId)}... from ${_truncate(originalSender, _nodeIdTruncateLength)}... to ${_truncate(recipient, _nodeIdTruncateLength)}...');
  }
  
  /// Log relay blocked by spam prevention or TTL
  static void relayBlocked(String messageId, String reason, {double? spamScore}) {
    if (!_debugEnabled) return;
    final scoreText = spamScore != null ? ' (spam score: ${spamScore.toStringAsFixed(2)})' : '';
    print('🚫 RELAY BLOCKED: ${_truncate(messageId)}... reason: $reason$scoreText');
  }
  
  /// Log relay dropped due to no next hop or TTL exceeded
  static void relayDropped(String messageId, String reason) {
    if (!_debugEnabled) return;
    print('⚠️ RELAY DROPPED: ${_truncate(messageId)}... reason: $reason');
  }
  
  // 📤 MESSAGE QUEUING
  
  /// Log message added to queue
  static void messageQueued(String messageId, String recipient, String priority) {
    if (!_debugEnabled) return;
    print('📤 MESSAGE QUEUED: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}... priority: $priority');
  }
  
  /// Log message removed from queue for delivery
  static void messageDequeued(String messageId, String recipient) {
    if (!_debugEnabled) return;
    print('📥 MESSAGE DEQUEUED: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}... for delivery');
  }
  
  /// Log message delivery attempt
  static void deliveryAttempt(String messageId, int attempt, int maxRetries) {
    if (!_debugEnabled) return;
    print('🚀 DELIVERY ATTEMPT: ${_truncate(messageId)}... attempt $attempt/$maxRetries');
  }
  
  /// Log message delivery success
  static void deliverySuccess(String messageId, String recipient) {
    if (!_debugEnabled) return;
    print('✅ DELIVERY SUCCESS: ${_truncate(messageId)}... to ${_truncate(recipient, _nodeIdTruncateLength)}...');
  }
  
  /// Log message delivery failure
  static void deliveryFailed(String messageId, String reason, int attempt, int maxRetries) {
    if (!_debugEnabled) return;
    print('❌ DELIVERY FAILED: ${_truncate(messageId)}... reason: $reason (attempt $attempt/$maxRetries)');
  }
  
  // 🌐 CONNECTION EVENTS
  
  /// Log device connected event
  static void deviceConnected(String deviceId, {int? queuedMessages}) {
    if (!_debugEnabled) return;
    final queueText = queuedMessages != null ? ' - checking $queuedMessages queued messages' : ' - checking queued messages';
    print('🌐 DEVICE CONNECTED: ${_truncate(deviceId, _nodeIdTruncateLength)}...$queueText');
  }
  
  /// Log device disconnected event
  static void deviceDisconnected(String deviceId) {
    if (!_debugEnabled) return;
    print('🔌 DEVICE DISCONNECTED: ${_truncate(deviceId, _nodeIdTruncateLength)}... - future messages will queue');
  }
  
  /// Log automatic queue delivery trigger
  static void queueDeliveryTriggered(String deviceId, int messageCount) {
    if (!_debugEnabled) return;
    print('📋 QUEUE DELIVERY TRIGGERED: ${_truncate(deviceId, _nodeIdTruncateLength)}... processing $messageCount messages');
  }
  
  /// Log queue delivery completion
  static void queueDeliveryComplete(String deviceId, int processed, int successful, int failed) {
    if (!_debugEnabled) return;
    print('✅ QUEUE DELIVERY COMPLETE: ${_truncate(deviceId, _nodeIdTruncateLength)}... $successful/$processed successful ($failed failed)');
  }
  
  // 💾 CHAT STORAGE
  
  /// Log chat message saved
  static void chatMessageSaved(String messageId, String chatId, String sender) {
    if (!_debugEnabled) return;
    print('💾 MESSAGE SAVED: ${_truncate(messageId)}... in chat ${_truncate(chatId)}... from ${_truncate(sender, _nodeIdTruncateLength)}...');
  }
  
  /// Log chat ID generation
  static void chatIdGenerated(String chatId, String user1, String user2) {
    if (!_debugEnabled) return;
    print('🔗 CHAT ID GENERATED: ${_truncate(chatId)}... for ${_truncate(user1, _nodeIdTruncateLength)}... ↔ ${_truncate(user2, _nodeIdTruncateLength)}...');
  }
  
  // ❌ ERROR HANDLING
  
  /// Log general errors with operation context
  static void error(String operation, String error, {String? messageId}) {
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    print('❌ ERROR in $operation: $error$msgText');
  }
  
  /// Log warning conditions
  static void warning(String operation, String warning, {String? messageId}) {
    if (!_debugEnabled) return;
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    print('⚠️ WARNING in $operation: $warning$msgText');
  }
  
  // 🔧 UTILITY & FORMATTING
  
  /// Create section separator for major operations
  static void separator(String title) {
    if (!_debugEnabled) return;
    final separator = '=' * 60;
    print(separator);
    print('🔍 $title');
    print(separator);
  }
  
  /// Create sub-section header
  static void subsection(String title) {
    if (!_debugEnabled) return;
    print('--- $title ---');
  }
  
  /// Log key-value information
  static void info(String key, String value) {
    if (!_debugEnabled) return;
    print('ℹ️ $key: $value');
  }
  
  /// Log operation timing
  static void timing(String operation, Duration duration, {String? messageId}) {
    if (!_debugEnabled) return;
    final msgText = messageId != null ? ' (msg: ${_truncate(messageId)})' : '';
    print('⏱️ TIMING $operation: ${duration.inMilliseconds}ms$msgText');
  }
  
  // Private utility methods
  
  /// Safely truncate string to specified length
  static String _truncate(String? input, [int length = _defaultTruncateLength]) {
    if (input == null || input.isEmpty) return 'NULL';
    if (input.length <= length) return input;
    return input.substring(0, length);
  }
  
  /// Check if debug logging is enabled
  static bool get isDebugEnabled => _debugEnabled;
}