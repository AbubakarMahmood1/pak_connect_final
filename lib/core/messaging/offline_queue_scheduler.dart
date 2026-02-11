import 'dart:async';

import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_retry_scheduler.dart';

import '../services/retry_scheduler.dart';

class QueueScheduler {
  QueueScheduler({IRetryScheduler? retryScheduler})
    : _retryScheduler = retryScheduler;

  IRetryScheduler? _retryScheduler;
  Timer? _connectivityCheckTimer;
  Timer? _periodicCleanupTimer;

  IRetryScheduler get scheduler {
    _retryScheduler ??= RetryScheduler();
    return _retryScheduler!;
  }

  void startConnectivityMonitoring({
    required void Function() onConnectivityCheck,
    Duration interval = const Duration(seconds: 30),
  }) {
    _connectivityCheckTimer?.cancel();
    _connectivityCheckTimer = Timer.periodic(interval, (_) {
      onConnectivityCheck();
    });
  }

  void startPeriodicCleanup({
    required Future<void> Function() onPeriodicMaintenance,
    Duration interval = const Duration(hours: 6),
  }) {
    _periodicCleanupTimer?.cancel();
    _periodicCleanupTimer = Timer.periodic(interval, (_) {
      unawaited(onPeriodicMaintenance());
    });
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

  void cancelAllRetryTimers() {
    scheduler.cancelAllRetryTimers();
  }

  void cancelConnectivityMonitoring() {
    _connectivityCheckTimer?.cancel();
    _connectivityCheckTimer = null;
  }

  void cancelPeriodicCleanup() {
    _periodicCleanupTimer?.cancel();
    _periodicCleanupTimer = null;
  }

  void dispose() {
    cancelConnectivityMonitoring();
    cancelPeriodicCleanup();
    cancelAllRetryTimers();
  }
}
