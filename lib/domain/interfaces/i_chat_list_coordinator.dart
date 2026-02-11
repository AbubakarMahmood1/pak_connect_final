import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../entities/chat_list_item.dart';

/// Interface for managing chat list operations.
abstract class IChatListCoordinator {
  /// Initialize coordinator.
  Future<void> initialize();

  /// Load all chats with optional search.
  Future<List<ChatListItem>> loadChats({String? searchQuery});

  /// Perform surgical update of single chat item after new message.
  Future<void> updateSingleChatItem();

  /// Refresh unread message count.
  void refreshUnreadCount();

  /// Stream of total unread message count across all chats.
  Stream<int> get unreadCountStream;

  /// Current loaded chats (cached from last load).
  List<ChatListItem> get currentChats;

  /// Whether coordinator is currently loading.
  bool get isLoading;

  /// Setup periodic refresh timer.
  void setupPeriodicRefresh();

  /// Setup global message listener for real-time updates.
  void setupGlobalMessageListener();

  /// Get nearby devices from BLE discovery.
  Future<List<Peripheral>?> getNearbyDevices();

  /// Search chats by query.
  Future<void> searchChats(String query);

  /// Clear search and reload full chat list.
  Future<void> clearSearch();

  /// Cleanup timers and subscriptions.
  Future<void> dispose();
}
