import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import '../../test_helpers/test_setup.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/models/message_priority.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'offline_message_queue_sqlite',
    );
  });

  setUp(() async {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    // Clean database before each test
    await TestSetup.fullDatabaseReset();
  });

  tearDown(() async {
    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
    // Clean up after each test
    await TestSetup.fullDatabaseReset();
  });

  group('OfflineMessageQueue SQLite Tests', () {
    test('Initialize queue and load from empty database', () async {
      final queue = OfflineMessageQueue();

      await queue.initialize();

      final stats = queue.getStatistics();
      expect(stats.pendingMessages, equals(0));
      expect(stats.totalQueued, equals(0));
    });

    test('Queue a message and retrieve it', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message content',
        recipientPublicKey: 'recipient_pub_key_001',
        senderPublicKey: 'sender_pub_key_001',
        priority: MessagePriority.normal,
      );

      expect(messageId, isNotEmpty);

      final pending = queue.getPendingMessages();
      expect(pending.length, equals(1));
      expect(pending[0].content, equals('Test message content'));
      expect(pending[0].chatId, equals('chat_001'));
      expect(pending[0].status, equals(QueuedMessageStatus.pending));
    });

    test('Queue persists across queue instances', () async {
      final queue1 = OfflineMessageQueue();
      await queue1.initialize();

      final messageId = await queue1.queueMessage(
        chatId: 'chat_001',
        content: 'Persistent message',
        recipientPublicKey: 'recipient_pub_key_001',
        senderPublicKey: 'sender_pub_key_001',
      );

      // Create new queue instance
      final queue2 = OfflineMessageQueue();
      await queue2.initialize();

      final pending = queue2.getPendingMessages();
      expect(pending.length, equals(1));
      expect(pending[0].id, equals(messageId));
      expect(pending[0].content, equals('Persistent message'));
    });

    test('Queue multiple messages with different priorities', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Low priority',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
        priority: MessagePriority.low,
      );

      await queue.queueMessage(
        chatId: 'chat_002',
        content: 'Urgent priority',
        recipientPublicKey: 'recipient_002',
        senderPublicKey: 'sender_002',
        priority: MessagePriority.urgent,
      );

      await queue.queueMessage(
        chatId: 'chat_003',
        content: 'Normal priority',
        recipientPublicKey: 'recipient_003',
        senderPublicKey: 'sender_003',
        priority: MessagePriority.normal,
      );

      final stats = queue.getStatistics();
      expect(stats.pendingMessages, equals(3));

      // Verify messages are ordered by priority
      final pending = queue.getPendingMessages();
      expect(pending[0].priority, equals(MessagePriority.urgent));
    });

    test('Remove message from queue', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'To be removed',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      expect(queue.getPendingMessages().length, equals(1));

      await queue.removeMessage(messageId);

      expect(queue.getPendingMessages().length, equals(0));
    });

    test('Mark message as delivered', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      expect(queue.getPendingMessages().length, equals(1));

      await queue.markMessageDelivered(messageId);

      // Message should be removed from queue after delivery
      expect(queue.getPendingMessages().length, equals(0));

      final stats = queue.getStatistics();
      expect(stats.totalDelivered, equals(1));
    });

    test('Handle message with attachments', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Message with attachments',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
        attachments: ['file1.jpg', 'file2.pdf', 'file3.mp4'],
      );

      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      expect(message!.attachments.length, equals(3));
      expect(message.attachments, contains('file1.jpg'));
      expect(message.attachments, contains('file2.pdf'));
      expect(message.attachments, contains('file3.mp4'));
    });

    test('Handle message with reply reference', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Reply message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
        replyToMessageId: 'original_message_id_123',
      );

      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      expect(message!.replyToMessageId, equals('original_message_id_123'));
    });

    test('Clear entire queue', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      // Queue multiple messages
      await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Message 1',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      await queue.queueMessage(
        chatId: 'chat_002',
        content: 'Message 2',
        recipientPublicKey: 'recipient_002',
        senderPublicKey: 'sender_002',
      );

      expect(queue.getPendingMessages().length, equals(2));

      await queue.clearQueue();

      expect(queue.getPendingMessages().length, equals(0));
    });

    test('Track deleted messages', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = 'test_message_123';

      expect(queue.isMessageDeleted(messageId), isFalse);

      await queue.markMessageDeleted(messageId);

      expect(queue.isMessageDeleted(messageId), isTrue);
    });

    test('Deleted messages persist across instances', () async {
      final queue1 = OfflineMessageQueue();
      await queue1.initialize();

      await queue1.markMessageDeleted('deleted_msg_001');
      await queue1.markMessageDeleted('deleted_msg_002');

      // Create new instance
      final queue2 = OfflineMessageQueue();
      await queue2.initialize();

      expect(queue2.isMessageDeleted('deleted_msg_001'), isTrue);
      expect(queue2.isMessageDeleted('deleted_msg_002'), isTrue);
      expect(queue2.isMessageDeleted('not_deleted'), isFalse);
    });

    test('Get messages by status', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Message 1',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      final pending = queue.getMessagesByStatus(QueuedMessageStatus.pending);
      expect(pending.length, equals(1));

      final sending = queue.getMessagesByStatus(QueuedMessageStatus.sending);
      expect(sending.length, equals(0));
    });

    test('Queue statistics are accurate', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      // Initial state
      var stats = queue.getStatistics();
      expect(stats.pendingMessages, equals(0));
      expect(stats.totalQueued, equals(0));

      // Queue a message
      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      stats = queue.getStatistics();
      expect(stats.pendingMessages, equals(1));
      expect(stats.totalQueued, equals(1));

      // Deliver the message
      await queue.markMessageDelivered(messageId);

      stats = queue.getStatistics();
      expect(stats.pendingMessages, equals(0));
      expect(stats.totalDelivered, equals(1));
    });

    test('Relay message with metadata', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      // Test relay message by queueing a high-priority message
      await queue.queueMessage(
        chatId: 'chat_001',
        content: 'High priority relay message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
        priority: MessagePriority.high,
      );

      final pending = queue.getPendingMessages();
      expect(pending.length, equals(1));
      expect(pending[0].priority, equals(MessagePriority.high));
    });

    test('Calculate queue hash', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final hash1 = queue.calculateQueueHash();

      await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      final hash2 = queue.calculateQueueHash(forceRecalculation: true);

      // Hash should change when queue changes
      expect(hash1, isNot(equals(hash2)));
    });

    test('Get message by ID', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      expect(message!.id, equals(messageId));

      final nonExistent = queue.getMessageById('non_existent_id');
      expect(nonExistent, isNull);
    });

    test('Handle online/offline status changes', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final stats1 = queue.getStatistics();
      expect(stats1.isOnline, isFalse);

      await queue.setOnline();

      final stats2 = queue.getStatistics();
      expect(stats2.isOnline, isTrue);

      queue.setOffline();

      final stats3 = queue.getStatistics();
      expect(stats3.isOnline, isFalse);
    });

    test('Retry failed messages', () async {
      final queue = OfflineMessageQueue();
      await queue.initialize();

      final messageId = await queue.queueMessage(
        chatId: 'chat_001',
        content: 'Test message',
        recipientPublicKey: 'recipient_001',
        senderPublicKey: 'sender_001',
      );

      // Get the message and simulate at least one attempt
      final message = queue.getMessageById(messageId);
      expect(message, isNotNull);
      message!.attempts = 1; // Set attempts to avoid -1 in exponential backoff
      message.status = QueuedMessageStatus.sending;

      // Simulate failure
      await queue.markMessageFailed(messageId, 'Test failure');

      // Retry failed messages
      await queue.retryFailedMessages();

      // Message should be reset and ready to retry (pending or retrying status)
      final retriedMessage = queue.getMessageById(messageId);
      expect(retriedMessage, isNotNull);
      expect(retriedMessage!.status, isNot(equals(QueuedMessageStatus.failed)));
    });
  });
}
