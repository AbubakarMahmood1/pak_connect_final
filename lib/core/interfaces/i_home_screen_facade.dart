import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/values/id_types.dart';
import '../../core/models/connection_status.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';

/// Facade interface for HomeScreen presentation layer
///
/// Provides unified API for home screen widget
/// Coordinates 3 sub-services:
/// - ChatConnectionManager: Connection status determination
/// - ChatListCoordinator: Chat loading and refresh
/// - ChatInteractionHandler: User interactions
///
/// Pattern:
/// - Services are lazily initialized on first access
/// - DI-friendly: Optional service overrides for testing
/// - 100% backward compatible: No breaking changes to widget
/// - Widget focuses only on rendering, facade handles logic
abstract class IHomeScreenFacade {
  /// Initialize facade and all sub-services
  Future<void> initialize();

  // ============ Chat List Operations ============

  /// Load all chats with optional search
  Future<List<ChatListItem>> loadChats({String? searchQuery});

  /// Get currently loaded chats
  List<ChatListItem> get chats;

  /// Check if currently loading
  bool get isLoading;

  /// Refresh unread count
  void refreshUnreadCount();

  /// Stream of unread message count
  Stream<int> get unreadCountStream;

  // ============ Chat Interactions ============

  /// Open chat screen
  Future<void> openChat(ChatListItem chat);

  /// Toggle search UI
  void toggleSearch();

  /// Show search bar
  void showSearch();

  /// Clear search
  Future<void> clearSearch();

  /// Open settings
  void openSettings();

  /// Open profile
  void openProfile();

  /// Edit display name
  Future<String?> editDisplayName(String currentName);

  /// Open contacts screen
  void openContacts();

  /// Open archives screen
  void openArchives();

  /// Show archive confirmation
  Future<bool> showArchiveConfirmation(ChatListItem chat);

  /// Archive a chat
  Future<void> archiveChat(ChatListItem chat);

  /// Show delete confirmation
  Future<bool> showDeleteConfirmation(ChatListItem chat);

  /// Delete a chat
  Future<void> deleteChat(ChatListItem chat);

  /// Show context menu
  void showChatContextMenu(ChatListItem chat);

  /// Toggle pin on chat
  Future<void> toggleChatPin(ChatListItem chat);

  /// Mark chat as read
  Future<void> markChatAsRead(ChatId chatId);

  // ============ Connection Status ============

  /// Get connection status for a specific contact
  ///
  /// Parameters:
  /// - contactPublicKey: Public key of the contact
  /// - contactName: Display name of the contact
  /// - currentConnectionInfo: Current BLE connection info (nullable)
  /// - discoveredDevices: List of discovered peripherals from BLE scan
  /// - discoveryData: Map of deduplicated discovered devices (keyed by device ID)
  ///   ⚠️ NOTE: Must use DiscoveredDevice objects (from DeviceDeduplicationManager),
  ///   not raw DiscoveredEventArgs. This provides contact info matching.
  /// - lastSeenTime: When this contact was last seen (from database)
  ConnectionStatus determineConnectionStatus({
    required String? contactPublicKey,
    required String contactName,
    required ConnectionInfo? currentConnectionInfo,
    required List<Peripheral> discoveredDevices,
    required Map<String, DiscoveredDevice> discoveryData,
    required DateTime? lastSeenTime,
  });

  /// Stream of connection status changes
  Stream<ConnectionStatus> get connectionStatusStream;

  // ============ Lifecycle ============

  /// Cleanup all resources
  Future<void> dispose();
}
