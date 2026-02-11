import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../entities/chat_list_item.dart';
import '../models/connection_info.dart';
import '../models/connection_status.dart';
import '../values/id_types.dart';

/// Facade interface for HomeScreen presentation layer.
///
/// Presentation should consume this domain contract instead of concrete core
/// service implementations.
abstract class IHomeScreenFacade {
  /// Initialize facade and all sub-services.
  Future<void> initialize();

  // ============ Chat List Operations ============

  /// Load all chats with optional search.
  Future<List<ChatListItem>> loadChats({String? searchQuery});

  /// Get currently loaded chats.
  List<ChatListItem> get chats;

  /// Check if currently loading.
  bool get isLoading;

  /// Refresh unread count.
  void refreshUnreadCount();

  /// Stream of unread message count.
  Stream<int> get unreadCountStream;

  // ============ Chat Interactions ============

  /// Open chat screen.
  Future<void> openChat(ChatListItem chat);

  /// Toggle search UI.
  void toggleSearch();

  /// Show search bar.
  void showSearch();

  /// Clear search.
  Future<void> clearSearch();

  /// Open settings.
  void openSettings();

  /// Open profile.
  void openProfile();

  /// Edit display name.
  Future<String?> editDisplayName(String currentName);

  /// Open contacts screen.
  void openContacts();

  /// Open archives screen.
  void openArchives();

  /// Show archive confirmation.
  Future<bool> showArchiveConfirmation(ChatListItem chat);

  /// Archive a chat.
  Future<void> archiveChat(ChatListItem chat);

  /// Show delete confirmation.
  Future<bool> showDeleteConfirmation(ChatListItem chat);

  /// Delete a chat.
  Future<void> deleteChat(ChatListItem chat);

  /// Show context menu.
  void showChatContextMenu(ChatListItem chat);

  /// Toggle pin on chat.
  Future<void> toggleChatPin(ChatListItem chat);

  /// Mark chat as read.
  Future<void> markChatAsRead(ChatId chatId);

  // ============ Connection Status ============

  /// Get connection status for a specific contact.
  ///
  /// `discoveryData` is intentionally typed as `Map<String, dynamic>` to avoid
  /// exposing core discovery models through the domain contract.
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, dynamic> discoveryData,
    required DateTime? lastSeenTime,
  });

  /// Stream of connection status changes.
  Stream<ConnectionStatus> get connectionStatusStream;

  // ============ Lifecycle ============

  /// Cleanup all resources.
  Future<void> dispose();
}
