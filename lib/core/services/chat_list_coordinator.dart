import 'dart:async';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;
import '../../domain/interfaces/i_chat_list_coordinator.dart';
import '../../domain/models/connection_status.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_connection_service.dart';

/// Service for managing chat list operations
///
/// Owns:
/// - Loading chats from repository with search/filtering
/// - Periodic refresh (10s timer)
/// - Global message listener for real-time updates
/// - Surgical single chat item updates
/// - Unread count stream management
///
/// Pattern:
/// - Uses optional DI for repository and BLE service (testability)
/// - Exposes unreadCountStream for UI consumption
/// - Maintains currentChats cache and isLoading state
class ChatListCoordinator implements IChatListCoordinator {
  final _logger = Logger('ChatListCoordinator');

  final IChatsRepository? _chatsRepository;
  final IConnectionService? _bleService;

  List<ChatListItem> _currentChats = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _refreshTimer;
  Timer? _connectionStatusDebounceTimer;
  StreamSubscription? _globalMessageSubscription;
  StreamSubscription? _discoveryDataSubscription;
  StreamSubscription? _connectionStatusSubscription;
  Map<String, DiscoveredEventArgs>? _lastDiscoveryData;

  // ✅ Phase 6D: Periodic unread count stream (no controller needed)
  Stream<int>? _unreadCountStream;

  // Optional connection status stream for triggering refreshes
  final Stream<ConnectionStatus>? _connectionStatusStream;

  ChatListCoordinator({
    IChatsRepository? chatsRepository,
    IConnectionService? bleService,
    Stream<ConnectionStatus>? connectionStatusStream,
  }) : _chatsRepository = chatsRepository,
       _bleService = bleService,
       _connectionStatusStream = connectionStatusStream;

  @override
  Future<void> initialize() async {
    await loadChats();
    setupPeriodicRefresh();
    setupGlobalMessageListener();
    setupDiscoveryDataListener();
    setupConnectionStatusListener();
    setupUnreadCountStream();
    _logger.info('✅ ChatListCoordinator initialized');
  }

  @override
  Future<List<ChatListItem>> loadChats({String? searchQuery}) async {
    if (!_canLoadChats()) {
      _logger.warning('⚠️ Cannot load chats: dependencies not available');
      return _currentChats;
    }

    // Only show loading spinner on initial load or when list is empty
    final showSpinner = _currentChats.isEmpty;
    if (showSpinner) {
      _isLoading = true;
    }

    try {
      final nearbyDevices = await getNearbyDevices();

      final chats = await _chatsRepository!.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: _lastDiscoveryData ?? <String, DiscoveredEventArgs>{},
        searchQuery: searchQuery?.isEmpty ?? true ? null : searchQuery,
        limit: null,
        offset: null,
      );

      _currentChats = chats;
      _searchQuery = searchQuery ?? '';
      _isLoading = false;

      // Refresh unread count when chats are loaded
      refreshUnreadCount();

      _logger.info(
        '📋 Loaded ${chats.length} chats${searchQuery != null ? " (search: $searchQuery)" : ""}',
      );

      return chats;
    } catch (e) {
      _logger.severe('❌ Error loading chats: $e');
      _isLoading = false;
      rethrow;
    }
  }

  @override
  Future<void> updateSingleChatItem() async {
    if (!_canLoadChats()) return;

    try {
      final nearbyDevices = await getNearbyDevices();

      // Get fresh list to find the updated chat
      final updatedChats = await _chatsRepository!.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: _lastDiscoveryData ?? <String, DiscoveredEventArgs>{},
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
      );

      if (updatedChats.isEmpty) return;

      // Find the chat that was just updated (most recent message)
      final mostRecentChat =
          updatedChats.first; // Already sorted by last message time

      // 🎯 SURGICAL UPDATE: Only update this one chat in the list
      final existingIndex = _currentChats.indexWhere(
        (c) => c.chatId == mostRecentChat.chatId,
      );

      if (existingIndex != -1) {
        // Chat exists - update it in place
        _currentChats[existingIndex] = mostRecentChat;

        // Re-sort to move updated chat to top (if needed)
        _currentChats.sort((a, b) {
          // Online chats first
          if (a.isOnline && !b.isOnline) return -1;
          if (!a.isOnline && b.isOnline) return 1;

          // Then by last message time
          final aTime = a.lastMessageTime ?? DateTime(1970);
          final bTime = b.lastMessageTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
      } else {
        // New chat - add to top
        _currentChats.insert(0, mostRecentChat);
      }

      _logger.fine(
        '🎯 Surgical update completed - only affected chat item updated',
      );
    } catch (e) {
      _logger.warning(
        '⚠️ Surgical update failed, will trigger full refresh: $e',
      );
      // Fallback to full refresh only if surgical update fails
      await loadChats(searchQuery: _searchQuery.isEmpty ? null : _searchQuery);
    }
  }

  @override
  void refreshUnreadCount() async {
    // ✅ Phase 6D: Periodic stream handles unread count updates
    // No need to manually add to controller - periodic polling will refresh on next cycle (3s)
    _logger.fine(
      '🔢 Unread count refresh triggered (will update on next poll cycle)',
    );
  }

  @override
  Stream<int> get unreadCountStream => _unreadCountStream ?? Stream.empty();

  @override
  List<ChatListItem> get currentChats => _currentChats;

  @override
  bool get isLoading => _isLoading;

  @override
  void setupPeriodicRefresh() {
    // Convert periodic refresh to event-driven: rely on BLE/service listeners
    // set up in setupGlobalMessageListener and setupDiscoveryDataListener.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _logger.info('⏱️ Periodic refresh disabled (event-driven updates active)');
  }

  @override
  void setupGlobalMessageListener() {
    try {
      final bleService = _bleService;
      if (bleService == null) return;

      _globalMessageSubscription = bleService.receivedMessages.listen((
        content,
      ) async {
        _logger.info('🔔 New message received - surgical update');
        await updateSingleChatItem();
        refreshUnreadCount();
      });

      _logger.info('✅ Global message listener set up for real-time updates');
    } catch (e) {
      _logger.warning('⚠️ Failed to set up global message listener: $e');
      // Not critical - periodic refresh will still work
    }
  }

  /// 📡 Listen to discovery data changes and cache them
  /// IChatsRepository needs the raw DiscoveredEventArgs for hash-based online detection
  void setupDiscoveryDataListener() {
    try {
      final bleService = _bleService;
      if (bleService == null) return;

      _discoveryDataSubscription = bleService.discoveryData.listen((data) {
        _lastDiscoveryData = data;
        _logger.fine('📡 Discovery data updated: ${data.length} devices');
      });

      _logger.info('✅ Discovery data listener set up');
    } catch (e) {
      _logger.warning('⚠️ Failed to set up discovery data listener: $e');
      // Not critical - will still work without live discovery updates
    }
  }

  /// 🔄 Listen to connection status changes and trigger refresh with debounce
  /// Prevents database starvation when discovery events fire rapidly
  void setupConnectionStatusListener() {
    try {
      final stream = _connectionStatusStream;
      if (stream == null) return;

      _connectionStatusSubscription = stream.listen((_) {
        // Cancel previous timer if exists
        _connectionStatusDebounceTimer?.cancel();

        // Set new debounce timer (500ms)
        _connectionStatusDebounceTimer = Timer(
          Duration(milliseconds: 500),
          () async {
            _logger.fine('🔄 Connection status changed, refreshing chats');
            if (!_isLoading) {
              await loadChats(
                searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
              );
            }
          },
        );
      });

      _logger.info('✅ Connection status listener set up (500ms debounce)');
    } catch (e) {
      _logger.warning('⚠️ Failed to set up connection status listener: $e');
      // Not critical - periodic refresh will still work
    }
  }

  void setupUnreadCountStream() {
    // Create a simple periodic stream that updates unread count
    _unreadCountStream = Stream.periodic(Duration(seconds: 3), (_) {
      return _chatsRepository?.getTotalUnreadCount() ?? Future.value(0);
    }).asyncMap((futureCount) async => await futureCount);

    _logger.info('🔢 Unread count stream set up (3s interval)');
  }

  @override
  Future<List<Peripheral>?> getNearbyDevices() async {
    try {
      final bleService = _bleService;
      if (bleService == null) return null;

      // Prefer cached discovery data for presence/nearby calculations.
      if (_lastDiscoveryData != null && _lastDiscoveryData!.isNotEmpty) {
        return _lastDiscoveryData!.values
            .map((event) => event.peripheral)
            .toList(growable: false);
      }

      // Fallback: return empty list without blocking.
      return const [];
    } catch (e) {
      _logger.warning('⚠️ Error getting nearby devices: $e');
      return null;
    }
  }

  @override
  Future<void> searchChats(String query) async {
    _logger.info('🔍 Searching chats for: "$query"');
    await loadChats(searchQuery: query);
  }

  @override
  Future<void> clearSearch() async {
    _logger.info('❌ Clearing search');
    _searchQuery = '';
    await loadChats();
  }

  bool _canLoadChats() => _chatsRepository != null;

  @override
  Future<void> dispose() async {
    _refreshTimer?.cancel();
    _connectionStatusDebounceTimer?.cancel();
    await _globalMessageSubscription?.cancel();
    await _discoveryDataSubscription?.cancel();
    await _connectionStatusSubscription?.cancel();
    // ✅ Phase 6D: No controller to close (using periodic stream)
    _logger.info('♻️ ChatListCoordinator disposed');
  }
}
