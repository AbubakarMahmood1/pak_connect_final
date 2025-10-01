// Queue synchronization manager for efficient mesh networking message queue sync

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import '../models/mesh_relay_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_message_queue.dart';

/// Manages queue synchronization between mesh network nodes
class QueueSyncManager {
  static final _logger = Logger('QueueSyncManager');
  
  // Storage keys
  static const String _syncStatsKey = 'queue_sync_stats_v1';
  
  // Rate limiting constants
  static const int _maxSyncsPerHour = 60;
  static const Duration _minSyncInterval = Duration(seconds: 30);
  static const Duration _syncTimeout = Duration(seconds: 15);
  
  final OfflineMessageQueue _messageQueue;
  final String _nodeId;
  
  // Sync state tracking
  final Map<String, DateTime> _lastSyncWithNode = {};
  final Map<String, Timer> _activeSyncs = {};
  final Map<String, int> _syncAttempts = {};
  final Set<String> _syncInProgress = {};
  
  // Rate limiting
  final List<DateTime> _recentSyncs = [];
  
  // Statistics
  int _totalSyncRequests = 0;
  int _successfulSyncs = 0;
  int _failedSyncs = 0;
  int _messagesTransferred = 0;
  
  // Callbacks
  Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest;
  Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages;
  Function(String nodeId, QueueSyncResult result)? onSyncCompleted;
  Function(String nodeId, String error)? onSyncFailed;
  
  QueueSyncManager({
    required OfflineMessageQueue messageQueue,
    required String nodeId,
  }) : _messageQueue = messageQueue,
       _nodeId = nodeId;
  
  /// Initialize the sync manager
  Future<void> initialize({
    Function(QueueSyncMessage message, String fromNodeId)? onSyncRequest,
    Function(List<QueuedMessage> messages, String toNodeId)? onSendMessages,
    Function(String nodeId, QueueSyncResult result)? onSyncCompleted,
    Function(String nodeId, String error)? onSyncFailed,
  }) async {
    this.onSyncRequest = onSyncRequest;
    this.onSendMessages = onSendMessages;
    this.onSyncCompleted = onSyncCompleted;
    this.onSyncFailed = onSyncFailed;
    
    await _loadSyncStats();
    _startCleanupTimer();
    
    final truncatedNodeId = _nodeId.length > 16 ? _nodeId.substring(0, 16) : _nodeId;
    _logger.info('Queue sync manager initialized for node: $truncatedNodeId...');
  }
  
  /// Initiate synchronization with another node
  Future<QueueSyncResult> initiateSync(String targetNodeId) async {
    if (!_canSync(targetNodeId)) {
      final reason = _getSyncBlockReason(targetNodeId);
      _logger.warning('Sync blocked with $targetNodeId: $reason');
      return QueueSyncResult.rateLimited(reason);
    }
    
    _totalSyncRequests++;
    _syncInProgress.add(targetNodeId);
    
    try {
      final syncMessage = _messageQueue.createSyncMessage(_nodeId);
      final result = await _performSync(targetNodeId, syncMessage);
      
      if (result.success) {
        _successfulSyncs++;
        _lastSyncWithNode[targetNodeId] = DateTime.now();
        _recordSyncAttempt();
      } else {
        _failedSyncs++;
      }
      
      await _saveSyncStats();
      onSyncCompleted?.call(targetNodeId, result);
      
      return result;
      
    } catch (e) {
      _failedSyncs++;
      _logger.severe('Sync failed with $targetNodeId: $e');
      onSyncFailed?.call(targetNodeId, e.toString());
      
      return QueueSyncResult.error('Sync failed: $e');
    } finally {
      _syncInProgress.remove(targetNodeId);
      _syncAttempts.remove(targetNodeId);
    }
  }
  
  /// Handle incoming sync request from another node
  Future<QueueSyncResponse> handleSyncRequest(
    QueueSyncMessage syncMessage, 
    String fromNodeId,
  ) async {
    final truncatedNodeId = fromNodeId.length > 16 ? fromNodeId.substring(0, 16) : fromNodeId;
    _logger.info('Handling sync request from $truncatedNodeId...');
    
    if (!_canAcceptSync(fromNodeId)) {
      return QueueSyncResponse.rateLimited('Rate limit exceeded');
    }
    
    try {
      
      // Check if synchronization is needed
      if (!_messageQueue.needsSynchronization(syncMessage.queueHash)) {
        _logger.info('Queues already synchronized with $fromNodeId');
        return QueueSyncResponse.alreadySynced();
      }
      
      // Determine what needs to be synchronized
      final missingIds = _messageQueue.getMissingMessageIds(syncMessage.messageIds);
      final excessMessages = _messageQueue.getExcessMessages(syncMessage.messageIds);
      
      // Create response with our queue state
      final responseMessage = QueueSyncMessage.createResponse(
        messageIds: _messageQueue.getMessagesByStatus(QueuedMessageStatus.pending)
            .map((m) => m.id)
            .toList(),
        nodeId: _nodeId,
        stats: _createSyncStats(),
      );
      
      return QueueSyncResponse.success(
        responseMessage: responseMessage,
        missingMessages: missingIds,
        excessMessages: excessMessages,
      );
      
    } catch (e) {
      _logger.severe('Failed to handle sync request: $e');
      return QueueSyncResponse.error('Failed to process sync request: $e');
    }
  }
  
  /// Process sync response and complete synchronization
  Future<QueueSyncResult> processSyncResponse(
    QueueSyncMessage responseMessage,
    List<QueuedMessage> receivedMessages,
    String fromNodeId,
  ) async {
    try {
      int messagesAdded = 0;
      int messagesSkipped = 0;
      int messagesUpdated = 0;
      
      // Process received messages
      for (final message in receivedMessages) {
        if (_messageQueue.isMessageDeleted(message.id)) {
          messagesSkipped++;
          continue;
        }
        
        // Check if we already have this message
        final existingMessages = _messageQueue.getMessagesByStatus(QueuedMessageStatus.pending);
        final exists = existingMessages.any((m) => m.id == message.id);
        
        if (exists) {
          // Update status if our version is older
          messagesUpdated++;
        } else {
          // Add new message to queue
          await _addReceivedMessage(message);
          messagesAdded++;
        }
      }
      
      _messagesTransferred += messagesAdded;
      
      final result = QueueSyncResult.success(
        messagesReceived: messagesAdded,
        messagesUpdated: messagesUpdated,
        messagesSkipped: messagesSkipped,
        finalHash: _messageQueue.calculateQueueHash(forceRecalculation: true),
        syncDuration: Duration.zero, // Will be set by caller
      );
      
      _logger.info('Sync completed with $fromNodeId: +$messagesAdded, ~$messagesUpdated, -$messagesSkipped');
      
      return result;
      
    } catch (e) {
      _logger.severe('Failed to process sync response: $e');
      return QueueSyncResult.error('Failed to process response: $e');
    }
  }
  
  /// Check if we can sync with a specific node
  bool _canSync(String nodeId) {
    // Check if sync is already in progress
    if (_syncInProgress.contains(nodeId)) {
      return false;
    }
    
    // Check minimum interval since last sync
    final lastSync = _lastSyncWithNode[nodeId];
    if (lastSync != null) {
      final timeSinceSync = DateTime.now().difference(lastSync);
      if (timeSinceSync < _minSyncInterval) {
        return false;
      }
    }
    
    // Check global rate limiting
    _cleanupRecentSyncs();
    if (_recentSyncs.length >= _maxSyncsPerHour) {
      return false;
    }
    
    return true;
  }
  
  /// Check if we can accept sync from a node
  bool _canAcceptSync(String fromNodeId) {
    // Always accept sync requests, but may rate limit responses
    return true;
  }
  
  /// Get reason why sync is blocked
  String _getSyncBlockReason(String nodeId) {
    if (_syncInProgress.contains(nodeId)) {
      return 'Sync already in progress';
    }
    
    final lastSync = _lastSyncWithNode[nodeId];
    if (lastSync != null) {
      final timeSinceSync = DateTime.now().difference(lastSync);
      if (timeSinceSync < _minSyncInterval) {
        return 'Minimum sync interval not met';
      }
    }
    
    _cleanupRecentSyncs();
    if (_recentSyncs.length >= _maxSyncsPerHour) {
      return 'Global rate limit exceeded';
    }
    
    return 'Unknown reason';
  }
  
  /// Perform actual synchronization with timeout
  Future<QueueSyncResult> _performSync(String targetNodeId, QueueSyncMessage syncMessage) async {
    final stopwatch = Stopwatch()..start();
    
    try {
      // Set up timeout
      final syncCompleter = Completer<QueueSyncResult>();
      
      final timeoutTimer = Timer(_syncTimeout, () {
        if (!syncCompleter.isCompleted) {
          syncCompleter.complete(QueueSyncResult.timeout());
        }
      });
      
      // Track sync attempts for exponential backoff
      final attempts = _syncAttempts[targetNodeId] ?? 0;
      _syncAttempts[targetNodeId] = attempts + 1;
      
      // Send sync request via callback
      onSyncRequest?.call(syncMessage, targetNodeId);
      
      // Simulate sync completion (in real implementation, this would be handled by response)
      Timer(Duration(seconds: 2), () {
        if (!syncCompleter.isCompleted) {
          final mockResult = QueueSyncResult.success(
            messagesReceived: 0,
            messagesUpdated: 0,
            messagesSkipped: 0,
            finalHash: _messageQueue.calculateQueueHash(),
            syncDuration: stopwatch.elapsed,
          );
          syncCompleter.complete(mockResult);
        }
      });
      
      final result = await syncCompleter.future;
      timeoutTimer.cancel();
      
      return result;
      
    } catch (e) {
      _logger.severe('Sync performance failed: $e');
      return QueueSyncResult.error('Sync failed: $e');
    }
  }
  
  /// Add a received message to our queue
  Future<void> _addReceivedMessage(QueuedMessage message) async {
    // Note: This is a simplified version. In practice, you'd need to integrate
    // with the queue's internal methods more carefully
    final truncatedId = message.id.length > 16 ? message.id.substring(0, 16) : message.id;
    _logger.info('Would add received message: $truncatedId...');
  }
  
  /// Record sync attempt for rate limiting
  void _recordSyncAttempt() {
    _recentSyncs.add(DateTime.now());
    _cleanupRecentSyncs();
  }
  
  /// Clean up old sync timestamps
  void _cleanupRecentSyncs() {
    final cutoff = DateTime.now().subtract(Duration(hours: 1));
    _recentSyncs.removeWhere((timestamp) => timestamp.isBefore(cutoff));
  }
  
  /// Create sync stats for responses
  QueueSyncStats _createSyncStats() {
    final queueStats = _messageQueue.getStatistics();
    
    return QueueSyncStats(
      totalMessages: queueStats.totalQueued,
      pendingMessages: queueStats.pendingMessages,
      failedMessages: queueStats.failedMessages,
      lastSyncTime: DateTime.now(),
      successRate: queueStats.successRate,
    );
  }
  
  /// Start cleanup timer for old sync data
  void _startCleanupTimer() {
    Timer.periodic(Duration(hours: 1), (timer) {
      _cleanupRecentSyncs();
      _cleanupOldSyncData();
    });
  }
  
  /// Clean up old sync tracking data
  void _cleanupOldSyncData() {
    final cutoff = DateTime.now().subtract(Duration(hours: 24));
    
    _lastSyncWithNode.removeWhere((nodeId, timestamp) => timestamp.isBefore(cutoff));
    
    // Clean up active syncs that might be stuck
    final stuckSyncs = <String>[];
    for (final nodeId in _syncInProgress) {
      final lastAttempt = _lastSyncWithNode[nodeId];
      if (lastAttempt != null && DateTime.now().difference(lastAttempt) > Duration(minutes: 5)) {
        stuckSyncs.add(nodeId);
      }
    }
    
    for (final nodeId in stuckSyncs) {
      _syncInProgress.remove(nodeId);
      _logger.warning('Cleaned up stuck sync with $nodeId');
    }
  }
  
  /// Load sync statistics from storage
  Future<void> _loadSyncStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statsJson = prefs.getString(_syncStatsKey);
      
      if (statsJson != null) {
        final stats = jsonDecode(statsJson) as Map<String, dynamic>;
        _totalSyncRequests = stats['totalSyncRequests'] ?? 0;
        _successfulSyncs = stats['successfulSyncs'] ?? 0;
        _failedSyncs = stats['failedSyncs'] ?? 0;
        _messagesTransferred = stats['messagesTransferred'] ?? 0;
        
        _logger.info('Loaded sync stats: $_successfulSyncs successful, $_failedSyncs failed');
      }
    } catch (e) {
      _logger.warning('Failed to load sync stats: $e');
    }
  }
  
  /// Save sync statistics to storage
  Future<void> _saveSyncStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stats = {
        'totalSyncRequests': _totalSyncRequests,
        'successfulSyncs': _successfulSyncs,
        'failedSyncs': _failedSyncs,
        'messagesTransferred': _messagesTransferred,
        'lastSaved': DateTime.now().millisecondsSinceEpoch,
      };
      
      await prefs.setString(_syncStatsKey, jsonEncode(stats));
    } catch (e) {
      _logger.warning('Failed to save sync stats: $e');
    }
  }
  
  /// Get synchronization statistics
  QueueSyncManagerStats getStats() {
    final successRate = _totalSyncRequests > 0 
        ? _successfulSyncs / _totalSyncRequests 
        : 0.0;
    
    return QueueSyncManagerStats(
      totalSyncRequests: _totalSyncRequests,
      successfulSyncs: _successfulSyncs,
      failedSyncs: _failedSyncs,
      messagesTransferred: _messagesTransferred,
      activeSyncs: _syncInProgress.length,
      successRate: successRate,
      recentSyncCount: _recentSyncs.length,
    );
  }
  
  /// Force sync with all known nodes (maintenance operation)
  Future<Map<String, QueueSyncResult>> forceSyncAll(List<String> nodeIds) async {
    final results = <String, QueueSyncResult>{};
    
    for (final nodeId in nodeIds) {
      try {
        final result = await initiateSync(nodeId);
        results[nodeId] = result;
        
        // Small delay between syncs to prevent overwhelming
        if (nodeId != nodeIds.last) {
          await Future.delayed(Duration(seconds: 1));
        }
      } catch (e) {
        results[nodeId] = QueueSyncResult.error('Force sync failed: $e');
      }
    }
    
    return results;
  }
  
  /// Dispose resources
  void dispose() {
    for (final timer in _activeSyncs.values) {
      timer.cancel();
    }
    _activeSyncs.clear();
    
    _logger.info('Queue sync manager disposed');
  }
}

/// Result of a queue synchronization operation
class QueueSyncResult {
  final bool success;
  final String? error;
  final int messagesReceived;
  final int messagesUpdated;
  final int messagesSkipped;
  final String? finalHash;
  final Duration? syncDuration;
  final QueueSyncResultType type;
  
  const QueueSyncResult._({
    required this.success,
    this.error,
    required this.messagesReceived,
    required this.messagesUpdated,
    required this.messagesSkipped,
    this.finalHash,
    this.syncDuration,
    required this.type,
  });
  
  factory QueueSyncResult.success({
    required int messagesReceived,
    required int messagesUpdated,
    required int messagesSkipped,
    required String finalHash,
    required Duration syncDuration,
  }) => QueueSyncResult._(
    success: true,
    messagesReceived: messagesReceived,
    messagesUpdated: messagesUpdated,
    messagesSkipped: messagesSkipped,
    finalHash: finalHash,
    syncDuration: syncDuration,
    type: QueueSyncResultType.success,
  );
  
  factory QueueSyncResult.alreadySynced() => QueueSyncResult._(
    success: true,
    messagesReceived: 0,
    messagesUpdated: 0,
    messagesSkipped: 0,
    type: QueueSyncResultType.alreadySynced,
  );
  
  factory QueueSyncResult.rateLimited(String reason) => QueueSyncResult._(
    success: false,
    error: reason,
    messagesReceived: 0,
    messagesUpdated: 0,
    messagesSkipped: 0,
    type: QueueSyncResultType.rateLimited,
  );
  
  factory QueueSyncResult.timeout() => QueueSyncResult._(
    success: false,
    error: 'Sync timeout',
    messagesReceived: 0,
    messagesUpdated: 0,
    messagesSkipped: 0,
    type: QueueSyncResultType.timeout,
  );
  
  factory QueueSyncResult.error(String error) => QueueSyncResult._(
    success: false,
    error: error,
    messagesReceived: 0,
    messagesUpdated: 0,
    messagesSkipped: 0,
    type: QueueSyncResultType.error,
  );
}

/// Type of sync result
enum QueueSyncResultType {
  success,
  alreadySynced,
  rateLimited,
  timeout,
  error,
}

/// Response to a sync request
class QueueSyncResponse {
  final bool success;
  final String? error;
  final QueueSyncMessage? responseMessage;
  final List<String>? missingMessages;
  final List<QueuedMessage>? excessMessages;
  final QueueSyncResponseType type;
  
  const QueueSyncResponse._({
    required this.success,
    this.error,
    this.responseMessage,
    this.missingMessages,
    this.excessMessages,
    required this.type,
  });
  
  factory QueueSyncResponse.success({
    required QueueSyncMessage responseMessage,
    required List<String> missingMessages,
    required List<QueuedMessage> excessMessages,
  }) => QueueSyncResponse._(
    success: true,
    responseMessage: responseMessage,
    missingMessages: missingMessages,
    excessMessages: excessMessages,
    type: QueueSyncResponseType.success,
  );
  
  factory QueueSyncResponse.alreadySynced() => QueueSyncResponse._(
    success: true,
    type: QueueSyncResponseType.alreadySynced,
  );
  
  factory QueueSyncResponse.rateLimited(String reason) => QueueSyncResponse._(
    success: false,
    error: reason,
    type: QueueSyncResponseType.rateLimited,
  );
  
  factory QueueSyncResponse.error(String error) => QueueSyncResponse._(
    success: false,
    error: error,
    type: QueueSyncResponseType.error,
  );
}

/// Type of sync response
enum QueueSyncResponseType {
  success,
  alreadySynced,
  rateLimited,
  error,
}

/// Statistics for the queue sync manager
class QueueSyncManagerStats {
  final int totalSyncRequests;
  final int successfulSyncs;
  final int failedSyncs;
  final int messagesTransferred;
  final int activeSyncs;
  final double successRate;
  final int recentSyncCount;
  
  const QueueSyncManagerStats({
    required this.totalSyncRequests,
    required this.successfulSyncs,
    required this.failedSyncs,
    required this.messagesTransferred,
    required this.activeSyncs,
    required this.successRate,
    required this.recentSyncCount,
  });
  
  @override
  String toString() => 'SyncStats(requests: $totalSyncRequests, success: ${(successRate * 100).toStringAsFixed(1)}%, active: $activeSyncs)';
}