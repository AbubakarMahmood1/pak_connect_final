import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';
import 'test_helpers/test_setup.dart';

void main() {
  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  // Reset database before each test
  setUp(() async {
    await TestSetup.fullDatabaseReset();
  });

  // Helper method to create a chat (required due to foreign key constraint)
  Future<void> createChat(String chatId, {String? contactName}) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('chats', {
      'chat_id': chatId,
      'contact_name': contactName ?? 'Test Contact',
      'created_at': now,
      'updated_at': now,
    });
  }

  group('MessageRepository SQLite Tests', () {
    test('Save and retrieve basic message', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final message = Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Hello, World!',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await repository.saveMessage(message);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);
      expect(messages.first.id, 'msg_001');
      expect(messages.first.content, 'Hello, World!');
      expect(messages.first.isFromMe, true);
      expect(messages.first.status, MessageStatus.sent);
    });

    test('Save and retrieve EnhancedMessage with all fields', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final enhancedMessage = EnhancedMessage(
        id: 'msg_002',
        chatId: 'chat_001',
        content: 'Enhanced message',
        timestamp: DateTime.now(),
        isFromMe: false,
        status: MessageStatus.delivered,
        replyToMessageId: 'msg_001',
        threadId: 'thread_001',
        isStarred: true,
        isForwarded: false,
        priority: MessagePriority.high,
        editedAt: DateTime.now(),
        originalContent: 'Original content',
        metadata: {'key': 'value'},
        deliveryReceipt: MessageDeliveryReceipt(
          deliveredAt: DateTime.now(),
          deviceId: 'device_001',
          networkRoute: 'direct',
        ),
        readReceipt: MessageReadReceipt(
          readAt: DateTime.now(),
          readBy: 'user_001',
          deviceId: 'device_001',
        ),
        reactions: [
          MessageReaction(
            emoji: '👍',
            userId: 'user_001',
            reactedAt: DateTime.now(),
          ),
        ],
        attachments: [
          MessageAttachment(
            id: 'attach_001',
            type: 'image',
            name: 'photo.jpg',
            size: 1024,
            mimeType: 'image/jpeg',
            localPath: '/path/to/photo.jpg',
          ),
        ],
        encryptionInfo: MessageEncryptionInfo(
          algorithm: 'AES-256',
          keyId: 'key_001',
          isEndToEndEncrypted: true,
          encryptedAt: DateTime.now(),
          senderKeyFingerprint: 'sender_fp',
          recipientKeyFingerprint: 'recipient_fp',
        ),
      );

      await repository.saveMessage(enhancedMessage);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);

      final retrieved = messages.first as EnhancedMessage;
      expect(retrieved.id, 'msg_002');
      expect(retrieved.content, 'Enhanced message');
      expect(retrieved.replyToMessageId, 'msg_001');
      expect(retrieved.threadId, 'thread_001');
      expect(retrieved.isStarred, true);
      expect(retrieved.isForwarded, false);
      expect(retrieved.priority, MessagePriority.high);
      expect(retrieved.originalContent, 'Original content');
      expect(retrieved.metadata?['key'], 'value');
      expect(retrieved.deliveryReceipt?.deviceId, 'device_001');
      expect(retrieved.readReceipt?.readBy, 'user_001');
      expect(retrieved.reactions.length, 1);
      expect(retrieved.reactions.first.emoji, '👍');
      expect(retrieved.attachments.length, 1);
      expect(retrieved.attachments.first.name, 'photo.jpg');
      expect(retrieved.encryptionInfo?.algorithm, 'AES-256');
    });

    test('Save multiple messages and retrieve them sorted by timestamp', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final now = DateTime.now();
      final message1 = Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'First',
        timestamp: now.subtract(const Duration(hours: 2)),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      final message2 = Message(
        id: 'msg_002',
        chatId: 'chat_001',
        content: 'Second',
        timestamp: now.subtract(const Duration(hours: 1)),
        isFromMe: false,
        status: MessageStatus.delivered,
      );

      final message3 = Message(
        id: 'msg_003',
        chatId: 'chat_001',
        content: 'Third',
        timestamp: now,
        isFromMe: true,
        status: MessageStatus.sent,
      );

      // Save in random order
      await repository.saveMessage(message2);
      await repository.saveMessage(message3);
      await repository.saveMessage(message1);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 3);
      expect(messages[0].content, 'First');
      expect(messages[1].content, 'Second');
      expect(messages[2].content, 'Third');
    });

    test('Update message', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final message = Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Original content',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sending,
      );

      await repository.saveMessage(message);

      final updatedMessage = message.copyWith(status: MessageStatus.delivered);
      await repository.updateMessage(updatedMessage);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);
      expect(messages.first.status, MessageStatus.delivered);
    });

    test('Update EnhancedMessage with reactions', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final message = EnhancedMessage(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Message with reactions',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await repository.saveMessage(message);

      final updatedMessage = message.copyWith(
        reactions: [
          MessageReaction(
            emoji: '❤️',
            userId: 'user_001',
            reactedAt: DateTime.now(),
          ),
        ],
      );

      await repository.updateMessage(updatedMessage);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);
      final retrieved = messages.first as EnhancedMessage;
      expect(retrieved.reactions.length, 1);
      expect(retrieved.reactions.first.emoji, '❤️');
    });

    test('Delete message', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final message = Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'To be deleted',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await repository.saveMessage(message);
      expect(await repository.getMessages('chat_001'), hasLength(1));

      final deleted = await repository.deleteMessage('msg_001');
      expect(deleted, true);
      expect(await repository.getMessages('chat_001'), isEmpty);
    });

    test('Delete non-existent message returns false', () async {
      final repository = MessageRepository();
      final deleted = await repository.deleteMessage('non_existent');
      expect(deleted, false);
    });

    test('Clear messages for chat', () async {
      final repository = MessageRepository();

      // Create chats first (foreign key requirement)
      await createChat('chat_001');
      await createChat('chat_002');

      // Add messages to two different chats
      await repository.saveMessage(Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Chat 1 Message 1',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_002',
        chatId: 'chat_001',
        content: 'Chat 1 Message 2',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_003',
        chatId: 'chat_002',
        content: 'Chat 2 Message 1',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      // Clear chat_001
      await repository.clearMessages('chat_001');

      expect(await repository.getMessages('chat_001'), isEmpty);
      expect(await repository.getMessages('chat_002'), hasLength(1));
    });

    test('Get all messages', () async {
      final repository = MessageRepository();

      // Create chats first (foreign key requirement)
      await createChat('chat_001');
      await createChat('chat_002');

      await repository.saveMessage(Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Chat 1',
        timestamp: DateTime.now().subtract(const Duration(hours: 1)),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_002',
        chatId: 'chat_002',
        content: 'Chat 2',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      final allMessages = await repository.getAllMessages();
      expect(allMessages.length, 2);
      expect(allMessages[0].content, 'Chat 1');
      expect(allMessages[1].content, 'Chat 2');
    });

    test('Get messages for contact', () async {
      final repository = MessageRepository();

      // Create chats first (foreign key requirement)
      await createChat('public_key_001');
      await createChat('public_key_002');

      await repository.saveMessage(Message(
        id: 'msg_001',
        chatId: 'public_key_001',
        content: 'Message 1',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_002',
        chatId: 'public_key_002',
        content: 'Message 2',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      final messages = await repository.getMessagesForContact('public_key_001');
      expect(messages.length, 1);
      expect(messages.first.content, 'Message 1');
    });

    test('Get messages for non-existent chat returns empty list', () async {
      final repository = MessageRepository();
      final messages = await repository.getMessages('non_existent_chat');
      expect(messages, isEmpty);
    });

    test('EnhancedMessage with minimal fields', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      // Create EnhancedMessage with just one enhanced field set (isStarred)
      // This ensures it's saved and retrieved as EnhancedMessage
      final enhancedMessage = EnhancedMessage(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Starred message',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
        isStarred: true, // Set at least one enhanced field
      );

      await repository.saveMessage(enhancedMessage);

      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);

      final retrieved = messages.first as EnhancedMessage;
      expect(retrieved.isStarred, true);
      expect(retrieved.replyToMessageId, isNull);
      expect(retrieved.threadId, isNull);
      expect(retrieved.metadata, isNull);
      expect(retrieved.deliveryReceipt, isNull);
      expect(retrieved.readReceipt, isNull);
      expect(retrieved.reactions, isEmpty);
      expect(retrieved.attachments, isEmpty);
      expect(retrieved.encryptionInfo, isNull);
    });

    test('Update message preserves created_at timestamp', () async {
      final repository = MessageRepository();

      // Create chat first (foreign key requirement)
      await createChat('chat_001');

      final message = Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Original',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await repository.saveMessage(message);

      // Wait a bit to ensure timestamps differ
      await Future.delayed(const Duration(milliseconds: 10));

      final updatedMessage = message.copyWith(status: MessageStatus.delivered);
      await repository.updateMessage(updatedMessage);

      // The update should preserve the original created_at
      final messages = await repository.getMessages('chat_001');
      expect(messages.length, 1);
      expect(messages.first.status, MessageStatus.delivered);
    });

    test('Multiple chats isolation', () async {
      final repository = MessageRepository();

      // Create chats first (foreign key requirement)
      await createChat('chat_001');
      await createChat('chat_002');
      await createChat('chat_003');

      // Add messages to different chats
      await repository.saveMessage(Message(
        id: 'msg_001',
        chatId: 'chat_001',
        content: 'Chat 1',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_002',
        chatId: 'chat_002',
        content: 'Chat 2',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      await repository.saveMessage(Message(
        id: 'msg_003',
        chatId: 'chat_003',
        content: 'Chat 3',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      ));

      // Verify each chat has only its messages
      expect(await repository.getMessages('chat_001'), hasLength(1));
      expect(await repository.getMessages('chat_002'), hasLength(1));
      expect(await repository.getMessages('chat_003'), hasLength(1));

      expect((await repository.getMessages('chat_001')).first.content, 'Chat 1');
      expect((await repository.getMessages('chat_002')).first.content, 'Chat 2');
      expect((await repository.getMessages('chat_003')).first.content, 'Chat 3');
    });
  });
}
