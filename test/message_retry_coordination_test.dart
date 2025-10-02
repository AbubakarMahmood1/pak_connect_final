import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/services/message_retry_coordinator.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

/// Test to verify the message retry coordination functionality
/// This addresses the "retry all" bug by testing coordination between persistence systems
void main() {
  final testLogger = Logger('MessageRetryCoordinationTest');

  // Set up logging for tests
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  group('Message Retry Coordination Tests', () {
    late MessageRepository messageRepository;
    late OfflineMessageQueue offlineQueue;
    late MessageRetryCoordinator coordinator;
    
    setUp(() async {
      messageRepository = MessageRepository();
      offlineQueue = OfflineMessageQueue();
      
      // Initialize the offline queue
      await offlineQueue.initialize();
      
      coordinator = MessageRetryCoordinator(
        messageRepository: messageRepository,
        offlineQueue: offlineQueue,
      );
    });

    tearDown(() {
      offlineQueue.dispose();
    });

    test('should detect failed messages from both persistence systems', () async {
      const chatId = 'test_chat_123';
      
      // Add failed messages to repository
      final repoMessage1 = Message(
        id: 'repo_msg_1',
        chatId: chatId,
        content: 'Repository failed message 1',
        timestamp: DateTime.now().subtract(Duration(minutes: 5)),
        isFromMe: true,
        status: MessageStatus.failed,
      );
      
      final repoMessage2 = Message(
        id: 'repo_msg_2',
        chatId: chatId,
        content: 'Repository failed message 2',
        timestamp: DateTime.now().subtract(Duration(minutes: 3)),
        isFromMe: true,
        status: MessageStatus.failed,
      );
      
      await messageRepository.saveMessage(repoMessage1);
      await messageRepository.saveMessage(repoMessage2);
      
      // Add failed messages to queue
      await offlineQueue.queueMessage(
        chatId: chatId,
        content: 'Queue failed message 1',
        recipientPublicKey: 'test_recipient_key',
        senderPublicKey: 'test_sender_key',
        priority: MessagePriority.normal,
      );
      
      // Simulate queue message failure
      final queueStats = offlineQueue.getStatistics();
      expect(queueStats.pendingMessages, greaterThan(0));
      
      // Test coordinator detection
      final retryStatus = await coordinator.getFailedMessageStatus(chatId);
      
      expect(retryStatus.hasError, false);
      expect(retryStatus.repositoryFailedMessages, hasLength(2));
      expect(retryStatus.totalFailed, greaterThanOrEqualTo(2));
      expect(retryStatus.hasFailedMessages, true);
      
      testLogger.info('✅ Successfully detected ${retryStatus.totalFailed} failed messages across both systems');
    });

    test('should coordinate retry across both systems', () async {
      const chatId = 'test_chat_coordination';
      
      // Add a failed repository message
      final repoMessage = Message(
        id: 'coord_repo_msg',
        chatId: chatId,
        content: 'Test coordination message',
        timestamp: DateTime.now().subtract(Duration(minutes: 2)),
        isFromMe: true,
        status: MessageStatus.failed,
      );
      
      await messageRepository.saveMessage(repoMessage);
      
      // Mock retry callbacks
      bool repoRetryWasCalled = false;
      bool queueRetryWasCalled = false;
      
      // Execute coordinated retry
      final retryResult = await coordinator.retryAllFailedMessages(
        chatId: chatId,
        onRepositoryMessageRetry: (Message message) async {
          repoRetryWasCalled = true;
          expect(message.id, equals('coord_repo_msg'));
          
          // Simulate successful retry by updating the message
          final successMessage = message.copyWith(status: MessageStatus.delivered);
          await messageRepository.updateMessage(successMessage);
          
          testLogger.info('📱 Repository message retry callback executed for: ${message.id}');
        },
        onQueueMessageRetry: (QueuedMessage queuedMessage) async {
          queueRetryWasCalled = true;
          testLogger.info('📤 Queue message retry callback executed for: ${queuedMessage.id}');
        },
      );
      
      expect(retryResult.success, true);
      expect(retryResult.repositoryAttempted, 1);
      expect(retryResult.repositorySucceeded, 1);
      expect(repoRetryWasCalled, true);
      
      // Verify message was updated in repository
      final updatedMessages = await messageRepository.getMessages(chatId);
      final updatedMessage = updatedMessages.firstWhere((m) => m.id == 'coord_repo_msg');
      expect(updatedMessage.status, MessageStatus.delivered);
      
      testLogger.info('✅ Coordinated retry completed successfully: ${retryResult.message}');
    });

    test('should handle mixed success/failure scenarios', () async {
      const chatId = 'test_chat_mixed';
      
      // Add multiple failed messages
      final messages = [
        Message(
          id: 'mixed_msg_1',
          chatId: chatId,
          content: 'Will succeed',
          timestamp: DateTime.now().subtract(Duration(minutes: 5)),
          isFromMe: true,
          status: MessageStatus.failed,
        ),
        Message(
          id: 'mixed_msg_2',
          chatId: chatId,
          content: 'Will fail',
          timestamp: DateTime.now().subtract(Duration(minutes: 3)),
          isFromMe: true,
          status: MessageStatus.failed,
        ),
      ];
      
      for (final message in messages) {
        await messageRepository.saveMessage(message);
      }
      
      // Execute retry with mixed results
      final retryResult = await coordinator.retryAllFailedMessages(
        chatId: chatId,
        onRepositoryMessageRetry: (Message message) async {
          if (message.id == 'mixed_msg_1') {
            // Simulate success
            final successMessage = message.copyWith(status: MessageStatus.delivered);
            await messageRepository.updateMessage(successMessage);
          } else if (message.id == 'mixed_msg_2') {
            // Simulate failure by throwing exception
            throw Exception('Simulated delivery failure');
          }
        },
        onQueueMessageRetry: (QueuedMessage queuedMessage) async {
          // No queue messages in this test
        },
      );
      
      expect(retryResult.repositoryAttempted, 2);
      expect(retryResult.repositorySucceeded, 1); // Only one succeeded
      expect(retryResult.successRate, 0.5);
      
      // Verify only the successful message was updated
      final finalMessages = await messageRepository.getMessages(chatId);
      final successfulMessage = finalMessages.firstWhere((m) => m.id == 'mixed_msg_1');
      final failedMessage = finalMessages.firstWhere((m) => m.id == 'mixed_msg_2');
      
      expect(successfulMessage.status, MessageStatus.delivered);
      expect(failedMessage.status, MessageStatus.failed);
      
      testLogger.info('✅ Mixed scenario handled correctly: ${retryResult.successRate * 100}% success rate');
    });

    test('should report system health accurately', () async {
      const chatId = 'test_chat_health';
      
      // Add a mix of delivered and failed messages
      final messages = [
        Message(
          id: 'health_delivered_1',
          chatId: chatId,
          content: 'Delivered message 1',
          timestamp: DateTime.now().subtract(Duration(minutes: 10)),
          isFromMe: true,
          status: MessageStatus.delivered,
        ),
        Message(
          id: 'health_delivered_2',
          chatId: chatId,
          content: 'Delivered message 2',
          timestamp: DateTime.now().subtract(Duration(minutes: 8)),
          isFromMe: true,
          status: MessageStatus.delivered,
        ),
        Message(
          id: 'health_failed_1',
          chatId: chatId,
          content: 'Failed message 1',
          timestamp: DateTime.now().subtract(Duration(minutes: 5)),
          isFromMe: true,
          status: MessageStatus.failed,
        ),
      ];
      
      for (final message in messages) {
        await messageRepository.saveMessage(message);
      }
      
      final health = await coordinator.getSystemHealth();
      
      expect(health.totalRepositoryMessages, 3);
      expect(health.failedRepositoryMessages, 1);
      expect(health.repositoryHealthScore, closeTo(0.67, 0.1)); // 2/3 success rate
      
      // Overall health should reflect both systems
      expect(health.overallHealth, greaterThan(0.0));
      expect(health.totalMessages, greaterThanOrEqualTo(3));
      
      testLogger.info('✅ System health assessment: ${(health.overallHealth * 100).toStringAsFixed(1)}% overall health');
      testLogger.info('   Repository: ${health.totalRepositoryMessages} total, ${health.failedRepositoryMessages} failed');
      testLogger.info('   Queue: ${health.totalQueueMessages} total, ${health.failedQueueMessages} failed');
    });

    test('should handle empty retry scenarios gracefully', () async {
      const chatId = 'test_chat_empty';
      
      // No failed messages - should handle gracefully
      final retryStatus = await coordinator.getFailedMessageStatus(chatId);
      expect(retryStatus.hasFailedMessages, false);
      expect(retryStatus.totalFailed, 0);
      
      final retryResult = await coordinator.retryAllFailedMessages(
        chatId: chatId,
        onRepositoryMessageRetry: (Message message) async {
          fail('Should not be called when no failed messages exist');
        },
        onQueueMessageRetry: (QueuedMessage queuedMessage) async {
          fail('Should not be called when no failed messages exist');
        },
      );
      
      expect(retryResult.success, true);
      expect(retryResult.totalAttempted, 0);
      expect(retryResult.totalSucceeded, 0);
      expect(retryResult.message, contains('No failed messages'));
      
      testLogger.info('✅ Empty retry scenario handled gracefully: ${retryResult.message}');
    });
  });

  group('Integration with Original Systems', () {
    test('should maintain backward compatibility with MessageRepository', () async {
      final repository = MessageRepository();
      const chatId = 'test_compatibility';
      
      // Test basic repository operations still work
      final message = Message(
        id: 'compat_test_msg',
        chatId: chatId,
        content: 'Compatibility test message',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.delivered,
      );
      
      await repository.saveMessage(message);
      
      final retrievedMessages = await repository.getMessages(chatId);
      expect(retrievedMessages, hasLength(1));
      expect(retrievedMessages.first.id, equals('compat_test_msg'));
      expect(retrievedMessages.first.status, MessageStatus.delivered);
      
      testLogger.info('✅ MessageRepository compatibility maintained');
    });

    test('should maintain backward compatibility with OfflineMessageQueue', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();
      
      try {
        // Test basic queue operations still work
        final messageId = await queue.queueMessage(
          chatId: 'compat_chat',
          content: 'Queue compatibility test',
          recipientPublicKey: 'test_recipient',
          senderPublicKey: 'test_sender',
          priority: MessagePriority.normal,
        );
        
        expect(messageId, isNotEmpty);
        
        final stats = queue.getStatistics();
        expect(stats.totalQueued, greaterThan(0));
        
        testLogger.info('✅ OfflineMessageQueue compatibility maintained');
      } finally {
        queue.dispose();
      }
    });
  });
}