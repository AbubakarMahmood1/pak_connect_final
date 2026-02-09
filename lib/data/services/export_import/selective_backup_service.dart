import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import '../../database/database_helper.dart';
import '../../database/database_encryption.dart';
import 'export_bundle.dart';

class SelectiveBackupService {
  static final _logger = Logger('SelectiveBackupService');

  /// Create a selective backup based on export type
  static Future<SelectiveBackupResult> createSelectiveBackup({
    required ExportType exportType,
    String? customBackupDir,
  }) async {
    try {
      _logger.info('Creating selective backup: ${exportType.name}');

      final db = await DatabaseHelper.database;

      // Determine backup directory
      String backupDir;
      if (customBackupDir != null) {
        backupDir = customBackupDir;
      } else {
        final dbPath = await DatabaseHelper.getDatabasePath();
        backupDir = join(dirname(dbPath), 'selective_backups');
      }

      await Directory(backupDir).create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final backupPath = join(
        backupDir,
        'selective_${exportType.name}_$timestamp.db',
      );

      // Create a new database with selected tables
      final factory = Platform.isAndroid || Platform.isIOS
          ? sqlcipher.databaseFactory
          : sqflite_common.databaseFactory;

      // Get encryption key for mobile platforms
      String? encryptionKey;
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
          _logger.fine('Using encryption key for backup database');
        } catch (e) {
          _logger.warning('Failed to get encryption key for backup: $e');
          // Continue without encryption for backup
        }
      }

      // Open database with platform-specific options
      final backupDb = Platform.isAndroid || Platform.isIOS
          ? await factory.openDatabase(
              backupPath,
              options: sqlcipher.OpenDatabaseOptions(
                version: 1,
                onCreate: (db, version) async {
                  await _createSelectiveSchema(db, exportType);
                },
                password: encryptionKey, // Encrypt backup on mobile platforms
              ),
            )
          : await factory.openDatabase(
              backupPath,
              options: sqflite_common.OpenDatabaseOptions(
                version: 1,
                onCreate: (db, version) async {
                  await _createSelectiveSchema(db, exportType);
                },
                // No password parameter for sqflite_common
              ),
            );

      // Copy data based on export type
      int recordCount = 0;
      switch (exportType) {
        case ExportType.contactsOnly:
          recordCount = await _exportContactsOnly(db, backupDb);
          break;
        case ExportType.messagesOnly:
          recordCount = await _exportMessagesOnly(db, backupDb);
          break;
        case ExportType.full:
          // Full export uses the regular database backup
          await backupDb.close();
          await File(backupPath).delete();
          throw UnsupportedError('Use DatabaseBackupService for full exports');
      }

      await backupDb.close();

      final backupFile = File(backupPath);
      final backupSize = await backupFile.length();

      _logger.info(
        '✅ Selective backup created: $backupPath ($recordCount records, ${backupSize / 1024}KB)',
      );

      return SelectiveBackupResult(
        success: true,
        backupPath: backupPath,
        recordCount: recordCount,
        backupSize: backupSize,
        exportType: exportType,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Selective backup failed', e, stackTrace);
      return SelectiveBackupResult(
        success: false,
        errorMessage: 'Selective backup failed: $e',
      );
    }
  }

  /// Create schema for selective backup
  static Future<void> _createSelectiveSchema(
    sqflite_common.Database db,
    ExportType exportType,
  ) async {
    switch (exportType) {
      case ExportType.contactsOnly:
        await _createContactsSchema(db);
        break;
      case ExportType.messagesOnly:
        await _createMessagesSchema(db);
        break;
      case ExportType.full:
        throw UnsupportedError('Full schema not supported in selective backup');
    }
  }

  /// Create contacts table schema
  static Future<void> _createContactsSchema(sqflite_common.Database db) async {
    await db.execute('''
      CREATE TABLE contacts (
        public_key TEXT PRIMARY KEY,
        persistent_public_key TEXT UNIQUE,
        current_ephemeral_id TEXT,
        ephemeral_id TEXT,
        display_name TEXT NOT NULL,
        trust_status INTEGER NOT NULL,
        security_level INTEGER NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        last_security_sync INTEGER,
        noise_public_key TEXT,
        noise_session_state TEXT,
        last_handshake_time INTEGER,
        is_favorite INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_trust ON contacts(trust_status)
    ''');

    await db.execute('''
      CREATE INDEX idx_contacts_security ON contacts(security_level)
    ''');
  }

  /// Create messages schema (includes chats as messages need chat context)
  static Future<void> _createMessagesSchema(sqflite_common.Database db) async {
    // Chats table (needed for message context)
    await db.execute('''
      CREATE TABLE chats (
        chat_id TEXT PRIMARY KEY,
        contact_public_key TEXT,
        contact_name TEXT NOT NULL,
        last_message TEXT,
        last_message_time INTEGER,
        unread_count INTEGER DEFAULT 0,
        is_archived INTEGER DEFAULT 0,
        is_muted INTEGER DEFAULT 0,
        is_pinned INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_chats_contact ON chats(contact_public_key)
    ''');

    // Messages table
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_from_me INTEGER NOT NULL,
        status INTEGER NOT NULL,
        reply_to_message_id TEXT,
        thread_id TEXT,
        is_starred INTEGER DEFAULT 0,
        is_forwarded INTEGER DEFAULT 0,
        priority INTEGER DEFAULT 1,
        edited_at INTEGER,
        original_content TEXT,
        has_media INTEGER DEFAULT 0,
        media_type TEXT,
        metadata_json TEXT,
        delivery_receipt_json TEXT,
        read_receipt_json TEXT,
        reactions_json TEXT,
        attachments_json TEXT,
        encryption_info_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_chat_time ON messages(chat_id, timestamp DESC)
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_starred ON messages(is_starred) WHERE is_starred = 1
    ''');
  }

  /// Export contacts only
  static Future<int> _exportContactsOnly(
    sqlcipher.Database sourceDb,
    sqflite_common.Database targetDb,
  ) async {
    _logger.info('Exporting contacts...');

    final contacts = await sourceDb.query('contacts');

    if (contacts.isEmpty) {
      _logger.warning('No contacts found to export');
      return 0;
    }

    final batch = targetDb.batch();
    for (final contact in contacts) {
      batch.insert('contacts', contact);
    }
    await batch.commit(noResult: true);

    _logger.info('Exported ${contacts.length} contacts');
    return contacts.length;
  }

  /// Export messages only (includes related chats)
  static Future<int> _exportMessagesOnly(
    sqlcipher.Database sourceDb,
    sqflite_common.Database targetDb,
  ) async {
    _logger.info('Exporting messages and chats...');

    // Export chats first (foreign key dependency)
    final chats = await sourceDb.query('chats');
    _logger.info('Found ${chats.length} chats');

    final batch = targetDb.batch();
    for (final chat in chats) {
      final normalizedChat = Map<String, Object?>.from(chat);
      normalizedChat['chat_id'] = chat['chat_id']?.toString();
      normalizedChat['contact_public_key'] = chat['contact_public_key']
          ?.toString();
      batch.insert('chats', normalizedChat);
    }
    await batch.commit(noResult: true);

    // Export messages
    final messages = await sourceDb.query('messages');
    _logger.info('Found ${messages.length} messages');

    if (messages.isEmpty) {
      _logger.warning('No messages found to export');
      return chats.length; // Return chat count
    }

    final batch2 = targetDb.batch();
    for (final message in messages) {
      final normalizedMessage = Map<String, Object?>.from(message);
      normalizedMessage['id'] = message['id']?.toString();
      normalizedMessage['chat_id'] = message['chat_id']?.toString();
      normalizedMessage['reply_to_message_id'] = message['reply_to_message_id']
          ?.toString();
      batch2.insert('messages', normalizedMessage);
    }
    await batch2.commit(noResult: true);

    final totalRecords = chats.length + messages.length;
    _logger.info(
      'Exported $totalRecords total records (${chats.length} chats + ${messages.length} messages)',
    );
    return totalRecords;
  }

  /// Get statistics for selective backup
  static Future<Map<String, dynamic>> getSelectiveStats(
    ExportType exportType,
  ) async {
    final db = await DatabaseHelper.database;

    switch (exportType) {
      case ExportType.contactsOnly:
        final result = await db.rawQuery(
          'SELECT COUNT(*) as count FROM contacts',
        );
        final count = sqlcipher.Sqflite.firstIntValue(result) ?? 0;
        return {
          'type': 'contacts_only',
          'record_count': count,
          'tables': ['contacts'],
        };

      case ExportType.messagesOnly:
        final chatsResult = await db.rawQuery(
          'SELECT COUNT(*) as count FROM chats',
        );
        final messagesResult = await db.rawQuery(
          'SELECT COUNT(*) as count FROM messages',
        );
        final chatCount = sqlcipher.Sqflite.firstIntValue(chatsResult) ?? 0;
        final messageCount =
            sqlcipher.Sqflite.firstIntValue(messagesResult) ?? 0;
        return {
          'type': 'messages_only',
          'record_count': chatCount + messageCount,
          'chat_count': chatCount,
          'message_count': messageCount,
          'tables': ['chats', 'messages'],
        };

      case ExportType.full:
        return DatabaseHelper.getStatistics();
    }
  }
}

/// Result of selective backup operation
class SelectiveBackupResult {
  final bool success;
  final String? backupPath;
  final String? errorMessage;
  final int recordCount;
  final int backupSize;
  final ExportType? exportType;

  SelectiveBackupResult({
    required this.success,
    this.backupPath,
    this.errorMessage,
    this.recordCount = 0,
    this.backupSize = 0,
    this.exportType,
  });

  @override
  String toString() => success
      ? 'SelectiveBackupResult(success, type: ${exportType?.name}, records: $recordCount, size: ${backupSize / 1024}KB)'
      : 'SelectiveBackupResult(failure: $errorMessage)';
}
