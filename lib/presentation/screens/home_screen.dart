import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart'
    hide ConnectionState;
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import '../providers/ble_providers.dart';
import '../providers/archive_provider.dart';
import '../providers/mesh_networking_provider.dart';
import '../../core/interfaces/i_chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../../core/models/connection_status.dart';
import '../widgets/discovery_overlay.dart';
import '../widgets/relay_queue_widget.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'archive_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import '../../core/models/connection_info.dart';
import '../../core/discovery/device_deduplication_manager.dart';
import '../../core/services/home_screen_facade.dart';
import '../../domain/services/chat_management_service.dart';
import '../controllers/home_screen_controller.dart';
import '../services/chat_interaction_handler.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

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
  late final IChatsRepository _chatsRepository;
  final ChatManagementService _chatManagementService = ChatManagementService();
  late final HomeScreenController _controller;
  final TextEditingController _searchController = TextEditingController();

  // Tab controller for Chats and Relay Queue
  late TabController _tabController;

  List<ChatListItem> get _chats => _controller.chats;
  bool get _isLoading => _controller.isLoading;
  String get _searchQuery => _controller.searchQuery;
  Stream<int>? get _unreadCountStream => _controller.unreadCountStream;
  bool _showDiscoveryOverlay = false;

  @override
  void initState() {
    super.initState();
    _chatsRepository = GetIt.instance<IChatsRepository>();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(
      _onTabChanged,
    ); // Listen for tab changes to update FAB
    _controller = HomeScreenController(
      ref: ref,
      context: context,
      chatsRepository: _chatsRepository,
      logger: _logger,
      chatManagementService: _chatManagementService,
      homeScreenFacade: HomeScreenFacade(
        chatsRepository: _chatsRepository,
        bleService: ref.read(connectionServiceProvider),
        chatManagementService: _chatManagementService,
        context: context,
        ref: ref,
        enableListCoordinatorInitialization: false,
        interactionHandlerBuilder:
            ({context, ref, chatsRepository, chatManagementService}) {
              return ChatInteractionHandler(
                context: context,
                ref: ref,
                chatsRepository: chatsRepository,
                chatManagementService: chatManagementService,
              );
            },
      ),
    )..addListener(_onControllerChanged);
    _controller.initialize();
  }

  void _onTabChanged() {
    // Rebuild to update FAB visibility immediately when tab changes
    if (mounted) {
      setState(() {});
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadChats() => _controller.loadChats();

  Future<void> _updateSingleChatItem() => _controller.updateSingleChatItem();

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
    final discoveredDevices = ref.watch(discoveredDevicesProvider).value ?? [];
    final deduplicatedDevices =
        ref.watch(deduplicatedDevicesProvider).value ?? {};

    // 🎯 Use controller facade for connection status
    final connectionStatus = _controller.determineConnectionStatus(
      contactPublicKey: chat.contactPublicKey,
      contactName: chat.contactName,
      currentConnectionInfo: connectionInfo,
      discoveredDevices: discoveredDevices,
      discoveryData: deduplicatedDevices,
      lastSeenTime: chat.lastSeen,
    );

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
          _controller.onSearchChanged(query);
        },
      ),
    );
  }

  void _onDeviceSelected(Peripheral device) async {
    setState(() => _showDiscoveryOverlay = false);
    _logger.info('Connecting to device: ${device.uuid.toString().shortId(8)}');
    await _controller.handleDeviceSelected(device);
  }

  void _openChat(ChatListItem chat) async {
    await _controller.openChat(chat);
  }

  void _showSearch() {
    setState(() {
      if (_searchQuery.isEmpty) {
        _controller.onSearchChanged(' ');
      } else {
        _clearSearch();
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _controller.clearSearch();
  }

  void _showSettings() {
    _controller.openSettings();
  }

  void _openProfile() {
    _controller.openProfile();
  }

  void _editDisplayName() async {
    // Get the username first using modern AsyncNotifier provider
    final currentName = await ref.read(usernameProvider.future);

    // Check mounted after async
    if (!mounted) return;

    await _controller.editDisplayName(currentName);
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

  void _openContacts() => _controller.openContacts();

  void _openArchives() => _controller.openArchives();

  Future<bool> _showArchiveConfirmation(ChatListItem chat) =>
      _controller.showArchiveConfirmation(chat);

  Future<void> _archiveChat(ChatListItem chat) async {
    await _controller.archiveChat(chat);
  }

  Future<bool> _showDeleteConfirmation(ChatListItem chat) =>
      _controller.showDeleteConfirmation(chat);

  Future<void> _deleteChat(ChatListItem chat) async {
    await _controller.deleteChat(chat);
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
    await _controller.toggleChatPin(chat);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }
}
