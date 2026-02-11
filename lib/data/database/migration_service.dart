// Comprehensive migration service for SharedPreferences → SQLite
// Handles contacts, messages, chats, offline queue with validation

import 'dart:convert';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'package:crypto/crypto.dart';
import 'database_helper.dart';
import 'package:pak_connect/domain/utils/chat_utils.dart';

/// Migration result with detailed statistics
class MigrationResult {
  final bool success;
  final String message;
  final Map<String, int> migrationCounts;
  final Map<String, String> checksums;
  final Duration duration;
  final String? backupPath;
  final List<String> errors;
  final List<String> warnings;

  const MigrationResult({
    required this.success,
    required this.message,
    required this.migrationCounts,
    required this.checksums,
    required this.duration,
    this.backupPath,
    this.errors = const [],
    this.warnings = const [],
  });

  Map<String, dynamic> toJson() => {
    'success': success,
    'message': message,
    'migrationCounts': migrationCounts,
    'checksums': checksums,
    'durationMs': duration.inMilliseconds,
    'backupPath': backupPath,
    'errors': errors,
    'warnings': warnings,
  };
}

/// Migration service for data migration
class MigrationService {
  static final _logger = Logger('MigrationService');

  /// Check if migration is needed
  ///
  /// Set SKIP_MIGRATION=true in environment to start fresh (useful for dev)
  static Future<bool> needsMigration() async {
    try {
      // Allow skipping migration for fresh starts (dev mode)
      const skipMigration = bool.fromEnvironment(
        'SKIP_MIGRATION',
        defaultValue: false,
      );
      if (skipMigration) {
        _logger.info('Migration skipped (SKIP_MIGRATION=true)');
        return false;
      }

      final prefs = await SharedPreferences.getInstance();

      // Check if already migrated
      final migrated = prefs.getBool('sqlite_migration_completed') ?? false;
      if (migrated) {
        _logger.info('Migration already completed');
        return false;
      }

      // Check if there's any data to migrate
      final hasMessages =
          (prefs.getStringList('chat_messages') ?? []).isNotEmpty;
      final hasContacts =
          (prefs.getStringList('enhanced_contacts_v2') ?? []).isNotEmpty;
      final hasQueue =
          (prefs.getStringList('offline_message_queue_v2') ?? []).isNotEmpty;

      final needsMigration = hasMessages || hasContacts || hasQueue;

      if (needsMigration) {
        _logger.info(
          'Migration needed: messages=$hasMessages, contacts=$hasContacts, queue=$hasQueue',
        );
      } else {
        _logger.info('No data to migrate');
      }

      return needsMigration;
    } catch (e) {
      _logger.severe('Failed to check migration status: $e');
      return false;
    }
  }

  /// Perform complete migration
  static Future<MigrationResult> migrate() async {
    final startTime = DateTime.now();
    final counts = <String, int>{};
    final checksums = <String, String>{};
    final errors = <String>[];
    final warnings = <String>[];

    _logger.info('🚀 Starting SharedPreferences → SQLite migration...');

    try {
      final db = await DatabaseHelper.database;
      final prefs = await SharedPreferences.getInstance();

      // Create backup first
      final backupPath = await _createBackup(prefs);
      _logger.info('✅ Backup created at: $backupPath');

      // Use transaction for atomicity
      await db.transaction((txn) async {
        // Migrate in order of dependencies
        counts['contacts'] = await _migrateContacts(txn, prefs);
        checksums['contacts'] = await _calculateContactsChecksum(txn);

        counts['chats'] = await _migrateChats(txn, prefs);
        checksums['chats'] = await _calculateChatsChecksum(txn);

        counts['messages'] = await _migrateMessages(txn, prefs);
        checksums['messages'] = await _calculateMessagesChecksum(txn);

        counts['offline_queue'] = await _migrateOfflineQueue(txn, prefs);
        checksums['queue'] = await _calculateQueueChecksum(txn);

        counts['deleted_ids'] = await _migrateDeletedMessageIds(txn, prefs);

        counts['device_mappings'] = await _migrateDeviceMappings(txn, prefs);

        counts['last_seen'] = await _migrateLastSeen(txn, prefs);

        counts['user_prefs'] = await _migrateUserPreferences(txn, prefs);

        // Record migration metadata
        await txn.insert('migration_metadata', {
          'key': 'migration_completed_at',
          'value': DateTime.now().toIso8601String(),
          'migrated_at': DateTime.now().millisecondsSinceEpoch,
        });
      });

      // Mark as migrated
      await prefs.setBool('sqlite_migration_completed', true);

      final duration = DateTime.now().difference(startTime);
      final totalRecords = counts.values.fold<int>(
        0,
        (sum, count) => sum + count,
      );

      _logger.info(
        '✅ Migration completed successfully in ${duration.inMilliseconds}ms',
      );
      _logger.info('📊 Total records migrated: $totalRecords');
      counts.forEach((key, value) {
        _logger.info('   - $key: $value records');
      });

      return MigrationResult(
        success: true,
        message:
            'Migration completed successfully. Migrated $totalRecords records.',
        migrationCounts: counts,
        checksums: checksums,
        duration: duration,
        backupPath: backupPath,
        errors: errors,
        warnings: warnings,
      );
    } catch (e, stackTrace) {
      _logger.severe('❌ Migration failed: $e', e, stackTrace);

      return MigrationResult(
        success: false,
        message: 'Migration failed: $e',
        migrationCounts: counts,
        checksums: checksums,
        duration: DateTime.now().difference(startTime),
        errors: [e.toString()],
        warnings: warnings,
      );
    }
  }

  /// Migrate contacts with security levels
  static Future<int> _migrateContacts(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating contacts...');

    final contactsJson = prefs.getStringList('enhanced_contacts_v2') ?? [];
    int count = 0;

    for (final json in contactsJson) {
      try {
        final contactData = jsonDecode(json);
        final now = DateTime.now().millisecondsSinceEpoch;

        await db.insert('contacts', {
          'public_key': contactData['publicKey'],
          'display_name': contactData['displayName'],
          'trust_status': contactData['trustStatus'] ?? 0,
          'security_level': contactData['securityLevel'] ?? 0,
          'first_seen': contactData['firstSeen'],
          'last_seen': contactData['lastSeen'],
          'last_security_sync': contactData['lastSecuritySync'],
          'created_at': now,
          'updated_at': now,
        });

        count++;
      } catch (e) {
        _logger.warning('Failed to migrate contact: $e');
      }
    }

    _logger.info('✅ Migrated $count contacts');
    return count;
  }

  /// Migrate chats metadata
  static Future<int> _migrateChats(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating chats metadata...');

    // Get all messages to extract unique chat IDs
    final messagesJson = prefs.getStringList('chat_messages') ?? [];
    final chatIds = <String>{};

    for (final json in messagesJson) {
      try {
        final messageData = jsonDecode(json);
        chatIds.add(messageData['chatId'] as String);
      } catch (e) {
        _logger.warning('Failed to parse message for chat extraction: $e');
      }
    }

    // Get unread counts
    final unreadCounts = await _getUnreadCounts(prefs);

    int count = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final chatId in chatIds) {
      try {
        // Get contact public key from chat ID
        // 🔥 FIX: Use ChatUtils.extractContactKey() to handle all formats robustly
        // Note: Pass empty string for myPublicKey (backwards compat for migration)
        String? contactPublicKey = ChatUtils.extractContactKey(chatId, '');
        String contactName = 'Unknown';

        if (contactPublicKey != null) {
          // Try to get contact name from contacts table
          final contactResult = await db.query(
            'contacts',
            columns: ['display_name'],
            where: 'public_key = ?',
            whereArgs: [contactPublicKey],
            limit: 1,
          );

          if (contactResult.isNotEmpty) {
            contactName = contactResult.first['display_name'] as String;
          }
        } else if (chatId.startsWith('temp_')) {
          contactName =
              'Device ${chatId.substring(5, chatId.length.clamp(0, 13))}';
        }

        // Get last message for this chat
        final lastMessageResult = await db.query(
          'messages',
          columns: ['content', 'timestamp'],
          where: 'chat_id = ?',
          whereArgs: [chatId],
          orderBy: 'timestamp DESC',
          limit: 1,
        );

        String? lastMessage;
        int? lastMessageTime;

        if (lastMessageResult.isNotEmpty) {
          lastMessage = lastMessageResult.first['content'] as String?;
          lastMessageTime = lastMessageResult.first['timestamp'] as int?;
        }

        await db.insert('chats', {
          'chat_id': chatId,
          'contact_public_key': contactPublicKey,
          'contact_name': contactName,
          'last_message': lastMessage,
          'last_message_time': lastMessageTime,
          'unread_count': unreadCounts[chatId] ?? 0,
          'is_archived': 0,
          'is_muted': 0,
          'is_pinned': 0,
          'created_at': now,
          'updated_at': now,
        });

        count++;
      } catch (e) {
        _logger.warning('Failed to migrate chat $chatId: $e');
      }
    }

    _logger.info('✅ Migrated $count chats');
    return count;
  }

  /// Migrate messages (supports both Message and EnhancedMessage)
  static Future<int> _migrateMessages(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating messages...');

    final messagesJson = prefs.getStringList('chat_messages') ?? [];
    int count = 0;

    for (final json in messagesJson) {
      try {
        final messageData = jsonDecode(json);
        final now = DateTime.now().millisecondsSinceEpoch;

        // Basic message fields
        final record = {
          'id': messageData['id']?.toString(),
          'chat_id': messageData['chatId']?.toString(),
          'content': messageData['content'],
          'timestamp': messageData['timestamp'],
          'is_from_me': (messageData['isFromMe'] ?? false) ? 1 : 0,
          'status': messageData['status'] ?? 0,
          'has_media': 0,
          'created_at': now,
          'updated_at': now,
        };

        // Enhanced message fields (if present)
        if (messageData.containsKey('replyToMessageId')) {
          record['reply_to_message_id'] = messageData['replyToMessageId']
              ?.toString();
        }
        if (messageData.containsKey('threadId')) {
          record['thread_id'] = messageData['threadId']?.toString();
        }
        if (messageData.containsKey('isStarred')) {
          record['is_starred'] = messageData['isStarred'] ? 1 : 0;
        }
        if (messageData.containsKey('isForwarded')) {
          record['is_forwarded'] = messageData['isForwarded'] ? 1 : 0;
        }
        if (messageData.containsKey('priority')) {
          record['priority'] = messageData['priority'];
        }
        if (messageData.containsKey('editedAt')) {
          record['edited_at'] = messageData['editedAt'];
        }
        if (messageData.containsKey('originalContent')) {
          record['original_content'] = messageData['originalContent'];
        }

        // Serialize complex objects to JSON
        if (messageData.containsKey('metadata') &&
            messageData['metadata'] != null) {
          record['metadata_json'] = jsonEncode(messageData['metadata']);
        }
        if (messageData.containsKey('deliveryReceipt') &&
            messageData['deliveryReceipt'] != null) {
          record['delivery_receipt_json'] = jsonEncode(
            messageData['deliveryReceipt'],
          );
        }
        if (messageData.containsKey('readReceipt') &&
            messageData['readReceipt'] != null) {
          record['read_receipt_json'] = jsonEncode(messageData['readReceipt']);
        }
        if (messageData.containsKey('reactions') &&
            messageData['reactions'] != null) {
          final reactions = messageData['reactions'];
          if (reactions is List && reactions.isNotEmpty) {
            record['reactions_json'] = jsonEncode(reactions);
          }
        }
        if (messageData.containsKey('attachments') &&
            messageData['attachments'] != null) {
          final attachments = messageData['attachments'];
          if (attachments is List && attachments.isNotEmpty) {
            record['attachments_json'] = jsonEncode(attachments);
            record['has_media'] = 1;
            if (attachments.isNotEmpty && attachments[0] is Map) {
              record['media_type'] = attachments[0]['type'];
            }
          }
        }
        if (messageData.containsKey('encryptionInfo') &&
            messageData['encryptionInfo'] != null) {
          record['encryption_info_json'] = jsonEncode(
            messageData['encryptionInfo'],
          );
        }

        await db.insert('messages', record);
        count++;
      } catch (e) {
        _logger.warning('Failed to migrate message: $e');
      }
    }

    _logger.info('✅ Migrated $count messages');
    return count;
  }

  /// Migrate offline message queue (CRITICAL for mesh networking)
  static Future<int> _migrateOfflineQueue(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating offline message queue...');

    final queueJson = prefs.getStringList('offline_message_queue_v2') ?? [];
    int count = 0;

    for (final json in queueJson) {
      try {
        final queueData = jsonDecode(json);
        final now = DateTime.now().millisecondsSinceEpoch;

        final replyToMessageId = queueData['replyToMessageId'];

        await db.insert('offline_message_queue', {
          'queue_id': queueData['id'] ?? 'queue_${now}_$count',
          'message_id': queueData['id'],
          'chat_id': queueData['chatId'],
          'content': queueData['content'],
          'recipient_public_key': queueData['recipientPublicKey'],
          'sender_public_key': queueData['senderPublicKey'],
          'queued_at': queueData['queuedAt'] ?? now,
          'retry_count': queueData['attempts'] ?? 0,
          'max_retries': queueData['maxRetries'] ?? 5,
          'next_retry_at': queueData['nextRetryAt'],
          'priority': queueData['priority'] ?? 1,
          'status': queueData['status'] ?? 0,
          'attempts': queueData['attempts'] ?? 0,
          'last_attempt_at': queueData['lastAttemptAt'],
          'delivered_at': queueData['deliveredAt'],
          'failed_at': queueData['failedAt'],
          'failure_reason': queueData['failureReason'],
          'is_relay_message': queueData['isRelayMessage'] ? 1 : 0,
          'original_message_id': queueData['originalMessageId'],
          'relay_node_id': queueData['relayNodeId'],
          'message_hash': queueData['messageHash'],
          'relay_metadata_json': queueData['relayMetadata'] != null
              ? jsonEncode(queueData['relayMetadata'])
              : null,
          'reply_to_message_id': replyToMessageId?.toString(),
          'attachments_json': queueData['attachments'] != null
              ? jsonEncode(queueData['attachments'])
              : null,
          'sender_rate_count': queueData['senderRateCount'] ?? 0,
          'created_at': now,
          'updated_at': now,
        });

        count++;
      } catch (e) {
        _logger.warning('Failed to migrate queue item: $e');
      }
    }

    _logger.info('✅ Migrated $count offline queue items');
    return count;
  }

  /// Migrate deleted message IDs for queue sync
  static Future<int> _migrateDeletedMessageIds(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating deleted message IDs...');

    final deletedIds = prefs.getStringList('deleted_message_ids_v1') ?? [];
    int count = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final messageId in deletedIds) {
      try {
        await db.insert('deleted_message_ids', {
          'message_id': messageId,
          'deleted_at': now,
          'reason': 'Migrated from SharedPreferences',
        });
        count++;
      } catch (e) {
        _logger.warning('Failed to migrate deleted ID: $e');
      }
    }

    _logger.info('✅ Migrated $count deleted message IDs');
    return count;
  }

  /// Migrate device to public key mappings
  static Future<int> _migrateDeviceMappings(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating device mappings...');

    final mappingData = prefs.getString('device_public_key_mapping') ?? '';
    int count = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (mappingData.isNotEmpty) {
      for (final entry in mappingData.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          try {
            await db.insert('device_mappings', {
              'device_uuid': parts[0],
              'public_key': parts[1],
              'last_seen': now,
              'created_at': now,
              'updated_at': now,
            });
            count++;
          } catch (e) {
            _logger.warning('Failed to migrate device mapping: $e');
          }
        }
      }
    }

    _logger.info('✅ Migrated $count device mappings');
    return count;
  }

  /// Migrate contact last seen data
  static Future<int> _migrateLastSeen(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating last seen data...');

    final lastSeenData = await _getLastSeenData(prefs);
    int count = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final entry in lastSeenData.entries) {
      try {
        await db.insert('contact_last_seen', {
          'public_key': entry.key,
          'last_seen_at': entry.value,
          'was_online': 0,
          'updated_at': now,
        });
        count++;
      } catch (e) {
        _logger.warning('Failed to migrate last seen: $e');
      }
    }

    _logger.info('✅ Migrated $count last seen records');
    return count;
  }

  /// Migrate user preferences (excluding sensitive data)
  static Future<int> _migrateUserPreferences(
    DatabaseExecutor db,
    SharedPreferences prefs,
  ) async {
    _logger.info('Migrating user preferences...');

    // Only migrate non-sensitive preferences
    final keysToMigrate = ['username', 'device_id', 'app_version'];
    int count = 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final key in keysToMigrate) {
      final value = prefs.getString(key);
      if (value != null) {
        try {
          await db.insert('user_preferences', {
            'key': key,
            'value': value,
            'value_type': 'string',
            'updated_at': now,
          });
          count++;
        } catch (e) {
          _logger.warning('Failed to migrate preference $key: $e');
        }
      }
    }

    _logger.info('✅ Migrated $count user preferences');
    return count;
  }

  // Helper methods

  static Future<Map<String, int>> _getUnreadCounts(
    SharedPreferences prefs,
  ) async {
    final data = prefs.getString('chat_unread_counts') ?? '';
    final counts = <String, int>{};

    if (data.isNotEmpty) {
      for (final entry in data.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          counts[parts[0]] = int.tryParse(parts[1]) ?? 0;
        }
      }
    }
    return counts;
  }

  static Future<Map<String, int>> _getLastSeenData(
    SharedPreferences prefs,
  ) async {
    final data = prefs.getString('contact_last_seen') ?? '';
    final lastSeen = <String, int>{};

    if (data.isNotEmpty) {
      for (final entry in data.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          lastSeen[parts[0]] = int.tryParse(parts[1]) ?? 0;
        }
      }
    }
    return lastSeen;
  }

  /// Create backup of SharedPreferences data
  static Future<String> _createBackup(SharedPreferences prefs) async {
    final backup = <String, dynamic>{};

    // Backup all keys
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value != null) {
        backup[key] = value;
      }
    }

    final backupJson = jsonEncode(backup);
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupKey = 'migration_backup_$timestamp';

    await prefs.setString(backupKey, backupJson);

    _logger.info('Backup created with key: $backupKey');
    return backupKey;
  }

  /// Calculate checksums for validation

  static Future<String> _calculateContactsChecksum(DatabaseExecutor db) async {
    final result = await db.query('contacts', orderBy: 'public_key ASC');
    final data = jsonEncode(result);
    return sha256.convert(utf8.encode(data)).toString();
  }

  static Future<String> _calculateChatsChecksum(DatabaseExecutor db) async {
    final result = await db.query('chats', orderBy: 'chat_id ASC');
    final data = jsonEncode(result);
    return sha256.convert(utf8.encode(data)).toString();
  }

  static Future<String> _calculateMessagesChecksum(DatabaseExecutor db) async {
    final result = await db.query(
      'messages',
      columns: ['id', 'content'],
      orderBy: 'id ASC',
    );
    final data = jsonEncode(result);
    return sha256.convert(utf8.encode(data)).toString();
  }

  static Future<String> _calculateQueueChecksum(DatabaseExecutor db) async {
    final result = await db.query(
      'offline_message_queue',
      orderBy: 'queue_id ASC',
    );
    final data = jsonEncode(result);
    return sha256.convert(utf8.encode(data)).toString();
  }
}
