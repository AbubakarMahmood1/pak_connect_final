import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/models/message_priority.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import '../../test_helpers/test_setup.dart';

/// Phase 12.1: Supplementary tests for ArchiveRepository
/// Targets: getArchivedChatsCount, getArchivedChatByOriginalId, clearCache,
///   dispose, getArchivedChats filter/sort combos, mapping helper edge cases
void main() {
  late List<LogRecord> logRecords;
  late Set<String> allowedSevere;

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(
      dbLabel: 'archive_repository_phase12',
    );
    await TestSetup.fullDatabaseReset();
  });

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

  /// Insert an archive directly in the DB (bypasses ChatsRepository)
  Future<ArchiveId> createArchiveDirectly(
    String chatId,
    String contactName,
    int messageCount, {
    int estimatedSize = 0,
    bool isCompressed = false,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch;
    final size = estimatedSize > 0 ? estimatedSize : messageCount * 100;
    final archiveId = ArchiveId('archive_${chatId}_$timestamp');

    await db.insert('archived_chats', {
      'archive_id': archiveId.value,
      'original_chat_id': chatId,
      'contact_name': contactName,
      'contact_public_key': 'test_pk_$chatId',
      'archived_at': timestamp,
      'last_message_time': timestamp,
      'message_count': messageCount,
      'archive_reason': 'Test archive',
      'estimated_size': size,
      'is_compressed': isCompressed ? 1 : 0,
      'metadata_json':
          '{"version":"1.0","reason":"Test archive","originalUnreadCount":0,'
          '"wasOnline":false,"hadUnsentMessages":false,'
          '"estimatedStorageSize":$size,"archiveSource":"test",'
          '"tags":[],"hasSearchIndex":true}',
      'created_at': timestamp,
      'updated_at': timestamp,
    });

    for (int i = 0; i < messageCount; i++) {
      final msgTime = now.subtract(Duration(hours: messageCount - i));
      await db.insert('archived_messages', {
        'id': 'archived_msg_${timestamp}_${chatId}_$i',
        'archive_id': archiveId.value,
        'original_message_id': 'msg_${chatId}_$i',
        'chat_id': chatId,
        'content': 'Test message $i for $contactName',
        'timestamp': msgTime.millisecondsSinceEpoch,
        'is_from_me': i % 2 == 0 ? 1 : 0,
        'status': MessageStatus.delivered.index,
        'is_starred': i == 0 ? 1 : 0,
        'is_forwarded': i == 1 ? 1 : 0,
        'priority': 1,
        'has_media': 0,
        'archived_at': timestamp,
        'original_timestamp': msgTime.millisecondsSinceEpoch,
        'searchable_text': 'Test message $i for $contactName',
        'created_at': timestamp,
      });
    }

    return archiveId;
  }

  group('ArchiveRepository.getArchivedChatsCount', () {
    test('returns 0 for empty database', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final count = await repo.getArchivedChatsCount();
      expect(count, 0);
    });

    test('returns correct count with multiple archives', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_cnt_1', 'Alice', 3);
      await createArchiveDirectly('chat_cnt_2', 'Bob', 5);
      await createArchiveDirectly('chat_cnt_3', 'Charlie', 2);

      final count = await repo.getArchivedChatsCount();
      expect(count, 3);
    });

    test('updates after permanent delete', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final id = await createArchiveDirectly('chat_cnt_del', 'Alice', 2);
      expect(await repo.getArchivedChatsCount(), 1);

      await repo.permanentlyDeleteArchive(id);
      expect(await repo.getArchivedChatsCount(), 0);
    });
  });

  group('ArchiveRepository.getArchivedChatByOriginalId', () {
    test('returns summary when archive exists', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('chat_orig_1', 'Alice', 4);

      final summary = await repo.getArchivedChatByOriginalId('chat_orig_1');
      expect(summary, isNotNull);
      expect(summary!.contactName, 'Alice');
      expect(summary.messageCount, 4);
      expect(summary.originalChatId, ChatId('chat_orig_1'));
    });

    test('returns null when archive does not exist', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final summary = await repo.getArchivedChatByOriginalId('nonexistent');
      expect(summary, isNull);
    });

    test('returns first match when multiple archives for same chat', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      // Create two archives for same original chat
      await createArchiveDirectly('chat_multi', 'Alice', 3);
      await Future.delayed(const Duration(milliseconds: 50));
      await createArchiveDirectly('chat_multi', 'Alice Updated', 5);

      final summary = await repo.getArchivedChatByOriginalId('chat_multi');
      expect(summary, isNotNull);
      // Should find one of them (LIMIT 1)
      expect(summary!.originalChatId, ChatId('chat_multi'));
    });
  });

  group('ArchiveRepository.clearCache and dispose', () {
    test('clearCache runs without error', () {
      final repo = ArchiveRepository();
      // clearCache is synchronous no-op for SQLite
      repo.clearCache();
    });

    test('dispose runs without error', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      await repo.dispose();
    });

    test('initialize is idempotent', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      await repo.initialize(); // Second call should be safe
    });
  });

  group('ArchiveRepository.getArchivedChats — size filters', () {
    test('filter small archives (<=1KB)', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_s', 'Small', 1, estimatedSize: 512);
      await createArchiveDirectly('ch_m', 'Medium', 5, estimatedSize: 50000);
      await createArchiveDirectly('ch_l', 'Large', 10, estimatedSize: 2000000);

      final filter = ArchiveSearchFilter(sizeFilter: ArchiveSizeFilter.small);
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'Small');
    });

    test('filter medium archives (1KB-1MB)', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_s2', 'Small', 1, estimatedSize: 512);
      await createArchiveDirectly('ch_m2', 'Medium', 5, estimatedSize: 50000);
      await createArchiveDirectly(
        'ch_l2',
        'Large',
        10,
        estimatedSize: 2000000,
      );

      final filter = ArchiveSearchFilter(sizeFilter: ArchiveSizeFilter.medium);
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'Medium');
    });

    test('filter large archives (>1MB)', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_s3', 'Small', 1, estimatedSize: 512);
      await createArchiveDirectly('ch_m3', 'Medium', 5, estimatedSize: 50000);
      await createArchiveDirectly(
        'ch_l3',
        'Large',
        10,
        estimatedSize: 2000000,
      );

      final filter = ArchiveSearchFilter(sizeFilter: ArchiveSizeFilter.large);
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'Large');
    });
  });

  group('ArchiveRepository.getArchivedChats — onlyCompressed filter', () {
    test('returns only compressed archives', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_uc', 'Uncompressed', 3);
      await createArchiveDirectly(
        'ch_c',
        'Compressed',
        5,
        isCompressed: true,
      );

      final filter = ArchiveSearchFilter(onlyCompressed: true);
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'Compressed');
      expect(results.first.isCompressed, true);
    });
  });

  group('ArchiveRepository.getArchivedChats — sort options', () {
    test('sort by contact name ascending', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_z', 'Zara', 2);
      await createArchiveDirectly('ch_a', 'Alice', 4);
      await createArchiveDirectly('ch_m', 'Marcus', 3);

      final filter = ArchiveSearchFilter(
        sortBy: ArchiveSortOption.contactName,
      );
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 3);
      expect(results[0].contactName, 'Alice');
      expect(results[1].contactName, 'Marcus');
      expect(results[2].contactName, 'Zara');
    });

    test('sort by size descending', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_sm', 'Small', 1, estimatedSize: 100);
      await createArchiveDirectly('ch_bg', 'Big', 5, estimatedSize: 50000);
      await createArchiveDirectly('ch_md', 'Mid', 3, estimatedSize: 5000);

      final filter = ArchiveSearchFilter(sortBy: ArchiveSortOption.size);
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 3);
      expect(results[0].contactName, 'Big');
      expect(results[1].contactName, 'Mid');
      expect(results[2].contactName, 'Small');
    });

    test('sort by dateOriginal (last_message_time)', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_do1', 'Old', 2);
      await Future.delayed(const Duration(milliseconds: 50));
      await createArchiveDirectly('ch_do2', 'New', 3);

      final filter = ArchiveSearchFilter(
        sortBy: ArchiveSortOption.dateOriginal,
      );
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 2);
      // dateOriginal sorts by last_message_time DESC
      expect(results[0].contactName, 'New');
      expect(results[1].contactName, 'Old');
    });

    test('sort by relevance defaults to date archived desc', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly('ch_r1', 'First', 1);
      await Future.delayed(const Duration(milliseconds: 50));
      await createArchiveDirectly('ch_r2', 'Second', 2);

      final filter = ArchiveSearchFilter(
        sortBy: ArchiveSortOption.relevance,
      );
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 2);
      expect(results[0].contactName, 'Second');
      expect(results[1].contactName, 'First');
    });
  });

  group('ArchiveRepository.getArchivedChats — pagination', () {
    test('offset skips first N results', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      for (int i = 0; i < 5; i++) {
        await createArchiveDirectly('ch_pg_$i', 'Contact $i', 2);
        await Future.delayed(const Duration(milliseconds: 20));
      }

      final page2 = await repo.getArchivedChats(limit: 2, offset: 2);
      expect(page2.length, 2);

      final page3 = await repo.getArchivedChats(limit: 2, offset: 4);
      expect(page3.length, 1);
    });
  });

  group('ArchiveRepository.getArchivedChats — combined filters', () {
    test('contact filter + size filter combined', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      await createArchiveDirectly(
        'ch_cf1',
        'Alice Big',
        10,
        estimatedSize: 2000000,
      );
      await createArchiveDirectly(
        'ch_cf2',
        'Alice Small',
        1,
        estimatedSize: 100,
      );
      await createArchiveDirectly(
        'ch_cf3',
        'Bob Big',
        10,
        estimatedSize: 2000000,
      );

      final filter = ArchiveSearchFilter(
        contactFilter: 'Alice',
        sizeFilter: ArchiveSizeFilter.large,
      );
      final results = await repo.getArchivedChats(filter: filter);

      expect(results.length, 1);
      expect(results.first.contactName, 'Alice Big');
    });
  });

  group('Mapping helper — rich message fields via getArchivedChat', () {
    test('maps message with starred, forwarded, edited fields', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      final db = await DatabaseHelper.database;

      final now = DateTime.now();
      final ts = now.millisecondsSinceEpoch;
      final archiveId = 'archive_rich_$ts';

      await db.insert('archived_chats', {
        'archive_id': archiveId,
        'original_chat_id': 'rich_chat',
        'contact_name': 'Rich Contact',
        'contact_public_key': 'rich_pk',
        'archived_at': ts,
        'last_message_time': ts,
        'message_count': 1,
        'archive_reason': 'Test',
        'estimated_size': 200,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"1.0","reason":"Test","originalUnreadCount":0,'
            '"wasOnline":false,"hadUnsentMessages":false,'
            '"estimatedStorageSize":200,"archiveSource":"test",'
            '"tags":[],"hasSearchIndex":true}',
        'created_at': ts,
        'updated_at': ts,
      });

      await db.insert('archived_messages', {
        'id': 'rich_msg_1',
        'archive_id': archiveId,
        'original_message_id': 'orig_rich_1',
        'chat_id': 'rich_chat',
        'content': 'Starred and forwarded message',
        'timestamp': ts,
        'is_from_me': 1,
        'status': MessageStatus.delivered.index,
        'is_starred': 1,
        'is_forwarded': 1,
        'priority': 2,
        'has_media': 0,
        'edited_at': ts + 1000,
        'original_content': 'Original content before edit',
        'reply_to_message_id': 'parent_msg_123',
        'thread_id': 'thread_abc',
        'archived_at': ts,
        'original_timestamp': ts - 5000,
        'searchable_text': 'Starred and forwarded message',
        'created_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveId));
      expect(archive, isNotNull);
      expect(archive!.messages.length, 1);

      final msg = archive.messages.first;
      expect(msg.isStarred, true);
      expect(msg.isForwarded, true);
      expect(msg.editedAt, isNotNull);
      expect(msg.originalContent, 'Original content before edit');
      expect(msg.replyToMessageId, MessageId('parent_msg_123'));
      expect(msg.threadId, 'thread_abc');
      expect(msg.priority, MessagePriority.high);
    });

    test('maps message with null optional fields', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      final db = await DatabaseHelper.database;

      final now = DateTime.now();
      final ts = now.millisecondsSinceEpoch;
      final archiveId = 'archive_minimal_$ts';

      await db.insert('archived_chats', {
        'archive_id': archiveId,
        'original_chat_id': 'minimal_chat',
        'contact_name': 'Minimal',
        'archived_at': ts,
        'message_count': 1,
        'estimated_size': 50,
        'is_compressed': 0,
        'created_at': ts,
        'updated_at': ts,
      });

      await db.insert('archived_messages', {
        'id': 'min_msg_1',
        'archive_id': archiveId,
        'chat_id': 'minimal_chat',
        'content': 'Simple message',
        'timestamp': ts,
        'is_from_me': 0,
        'status': MessageStatus.sent.index,
        'archived_at': ts,
        'original_timestamp': ts,
        'created_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveId));
      expect(archive, isNotNull);

      final msg = archive!.messages.first;
      expect(msg.isStarred, false);
      expect(msg.isForwarded, false);
      expect(msg.editedAt, isNull);
      expect(msg.originalContent, isNull);
      expect(msg.replyToMessageId, isNull);
      expect(msg.threadId, isNull);
      expect(msg.reactions, isEmpty);
      expect(msg.attachments, isEmpty);
    });

    test('maps chat summary with all expected fields', () async {
      final repo = ArchiveRepository();
      await repo.initialize();

      final id = await createArchiveDirectly('sum_chat', 'Summary User', 7);

      final summaries = await repo.getArchivedChats();
      expect(summaries.length, 1);

      final s = summaries.first;
      expect(s.id, id);
      expect(s.originalChatId, ChatId('sum_chat'));
      expect(s.contactName, 'Summary User');
      expect(s.messageCount, 7);
      expect(s.archivedAt, isNotNull);
      expect(s.lastMessageTime, isNotNull);
      expect(s.isSearchable, true);
    });

    test('maps archived chat with custom metadata and reason', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      final db = await DatabaseHelper.database;

      final ts = DateTime.now().millisecondsSinceEpoch;
      final archiveId = 'archive_meta_$ts';

      await db.insert('archived_chats', {
        'archive_id': archiveId,
        'original_chat_id': 'meta_chat',
        'contact_name': 'Meta User',
        'archived_at': ts,
        'last_message_time': ts,
        'message_count': 0,
        'archive_reason': 'User requested cleanup',
        'estimated_size': 100,
        'is_compressed': 0,
        'metadata_json':
            '{"version":"2.0","reason":"User requested cleanup",'
            '"originalUnreadCount":5,"wasOnline":true,'
            '"hadUnsentMessages":true,"estimatedStorageSize":100,'
            '"archiveSource":"user_action","tags":["important","cleanup"],'
            '"hasSearchIndex":true}',
        'custom_data_json': '{"category":"work","priority":"high"}',
        'created_at': ts,
        'updated_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveId));
      expect(archive, isNotNull);
      expect(archive!.metadata.reason, 'User requested cleanup');
      expect(archive.metadata.wasOnline, true);
      expect(archive.metadata.hadUnsentMessages, true);
      expect(archive.metadata.originalUnreadCount, 5);
      expect(archive.customData, isNotNull);
      expect(archive.customData!['category'], 'work');
    });

    test('maps archive with default metadata when json is null', () async {
      final repo = ArchiveRepository();
      await repo.initialize();
      final db = await DatabaseHelper.database;

      final ts = DateTime.now().millisecondsSinceEpoch;
      final archiveId = 'archive_nomd_$ts';

      await db.insert('archived_chats', {
        'archive_id': archiveId,
        'original_chat_id': 'nomd_chat',
        'contact_name': 'NoMeta',
        'archived_at': ts,
        'message_count': 0,
        'archive_reason': 'Auto-archive',
        'estimated_size': 50,
        'is_compressed': 0,
        'created_at': ts,
        'updated_at': ts,
      });

      final archive = await repo.getArchivedChat(ArchiveId(archiveId));
      expect(archive, isNotNull);
      // Should get default ArchiveMetadata
      expect(archive!.metadata.version, '1.0');
      expect(archive.metadata.archiveSource, 'migration');
      expect(archive.customData, isNull);
    });
  });
}
