part of 'offline_message_queue.dart';

class _OfflineMessageQueueMaintenanceHelper {
  _OfflineMessageQueueMaintenanceHelper(this._owner);

  final OfflineMessageQueue _owner;

  void startConnectivityMonitoring() {
    _owner._queueScheduler.startConnectivityMonitoring(
      onConnectivityCheck: () {
        _owner.onConnectivityCheck?.call();
      },
    );
  }

  void cancelAllActiveRetries() {
    _owner._queueScheduler.cancelAllRetryTimers();
  }

  void cancelRetryTimer(MessageId messageId) {
    _owner._queueScheduler.cancelRetryTimer(messageId.value);
  }

  Duration calculateAverageDeliveryTime() {
    // PRIORITY 1 FIX: Calculate across both queues
    final deliveredMessages = _owner
        ._getAllMessages()
        .where(
          (m) =>
              m.status == QueuedMessageStatus.delivered &&
              m.deliveredAt != null,
        )
        .toList();

    if (deliveredMessages.isEmpty) return Duration.zero;

    final totalTime = deliveredMessages
        .map((m) => m.deliveredAt!.difference(m.queuedAt))
        .fold<Duration>(Duration.zero, (sum, duration) => sum + duration);

    return Duration(
      milliseconds: totalTime.inMilliseconds ~/ deliveredMessages.length,
    );
  }

  void updateStatistics() {
    final stats = _owner.getStatistics();
    _owner.onStatsUpdated?.call(stats);
  }

  Future<void> saveMessageToStorage(QueuedMessage message) async {
    await _owner._store.saveMessageToStorage(message);
    _owner.invalidateHashCache();
  }

  Future<void> deleteMessageFromStorage(String messageId) async {
    await _owner._store.deleteMessageFromStorage(messageId);
    _owner.invalidateHashCache();
  }

  Future<void> saveQueueToStorage() async {
    await _owner._store.saveQueueToStorage();
    _owner.invalidateHashCache();
  }

  void startPeriodicCleanup() {
    _owner._queueScheduler.startPeriodicCleanup(
      onPeriodicMaintenance: _owner._performPeriodicMaintenance,
    );
  }

  Future<void> performPeriodicMaintenance() async {
    final startedAt = DateTime.now();
    try {
      OfflineMessageQueue._logger.info(
        AppLogger.event(type: 'offline_queue_maintenance_started'),
      );

      // Clean up old deleted IDs
      await _owner.cleanupOldDeletedIds();

      // Clean up expired messages (older than 30 days)
      await cleanupExpiredMessages();

      // Optimize storage if needed
      await optimizeStorage();

      // Invalidate old hash cache
      final lastHashTime = _owner._queueSync.getSyncStatistics().lastHashTime;
      if (lastHashTime != null) {
        final cacheAge = DateTime.now().difference(lastHashTime);
        if (cacheAge.inHours > 1) {
          _owner.invalidateHashCache();
        }
      }

      OfflineMessageQueue._logger.info(
        AppLogger.event(
          type: 'offline_queue_maintenance_completed',
          duration: DateTime.now().difference(startedAt),
        ),
      );
    } catch (e) {
      OfflineMessageQueue._logger.warning(
        AppLogger.event(
          type: 'offline_queue_maintenance_failed',
          duration: DateTime.now().difference(startedAt),
          fields: {'error': e},
        ),
      );
    }
  }

  Future<void> cleanupExpiredMessages() async {
    final cutoffDate = DateTime.now().subtract(const Duration(days: 30));
    int ttlExpiredCount = 0;
    int oldMessagesCount = 0;

    final expiredIds = <String>[];

    // PRIORITY 1 FIX: Clean both queues
    _owner._directMessageQueue.removeWhere((message) {
      // Remove messages that have exceeded their TTL
      if (message.status == QueuedMessageStatus.pending ||
          message.status == QueuedMessageStatus.retrying) {
        if (_owner._isMessageExpired(message)) {
          ttlExpiredCount++;
          expiredIds.add(message.id);
          OfflineMessageQueue._logger.info(
            'Message ${message.id.shortId()}... expired (TTL exceeded)',
          );
          return true;
        }
      }

      // Remove old delivered or failed messages
      if (message.status == QueuedMessageStatus.delivered ||
          message.status == QueuedMessageStatus.failed) {
        final messageAge =
            message.deliveredAt ?? message.failedAt ?? message.queuedAt;
        if (messageAge.isBefore(cutoffDate)) {
          oldMessagesCount++;
          expiredIds.add(message.id);
          return true;
        }
      }
      return false;
    });

    _owner._relayMessageQueue.removeWhere((message) {
      // Remove messages that have exceeded their TTL
      if (message.status == QueuedMessageStatus.pending ||
          message.status == QueuedMessageStatus.retrying) {
        if (_owner._isMessageExpired(message)) {
          ttlExpiredCount++;
          expiredIds.add(message.id);
          OfflineMessageQueue._logger.info(
            'Message ${message.id.shortId()}... expired (TTL exceeded)',
          );
          return true;
        }
      }

      // Remove old delivered or failed messages
      if (message.status == QueuedMessageStatus.delivered ||
          message.status == QueuedMessageStatus.failed) {
        final messageAge =
            message.deliveredAt ?? message.failedAt ?? message.queuedAt;
        if (messageAge.isBefore(cutoffDate)) {
          oldMessagesCount++;
          expiredIds.add(message.id);
          return true;
        }
      }
      return false;
    });

    // Persist removal to storage
    if (expiredIds.isNotEmpty) {
      await saveQueueToStorage();

      OfflineMessageQueue._logger.info(
        'Cleaned up ${expiredIds.length} expired messages '
        '(TTL: $ttlExpiredCount, Old: $oldMessagesCount)',
      );
    }
  }

  Future<void> optimizeStorage() async {
    try {
      // Force a complete save to optimize storage structure
      await saveQueueToStorage();

      // Check if we need to compact deleted IDs
      if (_owner._deletedMessageIds.length >
          OfflineMessageQueue._maxDeletedIdsToKeep * 2) {
        await _owner.cleanupOldDeletedIds();
      }

      OfflineMessageQueue._logger.fine('Storage optimization completed');
    } catch (e) {
      OfflineMessageQueue._logger.warning('Storage optimization failed: $e');
    }
  }

  Map<String, dynamic> getPerformanceStats() {
    final syncStats = _owner._queueSync.getSyncStatistics();
    // PRIORITY 1 FIX: Include both queue stats
    return {
      'totalMessages':
          _owner._directMessageQueue.length + _owner._relayMessageQueue.length,
      'directMessages': _owner._directMessageQueue.length,
      'relayMessages': _owner._relayMessageQueue.length,
      'deletedIdsCount': _owner._deletedMessageIds.length,
      'hashCacheAge': syncStats.lastHashTime != null
          ? DateTime.now().difference(syncStats.lastHashTime!).inSeconds
          : null,
      'hashCached': syncStats.isCachValid,
      'memoryOptimized':
          _owner._deletedMessageIds.length <=
          OfflineMessageQueue._maxDeletedIdsToKeep,
    };
  }

  void dispose() {
    _owner._queueScheduler.dispose();
    OfflineMessageQueue._logger.info('Offline message queue disposed');
  }
}
