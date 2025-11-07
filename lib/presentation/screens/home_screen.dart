import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import '../providers/ble_providers.dart';
import '../providers/archive_provider.dart';
import '../providers/mesh_networking_provider.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../core/models/connection_status.dart';
import '../../data/services/ble_service.dart';
import '../widgets/discovery_overlay.dart';
import '../widgets/relay_queue_widget.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'archive_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../domain/services/chat_management_service.dart';

/// Menu actions for home screen
enum HomeMenuAction { openProfile, openContacts, openArchives, settings }

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _logger = Logger('HomeScreen');
  final ChatsRepository _chatsRepository = ChatsRepository();
  final ChatManagementService _chatManagementService = ChatManagementService();
  final TextEditingController _searchController = TextEditingController();

  // Tab controller for Chats and Relay Queue
  late TabController _tabController;

  List<ChatListItem> _chats = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _refreshTimer;
  Timer? _searchDebounceTimer;
  bool _showDiscoveryOverlay = false;
  StreamSubscription? _peripheralConnectionSubscription;
  StreamSubscription? _discoveryDataSubscription;

  // Unread count stream
  Stream<int>? _unreadCountStream;
  StreamSubscription? _unreadCountSubscription;

  // 🔥 NEW: Global message listener for instant UI updates
  StreamSubscription<String>? _globalMessageSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(
      _onTabChanged,
    ); // Listen for tab changes to update FAB
    _initializeServices();
    _loadChats();
    _setupPeriodicRefresh();
    _setupPeripheralConnectionListener();
    _setupDiscoveryListener();
    _setupUnreadCountStream();
    _setupGlobalMessageListener(); // 🔥 NEW: Real-time chat list updates
  }

  void _onTabChanged() {
    // Rebuild to update FAB visibility immediately when tab changes
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initializeServices() async {
    await _chatManagementService.initialize();
  }

  /// Load all chats (full refresh - used on initial load and manual refresh)
  /// 🎯 For message updates, use _updateSingleChatItem() instead to prevent flicker
  void _loadChats() async {
    if (!mounted) return;

    // Only show loading spinner on initial load or when list is empty
    final showSpinner = _chats.isEmpty;
    if (showSpinner) {
      setState(() => _isLoading = true);
    }

    final nearbyDevices = await _getNearbyDevices();

    // Get discovery data with advertisements
    final discoveryDataAsync = ref.read(discoveryDataProvider);
    final discoveryData = discoveryDataAsync.maybeWhen(
      data: (data) => data,
      orElse: () => <String, DiscoveredEventArgs>{},
    );

    final chats = await _chatsRepository.getAllChats(
      nearbyDevices: nearbyDevices,
      discoveryData: discoveryData,
      searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
    );

    if (!mounted) return;
    setState(() {
      _chats = chats;
      _isLoading = false;
    });

    // Refresh unread count when chats are loaded
    _refreshUnreadCount();
  }

  Future<List<Peripheral>?> _getNearbyDevices() async {
    final devicesAsync = ref.read(discoveredDevicesProvider);
    return devicesAsync.maybeWhen(
      data: (devices) => devices,
      orElse: () => null,
    );
  }

  void _setupPeriodicRefresh() {
    _refreshTimer = Timer.periodic(Duration(seconds: 10), (_) {
      if (mounted && !_isLoading) {
        _loadChats();
      }
    });
  }

  /// 🔥 NEW: Setup global message listener for instant chat list updates
  /// This listens to ALL incoming messages and triggers an immediate refresh
  /// 🎯 OPTIMIZED: Updates only the affected chat item to prevent UI flicker
  void _setupGlobalMessageListener() {
    try {
      final bleService = ref.read(bleServiceProvider);

      _globalMessageSubscription = bleService.receivedMessages.listen((
        content,
      ) async {
        if (!mounted) return;

        _logger.info(
          '🔔 Global listener: New message received - surgical update to prevent flicker',
        );

        // 🎯 SURGICAL UPDATE: Only refresh the affected chat, not the entire list
        await _updateSingleChatItem();

        // Also refresh unread count
        _refreshUnreadCount();
      });

      _logger.info(
        '✅ Global message listener set up for instant surgical updates (no flicker)',
      );
    } catch (e) {
      _logger.warning('⚠️ Failed to set up global message listener: $e');
      // Not critical - periodic refresh will still work
    }
  }

  /// 🎯 OPTIMIZED: Surgical update of single chat item (prevents full list rebuild/flicker)
  /// Only fetches the most recently updated chat instead of ALL chats
  Future<void> _updateSingleChatItem() async {
    if (!mounted) return;

    try {
      final nearbyDevices = await _getNearbyDevices();
      final discoveryDataAsync = ref.read(discoveryDataProvider);
      final discoveryData = discoveryDataAsync.maybeWhen(
        data: (data) => data,
        orElse: () => <String, DiscoveredEventArgs>{},
      );

      // Get fresh list to find the updated chat
      final updatedChats = await _chatsRepository.getAllChats(
        nearbyDevices: nearbyDevices,
        discoveryData: discoveryData,
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
      );

      if (!mounted || updatedChats.isEmpty) return;

      // Find the chat that was just updated (most recent message)
      final mostRecentChat =
          updatedChats.first; // Already sorted by last message time

      // 🎯 SURGICAL UPDATE: Only update this one chat in the list
      setState(() {
        final existingIndex = _chats.indexWhere(
          (c) => c.chatId == mostRecentChat.chatId,
        );

        if (existingIndex != -1) {
          // Chat exists - update it in place
          _chats[existingIndex] = mostRecentChat;

          // Re-sort to move updated chat to top (if needed)
          _chats.sort((a, b) {
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
          _chats.insert(0, mostRecentChat);
        }
      });

      _logger.fine(
        '🎯 Surgical update completed - only affected chat item rebuilt',
      );
    } catch (e) {
      _logger.warning(
        '⚠️ Surgical update failed, falling back to full refresh: $e',
      );
      // Fallback to full refresh only if surgical update fails
      _loadChats();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleStateAsync = ref.watch(bleStateProvider);
    ref.watch(connectionInfoProvider);
    ref.watch(discoveredDevicesProvider);

    return Stack(
      children: [
        // Main scaffold with tabs
        Scaffold(
          appBar: AppBar(
            title: Consumer(
              builder: (context, ref, child) {
                final usernameAsync = ref.watch(usernameProvider);
                return usernameAsync.when(
                  data: (username) => GestureDetector(
                    onTap: () => _editDisplayName(),
                    child: Text(
                      username.isEmpty ? 'PakConnect' : username,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  loading: () => Text('PakConnect'),
                  error: (_, _) => Text('PakConnect'),
                );
              },
            ),
            actions: [
              // 🔧 HIDE: Queue status indicator for better UX (users don't need to see technical mesh status)
              // Developer note: If needed for debugging, can be re-enabled in developer settings
              /* Consumer(
              builder: (context, ref, child) {
                final meshStatus = ref.watch(meshNetworkStatusProvider);
                return meshStatus.when(
                  data: (status) => QueueStatusIndicatorFactory.appBarIndicator(
                    queueStats: status.statistics.queueStatistics,
                    onTap: () => _tabController.animateTo(1), // Switch to relay queue tab
                  ),
                  loading: () => SizedBox.shrink(),
                  error: (err, stack) => SizedBox.shrink(),
                );
              },
            ),
            SizedBox(width: 8), */
              Stack(
                children: [
                  IconButton(
                    onPressed: () => _showSearch(),
                    icon: Icon(Icons.search),
                  ),
                  StreamBuilder<int>(
                    stream: _unreadCountStream,
                    builder: (context, snapshot) {
                      final count = snapshot.data ?? 0;
                      if (count == 0) return SizedBox.shrink();

                      return Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            count > 99 ? '99+' : '$count',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              PopupMenuButton<HomeMenuAction>(
                onSelected: _handleMenuAction,
                itemBuilder: (context) => [
                  PopupMenuItem<HomeMenuAction>(
                    value: HomeMenuAction.openProfile,
                    child: Row(
                      children: [
                        Icon(Icons.person, size: 18),
                        SizedBox(width: 8),
                        Text('Profile'),
                      ],
                    ),
                  ),
                  PopupMenuItem<HomeMenuAction>(
                    value: HomeMenuAction.openContacts,
                    child: Row(
                      children: [
                        Icon(Icons.contacts, size: 18),
                        SizedBox(width: 8),
                        Text('Contacts'),
                      ],
                    ),
                  ),
                  PopupMenuItem<HomeMenuAction>(
                    value: HomeMenuAction.openArchives,
                    child: Row(
                      children: [
                        Icon(Icons.archive, size: 18),
                        SizedBox(width: 8),
                        Text('Archived Chats'),
                      ],
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem<HomeMenuAction>(
                    value: HomeMenuAction.settings,
                    child: Row(
                      children: [
                        Icon(Icons.settings, size: 18),
                        SizedBox(width: 8),
                        Text('Settings'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            // 🎯 NEW: Add tab bar
            bottom: TabBar(
              controller: _tabController,
              tabs: [
                Tab(icon: Icon(Icons.chat), text: 'Chats'),
                Tab(icon: Icon(Icons.device_hub), text: 'Mesh Relay'),
              ],
            ),
          ),
          body: Column(
            children: [
              _buildBLEStatusBanner(bleStateAsync),

              // 🎯 NEW: Tab bar view with chats and relay queue
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Tab 1: Chats (existing functionality)
                    _buildChatsTab(),

                    // Tab 2: Relay Queue (new functionality)
                    _buildRelayQueueTab(),
                  ],
                ),
              ),
            ],
          ),
          floatingActionButton:
              _tabController.index ==
                  0 // Only show FAB on Chats tab
              ? FloatingActionButton(
                  onPressed: () => setState(() => _showDiscoveryOverlay = true),
                  tooltip: 'Discover nearby devices',
                  child: Icon(Icons.bluetooth_searching),
                )
              : null,
        ),

        if (_showDiscoveryOverlay)
          Positioned.fill(
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) {
                  setState(() => _showDiscoveryOverlay = false);
                }
              },
              child: DiscoveryOverlay(
                onClose: () => setState(() => _showDiscoveryOverlay = false),
                onDeviceSelected: _onDeviceSelected,
              ),
            ),
          ),
      ],
    );
  }

  /// Build the chats tab (existing functionality moved to separate method)
  Widget _buildChatsTab() {
    return Column(
      children: [
        if (_searchQuery.isNotEmpty) _buildSearchBar(),

        Expanded(
          child: _isLoading
              ? Center(child: CircularProgressIndicator())
              : _chats.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: () async => _loadChats(),
                  child: ListView.builder(
                    itemCount: _chats.length,
                    itemBuilder: (context, index) {
                      final chat = _chats[index];
                      // 🎯 Use ValueKey for efficient widget reuse (prevents unnecessary rebuilds)
                      return _buildSwipeableChatTile(
                        chat,
                        key: ValueKey(chat.chatId),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Build the relay queue tab (new functionality)
  Widget _buildRelayQueueTab() {
    return Consumer(
      builder: (context, ref, child) {
        final meshService = ref.watch(meshNetworkingServiceProvider);

        return RelayQueueWidget(
          meshService: meshService,
          onRequestClose: () => _handleRelayQueueClose(),
        );
      },
    );
  }

  /// Handle relay queue close request by switching back to chats tab
  void _handleRelayQueueClose() {
    if (_tabController.index == 1) {
      // Currently on relay queue tab
      _tabController.animateTo(0); // Switch to chats tab
    }
  }

  Widget _buildChatTile(ChatListItem chat) {
    // Get live connection status
    final connectionInfo = ref.watch(connectionInfoProvider).value;
    final bleService = ref.read(bleServiceProvider);
    final discoveredDevices = ref.watch(discoveredDevicesProvider).value ?? [];
    final discoveryData = ref.watch(discoveryDataProvider).value ?? {};

    ConnectionStatus connectionStatus = _determineConnectionStatus(
      chat,
      connectionInfo,
      bleService,
      discoveredDevices,
      discoveryData,
    );

    // Determine real-time status
    if (connectionInfo != null &&
        connectionInfo.isConnected &&
        connectionInfo.otherUserName == chat.contactName) {
      connectionStatus = ConnectionStatus.connected;
    } else if (discoveredDevices.any(
      (device) =>
          chat.contactPublicKey?.contains(device.uuid.toString()) ?? false,
    )) {
      connectionStatus = ConnectionStatus.nearby;
    } else if (chat.isOnline) {
      connectionStatus = ConnectionStatus.nearby;
    } else {
      connectionStatus = ConnectionStatus.offline;
    }

    // Modern UI: Use subtle visual cues instead of colored dots
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Subtle border for connected status - like WhatsApp/Signal
            border: connectionStatus == ConnectionStatus.connected
                ? Border.all(color: connectionStatus.color, width: 2.5)
                : null,
          ),
          child: CircleAvatar(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        title: Text(
          chat.contactName,
          style: TextStyle(
            fontWeight: chat.unreadCount > 0
                ? FontWeight.bold
                : FontWeight.normal,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Modern approach: Show status as text like popular messaging apps
            if (connectionStatus == ConnectionStatus.connected)
              Padding(
                padding: EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'Active now',
                  style: TextStyle(
                    fontSize: 12,
                    color: connectionStatus.color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              )
            else if (connectionStatus == ConnectionStatus.nearby)
              Padding(
                padding: EdgeInsets.only(top: 2, bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bluetooth_searching,
                      size: 12,
                      color: connectionStatus.color,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Nearby',
                      style: TextStyle(
                        fontSize: 12,
                        color: connectionStatus.color,
                      ),
                    ),
                  ],
                ),
              ),
            // Show last message if available
            if (chat.lastMessage != null)
              Padding(
                padding: EdgeInsets.only(
                  top:
                      connectionStatus == ConnectionStatus.connected ||
                          connectionStatus == ConnectionStatus.nearby
                      ? 2
                      : 0,
                ),
                child: Text(
                  chat.lastMessage!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: chat.unreadCount > 0
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                ),
              ),
            // Show unsent message warning
            if (chat.hasUnsentMessages)
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 12, color: Colors.red),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Message failed to send',
                        style: TextStyle(fontSize: 11, color: Colors.red),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (chat.lastMessageTime != null)
              Text(
                _formatTime(chat.lastMessageTime!),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (chat.unreadCount > 0)
              Container(
                margin: EdgeInsets.only(top: 4),
                padding: EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${chat.unreadCount}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        onTap: () => _openChat(chat),
        onLongPress: () => _showChatContextMenu(chat),
      ),
    );
  }

  /// Build swipeable chat tile with archive and delete functionality
  /// 🎯 Accepts optional key for efficient widget reuse during surgical updates
  Widget _buildSwipeableChatTile(ChatListItem chat, {Key? key}) {
    return Dismissible(
      key:
          key ?? Key('chat_${chat.chatId}'), // Use provided key or generate one
      direction: DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.4, // 40% for archive
        DismissDirection.endToStart: 0.4, // 40% for delete
      },
      movementDuration: const Duration(milliseconds: 300),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.only(left: 20),
        color: Theme.of(context).colorScheme.tertiary, // Blue for archive
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.archive,
              color: Theme.of(context).colorScheme.onTertiary,
              size: 24,
            ),
            SizedBox(height: 4),
            Text(
              'Archive',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 20),
        color: Theme.of(context).colorScheme.error, // Red for delete
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.delete,
              color: Theme.of(context).colorScheme.onError,
              size: 24,
            ),
            SizedBox(height: 4),
            Text(
              'Delete',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onError,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Left swipe: Archive
          return await _showArchiveConfirmation(chat);
        } else if (direction == DismissDirection.endToStart) {
          // Right swipe: Delete
          return await _showDeleteConfirmation(chat);
        }
        return false;
      },
      onDismissed: (direction) async {
        // Add haptic feedback
        await HapticFeedback.mediumImpact();

        if (direction == DismissDirection.startToEnd) {
          // Left swipe: Archive
          await _archiveChat(chat);
        } else if (direction == DismissDirection.endToStart) {
          // Right swipe: Delete
          await _deleteChat(chat);
        }
      },
      child: _buildChatTile(chat),
    );
  }

  Widget _buildEmptyState() {
    final devicesAsync = ref.watch(discoveredDevicesProvider);
    final hasNearbyDevices = devicesAsync.maybeWhen(
      data: (devices) => devices.isNotEmpty,
      orElse: () => false,
    );

    return Center(
      child: Padding(
        padding: EdgeInsets.only(bottom: 80), // Account for FAB visual weight
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(),
            ),
            SizedBox(height: 16),
            Text(
              hasNearbyDevices
                  ? 'Connect to a nearby device first.'
                  : 'No conversations yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 8),
            Text(
              'Tap Bluetooth button below to scan/broadcast.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBLEStatusBanner(
    AsyncValue<BluetoothLowEnergyState> bleStateAsync,
  ) {
    return bleStateAsync.when(
      data: (state) {
        if (state != BluetoothLowEnergyState.poweredOn) {
          return Container(
            padding: EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Row(
              children: [
                Icon(Icons.bluetooth_disabled),
                SizedBox(width: 8),
                Text('Bluetooth ${state.name} - Allow Permission!'),
              ],
            ),
          );
        }
        return SizedBox.shrink();
      },
      loading: () => SizedBox.shrink(),
      error: (err, stack) => SizedBox.shrink(),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.all(12),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search chats...',
          prefixIcon: Icon(Icons.search),
          suffixIcon: IconButton(
            onPressed: _clearSearch,
            icon: Icon(Icons.clear),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(25)),
        ),
        onChanged: (query) {
          setState(() => _searchQuery = query);

          // Debounce search to prevent excessive calls
          _searchDebounceTimer?.cancel();
          _searchDebounceTimer = Timer(Duration(milliseconds: 300), () {
            if (mounted) _loadChats();
          });
        },
      ),
    );
  }

  ConnectionStatus _determineConnectionStatus(
    ChatListItem chat,
    ConnectionInfo? connectionInfo,
    BLEService bleService,
    List<Peripheral> discoveredDevices,
    Map<String, DiscoveredEventArgs> discoveryData,
  ) {
    // Check if this is the currently connected device
    if (connectionInfo != null &&
        connectionInfo.isConnected &&
        connectionInfo.isReady &&
        connectionInfo.otherUserName == chat.contactName) {
      return ConnectionStatus.connected;
    }

    // Check if currently connecting to this device
    if (connectionInfo != null &&
        connectionInfo.isConnected &&
        !connectionInfo.isReady &&
        bleService.theirPersistentKey == chat.contactPublicKey) {
      return ConnectionStatus.connecting;
    }

    // Check if device is nearby (discovered via BLE scan)
    if (chat.contactPublicKey != null) {
      // Method 1: Check via manufacturer data hash
      final isOnlineViaHash = _isContactOnlineViaHash(
        chat.contactPublicKey!,
        discoveryData.cast<String, DiscoveredDevice>(),
      );
      if (isOnlineViaHash) {
        return ConnectionStatus.nearby;
      }

      // Method 2: Check via device UUID mapping (fallback)
      final isNearbyViaUUID = discoveredDevices.any(
        (device) => chat.contactPublicKey!.contains(device.uuid.toString()),
      );
      if (isNearbyViaUUID) {
        return ConnectionStatus.nearby;
      }
    }

    // Check if recently seen (within last 5 minutes)
    if (chat.lastSeen != null) {
      final timeSinceLastSeen = DateTime.now().difference(chat.lastSeen!);
      if (timeSinceLastSeen.inMinutes <= 5) {
        return ConnectionStatus.recent;
      }
    }

    return ConnectionStatus.offline;
  }

  bool _isContactOnlineViaHash(
    String contactPublicKey,
    Map<String, DiscoveredDevice> discoveryData,
  ) {
    if (discoveryData.isEmpty) return false;

    for (final device in discoveryData.values) {
      if (device.isKnownContact && device.contactInfo != null) {
        final contact = device.contactInfo!.contact;

        // 🔐 PRIVACY FIX: Only match current active session
        // This prevents identity linkage across ephemeral sessions for LOW security contacts

        // Match 1: Current ephemeral ID (active session)
        if (contact.currentEphemeralId == contactPublicKey) {
          _logger.fine(
            '🟢 ONLINE: Current session match for ${contact.displayName} (ephemeral)',
          );
          return true;
        }

        // Match 2: Persistent public key (MEDIUM+ security only)
        if (contact.persistentPublicKey != null &&
            contact.persistentPublicKey == contactPublicKey) {
          _logger.fine(
            '🟢 ONLINE: Persistent identity match for ${contact.displayName} (paired)',
          );
          return true;
        }

        // NO MATCH: Don't match by first publicKey - that would link old sessions
        // This is intentional for privacy - only current session shows online
      }
    }

    return false;
  }

  void _setupPeripheralConnectionListener() {
    if (!Platform.isAndroid) return;

    final bleService = ref.read(bleServiceProvider);

    _peripheralConnectionSubscription = bleService
        .peripheralManager
        .connectionStateChanged
        .distinct(
          (prev, next) =>
              prev.central.uuid == next.central.uuid &&
              prev.state == next.state,
        )
        .where(
          (event) =>
              bleService.isPeripheralMode &&
              event.state == ble.ConnectionState.connected,
        )
        .listen((event) {
          _handleIncomingPeripheralConnection(event.central);
        });

    bleService.connectionInfo.listen((info) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _setupDiscoveryListener() {
    // Listen to real-time discovery data changes
    _discoveryDataSubscription = ref
        .read(bleServiceProvider)
        .discoveryData
        .listen((discoveryData) {
          if (mounted && !_isLoading) {
            // Trigger immediate refresh when discovery data changes
            _loadChats();
          }
        });
  }

  void _handleIncomingPeripheralConnection(Central central) {
    if (!mounted) return;

    _loadChats();
  }

  void _onDeviceSelected(Peripheral device) async {
    setState(() => _showDiscoveryOverlay = false);

    _logger.info(
      'Connecting to device: ${device.uuid.toString().substring(0, 8)}',
    );

    // The connection will be handled by the BLE service
    // The chat list will automatically update to show connection status
    // User can tap the chat when they see it's connected

    // Refresh the chat list after a short delay
    Future.delayed(Duration(seconds: 2), () {
      if (mounted) {
        _loadChats();
      }
    });
  }

  void _openChat(ChatListItem chat) async {
    if (!mounted) return;

    await _chatsRepository.markChatAsRead(chat.chatId);

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen.fromChatData(
          chatId: chat.chatId,
          contactName: chat.contactName,
          contactPublicKey: chat.contactPublicKey ?? '',
        ),
      ),
    ).then((_) {
      if (mounted) _loadChats();
    });
  }

  void _showSearch() {
    setState(() {
      if (_searchQuery.isEmpty) {
        _searchQuery = ' '; // Show search bar
      } else {
        _clearSearch();
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
    _loadChats();
  }

  void _showSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProfileScreen()),
    );
  }

  void _editDisplayName() async {
    // Get the username first using modern AsyncNotifier provider
    final currentName = await ref.read(usernameProvider.future);

    // Check mounted after async
    if (!mounted) return;

    final controller = TextEditingController(text: currentName);

    // Use bottom sheet for modern inline editing experience
    final newName = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
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
      try {
        await ref.read(usernameProvider.notifier).updateUsername(newName);
        _logger.info('Display name updated to: $newName');
      } catch (e) {
        _logger.warning('Failed to update display name: $e');
      }
    }
  }

  String _formatTime(DateTime time) {
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

  void _setupUnreadCountStream() {
    // Create a simple periodic stream that updates unread count
    _unreadCountStream = Stream.periodic(Duration(seconds: 3), (_) {
      return _chatsRepository.getTotalUnreadCount();
    }).asyncMap((futureCount) async => await futureCount);
  }

  void _refreshUnreadCount() async {
    // Force refresh the unread count when chats are updated
    setState(() {
      _setupUnreadCountStream();
    });
  }

  void _handleMenuAction(HomeMenuAction action) {
    switch (action) {
      case HomeMenuAction.openProfile:
        _openProfile();
        break;
      case HomeMenuAction.openContacts:
        _openContacts();
        break;
      case HomeMenuAction.openArchives:
        _openArchives();
        break;
      case HomeMenuAction.settings:
        _showSettings();
        break;
    }
  }

  void _openContacts() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ContactsScreen()),
    );
  }

  void _openArchives() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ArchiveScreen()),
    );
  }

  Future<bool> _showArchiveConfirmation(ChatListItem chat) async {
    return await showDialog<bool>(
          context: context,
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
  }

  Future<void> _archiveChat(ChatListItem chat) async {
    try {
      final result = await ref
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

      if (mounted) {
        if (result.success) {
          _logger.info('Chat archived: ${chat.contactName}');
          _loadChats();

          // 🔧 FIX: Invalidate archive providers so Archive screen updates
          ref.invalidate(archiveListProvider);
          ref.invalidate(archiveStatisticsProvider);
        } else {
          _logger.warning('Failed to archive chat: ${result.message}');
        }
      }
    } catch (e) {
      _logger.severe('Error archiving chat: $e');
    }
  }

  Future<bool> _showDeleteConfirmation(ChatListItem chat) async {
    return await showDialog<bool>(
          context: context,
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
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• This action cannot be undone',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '• All messages will be permanently deleted',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                      Text(
                        '• Chat history cannot be recovered',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
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
  }

  Future<void> _deleteChat(ChatListItem chat) async {
    try {
      final result = await _chatManagementService.deleteChat(chat.chatId);

      if (mounted) {
        if (result.success) {
          _logger.info('Chat deleted: ${chat.contactName}');
          _loadChats();
        } else {
          _logger.warning('Failed to delete chat: ${result.message}');
        }
      }
    } catch (e) {
      _logger.severe('Error deleting chat: $e');
    }
  }

  void _showChatContextMenu(ChatListItem chat) {
    final isPinned = _chatManagementService.isChatPinned(chat.chatId);
    final hasUnread = chat.unreadCount > 0;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        100,
        100,
        100,
        100,
      ), // Will be adjusted by Flutter
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
                color: Theme.of(context).colorScheme.error,
              ),
              SizedBox(width: 8),
              Text(
                'Delete Chat',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          if (await _showArchiveConfirmation(chat)) {
            await _archiveChat(chat);
          }
          break;
        case 'delete':
          if (await _showDeleteConfirmation(chat)) {
            await _deleteChat(chat);
          }
          break;
        case 'mark_read':
          await _chatsRepository.markChatAsRead(chat.chatId);
          _loadChats();
          break;
        case 'mark_unread':
          // Note: This would require implementing markChatAsUnread in repository
          // For now, we'll skip this option if no unread messages
          break;
        case 'pin':
        case 'unpin':
          await _toggleChatPin(chat);
          break;
      }
    });
  }

  Future<void> _toggleChatPin(ChatListItem chat) async {
    try {
      final result = await _chatManagementService.toggleChatPin(chat.chatId);

      if (mounted) {
        if (result.success) {
          _logger.info('Chat pin toggled: ${result.message}');
          _loadChats();
        } else {
          _logger.warning('Failed to toggle pin: ${result.message}');
        }
      }
    } catch (e) {
      _logger.severe('Error toggling pin: $e');
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _refreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _unreadCountSubscription?.cancel();
    _discoveryDataSubscription?.cancel();
    _globalMessageSubscription?.cancel(); // 🔥 Clean up global message listener
    _searchController.dispose();
    _peripheralConnectionSubscription?.cancel();
    _chatManagementService.dispose();
    super.dispose();
  }
}
