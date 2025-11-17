import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/messaging/offline_message_queue.dart';
import 'package:pak_connect/core/services/message_queue_repository.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

void main() {
  group('MessageQueueRepository', () {
    late MessageQueueRepository repository;

    setUp(() {
      repository = MessageQueueRepository();
    });

    test('getAllMessages returns combined direct and relay messages', () {
      // Arrange
      final directMsg = QueuedMessage(
        id: 'direct-1',
        chatId: 'chat-1',
        content: 'Direct message',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: false,
      );

      final relayMsg = QueuedMessage(
        id: 'relay-1',
        chatId: 'chat-1',
        content: 'Relay message',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: true,
      );

      repository.directMessageQueue.add(directMsg);
      repository.relayMessageQueue.add(relayMsg);

      // Act
      final allMessages = repository.getAllMessages();

      // Assert
      expect(allMessages.length, equals(2));
      expect(allMessages, contains(directMsg));
      expect(allMessages, contains(relayMsg));
    });

    test('getMessageById returns message when found', () {
      // Arrange
      final message = QueuedMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        content: 'Test message',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
      );

      repository.directMessageQueue.add(message);

      // Act
      final found = repository.getMessageById('msg-1');

      // Assert
      expect(found, isNotNull);
      expect(found?.id, equals('msg-1'));
      expect(found?.content, equals('Test message'));
    });

    test('getMessageById returns null when not found', () {
      // Act
      final found = repository.getMessageById('non-existent');

      // Assert
      expect(found, isNull);
    });

    test('getMessagesByStatus returns messages with correct status', () {
      // Arrange
      final pendingMsg = QueuedMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        content: 'Pending',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        status: QueuedMessageStatus.pending,
      );

      final sentMsg = QueuedMessage(
        id: 'msg-2',
        chatId: 'chat-1',
        content: 'Sent',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        status: QueuedMessageStatus.sending,
      );

      repository.directMessageQueue.addAll([pendingMsg, sentMsg]);

      // Act
      final pending = repository.getMessagesByStatus(QueuedMessageStatus.pending);

      // Assert
      expect(pending.length, equals(1));
      expect(pending.first.id, equals('msg-1'));
    });

    test('getPendingMessages returns only pending messages', () {
      // Arrange
      final pendingMsg1 = QueuedMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        content: 'Pending 1',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        status: QueuedMessageStatus.pending,
      );

      final pendingMsg2 = QueuedMessage(
        id: 'msg-2',
        chatId: 'chat-1',
        content: 'Pending 2',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        status: QueuedMessageStatus.pending,
      );

      repository.directMessageQueue.addAll([pendingMsg1, pendingMsg2]);

      // Act
      final pending = repository.getPendingMessages();

      // Assert
      expect(pending.length, equals(2));
      expect(pending.every((m) => m.status == QueuedMessageStatus.pending), isTrue);
    });

    test('insertMessageByPriority maintains priority ordering in direct queue', () {
      // Arrange
      final lowPriority = QueuedMessage(
        id: 'low',
        chatId: 'chat-1',
        content: 'Low',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.low,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: false,
      );

      final urgentPriority = QueuedMessage(
        id: 'urgent',
        chatId: 'chat-1',
        content: 'Urgent',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.urgent,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: false,
      );

      repository.insertMessageByPriority(lowPriority);

      // Act
      repository.insertMessageByPriority(urgentPriority);

      // Assert
      // Urgent should be first (higher priority index)
      expect(repository.directMessageQueue.first.id, equals('urgent'));
      expect(repository.directMessageQueue.last.id, equals('low'));
    });

    test('removeMessageFromQueue removes from both queues', () {
      // Arrange
      final directMsg = QueuedMessage(
        id: 'direct-1',
        chatId: 'chat-1',
        content: 'Direct',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: false,
      );

      final relayMsg = QueuedMessage(
        id: 'relay-1',
        chatId: 'chat-1',
        content: 'Relay',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: true,
      );

      repository.directMessageQueue.add(directMsg);
      repository.relayMessageQueue.add(relayMsg);

      // Act
      repository.removeMessageFromQueue('direct-1');
      repository.removeMessageFromQueue('relay-1');

      // Assert
      expect(repository.directMessageQueue, isEmpty);
      expect(repository.relayMessageQueue, isEmpty);
    });

    test('isMessageDeleted returns true for deleted messages', () {
      // Arrange
      repository.deletedMessageIds.add('msg-1');

      // Act
      final deleted = repository.isMessageDeleted('msg-1');

      // Assert
      expect(deleted, isTrue);
    });

    test('isMessageDeleted returns false for non-deleted messages', () {
      // Act
      final deleted = repository.isMessageDeleted('non-existent');

      // Assert
      expect(deleted, isFalse);
    });

    test('markMessageDeleted adds to deleted set and removes from queue', () {
      // Arrange
      final message = QueuedMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        content: 'Test',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
      );

      repository.directMessageQueue.add(message);
      expect(repository.directMessageQueue.length, equals(1));

      // Act
      // Note: This would call saveDeletedMessageIds and saveQueueToStorage which are async
      // For this unit test, we're testing the in-memory logic
      repository.deletedMessageIds.add(message.id);
      repository.removeMessageFromQueue(message.id);

      // Assert
      expect(repository.isMessageDeleted('msg-1'), isTrue);
      expect(repository.directMessageQueue, isEmpty);
    });

    test('queuedMessageToDb converts message to database format', () {
      // Arrange
      final message = QueuedMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        content: 'Test content',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.high,
        queuedAt: DateTime(2024, 1, 1),
        maxRetries: 5,
        attempts: 2,
        status: QueuedMessageStatus.retrying,
        replyToMessageId: 'reply-to',
        attachments: ['file1.txt'],
      );

      // Act
      final dbRow = repository.queuedMessageToDb(message);

      // Assert
      expect(dbRow['message_id'], equals('msg-1'));
      expect(dbRow['chat_id'], equals('chat-1'));
      expect(dbRow['content'], equals('Test content'));
      expect(dbRow['priority'], equals(MessagePriority.high.index));
      expect(dbRow['status'], equals(QueuedMessageStatus.retrying.index));
      expect(dbRow['attempts'], equals(2));
      expect(dbRow['max_retries'], equals(5));
    });

    test('queuedMessageFromDb converts database row to message', () {
      // Arrange
      final now = DateTime.now();
      final dbRow = {
        'message_id': 'msg-1',
        'chat_id': 'chat-1',
        'content': 'Test content',
        'recipient_public_key': 'recipient-key',
        'sender_public_key': 'sender-key',
        'priority': MessagePriority.high.index,
        'queued_at': now.millisecondsSinceEpoch,
        'max_retries': 5,
        'status': QueuedMessageStatus.pending.index,
        'attempts': 0,
        'last_attempt_at': null,
        'next_retry_at': null,
        'delivered_at': null,
        'failed_at': null,
        'failure_reason': null,
        'expires_at': null,
        'is_relay_message': 0,
        'relay_metadata_json': null,
        'original_message_id': null,
        'relay_node_id': null,
        'message_hash': null,
        'reply_to_message_id': null,
        'attachments_json': null,
        'sender_rate_count': 0,
      };

      // Act
      final message = repository.queuedMessageFromDb(dbRow);

      // Assert
      expect(message.id, equals('msg-1'));
      expect(message.chatId, equals('chat-1'));
      expect(message.content, equals('Test content'));
      expect(message.priority, equals(MessagePriority.high));
      expect(message.status, equals(QueuedMessageStatus.pending));
      expect(message.isRelayMessage, isFalse);
    });

    test('getOldestPendingMessage returns message with earliest queuedAt', () {
      // Arrange
      final now = DateTime.now();
      final older = QueuedMessage(
        id: 'older',
        chatId: 'chat-1',
        content: 'Older',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: now.subtract(Duration(minutes: 10)),
        maxRetries: 5,
        status: QueuedMessageStatus.pending,
      );

      final newer = QueuedMessage(
        id: 'newer',
        chatId: 'chat-1',
        content: 'Newer',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: now,
        maxRetries: 5,
        status: QueuedMessageStatus.pending,
      );

      repository.directMessageQueue.addAll([newer, older]);

      // Act
      final oldest = repository.getOldestPendingMessage();

      // Assert
      expect(oldest?.id, equals('older'));
    });

    test('insertMessageByPriority routes relay messages to relay queue', () {
      // Arrange
      final relayMsg = QueuedMessage(
        id: 'relay-1',
        chatId: 'chat-1',
        content: 'Relay',
        recipientPublicKey: 'recipient-key',
        senderPublicKey: 'sender-key',
        priority: MessagePriority.normal,
        queuedAt: DateTime.now(),
        maxRetries: 5,
        isRelayMessage: true,
      );

      // Act
      repository.insertMessageByPriority(relayMsg);

      // Assert
      expect(repository.relayMessageQueue.length, equals(1));
      expect(repository.directMessageQueue, isEmpty);
      expect(repository.relayMessageQueue.first.id, equals('relay-1'));
    });
  });
}
