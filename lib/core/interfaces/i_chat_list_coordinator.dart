import '../../domain/entities/chat_list_item.dart';

/// Interface for managing chat list operations
///
/// Owns:
/// - Loading chats from repository with search/filtering
/// - Periodic refresh (10s timer)
/// - Global message listener for real-time updates
/// - Surgical single chat item updates (prevent flicker)
/// - Unread count stream management
///
/// Depends on:
/// - ChatConnectionManager: Consumes connectionStatusStream for chat online status
/// - ChatsRepository: Fetch chat data
/// - BLEService: Listen to incoming messages
abstract class IChatListCoordinator {
  /// Initialize coordinator
  /// Sets up periodic refresh, global message listener, unread count stream
  Future<void> initialize();

  /// Load all chats with optional search
  ///
  /// Fetches from repository with:
  /// - Nearby devices for connection status
  /// - Discovery data for online indicators
  /// - Search query filtering (if provided)
  ///
  /// Returns sorted list (online chats first, then by last message time)
  Future<List<ChatListItem>> loadChats({String? searchQuery});

  /// Perform surgical update of single chat item after new message
  ///
  /// Instead of reloading entire list, fetch only the recently updated chat
  /// and update it in-place. Prevents UI flicker and is more efficient.
  ///
  /// Falls back to full reload if surgical update fails
  Future<void> updateSingleChatItem();

  /// Refresh unread message count
  /// Called after chats are loaded or when new message arrives
  void refreshUnreadCount();

  /// Get stream of total unread message count across all chats
  Stream<int> get unreadCountStream;

  /// Get current loaded chats (cached from last load)
  List<ChatListItem> get currentChats;

  /// Check if currently loading
  bool get isLoading;

  /// Setup periodic refresh timer (10s interval)
  /// Automatically refreshes chat list unless already loading
  void setupPeriodicRefresh();

  /// Setup global message listener for real-time updates
  /// Listens to all incoming messages and triggers surgical updates
  /// Prevents list stale state by keeping chat list in sync with latest messages
  void setupGlobalMessageListener();

  /// Get nearby devices from BLE discovery
  /// Used to determine connection status for each chat
  Future<List<Peripheral>?> getNearbyDevices();

  /// Search chats by query
  /// Triggers full reload with search filter
  Future<void> searchChats(String query);

  /// Clear search and reload full chat list
  Future<void> clearSearch();

  /// Cleanup timers and subscriptions
  Future<void> dispose();
}
