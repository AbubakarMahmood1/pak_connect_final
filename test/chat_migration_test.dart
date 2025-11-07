import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/services/chat_migration_service.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/domain/entities/message.dart';
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

  group('ChatMigrationService Tests', () {
    late ChatMigrationService migrationService;
    late MessageRepository messageRepository;
    late ChatsRepository chatsRepository;

    setUp(() {
      migrationService = ChatMigrationService();
      messageRepository = MessageRepository();
      chatsRepository = ChatsRepository();
    });

    // Helper to create test messages in an ephemeral chat
    Future<void> createEphemeralChat(
      String ephemeralId,
      int messageCount,
    ) async {
      await chatsRepository.markChatAsRead(ephemeralId); // Create chat entry

      for (int i = 0; i < messageCount; i++) {
        final message = Message(
          id: 'msg_${ephemeralId}_$i',
          chatId: ephemeralId,
          content: 'Test message $i',
          timestamp: DateTime.now().add(Duration(seconds: i)),
          isFromMe: i % 2 == 0,
          status: MessageStatus.delivered,
        );
        await messageRepository.saveMessage(message);
      }
    }

    test('Migrate chat with messages - success', () async {
      const ephemeralId = 'temp_abc123';
      const persistentKey = 'persistent_key_xyz789';

      // Create ephemeral chat with messages
      await createEphemeralChat(ephemeralId, 5);

      // Verify messages exist in ephemeral chat
      final beforeMessages = await messageRepository.getMessages(ephemeralId);
      expect(beforeMessages.length, 5);

      // Perform migration
      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
        contactName: 'Alice',
      );

      expect(success, true);

      // Verify messages moved to persistent chat
      final afterMessages = await messageRepository.getMessages(persistentKey);
      expect(afterMessages.length, 5);
      expect(afterMessages[0].content, 'Test message 0');
      expect(afterMessages[4].content, 'Test message 4');

      // Verify old ephemeral chat is deleted
      final ephemeralMessages = await messageRepository.getMessages(
        ephemeralId,
      );
      expect(ephemeralMessages.isEmpty, true);

      // Verify chat metadata updated
      final db = await DatabaseHelper.database;
      final chatRows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [persistentKey],
      );

      expect(chatRows.length, 1);
      // Note: contact_public_key stays null to avoid foreign key constraints
      // The actual contact linkage happens when the contact is created
      expect(chatRows.first['contact_public_key'], null);
      expect(chatRows.first['contact_name'], 'Alice');
      expect(chatRows.first['last_message'], 'Test message 4');
    });

    test('Migrate empty chat - no migration needed', () async {
      const ephemeralId = 'temp_empty123';
      const persistentKey = 'persistent_key_empty789';

      // Create empty chat (no messages)
      await chatsRepository.markChatAsRead(ephemeralId);

      // Perform migration
      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      expect(success, false); // No migration needed

      // Verify no messages in persistent chat
      final messages = await messageRepository.getMessages(persistentKey);
      expect(messages.isEmpty, true);
    });

    test('Migrate chat preserves message order', () async {
      const ephemeralId = 'temp_order123';
      const persistentKey = 'persistent_key_order789';

      // Create ephemeral chat with 10 messages
      await createEphemeralChat(ephemeralId, 10);

      // Perform migration
      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      expect(success, true);

      // Verify message order preserved
      final messages = await messageRepository.getMessages(persistentKey);
      expect(messages.length, 10);

      for (int i = 0; i < 10; i++) {
        expect(messages[i].content, 'Test message $i');
      }
    });

    test('Migrate chat preserves message properties', () async {
      const ephemeralId = 'temp_props123';
      const persistentKey = 'persistent_key_props789';

      await chatsRepository.markChatAsRead(ephemeralId);

      // Create messages with different properties
      final sentMessage = Message(
        id: 'sent_msg',
        chatId: ephemeralId,
        content: 'Sent message',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      final receivedMessage = Message(
        id: 'received_msg',
        chatId: ephemeralId,
        content: 'Received message',
        timestamp: DateTime.now().add(const Duration(seconds: 1)),
        isFromMe: false,
        status: MessageStatus.delivered,
      );

      await messageRepository.saveMessage(sentMessage);
      await messageRepository.saveMessage(receivedMessage);

      // Perform migration
      await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      // Verify properties preserved
      final messages = await messageRepository.getMessages(persistentKey);
      expect(messages.length, 2);

      final migratedSent = messages.firstWhere((m) => m.id == 'sent_msg');
      expect(migratedSent.isFromMe, true);
      expect(migratedSent.status, MessageStatus.sent);
      expect(migratedSent.content, 'Sent message');

      final migratedReceived = messages.firstWhere(
        (m) => m.id == 'received_msg',
      );
      expect(migratedReceived.isFromMe, false);
      expect(migratedReceived.status, MessageStatus.delivered);
      expect(migratedReceived.content, 'Received message');
    });

    test('Merge with existing persistent chat - no duplicates', () async {
      const ephemeralId = 'temp_merge123';
      const persistentKey = 'persistent_key_merge789';

      // Create ephemeral chat with messages
      await createEphemeralChat(ephemeralId, 3);

      // Create persistent chat with existing messages
      await chatsRepository.markChatAsRead(persistentKey);
      final existingMessage = Message(
        id: 'existing_msg',
        chatId: persistentKey,
        content: 'Existing message',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.delivered,
      );
      await messageRepository.saveMessage(existingMessage);

      // Note: We can't directly test duplicate handling via message repository
      // because the UNIQUE constraint prevents inserting duplicate IDs.
      // The deduplication logic in migration handles edge cases where
      // messages might exist in both chats through other means.

      // Perform migration
      final success = await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      expect(success, true);

      // Verify merged correctly
      final messages = await messageRepository.getMessages(persistentKey);
      expect(messages.length, 4); // 1 existing + 3 ephemeral = 4

      // Verify all messages are present
      final messageIds = messages.map((m) => m.id).toList();
      expect(messageIds.contains('existing_msg'), true);
    });

    test('needsMigration - detects temp chats with messages', () async {
      const tempChat = 'temp_needs_migration';
      const persistentChat = 'persistent_no_migration';

      // Create temp chat with messages
      await createEphemeralChat(tempChat, 2);

      // Create persistent chat with messages
      await chatsRepository.markChatAsRead(persistentChat);
      final msg = Message(
        id: 'persistent_msg',
        chatId: persistentChat,
        content: 'Test',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );
      await messageRepository.saveMessage(msg);

      // Test
      expect(await migrationService.needsMigration(tempChat), true);
      expect(await migrationService.needsMigration(persistentChat), false);
      expect(
        await migrationService.needsMigration('temp_empty'),
        false,
      ); // No messages
    });

    test(
      'getChatsNeedingMigration - returns all temp chats with messages',
      () async {
        // Create multiple temp chats
        await createEphemeralChat('temp_1', 2);
        await createEphemeralChat('temp_2', 3);
        await chatsRepository.markChatAsRead('temp_3'); // Empty temp chat

        // Create persistent chat (should be ignored)
        await chatsRepository.markChatAsRead('persistent_chat');
        final msg = Message(
          id: 'persistent_msg',
          chatId: 'persistent_chat',
          content: 'Test',
          timestamp: DateTime.now(),
          isFromMe: true,
          status: MessageStatus.sent,
        );
        await messageRepository.saveMessage(msg);

        // Get chats needing migration
        final chatsNeedingMigration = await migrationService
            .getChatsNeedingMigration();

        expect(chatsNeedingMigration.length, 2);
        expect(chatsNeedingMigration.contains('temp_1'), true);
        expect(chatsNeedingMigration.contains('temp_2'), true);
        expect(chatsNeedingMigration.contains('temp_3'), false); // Empty
        expect(
          chatsNeedingMigration.contains('persistent_chat'),
          false,
        ); // Not temp
      },
    );

    test('Batch migration - migrate multiple chats', () async {
      // Create multiple ephemeral chats
      await createEphemeralChat('temp_batch_1', 2);
      await createEphemeralChat('temp_batch_2', 3);
      await createEphemeralChat('temp_batch_3', 1);

      // Perform batch migration
      final results = await migrationService.migrateBatchChats({
        'temp_batch_1': 'persistent_batch_1',
        'temp_batch_2': 'persistent_batch_2',
        'temp_batch_3': 'persistent_batch_3',
      });

      // Verify all migrations succeeded
      expect(results.length, 3);
      expect(results['temp_batch_1'], true);
      expect(results['temp_batch_2'], true);
      expect(results['temp_batch_3'], true);

      // Verify messages migrated
      expect(
        (await messageRepository.getMessages('persistent_batch_1')).length,
        2,
      );
      expect(
        (await messageRepository.getMessages('persistent_batch_2')).length,
        3,
      );
      expect(
        (await messageRepository.getMessages('persistent_batch_3')).length,
        1,
      );

      // Verify old chats deleted
      expect(
        (await messageRepository.getMessages('temp_batch_1')).isEmpty,
        true,
      );
      expect(
        (await messageRepository.getMessages('temp_batch_2')).isEmpty,
        true,
      );
      expect(
        (await messageRepository.getMessages('temp_batch_3')).isEmpty,
        true,
      );
    });

    test('Migration updates last_message_time correctly', () async {
      const ephemeralId = 'temp_time123';
      const persistentKey = 'persistent_key_time789';

      // Create chat with messages at different times
      await chatsRepository.markChatAsRead(ephemeralId);

      final now = DateTime.now();
      final msg1 = Message(
        id: 'msg_1',
        chatId: ephemeralId,
        content: 'First',
        timestamp: now.subtract(const Duration(hours: 2)),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      final msg2 = Message(
        id: 'msg_2',
        chatId: ephemeralId,
        content: 'Second',
        timestamp: now.subtract(const Duration(hours: 1)),
        isFromMe: false,
        status: MessageStatus.delivered,
      );

      final msg3 = Message(
        id: 'msg_3',
        chatId: ephemeralId,
        content: 'Latest',
        timestamp: now,
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await messageRepository.saveMessage(msg1);
      await messageRepository.saveMessage(msg2);
      await messageRepository.saveMessage(msg3);

      // Perform migration
      await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      // Verify chat metadata
      final db = await DatabaseHelper.database;
      final chatRows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [persistentKey],
      );

      expect(chatRows.first['last_message'], 'Latest');
      expect(chatRows.first['last_message_time'], now.millisecondsSinceEpoch);
    });

    test('Migration with special characters in content', () async {
      const ephemeralId = 'temp_special123';
      const persistentKey = 'persistent_key_special789';

      await chatsRepository.markChatAsRead(ephemeralId);

      final specialMessage = Message(
        id: 'special_msg',
        chatId: ephemeralId,
        content: '🔒 Test émojis & spëcial çhars: "quotes" \'apostrophes\' 你好',
        timestamp: DateTime.now(),
        isFromMe: true,
        status: MessageStatus.sent,
      );

      await messageRepository.saveMessage(specialMessage);

      // Perform migration
      await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      // Verify content preserved
      final messages = await messageRepository.getMessages(persistentKey);
      expect(messages.length, 1);
      expect(
        messages.first.content,
        '🔒 Test émojis & spëcial çhars: "quotes" \'apostrophes\' 你好',
      );
    });

    test('Migration cleans up chat entry from chats table', () async {
      const ephemeralId = 'temp_cleanup123';
      const persistentKey = 'persistent_key_cleanup789';

      // Create ephemeral chat
      await createEphemeralChat(ephemeralId, 3);

      // Verify ephemeral chat exists in chats table
      final db = await DatabaseHelper.database;
      var ephemeralChats = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [ephemeralId],
      );
      expect(ephemeralChats.length, 1);

      // Perform migration
      await migrationService.migrateChatToPersistentId(
        ephemeralId: ephemeralId,
        persistentPublicKey: persistentKey,
      );

      // Verify ephemeral chat deleted from chats table
      ephemeralChats = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [ephemeralId],
      );
      expect(ephemeralChats.isEmpty, true);

      // Verify persistent chat exists
      final persistentChats = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [persistentKey],
      );
      expect(persistentChats.length, 1);
    });
  });
}
