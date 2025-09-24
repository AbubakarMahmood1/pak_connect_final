// Comprehensive offline message delivery and queue management system

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/enhanced_message.dart';
import '../security/message_security.dart';
import '../models/mesh_relay_models.dart';

/// Comprehensive offline message queue with intelligent retry and delivery management
class OfflineMessageQueue {
  static final _logger = Logger('OfflineMessageQueue');
  
  static const String _queueKey = 'offline_message_queue_v2';
  static const String _legacyQueueKey = 'offline_message_queue_v1'; // Backward compatibility
  static const String _deletedMessagesKey = 'deleted_message_ids_v1';
  static const String _queueHashKey = 'queue_hash_cache_v1';
  static const String _migrationKey = 'queue_migration_completed_v2';
  static const int _maxRetries = 5;
  static const Duration _initialDelay = Duration(seconds: 2);
  static const Duration _maxDelay = Duration(minutes: 10);
  
  // Performance optimization constants
  static const int _hashCacheTimeout = 30; // seconds
  static const int _maxDeletedIdsToKeep = 5000;
  static const int _cleanupThreshold = 10000;
  
  // Queue management
  final List<QueuedMessage> _messageQueue = [];
  final Map<String, Timer> _activeRetries = {};
  
  // Queue hash synchronization
  final Set<String> _deletedMessageIds = {};
  String? _cachedQueueHash;
  DateTime? _lastHashCalculation;
  
  // Connection monitoring
  bool _isOnline = false;
  Timer? _connectivityCheckTimer;
  
  // Statistics
  int _totalQueued = 0;
  int _totalDelivered = 0;
  int _totalFailed = 0;
  
  // Callbacks
  Function(QueuedMessage message)? onMessageQueued;
  Function(QueuedMessage message)? onMessageDelivered;
  Function(QueuedMessage message, String reason)? onMessageFailed;
  Function(QueueStatistics stats)? onStatsUpdated;
  Function(String messageId)? onSendMessage;
  Function()? onConnectivityCheck;
  
  /// Initialize the offline message queue
  Future<void> initialize({
    Function(QueuedMessage message)? onMessageQueued,
    Function(QueuedMessage message)? onMessageDelivered,
    Function(QueuedMessage message, String reason)? onMessageFailed,
    Function(QueueStatistics stats)? onStatsUpdated,
    Function(String messageId)? onSendMessage,
    Function()? onConnectivityCheck,
  }) async {
    this.onMessageQueued = onMessageQueued;
    this.onMessageDelivered = onMessageDelivered;
    this.onMessageFailed = onMessageFailed;
    this.onStatsUpdated = onStatsUpdated;
    this.onSendMessage = onSendMessage;
    this.onConnectivityCheck = onConnectivityCheck;
    
    await _loadQueueFromStorage();
    await _loadDeletedMessageIds();
    await _performMigrationIfNeeded();
    _startConnectivityMonitoring();
    _startPeriodicCleanup();
    
    _logger.info('Offline message queue initialized with ${_messageQueue.length} pending messages');
  }
  
  /// Queue a message for offline delivery
  Future<String> queueMessage({
    required String chatId,
    required String content,
    required String recipientPublicKey,
    required String senderPublicKey,
    MessagePriority priority = MessagePriority.normal,
    String? replyToMessageId,
    List<String> attachments = const [],
  }) async {
    try {
      // Generate secure message ID with nonce tracking
      final messageId = await MessageSecurity.generateSecureMessageId(
        senderPublicKey: senderPublicKey,
        content: content,
        recipientPublicKey: recipientPublicKey,
      );
      
      final queuedMessage = QueuedMessage(
        id: messageId,
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientPublicKey,
        senderPublicKey: senderPublicKey,
        priority: priority,
        queuedAt: DateTime.now(),
        replyToMessageId: replyToMessageId,
        attachments: attachments,
        attempts: 0,
        maxRetries: _getMaxRetriesForPriority(priority),
      );
      
      // Add to queue with priority ordering
      _insertMessageByPriority(queuedMessage);
      
      await _saveQueueToStorage();
      
      _totalQueued++;
      onMessageQueued?.call(queuedMessage);
      _updateStatistics();
      
      _logger.info('Message queued: ${messageId.substring(0, 16)}... (priority: ${priority.name})');
      
      // Attempt immediate delivery if online
      if (_isOnline) {
        _tryDeliveryForMessage(queuedMessage);
      }
      
      return messageId;
      
    } catch (e) {
      _logger.severe('Failed to queue message: $e');
      throw MessageQueueException('Failed to queue message: $e');
    }
  }
  
  /// Mark connection as online and attempt delivery of queued messages
  Future<void> setOnline() async {
    if (!_isOnline) {
      _isOnline = true;
      _logger.info('Connection online - attempting delivery of ${_messageQueue.length} queued messages');
      await _processQueue();
    }
  }
  
  /// Mark connection as offline
  void setOffline() {
    if (_isOnline) {
      _isOnline = false;
      _logger.info('Connection offline - queuing future messages');
      _cancelAllActiveRetries();
    }
  }
  
  /// Process the entire message queue
  Future<void> _processQueue() async {
    if (_messageQueue.isEmpty) return;
    
    _logger.info('Processing message queue with ${_messageQueue.length} messages');
    
    // Sort by priority and timestamp
    _messageQueue.sort((a, b) {
      final priorityComparison = b.priority.index.compareTo(a.priority.index);
      if (priorityComparison != 0) return priorityComparison;
      return a.queuedAt.compareTo(b.queuedAt);
    });
    
    // Process messages with staggered delays to prevent overwhelming
    for (int i = 0; i < _messageQueue.length; i++) {
      final message = _messageQueue[i];
      
      if (message.status == QueuedMessageStatus.pending) {
        // Stagger deliveries to prevent network congestion
        final delay = Duration(milliseconds: i * 100);
        
        Timer(delay, () {
          if (_isOnline) {
            _tryDeliveryForMessage(message);
          }
        });
      }
    }
  }
  
  /// Attempt delivery for a specific message
  Future<void> _tryDeliveryForMessage(QueuedMessage message) async {
    if (message.status != QueuedMessageStatus.pending) return;
    
    try {
      message.status = QueuedMessageStatus.sending;
      message.attempts++;
      message.lastAttemptAt = DateTime.now();
      
      await _saveQueueToStorage();
      
      _logger.fine('Attempting delivery: ${message.id.substring(0, 16)}... (attempt ${message.attempts}/${message.maxRetries})');
      
      // Validate message before sending (replay protection)
      final validationResult = await MessageSecurity.validateMessage(
        messageId: message.id,
        senderPublicKey: message.senderPublicKey,
        content: message.content,
        recipientPublicKey: message.recipientPublicKey,
        allowRetry: true,
      );
      
      if (!validationResult.isValid) {
        if (validationResult.isReplay) {
          _logger.warning('Message replay detected: ${message.id.substring(0, 16)}...');
          await _markMessageFailed(message, 'Replay protection triggered');
        } else {
          _logger.severe('Message validation failed: ${validationResult.errorMessage}');
          await _markMessageFailed(message, validationResult.errorMessage ?? 'Validation failed');
        }
        return;
      }
      
      // Attempt actual delivery via callback
      onSendMessage?.call(message.id);
      
      // For now, simulate successful delivery after callback
      // In a real implementation, this would be called by the BLE service
      Timer(Duration(seconds: 2), () async {
        await _simulateDeliveryResult(message, success: true);
      });
      
    } catch (e) {
      _logger.severe('Delivery attempt failed for ${message.id.substring(0, 16)}...: $e');
      await _handleDeliveryFailure(message, e.toString());
    }
  }
  
  /// Handle successful message delivery (called by BLE service)
  Future<void> markMessageDelivered(String messageId) async {
    final message = _messageQueue.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return;
    
    message.status = QueuedMessageStatus.delivered;
    message.deliveredAt = DateTime.now();
    
    _cancelRetryTimer(messageId);
    _removeMessageFromQueue(messageId);
    
    await _saveQueueToStorage();
    
    _totalDelivered++;
    onMessageDelivered?.call(message);
    _updateStatistics();
    
    _logger.info('Message delivered successfully: ${messageId.substring(0, 16)}...');
  }
  
  /// Handle failed message delivery (called by BLE service)
  Future<void> markMessageFailed(String messageId, String reason) async {
    final message = _messageQueue.where((m) => m.id == messageId).firstOrNull;
    if (message == null) return;
    
    await _handleDeliveryFailure(message, reason);
  }
  
  /// Handle delivery failure with intelligent retry
  Future<void> _handleDeliveryFailure(QueuedMessage message, String reason) async {
    _logger.warning('Delivery failed for ${message.id.substring(0, 16)}...: $reason (attempt ${message.attempts}/${message.maxRetries})');
    
    if (message.attempts >= message.maxRetries) {
      await _markMessageFailed(message, reason);
      return;
    }
    
    // Calculate exponential backoff delay
    final backoffDelay = _calculateBackoffDelay(message.attempts);
    
    message.status = QueuedMessageStatus.retrying;
    message.nextRetryAt = DateTime.now().add(backoffDelay);
    
    await _saveQueueToStorage();
    
    // Schedule retry
    final retryTimer = Timer(backoffDelay, () async {
      if (_isOnline) {
        await _tryDeliveryForMessage(message);
      } else {
        message.status = QueuedMessageStatus.pending;
        await _saveQueueToStorage();
      }
    });
    
    _activeRetries[message.id] = retryTimer;
    
    _logger.info('Retry scheduled for ${message.id.substring(0, 16)}... in ${backoffDelay.inSeconds}s');
  }
  
  /// Mark message as permanently failed
  Future<void> _markMessageFailed(QueuedMessage message, String reason) async {
    message.status = QueuedMessageStatus.failed;
    message.failureReason = reason;
    message.failedAt = DateTime.now();
    
    _cancelRetryTimer(message.id);
    
    // Keep failed messages for a while for debugging/retry
    // Remove after 24 hours
    Timer(Duration(hours: 24), () {
      _removeMessageFromQueue(message.id);
      _saveQueueToStorage();
    });
    
    await _saveQueueToStorage();
    
    _totalFailed++;
    onMessageFailed?.call(message, reason);
    _updateStatistics();
    
    _logger.severe('Message permanently failed: ${message.id.substring(0, 16)}... - $reason');
  }
  
  /// Get current queue statistics
  QueueStatistics getStatistics() {
    final pending = _messageQueue.where((m) => m.status == QueuedMessageStatus.pending).length;
    final sending = _messageQueue.where((m) => m.status == QueuedMessageStatus.sending).length;
    final retrying = _messageQueue.where((m) => m.status == QueuedMessageStatus.retrying).length;
    final failed = _messageQueue.where((m) => m.status == QueuedMessageStatus.failed).length;
    
    final oldestPending = _messageQueue
        .where((m) => m.status == QueuedMessageStatus.pending)
        .fold<QueuedMessage?>(null, (oldest, current) {
      if (oldest == null || current.queuedAt.isBefore(oldest.queuedAt)) {
        return current;
      }
      return oldest;
    });
    
    return QueueStatistics(
      totalQueued: _totalQueued,
      totalDelivered: _totalDelivered,
      totalFailed: _totalFailed,
      pendingMessages: pending,
      sendingMessages: sending,
      retryingMessages: retrying,
      failedMessages: failed,
      isOnline: _isOnline,
      oldestPendingMessage: oldestPending,
      averageDeliveryTime: _calculateAverageDeliveryTime(),
    );
  }
  
  /// Retry all failed messages
  Future<void> retryFailedMessages() async {
    final failedMessages = _messageQueue
        .where((m) => m.status == QueuedMessageStatus.failed)
        .toList();
    
    if (failedMessages.isEmpty) {
      _logger.info('No failed messages to retry');
      return;
    }
    
    _logger.info('Retrying ${failedMessages.length} failed messages');
    
    for (final message in failedMessages) {
      message.status = QueuedMessageStatus.pending;
      message.attempts = 0;
      message.failureReason = null;
      message.failedAt = null;
      message.nextRetryAt = null;
    }
    
    await _saveQueueToStorage();
    
    if (_isOnline) {
      await _processQueue();
    }
  }
  
  /// Clear all messages from queue
  Future<void> clearQueue() async {
    _cancelAllActiveRetries();
    _messageQueue.clear();
    await _saveQueueToStorage();
    
    _logger.info('Message queue cleared');
    _updateStatistics();
  }
  
  /// Get messages by status
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return _messageQueue.where((m) => m.status == status).toList();
  }
  
  /// Remove specific message from queue
  Future<void> removeMessage(String messageId) async {
    _cancelRetryTimer(messageId);
    _removeMessageFromQueue(messageId);
    await _saveQueueToStorage();
  }
  
  // Private methods
  
  /// Insert message into queue by priority
  void _insertMessageByPriority(QueuedMessage message) {
    // Find insertion point based on priority
    int insertIndex = 0;
    for (int i = 0; i < _messageQueue.length; i++) {
      if (_messageQueue[i].priority.index <= message.priority.index) {
        insertIndex = i;
        break;
      }
      insertIndex = i + 1;
    }
    
    _messageQueue.insert(insertIndex, message);
  }
  
  /// Remove message from queue
  void _removeMessageFromQueue(String messageId) {
    _messageQueue.removeWhere((m) => m.id == messageId);
  }
  
  /// Calculate exponential backoff delay
  Duration _calculateBackoffDelay(int attempt) {
    final exponentialDelay = Duration(
      milliseconds: _initialDelay.inMilliseconds * (1 << (attempt - 1))
    );
    
    // Cap at maximum delay and add jitter
    final cappedDelay = exponentialDelay.inMilliseconds > _maxDelay.inMilliseconds
        ? _maxDelay
        : exponentialDelay;
    
    // Add random jitter (±25%)
    final jitterRange = cappedDelay.inMilliseconds * 0.25;
    final jitter = (DateTime.now().millisecond % (jitterRange * 2)) - jitterRange;
    
    return Duration(milliseconds: (cappedDelay.inMilliseconds + jitter).round());
  }
  
  /// Get max retries based on message priority
  int _getMaxRetriesForPriority(MessagePriority priority) {
    switch (priority) {
      case MessagePriority.urgent:
        return _maxRetries + 2;
      case MessagePriority.high:
        return _maxRetries + 1;
      case MessagePriority.normal:
        return _maxRetries;
      case MessagePriority.low:
        return _maxRetries - 1;
    }
  }
  
  /// Start connectivity monitoring
  void _startConnectivityMonitoring() {
    _connectivityCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      onConnectivityCheck?.call();
    });
  }
  
  /// Cancel all active retry timers
  void _cancelAllActiveRetries() {
    for (final timer in _activeRetries.values) {
      timer.cancel();
    }
    _activeRetries.clear();
  }
  
  /// Cancel retry timer for specific message
  void _cancelRetryTimer(String messageId) {
    _activeRetries[messageId]?.cancel();
    _activeRetries.remove(messageId);
  }
  
  /// Calculate average delivery time
  Duration _calculateAverageDeliveryTime() {
    final deliveredMessages = _messageQueue
        .where((m) => m.status == QueuedMessageStatus.delivered && m.deliveredAt != null)
        .toList();
    
    if (deliveredMessages.isEmpty) return Duration.zero;
    
    final totalTime = deliveredMessages
        .map((m) => m.deliveredAt!.difference(m.queuedAt))
        .fold<Duration>(Duration.zero, (sum, duration) => sum + duration);
    
    return Duration(milliseconds: totalTime.inMilliseconds ~/ deliveredMessages.length);
  }
  
  /// Update statistics and notify listeners
  void _updateStatistics() {
    final stats = getStatistics();
    onStatsUpdated?.call(stats);
  }
  
  /// Simulate delivery result (for testing)
  Future<void> _simulateDeliveryResult(QueuedMessage message, {required bool success}) async {
    await Future.delayed(Duration(milliseconds: 500)); // Simulate network delay
    
    if (success) {
      await markMessageDelivered(message.id);
    } else {
      await markMessageFailed(message.id, 'Simulated delivery failure');
    }
  }
  
  /// Load queue from persistent storage
  Future<void> _loadQueueFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getStringList(_queueKey) ?? [];
      
      _messageQueue.clear();
      for (final json in queueJson) {
        try {
          final message = QueuedMessage.fromJson(jsonDecode(json));
          _messageQueue.add(message);
        } catch (e) {
          _logger.warning('Failed to parse queued message: $e');
        }
      }
      
      _logger.info('Loaded ${_messageQueue.length} messages from storage');
    } catch (e) {
      _logger.severe('Failed to load message queue: $e');
    }
  }
  
  /// Save queue to persistent storage
  Future<void> _saveQueueToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = _messageQueue
          .map((message) => jsonEncode(message.toJson()))
          .toList();
      
      await prefs.setStringList(_queueKey, queueJson);
      
      // Invalidate hash cache since queue changed
      _cachedQueueHash = null;
      _lastHashCalculation = null;
    } catch (e) {
      _logger.warning('Failed to save message queue: $e');
    }
  }
  
  /// Load deleted message IDs from persistent storage
  Future<void> _loadDeletedMessageIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deletedIds = prefs.getStringList(_deletedMessagesKey) ?? [];
      _deletedMessageIds.clear();
      _deletedMessageIds.addAll(deletedIds);
      
      _logger.info('Loaded ${_deletedMessageIds.length} deleted message IDs');
    } catch (e) {
      _logger.severe('Failed to load deleted message IDs: $e');
    }
  }
  
  /// Save deleted message IDs to persistent storage
  Future<void> _saveDeletedMessageIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_deletedMessagesKey, _deletedMessageIds.toList());
    } catch (e) {
      _logger.warning('Failed to save deleted message IDs: $e');
    }
  }
  
  // ===== QUEUE HASH SYNCHRONIZATION METHODS =====
  
  /// Calculate deterministic hash of current queue state
  /// Excludes delivered/expired messages and includes deleted message tracking
  String calculateQueueHash({bool forceRecalculation = false}) {
    if (!forceRecalculation && _cachedQueueHash != null && _lastHashCalculation != null) {
      // Use cache if less than 30 seconds old
      final cacheAge = DateTime.now().difference(_lastHashCalculation!);
      if (cacheAge.inSeconds < 30) {
        return _cachedQueueHash!;
      }
    }
    
    // Get syncable messages (excluding delivered/failed)
    final syncableMessages = _messageQueue
        .where((m) => m.status != QueuedMessageStatus.delivered &&
                     m.status != QueuedMessageStatus.failed)
        .toList();
    
    // Sort by message ID for consistent ordering
    syncableMessages.sort((a, b) => a.id.compareTo(b.id));
    
    // Create hash input combining message metadata and deleted IDs
    final hashComponents = <String>[];
    
    // Add active message metadata
    for (final message in syncableMessages) {
      final messageData = _getMessageHashData(message);
      hashComponents.add(messageData);
    }
    
    // Add deleted message IDs (sorted for consistency)
    final sortedDeletedIds = _deletedMessageIds.toList()..sort();
    hashComponents.addAll(sortedDeletedIds.map((id) => 'deleted:$id'));
    
    // Calculate final hash
    final combinedData = hashComponents.join('|');
    final bytes = utf8.encode(combinedData);
    final digest = sha256.convert(bytes);
    
    // Cache result
    _cachedQueueHash = digest.toString();
    _lastHashCalculation = DateTime.now();
    
    _logger.fine('Calculated queue hash: ${_cachedQueueHash!.substring(0, 16)}... (${syncableMessages.length} messages, ${_deletedMessageIds.length} deleted)');
    
    return _cachedQueueHash!;
  }
  
  /// Get hash data for a specific message
  String _getMessageHashData(QueuedMessage message) {
    return [
      message.id,
      message.status.index.toString(),
      message.queuedAt.millisecondsSinceEpoch.toString(),
      message.priority.index.toString(),
      message.attempts.toString(),
      message.messageHash ?? '',
    ].join(':');
  }
  
  /// Get queue sync information for mesh networking
  QueueSyncMessage createSyncMessage(String nodeId) {
    final syncableMessages = _messageQueue
        .where((m) => m.status != QueuedMessageStatus.delivered &&
                     m.status != QueuedMessageStatus.failed)
        .toList();
    
    final messageIds = syncableMessages.map((m) => m.id).toList();
    final messageHashes = <String, String>{};
    
    for (final message in syncableMessages) {
      if (message.messageHash != null) {
        messageHashes[message.id] = message.messageHash!;
      }
    }
    
    final stats = QueueSyncStats(
      totalMessages: _messageQueue.length,
      pendingMessages: _messageQueue.where((m) => m.status == QueuedMessageStatus.pending).length,
      failedMessages: _messageQueue.where((m) => m.status == QueuedMessageStatus.failed).length,
      lastSyncTime: DateTime.now(),
      successRate: getStatistics().successRate,
    );
    
    return QueueSyncMessage.createRequest(
      messageIds: messageIds,
      nodeId: nodeId,
      messageHashes: messageHashes.isNotEmpty ? messageHashes : null,
    );
  }
  
  /// Compare queue hashes to determine if synchronization is needed
  bool needsSynchronization(String otherQueueHash) {
    final currentHash = calculateQueueHash();
    return currentHash != otherQueueHash;
  }
  
  /// Get missing messages compared to another queue
  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final currentIds = _messageQueue
        .where((m) => m.status != QueuedMessageStatus.delivered &&
                     m.status != QueuedMessageStatus.failed)
        .map((m) => m.id)
        .toSet();
    
    return otherMessageIds.where((id) => !currentIds.contains(id) &&
                                        !_deletedMessageIds.contains(id)).toList();
  }
  
  /// Get excess messages that the other queue doesn't have
  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final otherIdSet = otherMessageIds.toSet();
    
    return _messageQueue
        .where((m) => m.status != QueuedMessageStatus.delivered &&
                     m.status != QueuedMessageStatus.failed &&
                     !otherIdSet.contains(m.id))
        .toList();
  }
  
  /// Mark message as deleted for sync purposes
  Future<void> markMessageDeleted(String messageId) async {
    _deletedMessageIds.add(messageId);
    await _saveDeletedMessageIds();
    
    // Remove from active queue if present
    _removeMessageFromQueue(messageId);
    await _saveQueueToStorage();
    
    _logger.info('Message marked as deleted: ${messageId.substring(0, 16)}...');
  }
  
  /// Check if message was deleted
  bool isMessageDeleted(String messageId) {
    return _deletedMessageIds.contains(messageId);
  }
  
  /// Clean up old deleted message IDs with improved performance
  Future<void> cleanupOldDeletedIds() async {
    final initialCount = _deletedMessageIds.length;
    
    // Performance-optimized cleanup based on size threshold
    if (_deletedMessageIds.length > _cleanupThreshold) {
      final deletedList = _deletedMessageIds.toList()..sort();
      _deletedMessageIds.clear();
      _deletedMessageIds.addAll(deletedList.take(_maxDeletedIdsToKeep));
      
      await _saveDeletedMessageIds();
      _logger.info('Cleaned up ${initialCount - _deletedMessageIds.length} old deleted message IDs (performance optimization)');
    }
  }
  
  /// Invalidate hash cache (call after manual queue modifications)
  void invalidateHashCache() {
    _cachedQueueHash = null;
    _lastHashCalculation = null;
  }

  /// Perform legacy data migration for backward compatibility
  Future<void> _performMigrationIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final migrationCompleted = prefs.getBool(_migrationKey) ?? false;
      
      if (!migrationCompleted) {
        _logger.info('Starting queue data migration for backward compatibility...');
        
        // Check for legacy queue data
        final legacyQueueJson = prefs.getStringList(_legacyQueueKey);
        if (legacyQueueJson != null && legacyQueueJson.isNotEmpty) {
          _logger.info('Found ${legacyQueueJson.length} messages in legacy format, migrating...');
          
          int migratedCount = 0;
          for (final json in legacyQueueJson) {
            try {
              final legacyData = jsonDecode(json) as Map<String, dynamic>;
              
              // Create new QueuedMessage with backward compatibility
              final migratedMessage = _migrateLegacyMessage(legacyData);
              if (migratedMessage != null) {
                _messageQueue.add(migratedMessage);
                migratedCount++;
              }
            } catch (e) {
              _logger.warning('Failed to migrate legacy message: $e');
            }
          }
          
          if (migratedCount > 0) {
            await _saveQueueToStorage();
            _logger.info('Successfully migrated $migratedCount messages from legacy format');
          }
          
          // Remove legacy data after successful migration
          await prefs.remove(_legacyQueueKey);
        }
        
        // Mark migration as completed
        await prefs.setBool(_migrationKey, true);
        _logger.info('Queue data migration completed');
      }
    } catch (e) {
      _logger.severe('Failed to perform queue migration: $e');
    }
  }
  
  /// Migrate legacy message format to new format
  QueuedMessage? _migrateLegacyMessage(Map<String, dynamic> legacyData) {
    try {
      // Handle potential differences in legacy format
      final id = legacyData['id'] as String?;
      final chatId = legacyData['chatId'] as String?;
      final content = legacyData['content'] as String?;
      final recipientKey = legacyData['recipientPublicKey'] as String? ?? legacyData['recipientId'] as String?;
      final senderKey = legacyData['senderPublicKey'] as String? ?? legacyData['senderId'] as String?;
      
      if (id == null || chatId == null || content == null || recipientKey == null || senderKey == null) {
        _logger.warning('Legacy message missing required fields, skipping migration');
        return null;
      }
      
      // Create new message with default values for new fields
      return QueuedMessage(
        id: id,
        chatId: chatId,
        content: content,
        recipientPublicKey: recipientKey,
        senderPublicKey: senderKey,
        priority: MessagePriority.values[legacyData['priority'] ?? 2], // Default to normal
        queuedAt: DateTime.fromMillisecondsSinceEpoch(legacyData['queuedAt'] ?? DateTime.now().millisecondsSinceEpoch),
        maxRetries: legacyData['maxRetries'] ?? _maxRetries,
        status: QueuedMessageStatus.values[legacyData['status'] ?? 0], // Default to pending
        attempts: legacyData['attempts'] ?? 0,
        // New fields get default values
        isRelayMessage: false,
        senderRateCount: 0,
      );
    } catch (e) {
      _logger.warning('Failed to migrate legacy message: $e');
      return null;
    }
  }
  
  /// Start periodic cleanup for performance optimization
  void _startPeriodicCleanup() {
    Timer.periodic(Duration(hours: 6), (timer) {
      _performPeriodicMaintenance();
    });
  }
  
  /// Perform periodic maintenance tasks
  Future<void> _performPeriodicMaintenance() async {
    try {
      _logger.info('Starting periodic queue maintenance...');
      
      // Clean up old deleted IDs
      await cleanupOldDeletedIds();
      
      // Clean up expired messages (older than 30 days)
      await _cleanupExpiredMessages();
      
      // Optimize storage if needed
      await _optimizeStorage();
      
      // Invalidate old hash cache
      if (_lastHashCalculation != null) {
        final cacheAge = DateTime.now().difference(_lastHashCalculation!);
        if (cacheAge.inHours > 1) {
          invalidateHashCache();
        }
      }
      
      _logger.info('Periodic queue maintenance completed');
    } catch (e) {
      _logger.warning('Periodic maintenance failed: $e');
    }
  }
  
  /// Clean up expired messages for performance
  Future<void> _cleanupExpiredMessages() async {
    final cutoffDate = DateTime.now().subtract(Duration(days: 30));
    final initialCount = _messageQueue.length;
    
    _messageQueue.removeWhere((message) {
      // Remove old delivered or failed messages
      if (message.status == QueuedMessageStatus.delivered || message.status == QueuedMessageStatus.failed) {
        final messageAge = message.deliveredAt ?? message.failedAt ?? message.queuedAt;
        return messageAge.isBefore(cutoffDate);
      }
      return false;
    });
    
    final removedCount = initialCount - _messageQueue.length;
    if (removedCount > 0) {
      await _saveQueueToStorage();
      _logger.info('Cleaned up $removedCount expired messages');
    }
  }
  
  /// Optimize storage by defragmenting data
  Future<void> _optimizeStorage() async {
    try {
      // Force a complete save to optimize storage structure
      await _saveQueueToStorage();
      
      // Check if we need to compact deleted IDs
      if (_deletedMessageIds.length > _maxDeletedIdsToKeep * 2) {
        await cleanupOldDeletedIds();
      }
      
      _logger.fine('Storage optimization completed');
    } catch (e) {
      _logger.warning('Storage optimization failed: $e');
    }
  }
  
  /// Get performance statistics
  Map<String, dynamic> getPerformanceStats() {
    return {
      'totalMessages': _messageQueue.length,
      'deletedIdsCount': _deletedMessageIds.length,
      'hashCacheAge': _lastHashCalculation != null
          ? DateTime.now().difference(_lastHashCalculation!).inSeconds
          : null,
      'hashCached': _cachedQueueHash != null,
      'memoryOptimized': _deletedMessageIds.length <= _maxDeletedIdsToKeep,
    };
  }

  /// Dispose of resources
  void dispose() {
    _connectivityCheckTimer?.cancel();
    _cancelAllActiveRetries();
    _logger.info('Offline message queue disposed');
  }
}

/// Queued message with delivery tracking
class QueuedMessage {
  final String id;
  final String chatId;
  final String content;
  final String recipientPublicKey;
  final String senderPublicKey;
  final MessagePriority priority;
  final DateTime queuedAt;
  final String? replyToMessageId;
  final List<String> attachments;
  final int maxRetries;
  
  // Delivery tracking
  QueuedMessageStatus status;
  int attempts;
  DateTime? lastAttemptAt;
  DateTime? nextRetryAt;
  DateTime? deliveredAt;
  DateTime? failedAt;
  String? failureReason;
  
  // Mesh relay fields (optional for backward compatibility)
  /// Indicates if this is a relay message
  final bool isRelayMessage;
  
  /// Relay metadata for mesh routing (only present for relay messages)
  final RelayMetadata? relayMetadata;
  
  /// Original message ID (for relay messages, different from relay wrapper ID)
  final String? originalMessageId;
  
  /// Node that created this relay (current relay node's public key)
  final String? relayNodeId;
  
  /// Message hash for deduplication across the mesh
  final String? messageHash;
  
  /// Rate limiting: sender's message count in current time window
  final int senderRateCount;
  
  QueuedMessage({
    required this.id,
    required this.chatId,
    required this.content,
    required this.recipientPublicKey,
    required this.senderPublicKey,
    required this.priority,
    required this.queuedAt,
    required this.maxRetries,
    this.replyToMessageId,
    this.attachments = const [],
    this.status = QueuedMessageStatus.pending,
    this.attempts = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.deliveredAt,
    this.failedAt,
    this.failureReason,
    // Relay-specific fields
    this.isRelayMessage = false,
    this.relayMetadata,
    this.originalMessageId,
    this.relayNodeId,
    this.messageHash,
    this.senderRateCount = 0,
  });
  
  /// Create a relay message from a MeshRelayMessage
  factory QueuedMessage.fromRelayMessage({
    required MeshRelayMessage relayMessage,
    required String chatId,
    required int maxRetries,
    QueuedMessageStatus status = QueuedMessageStatus.pending,
  }) {
    return QueuedMessage(
      id: '${relayMessage.originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: relayMessage.originalContent,
      recipientPublicKey: relayMessage.relayMetadata.finalRecipient,
      senderPublicKey: relayMessage.relayMetadata.originalSender,
      priority: relayMessage.relayMetadata.priority,
      queuedAt: relayMessage.relayedAt,
      maxRetries: maxRetries,
      status: status,
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: relayMessage.relayMetadata,
      originalMessageId: relayMessage.originalMessageId,
      relayNodeId: relayMessage.relayNodeId,
      messageHash: relayMessage.relayMetadata.messageHash,
      senderRateCount: relayMessage.relayMetadata.senderRateCount,
    );
  }
  
  /// Check if message can be relayed further
  bool get canRelay => isRelayMessage && relayMetadata != null && relayMetadata!.canRelay;
  
  /// Get relay hop count
  int get relayHopCount => relayMetadata?.hopCount ?? 0;
  
  /// Check if this message has exceeded TTL
  bool get hasExceededTTL => relayMetadata != null && relayMetadata!.hopCount >= relayMetadata!.ttl;
  
  /// Create next hop relay message
  QueuedMessage createNextHopRelay(String nextRelayNodeId) {
    if (!canRelay || relayMetadata == null) {
      throw RelayException('Cannot create next hop: message cannot be relayed');
    }
    
    final nextMetadata = relayMetadata!.nextHop(nextRelayNodeId);
    
    return QueuedMessage(
      id: '${originalMessageId}_relay_${DateTime.now().millisecondsSinceEpoch}',
      chatId: chatId,
      content: content,
      recipientPublicKey: recipientPublicKey,
      senderPublicKey: senderPublicKey,
      priority: priority,
      queuedAt: DateTime.now(),
      maxRetries: maxRetries,
      replyToMessageId: replyToMessageId,
      attachments: attachments,
      // Relay-specific fields
      isRelayMessage: true,
      relayMetadata: nextMetadata,
      originalMessageId: originalMessageId,
      relayNodeId: nextRelayNodeId,
      messageHash: messageHash,
      senderRateCount: senderRateCount,
    );
  }
  
  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'id': id,
    'chatId': chatId,
    'content': content,
    'recipientPublicKey': recipientPublicKey,
    'senderPublicKey': senderPublicKey,
    'priority': priority.index,
    'queuedAt': queuedAt.millisecondsSinceEpoch,
    'maxRetries': maxRetries,
    'replyToMessageId': replyToMessageId,
    'attachments': attachments,
    'status': status.index,
    'attempts': attempts,
    'lastAttemptAt': lastAttemptAt?.millisecondsSinceEpoch,
    'nextRetryAt': nextRetryAt?.millisecondsSinceEpoch,
    'deliveredAt': deliveredAt?.millisecondsSinceEpoch,
    'failedAt': failedAt?.millisecondsSinceEpoch,
    'failureReason': failureReason,
    // Relay-specific fields (for backward compatibility, only include if present)
    'isRelayMessage': isRelayMessage,
    if (relayMetadata != null) 'relayMetadata': relayMetadata!.toJson(),
    if (originalMessageId != null) 'originalMessageId': originalMessageId,
    if (relayNodeId != null) 'relayNodeId': relayNodeId,
    if (messageHash != null) 'messageHash': messageHash,
    'senderRateCount': senderRateCount,
  };
  
  /// Create from JSON
  factory QueuedMessage.fromJson(Map<String, dynamic> json) => QueuedMessage(
    id: json['id'],
    chatId: json['chatId'],
    content: json['content'],
    recipientPublicKey: json['recipientPublicKey'],
    senderPublicKey: json['senderPublicKey'],
    priority: MessagePriority.values[json['priority']],
    queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAt']),
    maxRetries: json['maxRetries'],
    replyToMessageId: json['replyToMessageId'],
    attachments: List<String>.from(json['attachments'] ?? []),
    status: QueuedMessageStatus.values[json['status']],
    attempts: json['attempts'] ?? 0,
    lastAttemptAt: json['lastAttemptAt'] != null
      ? DateTime.fromMillisecondsSinceEpoch(json['lastAttemptAt'])
      : null,
    nextRetryAt: json['nextRetryAt'] != null
      ? DateTime.fromMillisecondsSinceEpoch(json['nextRetryAt'])
      : null,
    deliveredAt: json['deliveredAt'] != null
      ? DateTime.fromMillisecondsSinceEpoch(json['deliveredAt'])
      : null,
    failedAt: json['failedAt'] != null
      ? DateTime.fromMillisecondsSinceEpoch(json['failedAt'])
      : null,
    failureReason: json['failureReason'],
    // Relay-specific fields (backward compatible - default to false/null if not present)
    isRelayMessage: json['isRelayMessage'] ?? false,
    relayMetadata: json['relayMetadata'] != null
      ? RelayMetadata.fromJson(json['relayMetadata'])
      : null,
    originalMessageId: json['originalMessageId'],
    relayNodeId: json['relayNodeId'],
    messageHash: json['messageHash'],
    senderRateCount: json['senderRateCount'] ?? 0,
  );
}

/// Queue message status
enum QueuedMessageStatus {
  pending,
  sending,
  retrying,
  delivered,
  failed,
}

/// Queue statistics
class QueueStatistics {
  final int totalQueued;
  final int totalDelivered;
  final int totalFailed;
  final int pendingMessages;
  final int sendingMessages;
  final int retryingMessages;
  final int failedMessages;
  final bool isOnline;
  final QueuedMessage? oldestPendingMessage;
  final Duration averageDeliveryTime;
  
  const QueueStatistics({
    required this.totalQueued,
    required this.totalDelivered,
    required this.totalFailed,
    required this.pendingMessages,
    required this.sendingMessages,
    required this.retryingMessages,
    required this.failedMessages,
    required this.isOnline,
    this.oldestPendingMessage,
    required this.averageDeliveryTime,
  });
  
  /// Get delivery success rate
  double get successRate {
    final totalAttempted = totalDelivered + totalFailed;
    return totalAttempted > 0 ? totalDelivered / totalAttempted : 0.0;
  }
  
  /// Get queue health score (0.0 - 1.0)
  double get queueHealthScore {
    final totalActive = pendingMessages + sendingMessages + retryingMessages;
    final healthFactors = [
      successRate, // Delivery success rate
      isOnline ? 1.0 : 0.5, // Connection status
      totalActive < 10 ? 1.0 : (10 / totalActive), // Queue congestion
      failedMessages < 5 ? 1.0 : (5 / failedMessages), // Failed message ratio
    ];
    
    return healthFactors.reduce((a, b) => a + b) / healthFactors.length;
  }
  
  @override
  String toString() => 'QueueStats(pending: $pendingMessages, success: ${(successRate * 100).toStringAsFixed(1)}%, health: ${(queueHealthScore * 100).toStringAsFixed(1)}%)';
}

/// Exception for queue operations
class MessageQueueException implements Exception {
  final String message;
  const MessageQueueException(this.message);
  
  @override
  String toString() => 'MessageQueueException: $message';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}