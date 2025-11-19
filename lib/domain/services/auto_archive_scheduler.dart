// Auto-archive scheduler for automatically archiving inactive chats
// Runs periodically based on user settings and archives chats with no recent activity

import 'dart:async';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import '../../core/interfaces/i_preferences_repository.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../data/repositories/preferences_repository.dart';
import 'archive_management_service.dart';

/// Auto-archive scheduler service
/// Periodically checks for inactive chats and archives them based on user settings
class AutoArchiveScheduler {
  static final _logger = Logger('AutoArchiveScheduler');
  static Timer? _checkTimer;
  static bool _isRunning = false;
  static DateTime? _lastCheckTime;

  /// Start the auto-archive scheduler
  /// Call this in main.dart after app initialization
  static Future<void> start() async {
    if (_isRunning) {
      _logger.fine('Auto-archive scheduler already running');
      return;
    }

    try {
      final prefs = GetIt.instance<IPreferencesRepository>();
      final enabled = await prefs.getBool(PreferenceKeys.autoArchiveOldChats);

      if (!enabled) {
        _logger.info('Auto-archive disabled in settings');
        return;
      }

      _isRunning = true;
      _logger.info('Starting auto-archive scheduler');

      // Check immediately on start (but only if never checked before)
      if (_lastCheckTime == null) {
        await _checkAndArchiveInactiveChats();
      }

      // Then check daily at midnight (or every 24 hours)
      _checkTimer = Timer.periodic(Duration(hours: 24), (_) {
        _checkAndArchiveInactiveChats();
      });

      _logger.info('Auto-archive scheduler started successfully');
    } catch (e) {
      _logger.severe('Failed to start auto-archive scheduler: $e');
      _isRunning = false;
    }
  }

  /// Stop the auto-archive scheduler
  static void stop() {
    _checkTimer?.cancel();
    _checkTimer = null;
    _isRunning = false;
    _logger.info('Auto-archive scheduler stopped');
  }

  /// Restart the scheduler (useful when settings change)
  static Future<void> restart() async {
    _logger.info('Restarting auto-archive scheduler');
    stop();
    await start();
  }

  /// Manual trigger for testing or immediate check
  /// Returns number of chats archived
  static Future<int> checkNow() async {
    _logger.info('Manual auto-archive check triggered');
    return await _checkAndArchiveInactiveChats();
  }

  /// Get scheduler status
  static bool get isRunning => _isRunning;
  static DateTime? get lastCheckTime => _lastCheckTime;

  /// Internal method to check and archive inactive chats
  static Future<int> _checkAndArchiveInactiveChats() async {
    try {
      _logger.info('Starting auto-archive check...');
      _lastCheckTime = DateTime.now();

      // Get user settings
      final prefs = GetIt.instance<IPreferencesRepository>();
      final enabled = await prefs.getBool(PreferenceKeys.autoArchiveOldChats);

      if (!enabled) {
        _logger.info('Auto-archive disabled, skipping check');
        return 0;
      }

      final archiveAfterDays = await prefs.getInt(
        PreferenceKeys.archiveAfterDays,
      );
      final cutoffDate = DateTime.now().subtract(
        Duration(days: archiveAfterDays),
      );

      _logger.info(
        'Checking for chats inactive since: $cutoffDate ($archiveAfterDays days ago)',
      );

      // Get all chats
      final chatsRepo = GetIt.instance<IChatsRepository>();
      final allChats = await chatsRepo.getAllChats();

      int archivedCount = 0;
      final List<String> archivedChatNames = [];

      for (final chat in allChats) {
        // Skip if no last message time (shouldn't happen, but be safe)
        if (chat.lastMessageTime == null) {
          _logger.fine('Skipping ${chat.contactName}: no last message time');
          continue;
        }

        // Skip if recently active
        if (chat.lastMessageTime!.isAfter(cutoffDate)) {
          _logger.fine(
            'Skipping ${chat.contactName}: active within $archiveAfterDays days',
          );
          continue;
        }

        // Calculate days inactive
        final daysInactive = DateTime.now()
            .difference(chat.lastMessageTime!)
            .inDays;

        _logger.info(
          'Found inactive chat: ${chat.contactName} ($daysInactive days inactive)',
        );

        // Archive this inactive chat
        try {
          final result = await ArchiveManagementService.instance.archiveChat(
            chatId: chat.chatId,
            reason: 'Auto-archived after $daysInactive days of inactivity',
            metadata: {
              'auto_archived': true,
              'last_activity': chat.lastMessageTime!.toIso8601String(),
              'archived_at': DateTime.now().toIso8601String(),
              'days_inactive': daysInactive,
              'archive_threshold_days': archiveAfterDays,
            },
          );

          if (result.success) {
            archivedCount++;
            archivedChatNames.add(chat.contactName);
            _logger.info(
              '✅ Auto-archived: ${chat.contactName} (inactive for $daysInactive days)',
            );
          } else {
            _logger.warning(
              '❌ Failed to auto-archive ${chat.contactName}: ${result.message}',
            );
          }
        } catch (e) {
          _logger.warning('❌ Error auto-archiving ${chat.contactName}: $e');
        }
      }

      if (archivedCount > 0) {
        _logger.info('🎯 Auto-archive complete: $archivedCount chats archived');
        _logger.info('   Archived chats: ${archivedChatNames.join(", ")}');
      } else {
        _logger.info('✓ Auto-archive check complete: no inactive chats found');
      }

      return archivedCount;
    } catch (e) {
      _logger.severe('❌ Auto-archive check failed: $e');
      return 0;
    }
  }
}
