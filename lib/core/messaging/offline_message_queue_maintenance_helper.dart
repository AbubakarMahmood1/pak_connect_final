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
    _owner._notifyObserver(
      'onStatsUpdated',
      () => _owner.onStatsUpdated?.call(stats),
    );
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
    var ttlExpiredCount = 0;
    var oldMessagesCount = 0;
    final expiredIds = <String>{};

    await _owner._mutationLock.synchronized(() async {
      if (_owner._disposed) return;
      for (final message in _owner._getAllMessages()) {
        if ((message.status == QueuedMessageStatus.pending ||
                message.status == QueuedMessageStatus.retrying) &&
            _owner._isMessageExpired(message)) {
          ttlExpiredCount++;
          expiredIds.add(message.id);
          continue;
        }

        if (message.status == QueuedMessageStatus.delivered ||
            message.status == QueuedMessageStatus.failed) {
          final messageAge =
              message.deliveredAt ?? message.failedAt ?? message.queuedAt;
          if (messageAge.isBefore(cutoffDate)) {
            oldMessagesCount++;
            expiredIds.add(message.id);
          }
        }
      }

      if (expiredIds.isEmpty) return;
      // Expiration is a deletion from the synchronized queue, not merely local
      // compaction. Commit tombstones with the row removals so a peer cannot
      // reintroduce the same expired payload during a later gossip round.
      await _owner._store.markMessagesDeleted(expiredIds);
      _owner._deletedMessageIds.addAll(expiredIds.map(MessageId.new));
      for (final id in expiredIds) {
        _owner._deliveryInFlightIds.remove(id);
        _owner._queueScheduler.cancelRetryTimer(id);
        _owner._cancelStaggerTimer(id);
        _owner._store.removeMessageFromQueue(id);
      }
      _owner.invalidateHashCache();
    });

    if (expiredIds.isNotEmpty) {
      OfflineMessageQueue._logger.info(
        'Cleaned up ${expiredIds.length} expired messages '
        '(TTL: $ttlExpiredCount, Old: $oldMessagesCount)',
      );
    }
  }

  Future<void> optimizeStorage() async {
    try {
      // Snapshot rewrites race admissions and provide no compaction benefit.
      // Keep optimization targeted to the timestamp-aware tombstone pruner.
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
    final messages = _owner._getAllMessages();
    final directCount = messages
        .where((message) => !message.isRelayMessage)
        .length;
    return {
      'totalMessages': messages.length,
      'directMessages': directCount,
      'relayMessages': messages.length - directCount,
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
