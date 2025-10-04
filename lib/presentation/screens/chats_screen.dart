import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' hide ConnectionState;
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
import 'qr_contact_screen.dart';
import 'contacts_screen.dart';
import 'archive_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../domain/services/chat_management_service.dart';

/// Menu actions for chats screen
enum ChatsMenuAction {
  openProfile,
  openContacts,
  openArchives,
  settings,
}

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> with SingleTickerProviderStateMixin {
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeServices();
    _loadChats();
    _setupPeriodicRefresh();
    _setupPeripheralConnectionListener();
    _setupDiscoveryListener();
    _setupUnreadCountStream();
  }

  Future<void> _initializeServices() async {
    await _chatManagementService.initialize();
  }


void _loadChats() async {
  if (!mounted) return;
  setState(() => _isLoading = true);
  
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
          leading: GestureDetector(
            onTap: () => _openProfile(),
            child: Padding(
              padding: EdgeInsets.all(8.0),
              child: Consumer(
                builder: (context, ref, child) {
                  final usernameAsync = ref.watch(usernameProvider);
                  return usernameAsync.when(
                    data: (username) => CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Text(
                        username.isNotEmpty ? username[0].toUpperCase() : 'P',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    loading: () => CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Icon(Icons.person, color: Colors.white),
                    ),
                    error: (_, _) => CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      child: Icon(Icons.person, color: Colors.white),
                    ),
                  );
                },
              ),
            ),
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
            PopupMenuButton<ChatsMenuAction>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                PopupMenuItem<ChatsMenuAction>(
                  value: ChatsMenuAction.openProfile,
                  child: Row(
                    children: [
                      Icon(Icons.person, size: 18),
                      SizedBox(width: 8),
                      Text('Profile'),
                    ],
                  ),
                ),
                PopupMenuItem<ChatsMenuAction>(
                  value: ChatsMenuAction.openContacts,
                  child: Row(
                    children: [
                      Icon(Icons.contacts, size: 18),
                      SizedBox(width: 8),
                      Text('Contacts'),
                    ],
                  ),
                ),
                PopupMenuItem<ChatsMenuAction>(
                  value: ChatsMenuAction.openArchives,
                  child: Row(
                    children: [
                      Icon(Icons.archive, size: 18),
                      SizedBox(width: 8),
                      Text('Archived Chats'),
                    ],
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem<ChatsMenuAction>(
                  value: ChatsMenuAction.settings,
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
              Tab(
                icon: Icon(Icons.chat),
                text: 'Chats',
              ),
              Tab(
                icon: Icon(Icons.device_hub),
                text: 'Mesh Relay',
              ),
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
        floatingActionButton: _buildSpeedDial(),
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
                  itemBuilder: (context, index) => _buildSwipeableChatTile(_chats[index]),
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
  if (_tabController.index == 1) {  // Currently on relay queue tab
    _tabController.animateTo(0);    // Switch to chats tab
  }
}

Widget _buildSpeedDial() {
  return FloatingActionButton(
    onPressed: _showAddOptions,
    tooltip: 'Add contact or discover',
    child: Icon(Icons.add),
  );
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
    discoveryData
  );
  
  // Determine real-time status
  if (connectionInfo != null && 
      connectionInfo.isConnected && 
      connectionInfo.otherUserName == chat.contactName) {
    connectionStatus = ConnectionStatus.connected;
  }
  else if (discoveredDevices.any((device) => 
    chat.contactPublicKey?.contains(device.uuid.toString()) ?? false)) {
    connectionStatus = ConnectionStatus.nearby;
  }
  else if (chat.isOnline) {
    connectionStatus = ConnectionStatus.nearby;
  }
  else {
    connectionStatus = ConnectionStatus.offline;
  }
  
  // Now use connectionStatus in the UI
  return Card(
    margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: connectionStatus.color.withValues(),
            child: Icon(
              Icons.person,
              color: connectionStatus.color,
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: connectionStatus.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Text(
              chat.contactName,
              style: TextStyle(
                fontWeight: chat.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 4), // Small spacing to prevent overflow
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: connectionStatus.color.withValues(),
              shape: BoxShape.circle,
            ),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: connectionStatus.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chat.lastMessage != null)
            Text(
              chat.lastMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: chat.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          if (chat.hasUnsentMessages)
            Row(
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
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.lastMessageTime != null)
            Text(
              _formatTime(chat.lastMessageTime!),
              style: TextStyle(fontSize: 12),
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
Widget _buildSwipeableChatTile(ChatListItem chat) {
  return Dismissible(
    key: Key('chat_${chat.chatId}'),
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
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.chat_bubble_outline,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(),
        ),
        SizedBox(height: 16),
        Text(
          hasNearbyDevices 
            ? 'Connect to a nearby device to start chatting'
            : 'No conversations yet',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => setState(() => _showDiscoveryOverlay = true),
          icon: Icon(Icons.bluetooth_searching),
          label: Text('Discover Devices'),
        ),
      ],
    ),
  );
}

  Widget _buildBLEStatusBanner(AsyncValue<BluetoothLowEnergyState> bleStateAsync) {
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
      bleService.otherDevicePersistentId == chat.contactPublicKey) {
    return ConnectionStatus.connecting;
  }
  
  // Check if device is nearby (discovered via BLE scan)
  if (chat.contactPublicKey != null) {
    // Method 1: Check via manufacturer data hash
    final isOnlineViaHash = _isContactOnlineViaHash(chat.contactPublicKey!, discoveryData.cast<String, DiscoveredDevice>());
    if (isOnlineViaHash) {
      return ConnectionStatus.nearby;
    }
    
    // Method 2: Check via device UUID mapping (fallback)
    final isNearbyViaUUID = discoveredDevices.any((device) => 
      chat.contactPublicKey!.contains(device.uuid.toString())
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

bool _isContactOnlineViaHash(String contactPublicKey, Map<String, DiscoveredDevice> discoveryData) {
  if (discoveryData.isEmpty) return false;
  
  for (final device in discoveryData.values) {
    if (device.isKnownContact && 
        device.contactInfo?.publicKey == contactPublicKey) {
      return true;
    }
  }
  
  return false;
}

void _setupPeripheralConnectionListener() {
    if (!Platform.isAndroid) return;
    
    final bleService = ref.read(bleServiceProvider);
    
    _peripheralConnectionSubscription = bleService.peripheralManager.connectionStateChanged
      .distinct((prev, next) => 
        prev.central.uuid == next.central.uuid && prev.state == next.state)
      .where((event) => 
        bleService.isPeripheralMode && 
        event.state == ble.ConnectionState.connected)
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
    _discoveryDataSubscription = ref.read(bleServiceProvider).discoveryData.listen((discoveryData) {
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

void _showAddOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.bluetooth_searching),
              title: Text('Discover Nearby Devices'),
              subtitle: Text('Connect via Bluetooth'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _showDiscoveryOverlay = true);
              },
            ),
            ListTile(
              leading: Icon(Icons.qr_code_scanner),
              title: Text('Add Contact via QR'),
              subtitle: Text('Exchange QR codes for secure contact'),
              onTap: () {
                Navigator.pop(context);
                _navigateToQRExchange();
              },
            ),
          ],
        ),
      ),
    );
  }

void _onDeviceSelected(Peripheral device) async {
  setState(() => _showDiscoveryOverlay = false);
  
  // Show a snackbar for connection progress
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          SizedBox(width: 12),
          Flexible(
            child: Text(
              'Connecting to ${device.uuid.toString().substring(0, 8)}...',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      duration: Duration(seconds: 3),
    ),
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

void _navigateToQRExchange() async {
  final result = await Navigator.push(
    context,
    MaterialPageRoute(builder: (context) => QRContactScreen()),
  );
  
  if (result == true) {
    _loadChats(); // Refresh to show new contact
  }
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
  
  // Now it's safe to use context
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Edit Display Name'),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: 'Your name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext), // Use dialogContext
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final navigator = Navigator.of(dialogContext);
            final messenger = ScaffoldMessenger.of(context);
            final name = controller.text.trim();
            
            if (name.isEmpty) {
              messenger.showSnackBar(
                SnackBar(content: Text('Name cannot be empty')),
              );
              return;
            }
            
            navigator.pop(); // Pop first
            
            try {
              // Use modern AsyncNotifier provider for real-time updates
              await ref.read(usernameProvider.notifier).updateUsername(name);

              messenger.showSnackBar(
                SnackBar(content: Text('Name updated and synced across devices')),
              );
            } catch (e) {
              if(kDebugMode){
              print('Error updating name: $e');
              }
            }
          },
          child: Text('Save'),
        ),
      ],
    ),
  );
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

  void _handleMenuAction(ChatsMenuAction action) {
    switch (action) {
      case ChatsMenuAction.openProfile:
        _openProfile();
        break;
      case ChatsMenuAction.openContacts:
        _openContacts();
        break;
      case ChatsMenuAction.openArchives:
        _openArchives();
        break;
      case ChatsMenuAction.settings:
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
      MaterialPageRoute(
        builder: (context) => ArchiveScreen(),
      ),
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
    ) ?? false;
  }
  
  Future<void> _archiveChat(ChatListItem chat) async {
    try {
      final result = await ref.read(archiveOperationsProvider.notifier).archiveChat(
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.archive,
                    color: Theme.of(context).colorScheme.onInverseSurface,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Archived chat with ${chat.contactName}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              action: SnackBarAction(
                label: 'View Archives',
                onPressed: _openArchives,
              ),
              duration: Duration(seconds: 4),
            ),
          );

          // Refresh the chat list
          _loadChats();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to archive chat: ${result.message}'),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => _archiveChat(chat),
                textColor: Theme.of(context).colorScheme.onError,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error archiving chat: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
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
    ) ?? false;
  }

  Future<void> _deleteChat(ChatListItem chat) async {
    try {
      final result = await _chatManagementService.deleteChat(chat.chatId);

      if (mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete,
                    color: Theme.of(context).colorScheme.onInverseSurface,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Deleted chat with ${chat.contactName}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              duration: Duration(seconds: 3),
            ),
          );

          // Refresh the chat list
          _loadChats();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete chat: ${result.message}'),
              backgroundColor: Theme.of(context).colorScheme.error,
              action: SnackBarAction(
                label: 'Retry',
                onPressed: () => _deleteChat(chat),
                textColor: Theme.of(context).colorScheme.onError,
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting chat: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _showChatContextMenu(ChatListItem chat) {
    final isPinned = _chatManagementService.isChatPinned(chat.chatId);
    final hasUnread = chat.unreadCount > 0;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(100, 100, 100, 100), // Will be adjusted by Flutter
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
              Icon(Icons.delete, size: 18, color: Theme.of(context).colorScheme.error),
              SizedBox(width: 8),
              Text('Delete Chat', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: hasUnread ? 'mark_read' : 'mark_unread',
          child: Row(
            children: [
              Icon(hasUnread ? Icons.mark_chat_read : Icons.mark_chat_unread, size: 18),
              SizedBox(width: 8),
              Text(hasUnread ? 'Mark as Read' : 'Mark as Unread'),
            ],
          ),
        ),
        PopupMenuItem(
          value: isPinned ? 'unpin' : 'pin',
          child: Row(
            children: [
              Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined, size: 18),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              duration: Duration(seconds: 2),
            ),
          );

          // Refresh the chat list to update sorting
          _loadChats();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to ${chat.chatId.contains('pin') ? 'unpin' : 'pin'} chat: ${result.message}'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error toggling pin: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _refreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _unreadCountSubscription?.cancel();
    _discoveryDataSubscription?.cancel();
    _searchController.dispose();
    _peripheralConnectionSubscription?.cancel();
    _chatManagementService.dispose();
    super.dispose();
  }
}