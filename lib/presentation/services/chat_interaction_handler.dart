import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_chat_interaction_handler.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/services/chat_management_service.dart';
import '../providers/archive_provider.dart';
import '../providers/ble_providers.dart';
import '../screens/chat_screen.dart';
import '../screens/contacts_screen.dart';
import '../screens/archive_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/settings_screen.dart';

/// Enumeration for home screen menu actions
enum HomeMenuAction { openProfile, openContacts, openArchives, settings }

/// Service for handling all user interactions and navigation from HomeScreen
///
/// Owns:
/// - Opening/navigating to other screens (Chat, Profile, Settings, Archives, Contacts)
/// - Search UI state (show/clear search)
/// - Display name editing with bottom sheet UI
/// - Archive/delete confirmation dialogs
/// - Chat context menus
/// - Pin/unpin chat operations
/// - Time formatting for UI display
///
/// Pattern:
/// - Requires BuildContext and WidgetRef for navigation and provider access
/// - Emits interaction intents that trigger coordinator refresh
/// - Handles all dialog/bottom sheet UI interactions
class ChatInteractionHandler implements IChatInteractionHandler {
  final _logger = Logger('ChatInteractionHandler');

  final BuildContext? _context;
  final WidgetRef? _ref;
  final ChatsRepository? _chatsRepository;
  final ChatManagementService? _chatManagementService;

  ChatInteractionHandler({
    BuildContext? context,
    WidgetRef? ref,
    ChatsRepository? chatsRepository,
    ChatManagementService? chatManagementService,
  }) : _context = context,
       _ref = ref,
       _chatsRepository = chatsRepository,
       _chatManagementService = chatManagementService;

  /// Stream controller for interaction intents
  final StreamController<ChatInteractionIntent> _intentController =
      StreamController.broadcast();

  @override
  Future<void> initialize() async {
    _logger.info('✅ ChatInteractionHandler initialized');
  }

  @override
  Stream<ChatInteractionIntent> get interactionIntentStream =>
      _intentController.stream;

  @override
  Future<void> openChat(ChatListItem chat) async {
    if (_context == null || !_canNavigate()) return;

    try {
      await _chatsRepository?.markChatAsRead(chat.chatId);

      if (!_canNavigate()) return;

      await Navigator.push(
        _context!,
        MaterialPageRoute(
          builder: (context) => ChatScreen.fromChatData(
            chatId: chat.chatId,
            contactName: chat.contactName,
            contactPublicKey: chat.contactPublicKey ?? '',
          ),
        ),
      ).then((_) {
        _intentController.add(ChatOpenedIntent(chat.chatId));
      });

      _logger.info('✅ Opened chat: ${chat.contactName}');
    } catch (e) {
      _logger.severe('❌ Error opening chat: $e');
    }
  }

  @override
  void toggleSearch() {
    _intentController.add(SearchToggleIntent(true));
    _logger.fine('🔍 Search toggled');
  }

  @override
  void showSearch() {
    _intentController.add(SearchToggleIntent(true));
    _logger.fine('🔍 Search shown');
  }

  @override
  void clearSearch() {
    _intentController.add(SearchToggleIntent(false));
    _logger.fine('✅ Search cleared');
  }

  @override
  void openSettings() {
    if (_context == null || !_canNavigate()) return;

    try {
      Navigator.push(
        _context!,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      );
      _intentController.add(NavigationIntent('settings'));
      _logger.info('✅ Opened settings screen');
    } catch (e) {
      _logger.severe('❌ Error opening settings: $e');
    }
  }

  @override
  void openProfile() {
    if (_context == null || !_canNavigate()) return;

    try {
      Navigator.push(
        _context!,
        MaterialPageRoute(builder: (context) => const ProfileScreen()),
      );
      _intentController.add(NavigationIntent('profile'));
      _logger.info('✅ Opened profile screen');
    } catch (e) {
      _logger.severe('❌ Error opening profile: $e');
    }
  }

  @override
  Future<String?> editDisplayName(String currentName) async {
    if (_context == null || _ref == null || !_canNavigate()) return null;

    try {
      final controller = TextEditingController(text: currentName);

      final newName = await showModalBottomSheet<String>(
        context: _context!,
        isScrollControlled: true,
        backgroundColor: Theme.of(_context!).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Edit Display Name',
                      style: Theme.of(sheetContext).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close),
                    onPressed: () => Navigator.pop(sheetContext),
                  ),
                ],
              ),
              SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter your display name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    Navigator.pop(sheetContext, value.trim());
                  }
                },
              ),
              SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final value = controller.text.trim();
                  if (value.isNotEmpty) {
                    Navigator.pop(sheetContext, value);
                  }
                },
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text('Save'),
              ),
              SizedBox(height: 16),
            ],
          ),
        ),
      );

      if (newName != null && newName.isNotEmpty && newName != currentName) {
        await _ref!.read(usernameProvider.notifier).updateUsername(newName);
        _logger.info('✅ Display name updated: $newName');
        return newName;
      }
      return null;
    } catch (e) {
      _logger.severe('❌ Error editing display name: $e');
      return null;
    }
  }

  @override
  void handleMenuAction(String action) {
    // Parse action string and delegate to appropriate method
    switch (action) {
      case 'openProfile':
        openProfile();
        break;
      case 'openContacts':
        openContacts();
        break;
      case 'openArchives':
        openArchives();
        break;
      case 'settings':
        openSettings();
        break;
      default:
        _logger.warning('Unknown menu action: $action');
    }
  }

  @override
  void openContacts() {
    if (_context == null || !_canNavigate()) return;

    try {
      Navigator.push(
        _context!,
        MaterialPageRoute(builder: (context) => const ContactsScreen()),
      );
      _intentController.add(NavigationIntent('contacts'));
      _logger.info('✅ Opened contacts screen');
    } catch (e) {
      _logger.severe('❌ Error opening contacts: $e');
    }
  }

  @override
  void openArchives() {
    if (_context == null || !_canNavigate()) return;

    try {
      Navigator.push(
        _context!,
        MaterialPageRoute(builder: (context) => ArchiveScreen()),
      );
      _intentController.add(NavigationIntent('archives'));
      _logger.info('✅ Opened archives screen');
    } catch (e) {
      _logger.severe('❌ Error opening archives: $e');
    }
  }

  @override
  Future<bool> showArchiveConfirmation(ChatListItem chat) async {
    if (_context == null || !_canNavigate()) return false;

    try {
      return await showDialog<bool>(
            context: _context!,
            builder: (context) => AlertDialog(
              title: Row(
                children: [
                  Icon(
                    Icons.archive,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  SizedBox(width: 8),
                  Text('Archive Chat'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Archive chat with ${chat.contactName}?'),
                  SizedBox(height: 8),
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• Chat will be moved to archives',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          '• You can restore it later',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          '• Messages will be preserved',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.tertiary,
                    foregroundColor: Theme.of(context).colorScheme.onTertiary,
                  ),
                  child: Text('Archive'),
                ),
              ],
            ),
          ) ??
          false;
    } catch (e) {
      _logger.severe('❌ Error showing archive confirmation: $e');
      return false;
    }
  }

  @override
  Future<void> archiveChat(ChatListItem chat) async {
    if (_ref == null) return;

    try {
      final result = await _ref!
          .read(archiveOperationsProvider.notifier)
          .archiveChat(
            chatId: chat.chatId,
            reason: 'User archived from chat list',
            metadata: {
              'contactName': chat.contactName,
              'lastMessage': chat.lastMessage,
              'unreadCount': chat.unreadCount,
            },
          );

      if (result.success) {
        _logger.info('✅ Chat archived: ${chat.contactName}');
        _ref!.invalidate(archiveListProvider);
        _ref!.invalidate(archiveStatisticsProvider);
        _intentController.add(ChatArchivedIntent(chat.chatId));
      } else {
        _logger.warning('⚠️ Failed to archive: ${result.message}');
      }
    } catch (e) {
      _logger.severe('❌ Error archiving chat: $e');
    }
  }

  @override
  Future<bool> showDeleteConfirmation(ChatListItem chat) async {
    if (_context == null || !_canNavigate()) return false;

    try {
      return await showDialog<bool>(
            context: _context!,
            builder: (context) => AlertDialog(
              title: Row(
                children: [
                  Icon(
                    Icons.delete_forever,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  SizedBox(width: 8),
                  Text('Delete Chat'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delete chat with ${chat.contactName}?'),
                  SizedBox(height: 8),
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '⚠️ This action cannot be undone',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '• Chat and messages will be permanently deleted',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  child: Text('Delete'),
                ),
              ],
            ),
          ) ??
          false;
    } catch (e) {
      _logger.severe('❌ Error showing delete confirmation: $e');
      return false;
    }
  }

  @override
  Future<void> deleteChat(ChatListItem chat) async {
    try {
      final result = await _chatManagementService?.deleteChat(chat.chatId);

      if (result?.success ?? false) {
        _logger.info('✅ Chat deleted: ${chat.contactName}');
        _intentController.add(ChatDeletedIntent(chat.chatId));
      } else {
        _logger.warning('⚠️ Failed to delete: ${result?.message}');
      }
    } catch (e) {
      _logger.severe('❌ Error deleting chat: $e');
    }
  }

  @override
  void showChatContextMenu(ChatListItem chat) async {
    if (_context == null || !_canNavigate()) return;

    try {
      final isPinned =
          _chatManagementService?.isChatPinned(chat.chatId) ?? false;
      final hasUnread = chat.unreadCount > 0;

      showMenu<String>(
        context: _context!,
        position: RelativeRect.fromLTRB(100, 100, 100, 100),
        items: [
          PopupMenuItem(
            value: 'archive',
            child: Row(
              children: [
                Icon(Icons.archive, size: 18),
                SizedBox(width: 8),
                Text('Archive Chat'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(
                  Icons.delete,
                  size: 18,
                  color: Theme.of(_context!).colorScheme.error,
                ),
                SizedBox(width: 8),
                Text(
                  'Delete Chat',
                  style: TextStyle(
                    color: Theme.of(_context!).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: hasUnread ? 'mark_read' : 'mark_unread',
            child: Row(
              children: [
                Icon(
                  hasUnread ? Icons.mark_chat_read : Icons.mark_chat_unread,
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(hasUnread ? 'Mark as Read' : 'Mark as Unread'),
              ],
            ),
          ),
          PopupMenuItem(
            value: isPinned ? 'unpin' : 'pin',
            child: Row(
              children: [
                Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(isPinned ? 'Unpin Chat' : 'Pin Chat'),
              ],
            ),
          ),
        ],
      ).then((value) async {
        if (value == null) return;

        switch (value) {
          case 'archive':
            if (await showArchiveConfirmation(chat)) {
              await archiveChat(chat);
            }
            break;
          case 'delete':
            if (await showDeleteConfirmation(chat)) {
              await deleteChat(chat);
            }
            break;
          case 'mark_read':
            await markChatAsRead(chat.chatId);
            break;
          case 'mark_unread':
            // TODO: Implement mark as unread in repository
            break;
          case 'pin':
          case 'unpin':
            await toggleChatPin(chat);
            break;
        }
      });

      _logger.fine('📱 Context menu shown for ${chat.contactName}');
    } catch (e) {
      _logger.severe('❌ Error showing context menu: $e');
    }
  }

  @override
  Future<void> toggleChatPin(ChatListItem chat) async {
    try {
      final result = await _chatManagementService?.toggleChatPin(chat.chatId);

      if (result?.success ?? false) {
        _logger.info('✅ Chat pin toggled: ${result?.message}');
        _intentController.add(ChatPinToggleIntent(chat.chatId));
      } else {
        _logger.warning('⚠️ Failed to toggle pin: ${result?.message}');
      }
    } catch (e) {
      _logger.severe('❌ Error toggling pin: $e');
    }
  }

  @override
  Future<void> markChatAsRead(String chatId) async {
    try {
      await _chatsRepository?.markChatAsRead(chatId);
      _logger.info('✅ Chat marked as read: $chatId');
    } catch (e) {
      _logger.severe('❌ Error marking chat as read: $e');
    }
  }

  String formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inDays > 7) {
      return '${time.day}/${time.month}';
    } else if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  bool _canNavigate() => _context != null;

  @override
  Future<void> dispose() async {
    await _intentController.close();
    _logger.info('♻️ ChatInteractionHandler disposed');
  }
}
