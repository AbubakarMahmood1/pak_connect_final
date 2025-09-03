import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../providers/ble_providers.dart';
import '../../data/repositories/chats_repository.dart';
import '../../domain/entities/chat_list_item.dart';
import '../widgets/device_tile.dart';
import 'discovery_screen.dart';
import 'chat_screen.dart';
import 'permission_screen.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  final ChatsRepository _chatsRepository = ChatsRepository();
  final TextEditingController _searchController = TextEditingController();
  
  List<ChatListItem> _chats = [];
  bool _isLoading = true;
  String _searchQuery = '';
  Timer? _refreshTimer;
  Timer? _searchDebounceTimer;

  @override
  void initState() {
    super.initState();
    _loadChats();
    _setupPeriodicRefresh();
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
    
    return Scaffold(
      appBar: AppBar(
        title: Text('Chats'),
        leading: GestureDetector(
          onTap: () => _showSettings(),
          child: Padding(
            padding: EdgeInsets.all(8.0),
            child: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Icon(Icons.person, color: Colors.white),
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: () => _showSearch(),
            icon: Icon(Icons.search),
          ),
        ],
      ),
      body: Column(
        children: [
          // BLE status banner
          _buildBLEStatusBanner(bleStateAsync),
          
          // Search bar (if active)
          if (_searchQuery.isNotEmpty) _buildSearchBar(),
          
          // Chats list
          Expanded(
            child: _isLoading 
              ? Center(child: CircularProgressIndicator())
              : _chats.isEmpty 
                ? _buildEmptyState()
                : RefreshIndicator(
                    onRefresh: () async => _loadChats(),
                    child: ListView.builder(
                      itemCount: _chats.length,
                      itemBuilder: (context, index) => _buildChatTile(_chats[index]),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToDiscovery(),
        child: Icon(Icons.add),
        tooltip: 'Find new devices',
      ),
    );
  }

  Widget _buildChatTile(ChatListItem chat) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: chat.isOnline 
            ? Colors.green.withOpacity(0.2)
            : Colors.grey.withOpacity(0.2),
          child: Icon(
            Icons.person,
            color: chat.isOnline ? Colors.green : Colors.grey,
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(chat.contactName)),
            if (chat.unreadCount > 0)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${chat.unreadCount}',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
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
            Row(
              children: [
                Text(
                  chat.displayLastSeen,
                  style: TextStyle(
                    fontSize: 12,
                    color: chat.isOnline ? Colors.green : Colors.grey,
                  ),
                ),
                if (chat.hasUnsentMessages) ...[
                  SizedBox(width: 8),
                  Icon(Icons.error_outline, size: 14, color: Colors.red),
                  Text(' Failed', style: TextStyle(fontSize: 12, color: Colors.red)),
                ],
              ],
            ),
          ],
        ),
        onTap: () => _openChat(chat),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('No conversations yet'),
          SizedBox(height: 8),
          Text('Tap + to find nearby devices'),
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
                Text('Bluetooth ${state.name} - Enable to see online contacts'),
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

void _openChat(ChatListItem chat) async {
  if (!mounted) return;
  
  // Mark as read immediately
  await _chatsRepository.markChatAsRead(chat.chatId);
  
  // Navigate using repository data - works offline!
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

  void _navigateToDiscovery() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => DiscoveryScreen()),
    ).then((_) => _loadChats());
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
    // Navigate to settings (you can implement this later)
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Settings coming soon')),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }
}