import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:pak_connect/domain/entities/queue_enums.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import '../../domain/values/id_types.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

/// Repository for offline message queue database operations
///
/// Responsibility: CRUD operations for offline message queue storage
/// - Load/save queue to persistent storage
/// - Query messages by ID, status, or peer
/// - Manage message lifecycle (pending, sending, delivered, failed)
/// - Track retry attempts and delivery status
class MessageQueueRepository
    implements IMessageQueueRepository, IConditionalMessageQueueRepository {
  static final _logger = Logger('MessageQueueRepository');
  static IDatabaseProvider? _defaultDatabaseProvider;

  // In-memory queues
  final List<QueuedMessage> directMessageQueue;
  final List<QueuedMessage> relayMessageQueue;
  final Set<MessageId> deletedMessageIds;
  final IDatabaseProvider? _databaseProvider;
  IDatabaseProvider? _resolvedDatabaseProvider;

  static void configureDefaultDatabaseProvider(
    IDatabaseProvider databaseProvider,
  ) {
    _defaultDatabaseProvider = databaseProvider;
  }

  static void clearDefaultDatabaseProvider() {
    _defaultDatabaseProvider = null;
  }

  static bool get hasDefaultDatabaseProvider =>
      _defaultDatabaseProvider != null;

  MessageQueueRepository({
    List<QueuedMessage>? directMessageQueue,
    List<QueuedMessage>? relayMessageQueue,
    Set<MessageId>? deletedMessageIds,
    IDatabaseProvider? databaseProvider,
  }) : directMessageQueue = directMessageQueue ?? [],
       relayMessageQueue = relayMessageQueue ?? [],
       deletedMessageIds = deletedMessageIds ?? {},
       _databaseProvider = databaseProvider;

  Future<Database> _getDatabase() async {
    _resolvedDatabaseProvider ??= _databaseProvider ?? _defaultDatabaseProvider;
    final provider = _resolvedDatabaseProvider;
    if (provider == null) {
      throw StateError('IDatabaseProvider not available');
    }
    return await provider.database;
  }

  /// Load entire queue from persistent storage
  @override
  Future<void> loadQueueFromStorage() async {
    try {
      final db = await _getDatabase();
      final List<Map<String, dynamic>> results = await db.query(
        'offline_message_queue',
        orderBy: 'priority DESC, queued_at ASC',
      );

      // Stage the complete load before replacing live queues. A malformed
      // later row must not leave a durable prefix published in memory.
      final loadedDirectMessages = <QueuedMessage>[];
      final loadedRelayMessages = <QueuedMessage>[];

      for (final row in results) {
        try {
          final message = queuedMessageFromDb(row);
          if (message.isRelayMessage &&
              !_isSupportedRelayPayload(message.content)) {
            await _markLegacyRelayPayloadFailed(
              db,
              message.id,
              reason: 'Unsupported plaintext relay payload from older build',
            );
            _logger.warning(
              'Dropped legacy relay payload from queue: ${message.id.shortId()}...',
            );
            continue;
          }
          if (message.isRelayMessage) {
            loadedRelayMessages.add(message);
          } else {
            loadedDirectMessages.add(message);
          }
        } catch (e) {
          _logger.severe('Failed to parse queued message: $e');
          rethrow;
        }
      }

      directMessageQueue
        ..clear()
        ..addAll(loadedDirectMessages);
      relayMessageQueue
        ..clear()
        ..addAll(loadedRelayMessages);

      final totalLoaded = directMessageQueue.length + relayMessageQueue.length;
      _logger.info(
        'Loaded $totalLoaded messages from storage (direct: ${directMessageQueue.length}, relay: ${relayMessageQueue.length})',
      );
    } catch (e) {
      _logger.severe('Failed to load message queue: $e');
      rethrow;
    }
  }

  /// Save a single message to persistent storage (optimized for individual updates)
  @override
  Future<void> saveMessageToStorage(QueuedMessage message) async {
    final row = Map<String, Object?>.unmodifiable(queuedMessageToDb(message));
    try {
      final db = await _getDatabase();

      // Use INSERT OR REPLACE for efficiency - updates if exists, inserts if not
      await db.insert(
        'offline_message_queue',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      _logger.warning('Failed to save message ${message.id.shortId()}...: $e');
      rethrow;
    }
  }

  /// Delete a single message from persistent storage
  @override
  Future<void> deleteMessageFromStorage(String messageId) {
    return deleteMessagesFromStorage([messageId]);
  }

  /// Atomically transition one delivery attempt only while its persisted
  /// ownership token still matches. This prevents a disposed queue from
  /// overwriting or deleting a successor queue's newer attempt.
  @override
  Future<QueueStateTransitionResult> transitionStateIfCurrent({
    required QueuedMessage expected,
    required QueuedMessage? replacement,
    bool includePriority = false,
  }) async {
    final predicate = _statePredicate(expected);
    final replacementColumns = replacement == null
        ? null
        : Map<String, Object?>.unmodifiable(
            _deliveryStateColumns(
              replacement,
              includePriority: includePriority,
            ),
          );
    try {
      final db = await _getDatabase();
      return await db.transaction((txn) async {
        final changed = replacement == null
            ? await txn.delete(
                'offline_message_queue',
                where: predicate.where,
                whereArgs: predicate.args,
              )
            : await txn.update(
                'offline_message_queue',
                replacementColumns!,
                where: predicate.where,
                whereArgs: predicate.args,
              );

        if (changed == 1) {
          return QueueStateTransitionResult(
            applied: true,
            current: replacement == null
                ? null
                : queuedMessageFromDb(
                    (await txn.query(
                      'offline_message_queue',
                      where: 'message_id = ?',
                      whereArgs: [expected.id],
                      limit: 1,
                    )).single,
                  ),
          );
        }

        final rows = await txn.query(
          'offline_message_queue',
          where: 'message_id = ?',
          whereArgs: [expected.id],
          limit: 1,
        );
        return QueueStateTransitionResult(
          applied: false,
          current: rows.isEmpty ? null : queuedMessageFromDb(rows.single),
        );
      });
    } catch (e) {
      _logger.warning(
        'Failed conditional queue transition for '
        '${expected.id.shortId()}...: $e',
      );
      rethrow;
    }
  }

  /// Atomically admit a peer-synced row without overwriting an active attempt
  /// or reviving a message that was durably deleted.
  @override
  Future<QueueStateTransitionResult> insertMessageIfAbsentAndNotDeleted(
    QueuedMessage message,
  ) async {
    final row = Map<String, Object?>.unmodifiable(queuedMessageToDb(message));
    try {
      final db = await _getDatabase();
      return await db.transaction((txn) async {
        final tombstone = await txn.query(
          'deleted_message_ids',
          columns: const <String>['message_id'],
          where: 'message_id = ?',
          whereArgs: [message.id],
          limit: 1,
        );
        if (tombstone.isNotEmpty) {
          return const QueueStateTransitionResult(
            applied: false,
            current: null,
          );
        }

        await txn.insert(
          'offline_message_queue',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final changes = await txn.rawQuery('SELECT changes() AS count');
        final inserted = (changes.single['count'] as int) == 1;
        final rows = await txn.query(
          'offline_message_queue',
          where: 'message_id = ?',
          whereArgs: [message.id],
          limit: 1,
        );
        return QueueStateTransitionResult(
          applied: inserted,
          current: rows.isEmpty ? null : queuedMessageFromDb(rows.single),
        );
      });
    } catch (e) {
      _logger.warning(
        'Failed atomic synced-message admission for '
        '${message.id.shortId()}...: $e',
      );
      rethrow;
    }
  }

  /// Delete messages from persistent storage in one transaction.
  @override
  Future<void> deleteMessagesFromStorage(Iterable<String> messageIds) async {
    final ids = _snapshotMessageIds(messageIds);
    if (ids.isEmpty) return;

    try {
      final db = await _getDatabase();
      await db.transaction((txn) async {
        for (final id in ids) {
          await txn.delete(
            'offline_message_queue',
            where: 'message_id = ?',
            whereArgs: [id],
          );
        }
      });
    } catch (e) {
      _logger.warning('Failed to delete ${ids.length} queued message(s): $e');
      rethrow;
    }
  }

  /// Save entire queue to persistent storage
  @override
  Future<void> saveQueueToStorage() {
    return saveQueueSnapshotToStorage([
      ...directMessageQueue,
      ...relayMessageQueue,
    ]);
  }

  /// Replace the durable queue from a detached point-in-time snapshot.
  @override
  Future<void> saveQueueSnapshotToStorage(
    Iterable<QueuedMessage> messages,
  ) async {
    // QueuedMessage is mutable. Convert every message to a detached immutable
    // row before the first await so caller mutations cannot change this write.
    final rows = List<Map<String, Object?>>.unmodifiable(
      messages.map(
        (message) =>
            Map<String, Object?>.unmodifiable(queuedMessageToDb(message)),
      ),
    );

    try {
      final db = await _getDatabase();

      // Use transaction for atomic operations
      await db.transaction((txn) async {
        // Clear and reinsert all messages
        await txn.delete('offline_message_queue');

        for (final row in rows) {
          await txn.insert('offline_message_queue', row);
        }
      });
    } catch (e) {
      _logger.warning('Failed to save message queue: $e');
      rethrow;
    }
  }

  /// Load deleted message IDs from persistent storage
  @override
  Future<void> loadDeletedMessageIds() async {
    try {
      final db = await _getDatabase();
      final List<Map<String, dynamic>> results = await db.query(
        'deleted_message_ids',
      );

      final loadedDeletedMessageIds = <MessageId>{};
      for (final row in results) {
        final raw = row['message_id'] as String;
        loadedDeletedMessageIds.add(MessageId(raw));
      }

      deletedMessageIds
        ..clear()
        ..addAll(loadedDeletedMessageIds);

      _logger.info('Loaded ${deletedMessageIds.length} deleted message IDs');
    } catch (e) {
      _logger.severe('Failed to load deleted message IDs: $e');
      rethrow;
    }
  }

  /// Save deleted message IDs to persistent storage
  @override
  Future<void> saveDeletedMessageIds() {
    return saveDeletedIdsSnapshotToStorage(
      deletedMessageIds.map((id) => id.value),
    );
  }

  @override
  Set<String> getDeletedMessageIdsSnapshot() => Set<String>.unmodifiable(
    deletedMessageIds.map((messageId) => messageId.value),
  );

  /// Replace durable tombstones while retaining their original timestamps.
  @override
  Future<void> saveDeletedIdsSnapshotToStorage(
    Iterable<String> messageIds,
  ) async {
    final ids = _snapshotMessageIds(messageIds);

    try {
      final db = await _getDatabase();

      await db.transaction((txn) async {
        final existingRows = await txn.query('deleted_message_ids');
        final existingRowsById = <String, Map<String, Object?>>{};
        for (final row in existingRows) {
          final id = row['message_id'] as String;
          existingRowsById[id] = row;
        }

        final deletedAt = DateTime.now().millisecondsSinceEpoch;
        await txn.delete('deleted_message_ids');

        for (final id in ids) {
          final existing = existingRowsById[id];
          final row = <String, Object?>{
            'message_id': id,
            'deleted_at': existing?['deleted_at'] ?? deletedAt,
          };
          // The canonical schema has a nullable reason column, while the
          // minimal queue-table bootstrap does not. Preserve it when present.
          if (existing?.containsKey('reason') ?? false) {
            row['reason'] = existing!['reason'];
          }
          await txn.insert('deleted_message_ids', row);
        }
      });
    } catch (e) {
      _logger.warning('Failed to save deleted message IDs: $e');
      rethrow;
    }
  }

  /// Get message by ID
  @override
  QueuedMessage? getMessageById(String messageId) {
    final id = MessageId(messageId);
    return getAllMessages()
        .where((m) => MessageId(m.id) == id)
        .cast<QueuedMessage?>()
        .firstWhere((m) => m != null, orElse: () => null);
  }

  /// Get messages by status
  @override
  List<QueuedMessage> getMessagesByStatus(QueuedMessageStatus status) {
    return getAllMessages().where((m) => m.status == status).toList();
  }

  /// Get all pending messages
  @override
  List<QueuedMessage> getPendingMessages() {
    return getMessagesByStatus(QueuedMessageStatus.pending);
  }

  /// Remove message from queue by ID
  @override
  Future<void> removeMessage(String messageId) async {
    await deleteMessageFromStorage(messageId);
    removeMessageFromQueue(messageId);
  }

  /// Get oldest pending message
  @override
  QueuedMessage? getOldestPendingMessage() {
    final pending = getAllMessages()
        .where((m) => m.status == QueuedMessageStatus.pending)
        .toList();

    if (pending.isEmpty) return null;

    pending.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return pending.first;
  }

  /// Get all messages from both queues
  @override
  List<QueuedMessage> getAllMessages() {
    return [...directMessageQueue, ...relayMessageQueue];
  }

  /// Insert message into queue by priority
  @override
  void insertMessageByPriority(QueuedMessage message) {
    // Determine target queue
    final targetQueue = message.isRelayMessage
        ? relayMessageQueue
        : directMessageQueue;

    final insertIndex = targetQueue.indexWhere((existing) {
      if (existing.priority.index != message.priority.index) {
        return existing.priority.index < message.priority.index;
      }
      return existing.queuedAt.isAfter(message.queuedAt);
    });
    final resolvedInsertIndex = insertIndex < 0
        ? targetQueue.length
        : insertIndex;

    targetQueue.insert(resolvedInsertIndex, message);

    _logger.fine(
      'Inserted into ${message.isRelayMessage ? "relay" : "direct"} queue at index $resolvedInsertIndex (queue size: ${targetQueue.length})',
    );
  }

  /// Remove message from queue
  @override
  void removeMessageFromQueue(String messageId) {
    final id = MessageId(messageId);
    directMessageQueue.removeWhere((m) => MessageId(m.id) == id);
    relayMessageQueue.removeWhere((m) => MessageId(m.id) == id);
  }

  /// Check if message was previously deleted
  @override
  bool isMessageDeleted(String messageId) {
    return deletedMessageIds.contains(MessageId(messageId));
  }

  /// Mark message as deleted for sync purposes
  @override
  Future<void> markMessageDeleted(String messageId) {
    return markMessagesDeleted([messageId]);
  }

  /// Atomically tombstone messages and remove their active queue rows.
  @override
  Future<void> markMessagesDeleted(Iterable<String> messageIds) async {
    final ids = _snapshotMessageIds(messageIds);
    if (ids.isEmpty) return;

    try {
      final deletedAt = DateTime.now().millisecondsSinceEpoch;
      final db = await _getDatabase();
      await db.transaction((txn) async {
        for (final id in ids) {
          // Ignore existing tombstones so their first-deletion timestamp is
          // never refreshed by a repeated sync/delete request.
          await txn.insert('deleted_message_ids', {
            'message_id': id,
            'deleted_at': deletedAt,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          await txn.delete(
            'offline_message_queue',
            where: 'message_id = ?',
            whereArgs: [id],
          );
        }
      });

      // Publish only after both tables commit successfully.
      final typedIds = ids.map(MessageId.new).toSet();
      deletedMessageIds.addAll(typedIds);
      directMessageQueue.removeWhere(
        (message) => typedIds.contains(MessageId(message.id)),
      );
      relayMessageQueue.removeWhere(
        (message) => typedIds.contains(MessageId(message.id)),
      );
    } catch (e) {
      _logger.warning('Failed to tombstone ${ids.length} message(s): $e');
      rethrow;
    }

    _logger.info('${ids.length} message(s) marked as deleted');
  }

  /// Keep only the newest durable tombstones and publish after commit.
  @override
  Future<Set<String>> pruneDeletedMessageIds(int maxRetained) async {
    if (maxRetained < 0) {
      throw ArgumentError.value(
        maxRetained,
        'maxRetained',
        'must not be negative',
      );
    }

    try {
      final db = await _getDatabase();
      final retainedIds = await db.transaction((txn) async {
        if (maxRetained == 0) {
          await txn.delete('deleted_message_ids');
        } else {
          await txn.rawDelete(
            '''
            DELETE FROM deleted_message_ids
            WHERE message_id NOT IN (
              SELECT message_id
              FROM deleted_message_ids
              ORDER BY deleted_at DESC, message_id ASC
              LIMIT ?
            )
            ''',
            [maxRetained],
          );
        }

        final rows = await txn.query(
          'deleted_message_ids',
          columns: const ['message_id'],
          orderBy: 'deleted_at DESC, message_id ASC',
        );
        final retained = List<String>.unmodifiable(
          rows.map((row) => row['message_id'] as String),
        );
        return retained;
      });

      deletedMessageIds
        ..clear()
        ..addAll(retainedIds.map(MessageId.new));
      return Set<String>.unmodifiable(retainedIds);
    } catch (e) {
      _logger.warning('Failed to prune deleted message IDs: $e');
      rethrow;
    }
  }

  /// Convert QueuedMessage to database row
  @override
  Map<String, dynamic> queuedMessageToDb(QueuedMessage message) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final replyId = message.replyToMessageId != null
        ? MessageId(message.replyToMessageId!)
        : null;
    final chat = ChatId(message.chatId);
    return {
      'queue_id': message.id,
      'message_id': message.id,
      'chat_id': chat.value,
      'content': message.content,
      'recipient_public_key': message.recipientPublicKey,
      'sender_public_key': message.senderPublicKey,
      'queued_at': message.queuedAt.millisecondsSinceEpoch,
      'retry_count': message.attempts,
      'max_retries': message.maxRetries,
      'next_retry_at': message.nextRetryAt?.millisecondsSinceEpoch,
      'priority': message.priority.index,
      'status': message.status.index,
      'attempts': message.attempts,
      'last_attempt_at': message.lastAttemptAt?.millisecondsSinceEpoch,
      'delivered_at': message.deliveredAt?.millisecondsSinceEpoch,
      'failed_at': message.failedAt?.millisecondsSinceEpoch,
      'failure_reason': message.failureReason,
      'expires_at': message.expiresAt?.millisecondsSinceEpoch,
      'is_relay_message': message.isRelayMessage ? 1 : 0,
      'original_message_id': message.originalMessageId,
      'relay_node_id': message.relayNodeId,
      'message_hash': message.messageHash,
      'relay_metadata_json': message.relayMetadata != null
          ? jsonEncode(message.relayMetadata!.toJson())
          : null,
      'reply_to_message_id': replyId?.value ?? message.replyToMessageId,
      'attachments_json': message.attachments.isNotEmpty
          ? jsonEncode(message.attachments)
          : null,
      'sender_rate_count': message.senderRateCount,
      'created_at': now,
      'updated_at': now,
    };
  }

  ({String where, List<Object?> args}) _statePredicate(QueuedMessage expected) {
    final lastAttemptAt = expected.lastAttemptAt?.millisecondsSinceEpoch;
    return (
      where:
          'message_id = ? AND status = ? AND attempts = ? AND '
          '${lastAttemptAt == null ? 'last_attempt_at IS NULL' : 'last_attempt_at = ?'}',
      args: <Object?>[
        expected.id,
        expected.status.index,
        expected.attempts,
        ?lastAttemptAt,
      ],
    );
  }

  Map<String, Object?> _deliveryStateColumns(
    QueuedMessage message, {
    required bool includePriority,
  }) {
    return <String, Object?>{
      if (includePriority) 'priority': message.priority.index,
      'retry_count': message.attempts,
      'status': message.status.index,
      'attempts': message.attempts,
      'last_attempt_at': message.lastAttemptAt?.millisecondsSinceEpoch,
      'next_retry_at': message.nextRetryAt?.millisecondsSinceEpoch,
      'delivered_at': message.deliveredAt?.millisecondsSinceEpoch,
      'failed_at': message.failedAt?.millisecondsSinceEpoch,
      'failure_reason': message.failureReason,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Convert database row to QueuedMessage
  @override
  QueuedMessage queuedMessageFromDb(Map<String, dynamic> row) {
    final replyId = row['reply_to_message_id'] as String?;
    final chatId = row['chat_id'] as String;

    return QueuedMessage(
      id: row['message_id'] as String,
      chatId: ChatId(chatId).value,
      content: row['content'] as String,
      recipientPublicKey: row['recipient_public_key'] as String,
      senderPublicKey: row['sender_public_key'] as String,
      priority: MessagePriority.values[row['priority'] as int],
      queuedAt: DateTime.fromMillisecondsSinceEpoch(row['queued_at'] as int),
      maxRetries: row['max_retries'] as int,
      replyToMessageId: replyId != null ? MessageId(replyId).value : null,
      attachments: row['attachments_json'] != null
          ? List<String>.from(jsonDecode(row['attachments_json'] as String))
          : [],
      status: QueuedMessageStatus.values[row['status'] as int],
      attempts: row['attempts'] as int,
      lastAttemptAt: row['last_attempt_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['last_attempt_at'] as int)
          : null,
      nextRetryAt: row['next_retry_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['next_retry_at'] as int)
          : null,
      deliveredAt: row['delivered_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['delivered_at'] as int)
          : null,
      failedAt: row['failed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['failed_at'] as int)
          : null,
      failureReason: row['failure_reason'] as String?,
      expiresAt: row['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int)
          : null,
      isRelayMessage: (row['is_relay_message'] as int) == 1,
      relayMetadata: row['relay_metadata_json'] != null
          ? RelayMetadata.fromJson(
              jsonDecode(row['relay_metadata_json'] as String),
            )
          : null,
      originalMessageId: row['original_message_id'] as String?,
      relayNodeId: row['relay_node_id'] as String?,
      messageHash: row['message_hash'] as String?,
      senderRateCount: row['sender_rate_count'] as int? ?? 0,
    );
  }

  bool _isSupportedRelayPayload(String payload) {
    if (payload.isEmpty) {
      return false;
    }

    try {
      final protocolBytes = Uint8List.fromList(base64.decode(payload));
      final protocolMessage = ProtocolMessage.fromBytes(protocolBytes);
      return protocolMessage.type == ProtocolMessageType.textMessage &&
          protocolMessage.version >= 2;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markLegacyRelayPayloadFailed(
    Database db,
    String messageId, {
    required String reason,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'offline_message_queue',
      {
        'status': QueuedMessageStatus.failed.index,
        'failed_at': now,
        'failure_reason': reason,
        'updated_at': now,
      },
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  List<String> _snapshotMessageIds(Iterable<String> messageIds) {
    return List<String>.unmodifiable(
      messageIds.map((id) => MessageId(id).value).toSet(),
    );
  }
}
