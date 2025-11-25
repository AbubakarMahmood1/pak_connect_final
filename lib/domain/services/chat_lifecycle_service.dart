import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/interfaces/i_archive_repository.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../core/interfaces/i_message_repository.dart';
import '../entities/archived_chat.dart';
import '../entities/chat_list_item.dart';
import '../entities/enhanced_message.dart';
import '../entities/message.dart';
import '../../core/models/archive_models.dart';
import 'archive_management_service.dart';
import 'chat_management_models.dart';
import 'chat_notification_service.dart';
import 'chat_sync_service.dart';

/// Chat lifecycle operations: archive/pin/star, delete, export, analytics
class ChatLifecycleService {
  final _logger = Logger('ChatLifecycleService');

  final IChatsRepository _chatsRepository;
  final IMessageRepository _messageRepository;
  final IArchiveRepository _archiveRepository;
  final ArchiveManagementService _archiveManagementService;
  final ChatCacheState _cacheState;
  final ChatNotificationService _notificationService;
  final ChatSyncService _syncService;

  ChatLifecycleService({
    required IChatsRepository chatsRepository,
    required IMessageRepository messageRepository,
    required IArchiveRepository archiveRepository,
    required ArchiveManagementService archiveManagementService,
    required ChatCacheState cacheState,
    required ChatNotificationService notificationService,
    required ChatSyncService syncService,
  }) : _chatsRepository = chatsRepository,
       _messageRepository = messageRepository,
       _archiveRepository = archiveRepository,
       _archiveManagementService = archiveManagementService,
       _cacheState = cacheState,
       _notificationService = notificationService,
       _syncService = syncService;

  Future<ChatOperationResult> toggleMessageStar(String messageId) async {
    try {
      if (_cacheState.starredMessageIds.contains(messageId)) {
        _cacheState.starredMessageIds.remove(messageId);
        await _syncService.saveStarredMessages();
        _notificationService.emitMessageUpdate(
          MessageUpdateEvent.unstarred(messageId),
        );
        return ChatOperationResult.success('Message unstarred');
      } else {
        _cacheState.starredMessageIds.add(messageId);
        await _syncService.saveStarredMessages();
        _notificationService.emitMessageUpdate(
          MessageUpdateEvent.starred(messageId),
        );
        return ChatOperationResult.success('Message starred');
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to update star status: $e');
    }
  }

  Future<List<EnhancedMessage>> getStarredMessages() async {
    try {
      final allChats = await _chatsRepository.getAllChats();
      final List<EnhancedMessage> starredMessages = [];

      for (final chat in allChats) {
        final messages = await _messageRepository.getMessages(chat.chatId);
        for (final message in messages) {
          if (_cacheState.starredMessageIds.contains(message.id)) {
            final enhanced = EnhancedMessage.fromMessage(
              message,
            ).copyWith(isStarred: true);
            starredMessages.add(enhanced);
          }
        }
      }

      starredMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return starredMessages;
    } catch (e) {
      _logger.severe('Failed to get starred messages: $e');
      return [];
    }
  }

  Future<ChatOperationResult> deleteMessages({
    required List<String> messageIds,
    bool deleteForEveryone = false,
  }) async {
    try {
      int successCount = 0;
      int failureCount = 0;

      for (final messageId in messageIds) {
        try {
          final chats = await _chatsRepository.getAllChats();
          bool found = false;

          for (final chat in chats) {
            final messages = await _messageRepository.getMessages(chat.chatId);
            final messageIndex = messages.indexWhere((m) => m.id == messageId);

            if (messageIndex != -1) {
              found = true;
              await _deleteMessageFromRepository(messageId, chat.chatId);

              _cacheState.starredMessageIds.remove(messageId);
              _notificationService.emitMessageUpdate(
                MessageUpdateEvent.deleted(messageId, chat.chatId),
              );
              successCount++;
              break;
            }
          }

          if (!found) {
            failureCount++;
          }
        } catch (e) {
          _logger.warning('Failed to delete message $messageId: $e');
          failureCount++;
        }
      }

      if (successCount > 0) {
        await _syncService.saveStarredMessages();
      }

      if (failureCount == 0) {
        return ChatOperationResult.success(
          '$successCount message${successCount > 1 ? 's' : ''} deleted',
        );
      } else {
        return ChatOperationResult.partial(
          '$successCount deleted, $failureCount failed',
        );
      }
    } catch (e) {
      return ChatOperationResult.failure('Delete operation failed: $e');
    }
  }

  Future<ChatOperationResult> toggleChatArchive(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    try {
      if (_cacheState.archivedChats.contains(chatId)) {
        if (useEnhancedArchive) {
          final archiveSummary = await _archiveRepository
              .getArchivedChatByOriginalId(chatId);

          if (archiveSummary != null) {
            final restoreResult = await _archiveManagementService.restoreChat(
              archiveId: archiveSummary.id,
            );

            if (restoreResult.success) {
              _cacheState.archivedChats.remove(chatId);
              await _syncService.saveArchivedChats();
              _notificationService.emitChatUpdate(
                ChatUpdateEvent.unarchived(chatId),
              );
              return ChatOperationResult.success(
                'Chat restored from enhanced archive',
              );
            } else {
              return ChatOperationResult.failure(
                'Failed to restore enhanced archive: ${restoreResult.message}',
              );
            }
          }
        }

        _cacheState.archivedChats.remove(chatId);
        await _syncService.saveArchivedChats();
        _notificationService.emitChatUpdate(ChatUpdateEvent.unarchived(chatId));
        return ChatOperationResult.success('Chat unarchived');
      } else {
        if (useEnhancedArchive) {
          final archiveResult = await _archiveManagementService.archiveChat(
            chatId: chatId,
            reason: reason ?? 'User archived via chat management',
          );

          if (archiveResult.success) {
            _cacheState.archivedChats.add(chatId);
            await _syncService.saveArchivedChats();
            _notificationService.emitChatUpdate(
              ChatUpdateEvent.archived(chatId),
            );
            return ChatOperationResult.success(
              'Chat archived with enhanced system',
            );
          } else {
            return ChatOperationResult.failure(
              'Enhanced archive failed: ${archiveResult.message}',
            );
          }
        } else {
          _cacheState.archivedChats.add(chatId);
          await _syncService.saveArchivedChats();
          _notificationService.emitChatUpdate(ChatUpdateEvent.archived(chatId));
          return ChatOperationResult.success('Chat archived');
        }
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to toggle archive: $e');
    }
  }

  Future<ChatOperationResult> toggleChatPin(String chatId) async {
    try {
      if (_cacheState.pinnedChats.contains(chatId)) {
        _cacheState.pinnedChats.remove(chatId);
        await _syncService.savePinnedChats();
        _notificationService.emitChatUpdate(ChatUpdateEvent.unpinned(chatId));
        return ChatOperationResult.success('Chat unpinned');
      } else {
        if (_cacheState.pinnedChats.length >= 3) {
          return ChatOperationResult.failure('Maximum 3 chats can be pinned');
        }
        _cacheState.pinnedChats.add(chatId);
        await _syncService.savePinnedChats();
        _notificationService.emitChatUpdate(ChatUpdateEvent.pinned(chatId));
        return ChatOperationResult.success('Chat pinned');
      }
    } catch (e) {
      return ChatOperationResult.failure('Failed to toggle pin: $e');
    }
  }

  Future<ChatOperationResult> deleteChat(String chatId) async {
    try {
      final chatMessages = await _messageRepository.getMessages(chatId);
      for (final message in chatMessages) {
        _cacheState.starredMessageIds.remove(message.id);
      }

      await _messageRepository.clearMessages(chatId);

      _cacheState.archivedChats.remove(chatId);
      _cacheState.pinnedChats.remove(chatId);

      await _syncService.saveArchivedChats();
      await _syncService.savePinnedChats();
      await _syncService.saveStarredMessages();

      _notificationService.emitChatUpdate(ChatUpdateEvent.deleted(chatId));

      return ChatOperationResult.success('Chat deleted');
    } catch (e) {
      return ChatOperationResult.failure('Failed to delete chat: $e');
    }
  }

  Future<ChatOperationResult> clearChatMessages(String chatId) async {
    try {
      final chatMessages = await _messageRepository.getMessages(chatId);
      for (final message in chatMessages) {
        _cacheState.starredMessageIds.remove(message.id);
      }

      await _messageRepository.clearMessages(chatId);
      await _syncService.saveStarredMessages();

      _notificationService.emitChatUpdate(
        ChatUpdateEvent.messagesCleared(chatId),
      );

      return ChatOperationResult.success('Chat messages cleared');
    } catch (e) {
      return ChatOperationResult.failure('Failed to clear messages: $e');
    }
  }

  Future<ChatAnalytics> getChatAnalytics(String chatId) async {
    try {
      final messages = await _messageRepository.getMessages(chatId);
      final enhancedMessages = messages
          .map((m) => EnhancedMessage.fromMessage(m))
          .toList();

      final totalMessages = enhancedMessages.length;
      final myMessages = enhancedMessages.where((m) => m.isFromMe).length;
      final theirMessages = totalMessages - myMessages;
      final starredCount = enhancedMessages
          .where((m) => _cacheState.starredMessageIds.contains(m.id))
          .length;

      final firstMessage = enhancedMessages.isNotEmpty
          ? enhancedMessages.reduce(
              (a, b) => a.timestamp.isBefore(b.timestamp) ? a : b,
            )
          : null;

      final lastMessage = enhancedMessages.isNotEmpty
          ? enhancedMessages.reduce(
              (a, b) => a.timestamp.isAfter(b.timestamp) ? a : b,
            )
          : null;

      final averageMessageLength = enhancedMessages.isNotEmpty
          ? enhancedMessages
                    .map((m) => m.content.length)
                    .reduce((a, b) => a + b) /
                enhancedMessages.length
          : 0.0;

      final messagesByDay = _groupMessagesByDay(enhancedMessages);
      final busiestDay = messagesByDay.entries.isNotEmpty
          ? messagesByDay.entries.reduce((a, b) => a.value > b.value ? a : b)
          : null;

      return ChatAnalytics(
        chatId: chatId,
        totalMessages: totalMessages,
        myMessages: myMessages,
        theirMessages: theirMessages,
        starredMessages: starredCount,
        firstMessage: firstMessage?.timestamp,
        lastMessage: lastMessage?.timestamp,
        averageMessageLength: averageMessageLength,
        messagesByDay: messagesByDay,
        busiestDay: busiestDay?.key,
        busiestDayCount: busiestDay?.value ?? 0,
      );
    } catch (e) {
      _logger.severe('Failed to get chat analytics: $e');
      return ChatAnalytics.empty(chatId);
    }
  }

  Future<ChatOperationResult> exportChat({
    required String chatId,
    ChatExportFormat format = ChatExportFormat.text,
    bool includeMetadata = false,
  }) async {
    try {
      final messages = await _messageRepository.getMessages(chatId);
      final chat = (await _chatsRepository.getAllChats())
          .where((c) => c.chatId == chatId)
          .firstOrNull;

      if (chat == null) {
        return ChatOperationResult.failure('Chat not found');
      }

      String exportData;
      switch (format) {
        case ChatExportFormat.text:
          exportData = _exportChatAsText(messages, chat, includeMetadata);
          break;
        case ChatExportFormat.json:
          exportData = _exportChatAsJson(messages, chat, includeMetadata);
          break;
        case ChatExportFormat.csv:
          exportData = _exportChatAsCsv(messages, chat, includeMetadata);
          break;
      }

      await _saveExportedData(exportData, format, chatId);
      _logger.info(
        'Exported chat ${chat.contactName} (${messages.length} messages) as ${format.name}',
      );
      return ChatOperationResult.success(
        'Chat exported successfully to local storage',
      );
    } catch (e) {
      return ChatOperationResult.failure('Export failed: $e');
    }
  }

  Future<ComprehensiveChatAnalytics> getComprehensiveChatAnalytics(
    String chatId,
  ) async {
    try {
      final liveAnalytics = await getChatAnalytics(chatId);

      ArchivedChatAnalytics? archiveAnalytics;
      try {
        final archives = await _archiveRepository.getArchivedChats(
          filter: ArchiveSearchFilter(contactFilter: chatId),
          offset: 0,
        );

        if (archives.isNotEmpty) {
          final archive = await _archiveRepository.getArchivedChat(
            archives.first.id,
          );
          if (archive != null) {
            archiveAnalytics = _calculateArchivedChatAnalytics(archive);
          }
        }
      } catch (e) {
        _logger.warning('Failed to get archive analytics: $e');
      }

      return ComprehensiveChatAnalytics(
        chatId: chatId,
        liveAnalytics: liveAnalytics,
        archiveAnalytics: archiveAnalytics,
        combinedMetrics: _calculateCombinedMetrics(
          liveAnalytics,
          archiveAnalytics,
        ),
      );
    } catch (e) {
      _logger.severe('Failed to get comprehensive analytics: $e');
      return ComprehensiveChatAnalytics.error(chatId);
    }
  }

  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    final results = <String, ChatOperationResult>{};

    for (final chatId in chatIds) {
      try {
        final result = await toggleChatArchive(
          chatId,
          reason: reason,
          useEnhancedArchive: useEnhancedArchive,
        );
        results[chatId] = result;
      } catch (e) {
        results[chatId] = ChatOperationResult.failure(
          'Batch archive failed: $e',
        );
      }
    }

    final successful = results.values.where((r) => r.success).length;
    final failed = results.length - successful;

    return BatchArchiveResult(
      results: results,
      totalProcessed: chatIds.length,
      successful: successful,
      failed: failed,
    );
  }

  ArchiveManagementService get archiveManager => _archiveManagementService;

  // Private helpers

  Map<DateTime, int> _groupMessagesByDay(List<EnhancedMessage> messages) {
    final grouped = <DateTime, int>{};

    for (final message in messages) {
      final day = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      grouped[day] = (grouped[day] ?? 0) + 1;
    }

    return grouped;
  }

  String _exportChatAsText(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final buffer = StringBuffer();
    buffer.writeln('Chat Export: ${chat.contactName}');
    buffer.writeln('Generated: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Messages: ${messages.length}');
    buffer.writeln('=' * 50);
    buffer.writeln();

    for (final message in messages) {
      final timestamp = message.timestamp.toLocal();
      final sender = message.isFromMe ? 'You' : chat.contactName;

      buffer.writeln('[${timestamp.toString().split('.')[0]}] $sender:');
      buffer.writeln(message.content);

      if (includeMetadata) {
        buffer.writeln('  Status: ${message.status.name}');
        if (_cacheState.starredMessageIds.contains(message.id)) {
          buffer.writeln('  ⭐ Starred');
        }
      }

      buffer.writeln();
    }

    return buffer.toString();
  }

  String _exportChatAsJson(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final exportData = {
      'chat_info': {
        'contact_name': chat.contactName,
        'chat_id': chat.chatId,
        'export_timestamp': DateTime.now().toIso8601String(),
        'message_count': messages.length,
      },
      'messages': messages.map((message) {
        final data = message.toJson();
        if (includeMetadata) {
          data['is_starred'] = _cacheState.starredMessageIds.contains(
            message.id,
          );
        }
        return data;
      }).toList(),
    };

    return jsonEncode(exportData);
  }

  String _exportChatAsCsv(
    List<Message> messages,
    ChatListItem chat,
    bool includeMetadata,
  ) {
    final csvLines = <String>[];

    var header = ['Timestamp', 'Sender', 'Message', 'Status'];
    if (includeMetadata) {
      header.add('Starred');
    }
    csvLines.add(header.map((field) => '"$field"').join(','));

    for (final message in messages) {
      final timestamp = message.timestamp.toIso8601String();
      final sender = message.isFromMe ? 'You' : chat.contactName;
      final content = message.content.replaceAll('"', '""');
      final status = message.status.name;

      var row = [timestamp, sender, content, status];
      if (includeMetadata) {
        row.add(
          _cacheState.starredMessageIds.contains(message.id) ? 'Yes' : 'No',
        );
      }

      csvLines.add(row.map((field) => '"$field"').join(','));
    }

    return csvLines.join('\n');
  }

  Future<void> _deleteMessageFromRepository(
    String messageId,
    String chatId,
  ) async {
    try {
      final success = await _messageRepository.deleteMessage(messageId);
      if (success) {
        _logger.info('Successfully deleted message: $messageId from $chatId');
      } else {
        _logger.warning('Failed to delete message - not found: $messageId');
        throw Exception('Message not found');
      }
    } catch (e) {
      _logger.severe('Error deleting message: $e');
      throw Exception('Failed to delete message: $e');
    }
  }

  Future<void> _saveExportedData(
    String data,
    ChatExportFormat format,
    String chatId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'chat_export_${format.name}_${chatId}_$timestamp';
      await prefs.setString(key, data);

      final exports = prefs.getStringList('chat_exports') ?? [];
      exports.add(
        jsonEncode({
          'key': key,
          'chat_id': chatId,
          'format': format.name,
          'timestamp': timestamp,
          'size': data.length,
        }),
      );
      await prefs.setStringList('chat_exports', exports);

      _logger.info('Exported chat data saved with key: $key');
    } catch (e) {
      _logger.warning('Failed to save exported data: $e');
    }
  }

  ArchivedChatAnalytics _calculateArchivedChatAnalytics(ArchivedChat archive) {
    final totalMessages = archive.messageCount;
    final myMessages = archive.messages.where((m) => m.isFromMe).length;
    final theirMessages = totalMessages - myMessages;
    final starredCount = archive.messages.where((m) => m.isStarred).length;

    return ArchivedChatAnalytics(
      archiveId: archive.id,
      totalMessages: totalMessages,
      myMessages: myMessages,
      theirMessages: theirMessages,
      starredMessages: starredCount,
      archivedAt: archive.archivedAt,
      originalDateRange:
          archive.lastMessageTime != null && archive.messages.isNotEmpty
          ? DateTimeRange(
              start: archive.messages
                  .map((m) => m.originalTimestamp)
                  .reduce((a, b) => a.isBefore(b) ? a : b),
              end: archive.lastMessageTime!,
            )
          : null,
      averageMessageLength: archive.messages.isNotEmpty
          ? archive.messages
                    .map((m) => m.content.length)
                    .reduce((a, b) => a + b) /
                archive.messages.length
          : 0.0,
      compressionRatio: archive.compressionInfo?.compressionRatio ?? 1.0,
    );
  }

  CombinedChatMetrics _calculateCombinedMetrics(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final totalLiveMessages = liveAnalytics.totalMessages;
    final totalArchivedMessages = archiveAnalytics?.totalMessages ?? 0;
    final totalMessages = totalLiveMessages + totalArchivedMessages;

    return CombinedChatMetrics(
      totalMessages: totalMessages,
      liveMessages: totalLiveMessages,
      archivedMessages: totalArchivedMessages,
      archivePercentage: totalMessages > 0
          ? (totalArchivedMessages / totalMessages) * 100
          : 0.0,
      hasArchives: archiveAnalytics != null,
      oldestMessage: _getOldestMessageDate(liveAnalytics, archiveAnalytics),
      newestMessage: _getNewestMessageDate(liveAnalytics, archiveAnalytics),
    );
  }

  DateTime? _getOldestMessageDate(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final liveOldest = liveAnalytics.firstMessage;
    final archivedOldest = archiveAnalytics?.originalDateRange?.start;

    if (liveOldest == null && archivedOldest == null) return null;
    if (liveOldest == null) return archivedOldest;
    if (archivedOldest == null) return liveOldest;

    return liveOldest.isBefore(archivedOldest) ? liveOldest : archivedOldest;
  }

  DateTime? _getNewestMessageDate(
    ChatAnalytics liveAnalytics,
    ArchivedChatAnalytics? archiveAnalytics,
  ) {
    final liveNewest = liveAnalytics.lastMessage;
    final archivedNewest = archiveAnalytics?.originalDateRange?.end;

    if (liveNewest == null && archivedNewest == null) return null;
    if (liveNewest == null) return archivedNewest;
    if (archivedNewest == null) return liveNewest;

    return liveNewest.isAfter(archivedNewest) ? liveNewest : archivedNewest;
  }
}
