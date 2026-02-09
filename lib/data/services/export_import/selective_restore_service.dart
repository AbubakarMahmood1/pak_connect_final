// Selective restore service
// Restores selective backups (contacts only, messages only)

import 'dart:io';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_common/sqflite.dart' as sqflite_common;
import '../../database/database_helper.dart';
import '../../database/database_encryption.dart';
import 'export_bundle.dart';

class SelectiveRestoreService {
  static final _logger = Logger('SelectiveRestoreService');

  /// Restore selective backup
  static Future<SelectiveRestoreResult> restoreSelectiveBackup({
    required String backupPath,
    required ExportType exportType,
    bool clearExistingData = false,
  }) async {
    try {
      _logger.info('Restoring selective backup: ${exportType.name}');

      final backupFile = File(backupPath);
      if (!await backupFile.exists()) {
        return SelectiveRestoreResult(
          success: false,
          errorMessage: 'Backup file not found: $backupPath',
        );
      }

      // Open backup database
      final factory = Platform.isAndroid || Platform.isIOS
          ? sqlcipher.databaseFactory
          : sqflite_common.databaseFactory;

      // Get encryption key for mobile platforms
      String? encryptionKey;
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          encryptionKey = await DatabaseEncryption.getOrCreateEncryptionKey();
          _logger.fine('Using encryption key to open backup database');
        } catch (e) {
          _logger.warning('Failed to get encryption key for restore: $e');
          // Try opening without encryption
        }
      }

      // Open database with platform-specific options
      final backupDb = Platform.isAndroid || Platform.isIOS
          ? await factory.openDatabase(
              backupPath,
              options: sqlcipher.OpenDatabaseOptions(
                readOnly: true,
                password: encryptionKey, // Use encryption key on mobile platforms
              ),
            )
          : await factory.openDatabase(
              backupPath,
              options: sqflite_common.OpenDatabaseOptions(
                readOnly: true,
                // No password parameter for sqflite_common
              ),
            );

      // Get target database
      final targetDb = await DatabaseHelper.database;

      int recordsRestored = 0;

      switch (exportType) {
        case ExportType.contactsOnly:
          recordsRestored = await _restoreContactsOnly(
            backupDb,
            targetDb,
            clearExistingData,
          );
          break;

        case ExportType.messagesOnly:
          recordsRestored = await _restoreMessagesOnly(
            backupDb,
            targetDb,
            clearExistingData,
          );
          break;

        case ExportType.full:
          await backupDb.close();
          throw UnsupportedError('Use DatabaseBackupService for full restore');
      }

      await backupDb.close();

      _logger.info('✅ Selective restore complete: $recordsRestored records');

      return SelectiveRestoreResult(
        success: true,
        recordsRestored: recordsRestored,
        exportType: exportType,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Selective restore failed', e, stackTrace);
      return SelectiveRestoreResult(
        success: false,
        errorMessage: 'Selective restore failed: $e',
      );
    }
  }

  /// Restore contacts only
  static Future<int> _restoreContactsOnly(
    sqflite_common.Database backupDb,
    sqlcipher.Database targetDb,
    bool clearExisting,
  ) async {
    _logger.info('Restoring contacts...');

    // Clear existing contacts if requested
    if (clearExisting) {
      _logger.fine('Clearing existing contacts...');
      await targetDb.delete('contacts');
    }

    // Read contacts from backup
    final contacts = await backupDb.query('contacts');

    if (contacts.isEmpty) {
      _logger.info('No contacts found in backup');
      return 0;
    }

    // Insert contacts into target database
    final batch = targetDb.batch();
    for (final contact in contacts) {
      // Use INSERT OR REPLACE to handle duplicates
      batch.rawInsert(
        '''
        INSERT OR REPLACE INTO contacts (
          public_key, display_name, trust_status, security_level,
          first_seen, last_seen, last_security_sync,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          contact['public_key'],
          contact['display_name'],
          contact['trust_status'],
          contact['security_level'],
          contact['first_seen'],
          contact['last_seen'],
          contact['last_security_sync'],
          contact['created_at'],
          DateTime.now().millisecondsSinceEpoch, // Update timestamp
        ],
      );
    }

    await batch.commit(noResult: true);

    _logger.info('Restored ${contacts.length} contacts');
    return contacts.length;
  }

  /// Restore messages only (includes chats)
  static Future<int> _restoreMessagesOnly(
    sqflite_common.Database backupDb,
    sqlcipher.Database targetDb,
    bool clearExisting,
  ) async {
    _logger.info('Restoring messages and chats...');

    // Clear existing messages and chats if requested
    if (clearExisting) {
      _logger.warning('Clearing existing messages and chats...');
      await targetDb.delete('messages');
      await targetDb.delete('chats');
    }

    // Restore chats first (foreign key dependency)
    final chats = await backupDb.query('chats');
    _logger.info('Found ${chats.length} chats in backup');

    final batch1 = targetDb.batch();
    for (final chat in chats) {
      final chatId = chat['chat_id']?.toString();
      batch1.rawInsert(
        '''
        INSERT OR REPLACE INTO chats (
          chat_id, contact_public_key, contact_name,
          last_message, last_message_time, unread_count,
          is_archived, is_muted, is_pinned,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          chatId,
          chat['contact_public_key']?.toString(),
          chat['contact_name'],
          chat['last_message'],
          chat['last_message_time'],
          chat['unread_count'],
          chat['is_archived'],
          chat['is_muted'],
          chat['is_pinned'],
          chat['created_at'],
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }

    await batch1.commit(noResult: true);

    // Restore messages
    final messages = await backupDb.query('messages');
    _logger.info('Found ${messages.length} messages in backup');

    if (messages.isEmpty) {
      return chats.length;
    }

    final batch2 = targetDb.batch();
    for (final message in messages) {
      batch2.rawInsert(
        '''
        INSERT OR REPLACE INTO messages (
          id, chat_id, content, timestamp, is_from_me, status,
          reply_to_message_id, thread_id, is_starred, is_forwarded,
          priority, edited_at, original_content, has_media, media_type,
          metadata_json, delivery_receipt_json, read_receipt_json,
          reactions_json, attachments_json, encryption_info_json,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          message['id']?.toString(),
          message['chat_id']?.toString(),
          message['content'],
          message['timestamp'],
          message['is_from_me'],
          message['status'],
          message['reply_to_message_id']?.toString(),
          message['thread_id'],
          message['is_starred'],
          message['is_forwarded'],
          message['priority'],
          message['edited_at'],
          message['original_content'],
          message['has_media'],
          message['media_type'],
          message['metadata_json'],
          message['delivery_receipt_json'],
          message['read_receipt_json'],
          message['reactions_json'],
          message['attachments_json'],
          message['encryption_info_json'],
          message['created_at'],
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    }

    await batch2.commit(noResult: true);

    final totalRecords = chats.length + messages.length;
    _logger.info('Restored $totalRecords total records');
    return totalRecords;
  }
}

/// Result of selective restore operation
class SelectiveRestoreResult {
  final bool success;
  final String? errorMessage;
  final int recordsRestored;
  final ExportType? exportType;

  SelectiveRestoreResult({
    required this.success,
    this.errorMessage,
    this.recordsRestored = 0,
    this.exportType,
  });

  @override
  String toString() => success
      ? 'SelectiveRestoreResult(success, type: ${exportType?.name}, records: $recordsRestored)'
      : 'SelectiveRestoreResult(failure: $errorMessage)';
}
