import '../../domain/entities/chat_list_item.dart';
import '../../domain/values/id_types.dart';

/// Interface for handling user interactions in home screen
///
/// Owns:
/// - Chat navigation (open chat)
/// - Search UI management (show, clear)
/// - Settings and profile navigation
/// - Display name editing
/// - Menu actions (open contacts, archives, profile, settings)
/// - Archive/delete operations with confirmations
/// - Chat pinning/unpinning
/// - Context menu operations
///
/// Pattern:
/// - Emits intents/events for actions
/// - Facade decides whether to refresh chat list
/// - Keeps UI logic separate from business logic
abstract class IChatInteractionHandler {
  /// Initialize handler
  Future<void> initialize();

  /// Navigate to chat screen for a specific chat
  /// Marks chat as read before navigating
  Future<void> openChat(ChatListItem chat);

  /// Show/toggle search UI
  /// If search is empty, shows search bar
  /// If search is active, clears it
  void toggleSearch();

  /// Show search bar (no clear)
  void showSearch();

  /// Clear search query and hide search bar
  void clearSearch();

  /// Navigate to settings screen
  void openSettings();

  /// Navigate to profile screen
  void openProfile();

  /// Edit user's display name via bottom sheet modal
  /// Returns new name if user confirmed, null if cancelled
  Future<String?> editDisplayName(String currentName);

  /// Handle menu action from popup menu
  /// Actions: openProfile, openContacts, openArchives, settings
  void handleMenuAction(String action);

  /// Navigate to contacts screen
  void openContacts();

  /// Navigate to archives screen
  void openArchives();

  /// Show archive confirmation dialog
  /// Returns true if user confirmed, false if cancelled
  Future<bool> showArchiveConfirmation(ChatListItem chat);

  /// Archive a chat
  /// Emits intent for facade to refresh list
  Future<void> archiveChat(ChatListItem chat);

  /// Show delete confirmation dialog
  /// Returns true if user confirmed, false if cancelled
  Future<bool> showDeleteConfirmation(ChatListItem chat);

  /// Delete a chat permanently
  /// Emits intent for facade to refresh list
  Future<void> deleteChat(ChatListItem chat);

  /// Show context menu for a chat (long press)
  /// Includes: archive, delete, mark read/unread, pin/unpin
  void showChatContextMenu(ChatListItem chat);

  /// Toggle pin status of a chat (pin or unpin)
  /// Emits intent for facade to refresh list
  Future<void> toggleChatPin(ChatListItem chat);

  /// Mark a chat as read
  Future<void> markChatAsRead(ChatId chatId);

  /// Get stream of interaction intents/events
  /// Facade listens to this to know when to refresh chat list
  Stream<ChatInteractionIntent> get interactionIntentStream;

  /// Cleanup resources
  Future<void> dispose();
}

/// Intent emitted by ChatInteractionHandler
/// Tells facade what happened and whether list needs refresh
abstract class ChatInteractionIntent {
  const ChatInteractionIntent();
}

class ChatOpenedIntent extends ChatInteractionIntent {
  final String chatId;
  ChatOpenedIntent(this.chatId);
}

class ChatArchivedIntent extends ChatInteractionIntent {
  final String chatId;
  ChatArchivedIntent(this.chatId);
}

class ChatDeletedIntent extends ChatInteractionIntent {
  final String chatId;
  ChatDeletedIntent(this.chatId);
}

class ChatPinToggleIntent extends ChatInteractionIntent {
  final String chatId;
  ChatPinToggleIntent(this.chatId);
}

class NavigationIntent extends ChatInteractionIntent {
  final String destination; // 'settings', 'profile', 'contacts', 'archives'
  NavigationIntent(this.destination);
}

class SearchToggleIntent extends ChatInteractionIntent {
  final bool isActive;
  SearchToggleIntent(this.isActive);
}
