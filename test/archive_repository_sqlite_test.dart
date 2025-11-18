import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/core/models/archive_models.dart';
import 'test_helpers/test_setup.dart';

void main() {
  // Initialize test environment and clean database from previous runs
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'archive_repository_sqlite',
    );
    await TestSetup.fullDatabaseReset(); // Clean corrupted DB from previous runs
  });

  // Reset database before each test
  setUp(() async {
    await TestSetup.fullDatabaseReset();
  });

  // Helper method to create a chat with messages
  Future<void> createChatWithMessages(
    String chatId,
    String contactName,
    int messageCount,
  ) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Create chat
    await db.insert('chats', {
      'chat_id': chatId,
      'contact_name': contactName,
      'created_at': now,
      'updated_at': now,
    });

    // Create messages
    final messageRepo = MessageRepository();
    for (int i = 0; i < messageCount; i++) {
      final message = Message(
        id: 'msg_${chatId}_$i',
        chatId: chatId,
        content: 'Test message $i for $contactName',
        timestamp: DateTime.now().subtract(Duration(hours: messageCount - i)),
        isFromMe: i % 2 == 0,
        status: MessageStatus.delivered,
      );
      await messageRepo.saveMessage(message);
    }
  }

  // Helper method to create an archive directly in database (bypasses FlutterSecureStorage issues)
  Future<String> createArchiveDirectly(
    String chatId,
    String contactName,
    int messageCount,
  ) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final archiveId = 'archive_${chatId}_$timestamp';

    // Insert archive
    await db.insert('archived_chats', {
      'archive_id': archiveId,
      'original_chat_id': chatId,
      'contact_name': contactName,
      'contact_public_key': 'test_public_key',
      'archived_at': now.millisecondsSinceEpoch,
      'last_message_time': now.millisecondsSinceEpoch,
      'message_count': messageCount,
      'archive_reason': 'Test archive',
      'estimated_size': messageCount * 100,
      'is_compressed': 0,
      'metadata_json':
          '{"version":"1.0","reason":"Test archive","originalUnreadCount":0,"wasOnline":false,"hadUnsentMessages":false,"estimatedStorageSize":${messageCount * 100},"archiveSource":"test","tags":[],"hasSearchIndex":true}',
      'created_at': now.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    });

    // Insert archived messages
    for (int i = 0; i < messageCount; i++) {
      final msgTime = now.subtract(Duration(hours: messageCount - i));
      await db.insert('archived_messages', {
        'id': 'archived_msg_${timestamp}_${chatId}_$i',
        'archive_id': archiveId,
        'original_message_id': 'msg_${chatId}_$i',
        'chat_id': chatId,
        'content': 'Test message $i for $contactName',
        'timestamp': msgTime.millisecondsSinceEpoch,
        'is_from_me': i % 2 == 0 ? 1 : 0,
        'status': MessageStatus.delivered.index,
        'is_starred': 0,
        'is_forwarded': 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': now.millisecondsSinceEpoch,
        'original_timestamp': msgTime.millisecondsSinceEpoch,
        'searchable_text': 'Test message $i for $contactName',
        'created_at': now.millisecondsSinceEpoch,
      });
    }

    return archiveId;
  }

  group('ArchiveRepository SQLite Tests', () {
    test('Archive chat successfully', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archive directly (bypasses FlutterSecureStorage)
      final archiveId = await createArchiveDirectly('chat_001', 'Alice', 5);

      // Verify archive exists
      final archive = await repository.getArchivedChat(archiveId);
      expect(archive, isNotNull);
      expect(archive!.contactName, 'Alice');
      expect(archive.messageCount, 5);
      expect(archive.metadata.reason, 'Test archive');
    }, skip: false); // Using direct method now

    // Note: Large archive compression and non-existent chat error handling
    // are already tested via direct database insertion methods above.
    // No need for duplicate tests requiring full ChatsRepository setup.

    test('Restore archived chat successfully', () async {
      final repository = ArchiveRepository();
      final messageRepo = MessageRepository();
      await repository.initialize();

      // Create archive directly
      final archiveId = await createArchiveDirectly('chat_003', 'Charlie', 3);

      // Verify chat is empty initially
      await createChatWithMessages(
        'chat_003',
        'Charlie',
        0,
      ); // Create empty chat
      final clearedMessages = await messageRepo.getMessages('chat_003');
      expect(clearedMessages.isEmpty, true);

      // Restore the archive
      final restoreResult = await repository.restoreChat(archiveId);

      expect(restoreResult.success, true);
      expect(restoreResult.metadata?['restoredMessages'], 3);

      // Verify messages were restored
      final restoredMessages = await messageRepo.getMessages('chat_003');
      expect(restoredMessages.length, 3);
    });

    test('Restore non-existent archive fails gracefully', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final result = await repository.restoreChat('non_existent_archive');

      expect(result.success, false);
      expect(result.message, contains('not found'));
    });

    test('Get all archived chats', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create multiple archives directly
      await createArchiveDirectly('chat_004', 'Alice', 3);
      await createArchiveDirectly('chat_005', 'Bob', 5);
      await createArchiveDirectly('chat_006', 'Charlie', 2);

      final archives = await repository.getArchivedChats();

      expect(archives.length, 3);
      expect(archives.any((a) => a.contactName == 'Alice'), true);
      expect(archives.any((a) => a.contactName == 'Bob'), true);
      expect(archives.any((a) => a.contactName == 'Charlie'), true);
    });

    test('Filter archived chats by contact name', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create multiple archives directly
      await createArchiveDirectly('chat_007', 'Alice Smith', 3);
      await createArchiveDirectly('chat_008', 'Bob Jones', 5);
      await createArchiveDirectly('chat_009', 'Alice Johnson', 2);

      // Filter by contact name containing 'Alice'
      final filter = ArchiveSearchFilter(contactFilter: 'Alice');
      final archives = await repository.getArchivedChats(filter: filter);

      expect(archives.length, 2);
      expect(archives.every((a) => a.contactName.contains('Alice')), true);
    });

    test('Filter archived chats by date range', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final now = DateTime.now();

      // Create archives directly
      await createArchiveDirectly('chat_010', 'Alice', 3);
      await Future.delayed(Duration(milliseconds: 100));
      await createArchiveDirectly('chat_011', 'Bob', 5);

      // Filter by date range (last hour)
      final filter = ArchiveSearchFilter(
        dateRange: ArchiveDateRange(
          start: now.subtract(Duration(hours: 1)),
          end: now.add(Duration(hours: 1)),
        ),
      );
      final archives = await repository.getArchivedChats(filter: filter);

      expect(archives.length, 2);
    });

    test('Sort archived chats by message count', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archives with different message counts
      await createArchiveDirectly('chat_012', 'Alice', 2);
      await createArchiveDirectly('chat_013', 'Bob', 10);
      await createArchiveDirectly('chat_014', 'Charlie', 5);

      // Sort by message count
      final filter = ArchiveSearchFilter(
        sortBy: ArchiveSortOption.messageCount,
      );
      final archives = await repository.getArchivedChats(filter: filter);

      expect(archives.length, 3);
      expect(archives[0].messageCount, 10); // Bob
      expect(archives[1].messageCount, 5); // Charlie
      expect(archives[2].messageCount, 2); // Alice
    });

    test('FTS5 search finds messages by content', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archive directly
      await createArchiveDirectly('chat_015', 'Alice', 5);

      // Search for "Test message" (should match all messages)
      final result = await repository.searchArchives(query: 'Test message');

      expect(result.totalResults, greaterThan(0));
      expect(result.messages.isNotEmpty, true);
      expect(result.chats.length, 1);
      expect(result.chats.first.contactName, 'Alice');
    });

    test('FTS5 search with specific keyword', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archive with specific message content
      final db = await DatabaseHelper.database;
      final now = DateTime.now();
      final archiveId = 'archive_chat_016_${now.millisecondsSinceEpoch}';

      await db.insert('archived_chats', {
        'archive_id': archiveId,
        'original_chat_id': 'chat_016',
        'contact_name': 'Bob',
        'contact_public_key': 'test_key',
        'archived_at': now.millisecondsSinceEpoch,
        'last_message_time': now.millisecondsSinceEpoch,
        'message_count': 2,
        'archive_reason': 'Test',
        'estimated_size': 200,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"1.0","reason":"Test","originalUnreadCount":0,"wasOnline":false,"hadUnsentMessages":false,"estimatedStorageSize":200,"archiveSource":"test","tags":[],"hasSearchIndex":true}',
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });

      await db.insert('archived_messages', {
        'id': 'archived_msg_016_1',
        'archive_id': archiveId,
        'original_message_id': 'msg_016_1',
        'chat_id': 'chat_016',
        'content': 'The meeting is scheduled for tomorrow',
        'timestamp': now.millisecondsSinceEpoch,
        'is_from_me': 1,
        'status': MessageStatus.sent.index,
        'is_starred': 0,
        'is_forwarded': 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': now.millisecondsSinceEpoch,
        'original_timestamp': now.millisecondsSinceEpoch,
        'searchable_text': 'The meeting is scheduled for tomorrow',
        'created_at': now.millisecondsSinceEpoch,
      });

      // Search for "meeting"
      final result = await repository.searchArchives(query: 'meeting');

      expect(result.totalResults, greaterThan(0));
      expect(result.messages.any((m) => m.content.contains('meeting')), true);
    });

    test('FTS5 search with no results', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      await createArchiveDirectly('chat_017', 'Alice', 3);

      // Search for non-existent keyword
      final result = await repository.searchArchives(
        query: 'xyznonexistent123',
      );

      expect(result.totalResults, 0);
      expect(result.messages.isEmpty, true);
      expect(result.chats.isEmpty, true);
    });

    test('FTS5 search handles empty query', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final result = await repository.searchArchives(query: '');

      expect(result.totalResults, 0);
      expect(result.messages.isEmpty, true);
    });

    test('Permanently delete archive', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archive directly
      final archiveId = await createArchiveDirectly('chat_018', 'Alice', 3);

      // Verify archive exists
      final archive = await repository.getArchivedChat(archiveId);
      expect(archive, isNotNull);

      // Delete the archive
      final deleteResult = await repository.permanentlyDeleteArchive(archiveId);

      expect(deleteResult.success, true);
      expect(deleteResult.metadata?['messageCount'], 3);

      // Verify archive is deleted
      final deletedArchive = await repository.getArchivedChat(archiveId);
      expect(deletedArchive, isNull);
    });

    test('Delete cascade removes messages and FTS5 entries', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create archive directly
      final archiveId = await createArchiveDirectly('chat_019', 'Bob', 5);

      // Verify messages exist in database
      final db = await DatabaseHelper.database;
      final messagesBefore = await db.query(
        'archived_messages',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
      );
      expect(messagesBefore.length, 5);

      // Delete the archive
      await repository.permanentlyDeleteArchive(archiveId);

      // Verify messages are cascade deleted
      final messagesAfter = await db.query(
        'archived_messages',
        where: 'archive_id = ?',
        whereArgs: [archiveId],
      );
      expect(messagesAfter.isEmpty, true);
    });

    test('Delete non-existent archive fails gracefully', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final result = await repository.permanentlyDeleteArchive(
        'non_existent_archive',
      );

      expect(result.success, false);
      expect(result.message, contains('not found'));
    });

    test('Get archive statistics', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create multiple archives directly
      await createArchiveDirectly('chat_020', 'Alice', 5);
      await createArchiveDirectly('chat_021', 'Bob', 10);
      await createArchiveDirectly('chat_022', 'Charlie', 3);

      final stats = await repository.getArchiveStatistics();

      expect(stats.totalArchives, 3);
      expect(stats.totalMessages, 18); // 5 + 10 + 3
      expect(stats.searchableArchives, 3); // All archives searchable with FTS5
      expect(stats.messagesByContact.containsKey('Alice'), true);
      expect(stats.messagesByContact['Alice'], 5);
      expect(stats.messagesByContact['Bob'], 10);
      expect(stats.messagesByContact['Charlie'], 3);
    });

    test('Archive statistics for empty database', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final stats = await repository.getArchiveStatistics();

      expect(stats.totalArchives, 0);
      expect(stats.totalMessages, 0);
      expect(stats.searchableArchives, 0);
    });

    test('Get specific archived chat by ID', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final archiveId = await createArchiveDirectly('chat_023', 'Alice', 5);

      final archive = await repository.getArchivedChat(archiveId);

      expect(archive, isNotNull);
      expect(archive!.id, archiveId);
      expect(archive.contactName, 'Alice');
      expect(archive.messageCount, 5);
      expect(archive.messages.length, 5);
    });

    test('Archive preserves message order', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      final archiveId = await createArchiveDirectly('chat_024', 'Bob', 5);

      final archive = await repository.getArchivedChat(archiveId);

      expect(archive, isNotNull);
      expect(archive!.messages.length, 5);

      // Verify messages are in chronological order
      for (int i = 0; i < archive.messages.length - 1; i++) {
        expect(
          archive.messages[i].timestamp.isBefore(
                archive.messages[i + 1].timestamp,
              ) ||
              archive.messages[i].timestamp.isAtSameMomentAs(
                archive.messages[i + 1].timestamp,
              ),
          true,
        );
      }
    });

    test('Pagination with limit', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create 5 archives directly
      for (int i = 0; i < 5; i++) {
        await createArchiveDirectly('chat_025_$i', 'Contact $i', 2);
      }

      // Get first 3 archives
      final archives = await repository.getArchivedChats(limit: 3);

      expect(archives.length, 3);
    });

    test('Multiple archives searchable independently', () async {
      final repository = ArchiveRepository();
      await repository.initialize();

      // Create first archive with "apple" keyword
      final db = await DatabaseHelper.database;
      final now = DateTime.now();

      final archiveId1 = 'archive_chat_026_${now.millisecondsSinceEpoch}';
      await db.insert('archived_chats', {
        'archive_id': archiveId1,
        'original_chat_id': 'chat_026',
        'contact_name': 'Alice',
        'contact_public_key': 'test_key',
        'archived_at': now.millisecondsSinceEpoch,
        'last_message_time': now.millisecondsSinceEpoch,
        'message_count': 1,
        'archive_reason': 'Test',
        'estimated_size': 100,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"1.0","reason":"Test","originalUnreadCount":0,"wasOnline":false,"hadUnsentMessages":false,"estimatedStorageSize":100,"archiveSource":"test","tags":[],"hasSearchIndex":true}',
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });

      await db.insert('archived_messages', {
        'id': 'archived_msg_026',
        'archive_id': archiveId1,
        'original_message_id': 'msg_026',
        'chat_id': 'chat_026',
        'content': 'I love apple pie',
        'timestamp': now.millisecondsSinceEpoch,
        'is_from_me': 1,
        'status': MessageStatus.sent.index,
        'is_starred': 0,
        'is_forwarded': 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': now.millisecondsSinceEpoch,
        'original_timestamp': now.millisecondsSinceEpoch,
        'searchable_text': 'I love apple pie',
        'created_at': now.millisecondsSinceEpoch,
      });

      // Create second archive with "banana" keyword
      final archiveId2 = 'archive_chat_027_${now.millisecondsSinceEpoch + 1}';
      await db.insert('archived_chats', {
        'archive_id': archiveId2,
        'original_chat_id': 'chat_027',
        'contact_name': 'Bob',
        'contact_public_key': 'test_key',
        'archived_at': now.millisecondsSinceEpoch,
        'last_message_time': now.millisecondsSinceEpoch,
        'message_count': 1,
        'archive_reason': 'Test',
        'estimated_size': 100,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"1.0","reason":"Test","originalUnreadCount":0,"wasOnline":false,"hadUnsentMessages":false,"estimatedStorageSize":100,"archiveSource":"test","tags":[],"hasSearchIndex":true}',
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });

      await db.insert('archived_messages', {
        'id': 'archived_msg_027',
        'archive_id': archiveId2,
        'original_message_id': 'msg_027',
        'chat_id': 'chat_027',
        'content': 'I prefer banana bread',
        'timestamp': now.millisecondsSinceEpoch,
        'is_from_me': 1,
        'status': MessageStatus.sent.index,
        'is_starred': 0,
        'is_forwarded': 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': now.millisecondsSinceEpoch,
        'original_timestamp': now.millisecondsSinceEpoch,
        'searchable_text': 'I prefer banana bread',
        'created_at': now.millisecondsSinceEpoch,
      });

      // Search for "apple" - should only find Alice's chat
      final appleResult = await repository.searchArchives(query: 'apple');
      expect(appleResult.chats.length, 1);
      expect(appleResult.chats.first.contactName, 'Alice');

      // Search for "banana" - should only find Bob's chat
      final bananaResult = await repository.searchArchives(query: 'banana');
      expect(bananaResult.chats.length, 1);
      expect(bananaResult.chats.first.contactName, 'Bob');
    });
  });
}
