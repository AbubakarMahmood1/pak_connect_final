import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'test_helpers/test_setup.dart';

void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;

  // Initialize test environment
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'chats_repository_sqlite',
    );
  });

  // Reset database before each test
  setUp(() async {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);
    await TestSetup.fullDatabaseReset();
  });

  tearDown(() {
    final severeErrors = logRecords
        .where((log) => log.level >= Level.SEVERE)
        .where(
          (log) =>
              !allowedSevere.any((pattern) => log.message.contains(pattern)),
        )
        .toList();
    expect(
      severeErrors,
      isEmpty,
      reason:
          'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
    );
  });

  group('ChatsRepository SQLite Tests', () {
    test('Mark chat as read - new chat', () async {
      final repo = ChatsRepository();
      const chatId = 'persistent_chat_alice_bob';

      // Mark as read (should create chat entry with 0 unread)
      await repo.markChatAsRead(chatId);

      // Verify unread count is 0
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );

      expect(rows.length, 1);
      expect(rows.first['unread_count'], 0);
      expect(rows.first['chat_id'], chatId);
    });

    test('Mark chat as read - existing chat with unread messages', () async {
      final repo = ChatsRepository();
      const chatId = 'persistent_chat_alice_bob';

      // First increment unread count
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);

      // Verify count is 3
      final db = await DatabaseHelper.database;
      var rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
      expect(rows.first['unread_count'], 3);

      // Mark as read
      await repo.markChatAsRead(chatId);

      // Verify count is now 0
      rows = await db.query('chats', where: 'chat_id = ?', whereArgs: [chatId]);
      expect(rows.first['unread_count'], 0);
    });

    test('Increment unread count - new chat', () async {
      final repo = ChatsRepository();
      const chatId = 'persistent_chat_alice_bob';

      // Increment unread count (should create chat with count = 1)
      await repo.incrementUnreadCount(chatId);

      // Verify
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );

      expect(rows.length, 1);
      expect(rows.first['unread_count'], 1);
    });

    test('Increment unread count - existing chat', () async {
      final repo = ChatsRepository();
      const chatId = 'persistent_chat_alice_bob';

      // Increment multiple times
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);
      await repo.incrementUnreadCount(chatId);

      // Verify count is 5
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );

      expect(rows.first['unread_count'], 5);
    });

    test('Get total unread count - no chats', () async {
      final repo = ChatsRepository();

      final total = await repo.getTotalUnreadCount();
      expect(total, 0);
    });

    test('Get total unread count - multiple chats', () async {
      final repo = ChatsRepository();

      // Create multiple chats with unread counts
      await repo.incrementUnreadCount('chat1');
      await repo.incrementUnreadCount('chat1');
      await repo.incrementUnreadCount('chat1'); // chat1: 3

      await repo.incrementUnreadCount('chat2');
      await repo.incrementUnreadCount('chat2'); // chat2: 2

      await repo.incrementUnreadCount('chat3'); // chat3: 1

      // Mark one as read
      await repo.markChatAsRead('chat2'); // chat2: 0

      final total = await repo.getTotalUnreadCount();
      expect(total, 4); // 3 + 0 + 1 = 4
    });

    test('Update contact last seen', () async {
      final repo = ChatsRepository();
      final contactRepo = ContactRepository();
      const publicKey = 'alice_public_key_123';

      // Create contact first (foreign key constraint)
      await contactRepo.saveContact(publicKey, 'Alice');

      // Update last seen
      await repo.updateContactLastSeen(publicKey);

      // Verify in database
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'contact_last_seen',
        where: 'public_key = ?',
        whereArgs: [publicKey],
      );

      expect(rows.length, 1);
      expect(rows.first['public_key'], publicKey);
      expect(rows.first['was_online'], 1);
      expect(rows.first['last_seen_at'], isA<int>());

      // Verify timestamp is recent (within last 5 seconds)
      final lastSeenAt = rows.first['last_seen_at'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(now - lastSeenAt, lessThan(5000));
    });

    test('Update contact last seen - multiple updates', () async {
      final repo = ChatsRepository();
      final contactRepo = ContactRepository();
      const publicKey = 'alice_public_key_123';

      // Create contact first (foreign key constraint)
      await contactRepo.saveContact(publicKey, 'Alice');

      // Update multiple times
      await repo.updateContactLastSeen(publicKey);
      await Future.delayed(const Duration(milliseconds: 100));

      final firstTimestamp = DateTime.now().millisecondsSinceEpoch;

      await Future.delayed(const Duration(milliseconds: 100));
      await repo.updateContactLastSeen(publicKey);

      // Verify only one row exists (upsert)
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'contact_last_seen',
        where: 'public_key = ?',
        whereArgs: [publicKey],
      );

      expect(rows.length, 1);

      // Verify timestamp was updated
      final lastSeenAt = rows.first['last_seen_at'] as int;
      expect(lastSeenAt, greaterThan(firstTimestamp));
    });

    test('Store device mapping', () async {
      final repo = ChatsRepository();
      const deviceUuid = 'device-uuid-123-456';
      const publicKey = 'alice_public_key_123';

      // Store mapping
      await repo.storeDeviceMapping(deviceUuid, publicKey);

      // Verify in database
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'device_mappings',
        where: 'device_uuid = ?',
        whereArgs: [deviceUuid],
      );

      expect(rows.length, 1);
      expect(rows.first['device_uuid'], deviceUuid);
      expect(rows.first['public_key'], publicKey);
      expect(rows.first['last_seen'], isA<int>());
    });

    test('Store device mapping - null deviceUuid', () async {
      final repo = ChatsRepository();
      const publicKey = 'alice_public_key_123';

      // Should not throw, just return early
      await repo.storeDeviceMapping(null, publicKey);

      // Verify nothing was stored
      final db = await DatabaseHelper.database;
      final rows = await db.query('device_mappings');
      expect(rows.length, 0);
    });

    test('Store device mapping - update existing', () async {
      final repo = ChatsRepository();
      const deviceUuid = 'device-uuid-123-456';
      const publicKey1 = 'alice_public_key_123';
      const publicKey2 = 'bob_public_key_456';

      // Store first mapping
      await repo.storeDeviceMapping(deviceUuid, publicKey1);

      // Update with new public key
      await repo.storeDeviceMapping(deviceUuid, publicKey2);

      // Verify only one row exists with updated public key
      final db = await DatabaseHelper.database;
      final rows = await db.query(
        'device_mappings',
        where: 'device_uuid = ?',
        whereArgs: [deviceUuid],
      );

      expect(rows.length, 1);
      expect(rows.first['public_key'], publicKey2);
    });

    test('Get contacts without chats', () async {
      final repo = ChatsRepository();
      final contactRepo = ContactRepository();
      final messageRepo = MessageRepository();

      await contactRepo.saveContact('alice_key', 'Alice');
      await contactRepo.saveContact('bob_key', 'Bob');
      await contactRepo.saveContact('charlie_key', 'Charlie');

      final now = DateTime.now();
      await messageRepo.saveMessage(
        Message(
          id: MessageId('msg1'),
          chatId: 'alice_key',
          content: 'Hello from Alice',
          timestamp: now,
          isFromMe: false,
          status: MessageStatus.delivered,
        ),
      );
      await messageRepo.saveMessage(
        Message(
          id: MessageId('msg2'),
          chatId: 'bob_key',
          content: 'Hello from Bob',
          timestamp: now,
          isFromMe: false,
          status: MessageStatus.delivered,
        ),
      );

      final contactsWithoutChats = await repo.getContactsWithoutChats();
      final publicKeys = contactsWithoutChats.map((c) => c.publicKey).toList();

      expect(publicKeys, contains('charlie_key'));
      expect(publicKeys, isNot(contains('alice_key')));
      expect(publicKeys, isNot(contains('bob_key')));
    });

    test('getAllChats returns empty list when no messages', () async {
      final repo = ChatsRepository();

      final chats = await repo.getAllChats();
      expect(chats, isEmpty);
    });

    test('Multiple chats with different unread counts', () async {
      final repo = ChatsRepository();

      // Create multiple chats with different unread counts
      const chat1 = 'persistent_chat_alice_bob';
      const chat2 = 'persistent_chat_charlie_dave';
      const chat3 = 'persistent_chat_eve_frank';

      // Chat 1: 5 unread
      for (int i = 0; i < 5; i++) {
        await repo.incrementUnreadCount(chat1);
      }

      // Chat 2: 2 unread
      for (int i = 0; i < 2; i++) {
        await repo.incrementUnreadCount(chat2);
      }

      // Chat 3: 0 unread (mark as read)
      await repo.incrementUnreadCount(chat3);
      await repo.markChatAsRead(chat3);

      // Verify total
      final total = await repo.getTotalUnreadCount();
      expect(total, 7); // 5 + 2 + 0 = 7

      // Verify individual counts
      final db = await DatabaseHelper.database;

      final chat1Rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chat1],
      );
      expect(chat1Rows.first['unread_count'], 5);

      final chat2Rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chat2],
      );
      expect(chat2Rows.first['unread_count'], 2);

      final chat3Rows = await db.query(
        'chats',
        where: 'chat_id = ?',
        whereArgs: [chat3],
      );
      expect(chat3Rows.first['unread_count'], 0);
    });

    test('Last seen data persists across multiple contacts', () async {
      final repo = ChatsRepository();
      final contactRepo = ContactRepository();

      // Create contacts first (foreign key constraint)
      await contactRepo.saveContact('alice_key', 'Alice');
      await contactRepo.saveContact('bob_key', 'Bob');
      await contactRepo.saveContact('charlie_key', 'Charlie');

      // Update last seen for multiple contacts
      await repo.updateContactLastSeen('alice_key');
      await Future.delayed(const Duration(milliseconds: 50));

      await repo.updateContactLastSeen('bob_key');
      await Future.delayed(const Duration(milliseconds: 50));

      await repo.updateContactLastSeen('charlie_key');

      // Verify all exist
      final db = await DatabaseHelper.database;
      final rows = await db.query('contact_last_seen');

      expect(rows.length, 3);

      final publicKeys = rows.map((r) => r['public_key']).toSet();
      expect(publicKeys, containsAll(['alice_key', 'bob_key', 'charlie_key']));
    });

    test('Device mappings support multiple devices', () async {
      final repo = ChatsRepository();

      // Store multiple device mappings
      await repo.storeDeviceMapping('device1', 'alice_key');
      await repo.storeDeviceMapping('device2', 'bob_key');
      await repo.storeDeviceMapping('device3', 'charlie_key');

      // Verify all exist
      final db = await DatabaseHelper.database;
      final rows = await db.query('device_mappings');

      expect(rows.length, 3);

      final mappings = {
        for (var row in rows)
          row['device_uuid'] as String: row['public_key'] as String,
      };

      expect(mappings['device1'], 'alice_key');
      expect(mappings['device2'], 'bob_key');
      expect(mappings['device3'], 'charlie_key');
    });
  });
}
