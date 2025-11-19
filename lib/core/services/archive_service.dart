import 'dart:async';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';
import '../interfaces/i_archive_repository.dart';
import '../../domain/services/archive_management_service.dart';
import '../../core/models/archive_models.dart';
import '../interfaces/i_archive_service.dart';
import '../../domain/services/chat_management_service.dart';

/// Archive service implementation for managing chat archives
/// Handles archiving/unarchiving, analytics, and batch operations
class ArchiveService implements IArchiveService {
  static final _logger = Logger('ArchiveService');

  final IArchiveRepository _archiveRepository;
  final ArchiveManagementService _archiveManagementService;

  static const String _archivedChatsKey = 'archived_chats';

  // In-memory cache for archived chats
  final Set<String> _archivedChats = {};

  ArchiveService({
    IArchiveRepository? archiveRepository,
    ArchiveManagementService? archiveManagementService,
  }) : _archiveRepository =
           archiveRepository ?? GetIt.instance<IArchiveRepository>(),
       _archiveManagementService =
           archiveManagementService ?? ArchiveManagementService.instance {
    _logger.info('✅ ArchiveService initialized');
  }

  @override
  Future<ChatOperationResult> archiveChat(
    String chatId, {
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    try {
      if (useEnhancedArchive) {
        final archiveResult = await _archiveManagementService.archiveChat(
          chatId: chatId,
          reason: reason ?? 'User archived via chat management',
        );

        if (archiveResult.success) {
          _archivedChats.add(chatId);
          await saveArchivedChats();
          _logger.info('✅ Chat archived: $chatId');
          return ChatOperationResult.success(
            'Chat archived with enhanced system',
          );
        } else {
          return ChatOperationResult.failure(
            'Enhanced archive failed: ${archiveResult.message}',
          );
        }
      } else {
        // Simple archive
        _archivedChats.add(chatId);
        await saveArchivedChats();
        _logger.info('✅ Chat archived (simple): $chatId');
        return ChatOperationResult.success('Chat archived');
      }
    } catch (e) {
      _logger.severe('❌ Failed to archive chat: $e');
      return ChatOperationResult.failure('Failed to toggle archive: $e');
    }
  }

  @override
  Future<ChatOperationResult> unarchiveChat(
    String chatId, {
    bool useEnhancedArchive = true,
  }) async {
    try {
      if (useEnhancedArchive) {
        // Find archive by original chat ID
        final archives = await _archiveRepository.getArchivedChats(
          filter: ArchiveSearchFilter(contactFilter: chatId),
        );

        if (archives.isNotEmpty) {
          final archiveToRestore = archives.first;
          final restoreResult = await _archiveManagementService.restoreChat(
            archiveId: archiveToRestore.id,
          );

          if (restoreResult.success) {
            _archivedChats.remove(chatId);
            await saveArchivedChats();
            _logger.info('✅ Chat restored from enhanced archive: $chatId');
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

      // Fallback to simple unarchive
      _archivedChats.remove(chatId);
      await saveArchivedChats();
      _logger.info('✅ Chat unarchived: $chatId');
      return ChatOperationResult.success('Chat unarchived');
    } catch (e) {
      _logger.severe('❌ Failed to unarchive chat: $e');
      return ChatOperationResult.failure('Failed to unarchive: $e');
    }
  }

  @override
  bool isArchived(String chatId) => _archivedChats.contains(chatId);

  @override
  int get archivedChatsCount => _archivedChats.length;

  @override
  Future<BatchArchiveResult> batchArchiveChats({
    required List<String> chatIds,
    String? reason,
    bool useEnhancedArchive = true,
  }) async {
    final results = <String, ChatOperationResult>{};

    for (final chatId in chatIds) {
      try {
        final result = await archiveChat(
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

    _logger.info('📊 Batch archive completed: $successful/$failed success');

    return BatchArchiveResult(
      results: results,
      totalProcessed: chatIds.length,
      successful: successful,
      failed: failed,
    );
  }

  @override
  Future<void> saveArchivedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_archivedChatsKey, _archivedChats.toList());
      _logger.fine('💾 Archived chats saved');
    } catch (e) {
      _logger.warning('⚠️ Failed to save archived chats: $e');
    }
  }

  @override
  Future<void> loadArchivedChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final archivedList = prefs.getStringList(_archivedChatsKey) ?? [];
      _archivedChats.clear();
      _archivedChats.addAll(archivedList);
      _logger.info('✅ Archived chats loaded: ${_archivedChats.length}');
    } catch (e) {
      _logger.warning('⚠️ Failed to load archived chats: $e');
    }
  }
}
