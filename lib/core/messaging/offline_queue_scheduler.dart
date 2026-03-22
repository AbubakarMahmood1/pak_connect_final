import 'dart:async';

import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';

import '../services/retry_scheduler.dart';

class QueueScheduler {
  QueueScheduler({IRetryScheduler? retryScheduler})
    : _retryScheduler = retryScheduler;

  IRetryScheduler? _retryScheduler;
  Timer? _maintenanceHeartbeatTimer;
  Duration? _connectivityCheckInterval;
  Duration? _periodicCleanupInterval;
  DateTime? _lastConnectivityCheckAt;
  DateTime? _lastPeriodicCleanupAt;
  void Function()? _onConnectivityCheck;
  Future<void> Function()? _onPeriodicMaintenance;
  bool _isPeriodicMaintenanceRunning = false;

  IRetryScheduler get scheduler {
    _retryScheduler ??= RetryScheduler();
    return _retryScheduler!;
  }

  void startConnectivityMonitoring({
    required void Function() onConnectivityCheck,
    Duration interval = const Duration(seconds: 30),
  }) {
    _onConnectivityCheck = onConnectivityCheck;
    _connectivityCheckInterval = interval;
    _lastConnectivityCheckAt = DateTime.now();
    _refreshMaintenanceHeartbeat();
  }

  void startPeriodicCleanup({
    required Future<void> Function() onPeriodicMaintenance,
    Duration interval = const Duration(hours: 6),
  }) {
    _onPeriodicMaintenance = onPeriodicMaintenance;
    _periodicCleanupInterval = interval;
    _lastPeriodicCleanupAt = DateTime.now();
    _refreshMaintenanceHeartbeat();
  }

  Duration calculateBackoffDelay(int attempt) {
    return scheduler.calculateBackoffDelay(attempt);
  }

  int getMaxRetriesForPriority(MessagePriority priority, int baseMaxRetries) {
    return scheduler.getMaxRetriesForPriority(priority, baseMaxRetries);
  }

  DateTime calculateExpiryTime(DateTime queuedAt, MessagePriority priority) {
    return scheduler.calculateExpiryTime(queuedAt, priority);
  }

  bool isMessageExpired(QueuedMessage message) {
    return scheduler.isMessageExpired(message);
  }

  void registerRetryTimer(
    String messageId,
    Duration delay,
    FutureOr<void> Function() callback,
  ) {
    scheduler.registerRetryTimer(messageId, delay, callback);
  }

  void cancelRetryTimer(String messageId) {
    scheduler.cancelRetryTimer(messageId);
  }

  bool shouldRetry(
    String messageId,
    DateTime? lastAttemptAt,
    int attempts,
    int maxRetries,
    DateTime? expiresAt,
  ) {
    return scheduler.shouldRetry(
      messageId,
      lastAttemptAt,
      attempts,
      maxRetries,
      expiresAt,
    );
  }

  void cancelAllRetryTimers() {
    scheduler.cancelAllRetryTimers();
  }

  void cancelConnectivityMonitoring() {
    _onConnectivityCheck = null;
    _connectivityCheckInterval = null;
    _lastConnectivityCheckAt = null;
    _refreshMaintenanceHeartbeat();
  }

  void cancelPeriodicCleanup() {
    _onPeriodicMaintenance = null;
    _periodicCleanupInterval = null;
    _lastPeriodicCleanupAt = null;
    _isPeriodicMaintenanceRunning = false;
    _refreshMaintenanceHeartbeat();
  }

  void dispose() {
    cancelConnectivityMonitoring();
    cancelPeriodicCleanup();
    cancelAllRetryTimers();
  }

  void _refreshMaintenanceHeartbeat() {
    final tickInterval = _resolveHeartbeatInterval();
    if (tickInterval == null) {
      _maintenanceHeartbeatTimer?.cancel();
      _maintenanceHeartbeatTimer = null;
      return;
    }

    _maintenanceHeartbeatTimer?.cancel();
    _maintenanceHeartbeatTimer = Timer.periodic(tickInterval, (_) {
      _runScheduledMaintenance();
    });
  }

  Duration? _resolveHeartbeatInterval() {
    final candidates = <Duration>[];
    if (_connectivityCheckInterval != null) {
      candidates.add(_connectivityCheckInterval!);
    }
    if (_periodicCleanupInterval != null) {
      candidates.add(_periodicCleanupInterval!);
    }
    if (candidates.isEmpty) {
      return null;
    }

    candidates.sort((a, b) => a.compareTo(b));
    return candidates.first;
  }

  void _runScheduledMaintenance() {
    final now = DateTime.now();
    final connectivityCheck = _onConnectivityCheck;
    if (connectivityCheck != null &&
        _connectivityCheckInterval != null &&
        _isIntervalElapsed(
          now,
          _lastConnectivityCheckAt,
          _connectivityCheckInterval!,
        )) {
      _lastConnectivityCheckAt = now;
      connectivityCheck();
    }

    final periodicMaintenance = _onPeriodicMaintenance;
    if (periodicMaintenance != null &&
        _periodicCleanupInterval != null &&
        !_isPeriodicMaintenanceRunning &&
        _isIntervalElapsed(
          now,
          _lastPeriodicCleanupAt,
          _periodicCleanupInterval!,
        )) {
      _lastPeriodicCleanupAt = now;
      _isPeriodicMaintenanceRunning = true;
      unawaited(_runPeriodicMaintenance(periodicMaintenance));
    }
  }

  bool _isIntervalElapsed(
    DateTime now,
    DateTime? lastRunAt,
    Duration interval,
  ) {
    if (lastRunAt == null) {
      return true;
    }
    return now.difference(lastRunAt) >= interval;
  }

  Future<void> _runPeriodicMaintenance(
    Future<void> Function() periodicMaintenance,
  ) async {
    try {
      await periodicMaintenance();
    } finally {
      _isPeriodicMaintenanceRunning = false;
    }
  }
}
