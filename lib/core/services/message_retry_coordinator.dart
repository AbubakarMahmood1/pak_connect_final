/// Coordinates message retry operations between MessageRepository and OfflineMessageQueue
/// Solves the dual persistence system conflict for retry all functionality
library;

import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/entities/message.dart';
import '../../domain/values/id_types.dart';
import '../interfaces/i_repository_provider.dart';
import '../messaging/offline_message_queue.dart';
import '../interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'package:get_it/get_it.dart';

/// Coordinates retry operations between different message persistence systems
class MessageRetryCoordinator {
  static final _logger = Logger('MessageRetryCoordinator');

  final IRepositoryProvider _repositoryProvider;
  final OfflineMessageQueue _offlineQueue;

  MessageRetryCoordinator({
    IRepositoryProvider? repositoryProvider,
    required OfflineMessageQueue offlineQueue,
    IMeshNetworkingService?
    meshService, // Kept for API compatibility but not used
  }) : _repositoryProvider =
           repositoryProvider ?? GetIt.instance<IRepositoryProvider>(),
       _offlineQueue = offlineQueue;

  /// Get unified failed message count from both persistence systems
  Future<MessageRetryStatus> getFailedMessageStatus(ChatId chatId) async {
    try {
      // Get failed messages from repository (UI messages)
      final repositoryMessages = await _repositoryProvider.messageRepository
          .getMessages(chatId);
      final repositoryFailedMessages = repositoryMessages
          .where((m) => m.isFromMe && m.status == MessageStatus.failed)
          .toList();

      // Get failed messages from queue
      final queueFailedMessages = _offlineQueue.getMessagesByStatus(
        QueuedMessageStatus.failed,
      );

      // Filter queue messages for this chat
      final chatQueueFailedMessages = queueFailedMessages
          .where((qm) => qm.chatId == chatId.value)
          .toList();

      _logger.info(
        '💾 Repository failed messages: ${repositoryFailedMessages.length}',
      );
      _logger.info(
        '📤 Queue failed messages for chat: ${chatQueueFailedMessages.length}',
      );

      return MessageRetryStatus(
        repositoryFailedMessages: repositoryFailedMessages,
        queueFailedMessages: chatQueueFailedMessages,
        totalFailed:
            repositoryFailedMessages.length + chatQueueFailedMessages.length,
      );
    } catch (e) {
      _logger.severe('❌ Failed to get retry status: $e');
      return MessageRetryStatus(
        repositoryFailedMessages: [],
        queueFailedMessages: [],
        totalFailed: 0,
        error: e.toString(),
      );
    }
  }

  /// Coordinate retry of all failed messages across both systems
  Future<MessageRetryResult> retryAllFailedMessages({
    required ChatId chatId,
    required Future<void> Function(Message message) onRepositoryMessageRetry,
    required Future<void> Function(QueuedMessage message) onQueueMessageRetry,
    bool allowPartialConnection = true,
  }) async {
    try {
      _logger.info('🔄 Starting coordinated retry for chat: ${chatId.value}');

      final queueStats = _offlineQueue.getStatistics();
      final queueIsOnline = queueStats.isOnline;
      final shouldAttemptImmediate = queueIsOnline || allowPartialConnection;

      if (!shouldAttemptImmediate) {
        _logger.info(
          '🌐 No active connection detected; will requeue without immediate send',
        );
      }

      final status = await getFailedMessageStatus(chatId);

      if (status.totalFailed == 0) {
        _logger.info('✅ No failed messages found in either system');
        return MessageRetryResult(
          success: true,
          repositoryAttempted: 0,
          repositorySucceeded: 0,
          queueAttempted: 0,
          queueSucceeded: 0,
          message: 'No failed messages to retry',
        );
      }

      _logger.info(
        '🎯 Found ${status.totalFailed} total failed messages to retry',
      );

      int repoAttempted = 0, repoSucceeded = 0;
      int queueAttempted = 0, queueSucceeded = 0;

      // STEP 1: Retry repository messages (UI messages)
      if (shouldAttemptImmediate) {
        for (final message in status.repositoryFailedMessages) {
          repoAttempted++;
          try {
            _logger.info(
              '🔄 Retrying repository message: ${message.id.value.shortId(8)}...',
            );
            await onRepositoryMessageRetry(message);
            repoSucceeded++;
          } catch (e) {
            _logger.warning('⚠️ Repository message retry failed: $e');
          }

          // Progressive delay between retries
          if (repoAttempted < status.repositoryFailedMessages.length) {
            await Future.delayed(Duration(milliseconds: 300));
          }
        }
      } else {
        _logger.info(
          '⏳ Skipping repository retries until a connection is available',
        );
      }

      // STEP 2: Retry queue messages using the queue's own retry mechanism
      if (status.queueFailedMessages.isNotEmpty) {
        queueAttempted = status.queueFailedMessages.length;
        int queueCallbackFailures = 0;

        try {
          _logger.info(
            '📤 Retrying ${status.queueFailedMessages.length} queue messages for chat ${chatId.value}',
          );

          for (var i = 0; i < status.queueFailedMessages.length; i++) {
            final queuedMessage = status.queueFailedMessages[i];
            try {
              _logger.info(
                '📤 Retrying queue message: ${queuedMessage.id.shortId(8)}...',
              );
              await onQueueMessageRetry(queuedMessage);
            } catch (e) {
              queueCallbackFailures++;
              _logger.warning(
                '⚠️ Queue retry callback failed for ${queuedMessage.id.shortId(8)}: $e',
              );
            }

            // Progressive delay between queue retries to avoid burst sends
            if (i < status.queueFailedMessages.length - 1) {
              await Future.delayed(Duration(milliseconds: 200));
            }
          }

          // Retry only this chat's failed messages to avoid leaking retries to other chats
          await _offlineQueue.retryFailedMessagesForChat(chatId.value);

          final remainingFailed = _offlineQueue
              .getMessagesByStatus(QueuedMessageStatus.failed)
              .where((qm) => qm.chatId == chatId.value)
              .length;

          queueSucceeded =
              queueAttempted - queueCallbackFailures - remainingFailed;

          if (queueSucceeded < 0) {
            queueSucceeded = 0;
          }

          _logger.info(
            '📤 Queue retry completed: $queueSucceeded/$queueAttempted succeeded',
          );
        } catch (e) {
          _logger.warning('⚠️ Queue retry failed: $e');
          queueSucceeded = queueAttempted - queueCallbackFailures;
          if (queueSucceeded < 0) {
            queueSucceeded = 0;
          }
        }
      }

      final totalSucceeded = repoSucceeded + queueSucceeded;
      final totalAttempted = repoAttempted + queueAttempted;
      final queuedForLater = !shouldAttemptImmediate && queueAttempted > 0;

      _logger.info(
        '🏁 Coordinated retry completed: $totalSucceeded/$totalAttempted messages succeeded',
      );

      return MessageRetryResult(
        success: totalSucceeded > 0 || queuedForLater,
        repositoryAttempted: repoAttempted,
        repositorySucceeded: repoSucceeded,
        queueAttempted: queueAttempted,
        queueSucceeded: queueSucceeded,
        message: queuedForLater
            ? 'Queued $queueAttempted message${queueAttempted > 1 ? 's' : ''} for delivery when a connection is available'
            : totalSucceeded > 0
            ? 'Successfully delivered $totalSucceeded message${totalSucceeded > 1 ? 's' : ''}'
            : 'All retry attempts failed - messages will retry automatically when connection improves',
      );
    } catch (e) {
      _logger.severe('💥 Coordinated retry failed: $e');
      return MessageRetryResult(
        success: false,
        repositoryAttempted: 0,
        repositorySucceeded: 0,
        queueAttempted: 0,
        queueSucceeded: 0,
        message: 'Retry coordination failed: $e',
      );
    }
  }

  /// Get overall queue and repository health
  Future<MessageSystemHealth> getSystemHealth() async {
    try {
      final queueStats = _offlineQueue.getStatistics();
      final repoMessages = await _repositoryProvider.messageRepository
          .getAllMessages();

      final totalRepoMessages = repoMessages.length;
      final failedRepoMessages = repoMessages
          .where((m) => m.isFromMe && m.status == MessageStatus.failed)
          .length;

      final repoHealthScore = totalRepoMessages > 0
          ? 1.0 - (failedRepoMessages / totalRepoMessages)
          : 1.0;

      return MessageSystemHealth(
        repositoryHealthScore: repoHealthScore,
        queueHealthScore: queueStats.queueHealthScore,
        totalRepositoryMessages: totalRepoMessages,
        failedRepositoryMessages: failedRepoMessages,
        totalQueueMessages: queueStats.totalQueued,
        failedQueueMessages: queueStats.failedMessages,
        isHealthy: repoHealthScore > 0.8 && queueStats.queueHealthScore > 0.7,
      );
    } catch (e) {
      _logger.severe('❌ Failed to get system health: $e');
      return MessageSystemHealth(
        repositoryHealthScore: 0.0,
        queueHealthScore: 0.0,
        totalRepositoryMessages: 0,
        failedRepositoryMessages: 0,
        totalQueueMessages: 0,
        failedQueueMessages: 0,
        isHealthy: false,
        error: e.toString(),
      );
    }
  }
}

/// Status of failed messages across both persistence systems
class MessageRetryStatus {
  final List<Message> repositoryFailedMessages;
  final List<QueuedMessage> queueFailedMessages;
  final int totalFailed;
  final String? error;

  const MessageRetryStatus({
    required this.repositoryFailedMessages,
    required this.queueFailedMessages,
    required this.totalFailed,
    this.error,
  });

  bool get hasFailedMessages => totalFailed > 0;
  bool get hasError => error != null;
}

/// Result of coordinated retry operation
class MessageRetryResult {
  final bool success;
  final int repositoryAttempted;
  final int repositorySucceeded;
  final int queueAttempted;
  final int queueSucceeded;
  final String message;

  const MessageRetryResult({
    required this.success,
    required this.repositoryAttempted,
    required this.repositorySucceeded,
    required this.queueAttempted,
    required this.queueSucceeded,
    required this.message,
  });

  int get totalAttempted => repositoryAttempted + queueAttempted;
  int get totalSucceeded => repositorySucceeded + queueSucceeded;
  double get successRate =>
      totalAttempted > 0 ? totalSucceeded / totalAttempted : 0.0;
}

/// Overall health of both message persistence systems
class MessageSystemHealth {
  final double repositoryHealthScore;
  final double queueHealthScore;
  final int totalRepositoryMessages;
  final int failedRepositoryMessages;
  final int totalQueueMessages;
  final int failedQueueMessages;
  final bool isHealthy;
  final String? error;

  const MessageSystemHealth({
    required this.repositoryHealthScore,
    required this.queueHealthScore,
    required this.totalRepositoryMessages,
    required this.failedRepositoryMessages,
    required this.totalQueueMessages,
    required this.failedQueueMessages,
    required this.isHealthy,
    this.error,
  });

  double get overallHealth => (repositoryHealthScore + queueHealthScore) / 2;
  int get totalMessages => totalRepositoryMessages + totalQueueMessages;
  int get totalFailedMessages => failedRepositoryMessages + failedQueueMessages;
}
